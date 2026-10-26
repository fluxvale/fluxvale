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
  confirmation. The provider's own cleanup removes a half-landed route,
  so a failure leaves the instance exactly as private as it was.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Instance

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
        AccessProvider.impl_for(gateway).attach_instance(gateway, instance)
    end
  end
end
