defmodule FluxVale.Feedback do
  @moduledoc """
  Feedback: the public feature-request board (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)). Posts are
  publicly readable (the board is a public surface); writes are
  platform-admin-only this slice — the paying-customer gate is slice 2,
  not built here.
  """

  # AshAdmin exposure (ADR-0027 §3, opt-in): moderation day one rides the
  # generated admin surface (ADR-0026 Am. 1) — the domain's own policies
  # (public reads, admin writes) are what the mount runs under, so no new
  # auth model.
  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Feedback.Post)
  end
end
