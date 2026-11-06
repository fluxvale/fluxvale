#!/bin/sh
# The release-body composer (#480): the matching `## [<version>]`
# section of cli/CHANGELOG.md plus the static install + sign-in primer.
# cli-release.yml's publish job runs this; test-release-notes.sh keeps
# it honest, and it lives here so shellcheck reaches it.
#
# Usage: release-notes.sh <version> [output-path]
#   The version comes off the cli-v* tag (check-tag-version.sh has
#   already asserted it equals Cargo.toml). Exit 1 when the section is
#   missing or the version is malformed — a release without its
#   changelog section does not publish.
set -eu

version="${1:?usage: release-notes.sh <version> [output-path]}"
if [ "$#" -ge 2 ]; then
  exec >"$2"
fi

# The same grammar guard the release workflow applies: URL- and
# path-safe characters only. The version goes into the notes heading.
case "$version" in
  "") echo "release version is empty" >&2; exit 1 ;;
  *[!0-9A-Za-z.+-]*) echo "release version '$version' has characters outside Cargo's grammar" >&2; exit 1 ;;
esac

# The section for this version: from its `## [version] - date` header
# to the next `## [` (or EOF). index() matches the header prefix
# without regex-escaping the version, and the tail check keeps 0.1.0
# from matching 0.1.0-rc1.
section="$(awk -v want="## [$version]" '
  index($0, want) == 1 {
    rest = substr($0, length(want) + 1)
    if (rest == "" || rest ~ /^ -/) { on = 1; next }
  }
  on && /^## \[/ { exit }
  on { print }
' "$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md")"

if [ -z "$section" ]; then
  echo "cli/CHANGELOG.md has no ## [$version] section. Write it before tagging." >&2
  exit 1
fi

# The static half: what the CLI is, how to install it, how to sign in.
# User-facing copy, so no em-dashes, no semicolons.
cat <<'HEAD'
The **FluxVale CLI**. Install apps from the catalog and manage your instances, backups, access, and wallet from the command line. A single self-contained binary, no language runtime to install.

## Install

```sh
curl -fsSL https://github.com/fluxvale/fluxvale/releases/latest/download/install.sh | sh
```

Installs into `~/.local/share/fluxvale`, puts a `fluxvale` shim in `~/.local/bin`, verifies the sha256 before extracting, and prunes the previous version on upgrade. Pin a version with `FLUXVALE_VERSION=<version>`. Re-running the line upgrades in place.

**Sign in** (the device flow):

```
fluxvale auth login     # prints a code and opens the approval page
                        # compare the code, click Approve
                        # the token lands in your OS keychain, done
```

Then `fluxvale apps list`, `fluxvale instances deploy --app <slug>`, and you are running.

Prefer to unpack by hand? The archives below are the same bits the installer fetches. Verify your download against `SHA256SUMS` (unix):

```
grep <your-archive> SHA256SUMS | sha256sum -c -
```

On Windows: `certutil -hashfile <your-archive> SHA256` and compare by eye.
HEAD

printf '\n## What changed in %s\n\n' "$version"
printf '%s\n' "$section"
