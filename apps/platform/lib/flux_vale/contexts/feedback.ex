defmodule FluxVale.Feedback do
  @moduledoc """
  Feedback: the public feature-request board (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)). Reads are
  public (the board is a public surface). Posts and votes run the paying
  gate (ADR-0026 §2/§3 — the org's owner past the paid gate, the
  launch-allowlist cohort, or a platform admin,
  `FluxVale.Checks.ActorOwnsPaidOrg`); comments follow the owner's Nov
  ruling for comments specifically — any authenticated user may comment,
  membership and paying status irrelevant. Content edits and moderation
  stay platform-admin-only.
  """

  # AshAdmin exposure (ADR-0027 §3, opt-in): moderation day one rides the
  # generated admin surface (ADR-0026 Am. 1) — the domain's own policies
  # (public reads; posts/votes behind the paying gate; comments open to
  # any authenticated user; moderation admin-only) are what the mount
  # runs under, so no new auth model.
  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Feedback.Post)
    resource(FluxVale.Feedback.Vote)
    resource(FluxVale.Feedback.Comment)
    # The curated topical vocabulary + its join (T10): both ride the
    # domain's own policies — public reads, admin-only writes.
    resource(FluxVale.Feedback.Tag)
    resource(FluxVale.Feedback.PostTag)
  end

  # Operations are verb-named modules under operations/ (see
  # apps/platform/AGENTS.md); the domain stays the public seam.
  defdelegate similar_posts(title, opts \\ []),
    to: FluxVale.Feedback.Operations.SimilarPosts,
    as: :call
end
