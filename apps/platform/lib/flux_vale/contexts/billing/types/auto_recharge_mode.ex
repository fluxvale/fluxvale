defmodule FluxVale.Billing.Types.AutoRechargeMode do
  @moduledoc """
  The auto-recharge lane the org opted into (#829, decision G): one
  setting row serves both lanes, and arming each is its own consent.

  - `:off` — the default; nothing fires.
  - `:reminder` — the launch lane: when the wallet dips below the
    threshold, the org gets a one-click top-up email (at most one per
    24h per episode).
  - `:auto` — the staged charge lane: the platform charges the org's
    saved payment method below the threshold. Settable only when the
    platform gate is on (the Polar Pro upgrade — activation slice S6)
    AND a method is attached; arming it is its own explicit owner
    consent, never implied by a reminder opt-in.
  """

  use Ash.Type.Enum, values: [:off, :reminder, :auto]
end
