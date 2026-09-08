---
name: fluxvale-pr-drift
description: FluxVale PR-conflict sweep and rebase workflow — run when any merge lands on main (agent- or maintainer-driven), at session start, or when an open PR reports CONFLICTING. Covers the mergeability sweep, rebasing with a convention-drift check against the new main commits, and repo mechanics (mix run script files, mix test path prefixes, GitHub-project board moves with programmatically-captured IDs).
---

# PR drift: main moved under an open PR

#39 sat `CONFLICTING` for hours after #37 merged — discovered only by
accident while merging an unrelated PR. Detection is a sweep, never luck.
The sweep is cheap (one command); the rebase it prevents landing mid-task
is not.

## When to sweep

- **Any merge to `main`** — yours (add it to the post-merge routine) or
  the maintainer's. Signs the maintainer merged something outside your
  session: an unfamiliar sha/title in `git log`, a board card moved
  without a session PR (#40 appearing `Done`), an issue closing.
- **Session start** — the board shows status, not conflicts. Board sync
  alone doesn't reveal them; sweep explicitly.
- **Before handing a PR to the maintainer** — re-check `mergeable` in
  addition to checks; `main` may have moved since the last green run.

## The sweep

```sh
gh pr list --repo fluxvale/fluxvale --state open --json number \
  | jq -r '.[].number' \
  | xargs -I{} gh pr view {} --repo fluxvale/fluxvale \
      --json number,mergeable \
      --jq 'select(.mergeable != "MERGEABLE") | "#\(.number) \(.mergeable)"'
```

`UNKNOWN` means GitHub is still computing against the new base — re-poll
after a few seconds before treating it as clean.

## BEHIND ≠ conflicting: the merge judgment

Branch protection does **not** require branches to be up-to-date
(maintainer decision, 2026-09-08 — the setting's forced sync-pushes
re-triggered the full CodeRabbit cycle even for drift that couldn't
affect the PR, e.g. docs-only commits). GitHub still blocks textual
conflicts regardless; what remains is a pre-merge judgment, run on the
open PR:

```bash
# bash — process substitution. FETCH_HEAD, not a local pr-<N> branch:
# a local branch collides non-fast-forward on repeat runs or after the
# PR force-pushes; FETCH_HEAD has no ref to collide.
git fetch -q origin pull/<N>/head
base=$(git merge-base origin/main FETCH_HEAD)
# --no-renames: a main-side rename would otherwise surface only the new
# path, hiding overlap with a PR still editing the old one
comm -12 <(git diff --name-only --no-renames "$base"..origin/main | sort) \
         <(gh pr view <N> --repo fluxvale/fluxvale --json files \
            -q '.files[].path' | sort)
```

Empty → merge as-is (`BEHIND` is fine — main-push CI gates the merged
result within minutes as the safety net). Non-empty → sync first: the
rebase workflow below, re-gate, force-with-lease — file overlap is
exactly where semantic conflicts hide (each PR green alone, broken
together).

Caveats: this is for **open** PRs, pre-merge. A squash-merged PR's
`pull/N/head` survives and `merge-base` still resolves the old branch
point — but the squash commit's content now sits in the
`$base..origin/main` diff, so the check self-intersects and reports
the PR's own files (observed live on #44). Revisit trigger for the
setting itself: parallel contributors or routinely-overlapping
in-flight PRs.

## Rebase workflow (a PR came back `CONFLICTING`)

1. In the PR's worktree: `git fetch origin && git rebase origin/main`.
2. **Before resolving any hunk**, ask what `main` actually got:

   ```sh
   base=$(git merge-base HEAD origin/main)   # run before the rebase starts
   git log --oneline "$base..origin/main"
   git diff "$base..origin/main" -- '**/AGENTS.md'
   ```

   An AGENTS.md diff in the span is a **convention delta** that may
   supersede your PR's shape in files Git sees no conflict in. #37
   landed the verb-module operations convention while #39 ported v1's
   single-`Operations` shape; the textual conflict was one file, the
   convention applied everywhere.
3. Resolve to the **newest convention** — AGENTS.md is canonical, the
   nearest file wins. Refactor, don't just hunk-resolve: if a superseded
   shape appears anywhere in your diff (module layout, test paths, call
   seams), move it, even where Git auto-merged cleanly.
4. Re-run the full gate — `cd apps/platform && mix ci` — the rebase
   imports the new base's test pool into the run (#39 went from 49 to
   63 tests across its rebase; that growth is expected, not
   suspicious).
5. `git push --force-with-lease` — never bare `--force`.
6. Update the PR body with a rebase note (what moved and why) — the
   squash-merged commit on `main` won't carry the story.
7. Run the full CodeRabbit cycle again: a force-push re-triggers
   review. `gh pr checks <N> --watch`, then the quiescence re-probe
   after a settling window — same as a fresh PR.

## Mechanics

- **`mix run` scripts go in files, never `-e`** — shell quoting plus
  Elixir parse ambiguity (binary concat, comprehension brackets) burns
  attempts; four failed `-e` one-liners preceded the file that worked.
  Write `<demo>.exs` in the app dir, `mise exec -- mix run <demo>.exs`,
  delete it before committing.
- **`mix test` wants `test/`-prefixed paths** — directories are already
  recursive, so `mix test test/flux_vale/contexts/identity` runs every
  suite under it; the bare `flux_vale/...` form matches nothing and
  exits with "did not match any directory/file".
- **Board moves: IDs flow through jq, never through fingers** — a
  retyped item ID dropped two characters and cost a GraphQL error
  (#39-era lesson; the `--single-select-option`-without-`-id` trap is
  older). Capture, substitute, read back:

  ```sh
  # field + option IDs (one-time per board rebuild)
  gh project field-list 2 --owner fluxvale --format json \
    | jq -r '.fields[] | select(.name=="Status") | .id as $f
             | "field \($f)", (.options[] | "  \(.id)  \(.name)")'

  # the move: item ID captured programmatically, then edited, then verified
  iid=$(gh project item-list 2 --owner fluxvale --format json \
    | jq -r '.items[] | select(.content.number == <N>) | .id')
  gh project item-edit --project-id <PVT_…> --id "$iid" \
    --field-id <PVTSSF_…> --single-select-option-id <option-id>
  gh project item-list 2 --owner fluxvale --format json \
    | jq -r '.items[] | select(.content.number == <N>) | .status'
  ```

- **Every PR starts in a sibling worktree — docs-only included**
  (root AGENTS.md policy): `git worktree add ../fluxvale-<topic> -b
  <type>/<desc> main`. The main checkout stays on clean, synced
  `main`, so an unfamiliar sha in its `git log` reliably means a
  maintainer-side merge — the drift signal "When to sweep" relies on —
  and there is no branch-restore bookkeeping. After merge, run from
  the main checkout — a worktree cannot remove itself — `git
  worktree remove ../fluxvale-<topic>` (the worktree must be clean;
  `--force` only to deliberately discard), then delete the branch. A
  docs-only worktree needs no `deps.get`/`ash.setup` — the setup cost
  is one command.
