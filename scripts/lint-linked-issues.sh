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
# Margins, documented rather than papered over with heuristics:
#   * The closing keyword and the slice language are not required to name the
#     same issue — `Closes #98 … / separately, slice 1 of 2 for #100 follows`
#     fires even though the slice language is about another issue. Only two
#     issues named in one body has never happened in history; correlating them
#     is a parser, not a lint.
#   * The match is body-wide rather than first-line-only (measured: identical
#     result either way).
#   * `slice 10 of 9` passes: N > M reads as "complete", so a typo'd total
#     slips through. Same direction as the N < M choice — it lets a PR past
#     rather than failing one on arithmetic the lint cannot check.
#   * `Closes <full issue URL>` passes. GitHub's documented closing syntax is
#     `KEYWORD #N` and `KEYWORD owner/repo#N` only; if GitHub ever closes on
#     a URL, this is the hole. Not verified against GitHub, said out loud
#     rather than assumed.
#
# Measured over the 152 merged PR bodies as of 2026-10-27: exactly two hits,
# #62 and #269 — both real incidents, so 85 of the 87 bodies carrying a
# closing keyword pass.
#
# Interface: `scripts/lint-linked-issues.sh [FILE]` — a path, `-`, or no
# argument (stdin). CI pipes `${{ github.event.pull_request.body }}` in; a
# local run points it at a saved body. Exit 0 passes, 1 fires, 2 is a usage
# or input error (never a silent pass).
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

body = File.binread(ARGV[0]).force_encoding("UTF-8")

# A body that is not UTF-8 is bad input, not a lint hit: exit 2 so a local
# run against the wrong file (a binary, a wrong path) cannot read as a
# verdict on the PR. The CI payload is always UTF-8.
unless body.valid_encoding?
  warn "cannot read #{ARGV[0]} as UTF-8 — is that a PR body?"
  exit 2
end

# Drop fenced blocks line-wise. A closing fence must match its opener's
# character and be at least as long (CommonMark): a ``` block containing a
# ~~~ line keeps going, because that ~~~ is content, not a fence. An
# unterminated fence hides the rest of the body rather than leaking half a
# code sample into the match.
fence = nil
prose = body.each_line.reject do |line|
  run = line[/\A[[:space:]]*(`{3,}|~{3,})/, 1]
  if run
    if fence.nil?
      fence = run
      true
    elsif run[0] == fence[0] && run.length >= fence.length
      fence = nil
      true
    else
      true   # a fence-ish line of the wrong character/length is content
    end
  else
    !fence.nil?
  end
end.join

# HTML comments: markers AND contents. CodeRabbit brackets its summary with
# them, but the summary text itself sits between the markers and is machine
# written, so strip the whole span. An UNCLOSED comment strips from the
# opener to the end of the body — an unclosed comment is not prose either,
# and the alternative (leaving it matchable) fails a body quoting an old one.
prose = prose.gsub(/<!--.*?(?:-->|\z)/m, "")

# Inline code spans, including GFM's multi-line ones (a backtick run closed
# by an equal-length run, newlines allowed).
prose = prose.gsub(/(`+)(?:(?!\1).)+?\1/m, "")

# `.match`/`.scan`, not `prose[RE]`: String#[] with a Regexp hands back the
# matched text, so `slice[1]` would be a character of it, not the capture.
#
# EVERY slice count is checked, not just the first: a body can say
# `Closes #7 (slice 3 of 3)` and later mention `slice 1 of 4` of the same
# issue, and the first match being complete must not exonerate the body.
# Any incomplete count fires, and the diagnostic names the one that fired.
closing = prose.match(CLOSING)
slice = prose.to_enum(:scan, SLICE).map { Regexp.last_match }
              .find { |m| m[1].to_i < m[2].to_i }

# `slice` is the incomplete count if any was found (see the scan above).
unless closing && slice
  puts "Linked issues consistent (no closing keyword on an incomplete slice)"
  exit 0
end

issue = closing[1]
warn "::error title=Closing keyword on a slice PR::" \
     "this body closes ##{issue} and calls itself \"#{slice[0]}\" — reference the issue " \
     "without the closing keyword (`Refs ##{issue}` or `Part of ##{issue}`) so it stays " \
     "open until the last slice lands."
# Squash whitespace: a keyword split across a newline ("Closes⏎#61") is a
# legitimate match, but its raw text would break the diagnostic across lines.
warn "  closing keyword: #{closing[0].gsub(/\s+/, ' ')}"
warn "  slice language:  #{slice[0].gsub(/\s+/, ' ')}"
warn "  AGENTS.md: \"slice PRs of an umbrella issue reference it without a closing keyword\""
exit 1
RUBY
exit "$status"
