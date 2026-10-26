#!/usr/bin/env bash
# ADR-index lint: every ADR carrying a NUMBERED amendment section must
# have its docs/adr/README.md index row marked
# "(amended — see Amendment(s) N)" — the "update the index" half of the
# conventions (docs/adr/README.md); "Never edit history" is the other
# half. Born from the #36 review, where 9 of 14 amended ADRs turned out
# to be unmarked.
#
# Detection is a NUMBERED amendment heading: `## Amendment <N>` — the
# documented `## Amendment N (YYYY-MM-DD)` form plus the `## Amendment N
# — title (date)` variant several ADRs actually use. A bare `##
# Amendment log` / `## Amendments` heading is not an amendment and must
# not demand an index marker: that over-match made a docs PR mark an
# unamended ADR "amended" to appease the linter (#269 review). An
# Amendment-ish heading with no number is surfaced as a warning rather
# than a failure, so a mistyped number can't hide silently.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

for adr in docs/adr/*.md; do
  name="$(basename "$adr")"

  # A numbered amendment, in either heading form the ADRs use.
  numbered="$(grep -cE '^## Amendment [0-9]+' "$adr" || true)"

  # Any Amendment-ish heading WITHOUT a number: not an amendment, but
  # suspicious enough to warn about (a mistyped number would otherwise
  # pass green).
  stray="$(grep -E '^## Amendment' "$adr" | grep -vE '^## Amendment [0-9]+' || true)"
  if [[ -n "$stray" ]]; then
    echo "::warning file=${adr}::heading does not match '## Amendment N (YYYY-MM-DD)' — not treated as an amendment: ${stray}"
  fi

  [[ "$numbered" -gt 0 ]] || continue

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
