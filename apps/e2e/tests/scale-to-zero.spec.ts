import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";
import { wakeCeilingMs, wakeSliSnapshot } from "./helpers/wake-metrics";

// #203 (ADR-0036): the scale-to-zero economic model end to end —
// deploy → idle → sleeps (storage-only) → request → wakes → serves,
// plus the settled owner rule that probes never count as traffic.
//
// Local-only: the bootstrap compresses the sweep CADENCE (and the
// timers CI leg compresses the threshold too — #210 part 3,
// IDLE_SLEEP_AFTER_SECONDS / IDLE_SWEEP_CRONEXPR), so a sleep lands
// within ~105s there. The nightly full-cadence run (e2e-nightly.yml)
// runs the real 1h + */5 pair and raises the budgets below
// accordingly. Staging keeps the real promise — not waitable in any
// suite budget; the unit tests pin the threshold semantics instead.

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

// Timer budgets scale with the environment's threshold + cadence
// (#210 part 3): sleep lands within threshold + one sweep, so the
// waits are env knobs, not constants. Defaults fit the pre-part-3
// bootstrap (180s + */5); the compressed PR-CI timers leg and the
// nightly set their own. Present-but-garbage THROWS — a mistyped
// budget must fail at load, not as a "timing flake" hours in (the
// runtime.exs stance: fail loud, name the env).
function numberEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name}=${raw} is not a positive number`);
  }
  return parsed;
}

const sleepWaitMs = numberEnv("E2E_SLEEP_WAIT_MS", 9 * 60_000);
const testTimeoutMs = numberEnv("E2E_TEST_TIMEOUT_MS", 30 * 60_000);
const probeWindowMs = numberEnv("E2E_PROBE_WINDOW_MS", 6 * 60_000);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test.skip(
  runtime !== "local",
  "scale-to-zero timing needs the bootstrap's shortened idle threshold — local only",
);

test.describe.serial("forgejo: scale-to-zero", () => {
  test.setTimeout(testTimeoutMs);

  let page: Page;
  let instanceUrl: string;

  test.beforeAll(async ({ browser, request }) => {
    // The deploy walk takes minutes — the hook's own clock, not just
    // the tests' (a bare beforeAll inherits the 30s config default).
    test.setTimeout(15 * 60_000);

    page = await browser.newPage();

    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Same stepper walk as the lifecycle spec (image already warm on the
    // node from it — the cold start we measure below is wake, not pull).
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await page.getByTestId("app-forgejo").click();
    await waitForLiveViewJoin(page);
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await page.getByTestId("continue-env").click();
    // 1 core (rung index 2 — the wire is index-based since #221) over
    // the 0.5-core `small` recommendation, like the lifecycle spec.
    await page.getByTestId("resource-cpu").fill("2");
    await page.getByTestId("continue-resources").click();
    await page.getByTestId("instance-name").fill(`e2e-s2z-${runId}`);
    await page.getByTestId("deploy-submit").click();

    await page.waitForURL(/\/instances\//);
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    instanceUrl = ((await page.getByTestId("instance-url").textContent()) ?? "").trim();
  });

  test.afterAll(async () => {
    await page.close();
  });

  test("idle → sleeps → bills storage-only", async () => {
    // The idle clock: no visitor after the deploy. Badge flips to
    // Sleeping within threshold + one sweep cadence — an env-scaled
    // budget (compressed in PR CI, real in the nightly).
    await waitForStatus(page, "Sleeping", sleepWaitMs);

    // The sleeping bill is the storage-only bill — the instance page's
    // price row swaps to the asleep fee (the ledger's identical accrual
    // is pinned usec-exact in perform_settle's suite).
    await expect(page.getByTestId("instance-price")).toContainText(/while asleep/);
    await expect(page.getByTestId("availability-mode")).toContainText("Sleeps when idle");
  });

  test("request → wakes → serves (cold start measured)", async ({ request }) => {
    await waitForStatus(page, "Sleeping", 60_000);

    // First touch: the waking interstitial (JS-free meta refresh).
    // Explicit Accept — Playwright's APIRequestContext sends `*/*`,
    // which is the machine path (503), not the browser path. The
    // first request after the sleep flip can transiently 502 while
    // Traefik converges on the freshly-applied wake objects — a real
    // visitor's browser refreshes through it; poll, don't fail.
    // The SLI snapshot precedes t0 so the ceiling below brackets
    // exactly this wake (the platform's own clock, not a constant).
    const sliBefore = await wakeSliSnapshot(request, "forgejo");
    const t0 = Date.now();
    const first = await firstWakeResponse(request, instanceUrl!);
    expect(first.status()).toBe(200);

    // Either the interstitial, or (if the app woke faster than Traefik
    // converged) the app itself — both prove the wake path answered.
    const firstBody = await first.text();
    expect(firstBody).toMatch(/data-testid="waking-page"|Forgejo/i);

    // Poll the URL until the app itself answers. Redirect-following
    // turns the wake endpoint's 302 into the app's first response.
    let body = "";
    let woke = false;

    while (Date.now() - t0 < 120_000) {
      const res = await request.get(instanceUrl!).catch(() => null);
      if (res && res.status() < 400) {
        body = await res.text();
        if (/Forgejo/i.test(body)) {
          woke = true;
          break;
        }
      }
      await new Promise((r) => setTimeout(r, 1_000));
    }

    expect(woke, "the woken instance serves Forgejo again").toBe(true);
    const coldStartMs = Date.now() - t0;
    console.log(`scale-to-zero cold start (request → serving): ${coldStartMs}ms`);

    // Two conjuncts, two different jobs:
    //
    // 1. Consistency — the cold start must track the platform's own
    //    wake clock (#232's total histogram) for THIS wake. The
    //    platform's clock includes the minute-cadence reconciler by
    //    design, so full-cadence wakes sit near the minute mark and a
    //    fixed ceiling was failing on true statements; this gate
    //    instead catches user-visible divergence from the instrument
    //    (edge convergence, restore glitches) — runner variance moves
    //    both numbers together.
    // 2. Absolute backstop — the serving loop's own 120s budget, said
    //    out loud: consistency alone cannot fail on a wake that is
    //    uniformly slow, so a gross regression (stuck reconciler,
    //    cold image pull) must still have a number to answer to.
    const { ceilingMs, samples } = await wakeCeilingMs(request, "forgejo", sliBefore);

    expect(
      coldStartMs,
      `cold start vs wake SLI (ceiling ${ceilingMs}ms over ${samples} sample(s))`,
    ).toBeLessThan(ceilingMs);
    expect(coldStartMs, "absolute cold-start budget").toBeLessThan(120_000);

    await waitForStatus(page, "Running", 3 * 60_000);
  });

  test("probe traffic does not wake a sleeping instance", async ({ request }) => {
    // Second idle cycle: let it sleep again, then hit it with an honest
    // probe UA. Probes must not count as traffic — no wake, no clock.
    await waitForStatus(page, "Sleeping", sleepWaitMs);

    for (let i = 0; i < 3; i++) {
      const res = await request.get(instanceUrl!, {
        headers: { "User-Agent": "kube-probe/1.29" },
        maxRedirects: 0,
      });
      expect(res.status()).toBe(503);
      await new Promise((r) => setTimeout(r, 2_000));
    }

    // Outlive one sweep cadence, polling the badge the whole way: a
    // probe-caused wake (and even a wake→re-sleep inside the window)
    // must fail the test, not just a wake that persists to the end.
    // One cadence + margin — an env knob like the other budgets
    // (default fits */5; the compressed timers leg shortens it).
    const until = Date.now() + probeWindowMs;
    while (Date.now() < until) {
      const badge = await page.getByTestId("status-badge").innerText();
      expect(badge.trim(), "probe traffic must not wake a sleeping instance").toBe("Sleeping");
      await new Promise((r) => setTimeout(r, 30_000));
    }
  });
});

