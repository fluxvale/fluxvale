defmodule FluxVale.Billing.Types.AutoRechargeDisabledReason do
  @moduledoc """
  Why an armed auto-recharge setting was disarmed with a reason
  (#829, decisions D3/F): the disable email says why, with a one-click
  top-up link — the reason is the row's own record of that event.

  - `:manual` — the owner disarmed it.
  - `:declines` — `failure_strikes` consecutive declines auto-disabled
    it (decision F).
  - `:no_method` — two sweeps passed with no saved method (decision
    D3's notice-then-disable).
  """

  use Ash.Type.Enum, values: [:manual, :declines, :no_method]
end
