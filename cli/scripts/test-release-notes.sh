#!/usr/bin/env bash
# Tests for cli/scripts/release-notes.sh, run by the `CLI gates` CI job
# (and locally): every case is a changelog fixture in, notes and an exit
# status out. The green case at the end runs against the REAL
# cli/CHANGELOG.md with the version from Cargo.toml — the same
# live-coupling test-check-tag-version.sh uses — so the repo's own
# changelog always satisfies its own composer. Bump Cargo.toml before
# the changelog has the section and this is the red that reminds you.
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ok() {
  echo "ok    $1"
  pass=$((pass + 1))
}
bad() {
  echo "FAIL  $1"
  fail=$((fail + 1))
}

# Run the composer against a fixture tree: the script reads
# cli/CHANGELOG.md next to its own location, so the fixture mirrors the
# cli/ layout. Prints the notes in $out; sets got to the exit status.
run_compose() {
  local tree="$1"
  shift
  if out="$(sh "$tree/scripts/release-notes.sh" "$@" 2>"$tree/err.txt")"; then got=0; else got=1; fi
}

make_fixture() {
  local tree="$1"
  mkdir -p "$tree/scripts"
  cp scripts/release-notes.sh "$tree/scripts/"
}

# --- green: the section is found and nothing else leaks in -------------------

t1="$work/t1"
make_fixture "$t1"
cat >"$t1/CHANGELOG.md" <<'EOF'
# Changelog

Policy header here.

## [Unreleased]

- unreleased thing nobody asked for

## [0.1.0] - 2026-11-05

### Added

- the 0.1.0 bullet
- another 0.1.0 bullet

## [0.0.9] - 2026-10-01

### Added

- the ancient bullet
EOF
run_compose "$t1" 0.1.0
if [ "$got" = 0 ]; then
  ok "exit 0: section found"
else
  bad "expected exit 0 for a present section, got 1: $(cat "$t1/err.txt")"
fi
if printf '%s\n' "$out" | grep -q "What changed in 0.1.0"; then
  ok "section heading names the version"
else
  bad "no versioned heading in: $out"
fi
if printf '%s\n' "$out" | grep -q "the 0.1.0 bullet"; then
  ok "the version's bullets are in"
else
  bad "0.1.0 bullets missing"
fi
if printf '%s\n' "$out" | grep -q "ancient bullet\|unreleased thing"; then
  bad "other sections leaked into the body"
else
  ok "no other section's content leaks in"
fi
if printf '%s\n' "$out" | grep -q "Sign in"; then
  ok "the static primer is in the body"
else
  bad "static primer missing"
fi
if printf '%s\n' "$out" | sed -n '1,/What changed in/p' | grep -q "—\|;"; then
  bad "static primer carries an em-dash or semicolon"
else
  ok "static primer is em-dash and semicolon free"
fi

# --- writing to a file ---------------------------------------------------------

t2="$work/t2"
make_fixture "$t2"
cp "$t1/CHANGELOG.md" "$t2/CHANGELOG.md"
sh "$t2/scripts/release-notes.sh" 0.1.0 "$t2/notes.md"
if grep -q "the 0.1.0 bullet" "$t2/notes.md"; then
  if [ "$(tail -c 1 "$t2/notes.md" | od -An -c | tr -d '[:space:]')" = '\n' ]; then
    ok "output-path argument lands the notes in a file, ending in exactly one newline"
  else
    bad "file output does not end in a single newline"
  fi
else
  bad "file output missing the section"
fi

# --- 0.1.0 does not match 0.1.0-rc1 ---------------------------------------------

t3="$work/t3"
make_fixture "$t3"
cat >"$t3/CHANGELOG.md" <<'EOF'
## [0.1.0-rc1] - 2026-11-01

### Added

- the rc1 bullet

## [0.1.0] - 2026-11-05

### Added

- the final bullet
EOF
run_compose "$t3" 0.1.0
if [ "$got" = 0 ]; then
  if printf '%s\n' "$out" | grep -q "rc1 bullet"; then
    bad "0.1.0 matched the 0.1.0-rc1 section"
  else
    ok "0.1.0 does not match the 0.1.0-rc1 section"
  fi
  if printf '%s\n' "$out" | grep -q "final bullet"; then
    ok "the exact version's section wins"
  else
    bad "final section missing"
  fi
else
  bad "expected exit 0 for 0.1.0 with rc1 present, got 1: $(cat "$t3/err.txt")"
fi
run_compose "$t3" 0.1.0-rc1
if [ "$got" = 0 ]; then
  if printf '%s\n' "$out" | grep -q "rc1 bullet"; then
    ok "the rc version finds its own section"
  else
    bad "0.1.0-rc1 notes lack the rc bullet: $out"
  fi
else
  bad "0.1.0-rc1 did not find its section (exit $got): $(cat "$t3/err.txt")"
fi

# --- missing section refuses -------------------------------------------------------

t4="$work/t4"
make_fixture "$t4"
printf '# Changelog\n\n## [Unreleased]\n\n- nothing\n' >"$t4/CHANGELOG.md"
run_compose "$t4" 0.2.0
if [ "$got" = 1 ]; then
  if grep -q "no ## \[0.2.0\] section" "$t4/err.txt"; then
    ok "exit 1 with a loud message: missing section"
  else
    bad "refusal does not name the missing section: $(cat "$t4/err.txt")"
  fi
else
  bad "missing section did not fail (exit $got)"
fi

# --- version grammar guard -----------------------------------------------------------

t5="$work/t5"
make_fixture "$t5"
cp "$t1/CHANGELOG.md" "$t5/CHANGELOG.md"
run_compose "$t5" "0.1.0 evil"
if [ "$got" = 1 ]; then
  if grep -q "characters outside Cargo's grammar" "$t5/err.txt"; then
    ok "exit 1: version outside the grammar"
  else
    bad "grammar refusal is not the grammar message: $(cat "$t5/err.txt")"
  fi
else
  bad "grammar guard did not fire (exit $got)"
fi

# --- a failed compose never truncates an existing output file -------------------------

t6="$work/t6"
make_fixture "$t6"
printf '# Changelog\n\n## [Unreleased]\n\n- nothing\n' >"$t6/CHANGELOG.md"
printf 'PRECIOUS\n' >"$t6/notes.md"
run_compose "$t6" 0.9.9 "$t6/notes.md"
if [ "$got" = 1 ] && [ "$(cat "$t6/notes.md")" = "PRECIOUS" ]; then
  ok "exit 1 and the pre-existing output file is untouched"
else
  bad "a failed compose clobbered the output file (exit $got): $(cat "$t6/notes.md" 2>&1)"
fi

# --- green against the real changelog -------------------------------------------------

cargo_version="$(grep -m1 '^version = ' fluxvale-cli/Cargo.toml | cut -d'"' -f2)"
if out="$(sh scripts/release-notes.sh "$cargo_version" 2>&1)"; then
  ok "exit 0: the real CHANGELOG.md has a [$cargo_version] section"
  if printf '%s\n' "$out" | grep -q "What changed in $cargo_version"; then
    ok "the real body carries the versioned heading"
  else
    bad "real body missing the heading"
  fi
else
  bad "the real CHANGELOG.md has no [$cargo_version] section. Write it before tagging ($out)"
fi

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
