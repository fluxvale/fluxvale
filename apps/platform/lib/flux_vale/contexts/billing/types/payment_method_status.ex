defmodule FluxVale.Billing.Types.PaymentMethodStatus do
  @moduledoc """
  Whether the org has a saved payment method on the provider (#829,
  decision C): arming `mode: :auto` requires `:attached` — consent over
  recurring charges needs a method on file. The provider vaults the
  instrument; we store this state plus the provider's customer id.

  - `:none` — the default; nothing to charge.
  - `:attached` — the provider has a usable saved method.
  """

  use Ash.Type.Enum, values: [:none, :attached]
end
