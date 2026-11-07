#!/usr/bin/env bash
# Pins the smoke verdict classifier and its wiring in ci.yml (#556).
#
# Acceptance: a flaky failure that passes the retry opens no revert and
# does not fail the run. A genuine failure that fails twice still
# reverts and fails. Confirmed (both attempts red) is therefore the
# only revert trigger, and the revert step in ci.yml must gate on the
# classifier's verdict, never on a raw single-attempt outcome.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/smoke-verdict.sh"
repo_root="$(dirname "$here")"
workflow="$repo_root/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0

run_verdict() {
  : >"$tmp/out"
  : >"$tmp/summary"
  GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" "$script"
  verdict="$(sed -n 's/^verdict=//p' "$tmp/out")"
  confirmed="$(sed -n 's/^confirmed=//p' "$tmp/out")"
  recovered="$(sed -n 's/^recovered=//p' "$tmp/out")"
}

expect_eq() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (want $2, got $3)"
    failures=$((failures + 1))
  fi
}

expect_contains() {
  if [[ "$3" == *"$2"* ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (missing $2 in: $3)"
    failures=$((failures + 1))
  fi
}

expect_not_contains() {
  if [[ "$3" != *"$2"* ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (unwanted $2 in: $3)"
    failures=$((failures + 1))
  fi
}

S1=success; S2=skipped   # pass leg (retry skipped behind a green attempt)
F1=failure; F2=failure   # confirmed leg
R1=failure; R2=success   # recovered leg

# Acceptance path 1: every flake shape (first red, retry green)
OUTCOME_BRUNO_STAGING_1=$R1 OUTCOME_BRUNO_STAGING_2=$R2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "staging bruno recovered: verdict" "recovered" "$verdict"
expect_eq "staging bruno recovered: no confirmed" "" "$confirmed"
expect_contains "staging bruno recovered: label" "staging(bruno)" "$recovered"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$R1 OUTCOME_PW_STAGING_2=$R2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "staging playwright recovered: verdict" "recovered" "$verdict"
expect_contains "staging playwright recovered: label" "staging(playwright)" "$recovered"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$R1 OUTCOME_BRUNO_PRODUCTION_2=$R2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "production bruno recovered: verdict" "recovered" "$verdict"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$R1 OUTCOME_PW_PRODUCTION_2=$R2 \
  run_verdict
expect_eq "production playwright recovered: verdict" "recovered" "$verdict"

# Recovery is visible in the run summary (yellow-noted success)
expect_contains "recovered run summary names the leg" "recovered on retry" "$(cat "$tmp/summary")"

# Acceptance path 2: every confirmed shape (both attempts red)
OUTCOME_BRUNO_STAGING_1=$F1 OUTCOME_BRUNO_STAGING_2=$F2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "staging bruno confirmed: verdict" "failed" "$verdict"
expect_contains "staging bruno confirmed: label" "staging(bruno)" "$confirmed"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$F1 OUTCOME_PW_STAGING_2=$F2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "staging playwright confirmed: verdict" "failed" "$verdict"
expect_contains "staging playwright confirmed: label" "staging(playwright)" "$confirmed"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$F1 OUTCOME_BRUNO_PRODUCTION_2=$F2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "production bruno confirmed: verdict" "failed" "$verdict"
expect_contains "production bruno confirmed: label" "production(bruno)" "$confirmed"

OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$F1 OUTCOME_PW_PRODUCTION_2=$F2 \
  run_verdict
expect_eq "production playwright confirmed: verdict" "failed" "$verdict"
expect_contains "production playwright confirmed: label" "production(playwright)" "$confirmed"

# Mixed run: a confirmed leg reverts AND the annotation still reports
# the leg that recovered on the same run
OUTCOME_BRUNO_STAGING_1=$F1 OUTCOME_BRUNO_STAGING_2=$F2 \
OUTCOME_PW_STAGING_1=$R1 OUTCOME_PW_STAGING_2=$R2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "mixed run: verdict" "failed" "$verdict"
expect_contains "mixed run: confirmed leg" "staging(bruno)" "$confirmed"
expect_contains "mixed run: recovered leg still reported" "staging(playwright)" "$recovered"

# Unconfirmed shapes never revert: retry skipped or cancelled after a
# red attempt, and a red attempt with no retry outcome at all
OUTCOME_BRUNO_STAGING_1=$F1 OUTCOME_BRUNO_STAGING_2=skipped \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "retry skipped: verdict stays pass, no revert" "pass" "$verdict"

OUTCOME_BRUNO_STAGING_1=$F1 OUTCOME_BRUNO_STAGING_2=cancelled \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "retry cancelled: verdict stays pass, no revert" "pass" "$verdict"

# All legs skipped (settle failed upstream): verdict not_run, no revert
OUTCOME_BRUNO_STAGING_1=skipped OUTCOME_BRUNO_STAGING_2=skipped \
OUTCOME_PW_STAGING_1=skipped OUTCOME_PW_STAGING_2=skipped \
OUTCOME_BRUNO_PRODUCTION_1=skipped OUTCOME_BRUNO_PRODUCTION_2=skipped \
OUTCOME_PW_PRODUCTION_1=skipped OUTCOME_PW_PRODUCTION_2=skipped \
  run_verdict
expect_eq "all skipped: verdict" "not_run" "$verdict"
expect_eq "all skipped: no confirmed" "" "$confirmed"

# All green: plain pass
OUTCOME_BRUNO_STAGING_1=$S1 OUTCOME_BRUNO_STAGING_2=$S2 \
OUTCOME_PW_STAGING_1=$S1 OUTCOME_PW_STAGING_2=$S2 \
OUTCOME_BRUNO_PRODUCTION_1=$S1 OUTCOME_BRUNO_PRODUCTION_2=$S2 \
OUTCOME_PW_PRODUCTION_1=$S1 OUTCOME_PW_PRODUCTION_2=$S2 \
  run_verdict
expect_eq "all green: verdict" "pass" "$verdict"
expect_eq "all green: no confirmed" "" "$confirmed"
expect_eq "all green: no recovered" "" "$recovered"

# Wiring pins: the revert step in ci.yml gates on the classifier
# verdict, not on a raw single-attempt outcome, and every leg carries
# an attempt-1 step plus a retry gated on that attempt's failure.
wf="$(cat "$workflow")"
expect_contains "red path gates on verdict output" "steps.verdict.outputs.verdict == 'failed'" "$wf"
expect_not_contains "no raw single-attempt red path left" "steps.bruno_staging.outcome == 'failure'" "$wf"
expect_contains "verdict step consumes attempt outcomes" "OUTCOME_BRUNO_STAGING_1: \${{ steps.bruno_staging_1.outcome }}" "$wf"
expect_contains "retry exists for bruno staging" "id: bruno_staging_2" "$wf"
expect_contains "retry exists for pw staging" "id: pw_staging_2" "$wf"
expect_contains "retry exists for bruno production" "id: bruno_production_2" "$wf"
expect_contains "retry exists for pw production" "id: pw_production_2" "$wf"
expect_contains "settle step runs before the legs" "id: settle" "$wf"
expect_contains "settle reuses the watch-deploy health check" "jq -r .version" "$wf"

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
