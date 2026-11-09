# Runbook: the Google OAuth client for Sign in with Google (#642)

**Internal, owner-only.** The Google sign-in arm needs one OAuth
client in Google Cloud Console, created and held by Terence — the
platform code ships with the arm dark (`:google_sign_in` flag
unseeded, credentials absent) until this runbook is walked. Nothing
below is automatable from the repo: the credentials are owner-held
by design ([ADR-0021](../adr/00021-secrets-bws-operator.md) posture).

## Once: create the OAuth client

1. <https://console.cloud.google.com> → pick or create the project
   (a dedicated `fluxvale` project is cleaner than sharing one).
2. **APIs & Services → OAuth consent screen**: External; app name
   FluxVale; support email; developer contact. Scopes: **add only
   `openid` and `email`** (`.../auth/userinfo.email`) — the arm
   requests `openid email` and nothing else ([plan](../plans/642-google-sign-in.md)
   D-scopes); adding profile scopes would widen what Google sends.
   No sensitive scopes, no verification flow needed.
3. **APIs & Services → Credentials → Create credentials → OAuth
   client ID**, type *Web application*:
   - Authorized redirect URI (prod): `https://fluxvale.com/auth/google/callback`
   - Authorized redirect URI (staging): `https://staging.fluxvale.com/auth/google/callback`
   - The path is fixed by the code; only hosts differ per
     environment.
4. Copy the **client ID** and **client secret**.

## Per environment: land the credentials

Stage the two values as env for the platform deployment through BWS
(the same path as Postmark/HitPay/Polar secrets), under:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- (`GOOGLE_OIDC_ISSUER` stays unset — the default
  `https://accounts.google.com` is correct for every real
  environment.)

Then flip the feature flag: the platform admin surface seeds the
`:google_sign_in` FeatureFlag row. The button renders only when the
flag is on AND both credentials are present, so a half-configured
environment stays dark rather than broken.

Verify: sign-in page shows **Sign in with Google**; a full round
trip lands in the app; telemetry counter
`flux_vale_identity_google_sign_in_count` moves (outcome tag
`success`).

## Launch-day checklist item

While the consent screen is in **Testing**, Google caps users at 100
test users and shows a warning screen. Before public launch: push
the OAuth consent screen to **In production**. With only
`openid`/`email` (not sensitive), Google accepts it without the
extended verification process.

## Rotation and revocation

- **Rotate**: Credentials → the client → add a second client secret,
  swap the BWS value, restart, remove the old secret. Zero-downtime
  by construction (the two-hop flow reads env per request).
- **Kill switch**: delete the client (Google-side) or flip the
  `:google_sign_in` flag off — either way the button disappears and
  email codes are unaffected (plan §5: the fallback never degrades).
