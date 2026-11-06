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
install_abs="$PWD/scripts/install.sh"

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
  local leg="${2:-linux-amd64}"
  local stage="fluxvale-$version-$leg"
  mkdir -p "$fixture/$stage"
  printf '#!/bin/sh\necho "fluxvale %s"\n' "$version" >"$fixture/$stage/fluxvale"
  chmod 755 "$fixture/$stage/fluxvale"
  tar -czf "$fixture/fluxvale-$version-$leg.tar.gz" -C "$fixture" "$stage"
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
printf '%s\n' "$url" >>"$fixture/requested_urls.log"
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

# One version dir on disk (the prune invariant). Digit-led only, to
# match the installer's notion of an installed version. tr strips the
# padding BSD wc puts around its output (macOS pads to width 7 even on
# pipes).
version_count() {
  find "$(versions_dir_of "$1")" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | wc -l | tr -d '[:space:]'
}

# The green-path cases share one fixture: the archives plus a SHA256SUMS
# listing them, and a redirect naming 0.2.0 as the latest.
make_archive 0.1.0
make_archive 0.2.0
make_archive 0.2.0 macos-aarch64
(cd "$fixture" && sha256sum fluxvale-0.1.0-linux-amd64.tar.gz fluxvale-0.2.0-linux-amd64.tar.gz fluxvale-0.2.0-macos-aarch64.tar.gz >SHA256SUMS)
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

# --- the pin accepts the v prefix ---------------------------------------------

t9="$work/t9"
mkdir -p "$t9"
if out="$(run_installer "$t9" FLUXVALE_VERSION=v0.2.0 2>&1)"; then
  assert "FLUXVALE_VERSION=v0.2.0 installs 0.2.0" test -x "$(versions_dir_of "$t9")/0.2.0/fluxvale"
else
  bad "expected exit 0 for the v-prefixed pin, got 1: $out"
fi

# --- a *-marker checksum line still matches --------------------------------------

fixture_star="$work/star"
mkdir -p "$fixture_star"
cp "$fixture/fluxvale-0.1.0-linux-amd64.tar.gz" "$fixture_star/"
(cd "$fixture_star" && sha256sum fluxvale-0.1.0-linux-amd64.tar.gz | sed 's/  /  */' >SHA256SUMS)
printf 'https://github.com/fluxvale/fluxvale/releases/tag/cli-v0.1.0\n' >"$fixture_star/redirect_url"
star_bin="$work/bin-star"
make_fake_curl "$star_bin"
t10="$work/t10"
mkdir -p "$t10"
if out="$(env PATH="$star_bin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture_star" \
  FLUXVALE_HOME="$t10/fluxvale" \
  FLUXVALE_BIN_DIR="$t10/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install" 2>&1)"; then
  assert "a *-marker checksum line still verifies" test -x "$t10/fluxvale/versions/0.1.0/fluxvale"
else
  bad "expected exit 0 for a *-marker SHA256SUMS, got 1: $out"
fi

# --- spaces in the install path are fine -------------------------------------------

t11="$work/t11"
mkdir -p "$t11/space home"
if out="$(run_installer "$t11/space home" FLUXVALE_VERSION=0.1.0 2>&1)"; then
  if [ "$("$t11/space home/bin/fluxvale" --version)" = "fluxvale 0.1.0" ]; then
    ok "a space in the install path still runs the shim"
  else
    bad "shim broken with a space in the install path"
  fi
else
  bad "expected exit 0 for a space in the install path, got 1: $out"
fi

# --- shim-breaking characters refuse --------------------------------------------------

t12="$work/t12"
mkdir -p "$t12"
if out="$(run_installer "$t12" 'FLUXVALE_HOME=/tmp/br"oken' FLUXVALE_VERSION=0.1.0 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  if printf '%s\n' "$out" | grep -q "unsafe install path"; then
    ok "exit 1: a quote in the install path refuses"
  else
    bad "quote refusal is not the unsafe-path message: $out"
  fi
else
  bad "expected exit 1 for a quote in FLUXVALE_HOME, got 0"
fi

# --- a relative FLUXVALE_HOME resolves absolute ----------------------------------------

t13="$work/t13"
mkdir -p "$t13/cwd"
if out="$(cd "$t13/cwd" && env PATH="$fakebin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture" \
  FLUXVALE_HOME=relhome/fluxvale \
  FLUXVALE_BIN_DIR="$t13/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install_abs" 2>&1)"; then
  assert "a relative FLUXVALE_HOME installs under the cwd" test -x "$t13/cwd/relhome/fluxvale/versions/0.1.0/fluxvale"
  if grep -q 'exec "/' "$t13/bin/fluxvale"; then
    ok "the shim embeds an absolute path"
  else
    bad "shim does not embed an absolute path: $(cat "$t13/bin/fluxvale")"
  fi
else
  bad "expected exit 0 for a relative FLUXVALE_HOME, got 1: $out"
fi

# --- macOS Apple silicon maps to the macos-aarch64 leg ---------------------------------

