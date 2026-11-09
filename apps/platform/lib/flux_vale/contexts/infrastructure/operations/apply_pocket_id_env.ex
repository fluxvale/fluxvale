defmodule FluxVale.Infrastructure.Operations.ApplyPocketIdEnv do
  @moduledoc """
  The SSO-scoped env-update + rollout-restart primitive (#597 S5,
  §4.6, D5) — the ONE way a deployed instance's env changes without a
  full re-deploy. Deliberately narrow: it rewrites ONLY the wiring
  recipe's keys (the same keys `ConnectPocketId` force-changes at
  create), never arbitrary env (general env editing stays deferred —
  D5's scope line).

  Order is the whole safety story (the plan's risk note): the k8s
  Secret update lands FIRST and atomically (SSA upsert of the merged
  map — a failed apply leaves the old Secret byte-identical, no
  half-written state exists), and only then the rolling restart picks
  the new values up. A restart that fails leaves updated-Secret +
  old-env pods — stale but working, and the caller's retry converges;
  the reverse order could boot NEW values then roll them back, which
  is the un-testable state this ordering exists to prevent.

  The instance row is NOT rewritten here: the row's `env_vars` is the
  create-time snapshot the deployer owns; this primitive is the
  deployed-instance overlay (S4's `merge_pocket_id_env` funnel stays
  the row writer for pre-deploy wirings — and the retrofit path calls
  BOTH: the row records the wiring's values for the next re-deploy,
  this primitive makes the RUNNING workload carry them now).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @env_secret "app-env"
  @deployment_name "app"

  @doc """
  Applies `sso_env` (the recipe's keys → values, built by the caller)
  to a DEPLOYED instance — plus `remove_keys` (the disconnect's
  strip: keys the Secret should no longer carry at all, the app's
  own unset semantics). k8s Secret merge-upsert + rolling restart.
  `{:error, reason}` — `:not_deployed` (no namespace — the pre-deploy
  path needs no rollout), or either k8s call's own error.
  """
  @spec apply_to_running(Instance.t(), %{optional(String.t()) => String.t()}, keyword()) ::
          :ok | {:error, term()}
  def apply_to_running(%Instance{} = instance, sso_env, opts \\ []) when is_map(sso_env) do
    remove = Keyword.get(opts, :remove_keys, [])

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         {:ok, namespace} <- deployed_namespace(instance),
         {:ok, data} <- read_env(kubeconfig, namespace),
         merged =
           data
           |> Map.merge(sso_env)
           |> Map.drop(remove),
         :ok <- upsert_secret(kubeconfig, namespace, merged) do
      rollout(kubeconfig, namespace, opts)
    end
  end

  # A deployed instance's namespace is pinned; anything else has no
  # running workload to reach (the honest refusal, not a nil crash).
  defp deployed_namespace(%Instance{namespace: ns}) when is_binary(ns),
    do: {:ok, ns}

  defp deployed_namespace(%Instance{}), do: {:error, :not_deployed}

  # The Secret the deployer wrote: read-merge-write so ONLY the recipe's
  # keys move (the map merge above) — concurrent unrelated keys ride
  # through SSA's field-level ownership untouched.
  defp read_env(kubeconfig, namespace) do
    case Secret.get_data(kubeconfig, namespace, @env_secret) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _empty} -> {:ok, %{}}
      {:error, %K8s.Error{reason: :not_found}} -> {:ok, %{}}
      {:error, _other} = error -> error
    end
  end

  defp upsert_secret(kubeconfig, namespace, data) do
    case Secret.upsert(kubeconfig, namespace, @env_secret, data) do
      {:ok, _secret} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The rolling restart — the "apply" half of the primitive. A refusal
  # here leaves the new Secret staged and the old pods serving: the
  # caller's honest retry re-upserts (idempotent) and re-rolls.
  defp rollout(kubeconfig, namespace, _opts) do
    case Deployment.restart(kubeconfig, namespace, @deployment_name) do
      {:ok, _deployment} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
