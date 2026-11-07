#!/usr/bin/env bash
# Dependency audit for the nightly pentest stage (issue #528). The ZAP
# job in pentest.yml gates HIGH-risk web findings, this gates the
# dependencies the stack is built from.
#
# Gates, per the sweep's settled design:
#   mix hex.audit   fail on (HIGH) or (CRITICAL) advisories only
#   govulncheck     fail only when the Go code is affected (called vulns)
# Both tools exit non-zero on weaker findings as well (hex.audit on any
# advisory or retirement, govulncheck on usage/tool errors), so the
# outputs are captured, printed verbatim, and gated on the severities
# above. A non-zero exit without the tool's own finding verdict is a
# broken run and fails loudly - it must not read as "audited and
# clean". Low/medium advisories and retirements stay green on purpose.
#
# Expected to stay red until the platform dependency-bump PRs of this
# sweep merge - the tfprovider bumps already landed (#531). That is
# the design, not an incident (stated in the sweep PR).
set -euo pipefail

if [ ! -f apps/platform/mix.exs ] || [ ! -d apps/tfprovider ]
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

# Throwaway capture files and GOBIN: one trap cleans all three, so a
# failed gate leaves nothing behind (the old gov_bin-only trap missed
# the audit captures).
audit_out="$(mktemp)"
gov_out="$(mktemp)"
gov_bin="$(mktemp -d)"
trap 'rm -rf "$audit_out" "$gov_out" "$gov_bin"' EXIT

audit_status=0
(cd apps/platform && mix hex.audit >"$audit_out" 2>&1) || audit_status=$?
cat "$audit_out"

# Severity markers are uppercase in parens - Hex renders them from
# advisory_severity/1 as " (HIGH)"/" (CRITICAL)" (hexpm/hex lib/hex/
# utils.ex prefixes the plain space before the color codes). The
# leading space keeps free-text prose (a paren inside a word) from
# false-positive on the grep.
if grep -qE ' \((HIGH|CRITICAL)\)' "$audit_out"
then
  fail "mix hex.audit found HIGH or CRITICAL advisories - bump the pinned deps"
fi

# hex.audit exits non-zero below the gate too, but ALSO when the run
# itself broke (registry errors crash before any verdict). Green only
# on its own finding verdicts (verified from hexpm/hex lib/mix/tasks/
# hex.audit.ex: Hex.Shell.error prints these exact lines), loud
# failure otherwise - a broken run must not read as "audited and
# clean" (same stance as the govulncheck arm below).
if [ "$audit_status" -ne 0 ]
then
  if grep -q -e "Found packages with security advisories" -e "Found retired packages" "$audit_out"
  then
    echo "mix hex.audit exited $audit_status on low/medium advisories or retirements - below the gate, staying green"
  else
    fail "mix hex.audit exited $audit_status without an advisory or retirement verdict - fix the run"
  fi
fi

echo "== govulncheck (apps/tfprovider) =="

# The GOBIN above keeps the install out of ~/go/bin and concurrent
# runs isolated - nothing to clean up by hand.
GOBIN="$gov_bin" go install golang.org/x/vuln/cmd/govulncheck@v1.9.0

gov_status=0
(cd apps/tfprovider && "$gov_bin/govulncheck" ./... >"$gov_out" 2>&1) || gov_status=$?
cat "$gov_out"

# Exit codes verified from golang/vuln source: 3 = errVulnerabilitiesFound,
# set only when findings are CALLED at the default symbol scan level
# (internal/scan/text.go). Import-only findings exit 0 and the summary
# then reads "affected by 0 vulnerabilities" - the [1-9] keeps that a
# pass. The grep is belt and braces for the exit-code path.
if [ "$gov_status" -eq 3 ] || grep -Eq "Your code is affected by [1-9][0-9]* vulnerabilit" "$gov_out"
then
  fail "govulncheck: apps/tfprovider code is affected by called vulnerabilities - bump the module pins"
fi

# A broken run (exit 1/2: usage, network, go version mismatch) must not
# read as "audited and clean" - fail loudly instead.
if [ "$gov_status" -ne 0 ]
then
  fail "govulncheck exited $gov_status without a called-vulnerability verdict - fix the run"
fi

echo "dependency audit clean"
