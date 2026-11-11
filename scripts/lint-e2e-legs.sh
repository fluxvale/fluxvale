#!/usr/bin/env bash
# E2E leg coverage (#510 batch 3): every apps/e2e/tests/**/*.spec.ts
# must appear in some e2e matrix leg's specs list in ci.yml, and every
# leg entry must resolve to a file. The gap class is real twice over:
# pocket-id-lifecycle shipped legless through #492's PRs (joined via
# #523), and instance-resize shipped legless through #518 — in both
# cases PR CI stayed green while the spec went red only in nightlies.
# apps/e2e/README.md documents the rule; this makes it a gate so the
# README line can't rot.
#
# Scope note: membership only. The gate says every spec runs in SOME
# leg — it cannot say the leg is the right one (an instance-deploying
# spec appended to pages would pass here and burn the leg at deploy).
set -euo pipefail

cd "$(dirname "$0")/.."

workflow=".github/workflows/ci.yml"
specs_dir="apps/e2e/tests"

# Known, deliberate gaps — reason as comments, then the bare basename
# plus an owning issue reference on its own line (that line is the
# machine-read entry). Empty when nothing is parked. A gap is deleted,
# not extended; one that goes stale (the spec joined a leg, or the
# file is gone) fails this lint instead of rotting.
known_gaps="$(cat <<'GAPS'
GAPS
)"

gap_entries="$(printf '%s\n' "$known_gaps" | grep -v '^#' || true)"
gap_names="$(cut -d' ' -f1 <<<"$gap_entries")"

fail=0

# Leg entries: the specs tokens inside the e2e job's matrix only —
# both the flow shape (`specs: a b c`) and a block list
# (`specs:` then `- a` lines). Scoped so an unrelated job's
# same-named key can't manufacture a false pass.
e2e_block="$(awk '/^  e2e:$/ {on=1; next} /^  [a-z][a-z0-9-]*:$/ {on=0} on' "$workflow")"
legged="$(printf '%s\n' "$e2e_block" | grep -oE 'tests/[A-Za-z0-9_.-]+\.spec\.ts' | sort -u)"

if [[ -z "$legged" ]]; then
  echo "::error file=${workflow}::found no e2e leg spec entries — did the matrix shape change? (scripts/lint-e2e-legs.sh)"
  exit 1
fi

# 1. Every on-disk spec (any depth — the nightly's testMatch is
# **/*.spec.ts, so a nested spec runs nightly; it must be leggable)
# is in some leg or a declared gap.
while IFS= read -r spec; do
  name="$(basename "$spec")"
  rel="tests/${spec#"$specs_dir"/}"
  if grep -qxF "$rel" <<<"$legged"; then
    continue
  fi
  if grep -qxF "$name" <<<"$gap_names"; then
    echo "::notice file=${spec}::in no e2e leg, declared gap (see scripts/lint-e2e-legs.sh)"
    continue
  fi
  echo "::error file=${spec}::in no e2e leg — PR CI will never run it (apps/e2e/README.md); add it to a leg's specs list in ${workflow} or declare the gap in scripts/lint-e2e-legs.sh"
  fail=1
done < <(find "$specs_dir" -name '*.spec.ts' | sort)

# 2. Every leg entry resolves to a file (typo'd or moved entries
# silently stop running the spec they name).
while IFS= read -r entry; do
  if [[ -f "$specs_dir/$(basename "$entry")" ]]; then
    continue
  fi
  echo "::error file=${workflow}::leg lists ${entry} but no such spec exists"
  fail=1
done <<<"$legged"

# 3. Gap hygiene: a declared gap whose spec joined a leg (or no
# longer exists) has gone stale — delete the entry.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! [[ -f "$specs_dir/$name" ]]; then
    echo "::error file=scripts/lint-e2e-legs.sh::declared gap ${name} has no spec on disk — stale entry, delete it"
    fail=1
    continue
  fi
  if grep -qxF "tests/$name" <<<"$legged"; then
    echo "::error file=scripts/lint-e2e-legs.sh::declared gap ${name} is legged now — stale entry, delete it"
    fail=1
  fi
done <<<"$gap_names"

[[ "$fail" -eq 0 ]] || exit 1
echo "e2e leg coverage ok: every spec legged or a declared gap, every leg entry resolves, no stale gaps"
