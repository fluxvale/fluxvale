defmodule FluxVale.Infrastructure.Operations.InstanceEnvSecret do
  @moduledoc """
  The ONE way a deployed instance's env Secret changes without a full
  re-deploy (#597 S5's `ApplyPocketIdEnv`, generalized for #731 T1,
  ADR-0052 decision 7). Two callers share this seam:

  - the three SSO operations (`ConnectPocketId`'s retrofit,
    `DisconnectPocketId`'s strip, `RotatePocketIdSecret`) pass only
    their recipe's keys — the ownership guard is the public action's,
    not this seam's — through `apply_locked/3` (row lock + upsert +
    restart);
  - the public in-place env action splits the same two legs:
    `upsert/5` inside its own row transaction, `restart/2` post-commit
    (never `apply_locked/3` — it already holds the lock).

  Order is the whole safety story: the k8s Secret update lands FIRST
  and atomically (SSA upsert of the merged map — a failed apply leaves
  the old Secret byte-identical, no half-written state exists), and
  only then does the rolling restart pick the new values up. A restart
  that fails leaves updated-Secret + old-env pods — stale but working,
  and the caller's retry converges; the reverse order could boot NEW
  values then roll them back, which is the un-testable state this
  ordering exists to prevent.

  Note: `read_env/3` treats an absent Secret as empty only when the
  instance has no row env to project (`expect_existing: false`). A
  deployed instance whose row carries env but whose Secret is gone is
  a broken state: writing only the patch's keys would boot the app
  without its other env, so `upsert/5` refuses with `:missing` and the
  caller says "redeploy to repair".

  The instance row is NOT written here: every caller owns its row
  write (the SSO operations' `:merge_system_env` funnel, the in-place
  action's `env_vars` force-change).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Repo

  require Ash.Query

  @env_secret "app-env"
  @deployment_name "app"

  @doc """
  The SSO callers' composed operation: lock the instance row, re-read
  it `FOR UPDATE`, apply `set`/`remove` to the Secret, then restart —
  all inside one transaction (ADR-0052 decision 7). The lock is the
  same one the public env action takes, so a concurrent PATCH and an
  SSO write serialize instead of interleaving two read-merge-writes.

  `{:error, reason}` — `:not_deployed` (no namespace — the pre-deploy
  path needs no rollout), `:missing` (a deployed row with env but no
  Secret), or either k8s call's own error. A failed restart returns the
  error with the Secret already updated; the row is not changed here.
  """
  @spec apply_locked(Instance.t(), map(), [String.t()]) :: :ok | {:error, term()}
  def apply_locked(%Instance{} = instance, set, remove) when is_map(set) and is_list(remove) do
    result =
      Repo.transaction(fn ->
        with {:ok, %Instance{} = locked} <- lock_row(instance.id),
             {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(locked),
             {:ok, namespace} <- deployed_namespace(locked),
             :ok <- upsert(kubeconfig, namespace, set, remove, map_size(locked.env_vars) > 0),
             :ok <- restart(kubeconfig, namespace) do
          :ok
        else
          # coveralls-ignore-start - defensive: the SSO operations load
          # the row immediately before this call; a teardown between the
          # two reads is the #86 race window ExUnit cannot stage
          # deterministically.
          {:ok, nil} ->
            Repo.rollback(:instance_gone)

          # coveralls-ignore-stop

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read-merge-write the `app-env` Secret: only the given keys move in
  this call's map. `expect_existing` is the instance row's
  `env_vars != %{}` — a missing Secret then means the live projection
  was lost, not that the app has no env.

  Honest limit: every writer here uses the same SSA field manager, so
  a re-deploy writing the Secret between the read and the upsert has
  its keys reverted to this call's snapshot until its next write — the
  same stale-but-working, converge-on-retry posture a failed roll
  leaves (not the cross-manager immunity SSA implies).
  """
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), map(), [String.t()], boolean()) ::
          :ok | {:error, term()}
  def upsert(kubeconfig, namespace, set, remove, expect_existing)
      when is_map(set) and is_list(remove) do
    with {:ok, data} <- read_env(kubeconfig, namespace, expect_existing),
         merged =
           data
           |> Map.merge(set)
           |> Map.drop(remove),
         {:ok, _secret} <- Secret.upsert(kubeconfig, namespace, @env_secret, merged) do
      :ok
    end
  end

  @doc """
  The rolling restart — the "apply" half of the primitive. A refusal
  here leaves the new Secret staged and the old pods serving: the
  caller's honest retry re-upserts (idempotent) and re-rolls.
  """
  @spec restart(Kubereq.Kubeconfig.t(), String.t()) :: :ok | {:error, term()}
  def restart(kubeconfig, namespace) do
    case Deployment.restart(kubeconfig, namespace, @deployment_name) do
      {:ok, _deployment} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The row lock the public action takes (AdoptCurrentRow's serialization
  # stance). Read inside the transaction so the lock covers the Secret
  # apply and the restart.
  defp lock_row(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  # A deployed instance's namespace is pinned; anything else has no
  # running workload to reach (the honest refusal, not a nil crash).
  defp deployed_namespace(%Instance{namespace: ns}) when is_binary(ns),
    do: {:ok, ns}

  defp deployed_namespace(%Instance{}), do: {:error, :not_deployed}

  defp read_env(kubeconfig, namespace, expect_existing) do
    case Secret.get_data(kubeconfig, namespace, @env_secret) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:error, %K8s.Error{reason: :not_found}} when not expect_existing ->
        {:ok, %{}}

      {:error, %K8s.Error{reason: :not_found}} ->
        {:error, :missing}

      {:error, _other} = error ->
        error
    end
  end
end
