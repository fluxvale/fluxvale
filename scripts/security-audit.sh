#!/usr/bin/env bash
# Dependency audit for the nightly pentest stage (issue #528). The ZAP
# job in pentest.yml gates HIGH-risk web findings, this gates the
# dependencies the stack is built from.
#
# Gate, per the sweep's settled design:
#   mix hex.audit   fail on (HIGH) or (CRITICAL) advisories only
# The tool exits non-zero on weaker findings as well (any advisory or
# retirement), so the output is captured, printed verbatim, and gated
# on the severities above. A non-zero exit without the tool's own
# finding verdict is a broken run and fails loudly - it must not read
# as "audited and clean". Low/medium advisories and retirements stay
# green on purpose.
#
# The Go half (govulncheck over the Terraform provider) moved with the
# provider to fluxvale/terraform-provider-fluxvale - this audit is
# BEAM-only since that extraction.
set -euo pipefail

if [ ! -f apps/platform/mix.exs ]
then
  echo "run from the repo root" >&2
  exit 2
fi

fail() {
  echo "::error::$1" >&2
  exit 1
}

echo "== mix hex.audit (apps/platform) =="

# deps first: hex.audit loads the dep graph and reads mix.lock (the
# official CI example in its docs runs deps.get before hex.audit).
(cd apps/platform && mix deps.get)

# Throwaway capture files: one trap cleans all, so a failed gate
# leaves nothing behind.
audit_out="$(mktemp)"
trap 'rm -rf "$audit_out"' EXIT

audit_status=0
(cd apps/platform && mix hex.audit >"$audit_out" 2>&1) || audit_status=$?
cat "$audit_out"

# Severity markers are uppercase in parens - Hex renders them from
# advisory_severity/1 as " (HIGH)"/" (CRITICAL)" (hexpm/hex lib/hex/
# utils.ex prefixes the plain space before the color codes). The
# leading space keeps free-text prose (a paren inside a word) from
# false-positive on the grep.
#
# Known-unfixable advisories, suppressed BY ADVISORY ID with their
# revisit trigger - a new advisory on the same package still reds.
# Adding one requires the evidence trail in the sweep notes.
KNOWN_UNFIXED=(
  # assent 0.2.13, Sign in with Apple callback override: the app's
  # only OAuth flow is Google (#332), and assent 0.3.x is capped out
  # by ash_authentication 4.x (requires < 0.3.0).
  # Revisit: ash_authentication 5.x GA.
  "EEF-CVE-2026-117656"
)

gate_hits="$(grep -E ' \((HIGH|CRITICAL)\)' "$audit_out" || true)"
for id in "${KNOWN_UNFIXED[@]}"
do
  gate_hits="$(printf '%s\n' "$gate_hits" | grep -F -v "$id" || true)"
done

if [ -n "$(printf '%s' "$gate_hits" | tr -d '[:space:]')" ]
then
  printf '%s\n' "$gate_hits"
  fail "mix hex.audit found HIGH or CRITICAL advisories - bump the pinned deps"
fi

# Say a suppression loudly when it fires - a silent one is a lie.
if grep -qF "${KNOWN_UNFIXED[0]}" "$audit_out" && grep -qE ' \((HIGH|CRITICAL)\)' "$audit_out" && \
   ! [ -n "$(grep -E ' \((HIGH|CRITICAL)\)' "$audit_out" | grep -F -v "${KNOWN_UNFIXED[0]}" | tr -d '[:space:]')" ]
then
  echo "known-unfixable advisory suppressed (see KNOWN_UNFIXED in this script): ${KNOWN_UNFIXED[0]}"
fi

# hex.audit exits non-zero below the gate too, but ALSO when the run
# itself broke (registry errors crash before any verdict). Green only
# on its own finding verdicts (verified from hexpm/hex lib/mix/tasks/
# hex.audit.ex: Hex.Shell.error prints these exact lines), loud
# failure otherwise - a broken run must not read as "audited and
# clean".
if [ "$audit_status" -ne 0 ]
then
  if grep -q -e "Found packages with security advisories" -e "Found retired packages" "$audit_out"
  then
    echo "mix hex.audit exited $audit_status on low/medium advisories or retirements - below the gate, staying green"
  else
    fail "mix hex.audit exited $audit_status without an advisory or retirement verdict - fix the run"
  fi
fi

echo "dependency audit clean"
