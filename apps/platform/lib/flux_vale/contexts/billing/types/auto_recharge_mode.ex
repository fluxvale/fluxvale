defmodule FluxVale.Billing.Types.AutoRechargeMode do
  @moduledoc """
  The auto-recharge lane the org opted into (#829, decision G): one
  setting row serves both lanes, and arming each is its own consent.

  - `:off` — the default; nothing fires.
  - `:reminder` — the launch lane: when the wallet dips below the
    threshold, the org gets a one-click top-up email (at most one per
    24h per episode). The staged charge lane (`:auto`, plan S2) joins
    this type later as its own explicit owner consent — never implied
    by a reminder opt-in.
  """

  use Ash.Type.Enum, values: [:off, :reminder]
end
