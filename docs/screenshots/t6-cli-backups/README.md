Rendered CLI output for the backups + access write commands
(T6 of #362) — captured against a local dev server
(`PORT=4100 mix phx.server`, seeded dev DB) with a real operator PAT
(scopes: instances:read, backups:read, backups:write, gateways:read,
gateways:write), minted and revoked through the smoke README's
operator shape. The token never appears in CLI output (the redacted
Token newtype); the example S3 access key id is masked to
AKIA****EXAMPLE; no credential is committed here.

What dev gave:
- `backups_status_not_configured.txt` — the 404 shape on the settings
  read, plus the empty history, exit 0.
- `backups_status_foreign_instance.txt` — the instance read 404s a
  foreign id (the runs index would filter, not 404 — the instance
  read is what names it).
- `backups_configure.txt` — the create arm (GET 404 → POST), the saved
  row echoed back.
- `backups_status_configured.txt` / `backups_status_json.txt` — the
  settings row; no runs yet.
- `backups_run_refusal.txt` — the honest guard: "backups are not
  configured for this instance", the operation's own words on a 400.
- `backups_run_dev.txt` — the configured instance on a dev box with no
  cluster: the POST rode the wire, the server answered its sanitized
  500 with an error id. Server-side truth surfaced verbatim.
- `backups_restore_no_confirm.txt` — the confirm gate: the overwrite
  warning, the exact re-run command, exit 1. NO request was sent
  (the CLI's zero-request guarantee).
- `no_token.txt` — the friendly sign-in line still guards a write
  command.
- `access_status_no_gateway.txt` — the org's gateway 404 reads as the
  plain "no gateway" line.

Access attach/detach/resume are wire-tested against mock servers in
the Rust suite (apps/cli/fluxvale-cli/src/writes.rs); dev has no gateway to
exercise them against.
