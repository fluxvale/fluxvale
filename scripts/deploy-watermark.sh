#!/usr/bin/env bash
# The deployed watermark (#868): the newest commit that either env's
# /health reports serving — "deployed up to here". check-changes diffs
# main against it, so a platform change whose own run was cancelled or
# skipped still ships on the next trigger instead of waiting for the
# next platform push (docs/deployment.md).
#
# Contract: prints exactly one line to stdout — `base=<40-hex sha>`, or
# `base=` when no env reports a sha that is a commit at or below the
# commit under test (unreachable, a non-build version like "dev", a sha
# off main's line). Everything else goes to stderr. Exit 0 whenever the
# line is printed; exit 2 on a usage error.
#
# No credentials: two public GETs, the watch-deploy posture (ADR-0007).
set -euo pipefail

usage() {
  echo "usage: scripts/deploy-watermark.sh [--head <sha>] name=<health-url> [name=<health-url>…]" >&2
  echo "  e.g. scripts/deploy-watermark.sh staging=https://staging.fluxvale.com/health production=https://fluxvale.com/health" >&2
}

head_sha=""
envs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      [ -n "${2:-}" ] || { usage; exit 2; }
      head_sha="$2"
      shift 2
      ;;
    *=*)
      envs+=("$1")
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
[ "${#envs[@]}" -gt 0 ] || { usage; exit 2; }

# The commit under test: HEAD, or what the test drives through --head
# (an older tip, so "a sha that exists but sits above it" is reachable).
head_sha="$(git rev-parse --verify --quiet "${head_sha:-HEAD}^{commit}")" || {
  echo "::error::the commit under test is not a commit — run inside a checkout with history" >&2
  exit 1
}

# Prints the full sha when <url>'s /health reports `sha-<sha>` for a
# commit at or below the commit under test; prints nothing otherwise.
serving_sha() {
  local name="$1" url="$2" version sha
  # --retry 2: a transient 5xx or timeout on one env must not read as
  # "unresolved" on the very push that owes a deploy (exit 37/file errors
  # stay single-shot — not transient).
  version="$(curl -fsS --max-time 10 --retry 2 --retry-delay 2 "$url" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
  # A multi-line version must never echo ::…:: lines into the log — the
  # runner parses those as workflow commands, and JSON-escaped newlines
  # arrive real after jq unescapes them. Squash before echoing.
  version="${version//$'\n'/ }"
  version="${version//$'\r'/ }"
  sha="$(sed -nE 's/^sha-([0-9a-f]{7,40})$/\1/p' <<<"$version" | head -1)"
  if [ -z "$sha" ]; then
    echo "deployed watermark: $name reports ${version:-nothing} — not a build identity, ignored" >&2
    return 0
  fi
  sha="$(git rev-parse --verify --quiet "$sha^{commit}")" || {
    echo "deployed watermark: $name serves sha-$sha — no such commit here, ignored" >&2
    return 0
  }
  if ! git merge-base --is-ancestor "$sha" "$head_sha"; then
    echo "deployed watermark: $name serves sha-${sha:0:8} — above the commit under test, ignored" >&2
    return 0
  fi
  echo "deployed watermark: $name serves sha-${sha:0:8}" >&2
  echo "$sha"
}

candidates=()
for env in "${envs[@]}"; do
  sha="$(serving_sha "${env%%=*}" "${env#*=}")"
  if [ -n "$sha" ]; then candidates+=("$sha"); fi
done

# The newest: the candidate every other candidate descends from. main is
# linear (squash merges), so one exists; a divergent pair falls back to
# their common ancestor — the older, stricter read.
base=""
if [ "${#candidates[@]}" -eq 1 ]; then
  base="${candidates[0]}"
elif [ "${#candidates[@]}" -gt 1 ]; then
  for candidate in "${candidates[@]}"; do
    newest=true
    for other in "${candidates[@]}"; do
      if [ "$other" != "$candidate" ] && ! git merge-base --is-ancestor "$other" "$candidate"; then
        newest=false
      fi
    done
    if [ "$newest" = true ]; then
      base="$candidate"
      break
    fi
  done
  [ -n "$base" ] || base="$(git merge-base "${candidates[@]}")"
fi

if [ -n "$base" ]; then
  echo "deployed watermark: base=sha-${base:0:8}" >&2
else
  echo "::warning::deployed watermark unresolved — no env reports a sha at or below the commit under test; the per-push diff stands alone" >&2
fi
echo "base=$base"
