# AGENTS.md

Working agreements for humans and AI agents in this repo. App-specific code
conventions live in [`apps/platform/AGENTS.md`](apps/platform/AGENTS.md) —
the nearest file wins. Everything **why** lives in [`docs/`](docs/README.md);
this file is only **how to work here**.

## Writing conventions

- **Link ADR references wherever markdown renders** — docs, README,
  AGENTS.md, PR bodies: `[ADR-NNNN](docs/adr/<file>.md)` with a relative
  path, verified to exist (mind the filename quirks — most are five-digit,
  ADR-0031 is `0031-build-order.md`). IDE go-to-file then works on every
  decision reference.
- Where links **can't** render — fenced code blocks, comments in
  Tiltfile/YAML — keep plain text and put the linked reference adjacent
  (the README layout fence does exactly this).
- Plain `ADR-NNNN` in commit messages is fine: relative links don't
  resolve usefully there.

## Before anything

- Read [`docs/README.md`](docs/README.md) and the ADRs relevant to your
  change. Accepted ADRs are settled — propose an amendment, never
  re-litigate in a work session. Anything undecided lives in
  `docs/open-questions.md`: surface it, don't invent an answer.
- `mise install` — the toolchain is exact-pinned in `mise.toml` with a
  committed `mise.lock` (per-platform checksums). Tool bumps are deliberate,
  reviewable diffs; there is no floating "latest" in this repo.
- Local database: any PostgreSQL 18+ (`min_pg_version`) reachable by the
  app's standard config — `postgres`/`postgres` at `localhost:5432` by
  default; override to taste. `mix setup` creates `flux_vale_{dev,test}`
  and the test alias creates the test DB on demand. How you actually run
  Postgres on your machine is your business — it is not prescribed here.
- No Node in `apps/platform` (tailwind/esbuild are Hex binaries); Node is for
  `apps/e2e` only.

## Planning: docs and issues together

- Plan work as GitHub issues whose bodies reference the `docs/`+ADRs that
  decided it. Milestones mirror the [ADR-0031](docs/adr/0031-build-order.md) ladder (M1–M7).
- Before implementing, settle design decisions **on the issue** (see #4's
  two-route probe design) — the issue is where intent gets reviewed before
  code exists.
- Create issues for the current milestone only; a milestone gets its issues
  when it starts. No speculative backlog.
- PRs open with `Closes #N` so intent and change stay linked (and CodeRabbit's
  linked-issues check verifies it).

## Local stack (k3d + Tilt, [ADR-0020](docs/adr/00020-local-dev-parity.md))

```sh
k3d cluster create --config deploy/local/k3d.yaml   # once; also creates the registry
tilt up                                              # from the repo root; UI at localhost:10350
curl -sk https://app.fluxvale.lvh.me/health          # through Traefik, self-signed
```

Use `tilt up`, not `tilt ci` (batch mode wedged on-machine; see [ADR-0020](docs/adr/00020-local-dev-parity.md)
Am. 1). Images push to the k3d local registry — never docker.io.

## The gate

- `cd apps/platform && mix ci` before every PR — one command, the same one
  CI runs. If it doesn't pass locally, it doesn't get a PR.
- CI installs the BEAM via `erlef/setup-beam` (v1's proven pattern), with
  versions **parsed from `mise.toml`** — the single source of truth, so CI
  and local dev cannot drift. (`MISE_LOCKED=1` + mise-action was tried and
  abandoned: identical lockfile + mise version failed on runners while
  succeeding locally, and linux erlang would compile from source — 15+ min
  per cache miss — where setup-beam is precompiled.) Do **not** set
  `locked = true` in project mise config: it applies to every config in
  scope and breaks teammates' global tools, which can't be in this repo's
  lockfile.
- credo is exact-pinned: a linter upgrade changes the findings set, so bumps
  are deliberate, never a side effect of `deps.update`.

## PR lifecycle (the loop)

1. Branch → implement → `mix ci` green → push → open PR (`Closes #N`) →
   card → `In Review`.
   **Verify board mutations by read-back** (`gh project item-list`): a CLI
   echo of what you *asked for* is not evidence — #6 sat in In Progress
   through a whole PR cycle because a `--jq` literal printed success over a
   silently-failed `item-edit`.
2. **Wait for CodeRabbit's verdict before involving the maintainer.** The
   bot reviews after the PR opens — poll it, address every finding (adopt,
   or rebut with evidence, in-thread), and resolve all threads (manually
   via GraphQL if the bot can't). Branch protection on `main` requires
   CodeRabbit resolution anyway — the PR must be clean before it's worth a
   human's attention.
3. Once CI exists (#8): also require all GitHub Actions checks green
   before asking for review.
4. Only then ask the maintainer for feedback/merge. On approval: squash
   merge, delete branch, sync `main`, card → `Done`.

The maintainer is the final gate, not the first reviewer.

**Verify what a commit/PR actually contains before pushing or merging** —
not just its review status. Before pushing, inspect the complete diff from
the target branch to `HEAD`, including file paths and changed hunks; before
merging, inspect the full PR diff (`gh pr diff` without `--name-only`)
against the target branch.
A root-level `git add -A` is dangerous on branches where app-level
`.gitignore` files are absent: #15 shipped 363k lines of `node_modules/`
to `main` that way, past a ⚪ Minimal review verdict (history rewritten;
lesson paid for).

## PR workflow

- Conventional-commit **PR titles** — squash-merge makes the title the
  commit on `main` (`feat(platform):`, `chore(platform):`, `test(e2e):`,
  `ci:`, `docs:`).
- One concern per PR. Squash merge, delete the branch, sync `main`.
- Kanban (org project "FluxVale v2 — build ladder"): `In Progress` when you
  start, `In Review` when the PR opens, `Done` when merged.

## AI-review protocol (CodeRabbit)

- Reply **in-thread** — top-level comments are invisible to the bot.
- Verify every finding against ground truth before acting: adopt if real,
  rebut with evidence (the commands you ran) if not. Both outcomes are
  normal here.
- Verify green as **states, not counts**: every row of `gh pr checks` must
  read `pass` (the required CodeRabbit check included) before pinging the
  maintainer — resolved threads are conversation state; the check is the
  gate. (`grep -c pass` and friends print numbers, not truth.)
- Then verify **quiescence**: CodeRabbit's analysis comments land
  asynchronously *after* the check flips green (#19 got a new finding
  minutes after "Review completed"). Re-check threads/comments after a
  settling window (a few minutes); only an unchanged state is "ready".
- If the bot cannot resolve a thread, resolve it manually (GraphQL
  `resolveReviewThread`).
- Pre-empt predictable findings in the PR body (deliberate test gaps, pin
  rationale) — it works.