// The first browser-shaped request after the flip: 200 + the waking
// page once Traefik has converged on the wake-mode objects (transient
// 5xx/3xx shapes are retried — a real browser would too).
async function firstWakeResponse(
  request: import("@playwright/test").APIRequestContext,
  url: string,
  timeoutMs = 30_000,
) {
  const deadline = Date.now() + timeoutMs;

  let last = await request.get(url, { headers: { Accept: "text/html" }, maxRedirects: 0 });
  while (last.status() !== 200 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1_000));
    last = await request.get(url, { headers: { Accept: "text/html" }, maxRedirects: 0 });
  }

  return last;
}

// The lifecycle spec's helper, verbatim (badge vocabulary, fail-fast on
// Failed) — local copy: that spec exports nothing and one shared
// helpers file for two specs is its own change.
async function waitForStatus(page: Page, want: string, timeoutMs: number) {  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const status = await page
      .getByTestId("status-badge")
      .innerText({ timeout: 10_000 })
      .catch(() => null);

    if (status?.trim() === want) return;
    if (status?.trim() === "Failed") {
      const message = await page
        .getByTestId("status-message")
        .textContent()
        .catch(() => "");
      throw new Error(`instance hit error state: ${message?.trim()}`);
    }

    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  throw new Error(`status never reached "${want}" within ${timeoutMs}ms`);
}
