#!/usr/bin/env bash
# Tests for cli/scripts/install.sh, run by the `CLI gates` CI job (and
# locally, with no network): the installer runs end to end against a
# fake curl that serves fixture files, so every case exercises the real
# script — platform detect, checksum verify, versions dir + current
# symlink, shim, prune-on-upgrade, and the honest refusals.
#
# The fixture archive is what cli-release.yml's archive step tars: one
# stage dir, fluxvale-<version>-<leg>/, with the binary at its top. The
# stand-in binary prints what the real one prints for --version.
set -euo pipefail
cd "$(dirname "$0")/.."

install=./scripts/install.sh

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

# assert <description> <command...>: the command must succeed.
assert() {
  local desc="$1"
  shift
  if "$@"; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

# --- fixtures -------------------------------------------------------------

fixture="$work/fixture"
mkdir -p "$fixture"

make_archive() {
  local version="$1"
  local stage="fluxvale-$version-linux-amd64"
  mkdir -p "$fixture/$stage"
  printf '#!/bin/sh\necho "fluxvale %s"\n' "$version" >"$fixture/$stage/fluxvale"
  chmod 755 "$fixture/$stage/fluxvale"
  tar -czf "$fixture/fluxvale-$version-linux-amd64.tar.gz" -C "$fixture" "$stage"
}

# fake curl: serves the fixture dir, no network. The installer's
# redirect resolution (-w '%{redirect_url}') reads fixture/redirect_url.
make_fake_curl() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
fixture="${FAKE_CURL_FIXTURE:?}"
mode=""
out="/dev/null"
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) mode="redirect"; shift 2 ;;
    --proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$mode" = "redirect" ]; then
  cat "$fixture/redirect_url"
  exit 0
fi
file="$fixture/${url##*/}"
if [ -f "$file" ]; then
  cp "$file" "$out"
  exit 0
fi
printf 'fake curl: no fixture for %s\n' "$url" >&2
exit 22
FAKE
  chmod 755 "$dir/curl"
}

fakebin="$work/bin"
make_fake_curl "$fakebin"

# The installer under a sandbox: fake curl, isolated HOME/BIN_DIR, the
# fixture dir as the asset base. Extra env pairs come as arguments.
run_installer() {
  local home="$1"
  shift
  env PATH="$fakebin:$PATH" \
    FAKE_CURL_FIXTURE="$fixture" \
    FLUXVALE_HOME="$home/fluxvale" \
    FLUXVALE_BIN_DIR="$home/bin" \
    FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
    "$@" \
    sh "$install"
}

versions_dir_of() {
  local home="$1"
  printf '%s\n' "$home/fluxvale/versions"
}

# One version dir on disk (the prune invariant).
version_count() {
  find "$(versions_dir_of "$1")" -mindepth 1 -maxdepth 1 -type d | wc -l
}

# The green-path cases share one fixture: both archives plus a
# SHA256SUMS listing them, and a redirect naming 0.2.0 as the latest.
make_archive 0.1.0
make_archive 0.2.0
(cd "$fixture" && sha256sum fluxvale-0.1.0-linux-amd64.tar.gz fluxvale-0.2.0-linux-amd64.tar.gz >SHA256SUMS)
printf 'https://github.com/fluxvale/fluxvale/releases/tag/cli-v0.2.0\n' >"$fixture/redirect_url"

# --- green install (pinned) -------------------------------------------------

t1="$work/t1"
mkdir -p "$t1"
if out="$(run_installer "$t1" FLUXVALE_VERSION=0.1.0 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 0 ]; then
  ok "exit 0: pinned install"
else
  bad "expected exit 0 for the pinned install, got 1: $out"
fi
assert "binary installed at versions/0.1.0/fluxvale" test -x "$(versions_dir_of "$t1")/0.1.0/fluxvale"
assert "shim installed at the bin dir" test -x "$t1/bin/fluxvale"
if [ "$(readlink "$t1/fluxvale/current")" = "$t1/fluxvale/versions/0.1.0" ]; then
  ok "current symlink points at versions/0.1.0"
else
  bad "current symlink wrong: $(readlink "$t1/fluxvale/current" 2>&1 || echo none)"
fi
if [ "$("$t1/bin/fluxvale" --version)" = "fluxvale 0.1.0" ]; then
  ok "shim runs the installed binary"
else
  bad "shim did not run the installed binary"
fi
if printf '%s\n' "$out" | grep -q "fluxvale 0.1.0 installed"; then
  ok "success message carries the version"
else
  bad "no versioned success message in: $out"
fi
if printf '%s\n' "$out" | grep -q "is not on PATH"; then
  ok "PATH warning printed for an off-PATH bin dir"
else
  bad "no PATH warning in: $out"
fi

# --- upgrade in place prunes the old version ------------------------------

if out="$(run_installer "$t1" FLUXVALE_VERSION=0.2.0 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 0 ]; then
  ok "exit 0: upgrade in place"
else
  bad "expected exit 0 for the upgrade, got 1: $out"
fi
count="$(version_count "$t1")"
if [ "$count" = 1 ]; then
  ok "prune leaves one version on disk"
else
  bad "expected one version after upgrade, got $count"
