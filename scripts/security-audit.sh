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
# above. Low/medium advisories and retirements stay green on purpose.
#
# Expected to be red until the two dependency-bump PRs of this sweep
# merge - that is the design, not an incident (stated in the sweep PR).
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

audit_out="$(mktemp)"
audit_status=0
(cd apps/platform && mix hex.audit >"$audit_out" 2>&1) || audit_status=$?
cat "$audit_out"

# Severity markers are uppercase in parens - Hex renders them from
# advisory_severity/1 as "(HIGH)"/"(CRITICAL)" (hexpm/hex lib/hex/utils.ex).
if grep -q -e "(HIGH)" -e "(CRITICAL)" "$audit_out"
then
  fail "mix hex.audit found HIGH or CRITICAL advisories - bump the pinned deps"
fi

# hex.audit exits non-zero on low/medium advisories and retirements too.
# Below the gate, so loud but green.
if [ "$audit_status" -ne 0 ]
then
  echo "mix hex.audit exited $audit_status on low/medium advisories or retirements - below the gate, staying green"
fi

echo "== govulncheck (apps/tfprovider) =="

# Throwaway GOBIN: never pollutes ~/go/bin, concurrent runs stay
# isolated, nothing to clean up by hand.
gov_bin="$(mktemp -d)"
trap 'rm -rf "$gov_bin"' EXIT
GOBIN="$gov_bin" go install golang.org/x/vuln/cmd/govulncheck@v1.9.0

gov_out="$(mktemp)"
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
