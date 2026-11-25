defmodule FluxVale.Infrastructure.Operations.DetachInstance do
  @moduledoc """
  Detaches an instance from its gateway (ADR-0039 §3): removes the serve
  route and the namespace policy's gateway entry, and deletes the
  pairing row.

  Detach does **not** change exposure. The instance returns to
  panel-only private — today's meaning — and the owner's two switches
  stay independent. Idempotent: an instance with no route detaches as
  success (the posture already holds).

  The access edge (ADR-0040 §7) is removed here too — AFTER the
  provider's detach succeeds. The order mirrors the provider's own
  discipline (policy → row → configs): the access IngressRoutes are the
  access edge's configs, so they go last, once the reachability gate
  has closed and the pairing row is gone. A failure past the provider
  is fail-closed either way — the re-narrowed policy denies the edge
  namespace, so any route that outlived this call routes nothing — and
  the idempotent retry converges the leftover objects.

  The org check mirrors `AttachInstance`'s: the provider looks a route
  up by instance id alone, so without it `detach(a_gateway,
  b_instance)` would delete another tenant's pairing and rewrite their
  policy — a tenant-isolation breach, not a validation error.

  The closed pairing also re-tells the instance's running app its URL
  env (the address lane's sync — best-effort, post-commit, warn-only).
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv

  require Logger

  @spec call(AccessGateway.t(), Instance.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessGateway{} = gateway, %Instance{} = instance, _opts \\ []) do
    if instance.organization_id == gateway.organization_id do
      detach(gateway, instance)
    else
      {:error, :different_organization}
    end
  end

  # The provider lands its order (policy → row → configs), then the
  # access edge goes, then the view re-renders after the primary write
  # commits (the org lost an attached private instance) — best-effort,
  # the derived-state stance (ADR-0040 §4); a failure never fails the
  # detach.
  defp detach(gateway, instance) do
    with :ok <- AccessProvider.impl_for(gateway).detach_instance(gateway, instance),
         :ok <- remove_access_edge(instance) do
      retell_url_env(instance)
      RenderAccessDNS.call()
      :ok
    end
  end

  # The lane's ruling: best-effort, post-commit of the pairing's
  # removal (above), warn-only — a sync failure is logged and never
  # fails the detach; the next event or a redeploy converges the env.
  defp retell_url_env(instance) do
    case SyncInstanceUrlEnv.call(instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Detach: the URL-env sync failed for instance #{instance.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp remove_access_edge(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      EdgeRoutes.apply_access_none(kubeconfig, instance)
    end
  end
end
