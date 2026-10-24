// Version currency (fluxvale#242): each deployed env's /health version
// must carry every platform change on main — current means the newest
// platform-carrying sha is an ancestor of the serving sha (deploys are
// linear on main), or the serving sha trails it by less than the grace
// window. Availability checks pass on old pods forever (the Oct-23
// freeze: 3h NotReady via dependency while every probe stayed green on
// the previous image); this check is the "is the deploy pipeline
// actually shipping" oracle, riding the scheduled smoke so its red
// path (annotation + no heartbeat → the dead-man's page) is the alert
// path that already exists.
//
// Red conditions, per env:
//   - version is not "sha-<sha>" (a "dev" or missing build identity on
//     a deployed env is a broken image build, not a slow deploy)
//   - the serving sha is not an ancestor of origin/main (a deploy from
//     a rewritten-away or foreign sha — the post-history-rewrite shape)
//   - the newest platform-carrying commit on main is NOT carried by the
//     serving image and has been undeployed longer than
//     CURRENCY_GRACE_HOURS (stuck deploy / skipped jobs)
//
// Green when current, or when behind within grace (a deploy in flight:
// merge → image → Flux bump → rollout is 15–35 min end to end). NB
// "newest platform-carrying" dates commits touching apps/platform, but
// the deploy trigger also fires on mise.toml/ci.yml changes — those
// builds descend the newest platform commit too, and the ancestor
// check below counts them current (a ci-only deploy must not read
// stale once the last platform commit ages past grace).
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GRACE_HOURS = Number(process.env.CURRENCY_GRACE_HOURS ?? "2");

// A non-numeric grace is NaN, and every `> NaN` comparison is false —
// a check whose job is "don't lie about deploys" must not fail open
// on one bad dispatch input.
if (!Number.isFinite(GRACE_HOURS) || GRACE_HOURS < 0) {
  console.error(`::error::CURRENCY_GRACE_HOURS must be a number >= 0 (got ${JSON.stringify(process.env.CURRENCY_GRACE_HOURS)})`);
  process.exit(2);
}

function usage() {
  console.error("usage: node version-currency.mjs name=base-url [name=base-url…]");
  console.error('  e.g. node version-currency.mjs staging=https://staging.fluxvale.com production=https://fluxvale.com');
}

function parseArgs(argv) {
  return argv.map((arg) => {
    const eq = arg.indexOf("=");
    if (eq < 1) {
      usage();
      process.exit(2);
    }
    return { name: arg.slice(0, eq), baseUrl: arg.slice(eq + 1) };
  });
}

async function git(args) {
  const { stdout } = await execFileAsync("git", args, { maxBuffer: 10 * 1024 * 1024 });
  return stdout.trim();
}

// The newest platform-carrying sha on main: what the deploy pipeline
// owes both envs. Commits that don't touch apps/platform don't change
// platform code; a build they trigger descends this commit and counts
// as current via the ancestor check below.
async function newestPlatformSha() {
  const root = await git(["rev-parse", "--show-toplevel"]);
  const out = await git(["-C", root, "log", "-1", "--format=%H %cI", "origin/main", "--", "apps/platform"]);
  const [sha, date] = out.split(" ");
  if (!sha || !date) {
    throw new Error("no platform-carrying commit found on origin/main -- apps/platform");
  }
  return { sha, date: new Date(date) };
}

async function servingVersion(baseUrl) {
  const response = await fetch(`${baseUrl}/health`, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) {
    throw new Error(`GET ${baseUrl}/health → ${response.status}`);
  }
  const body = await response.json();
  return body.version;
}

// Non-zero exit on any red: the workflow step fails, no heartbeat is
// written, and the dead-man pages — same contract as a Bruno failure.
async function main() {
  const envs = parseArgs(process.argv.slice(2));
  if (envs.length === 0) {
    usage();
    process.exit(2);
  }

  const newest = await newestPlatformSha();
  const newestShort = newest.sha.slice(0, 8);
  console.log(`newest platform sha on main: ${newestShort} (${newest.date.toISOString()}), grace ${GRACE_HOURS}h`);
  console.log(`deployed envs must serve it (or be within grace of it)`);

  const graceMs = GRACE_HOURS * 3600_000;
  const lagMs = Date.now() - newest.date.getTime();
  const lag = formatDuration(lagMs);
  let red = false;

  for (const env of envs) {
    let version;
    try {
      version = await servingVersion(env.baseUrl);
    } catch (error) {
      console.error(`::error::${env.name}: /health unreachable — ${error.message}`);
      red = true;
      continue;
    }

    const match = /^sha-([0-9a-f]{7,40})$/.exec(version ?? "");
    if (!match) {
      console.error(`::error::${env.name}: version ${JSON.stringify(version)} is not a build identity (sha-<sha>) — image built without BUILD_SHA`);
      red = true;
      continue;
    }

    const sha = await resolveOnMain(match[1]);
    if (!sha) {
      console.error(`::error::${env.name}: serving sha-${match[1].slice(0, 8)}, which is not on origin/main — deployed from a rewritten-away or foreign commit (or the clone's history is unavailable)`);
      red = true;
      continue;
    }

    if (sha === newest.sha || (await carries(sha, newest.sha))) {
      console.log(`${env.name}: sha-${sha.slice(0, 8)} — current ✓`);
      continue;
    }

    if (lagMs > graceMs) {
      console.error(`::error::${env.name}: serving sha-${sha.slice(0, 8)}, main has waited ${lag} for ${newestShort} to deploy (grace ${GRACE_HOURS}h) — deploy pipeline stuck or skipped`);
      red = true;
    } else {
      console.log(`${env.name}: sha-${sha.slice(0, 8)} — behind ${newestShort} by ${lag}, within grace (deploy in flight)`);
    }
  }

  if (red) {
    process.exit(1);
  }
}

// The /health sha is the full BUILD_SHA (github.sha); disambiguate
// short forms anyway. Ancestry, not just existence: a sha that isn't
// an ancestor of origin/main is a rewrite/foreign artifact — currency
// is unverifiable against it, which is itself the red.
async function resolveOnMain(sha) {
  try {
    await execFileAsync("git", ["merge-base", "--is-ancestor", sha, "origin/main"]);
    const { stdout } = await execFileAsync("git", ["rev-parse", `${sha}^{commit}`]);
    return stdout.trim();
  } catch {
    return null;
  }
}

// Current = the serving image carries the newest platform commit. A
// build triggered by a non-platform path (mise/ci-only merges ship new
// BUILD_SHAs too) descends the newest platform commit, so it must not
// read stale — main is linear, ancestry is the whole test.
async function carries(servingSha, platformSha) {
  try {
    await execFileAsync("git", ["merge-base", "--is-ancestor", platformSha, servingSha]);
    return true;
  } catch {
    return false;
  }
}

function formatDuration(ms) {
  const minutes = Math.round(ms / 60_000);
  if (minutes < 60) {
    return `${minutes}m`;
  }
  return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}m`;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
