defmodule FluxVale.OAuth do
  @moduledoc """
  The MCP OAuth 2.1 authorization server (#766): dynamic client
  registration, the authorization-code + PKCE flow, rotating refresh
  tokens, RFC 7009 revocation, and the OAuth audit trail.

  The token rows themselves stay in `FluxVale.Identity` — an OAuth
  access token is a short-lived scoped `personal_access_tokens` row
  (`fvoat_`), and a refresh token is the same table with the refresh
  kind (`fvort_`). Scope enforcement, revocation, `last_used_at`, the
  API audit, and rate limiting therefore apply unchanged.

  The platform is the authorization server; `apps/mcp` is the resource
  server. There is no OpenID Connect, no third-party federation, and no
  per-organization consent — tokens are user-scoped like PATs.
  """

  use Ash.Domain, otp_app: :flux_vale

  resources do
    resource(FluxVale.OAuth.AuditEvent)
    resource(FluxVale.OAuth.AuthorizationCode)
    resource(FluxVale.OAuth.Client)
  end

  # Client registration (RFC 7591) — unauthenticated by design; the
  # endpoint owns the rate limit, this owns the metadata rules.
  defdelegate register_client(params, opts \\ []),
    to: FluxVale.OAuth.Operations.RegisterClient,
    as: :call

  # The authorization request's validation: client, exact redirect,
  # S256 PKCE, scopes, resource (missing resource defaults).
  defdelegate validate_authorize_request(params),
    to: FluxVale.OAuth.Operations.ValidateAuthorizeRequest,
    as: :call

  # Consent approval → one 60-second, single-use code.
  defdelegate issue_authorization_code(request, opts \\ []),
    to: FluxVale.OAuth.Operations.IssueAuthorizationCode,
    as: :call

  # The token endpoint's two grants.
  defdelegate exchange_code(params),
    to: FluxVale.OAuth.Operations.ExchangeCode,
    as: :call

  defdelegate refresh_token(params),
    to: FluxVale.OAuth.Operations.RefreshToken,
    as: :call

  # RFC 7009 + the settings page's Disconnect.
  defdelegate revoke_token(params),
    to: FluxVale.OAuth.Operations.RevokeToken,
    as: :call

  defdelegate revoke_connection(actor, family_id, opts \\ []),
    to: FluxVale.OAuth.Operations.RevokeConnection,
    as: :call

  # The guarded audit append — the AS's one audit write seam.
  defdelegate record_audit_event(attrs),
    to: FluxVale.OAuth.Operations.RecordAuditEvent,
    as: :call

  # Janitor feeds.
  defdelegate prune_codes(opts \\ []),
    to: FluxVale.OAuth.Operations.PruneCodes,
    as: :call

  defdelegate prune_audit_events(opts \\ []),
    to: FluxVale.OAuth.Operations.PruneAuditEvents,
    as: :call
end
