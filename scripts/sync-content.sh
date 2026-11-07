#!/usr/bin/env bash
# Sync the authored content trees into the platform app's priv (ADR-0044).
#
# The centralized content home is docs/ — two servable subtrees, both
# authored in the repo root and both served from synced, gitignored
# priv copies by the same channel the loaders read:
#
#   docs/public  ->  apps/platform/priv/content/docs
#   docs/blog    ->  apps/platform/priv/content/blog   (ADR-00025 §1)
#
# One source of truth: the priv copies are generated output and never
# commit (apps/platform/.gitignore).
#
# Callers: `mix content.sync` (the test/setup alias chains run it so
# tests always carry fresh content), the CI release-image job and the
# e2e bootstrap (both docker-build with context=apps/platform, so the
# gitignored priv copies must exist on the host before docker build),
# and the Tiltfile (same reason, dev image).
#
# Idempotent: rsync --delete mirrors each source exactly, so a removed
# page never lingers in priv. Fails loudly if a source tree is
# missing — a silent no-op would ship an image with empty content.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sync_tree() {
  local src="$1" dest="$2"

  if [ ! -d "$src" ]; then
    echo "::error::$src not found — the content source tree is required (ADR-0044)" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"
  rsync -a --delete "$src"/ "$dest"/

  echo "synced ${src#"$root"/} -> ${dest#"$root"/} ($(find "$dest" -name '*.md' | wc -l) pages)"
}

sync_tree "$root/docs/public" "$root/apps/platform/priv/content/docs"
sync_tree "$root/docs/blog" "$root/apps/platform/priv/content/blog"
