#!/bin/sh
# FluxVale CLI installer — https://github.com/fluxvale/fluxvale
#
#   curl -fsSL https://github.com/fluxvale/fluxvale/releases/latest/download/install.sh | sh
#
# Installs a release archive into a versioned directory and puts a
# `fluxvale` shim on PATH. No root, no package manager. House pattern:
# dashfloat's installer, adapted to this repo's release assets
# (ADR-0019 Am. 3 — GitHub Releases is the distribution).
#
# Environment:
#   FLUXVALE_VERSION            install this version instead of the latest
#   FLUXVALE_HOME               install dir (default ${XDG_DATA_HOME:-$HOME/.local/share}/fluxvale)
#   FLUXVALE_BIN_DIR            shim dir (default $HOME/.local/bin)
#   FLUXVALE_RELEASE_BASE_URL   asset base URL (default: the GitHub release for the version)
#   FLUXVALE_REPO               GitHub repo (default fluxvale/fluxvale)
#
# Requires curl. The archive's sha256 is verified against the release's
# SHA256SUMS before anything is extracted. Re-running it upgrades in place
# and removes every other installed version. Windows has no installer:
# download windows-x86_64.zip from the release page and put fluxvale.exe
# on your PATH.

set -eu

REPO="${FLUXVALE_REPO:-fluxvale/fluxvale}"
REQUESTED_VERSION="${FLUXVALE_VERSION:-}"

# DATA_HOME: XDG first, then HOME, both possibly absent. A HOME-less
# host with no FLUXVALE_HOME gets an honest refusal, not a crash.
DATA_HOME="${XDG_DATA_HOME:-}"
if [ -z "$DATA_HOME" ]; then
  if [ -z "${HOME:-}" ]; then
    printf 'fluxvale: neither XDG_DATA_HOME nor HOME is set. Set FLUXVALE_HOME to pick an install dir.\n' >&2
    exit 1
  fi
  DATA_HOME="$HOME/.local/share"
fi
HOME_DIR="${FLUXVALE_HOME:-$DATA_HOME/fluxvale}"
BIN_DIR="${FLUXVALE_BIN_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'fluxvale: %s\n' "$*" >&2; exit 1; }

# The shim embeds HOME_DIR and BIN_DIR verbatim inside double quotes, so
# a double quote, dollar sign, backtick, or control character in either
# would break it. Spaces are fine. A relative path would resolve against
# whatever directory the shim runs from, so both are absolutized.
check_install_path() {
  case "$1" in
    *'"'* | *'$'* | *'`'* | *[[:cntrl:]]*)
      die "unsafe install path: $1. Double quotes, dollar signs, backticks, and control characters are not supported."
      ;;
  esac
}
absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${PWD:?}/$1" ;;
  esac
}

# --- platform -------------------------------------------------------------

# The archive names come from cli-release.yml's build matrix legs, not
# from Rust target triples: fluxvale-<version>-<leg>.tar.gz.
detect_target() {
  os=$(uname -s 2>/dev/null || true)
  arch=$(uname -m 2>/dev/null || true)

  case "$os" in
    Linux)
      # The release is a glibc build (ubuntu runners). On musl the binary
      # fails at exec time with a message that names nothing, so refuse
      # here instead, honestly.
      if ldd --version 2>&1 | grep -qi musl; then
        die "this is a musl system (Alpine?). The CLI ships a glibc build and does not run on musl yet."
      fi

      case "$arch" in
        x86_64 | amd64) printf '%s\n' "linux-amd64" ;;
        aarch64 | arm64) printf '%s\n' "linux-aarch64" ;;
        *) die "unsupported Linux architecture: $arch. The CLI ships linux-amd64 and linux-aarch64." ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64) printf '%s\n' "macos-aarch64" ;;
        x86_64) die "unsupported macOS architecture: $arch. The CLI ships Apple silicon (macos-aarch64) only." ;;
        *) die "unsupported macOS architecture: $arch" ;;
      esac
      ;;
    MINGW* | MSYS* | CYGWIN*)
      die "Windows has no installer. Download windows-x86_64.zip from https://github.com/$REPO/releases and put fluxvale.exe on your PATH."
      ;;
    *)
      die "unsupported operating system: $os. The CLI ships Linux amd64/arm64 and macOS Apple silicon. Windows: download the zip from the release page."
      ;;
  esac
}

# --- version --------------------------------------------------------------

resolve_version() {
  if [ -n "$REQUESTED_VERSION" ]; then
    printf '%s\n' "${REQUESTED_VERSION#v}"
    return 0
  fi

  url=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)

  # Only the CLI's namespaced tags (cli-v*) are CLI releases; anything
  # else at releases/latest is not ours to install.
  case "$url" in
    */tag/cli-v*) printf '%s\n' "${url##*/tag/cli-v}" ;;
    *) die "could not resolve the latest CLI release. Set FLUXVALE_VERSION to pick one, e.g. FLUXVALE_VERSION=0.1.0" ;;
  esac
}

