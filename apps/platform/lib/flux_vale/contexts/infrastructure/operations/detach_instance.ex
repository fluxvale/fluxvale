defmodule FluxVale.Infrastructure.Operations.DetachInstance do
  @moduledoc """
  Detaches an instance from its gateway (ADR-0039 §3): removes the serve
  route and the namespace policy's gateway entry, and deletes the
  pairing row.

  Detach does **not** change exposure. The instance returns to
  panel-only private — today's meaning — and the owner's two switches
  stay independent. Idempotent: an instance with no route detaches as
  success (the posture already holds).

  The org check mirrors `AttachInstance`'s: the provider looks a route
  up by instance id alone, so without it `detach(a_gateway,
  b_instance)` would delete another tenant's pairing and rewrite their
  policy — a tenant-isolation breach, not a validation error.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Instance

  @spec call(AccessGateway.t(), Instance.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessGateway{} = gateway, %Instance{} = instance, _opts \\ []) do
    if instance.organization_id == gateway.organization_id do
      AccessProvider.impl_for(gateway).detach_instance(gateway, instance)
    else
      {:error, :different_organization}
    end
  end
end
