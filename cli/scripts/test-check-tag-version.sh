#!/usr/bin/env bash
# Tests for cli/scripts/check-tag-version.sh, run by the `CLI gates` CI
# job (and locally, with no tag): every case is a tag in, an exit status
# out. The green case derives the version from Cargo.toml with its own
# extraction (grep+cut, not the script's sed), so a legit version bump
# keeps the test green without a fixture edit.
set -euo pipefail
cd "$(dirname "$0")/.."

check=./scripts/check-tag-version.sh
cargo_version="$(grep -m1 '^version = ' fluxvale-cli/Cargo.toml | cut -d'"' -f2)"
if [ -z "$cargo_version" ]; then
  echo "FAIL  could not extract the version from fluxvale-cli/Cargo.toml"
  exit 1
fi

pass=0
fail=0

expect() {
  local want="$1" tag="$2" out
  if out="$(bash "$check" "$tag" 2>&1)"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then
    echo "ok    exit $want: $tag"
    pass=$((pass + 1))
  else
    echo "FAIL  expected exit $want for '$tag', got $got: $out"
    fail=$((fail + 1))
  fi
}

# Green: the tag that matches the committed Cargo.toml.
expect 0 "cli-v$cargo_version"

# Red: a lazy tag one patch ahead of Cargo.toml. (9.9.9 would also do;
# a suffix can't — pre-release Cargo versions like 0.1.0-rc1 are legit.)
expect 1 "cli-v$cargo_version-mismatch"
# Red: the BEAM release namespace, not ours.
expect 1 "v$cargo_version"
# Red: the prefix without a version.
expect 1 "cli-v"
# Red: not a version tag at all.
expect 1 "some-branch-name"

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
