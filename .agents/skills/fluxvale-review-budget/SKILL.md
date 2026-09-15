---
name: fluxvale-review-budget
description: "FluxVale CodeRabbit review-budget discipline — one review per PR (#59): run the fresh-eyes subagent pass and reach final branch quality BEFORE opening the PR, then obtain the single review with one @coderabbitai review (checking capacity first with @coderabbitai rate limit when the bucket may be low); never request a re-review. Harness-agnostic: the reviewer prompt is the deliverable, `pi -p` is one implementation."
---

# Review budget: one CodeRabbit review per PR

The repo is public at 0 stars and every PR is authored by one identity,
so the whole org draws from CodeRabbit's smallest bucket: the OSS tier
at ~1 review/hour per developer per repository, and — under 10 stars —
reviews must be **triggered manually**; nothing reviews automatically
(docs.coderabbit.ai/management/plans). #48
burned ~8 review-trigger events for what needed ~3 and hit the limit
four times in one day; #50 (#49) stopped the auto-review burn; #59
removes re-reviews entirely: **one review per PR, spent on a
finished branch**. Current docs also correct #48's model of the
window: a rate-limited attempt costs nothing and does not delay the
next slot — a full window is full of *earlier delivered* reviews, not
failed retries.

## 1. Before the PR: the branch is final quality

The single review must land on a finished branch, so everything cheap
happens first, locally: implementation complete, `mix ci` green, and a
**fresh-eyes subagent pass** over the diff — fresh context matters:
the implementing agent reviews its own reasoning, not its own code.
This pass is now load-bearing: there is no second bot pass to catch
what it misses.

**The prompt is the deliverable** — any harness works. Spawn a subagent /
second session running, from the worktree root:

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
paths, issues that don't exist), and internal inconsistencies.
Output findings as file:line + one-paragraph justification; say 'clean'
if none.
```

Reference implementations:

- **pi**: `pi -p "<prompt>"` from the worktree root (non-interactive
  print mode; `2>&1 | tail -80` for long outputs). NB: `-p` mode does
  not load project resources under default trust — the prompt above is
  self-contained on purpose. Don't pass `--approve` casually.
- **Other harnesses**: any "spawn subagent / new session" facility, or
  plainly a second agent instance in another terminal. If no second
  context is available at all, do the pass yourself against the diff
  only — degraded, better than nothing.

Verify every finding against ground truth before adopting — fresh eyes
still hallucinate (same adopt-or-rebut-with-evidence protocol as
CodeRabbit findings). **Proven on its first run** (#50): the pass caught
that CodeRabbit `path_filters` also drive the bot's sparse-checkout —
filtering `docs/` would have deleted the ADR corpus from the bot's
clone on every PR.

## 2. One review per PR — obtained once, never repeated

- The PR opens only when the branch needs nothing but a verdict:
  implementation + fresh-eyes fixes + `mix ci` green all landed
  **locally first**.
- **Obtain the review with a single `@coderabbitai review`** — at 0
  stars nothing fires on open, push, or ready-for-review, so this
  trigger *is* the review. If the bucket may be low, check capacity
  first with `@coderabbitai rate limit` (a PR comment; costs nothing).
- After the verdict: adopt or rebut every finding in-thread as usual,
  then push adopted fixes as one commit **without requesting a
  re-review** — the maintainer verifies them (the accepted trade-off
  of #59). A second `@coderabbitai review` on the same PR is a bug in
  the loop, not a step.
- Never push mid-review-cycle; never push "just the typo" separately.
  A branch's commit structure is throwaway — we squash-merge.

## 3. Config reality (`.coderabbit.yaml`, #59)

- `auto_incremental_review: false` — pushes are never auto-re-reviewed.
  Today (0 stars) nothing auto-reviews at all; the key guards the
  policy for when the repo gains stars or a trial and automatic
  reviews become possible. (Supersedes #50's
  `auto_pause_after_reviewed_commits: 1`.)
- `!**/priv/resource_snapshots/**` filtered (ash codegen noise).
- **`docs/` deliberately NOT filtered** — path_filters shape the bot's
  clone, and its review context must keep the ADRs ("everything why
  lives in docs/"). Docs-only PRs do get reviewed; that's the accepted
  cost.
- **Draft PRs are skipped by default — that's the capacity lever.**
  A draft delays spending the review until you're ready to trigger it:
  open as draft while the bucket is low (#52 opened into a bucket
  drained the same day), flip to ready and spend the single
  `@coderabbitai review` once `@coderabbitai rate limit` reports
  capacity. A draft is also the free-iteration window for a PR known
  to churn.

## 4. If the one trigger is rate-limited: wait once, re-invoke once

If the single `@coderabbitai review` comes back "Review rate limited",
read the window from the bot's comment ("Next included review
available in N minutes"), wait it out, then trigger **once more** —
that is the sanctioned retry, and the only one. A blocked attempt
costs nothing and doesn't delay the next slot — but a retry inside
the window is still pure noise, so don't. The invocation ack ("Review
triggered") is not the verdict: confirm the check reads
`Review completed` and probe the summary comment's walkthrough marker
(`sourceCommitId … "kind":"reviewed"`) to verify the newest commit was
actually covered.
