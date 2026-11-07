#!/usr/bin/env bash
# Post-deploy smoke verdict classifier (#556).
#
# Reads the eight step outcomes (four legs x attempt 1 + retry) from
# OUTCOME_<LEG>_1 / OUTCOME_<LEG>_2 env vars and classifies the run:
#   confirmed  both attempts failed - the ONLY revert trigger
#   recovered  first attempt failed, retry passed - yellow-noted success
#   unconfirmed  first attempt failed, retry never failed - no revert
#   not run    legs skipped (settle failed upstream) - no revert
#
# Emits verdict/confirmed/recovered to GITHUB_OUTPUT and the run
# summary table to GITHUB_STEP_SUMMARY. Pure function: no network, no
# tokens. Behavior is pinned by scripts/test-smoke-verdict.sh.
set -euo pipefail

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

leg_label() {
  case "$1" in
    bruno_staging) echo "staging(bruno)" ;;
    pw_staging) echo "staging(playwright)" ;;
    bruno_production) echo "production(bruno)" ;;
    pw_production) echo "production(playwright)" ;;
  esac
}

confirmed=""
recovered=""
any_not_run=0
table=""

for leg in bruno_staging pw_staging bruno_production pw_production; do
  upper="${leg^^}"
  v1="OUTCOME_${upper}_1"
  v2="OUTCOME_${upper}_2"
  attempt1="${!v1:-skipped}"
  retry="${!v2:-skipped}"
  label="$(leg_label "$leg")"

  result="pass"
  if [ "$attempt1" = "failure" ]; then
    if [ "$retry" = "failure" ]; then
      result="CONFIRMED failure"
      confirmed="$confirmed $label"
    elif [ "$retry" = "success" ]; then
      result="recovered on retry"
      recovered="$recovered $label"
    else
      # Retry skipped or cancelled: not confirmed, never a revert
      result="unconfirmed (retry did not fail)"
    fi
  elif [ "$attempt1" != "success" ]; then
    # skipped (settle failed upstream) or cancelled
    result="not run"
    any_not_run=1
  fi

  table="$table| $label | $attempt1 | $retry | $result |"$'\n'
done

confirmed="${confirmed# }"
recovered="${recovered# }"

if [ -n "$confirmed" ]; then
  verdict="failed"
elif [ -n "$recovered" ]; then
  verdict="recovered"
elif [ "$any_not_run" = 1 ]; then
  verdict="not_run"
else
  verdict="pass"
fi

{
  echo "verdict=$verdict"
  echo "confirmed=$confirmed"
  echo "recovered=$recovered"
} >>"$GITHUB_OUTPUT"

{
  echo "### Post-deploy smoke verdict (#556)"
  echo ""
  echo "| Leg | Attempt 1 | Retry | Result |"
  echo "|---|---|---|---|"
  printf '%s' "$table"
  echo ""
  echo "verdict: $verdict"
} >>"$GITHUB_STEP_SUMMARY"
