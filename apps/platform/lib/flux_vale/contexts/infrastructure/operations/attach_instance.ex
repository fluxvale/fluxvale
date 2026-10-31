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
    case AccessProvider.impl_for(gateway).attach_instance(gateway, instance) do
      {:ok, route} ->
        case apply_access_edge(gateway, instance) do
          :ok ->
            {:ok, route}

          {:error, reason} ->
            unwind_failed_attach(instance, route, reason)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Routes first, then the policy admission (the provider's own attach
  # order: the serve config, then admit_gateway). Both must land for the
  # attach to succeed.
  defp apply_access_edge(gateway, instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         :ok <- access_arm(kubeconfig, gateway, instance) do
      admit_edge(kubeconfig, instance)
    end
  end

  # :running serves; anything else points at the wake endpoint (the
  # ServeConfig.target_for decision shape — a sleeping instance's first
  # knock must find the waking page, not a connectionless Service).
  defp access_arm(kubeconfig, gateway, %{status: :running} = instance) do
    EdgeRoutes.apply_access_serving(kubeconfig, gateway, instance)
  end

  defp access_arm(kubeconfig, gateway, instance) do
    EdgeRoutes.apply_access_wake(kubeconfig, gateway, instance)
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
