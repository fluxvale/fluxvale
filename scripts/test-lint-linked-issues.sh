#!/usr/bin/env bash
# Tests for scripts/lint-linked-issues.sh, run by the `linked-issues` CI job
# (and locally, with no PR): every case is a body in, an exit status out.
#
# The positive fixtures are the REAL bodies of #62 and #269 — the two PRs
# that actually closed an umbrella issue early, six weeks apart — fetched
# with `gh api repos/fluxvale/fluxvale/pulls/<n> --jq .body`. Their sha256
# is checked below, so a fixture quietly edited to keep the test green fails
# the test instead. Re-fetching a body is only correct if the PR body itself
# changed on GitHub; the hashes then need updating in the same commit.
set -euo pipefail
cd "$(dirname "$0")/.."

lint=./scripts/lint-linked-issues.sh
fixtures=scripts/fixtures/linked-issues
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# --- fixtures are what GitHub holds --------------------------------------
# The bodies as of 2026-10-27; #62 (Sep 15) and #269 (Oct 26) are the two
# incidents. A mismatch means the fixture is no longer history.
check_hash() {
  local expected="$1" file="$2" actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok    fixture ${file##*/} sha256 matches the fetched body"
    pass=$((pass + 1))
  else
    echo "FAIL  fixture ${file##*/} sha256 drifted: expected ${expected}, got ${actual}" \
         "(re-fetch with: gh api repos/fluxvale/fluxvale/pulls/<n> --jq .body)"
    fail=$((fail + 1))
  fi
}

check_hash 44a7733609901c08a0ea9f679565df4b21cc97c197057c682093317db4629cb9 "$fixtures/pr-62.md"
check_hash 894edfe693db64b8cdd38876a468bf8f129a821fe88977d07eb0987162d08a7b "$fixtures/pr-269.md"
check_hash e1500059ffa95a8a5cdaa856f3fc769d57fc66a94aed251ae1573c4e687c4cc4 "$fixtures/pr-33.md"
check_hash cb9832742ed0a3f2247a06101915d4a7019dcfa715102b1cd9cec9849b34109b "$fixtures/pr-177.md"
check_hash 064e1b0076fc50101bf0618c1787eecd1bc45568db73659f09f717ff660f3465 "$fixtures/pr-106.md"
check_hash 191839bac3e167c2a9c7a1c96a4a4571975bd7e0d53a7a515c34dfe27d0964f2 "$fixtures/pr-108.md"

# --- the contract --------------------------------------------------------
# expect_exit <status> <name> <body-file>
expect_exit() {
  local want="$1" name="$2" file="$3" got
  set +e
  output="$("$lint" "$file" 2>&1)"
  got=$?
  set -e
  if [[ "$got" -eq "$want" ]]; then
    echo "ok    ${name} (exit ${got})"
    pass=$((pass + 1))
  else
    echo "FAIL  ${name}: wanted exit ${want}, got ${got}"
    echo "$output" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}

# expect_stdin_exit <status> <name> <body>
expect_stdin_exit() {
  local want="$1" name="$2" body="$3" got
  set +e
  output="$(printf '%s\n' "$body" | "$lint" - 2>&1)"
  got=$?
  set -e
  if [[ "$got" -eq "$want" ]]; then
    echo "ok    ${name} (exit ${got})"
    pass=$((pass + 1))
  else
    echo "FAIL  ${name}: wanted exit ${want}, got ${got}"
    echo "$output" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}

# 1. History: the two real incidents must fail.
expect_exit 1 "#62 closes #61 while saying 'slice 1 of 7'" "$fixtures/pr-62.md"
expect_exit 1 "#269 closes #268 while saying 'slice 1 of 4'" "$fixtures/pr-269.md"

# 2. The correct forms must pass: a plain completing close, and a slice PR
#    that references without closing.
expect_exit 0 "#33 plain 'Closes #32', no slice language" "$fixtures/pr-33.md"
expect_exit 0 "#177 'Part of #175 (slice 2 of 3 …)', refs only" "$fixtures/pr-177.md"
expect_exit 0 "#106 'Slice 1 of 2 for #98 (refs #98 …)', no closing keyword" "$fixtures/pr-106.md"
expect_exit 0 "#108 near-miss: 'Closes #98 (the closing slice …)', no 'slice N of M'" "$fixtures/pr-108.md"

# 3. No issue reference at all.
expect_stdin_exit 0 "body with no issue reference" \
  $'Plain prose about a refactor.\n\nNo issues are closed or referenced here.'

# 4. Keywords and shapes the fixture set does not carry, both directions.
expect_stdin_exit 1 "lowercase 'fixes #7 (part 2 of 5)'" 'fixes #7 (part 2 of 5)'
expect_stdin_exit 1 "cross-repo 'Resolved owner/repo#7' + 'slice 1 of 3'" \
  $'Resolved owner/repo#7\n\nSlice 1 of 3 — the schema half.'
expect_stdin_exit 1 "colon form 'Fixes: #7' + 'slice 1 of 2'" 'Fixes: #7 — slice 1 of 2'
expect_stdin_exit 0 "'Closes #7' with no slice language" 'Closes #7'
expect_stdin_exit 0 "'slice 3 of 3' — a legitimate final slice" 'Closes #7 (slice 3 of 3 — the last one)'
expect_stdin_exit 0 "'refs #7' with slice language" 'Refs #7 (slice 2 of 4 — the UI)'
expect_stdin_exit 0 "'slices' as a plural noun, no N of M" \
  'Closes #7. Two slices of the old code were merged; nothing else.'

# 5. Code is not prose: documenting this rule must not trip it.
expect_stdin_exit 0 "incident quoted in a fenced block" \
  $'Documents the rule.\n\n```\nCloses #61 (slice 1 of 7 — calibration sample)\n```'
expect_stdin_exit 0 "incident quoted in an inline code span" \
  'The old bodies read `Closes #61 (slice 1 of 7)` and got closed early.'
expect_stdin_exit 0 "incident quoted in an HTML comment" \
  $'Closes #9\n\n<!--\nCloses #61 (slice 1 of 7 — calibration sample)\n-->'

# 6. The fix the message recommends must itself pass, on #269's real body.
sed 's/^Closes #268/Refs #268/' "$fixtures/pr-269.md" >"$tmp/refs.md"
expect_exit 0 "derived from #269: 'Closes' rewritten to 'Refs'" "$tmp/refs.md"

# 7. Bad invocation is a usage error, not a pass — a broken path must never
#    read as "consistent".
set +e
"$lint" "$tmp/does-not-exist.md" >/dev/null 2>&1
got=$?
set -e
if [[ "$got" -eq 2 ]]; then
  echo "ok    missing file is a usage error (exit 2), never a silent pass"
  pass=$((pass + 1))
else
  echo "FAIL  missing file should exit 2, got ${got}"
  fail=$((fail + 1))
fi

# 8. The failure message has to be actionable: name the issue, the phrase,
#    and the replacement form.
set +e
message="$("$lint" "$fixtures/pr-269.md" 2>&1)"
set -e
for needle in '#268' 'slice 1 of 4' 'Refs #268' 'AGENTS.md'; do
  if grep -qF -- "$needle" <<<"$message"; then
    echo "ok    failure message mentions ${needle}"
    pass=$((pass + 1))
  else
    echo "FAIL  failure message missing ${needle}:"
    echo "$message" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
done

echo
if [[ "$fail" -eq 0 ]]; then
  echo "linked-issues lint: ${pass}/${pass} cases pass"
else
  echo "linked-issues lint: ${fail} of $((pass + fail)) cases failed"
  exit 1
fi
