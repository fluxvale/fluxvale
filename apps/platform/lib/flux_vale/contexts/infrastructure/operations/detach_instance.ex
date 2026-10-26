defmodule FluxVale.Infrastructure.Operations.DetachInstance do
  @moduledoc """
  Detaches an instance from its gateway (ADR-0039 §3): removes the serve
  route and the namespace policy's gateway entry, and deletes the
  pairing row.

  Detach does **not** change exposure. The instance returns to
  panel-only private — today's meaning — and the owner's two switches
  stay independent. Idempotent: an instance with no route detaches as
  success (the posture already holds).
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Instance

  @spec call(AccessGateway.t(), Instance.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessGateway{} = gateway, %Instance{} = instance, _opts \\ []) do
    AccessProvider.impl_for(gateway).detach_instance(gateway, instance)
  end
end
