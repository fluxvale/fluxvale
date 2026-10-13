---
name: fluxvale-review-budget
description: "FluxVale CodeRabbit discipline — one review per PR (#59): fresh-eyes pass and mix ci green before the PR opens; ensure exactly one review runs (probe the walkthrough marker; one @coderabbitai review only if HEAD is unreviewed); when the bucket is rate-limited, a hostile agent review substitutes and the merge doesn't wait; never re-review — the maintainer verifies fixes. Harness-agnostic: the reviewer prompt is the deliverable, `pi -p` is one implementation."
---

# Review budget: one CodeRabbit review per PR

Public repo, 0 stars, one PR identity: the OSS tier gives ~1 review/hour
per developer per repo (docs.coderabbit.ai/management/plans). So one
review per PR, spent on a finished branch. A rate-limited attempt costs
nothing and doesn't delay the next slot.

## 1. Before the PR

Implementation done, `mix ci` green, then a **fresh-eyes subagent pass**
over the diff — fresh context reviews the code, not the author's
reasoning. Load-bearing: there is no second bot pass.

The prompt is the deliverable; any harness works (`pi -p "<prompt>"`
from the worktree root is one — `-p` mode skips project resources
under default trust, so the prompt is self-contained; don't pass
`--approve` casually). With no second context at all, do the pass
yourself against the diff only — degraded, better than nothing.
Run from the worktree root:

```text
You are a hostile senior reviewer with fresh eyes. Review the current
branch: run 'git diff main' and read the changed files in full. This
repo is an Elixir/Phoenix/Ash monorepo; for changed app code
(apps/platform), hunt:
(1) moduledoc/comment claims that the code contradicts,
(2) untested branches in changed files,
(3) race conditions and security edges,
(4) anything a CHILL-profile bot reviewer would skip.
For docs/, skills, CI, scripts, or config files in the diff — alone
or alongside code — also hunt: claims the referenced code or config
contradicts, malformed frontmatter/YAML, stale references (files,
paths, issues that don't exist), internal inconsistencies, walls of
text a time-pressed human wouldn't write, and load-bearing points
buried mid-paragraph (#61 — write for a short-attention-span reader).
Output findings as file:line + one-paragraph justification; say 'clean'
if none.
```

Verify every finding against ground truth before adopting — fresh eyes
hallucinate too.

## 2. One review per PR

- Open the PR only when the branch needs nothing but a verdict.
- Probe the summary comment's walkthrough marker (`sourceCommitId …
  "kind":"reviewed"`). If it covers HEAD, the review ran — #60
  auto-fired at open. An absent marker with the CodeRabbit check
  reading "Review in progress" means it is running — wait it out
  (triggering now spends a second review; #62 finding). Only when
  neither, spend the single `@coderabbitai review` (#52's regime);
  check `@coderabbitai rate limit` first (a PR comment; free) if the
  bucket may be low. The ack ("Review triggered") is not the verdict —
  confirm the check reads `Review completed` and the marker covers HEAD.
- Rate-limited bucket ≠ waiting. The CodeRabbit check reports `pass`
  when rate-limited (observed on #134), so branch protection never
  blocks on the missing review — and the PR may merge on the agent
  review + green CI once the maintainer verifies. The substitute is
  the section-1 hostile pass over the PR diff (re-run only if pushes
  landed since the pre-PR pass), under any harness — the working
  session's subagent runner, or standalone (`pi -p` is one) when no
  session is alive. Findings are addressed as if they were the bot's.
  If the bot review fires later while the PR is still open, it's a
  bonus pass, not a blocker; a PR merged without the bot review never
  spends the bucket.
- After the verdict: adopt or rebut in-thread, push fixes as one
  commit, **no re-review** — the maintainer verifies (#59).
- Never push mid-review-cycle; branch history is throwaway (squash
  merge).

## 3. Config (`.coderabbit.yaml`)

- `auto_incremental_review: false` — no auto-re-reviews on pushes
  (supersedes #50's `auto_pause_after_reviewed_commits: 1`).
- `!**/priv/resource_snapshots/**` filtered — ash codegen noise.
- `docs/` NOT filtered — path_filters shape the bot's sparse-checkout;
  its review context must keep the ADRs.
- Draft-while-rate-limited is superseded by §2's agent fallback — a
  rate-limited PR no longer waits for capacity. Drafts still skip the
  auto-review at open, so keep a PR draft only while it's genuinely
  not finished.
