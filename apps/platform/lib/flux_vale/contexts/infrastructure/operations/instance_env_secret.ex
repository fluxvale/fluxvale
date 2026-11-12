defmodule FluxVale.Infrastructure.Operations.InstanceEnvSecret do
  @moduledoc """
  The ONE way a deployed instance's env Secret changes without a full
  re-deploy (#597 S5's `ApplyPocketIdEnv`, generalized for #731 T1,
  ADR-0052 decision 7). Two callers share this seam:

  - the three SSO operations (`ConnectPocketId`'s retrofit,
    `DisconnectPocketId`'s strip, `RotatePocketIdSecret`) pass only
    their recipe's keys — the ownership guard is the public action's,
    not this seam's — through `apply_to_running/4` (upsert + restart);
  - the public in-place env action splits the same two legs:
    `upsert/4` inside the row transaction, `restart/2` post-commit.

  Order is the whole safety story: the k8s Secret update lands FIRST
  and atomically (SSA upsert of the merged map — a failed apply leaves
  the old Secret byte-identical, no half-written state exists), and
  only then does the rolling restart pick the new values up. A restart
  that fails leaves updated-Secret + old-env pods — stale but working,
  and the caller's retry converges; the reverse order could boot NEW
  values then roll them back, which is the un-testable state this
  ordering exists to prevent.

  The instance row is NOT written here: every caller owns its row
  write (the SSO operations' `:merge_system_env` funnel, the in-place
  action's `env_vars` force-change).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @env_secret "app-env"
  @deployment_name "app"

  @doc """
  Applies `set` (and drops `remove`) to a DEPLOYED instance's Secret,
  then restarts the Deployment. `{:error, reason}` — `:not_deployed`
  (no namespace — the pre-deploy path needs no rollout), or either k8s
  call's own error.
  """
  @spec apply_to_running(Instance.t(), map(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def apply_to_running(%Instance{} = instance, set, remove, opts \\ [])
      when is_map(set) and is_list(remove) do
    _opts = opts

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, namespace} <- deployed_namespace(instance),
         :ok <- upsert(kubeconfig, namespace, set, remove) do
      restart(kubeconfig, namespace)
    end
  end

  @doc """
  Read-merge-write the `app-env` Secret: only the given keys move in
  this call's map. Honest limit: every writer here uses the same SSA
  field manager, so a re-deploy writing the Secret between the read
  and the upsert has its keys reverted to this call's snapshot until
  its next write — the same stale-but-working, converge-on-retry
  posture a failed roll leaves (not the cross-manager immunity SSA
  implies).
  """
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), map(), [String.t()]) ::
          :ok | {:error, term()}
  def upsert(kubeconfig, namespace, set, remove) when is_map(set) and is_list(remove) do
    with {:ok, data} <- read_env(kubeconfig, namespace),
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

  # A deployed instance's namespace is pinned; anything else has no
  # running workload to reach (the honest refusal, not a nil crash).
  defp deployed_namespace(%Instance{namespace: ns}) when is_binary(ns),
    do: {:ok, ns}

  defp deployed_namespace(%Instance{}), do: {:error, :not_deployed}

  defp read_env(kubeconfig, namespace) do
    case Secret.get_data(kubeconfig, namespace, @env_secret) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:error, %K8s.Error{reason: :not_found}} ->
        {:ok, %{}}

      # coveralls-ignore-start - a non-not_found read error other
      # than the upsert's own (staged): the K8s-client error surface
      # this seam passes through verbatim.
      {:error, _other} = error ->
        error

        # coveralls-ignore-stop
    end
  end
end
