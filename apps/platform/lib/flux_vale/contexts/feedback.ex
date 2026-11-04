defmodule FluxVale.Feedback do
  @moduledoc """
  Feedback: the public feature-request board (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)). Posts and
  votes are publicly readable (the board is a public surface); writes run
  the paying gate (ADR-0026 §2/§3) — the org's owner past the paid gate,
  the launch-allowlist cohort, or a platform admin
  (`FluxVale.Checks.ActorOwnsPaidOrg`). Content edits and moderation stay
  platform-admin-only.
  """

  # AshAdmin exposure (ADR-0027 §3, opt-in): moderation day one rides the
  # generated admin surface (ADR-0026 Am. 1) — the domain's own policies
  # (public reads, the paying gate on writes) are what the mount runs
  # under, so no new auth model.
  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Feedback.Post)
    resource(FluxVale.Feedback.Vote)
  end
end