# The same grammar guard the release workflow applies to the tag version:
# URL- and path-safe characters only. The real grammar policy lives in
# Cargo.toml, enforced by cli/scripts/check-tag-version.sh at release
# time.
check_version() {
  if [ -z "$1" ]; then
    die "invalid version: (empty)"
  fi
  case "$1" in
    . | ..) die "invalid version: $1" ;;
    *[!0-9A-Za-z.+-]*) die "invalid version: $1" ;;
  esac
}

# --- download + verify ----------------------------------------------------

proto_for() {
  case "$1" in
    http://*) printf '%s\n' "=https,http" ;;
    *) printf '%s\n' "=https" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "no sha256 tool found (need sha256sum or shasum)"
  fi
}

expected_sum() {
  awk -v asset="$2" '
    {
      name = $2
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      if (name == asset) { print $1; exit }
    }
  ' "$1"
}

# --- install --------------------------------------------------------------

HOME_DIR="$(absolute "$HOME_DIR")"
BIN_DIR="$(absolute "$BIN_DIR")"

# The guard runs AFTER absolutization: a relative FLUXVALE_HOME under a
# cwd with a hostile name composes into the shim line just as surely as
# a hostile FLUXVALE_HOME would.
check_install_path "$HOME_DIR"
check_install_path "$BIN_DIR"

target=$(detect_target)
[ -n "$target" ] || die "could not detect this platform"

command -v curl >/dev/null 2>&1 || die "curl is required"

version=$(resolve_version)
check_version "$version"

base_url="${FLUXVALE_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download/cli-v$version}"
asset="fluxvale-$version-$target.tar.gz"
sums="SHA256SUMS"
proto=$(proto_for "$base_url")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fluxvale.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

say "Downloading fluxvale $version ($target)..."
curl -fsSL --retry 3 --proto "$proto" -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL --retry 3 --proto "$proto" -o "$tmp/$sums" "$base_url/$sums"

expected=$(expected_sum "$tmp/$sums" "$asset")
[ -n "$expected" ] || die "no checksum for $asset in $sums"

actual=$(sha256_of "$tmp/$asset")
if [ "$actual" != "$expected" ]; then
  die "checksum mismatch for $asset
  expected: $expected
  actual:   $actual
Refusing to install."
fi

versions_dir="$HOME_DIR/versions"
target_dir="$versions_dir/$version"
staging="$target_dir.tmp.$$"

rm -rf "$staging"
mkdir -p "$staging"
tar -xzf "$tmp/$asset" -C "$staging"

# The archive holds one stage dir, fluxvale-<version>-<leg>/, with the
# binary at its top (cli-release.yml's archive step).
[ -x "$staging/fluxvale-$version-$target/fluxvale" ] || die "archive did not contain fluxvale-$version-$target/fluxvale"

mkdir -p "$versions_dir"
rm -rf "$target_dir"
mv "$staging/fluxvale-$version-$target" "$target_dir"
rm -rf "$staging"
ln -sfn "$target_dir" "$HOME_DIR/current"

# Prune on upgrade: one version on disk, so an old binary is never left
# behind. Re-installing is seconds; rollback is a re-install. Everything
# digit-led in versions/ is an install or a crashed staging dir (both
# prunable); anything else is not ours, so it stays.
for dir in "$versions_dir"/*; do
  [ -d "$dir" ] || continue
  case "${dir##*/}" in
    [0-9]*) ;;
    *) continue ;;
  esac
  if [ "$dir" = "$target_dir" ]; then
    continue
  fi
  rm -rf "$dir"
done

mkdir -p "$BIN_DIR"
printf '#!/bin/sh\nexec "%s/current/fluxvale" "$@"\n' "$HOME_DIR" >"$BIN_DIR/fluxvale"
chmod 755 "$BIN_DIR/fluxvale"

# The point of the shim and the versioned dir: prove the installed
# artifact actually runs on this host before claiming success.
if ! installed=$("$target_dir/fluxvale" --version 2>&1); then
  printf '%s\n' "$installed" >&2
  die "installed, but the binary failed to run on this host.
The error above names what is missing (Linux builds link glibc)."
fi

# stderr noise (locale warnings and the like) is not a failed install.
installed=$(printf '%s\n' "$installed" | grep -E '^fluxvale ' | head -1)
[ -n "$installed" ] || installed="fluxvale $version"

say ""
say "$installed installed."
say ""
say "  binary: $BIN_DIR/fluxvale"
say "  install dir: $HOME_DIR"

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "$BIN_DIR is not on PATH. Add it to your shell profile:"
    say ""
    say "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

if [ "$(uname -s)" = "Darwin" ]; then
  say ""
  say "macOS note: this build is not notarized. A copy downloaded with a"
  say "browser is quarantined and macOS refuses it on first launch."
  say "Right-click the binary in Finder and choose Open once to clear it."
  say "Installing with curl sets no quarantine flag."
fi
