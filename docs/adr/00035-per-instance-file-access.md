# ADR-0035: Per-instance file access — WebDAV sidecar (rclone) + per-instance generated credential

**Status**: Accepted
**Date**: 2026-10-21
**Issue**: #190 (design settled there Oct 21; this ADR owns the sidecar
pick and the credential model)

## Context

File-based catalog apps (Kavita: ebooks/comics/audiobooks, #189) are
useless without bulk ingest ([open-questions.md](../open-questions.md)
OQ #3/#6; v1's SFTP gateway was a launch-gate item and churn source).
Users need to push gigabytes of library files into an instance's data
volume — from CI, from a NAS, unattended. The settled shape (#190):
a per-app catalog toggle `file_access` → a sidecar in the instance pod
sharing the app's data volume, serving WebDAV on the instance hostname
(`<slug>.<domain>/dav` via Traefik — rides the proxied wildcard, no DNS
changes). Two decisions this ADR owns: the sidecar implementation, and
the credential model.

**Hard constraint**: Cloudflare caps proxied request bodies at 100 MB
(free plan), and rclone uploads WebDAV PUTs whole files. Phase 1
(small/medium files — epubs, PDFs, most comics) goes through the
sidecar; phase 2 (large files — m4b audiobooks, comic packs) is
presigned R2 uploads that bypass the zone proxy entirely, a separate
PR. Phase 1 must not block that path.

## Decision

### 1. Sidecar: `rclone serve webdav` (rejected: SFTPGo)

One platform-owned container in the instance's Deployment (`Deployment`
builder's `sidecar` spec, #190):

```
rclone serve webdav /data --addr 0.0.0.0:8080 --baseurl /dav
# auth via env: RCLONE_USER / RCLONE_PASS (from the file-access Secret)
```

- **Image**: `rclone/rclone:1.75.2`, pinned in config (`:file_access`) —
  a deliberate bump, like every supply-chain pin.
- **Routing**: own Service `dav` + IngressRoute `app-dav` matching
  `Host(<slug>.<domain>) && PathPrefix(/dav)` — Traefik auto-prioritizes
  the longer match above the app's bare Host rule; the app's
  Service/IngressRoute stay untouched. rclone's `--baseurl /dav` makes
  the sidecar itself prefix-aware — no StripPrefix middleware.
- **Resources**: 0.05 CPU / 64 MB requests (limits 2x, the builders'
  convention). Platform overhead, not purchased allocation: the
  namespace ResourceQuota widens by exactly the sidecar's requests, so
  the app pod's share stays what the user chose.
- **Probes**: none — pod readiness is the app container's contract (the
  reconciler's semantics are unchanged; a crashed sidecar degrades file
  access, not the app's status).
- **Gate**: the sidecar lands only when the Instance snapshots
  `file_access` AND allocated storage > 0 — a toggle without a volume
  has nothing to serve.
- **Serves the app's own mount path** (#189 × #190): the rclone root is
  the Instance's `storage_mount_path` snapshot — `/kavita/config` for
  Kavita, whose libraries live in subdirs of the same volume, so the
  mount root exposes the whole volume, not just the config dir.

Why rclone over **SFTPGo** (the purpose-built per-user gateway):

- rclone is one static container, zero bootstrap — SFTPGo needs user
  provisioning (REST/CLI/init) before it serves anything: an init
  container or SFTPGO_INITD loop, more moving parts per instance.
- The per-user machinery SFTPGo adds (multi-user, per-user quotas,
  audit log, admin UI) is platform-side concern in FluxVale's model:
  one credential per instance (below), quota = the namespace
  ResourceQuota, audit = future platform access logs. We'd run a
  user-database to hold exactly one user.
- SFTPGo's flagship protocol (SFTP) is unusable behind the HTTP edge
  proxy anyway (#190's constraint) — we'd use only its WebDAV +
  HTTP file manager, which overlaps rclone's WebDAV + web UI.
- rclone's VFS over a local directory is battle-tested at exactly this
  shape (serve a local path over WebDAV); its flags are env-var
  addressable (`RCLONE_USER`/`RCLONE_PASS`), so the credential rides a
  K8s Secret via `envFrom` — no shell wrapper, no command-line password
  exposure.

Rejected-with-SFTPGo tradeoff to keep in view: if instances ever need
**per-human attribution** of file operations (shared-org instances,
audit requirements), SFTPGo's user model is the natural upgrade — the
sidecar swap is contained in DeployInstance + the credential reveal.

### 2. Credential model: per-instance generated credential (rejected: platform-session token at the sidecar)

The platform generates a random credential at deploy
(`RCLONE_USER` = fixed `fluxvale`, `RCLONE_PASS` = 32 bytes CSPRNG,
URL-safe base64) and stores it **only** as the `file-access` Secret in
the instance namespace — get-or-created across deploy retries (a retry
never rotates a credential the owner already configured rclone with).
The instance page reveals it on demand (a live Secret read); teardown
deletes it with the namespace.

Why over a **platform-session token accepted by the sidecar**:

- **No auth bridge to build or expose.** rclone has no external-auth
  hook; validating a platform token would need an auth proxy in front
  of every sidecar or SFTPGo's external-auth callback into a new public
  platform endpoint — a fresh security surface per instance for zero
  product value.
- **No coupling of the data path to platform availability.** With a
  generated credential the sidecar is self-contained; with token
  validation every WebDAV request (a PROPFIND per directory listing)
  depends on the platform API being up.
- **rclone speaks Basic auth, and so do our users.** The WebDAV client
  story is `rclone copy` with a username/password in `rclone config`.
  A platform session token would ride the same Basic-auth password
  field anyway — without gaining its bearer semantics.
- **Sessions expire; libraries don't.** Unattended sync jobs (cron,
  NAS) want long-lived credentials. Session tokens are short-lived by
  design and die on "sign out everywhere".
- **Blast radius.** A leaked per-instance credential reaches exactly
  one instance's volume. A leaked session token is a full account
  credential — every org instance, billing, email.

Tradeoffs accepted: no per-human attribution inside an org (org-level
trust — the same people can already delete the instance; revisit with
SFTPGo if audit needs arrive); the credential is visible to org members
via reveal and to the platform SA (already true for `app-env`); rotation
is phase-2 UX (regenerate + rolling restart — the mechanism is just a
Secret write + `Deployment.restart`, nothing in this design resists it).

**Storage: the namespace Secret, not BWS** (ADR-0021). Instance
credentials are ephemeral, platform-generated runtime state — exactly
the `app-env` Secret's shape — not fleet-repo declarative secrets. BWS
sync would need write-scoped machine accounts (against
[ADR-0021](00021-secrets-bws-operator.md) Am. 2's read-scoped stance),
per-instance BitwardenSecret lifecycle churn on every deploy/teardown,
and buys nothing: the Secret dies with its namespace, and the platform
DB never stores the credential at all. Revisit trigger: credentials
that must outlive namespaces (stable-across-migration, centralized
rotation audit).

### Phase 2 framing (presigned R2 — separate PR, not blocked)

Nothing in phase 1 hardcodes WebDAV as the only ingest: the credential
is instance-scoped and platform-verifiable-by-possession (the reveal
proves it), the `/dav` route is additive, and the sidecar is one
container. Phase 2's natural shape: a platform endpoint that
authenticates the instance owner, presigns R2 PUTs (no proxy cap), and
an in-cluster puller/sync into the volume (the sidecar image already
speaks both ends — `rclone copy` R2→local is the puller). The 100 MB
cap is documented in the instance page's panel copy; files above it
fail fast at upload with rclone's clear error until phase 2 lands.

## Consequences

- `App.file_access` (catalog-declared) → `Instance.file_access`
  (snapshot at create, `DeriveFromAppVersion`) — catalog edits never
  re-spec running instances; the sidecar lands on their next deploy.
- DeployInstance applies 3 more resources per file-access instance
  (Secret, Service, IngressRoute) and widens the quota by the sidecar's
  requests; teardown deletes them tolerantly (`:not_found` = success —
  pre-#190 namespaces never had them).
- **Kavita ships with `file_access: true`** (#189 seeded it; the first
  customer is the owner's ebook/comic library). Forgejo ships without:
  raw WebDAV into a git forge's data dir is a footgun, not a feature —
  the toggle stays a deliberate per-app catalog decision.
- OQ #6 (SFTP/file access) is resolved by this ADR: WebDAV now, SFTP
  stays deferred (the proxy constraint is protocol-level), large files
  ride phase 2's R2 path.

## Amendment 1 (2026-10-21): the credential must survive the human path — `--obscure` is not cosmetic

The panel's first dogfood (#194, the same day the ADR landed) failed to
authenticate. Neither the credential nor the sidecar was at fault: the
reveal path, the Secret's literal values, and the proxied Basic-auth
chain all check out (207 with the exact values, 401 without). Two
avoidable client-side traps did the damage.

**1. rclone's obscured-password guess.** `rclone config create … pass
<value>` heuristically decides whether the value is already obscured.
The generated password — 32 random bytes, URL-safe base64, no padding,
43 chars — is misread as obscured in ~99% of samples (200-sample check),
so rclone kept the literal and then *decrypted* it, putting garbage on
the wire. The zero-config `rclone obscure` form never had the bug: it
pre-obscures. Fix: the panel's snippet passes `--obscure`, forcing the
plaintext reading. Verified against the pinned `rclone/rclone:1.75.2` —
the literal form 401s, the `--obscure` form authenticates.

**2. Hand-selection of a wrapped secret.** The 43-char password rendered
as ordinary wrapped body text with no copy affordance, so a triple-click
selected the neighbouring "Password" label plus a trailing newline
(53 chars) — a paste that 401s. Fix: every credential value gets a copy
button carrying the exact rendered string in a `data-` attribute, and
the password renders no-wrap.

The lesson generalizes past this ADR: a credential's *representation on
the page* is part of its contract, and the E2E must exercise the copy
path a human actually takes rather than consuming the Secret directly.
The file-access E2E now asserts each copy button's carried value, drives
a real clipboard write, and runs the snippet's own config line against
the live endpoint.

## Connecting (client quick-starts, #227)

The endpoint is WebDAV, not a website: browsers send GET, collections
answer PROPFIND — so opening the address in a browser returns 405
"Method not allowed" even with valid credentials. Correct behavior; use
a client. The instance page's panel says the same in one line.

**Cyberduck** (macOS/Windows, free) — the recommended client for
browsing and drag-drop. Open Connection → pick **WebDAV (HTTPS)** →
server = the panel's Address, username = `fluxvale`, password = the
revealed password.

**rclone** — mounting as a drive and scripted sync. The panel's snippet
is the whole setup (`--obscure` is load-bearing, Amendment 1):

```
rclone config create fluxvale-<slug> webdav \
    url https://<slug>.fluxvale.app/dav vendor rclone user fluxvale pass '<password>' --obscure
rclone copy ~/library fluxvale-<slug>:library --progress
```

Alternates, known to work but not recommended: RaiDrive and WinSCP on
Windows. Mobile WebDAV apps: none vetted yet — a future note.

## Amendment 2 — copy-paste-safe quick-start (2026-10-24)

Live dogfooding caught the original rclone example failing verbatim:
its source path was a placeholder, so `rclone copy` died on
"directory not found" before ever touching the network. Any user
would hit the same. The quick-start, as amended:

```
mkdir -p ~/Books   # your local source — create it before copying
rclone config create fluxvale-<slug> webdav \
    url https://<slug>.fluxvale.app/dav vendor rclone user fluxvale pass '<password>' --obscure
rclone lsd fluxvale-<slug>:   # verify: lists the instance's root dirs (auth + URL proven)
rclone copy ~/Books fluxvale-<slug>:library/books --progress
```

Keeping it updated: `rclone copy` is incremental and never deletes —
re-run it after adding or changing files locally; new or changed files
upload. A strict mirror (local deletions removed remotely) is
`rclone sync`; it deletes by design, so `--dry-run` it first. After
uploading, the app must be told about the files: register the folder
in the app's settings and trigger a scan (e.g. Kavita: Settings →
Libraries → add the path, then Scan) — the file layer and the app's
index are separate by design.

