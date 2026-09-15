---
name: fluxvale-pr-drift
description: "FluxVale PR-conflict sweep and rebase workflow — run when any merge lands on main (agent- or maintainer-driven), at session start, or when an open PR reports CONFLICTING. Covers the sweep, the BEHIND merge judgment, rebasing with a convention-drift check, and repo mechanics (mix run script files, mix test path prefixes, board moves with captured IDs)."
---

# PR drift: main moved under an open PR

#39 sat `CONFLICTING` for hours after #37 merged, found only by
accident. Detection is a sweep, never luck — and the sweep is one
command.

## When to sweep

- **Any merge to `main`** (yours or the maintainer's — maintainer-merge
  signs: unfamiliar sha/title in `git log`, a card moved without a
  session PR, an issue closing).
- **Session start** — the board shows status, not conflicts.
- **Before handing a PR over** — re-check `mergeable` alongside
  checks; main may have moved since the last green run.

## The sweep

```sh
gh pr list --repo fluxvale/fluxvale --state open --json number \
  | jq -r '.[].number' \
  | xargs -I{} gh pr view {} --repo fluxvale/fluxvale \
      --json number,mergeable \
      --jq 'select(.mergeable != "MERGEABLE") | "#\(.number) \(.mergeable)"'
```

`UNKNOWN` = GitHub still computing against the new base — re-poll
after a few seconds.

## BEHIND ≠ conflicting: the merge judgment

Branch protection does **not** require up-to-date branches (maintainer
decision 2026-09-08, pre-#59: forced sync-pushes re-triggered the full
CodeRabbit cycle even for drift that couldn't affect the PR).
Textual conflicts still block; what remains is a file-overlap check on
the open PR:

```bash
# bash — process substitution (<(...) fails under plain sh).
# FETCH_HEAD, not a local pr-<N> branch — a local ref collides
# non-fast-forward on repeat runs or after force-pushes.
# --no-renames: a main-side rename would hide overlap with a PR
# still editing the old path.
git fetch -q origin pull/<N>/head
base=$(git merge-base origin/main FETCH_HEAD)
comm -12 <(git diff --name-only --no-renames "$base"..origin/main | sort) \
         <(gh pr view <N> --repo fluxvale/fluxvale --json files \
            -q '.files[].path' | sort)
```

Empty → merge as-is (`BEHIND` is fine; main-push CI gates the merged
result). Non-empty → rebase first — file overlap is where semantic
conflicts hide (each PR green alone, broken together).

Open PRs only: after a squash-merge, `pull/N/head` survives and the
check self-intersects, reporting the PR's own files (#44). Revisit
trigger for the setting itself: parallel contributors or routinely
overlapping in-flight PRs.

## Rebase workflow (a PR came back `CONFLICTING`)

1. In the PR's worktree: `git fetch origin && git rebase origin/main`.
2. **Before resolving any hunk**, ask what main actually got:

   ```sh
   base=$(git merge-base HEAD origin/main)   # run before the rebase starts
   git log --oneline "$base..origin/main"
   git diff "$base..origin/main" -- '**/AGENTS.md'
   ```

   An AGENTS.md diff in the span is a **convention delta** that may
   supersede your PR's shape in files Git sees no conflict in (#37
   landed the verb-module operations convention while #39 ported v1's
   single-`Operations` shape: one textual conflict, the convention
   applied everywhere).
3. Resolve to the **newest convention** — AGENTS.md is canonical, the
   nearest file wins. Refactor, don't hunk-resolve: move superseded
   shapes (module layout, test paths, call seams) even where Git
   auto-merged cleanly.
4. Re-run the full gate (`cd apps/platform && mix ci`) — the rebase
   imports the new base's test pool; a growing count is expected
   (#39: 49 → 63), not suspicious.
5. `git push --force-with-lease` — never bare `--force`.
6. Update the PR body with a rebase note (what moved, why) — the
   squash commit on `main` won't carry the story.
7. CI re-runs on the push — watch it to green
   (`gh pr checks <N> --watch`) before handover. Under
   one-review-per-PR (#59) no re-review fires: if the verdict
   predated the rebase, the rebase note is what the maintainer
   verifies against.

## Mechanics

- **`mix run` scripts go in files, never `-e`** — shell quoting plus
  Elixir parse ambiguity burns attempts (four failed one-liners
  preceded the file that worked). Write `<demo>.exs` in the app dir,
  `mise exec -- mix run <demo>.exs`, delete it before committing.
- **`mix test` wants `test/`-prefixed paths** — directories are
  recursive: `mix test test/flux_vale/contexts/identity` runs every
  suite under it; the bare form matches nothing and exits with "did
  not match any directory/file".
- **Board moves: IDs flow through jq, never through fingers** — a
  retyped item ID dropped two characters (#39-era). Capture,
  substitute, read back:

  ```sh
  # field + option IDs
  gh project field-list 2 --owner fluxvale --format json \
    | jq -r '.fields[] | select(.name=="Status") | .id as $f
             | "field \($f)", (.options[] | "  \(.id)  \(.name)")'

  # the move
  iid=$(gh project item-list 2 --owner fluxvale --format json \
    | jq -r '.items[] | select(.content.number == <N>) | .id')
  gh project item-edit --project-id <PVT_…> --id "$iid" \
    --field-id <PVTSSF_…> --single-select-option-id <option-id>
  gh project item-list 2 --owner fluxvale --format json \
    | jq -r '.items[] | select(.content.number == <N>) | .status'
  ```

- **Worktrees**: every PR in a sibling worktree (root AGENTS.md); the
  main checkout stays on clean, synced `main` — the drift signal. A
  worktree can't remove itself: from the main checkout,
  `git worktree remove ../fluxvale-<topic>` (must be clean; `--force`
  only to discard deliberately), then delete the branch. Docs-only
  worktrees skip `deps.get`/`ash.setup` — setup cost is one command.
