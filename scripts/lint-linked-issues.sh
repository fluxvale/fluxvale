#!/usr/bin/env bash
# Linked-issues lint: a PR body that CLOSES an issue while declaring itself
# an incomplete slice of it (`Closes #N (slice 1 of 4 …)`) closes the issue
# on merge, before the rest of the slices exist. The rule is in AGENTS.md
# twice ("slice PRs of an umbrella issue reference it without a closing
# keyword"; "`Closes #N` only when it completes the issue") and prose did
# not hold it: #62 said `Closes #61 (slice 1 of 7)` and #61 was reopened 15
# seconds after the merge; #269 said `Closes #268 (slice 1 of 4 — the ADR;
# code PRs follow)` and #268 closed with three of its six scope items
# unbuilt. Both went through a green pipeline — nothing read the body.
#
# The parenthetical is the problem, and it is *good writing*: the author is
# being accurate and helpful exactly where the mechanical side effect fires.
# So this lint only checks the mechanical half: both a closing keyword bound
# to `#N` and incomplete-slice language ("slice|part N of M"). Whether the
# issue's exit criteria were actually met stays a human call.
#
# Precision over recall, deliberately — a false positive teaches authors to
# distrust the guard, which is worse than a miss:
#   * The slice number must be BELOW the total (`slice 1 of 4`, not `2 of 2`).
#     This is future-proofing, not a history fix: on all 152 merged bodies
#     this rule and the blunt "any N of M" rule score identically (2 hits).
#     It exists so a legitimate final slice — `Closes #N (slice 3 of 3)` —
#     is not failed by a check that cannot know the slice is the last one.
#     It errs toward letting a real PR through, which is the right direction.
#   * #108 is the near-miss this guards: it reads `Closes #98 (the closing
#     slice — slice 1 was the release image …)`. It talks about slices but
#     carries no `slice N of M`, so it passes — under this rule and the blunt
#     one alike (fixture pr-108.md).
#   * Code is not prose: fenced blocks, inline code spans and HTML comments
#     are dropped before matching. A PR that documents this rule quotes the
#     incident bodies verbatim, and the CodeRabbit summary block at the
#     bottom of every body is machine-written.
#
# Margins, documented rather than papered over with heuristics: the closing
# keyword and the slice language are not required to name the same issue
# (no body in history names two), and the match is body-wide rather than
# first-line-only (measured: identical result either way).
#
# Measured over the 152 merged PR bodies as of 2026-10-27: exactly two hits,
# #62 and #269, and none of the 87 bodies carrying a closing keyword.
#
# Interface: `scripts/lint-linked-issues.sh [FILE]` — a path, `-`, or no
# argument (stdin). CI pipes `${{ github.event.pull_request.body }}` in; a
# local run points it at a saved body.
set -euo pipefail
cd "$(dirname "$0")/.."

# The ruby program arrives on stdin as a heredoc, so a body arriving on
# stdin too has to be spooled to a file first — otherwise ruby reads its own
# source as the body and passes everything. (It did, twice, while this was
# being written.)
target="${1:--}"
if [[ "$target" == "-" ]]; then
  target="$(mktemp)"
  trap 'rm -f "$target"' EXIT
  cat >"$target"
fi

[[ -f "$target" ]] || {
  echo "usage: scripts/lint-linked-issues.sh [FILE|-]  (no such file: ${1:--})" >&2
  exit 2
}

status=0
ruby - "$target" <<'RUBY' || status=$?
# Closing keyword bound to an issue: `Closes #12`, `fix: #12`, `Fixes
# owner/repo#12`. Not /x mode — a bare `#` in an extended regex starts a
# comment, which is how the first draft of this file broke.
CLOSING = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s*(?:[\w.-]+\/[\w.-]+)?#(\d+)/i

# "slice 1 of 4", "part 2a of 3" — capture both numbers so the lint can tell
# an incomplete slice from a closing one.
SLICE = /\b(?:slice|part)s?\s+(\d+)[a-z]?\s+of\s+(\d+)/i

body = File.read(ARGV[0])

# Drop fenced blocks line-wise: an unterminated fence hides the rest of the
# body rather than leaking half a code sample into the match.
in_fence = false
prose = body.each_line.reject do |line|
  if line.match?(/\A[[:space:]]*(?:```|~~~)/)
    in_fence = !in_fence
    true
  else
    in_fence
  end
end.join

prose = prose.gsub(/<!--.*?-->/m, "")   # CodeRabbit's summary block lives here
prose = prose.gsub(/`[^`\n]*`/, "")     # inline code spans

# `.match`, not `prose[RE]`: String#[] with a Regexp hands back the matched
# text, so `slice[1]` would be a character of it, not the capture.
closing = prose.match(CLOSING)
slice = prose.match(SLICE)
incomplete = slice && slice[1].to_i < slice[2].to_i

unless closing && incomplete
  puts "Linked issues consistent (no closing keyword on an incomplete slice)"
  exit 0
end

issue = closing[1]
warn "::error title=Closing keyword on a slice PR::" \
     "this body closes ##{issue} and calls itself \"#{slice[0]}\" — reference the issue " \
     "without the closing keyword (`Refs ##{issue}` or `Part of ##{issue}`) so it stays " \
     "open until the last slice lands."
warn "  closing keyword: #{closing[0]}"
warn "  slice language:  #{slice[0]}"
warn "  AGENTS.md: \"slice PRs of an umbrella issue reference it without a closing keyword\""
exit 1
RUBY
exit "$status"
