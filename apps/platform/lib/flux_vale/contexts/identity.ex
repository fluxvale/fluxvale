defmodule FluxVale.Identity do
  @moduledoc """
  Identity: users, platform roles, personal access tokens, and the
  revocable token store.

  Passwordless email-code sign-in (#21) and PATs (#360 — mint via
  `mint_pat/3` with scopes, revoke via `revoke_pat/3`; the token
  store below backs sessions, `prune_expired_tokens/1` its janitor)
  build on this domain. Deliberately **not** exposed through AshAdmin
  — User/Token are sensitive resources (ADR-0027 §3).

  Invites (#502) are pre-provisioned Users: `invite_user/2` creates the
  inert account (or re-issues) and delivers a one-time accept link;
  `accept_invitation/1` verifies the address, runs the first-login
  bootstrap, and mints the session; `withdraw_invite/2` retires an
  unaccepted invite. The #478 invited-email gate on `verify_auth_code/2`
  narrows to its structural core: the team-domain JIT bypass only.
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

  # Invites (#502): inviting IS creating the User — a pre-provisioned
  # inert account plus a one-time accept link (the raw token exists
  # exactly once, in the {:ok, user, raw} return). See the ops for the
  # failure shapes.
  defdelegate invite_user(
                actor,
                address,
                deliver \\ &FluxVale.Mailer.deliver_user_invitation/2,
                opts \\ []
              ),
              to: FluxVale.Identity.Operations.InviteUser,
              as: :call

  defdelegate accept_invitation(raw_token),
    to: FluxVale.Identity.Operations.AcceptInvitation,
    as: :call

  defdelegate withdraw_invite(actor, user_or_id, opts \\ []),
    to: FluxVale.Identity.Operations.WithdrawInvite,
    as: :call

  # The signup counter's event name (#502): one semantic event, two fire
  # sites — the JIT signup (VerifyAuthCode) and the invite acceptance
  # (AcceptInvitation). A shared contract, not either operation's
  # constant; the listener is FluxValeWeb.Telemetry.
  @doc "The signup-success telemetry event — VerifyAuthCode and AcceptInvitation fire it"
  @spec signup_event() :: [atom(), ...]
  def signup_event, do: [:flux_vale, :identity, :signup]

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
