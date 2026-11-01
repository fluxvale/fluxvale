/* S10 captures: the org settings cluster — General, Members, and the
 * Access page's three states (no gateway / enabled / with pairings)
 * plus the personal /settings/access frame — at 1440x900 + 375x667,
 * light + dark, fullPage. S10_LABEL ("before"/"after") names the files;
 * theme is re-selected before EVERY shot and animations are settled
 * first so no shot catches content mid-reveal.
 *
 * The access states ride /tmp/opencode/s10_seed.exs (four orgs + a
 * personal org; the session token lands in /tmp/opencode/s10_token.txt).
 *
 * Usage: node s10_capture.mjs <outdir>   (FV_BASE, FV_TOKEN, S10_SLUG,
 *                                S10_SLUG_EMPTY, S10_SLUG_ENABLED — all
 *                                required; the seed's org slugs)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4193";
const label = process.env.S10_LABEL ?? "after";
const outdir = process.argv[2] ?? `/tmp/opencode/s10-shots-${label}`;
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
// All three slugs up front (hostile-355 F1): an unset slug would build
// /organizations/undefined/… and shoot the error page under a real
// surface's filename — validate before any navigation, not after.
const SLUG = process.env.S10_SLUG ?? "";
const SLUG_EMPTY = process.env.S10_SLUG_EMPTY ?? "";
const SLUG_ENABLED = process.env.S10_SLUG_ENABLED ?? "";
if (!token || !SLUG || !SLUG_EMPTY || !SLUG_ENABLED) {
  console.error("FV_TOKEN, S10_SLUG, S10_SLUG_EMPTY, S10_SLUG_ENABLED required");
  process.exit(1);
}

// One live-socket assertion, the S7 lesson: the static render carries
// the same DOM, so a click before the socket connects lands on the
// dead page (a harness flake that reads like an app bug).
const live = (page) =>
  page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

const settle = (page) =>
  // Finite animations only. Two ways an animation never finishes and
  // would hang the await (hostile-355 F3): a missing effect, and an
  // INFINITE-ITERATION spinner (motion-safe:animate-spin has a finite
  // 1s duration, so duration alone doesn't catch it). Both are skipped,
  // and the whole await races a hard timeout as the backstop.
  page.evaluate(() => {
    const finite = (a) => {
      try {
        if (!a.effect) return false;
        const timing = a.effect.getComputedTiming();
        return Number.isFinite(timing.duration ?? 0) && timing.iterations !== Infinity;
      } catch {
        return false;
      }
    };
    return Promise.race([
      Promise.all(
        document.getAnimations().filter(finite).map((a) => a.finished.catch(() => {})),
      ),
      new Promise((resolve) => setTimeout(resolve, 2_000)),
    ]);
  });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);
// A silently-dead session renders /sign-in under our filenames —
// verify the app actually knows us before the first shot.
await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
if (page.url().includes("/sign-in")) throw new Error("session did not take — check FV_TOKEN");
await live(page);

const SURFACES = [
  [
    "org-settings",
    async () =>
      await page.goto(`${BASE}/organizations/${SLUG}/settings`, { waitUntil: "networkidle" }),
  ],
  [
    "org-members",
    async () =>
      await page.goto(`${BASE}/organizations/${SLUG}/settings/members`, {
        waitUntil: "networkidle",
      }),
  ],
  [
    "access-empty",
    async () =>
      await page.goto(`${BASE}/organizations/${SLUG_EMPTY}/settings/access`, {
        waitUntil: "networkidle",
      }),
  ],
  [
    "access-enabled",
    async () =>
      await page.goto(`${BASE}/organizations/${SLUG_ENABLED}/settings/access`, {
        waitUntil: "networkidle",
      }),
  ],
  [
    "access-pairings",
    async () =>
      await page.goto(`${BASE}/organizations/${SLUG}/settings/access`, { waitUntil: "networkidle" }),
  ],
  [
    "access-personal",
    async () => await page.goto(`${BASE}/settings/access`, { waitUntil: "networkidle" }),
  ],
];

for (const [width, height] of [[1440, 900], [375, 667]]) {
  await page.setViewportSize({ width, height });
  for (const [name, navigate] of SURFACES) {
    await navigate();
    await live(page);
    // A mis-sluged navigation must never render under a real surface's
    // filename (hostile-355 F1) — fail loudly instead.
    if (page.url().includes("undefined")) {
      throw new Error(`${name}: navigation landed on an 'undefined' URL: ${page.url()}`);
    }
    await settle(page);
    for (const mode of ["light", "dark"]) {
      await page.evaluate((m) => {
        localStorage.setItem("phx:theme", m);
        document.documentElement.setAttribute("data-theme", m);
        document.documentElement.setAttribute("data-theme-source", "user");
      }, mode);
      await page.waitForTimeout(250);
      await settle(page);
      const theme = await page.evaluate(() =>
        document.documentElement.getAttribute("data-theme"),
      );
      if (theme !== mode) throw new Error(`theme did not take: wanted ${mode} got ${theme}`);
      const file = `${outdir}/${label}-${name}-${width}-${mode}.png`;
      await page.screenshot({ path: file, fullPage: true });
      console.log(`captured ${file}`);
    }
  }
}

await ctx.close();
await browser.close();
