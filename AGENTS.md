# AGENTS.md

Working agreements for humans and AI agents in this repo. App conventions
live in [`apps/platform/AGENTS.md`](apps/platform/AGENTS.md) — the nearest
file wins. Everything **why** lives in [`docs/`](docs/README.md); this file
is only **how to work here**.

## Writing conventions

- **Write like a time-pressed human** (#61) — shortest form that keeps
  the needed info; rationale lives where it's linked (usually the
  ADR), not retold in place; longer text wins only when genuinely
  simpler. Applies to comments, AGENTS.md files, skills, docs,
  issues, PR bodies, commit messages.
- **Write for a short-attention-span reader** — assume they skim and
  lose the thread in walls of text: front-load the point, one idea
  per paragraph/bullet, short sentences, and never bury a decision
  or instruction mid-block; the load-bearing line should be the
  easiest one to find.
- **Link ADR references wherever markdown renders** —
  `[ADR-NNNN](docs/adr/<file>.md)`, relative to the linking file (the
  template shows the root-docs shape; ADR-index rows link siblings:
  `[ADR-00023](00023-day-one-gates.md)`), verified to exist
  (most files are five-digit; ADR-0031 is `0031-build-order.md`) so
  IDE go-to-file works. In code fences and config comments, keep
  plain text adjacent. Plain `ADR-NNNN` in commit messages is fine —
  relative links don't resolve usefully there.

## Before anything

- Read [`docs/README.md`](docs/README.md) and the ADRs relevant to your
  change. Accepted ADRs are settled — amend, don't re-litigate.
  Undecided things live in `docs/open-questions.md`: surface, don't
  invent.
- `mise install` — exact-pinned toolchain (`mise.toml` + `mise.lock`);
  bumps are deliberate, reviewable diffs.
- Postgres 18+ (`min_pg_version`) reachable by the app's standard config —
  `postgres`/`postgres` at localhost:5432 by default; how you run it
  is your business. `mix setup` creates `flux_vale_{dev,test}`; the
  test alias creates the test DB on demand.
- No Node in `apps/platform` (tailwind/esbuild are Hex binaries); Node
  is for `apps/e2e` only.

## Planning

- Work is planned as GitHub issues referencing the deciding
  `docs/`+ADRs. Milestones mirror
  [ADR-0031](docs/adr/0031-build-order.md) (M1–M7); issues for the
  current milestone only — no speculative backlog.
- Settle design decisions **on the issue** before implementing —
  that's where intent gets reviewed.
- PRs that complete an issue open with `Closes #N` (CodeRabbit's
  linked-issues check verifies it); slice PRs of an umbrella issue
  reference it without a closing keyword.

## Local stack (k3d + Tilt, [ADR-0020](docs/adr/00020-local-dev-parity.md))

```sh
k3d cluster create --config deploy/local/k3d.yaml   # once; also creates the registry
tilt up                                              # from the repo root; UI at localhost:10350
curl -sk https://app.fluxvale.lvh.me/health          # through Traefik, self-signed
```

`tilt up` only, interactive with a TTY — neither `tilt ci` nor
headless `nohup tilt up` is supported on-machine
([ADR-0020](docs/adr/00020-local-dev-parity.md) Am. 1, 3). Images push
to the k3d local registry — never docker.io.

## The gate

- `cd apps/platform && mix ci` before every PR — one command, the same
  one CI runs.