fi
assert "the new version is the one on disk" test -x "$(versions_dir_of "$t1")/0.2.0/fluxvale"
if [ "$(readlink "$t1/fluxvale/current")" = "$t1/fluxvale/versions/0.2.0" ]; then
  ok "current symlink moved to 0.2.0"
else
  bad "current symlink did not move: $(readlink "$t1/fluxvale/current" 2>&1 || echo none)"
fi
if [ "$("$t1/bin/fluxvale" --version)" = "fluxvale 0.2.0" ]; then
  ok "shim follows the upgrade"
else
  bad "shim still runs the old version"
fi

# --- latest resolution (no pin) ---------------------------------------------

t3="$work/t3"
mkdir -p "$t3"
if out="$(run_installer "$t3" 2>&1)"; then
  assert "no pin installs the release the redirect names (0.2.0)" test -x "$(versions_dir_of "$t3")/0.2.0/fluxvale"
else
  bad "expected exit 0 for the no-pin install, got 1: $out"
fi

# --- the pin wins over the redirect ------------------------------------------

t4="$work/t4"
mkdir -p "$t4"
if out="$(run_installer "$t4" FLUXVALE_VERSION=0.1.0 2>&1)"; then
  assert "FLUXVALE_VERSION pins against the redirect" test -x "$(versions_dir_of "$t4")/0.1.0/fluxvale"
else
  bad "expected exit 0 for the pinned-over-redirect install, got 1: $out"
fi

# --- checksum mismatch refuses -------------------------------------------------

fixture_mismatch="$work/mismatch"
mkdir -p "$fixture_mismatch"
cp "$fixture/fluxvale-0.1.0-linux-amd64.tar.gz" "$fixture_mismatch/"
printf 'deadbeef  fluxvale-0.1.0-linux-amd64.tar.gz\n' >"$fixture_mismatch/SHA256SUMS"
printf 'https://github.com/fluxvale/fluxvale/releases/tag/cli-v0.1.0\n' >"$fixture_mismatch/redirect_url"
mismatch_bin="$work/bin-mismatch"
make_fake_curl "$mismatch_bin"
t5="$work/t5"
mkdir -p "$t5"
if out="$(env PATH="$mismatch_bin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture_mismatch" \
  FLUXVALE_HOME="$t5/fluxvale" \
  FLUXVALE_BIN_DIR="$t5/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install" 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  ok "exit 1: checksum mismatch"
else
  bad "expected exit 1 for a checksum mismatch, got 0"
fi
if printf '%s\n' "$out" | grep -q "checksum mismatch"; then
  ok "the refusal names the mismatch"
else
  bad "refusal does not name the mismatch: $out"
fi
assert "a refused install writes nothing under the versions dir" test ! -e "$t5/fluxvale/versions"

# --- missing checksum entry refuses ---------------------------------------------

fixture_missing="$work/missing"
mkdir -p "$fixture_missing"
cp "$fixture/fluxvale-0.1.0-linux-amd64.tar.gz" "$fixture_missing/"
printf 'not-the-right-line  some-other-archive.tar.gz\n' >"$fixture_missing/SHA256SUMS"
printf 'https://github.com/fluxvale/fluxvale/releases/tag/cli-v0.1.0\n' >"$fixture_missing/redirect_url"
missing_bin="$work/bin-missing"
make_fake_curl "$missing_bin"
t6="$work/t6"
mkdir -p "$t6"
if out="$(env PATH="$missing_bin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture_missing" \
  FLUXVALE_HOME="$t6/fluxvale" \
  FLUXVALE_BIN_DIR="$t6/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install" 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  ok "exit 1: no checksum for the archive"
else
  bad "expected exit 1 for a missing checksum entry, got 0"
fi
if printf '%s\n' "$out" | grep -q "no checksum for"; then
  ok "the refusal names the missing entry"
else
  bad "refusal does not name the missing entry: $out"
fi

# --- version grammar guard --------------------------------------------------------

t7="$work/t7"
mkdir -p "$t7"
if out="$(run_installer "$t7" 'FLUXVALE_VERSION=0.1.0 evil' 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  ok "exit 1: version with characters outside the grammar"
else
  bad "expected exit 1 for an invalid FLUXVALE_VERSION, got 0"
fi
assert "an invalid version installs nothing" test ! -e "$t7/fluxvale/versions"

# --- unsupported platform refuses ---------------------------------------------------

uname_bin="$work/bin-uname"
make_fake_curl "$uname_bin"
cat >"$uname_bin/uname" <<'FAKE'
#!/bin/sh
case "$1" in
  -s) printf 'Linux\n' ;;
  -m) printf 'i686\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
FAKE
chmod 755 "$uname_bin/uname"
t8="$work/t8"
mkdir -p "$t8"
if out="$(env PATH="$uname_bin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture" \
  FLUXVALE_HOME="$t8/fluxvale" \
  FLUXVALE_BIN_DIR="$t8/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install" 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  ok "exit 1: unsupported Linux architecture"
else
  bad "expected exit 1 for an unsupported architecture, got 0"
fi
if printf '%s\n' "$out" | grep -q "unsupported Linux architecture"; then
  ok "the refusal names the platform"
else
  bad "refusal does not name the platform: $out"
fi

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
