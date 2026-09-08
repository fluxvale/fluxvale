defmodule FluxVale.Identity do
  @moduledoc """
  Identity: users, platform roles, and the revocable token store.

  Passwordless email-code sign-in (#21) and PATs (#23 — mint via the
  `User` code interface, prune via `prune_expired_tokens/1`) build on this
  domain. Deliberately **not** exposed through AshAdmin — User/Token are
  sensitive resources (ADR-0027 §3).
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshJsonApi.Domain]

  resources do
    resource FluxVale.Identity.AuthCode
    resource FluxVale.Identity.Token
    resource FluxVale.Identity.User
  end

  # Operations are verb-named modules under operations/ (see
  # apps/platform/AGENTS.md); the domain stays the public seam
  defdelegate request_auth_code(email, deliver \\ &FluxVale.Mailer.deliver_auth_code/2),
    to: FluxVale.Identity.Operations.RequestAuthCode,
    as: :call

  defdelegate verify_auth_code(email, code),
    to: FluxVale.Identity.Operations.VerifyAuthCode,
    as: :call

  defdelegate prune_expired_tokens(opts \\ []),
    to: FluxVale.Identity.Operations.PruneExpiredTokens,
    as: :call
end