- Coverage target is **100%** — earned, not gamed: tests for reasonable
  paths, documented coveralls exclusions for unreasonable ones (DB-down,
  race windows, prod-only). Conventions in
  [`apps/platform/AGENTS.md`](apps/platform/AGENTS.md) (#86).
- CI installs the BEAM via `erlef/setup-beam`, versions **parsed from
  `mise.toml`** — the single source of truth, so CI can't drift from
  local. (`MISE_LOCKED=1` + mise-action was tried and abandoned:
  identical lockfile + mise version failed on runners, and linux
  erlang compiled from source — 15+ min per cache miss.) Never set `locked = true` in project mise config:
  it applies to every config in scope and breaks teammates' global
  tools, which can't be in this repo's lockfile.
- credo is exact-pinned: a linter upgrade changes the findings set —
  bumps are deliberate, never a side effect of `deps.update`.

## PR lifecycle (the loop)

1. **Every PR starts in a sibling worktree — docs-only included**
   (`git worktree add ../fluxvale-<topic> -b <type>/<desc> main`):
   implement → `mix ci` green → push → PR (`Closes #N` only when it
   completes the issue) → card → `In Review`. The main checkout stays on clean, synced `main` — an
   unfamiliar sha in its `git log` reliably means a maintainer merge
   (drift signal).
   **Board moves: verify by read-back** (`gh project item-list`) — a
   CLI echo of what you asked for is not evidence (#6 sat in In
   Progress through a whole PR cycle that way). Prefer the `-id` flag
   forms — `--single-select-option` without `-id` is not a flag, and
   the name-based `--field <name> --value <name>` form exists but is
   not the verified path:

   ```sh
   gh project field-list <N> --owner fluxvale --format json   # Status field + option IDs
   gh project item-list <N> --owner fluxvale --format json    # item ID per issue
   gh project item-edit --project-id PVT_… --id PVTI_… \
     --field-id PVTSSF_… --single-select-option-id <option-id>
   ```

2. **The one CodeRabbit review, then its verdict** (procedure:
   [fluxvale-review-budget
   skill](.agents/skills/fluxvale-review-budget/SKILL.md)) — poll the
   verdict, address every finding (adopt, or rebut with evidence
   in-thread), resolve all threads (GraphQL `resolveReviewThread` if
   the bot can't). Adopted fixes land as one push, no re-review; the
   maintainer verifies. Branch protection on `main` requires CodeRabbit
   resolution anyway — the PR must be clean before it's worth a
   human's attention.
3. All GitHub Actions checks green before asking for review.
4. The maintainer is the final gate, not the first reviewer. On
   approval: squash merge, remove the worktree, delete the branch,
   sync `main`, card → `Done`.

**Verify contents, not just review status**: inspect the complete
diff **from the target branch** to `HEAD` before pushing, and the
full `gh pr diff` — never `--name-only` — before merging. A root-level `git add -A` is dangerous where app `.gitignore` files
don't reach — #15 shipped 363k lines of `node_modules/` to `main` that
way.

## PR workflow

- Conventional-commit **PR titles** — squash-merge makes the title the
  commit on `main` (`feat(platform):`, `chore(platform):`,
  `test(e2e):`, `ci:`, `docs:`).
- One concern per PR. Squash merge, delete the branch, sync `main`.
- Kanban (org project "FluxVale" — `gh project 2 --owner fluxvale`):
  `In Progress` when you start, `In Review` when the PR opens, `Done`
  when merged.

## AI-review protocol (CodeRabbit)

~1 review/hour at the 0-star OSS floor, one identity for every PR —
**one review per PR** (#59). The full discipline lives in the
[fluxvale-review-budget
skill](.agents/skills/fluxvale-review-budget/SKILL.md)
(`.coderabbit.yaml` guards only the automatic paths).

- Reply **in-thread** — top-level comments are invisible to the bot.
- Verify every finding against ground truth: adopt if real, rebut
  with evidence (the commands you ran) if not.
- Green is **states, not counts** — every `gh pr checks` row `pass`
  (required CodeRabbit check included; `grep -c pass` prints
  numbers, not truth).
- Then verify **quiescence**: analysis comments land asynchronously
  *after* the check flips green (#19) — re-probe threads/comments
  after a few minutes; only an unchanged state is ready.
- Pre-empt predictable findings in the PR body — it works.
- `gh pr checks <N> --watch` blocks until checks settle — use it
  instead of sleep-polling.
