defmodule FluxVale.Identity do
  @moduledoc """
  Identity: users, platform roles, personal access tokens, and the
  revocable token store.

  Passwordless email-code sign-in (#21) and PATs (#360 — mint via
  `mint_pat/3` with scopes, revoke via `revoke_pat/3`; the token
  store below backs sessions, `prune_expired_tokens/1` its janitor)
  build on this domain. Deliberately **not** exposed through AshAdmin
  — User/Token are sensitive resources (ADR-0027 §3).

  Since #478, `verify_auth_code/2` carries the invitation gate: JIT
  provisioning needs `@fluxvale.com` or a recorded invitation (the
  list itself is operator data, `FluxVale.Ops.InvitedEmail` in
  AshAdmin).
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshJsonApi.Domain]

  resources do
    resource(FluxVale.Identity.AuthCode)
    resource(FluxVale.Identity.DeviceCode)
    resource(FluxVale.Identity.PersonalAccessToken)
    resource(FluxVale.Identity.Token)
    resource(FluxVale.Identity.User)
    resource(FluxVale.Identity.UserEmail)
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

  # Email management (#285 T3): the actor's own addresses. See the ops
  # for the failure shapes.
  defdelegate add_email(actor, address), to: FluxVale.Identity.Operations.AddEmail, as: :call

  defdelegate verify_email(actor, email_row_id, code),
    to: FluxVale.Identity.Operations.VerifyEmail,
    as: :call

  defdelegate set_primary_email(actor, email_row_id),
    to: FluxVale.Identity.Operations.SetPrimaryEmail,
    as: :call

  defdelegate remove_email(actor, email_row_id),
    to: FluxVale.Identity.Operations.RemoveEmail,
    as: :call

  # PATs (#360): scoped opaque tokens for the machine API. The mint
  # operation returns the raw value exactly once; see the op for the
  # failure shapes.
  defdelegate mint_pat(actor, params, opts \\ []),
    to: FluxVale.Identity.Operations.MintPat,
    as: :call

  defdelegate revoke_pat(actor, pat_or_id, opts \\ []),
    to: FluxVale.Identity.Operations.RevokePat,
    as: :call

  # Device flow (#362 T3, RFC 8628): mint the sign-in request, run the
  # poll machine (see PollDeviceCode for the answer order), sweep dead
  # rows. Unauthenticated endpoints are the callers — the device_code
  # is the credential.
  defdelegate mint_device_code(params, opts \\ []),
    to: FluxVale.Identity.Operations.MintDeviceCode,
    as: :call

  defdelegate poll_device_code(client_id, device_code, opts \\ []),
    to: FluxVale.Identity.Operations.PollDeviceCode,
    as: :call

  defdelegate prune_device_codes(opts \\ []),
    to: FluxVale.Identity.Operations.PruneDeviceCodes,
    as: :call
end
