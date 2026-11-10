#!/usr/bin/env bash
# E2E leg coverage (#510 batch 3): every apps/e2e/tests/*.spec.ts must
# appear in some e2e matrix leg's specs list in ci.yml, and every leg
# entry must resolve to a file. The gap class is real twice over:
# pocket-id-lifecycle shipped legless through #492's PRs (joined via
# #523), and instance-resize shipped legless through #518 — in both
# cases PR CI stayed green while the spec went red only in nightlies.
# apps/e2e/README.md documents the rule; this makes it a gate so the
# README line can't rot.
set -euo pipefail

cd "$(dirname "$0")/.."

workflow=".github/workflows/ci.yml"
specs_dir="apps/e2e/tests"

# Known, deliberate gaps — reason lines as comments, then the bare
# basename on its own line (that line is the machine-read entry).
# Empty when nothing is parked. A gap entry without a live reason
# gets deleted, not extended.
known_gaps="$(cat <<'GAPS'
# instance-resize.spec.ts joins a leg together with the fix it needs
# first: chronically red since #518 (storage-probe 403 on k3d — the
# local platform role lacks the storageclasses grant, so the panel
# shows the probe-error copy the spec doesn't assert). #510 tracks
# the decision.
instance-resize.spec.ts
GAPS
)"

gap_names="$(printf '%s\n' "$known_gaps" | grep -v '^#' || true)"

fail=0

# Leg entries: every tests/*.spec.ts token on a `specs:` line.
legged="$(grep -E '^\s+specs:' "$workflow" | grep -oE 'tests/[a-z0-9-]+\.spec\.ts' | sort -u)"

# 1. Every on-disk spec is in some leg (or a declared gap).
while IFS= read -r spec; do
  name="$(basename "$spec")"
  if grep -qxF "tests/$name" <<<"$legged"; then
    continue
  fi
  if grep -qxF "$name" <<<"$gap_names"; then
    echo "::notice file=${spec}::in no e2e leg, declared gap (see scripts/lint-e2e-legs.sh)"
    continue
  fi
  echo "::error file=${spec}::in no e2e leg — PR CI will never run it (apps/e2e/README.md); add it to a leg's specs list in ${workflow} or declare the gap in scripts/lint-e2e-legs.sh"
  fail=1
done < <(find "$specs_dir" -maxdepth 1 -name '*.spec.ts' | sort)

# 2. Every leg entry resolves to a file (typo'd or moved entries
# silently stop running the spec they name).
while IFS= read -r entry; do
  if [[ -f "$specs_dir/$(basename "$entry")" ]]; then
    continue
  fi
  echo "::error file=${workflow}::leg lists ${entry} but no such spec exists"
  fail=1
done <<<"$legged"

[[ "$fail" -eq 0 ]] || exit 1
echo "e2e leg coverage ok: every spec legged or a declared gap, every leg entry resolves"
