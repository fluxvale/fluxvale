# Runbook: the Google OAuth client for Sign in with Google (#642)

**Internal, owner-only.** The Google sign-in arm needs one OAuth
client in Google Cloud Console, created and held by Terence. The
Google-console half is manual by design — the credentials are
owner-held ([ADR-0021](../adr/00021-secrets-bws-operator.md) posture);
the flag flip at the end is a platform-admin step in the app. The
platform ships with the arm dark (`:google_sign_in` flag unseeded,
credentials absent) until this runbook is walked.

## Once: create the OAuth client

1. <https://console.cloud.google.com> → pick or create the project
   (a dedicated `fluxvale` project is cleaner than sharing one).
2. **Google Auth Platform** (the current console's name for the old
   "OAuth consent screen", under APIs & Services or its own entry):
   - **Branding**: app name FluxVale, support email, and the app's
     home page. Set the **privacy policy link** to
     `https://fluxvale.com/policies/privacy` — required for an
     external app, and the reason that page exists.
   - **Audience**: External.
   - **Authorized domains**: add `fluxvale.com` (covers prod and
     staging subdomains — Google requires the top private domain
     before redirect URIs are accepted).
   - **Data access / scopes**: add only `openid` and `email`
     (`.../auth/userinfo.email`) — the arm requests `openid email`
     and nothing else ([plan](../plans/642-google-sign-in.md)
     D-scopes); profile scopes would widen what Google sends. No
     sensitive scopes, so no extended verification.
   - **Test users** (while in Testing mode): add the owner's Google
     account, or the verify step below will hit the warning wall.
3. **Clients → Create client**, type *Web application*:
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

Env is sampled at boot, so a restart of the platform pod applies a
credential change.

Then turn the arm on: in the app's admin surface, create the
feature flag with key `google_sign_in`, enabled. The button renders
only when the flag is on AND both credentials are present, so a
half-configured environment stays dark rather than broken.

Verify: sign-in page shows **Sign in with Google**; a full round
trip lands in the app; the telemetry counter
`flux_vale_identity_google_sign_in_count` moves with outcome tag
`ok` (the operation's success atom — not `success`).

## Launch-day checklist item

While the consent screen is in **Testing**, Google caps users at 100
test users and shows a warning screen. Before public launch: push
the consent screen to **In production**. With only `openid`/`email`
(not sensitive), Google accepts it without the extended verification
process.

## Rotation and revocation

- **Rotate**: Google Auth Platform → the client → add a second
  client secret, swap the BWS value, restart the platform pod,
  remove the old secret. The brief window where either secret works
  is by design.
- **Kill switch**: flip the `google_sign_in` flag off — the button
  disappears and email codes are unaffected (plan §5: the fallback
  never degrades). Deleting the Google-side client alone is NOT a
  clean kill: the app still holds the credentials in env, so the
  button stays visible and every attempt fails with the "use an
  email code" copy until the flag is flipped or the env is cleared.
