#!/usr/bin/env bash
# The release-tag gate (#362 T7): a `cli-v*` tag must carry exactly the
# version in cli/fluxvale-cli/Cargo.toml — the binary's version source
# (clap wires it into `--version`). A tag that disagrees with the shipped
# binary's self-report fails the release, so lazy tags can't ship.
#
# Usage: check-tag-version.sh cli-vX.Y.Z [cargo-toml-path]
#   The second arg overrides the Cargo.toml location — the test seam
#   for the no-version branch; the release workflow passes none.
# Exit 0 on match; 1 on mismatch, a foreign tag, or no version at all.
set -euo pipefail

tag="${1:?usage: check-tag-version.sh cli-vX.Y.Z [cargo-toml-path]}"

case "$tag" in
  cli-v*) version="${tag#cli-v}" ;;
  *)
    echo "not a CLI release tag: '$tag' (want cli-v<version>)" >&2
    exit 1
    ;;
esac

cargo_toml="${2:-$(cd "$(dirname "$0")/.." && pwd)/fluxvale-cli/Cargo.toml}"
# The first `version = "..."` at line start is the [package] table's —
# dependencies use inline tables, never a bare `version =` line.
cargo_version="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$cargo_toml" | head -1)"

if [ -z "$cargo_version" ]; then
  echo "no [package] version found in $cargo_toml" >&2
  exit 1
fi

if [ "$version" = "$cargo_version" ]; then
  echo "tag $tag matches Cargo.toml version $cargo_version"
else
  echo "tag $tag does not match the binary's version: Cargo.toml says $cargo_version — bump Cargo.toml (or re-tag) so the release name and \`fluxvale --version\` agree" >&2
  exit 1
fi
