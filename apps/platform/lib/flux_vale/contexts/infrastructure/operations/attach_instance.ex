defmodule FluxVale.Infrastructure.Operations.AttachInstance do
  @moduledoc """
  Attaches an instance to the org's gateway (ADR-0039 §3) — the
  owner-facing half of the exposure pairing.

  Preconditions, checked here rather than in the panel so the API cannot
  bypass them:

  - the gateway exists and belongs to the actor's org (the panel's
    read enforces the same; an actor is always authorized);
  - the gateway is `:active` or `:provisioning` (a suspended gateway
    is not serving; attaching to it would mint a route nobody can
    reach — the wallet's ladder is the fix, not a second switch);
  - the instance is `:private` — a public instance already has an
    address, and attaching would mint a second one (the two switches
    are independent, §3);
  - the instance belongs to the same org (a cross-org attach is a
    tenant-isolation breach, not a validation error).

  The provider does the cluster work; this module owns the ordering:
  attach (row + serve config + policy) first, then the row's
  confirmation — then the ACCESS EDGE (ADR-0040 §7): the access serving
  or wake arms per the instance's current status (`:running` serves,
  anything else points at the wake endpoint — the ServeConfig.target_for
  decision shape), and the policy re-apply that admits the edge
  namespace to the private+attached namespace (the widening is the
  platform's spec builder, not the provider's — the provider-agnostic
  seam keeps the provider knowing nothing of the edge dimension). The
  provider's own cleanup removes a half-landed route; if the access
  edge itself fails to land, the unwind here removes the row — a row
  whose cluster limbs failed claims a pairing nothing can reach (the
  row-claims-nothing discipline, the provider's own cleanup stance for
  its failed limbs), and the idempotent retry re-attaches cleanly.
  """

  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Logger

  # The same object name EdgeRoutes / SetExposure / the provider use.
  @policy "default-deny-ingress"

  @doc """
  `{:ok, route}` or `{:error, reason}`. `reason` is `:not_private |
  :gateway_not_active | :different_organization | term()`.
  """
  @spec call(AccessGateway.t(), Instance.t(), keyword()) ::
          {:ok, FluxVale.Infrastructure.AccessRoute.t()} | {:error, term()}
  def call(%AccessGateway{} = gateway, %Instance{} = instance, _opts \\ []) do
    cond do
      instance.organization_id != gateway.organization_id ->
        {:error, :different_organization}

      instance.exposure != :private ->
        {:error, :not_private}

      # The provider's own stance (its admit skips a nil namespace): a
      # pending instance has no namespace to route into — refuse cleanly
      # instead of a raw K8s crash in the access-edge limbs below.
      instance.namespace == nil ->
        {:error, :not_deployed}

      gateway.state not in [:active, :provisioning] ->
        {:error, :gateway_not_active}

      true ->
        attach_with_access_edge(gateway, instance)
    end
  end

  # The provider lands the pairing; the operation lands the access edge.
  # Split out of `call` so the failure arms stay readable (credo's depth
  # gate agrees with the reviewability).
  defp attach_with_access_edge(gateway, instance) do
    # Created-vs-existing (the provider-cleanup lesson: only unwind what
    # THIS attempt created): the provider answers {:ok, existing} on an
    # idempotent retry — a transient arm failure must not destroy a
    # pairing that predates this attempt.
    existed_before = pairing_row_existed?(instance)

    case AccessProvider.impl_for(gateway).attach_instance(gateway, instance) do
      {:ok, route} -> finish_attach(gateway, instance, route, existed_before)
      {:error, _reason} = error -> error
    end
  end

  defp finish_attach(gateway, instance, route, existed_before) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         :ok <- apply_access_edge(gateway, kubeconfig, instance) do
      reapply_if_status_moved(kubeconfig, gateway, instance)
      after_commit_render()
      {:ok, route}
    else
      {:error, reason} ->
        if existed_before,
          do: {:error, reason},
          else: unwind_failed_attach(instance, route, reason)
    end
  end

  # The view is derived state (ADR-0040 §4): attach just changed WHICH
  # hostnames answer (the org gained an attached private instance), so
  # the Corefile re-renders best-effort AFTER the pairing commits — a
  # failed render never fails the attach, and the 15-min pass converges.
  defp after_commit_render do
    RenderAccessDNS.call()
  end

  defp pairing_row_existed?(instance) do
    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, _route} -> true
      {:error, _not_found} -> false
    end
  end

  # Routes first, then the policy admission (the provider's own attach
  # order: the serve config, then admit_gateway). Both must land for the
  # attach to succeed.
  defp apply_access_edge(gateway, kubeconfig, instance) do
    with :ok <- access_arm(kubeconfig, gateway, instance) do
      admit_edge(kubeconfig, instance)
    end
  end

  # The arm is decided by the row's CURRENT status. The mint raced a
  # status write (a sleep or wake committing between the panel's read
  # and this apply — the controller's maybe_recheck interleaving):
  # re-read once after the mint and, if the status moved, re-apply per
  # the fresh status. One bounded re-apply, same claim-free idempotence.
  # A failed re-apply does not retro-fail the attach — the row and the
  # first arm stand; the visitor's ts.net-fallback request or the next
  # lifecycle write (sleep/wake/deploy/toggle) drives the flip. The
  # janitor does NOT periodically re-apply arms, so nothing silently
  # converges this — the failure is logged, never dropped.
  defp reapply_if_status_moved(kubeconfig, gateway, instance) do
    case Instance.get_by_id(instance.id, authorize?: false) do
      {:ok, %{status: status} = fresh} when status != instance.status ->
        case EdgeRoutes.apply_access_for_status(kubeconfig, gateway, fresh) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Attach: the fresh-status access re-apply failed for instance " <>
                "#{instance.id}: #{inspect(reason)}"
            )

            :ok
        end

      {:ok, _status_stable} ->
        :ok

      # coveralls-ignore-start - race only: the row vanished under the
      # attach (teardown won between the panel's read and this mint);
      # the pairing row dies with it in the FK cascade.
      {:error, _gone} ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # The dispatch lives in EdgeRoutes (one owner): :running serves,
  # anything wake-shaped stays wake.
  defp access_arm(kubeconfig, gateway, instance) do
    EdgeRoutes.apply_access_for_status(kubeconfig, gateway, instance)
  end

  # The private+attached widening (ADR-0040 Am. 1): the spec is built
  # from the INSTANCE record — the row the provider just committed makes
  # the gateway peer (pod-narrowed) and the access edge's dial compose
  # in one source of truth, the same object every exposure apply
  # converges on.
  defp admit_edge(kubeconfig, instance) do
    case NetworkPolicy.create(
           kubeconfig,
           instance.namespace,
           @policy,
           InstanceK8s.network_policy_spec(instance)
         ) do
      {:ok, _policy} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Best-effort unwind — the original error is what the caller surfaces
  # and retries on. The row must not stand (above); the access arms go
  # with it (apply_access_none is idempotent, 404s tolerated). The
  # provider's gateway-peer admission is left as it finds the namespace:
  # with no row it admits a gateway to nothing, the same residue the
  # provider's own cleanup_failed_attach leaves.
  defp unwind_failed_attach(instance, route, reason) do
    _destroyed = AccessRoute.destroy(route, authorize?: false)

    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        _removed = EdgeRoutes.apply_access_none(kubeconfig, instance)

      # coveralls-ignore-next-line race only: the limb resolved this moments ago
      {:error, _no_cluster} ->
        :ok
    end

    {:error, reason}
  end
end
