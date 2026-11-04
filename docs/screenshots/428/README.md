Rendered CLI output for the read commands (PR #428, T4 of #362) —
captured against a local dev server (`mix phx.server`, seeded dev DB)
with a real PAT (scopes: catalog:read, instances:read, wallet:read),
minted and revoked through the smoke README's operator shape. The
token never appears in CLI output (the redacted Token newtype); no
credential is committed here.
