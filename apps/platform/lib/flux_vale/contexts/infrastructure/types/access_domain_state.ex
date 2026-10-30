defmodule FluxVale.Infrastructure.Types.AccessDomainState do
  @moduledoc """
  An `AccessDomain`'s verification life (ADR-0040), driven by
  `Operations.VerifyAccessDomains` — the observer pass:

  - `:pending` — registered, the Certificate exists, Let's Encrypt has
    not (yet) confirmed the DNS-01 delegation. Issuance success IS the
    verification; the deadline (`issuance_deadline_hours`) fails the
    wait.
  - `:verified` — the Certificate's Ready condition is True. The ONLY
    state that may claim the domain works (verify-by-issuance: a row is
    never promoted by anything that has not read the cluster).
  - `:needs_attention` — observed: a verified Certificate's Ready went
    False (renewal trouble). Self-heals back to `:verified` when the
    observer sees True again — the gateway-observer stance.
  - `:failed` — the issuance window lapsed without a Ready Certificate.
    Terminal for this registration; the owner re-registers.
  - `:suspended` — no writer yet: S6's billing ladder owns the
    suspension (a lapsed custom domain). The `mark_suspended` funnel
    exists so the ladder lands through the same one-funnel-per-
    transition discipline as every other state.

  `:text`-stored like `AccessGatewayState`.
  """

  use Ash.Type.Enum, values: [:pending, :verified, :suspended, :failed, :needs_attention]
end
