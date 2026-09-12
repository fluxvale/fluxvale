---
name: fluxvale-review-budget
description: FluxVale CodeRabbit review-budget discipline — run before opening any PR (fresh-eyes subagent pass over the branch), before pushing to an open PR (one push per verdict cycle), and whenever CodeRabbit reports rate-limited (wait-once protocol). Harness-agnostic: the reviewer prompt is the deliverable, `pi -p` is one implementation.
---

# Review budget: spend CodeRabbit reviews deliberately

Issue #48 burned ~8 review-trigger events — 1 opening review, **5 auto-reviews
of mid-loop pushes**, and forced retries fired *inside* rate-limit
windows — for what needed ~3, and hit the limit four times in one day.
Every push to an open PR is an auto-review trigger under the default
config, and each invocation during a limit window deepens it. The rules
below are the fix; the `.coderabbit.yaml` half (merged in #50) is the
enforcement, this skill is the behavior.

## 1. The pre-PR fresh-eyes pass — the cheap reviewer

Before the **first push** of a branch, get a second, fresh context to
review it adversarially. Fresh context matters: the implementing agent
reviews its own reasoning, not its own code.

**The prompt is the deliverable** — any harness works. Spawn a subagent /
second session running, from the worktree root:

```text
You are a hostile senior reviewer with fresh eyes. This repo is an
Elixir/Phoenix/Ash monorepo (apps/platform). Review the current branch:
run 'git diff main' and read the changed files in full. Hunt:
(1) moduledoc/comment claims that the code contradicts,
(2) untested branches in changed files,
(3) race conditions and security edges,
(4) anything a CHILL-profile bot reviewer would skip.
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

## 2. One push per verdict cycle

The default config auto-reviews every push. So:

- Implementation + fresh-eyes fixes + `mix ci` green all land
  **locally first**; **one push** opens the PR → one opening review.
- After a CodeRabbit verdict: address **all** findings in **one**
  commit/push → at most one re-review.
- Never push mid-review-cycle; never push "just the typo" separately.
  A branch's commit structure is throwaway — we squash-merge.

## 3. Config reality (`.coderabbit.yaml`, #50)

- `auto_pause_after_reviewed_commits: 1` — the bot reviews the opening
  state, then pauses automatic incremental reviews. The post-fix pass
  is requested explicitly: `@coderabbitai review` in a PR comment.
- `!**/priv/resource_snapshots/**` filtered (ash codegen noise).
- **`docs/` deliberately NOT filtered** — path_filters shape the bot's
  clone, and its review context must keep the ADRs ("everything why
  lives in docs/"). Docs-only PRs do get reviewed; that's the accepted
  cost.
- **Draft PRs are skipped entirely by default — and that's the lever
  for a low bucket.** Opening reviews are unsuppressible, and every PR
  in the org draws from the same replenishing window (#52 opened into
  an empty bucket drained by #48's burn plus #50's review the same
  day). When recent activity has the bucket low: open as **draft**
  (costs nothing), flip to ready when capacity returns — the opening
  review fires on ready-for-review, not on push. A draft is also the
  free-iteration window for a PR known to churn.

## 4. When rate-limited: wait once, invoke once

Read the window from the bot's "Review limit reached" comment ("Next
included review available in N minutes"), wait it out, then a **single**
`@coderabbitai review`. Never retry-loop inside the window — #48's
evidence is that retries deepen it. The invocation ack ("Review
triggered") is not the verdict: confirm the check reads
`Review completed` and probe the summary comment's walkthrough marker
(`sourceCommitId … "kind":"reviewed"`) to verify the newest commit was
actually covered.
