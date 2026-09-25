defmodule FluxVale.Infrastructure.Operations.TeardownInstance do
  @moduledoc """
  Tears down an Instance's K8s namespace and hard-deletes the row — the
  AshOban `:teardown` trigger's body (ADR-0005).

  Deletes each resource then the namespace (namespace deletion
  garbage-collects everything anyway; the per-resource deletes release
  PVs promptly and keep the audit trail explicit). All deletes are
  `:not_found`-tolerant — teardown is idempotent, safe to retry.

  On K8s failure: log + `{:error, _}` **without** flipping status — the
  row stays `:deleting` and Oban retries transient outages; the trigger's
  `on_error` (`:mark_teardown_error`) surfaces exhaustion as `:error`
  with a retry hint.
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Logger

  @doc """
  Tears down a `:deleting` Instance. `{:ok, instance}` on success (row
  hard-deleted); `{:error, _}` lets Oban retry.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()} | {:error, term()}
  def call(%{status: :deleting} = instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        finish_teardown(kubeconfig, instance)

      {:error, error} ->
        log_teardown_failure(instance, error)
    end
  end

  # Oban retry racing another writer — already superseded, not failed.
  def call(instance), do: {:ok, instance}

  defp finish_teardown(kubeconfig, instance) do
    case teardown_resources(kubeconfig, instance) do
      :ok ->
        destroy_row(instance)

      {:error, error} ->
        log_teardown_failure(instance, error)
    end
  end

  # authorize?: false: trigger context has no actor and the AshOban
  # bypass doesn't propagate to nested calls — entry to :deleting was
  # ownership-checked by the delete action.
  defp destroy_row(instance) do
    case Ash.destroy(instance, authorize?: false) do
      :ok ->
        {:ok, instance}

      {:error, error} ->
        # coveralls-ignore-start - defensive: instances have no FK
        # dependents, so Ash.destroy on a valid row can't fail in tests.
        # A dependent row blocks the delete — surface it so Oban retries /
        # on_error makes it visible rather than silently orphaning the row.
        Logger.warning("Instance #{instance.id} row delete failed: #{inspect(error)}")

        # coveralls-ignore-stop
        {:error, error}
    end
  end

  defp log_teardown_failure(instance, error) do
    Logger.warning("Instance #{instance.id} teardown failed: #{inspect(error)}")
    {:error, error}
  end

  # Reverse creation order; every delete tolerates :not_found.
  defp teardown_resources(kubeconfig, instance) do
    namespace = instance.namespace

    with {:ok, _ingress} <- safe_delete(Ingress, kubeconfig, namespace, "app-ingress"),
         {:ok, _service} <- safe_delete(Service, kubeconfig, namespace, "app"),
         {:ok, _deployment} <- safe_delete(Deployment, kubeconfig, namespace, "app"),
         {:ok, _secret} <- safe_delete(Secret, kubeconfig, namespace, "app-env"),
         {:ok, _pvc} <- safe_delete(PersistentVolumeClaim, kubeconfig, namespace, "app-data"),
         {:ok, _policy} <-
           safe_delete(NetworkPolicy, kubeconfig, namespace, "default-deny-ingress"),
         {:ok, _quota} <- safe_delete(ResourceQuota, kubeconfig, namespace, "app-quota"),
         {:ok, _binding} <- safe_delete(RoleBinding, kubeconfig, namespace, "fluxvale-platform"),
         {:ok, _namespace} <- safe_delete(Namespace, kubeconfig, namespace) do
      :ok
    end
  end

  defp safe_delete(module, kubeconfig, namespace, name) do
    case module.delete(kubeconfig, namespace, name) do
      :ok -> {:ok, nil}
      {:error, %Error{reason: :not_found}} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp safe_delete(Namespace = module, kubeconfig, namespace) do
    case module.delete(kubeconfig, namespace) do
      :ok -> {:ok, nil}
      {:error, %Error{reason: :not_found}} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end
end
