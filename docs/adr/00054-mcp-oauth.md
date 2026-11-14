# ADR-0054: MCP OAuth — the platform is the authorization server, the MCP server is the resource

**Status**: Accepted (#766)
**Date**: 2026-11-13

**Context**: The remote MCP server authenticated with a pasted personal
access token (`Authorization: Bearer fvpat_…`). That is a manual step
in the one flow that should have none, and the token ends up in the
agent's conversation and its committed-or-not config file. Hosted MCP
servers now ship OAuth 2.1 under the MCP authorization spec. The
clients that drive this surface (Claude, Cursor, opencode, rmcp-based
CLIs) already implement the discovery → registration → consent →
token dance; the platform was the missing authorization server.

The constraint that shaped everything below: existing PATs keep
working. OAuth is additive, not a migration.

## Decision

1. **The platform is the authorization server; `apps/mcp` is the
   resource server.** Discovery starts at the MCP host's
   `/.well-known/oauth-protected-resource` (RFC 9728): the resource
   identifier, the authorization server, the supported scopes, and
   `bearer_methods_supported: ["header"]`. A request without a usable
   bearer gets `401` with
   `WWW-Authenticate: Bearer resource_metadata="…", scope="…"`; a
   dead or revoked token adds `error="invalid_token"`. Browser MCP
   clients get CORS preflight answered before bearer auth, with the
   challenge header exposed. The platform serves RFC 8414 metadata at
   `/.well-known/oauth-authorization-server`: issuer, endpoints,
   `S256`, public clients, the scope catalog plus `offline_access`.

2. **Public clients only, registered dynamically.** RFC 7591
   registration mints `fvoc_` client ids. There is no client secret —
   every client here is a native app or CLI, and PKCE is the proof.
   Redirect URIs are HTTPS anywhere, HTTP on loopback only, or one of
   the known desktop custom schemes; fragments and userinfo are
   refused. The registration endpoint is unauthenticated by design,
   so it is per-IP rate-limited and capped globally per window. The
   requested grant set is validated then normalized to the two
   supported grants — both are always issued, so no restriction is
   stored that the token endpoint would ignore. The cap count and the
   insert share one transaction and advisory lock.

3. **Authorization code + mandatory PKCE (`S256`).** No implicit flow,
   no plain verifier. Redirect URIs match exactly against the
   registration. Codes live 60 seconds, are stored only as a SHA-256
   hash, and are consumed exactly once — the UPDATE pins
   `consumed_at IS NULL`, so two concurrent exchanges race and the
   loser gets `invalid_grant`. A cancelled consent returns
   `error=access_denied`; an unknown client or redirect is a local
   error page, never an open redirect.

4. **Consent is a signed, full-request binding.** The consent POST
   carries a short-lived `Phoenix.Token` binding the user, client,
   redirect URI, scopes, resource, PKCE challenge, and state. Form
   fields cannot alter the request, and the token cannot be replayed
   for a different one. The page shows the client name, the host it
   returns to, and every scope in product language; the copy states
   plainly that access spans all of the user's organizations and that
   disconnecting revokes immediately. The POST is rate-limited like
   the GET.

5. **OAuth tokens reuse the revocable-token machinery.** An access
   token is a short-lived scoped `personal_access_tokens` row
   (`fvoat_`, one hour); a refresh token is the same table with the
   refresh kind (`fvort_`, thirty days); both carry the client, the
   RFC 8707 resource, and a shared `token_family_id`. Scope
   enforcement, revocation, `last_used_at`, and the API audit trail
   therefore apply unchanged. Refresh always rotates and a reused
   refresh token severs the whole family. The prefix and the kind
   must agree at the bearer plug: a refresh token never
   authenticates an API call.

6. **Resource indicators are validated, with a compatibility
   default.** A present `resource` must match the configured MCP
   allowlist exactly; a mismatch is `invalid_target`. A request that
   omits it (older clients predate RFC 8707) binds the configured
   default and records `resource_defaulted` in the audit row. The
   deployed defaults derive from the environment: prod
   `https://mcp.fluxvale.com/mcp`, staging
   `https://mcp-staging.fluxvale.com/mcp`, local k3d
   `https://mcp.fluxvale.lvh.me/mcp`; `MCP_RESOURCE_URLS` overrides
   with a comma-separated list. A bare dev server accepts the
   loopback MCP resource.

7. **`offline_access` is an advertised no-op.** Refresh is always
   issued, so the scope is accepted and advertised, then stripped
   before anything is stored or granted. Unknown scopes and duplicates
   still return `invalid_scope`. The PAT mint catalog is unchanged.

8. **Rate limits key on the real client IP.** The unauthenticated
   endpoints (register, authorize GET/POST, token, revoke) use the
   existing trusted-proxy chain — `CF-Connecting-IP`, then the
   rightmost `X-Forwarded-For`, then `remote_ip`. Behind the deployed
   edge `remote_ip` is a proxy pod, so keying on it would put every
   client in one bucket. Exceeding a window answers `429` with
   `Retry-After`; the limiter fails open if its ETS owner is
   mid-restart — a throttle must never 500 the sign-in door.

9. **Revocation is immediate by construction.** RFC 7009 revoking
   either half of a pair severs the family; the settings page's
   Disconnect calls the same family revoke. The family revoke commits
   a `connection_revoked` tombstone in the same transaction, and the
   mint path takes the same family advisory lock and refuses a
   tombstoned family — a refresh already in flight cannot mint a pair
   that outlives the disconnect. The MCP server validates an OAuth
   access token against `GET /me` on every request (the body also
   carries the token's RFC 8707 resource, which the server compares to
   its own public URL) — that read is both the proof and the scope
   source for `tools/list` and the destructive pre-checks — so a
   revoked or wrong-audience token is refused on the next call with
   the 401 challenge. No token state is cached in the MCP process.

10. **No OpenID Connect, no third-party federation, no per-org
    consent.** The consent principal is the user, and a token is
    user-scoped like a PAT: it reaches every organization the user
    belongs to, and the consent copy says so. There is no `id_token`,
    no `openid` scope, no SSO binding, and no organization picker.
    The audit trail (client registration, consent decision, code
    issuance and reuse, token issuance/refresh, revocation,
    connection disconnect) is append-only and pruned on the same
    90-day horizon as the API audit.

## Rejected alternatives

- **A second token table for OAuth.** A parallel table would
  duplicate hashing, expiry, scope validation, `last_used_at`, the
  bearer lookup, the API audit, and revocation — and every fix would
  land twice. The `kind` column is the smaller seam; the existing
  PAT rows and the existing operations are untouched.
- **JWTs for access tokens.** Self-contained tokens would need a
  signing key, a JWKS endpoint, and clock-skew rules, and revocation
  would become a denylist with a propagation window. The opacity and
  immediate-revocation property of the database row is worth more
  here than stateless validation, especially for a server that already
  reads `/me` per request.
- **Introspection endpoint instead of `/me`.** RFC 7662 introspection
  is the standard RS check, but `/me` already answers the same
  question and carries the scope list `tools/list` needs; adding an
  introspection endpoint would be a second token-validating surface
  to keep consistent.
- **Mandatory `resource` (strict RFC 8707).** It would hard-fail
  every client that predates resource indicators for no security
  gain on a single-resource AS. Defaulting the audience and auditing
  the default keeps compatibility; a present value is still matched
  exactly.
- **Implicit flow / token in the redirect.** Deprecated by OAuth 2.1
  and unsafe for native clients; PKCE exists precisely to avoid it.
- **Client secrets.** Public clients cannot keep them; shipping a
  secret in a desktop app or CLI is a false boundary, and PKCE plus
  exact redirect matching is the actual proof.
- **OIDC / SSO federation.** The MCP surface needs authorization, not
  identity federation. Linking MCP consent to an external IdP is a
  product decision with its own trust and account-linking questions,
  not a prerequisite for agent access.
- **Per-organization consent.** It reads safer, but PATs are
  user-scoped today and the platform's authorization model is
  user-plus-membership; a per-org consent screen would imply an
  isolation the token does not have. If per-org tokens become a
  product requirement, that is a separate model change.
- **Persisting OAuth state in the MCP server.** A token cache or
  session store would make revocation eventual and the stateless
  deployment stateful. The per-request `/me` read is the price of
  immediate revocation, and it was already the scope read.
- **A client allowlist during the beta.** Registration is open by
  design (the MCP spec expects it); the per-IP window and the global
  per-window client cap bound abuse without a manual onboarding step.
  A reviewed-client registry is a later product decision if the cap
  proves insufficient.

## Consequences

- Deployment: the platform needs `MCP_RESOURCE_URLS` (or the derived
  default) per environment; the MCP server derives its public URL and
  authorization server from `MCP_ALLOWED_HOSTS`, with
  `MCP_PUBLIC_URL` / `MCP_AUTHORIZATION_SERVER` as explicit overrides.
  Staging is main-deploy-only, so the staging handshake is verified
  after the merge (#766's S6).
- The consent page is a new public, session-bearing surface; its
  signed-token binding and rate limit are the security boundary.
- The API audit and the OAuth audit are separate tables with the same
  retention posture; "what did this token do" still starts from the
  token row. Expired OAuth token rows stay as audit history (the PAT
  rows' posture); the Connected apps read hides expired families, and
  the janitor prunes short-lived codes and OAuth audit rows.
- Existing PAT documentation and client snippets remain valid; OAuth
  is the recommended path where the client supports it.
