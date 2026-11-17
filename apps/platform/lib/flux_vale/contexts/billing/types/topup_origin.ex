defmodule FluxVale.Billing.Types.TopupOrigin do
  @moduledoc """
  Which lane created the top-up (#829, decision A — the attempt IS a
  top-up):

  - `:manual` — a buyer-initiated checkout (the wizard).
  - `:auto` — the staged off-session auto-recharge charge
    (StartAutoRecharge, #829 S3). Additive: every pre-existing row is
    `:manual` by default, history untouched.
  """

  use Ash.Type.Enum, values: [:manual, :auto]
end
