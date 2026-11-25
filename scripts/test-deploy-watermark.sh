#!/usr/bin/env bash
# Tests for scripts/deploy-watermark.sh, run by the `check-changes` CI job
# (and locally, with no PR). The /health bodies are files — curl reads
# file:// the way it reads https:// — and the shas are real commits from
# this repo's history, so nothing here commits, serves, or needs a network.
set -euo pipefail
cd "$(dirname "$0")/.."

script=./scripts/deploy-watermark.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git rev-parse --verify --quiet HEAD~12 >/dev/null || {
  echo "::error::needs at least 12 commits of history (git fetch --unshallow?)"
  exit 1
}

# First-parent offsets from HEAD: n0 the tip, n9 the oldest used.
n0="$(git rev-parse HEAD)"
n1="$(git rev-parse HEAD~1)"
n4="$(git rev-parse HEAD~4)"
n9="$(git rev-parse HEAD~9)"
foreign=0000000000000000000000000000000000000001 # well-formed, no such commit

# health <file> <version> — one /health body
health() { printf '{"status":"ok","version":"%s"}\n' "$2" > "$tmp/$1"; }
health n4.json "sha-$n4"
health n9.json "sha-$n9"
health n1.json "sha-$n1"
health n0.json "sha-$n0"
health short.json "sha-${n4:0:12}"
health dev.json "dev"
health foreign.json "sha-$foreign"
health embedded.json "1.2.3+sha-$n4"   # contains a sha; must NOT count as one
health forged.json 'x\n::error::forged\n' # JSON-escaped newlines: a workflow-command injection probe

pass=0
fail=0

# expect <name> <want-base> <script args…> — stdout must be exactly `base=<want>`
expect() {
  local name="$1" want="$2" got
  shift 2
  got="$("$script" "$@" 2>/dev/null)"
  if [ "$got" = "base=$want" ]; then
    echo "ok    $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name: wanted base=$want, got '$got'"
    fail=$((fail + 1))
  fi
}

expect "one env, serving an ancestor" "$n4" "staging=file://$tmp/n4.json"
expect "both envs on the same commit" "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/n4.json"
expect "prod mid-rollout behind staging: the newer env wins" "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/n9.json"
expect "staging behind prod: the newer env wins" "$n4" "staging=file://$tmp/n9.json" "production=file://$tmp/n4.json"
expect "one env on a sha that is no commit: ignored" "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/foreign.json"
expect "one env unreachable (any curl failure — 5xx, timeout, no route): ignored" "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/missing.json"
expect "one env on a non-build identity: ignored" "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/dev.json"
expect "both envs on a non-build identity: unresolved" "" "staging=file://$tmp/dev.json" "production=file://$tmp/dev.json"
expect "both envs unreachable: unresolved" "" "staging=file://$tmp/missing.json" "production=file://$tmp/missing.json"
expect "a serving sha above the commit under test: ignored" "$n4" --head "$n4" "staging=file://$tmp/n4.json" "production=file://$tmp/n0.json"
expect "only a serving sha above the commit under test: unresolved" "" --head "$n4" "staging=file://$tmp/n1.json"
expect "a short /health sha resolves" "$n4" "staging=file://$tmp/short.json"
expect "a version that merely contains a sha is not a build identity" "$n9" "staging=file://$tmp/embedded.json" "production=file://$tmp/n9.json"
expect "both envs on embedded shas: unresolved" "" "staging=file://$tmp/embedded.json" "production=file://$tmp/embedded.json"

# A multi-line /health version must not smuggle ::…:: workflow commands
# into the run log: squashed to spaces, no ::error:: line on stderr.
err="$("$script" "staging=file://$tmp/forged.json" 2>&1 >/dev/null)"
if printf '%s\n' "$err" | grep -q '^::error::'; then
  echo "FAIL  forged workflow command reached the log: $(printf '%s\n' "$err" | grep '^::error::')"
  fail=$((fail + 1))
elif printf '%s\n' "$err" | grep -q 'reports x ::error::forged — not a build identity'; then
  echo "ok    a multi-line version is squashed before the log"
  pass=$((pass + 1))
else
  echo "FAIL  multi-line version: expected the squashed line, got: $(printf '%s\n' "$err" | head -2)"
  fail=$((fail + 1))
fi

# expect_usage <name> <script args…> — the resolver exits 2 and prints no base line
expect_usage() {
  local name="$1" got rc
  shift
  set +e
  got="$("$script" "$@" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && [ -z "$got" ]; then
    echo "ok    $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name: wanted exit 2 and no output, got exit $rc and '$got'"
    fail=$((fail + 1))
  fi
}
expect_usage "no envs given"
expect_usage "an argument without name=url" "staging"
expect_usage "--head without a sha" --head

echo "deploy-watermark: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
