#!/usr/bin/env bash
# ADR-index lint: every ADR carrying `## Amendment N` sections must have
# its docs/adr/README.md index row marked "(amended — see Amendment(s) N)"
# — the "update the index" half of the conventions (docs/adr/README.md);
# "Never edit history" is the other half. Born from the #36 review, where
# 9 of 14 amended ADRs turned out to be unmarked.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for adr in docs/adr/*.md; do
  name="$(basename "$adr")"
  grep -q '^## Amendment' "$adr" || continue
  row="$(grep -F "](${name})" docs/adr/README.md | head -n1 || true)"
  if [[ -z "$row" ]]; then
    echo "::error file=docs/adr/README.md::${name} has amendments but no index row"
    status=1
  elif ! grep -qi 'amended' <<<"$row"; then
    echo "::error file=docs/adr/README.md::${name} has amendments; index row not marked: ${row}"
    status=1
  fi
done

[[ $status -eq 0 ]] && echo "ADR index consistent"
exit $status