uname_darwin="$work/bin-darwin"
make_fake_curl "$uname_darwin"
cat >"$uname_darwin/uname" <<'FAKE'
#!/bin/sh
case "$1" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'arm64\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
FAKE
chmod 755 "$uname_darwin/uname"
t14="$work/t14"
mkdir -p "$t14"
if out="$(env PATH="$uname_darwin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture" \
  FLUXVALE_HOME="$t14/fluxvale" \
  FLUXVALE_BIN_DIR="$t14/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.2.0 \
  sh "$install" 2>&1)"; then
  assert "Darwin arm64 installs the macos-aarch64 archive" test -x "$t14/fluxvale/versions/0.2.0/fluxvale"
  if printf '%s\n' "$out" | grep -q "macOS note"; then
    ok "the macOS quarantine note prints on Darwin"
  else
    bad "no macOS note on Darwin: $out"
  fi
else
  bad "expected exit 0 for Darwin arm64, got 1: $out"
fi

# --- Windows refuses with the manual-download pointer ------------------------------------

uname_mingw="$work/bin-mingw"
make_fake_curl "$uname_mingw"
cat >"$uname_mingw/uname" <<'FAKE'
#!/bin/sh
case "$1" in
  -s) printf 'MINGW64_NT-10.0-26100\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
FAKE
chmod 755 "$uname_mingw/uname"
t15="$work/t15"
mkdir -p "$t15"
if out="$(env PATH="$uname_mingw:$PATH" \
  FAKE_CURL_FIXTURE="$fixture" \
  FLUXVALE_HOME="$t15/fluxvale" \
  FLUXVALE_BIN_DIR="$t15/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install" 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  if printf '%s\n' "$out" | grep -q "Windows has no installer"; then
    ok "exit 1: Windows refuses with the manual-download pointer"
  else
    bad "Windows refusal is not the manual-download message: $out"
  fi
else
  bad "expected exit 1 for MINGW, got 0"
fi

# --- the default base URL is the release for the version --------------------------

fixture_log="$work/logged"
mkdir -p "$fixture_log"
cp "$fixture/fluxvale-0.1.0-linux-amd64.tar.gz" "$fixture_log/"
(cd "$fixture_log" && sha256sum fluxvale-0.1.0-linux-amd64.tar.gz >SHA256SUMS)
printf 'https://github.com/fluxvale/fluxvale/releases/tag/cli-v0.1.0\n' >"$fixture_log/redirect_url"
log_bin="$work/bin-log"
make_fake_curl "$log_bin"
t16="$work/t16"
mkdir -p "$t16"
if out="$(env PATH="$log_bin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture_log" \
  FLUXVALE_HOME="$t16/fluxvale" \
  FLUXVALE_BIN_DIR="$t16/bin" \
  sh "$install" 2>&1)"; then
  if grep -q "https://github.com/fluxvale/fluxvale/releases/download/cli-v0.1.0/fluxvale-0.1.0-linux-amd64.tar.gz" "$fixture_log/requested_urls.log"; then
    ok "the default base URL names the cli-v tag and the leg archive"
  else
    bad "default asset URL wrong: $(cat "$fixture_log/requested_urls.log")"
  fi
  if grep -q "https://github.com/fluxvale/fluxvale/releases/latest" "$fixture_log/requested_urls.log"; then
    ok "latest resolution asks releases/latest"
  else
    bad "no releases/latest request: $(cat "$fixture_log/requested_urls.log")"
  fi
else
  bad "expected exit 0 for the default-URL install, got 1: $out"
fi

# --- the narrowed prune keeps non-version dirs -------------------------------------

t17="$work/t17"
mkdir -p "$t17"
run_installer "$t17" FLUXVALE_VERSION=0.1.0 >/dev/null 2>&1
mkdir -p "$t17/fluxvale/versions/notes"
run_installer "$t17" FLUXVALE_VERSION=0.2.0 >/dev/null 2>&1
assert "a non-version dir in versions/ survives the prune" test -d "$t17/fluxvale/versions/notes"
count="$(version_count "$t17")"
if [ "$count" = 1 ]; then
  ok "the prune still leaves one installed version"
else
  bad "expected one version dir alongside the survivor, got $count"
fi

# --- a hostile cwd composes into the guard -------------------------------------------

t18="$work/t18"
mkdir -p "$t18/cwd/quo\"te"
if out="$(cd "$t18/cwd/quo\"te" && env PATH="$fakebin:$PATH" \
  FAKE_CURL_FIXTURE="$fixture" \
  FLUXVALE_HOME=relhome \
  FLUXVALE_BIN_DIR="$t18/bin" \
  FLUXVALE_RELEASE_BASE_URL="https://fixture.invalid/download" \
  FLUXVALE_VERSION=0.1.0 \
  sh "$install_abs" 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  if printf '%s\n' "$out" | grep -q "unsafe install path"; then
    ok "exit 1: a hostile cwd composes into the unsafe-path refusal"
  else
    bad "hostile-cwd refusal is not the unsafe-path message: $out"
  fi
else
  bad "expected exit 1 for a hostile cwd with a relative FLUXVALE_HOME, got 0"
fi

# --- . and .. are not versions ----------------------------------------------------------

t19="$work/t19"
mkdir -p "$t19"
if out="$(run_installer "$t19" FLUXVALE_VERSION=.. 2>&1)"; then got=0; else got=1; fi
if [ "$got" = 1 ]; then
  ok "exit 1: .. is refused as a version"
else
  bad "expected exit 1 for FLUXVALE_VERSION=.., got 0"
fi

echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
