defmodule FluxVale.Infrastructure.Types.AccessGatewayState do
  @moduledoc """
  An `AccessGateway`'s life (ADR-0039 §2), deliberately small:

  - `:provisioning` — row written, cluster objects landing. The settle
    trigger does not run yet (nothing to bill until it is up).
  - `:active` — the pod exists and is expected to be on the tailnet.
    Accrues its rate (`AccessGateway.PerformSettle`).
  - `:needs_attention` — **observed**: the pod is not running or not on
    the tailnet (bad/expired key, node deleted in the console). Accrual
    **stops** (the owner is not getting reachability) but the row is not
    destroyed: re-pasting a key or redeploying re-enters `:active`.
  - `:suspended` — platform action, not failure: the zero-balance
    ladder scaled it to 0 (#268's must-fix). Accrues nothing; the
    owner's resume (funded wallet) returns it to `:active`.
  - `:destroying` — opt-out in flight.

  `:needs_attention` vs `:suspended` is the difference between "the
  owner must fix something" and "the wallet must be funded" — the panel
  renders different copy and different buttons for each, so they cannot
  share an atom. `:text`-stored like `InstanceStatus`.
  """

  use Ash.Type.Enum, values: [:provisioning, :active, :needs_attention, :suspended, :destroying]
end
