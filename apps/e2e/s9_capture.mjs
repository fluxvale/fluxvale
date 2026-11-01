/* S9 captures: the billing trio (/billing, org billing, the top-up
 * wizard's three steps, the gateway-return receipt) at 1440x900 +
 * 375x667, light + dark, fullPage. S9_LABEL ("before"/"after") names
 * the files; theme is re-selected before EVERY shot and animations are
 * settled first so no shot catches content mid-reveal.
 *
 * The wizard is driven through its real forms (details → amount →
 * payment); the receipt state rides the completed top-up row seeded by
 * /tmp/opencode/s9_seed.exs (reference pr_s9_capture).
 *
 * Usage: node s9_capture.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4192";
const label = process.env.S9_LABEL ?? "after";
const outdir = process.argv[2] ?? `/tmp/opencode/s9-shots-${label}`;
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

// One live-socket assertion, the S7 lesson: the static render carries
// the same DOM, so a click before the socket connects lands on the
// dead page and the phx event never fires (a harness flake that reads
// like an app bug). Await this after every navigation, before driving.
const live = (page) =>
  page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

const settle = (page) =>
  // Finite animations only: a pending receipt's spinner is infinite and
  // its `finished` promise never resolves — waiting on it hung the
  // receipt capture (CodeRabbit #351).
  page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter(
          (a) =>
            !a.effect ||
            Number.isFinite(a.effect.getComputedTiming().duration ?? 0),
        )
        .map((a) => a.finished.catch(() => {})),
    ),
  );

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
// A silently-dead session renders /sign-in under billing filenames —
// verify the app actually knows us before the first shot.
await page.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
if (page.url().includes("/sign-in")) throw new Error("session did not take — check FV_TOKEN");
await live(page);

// Drive the wizard: 1 = details, 2 = amount with the live-priced
// receipt panel visible (the capture's subject), 3 = payment. Each
// advance waits for the DESTINATION's element, not a fixed delay — a
// slow submission used to leave the previous step under the next
// step's filename (CodeRabbit #351).
const gotoStep = async (n) => {
  await live(page);
  if (n > 1) {
    await page.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe");
    await page.locator("#topup-details-form input[name='details[country]']").fill("DE");
    await page.locator("#topup-details-next").click();
    await page.locator("#topup-amount-form").waitFor();
  }
  if (n >= 2) {
    // A typed amount is what prices the panel; an empty field captures
    // the form without it.
    await page.locator("#topup-amount-form input[name='amount[dollars]']").fill("25");
    await page.locator("[data-testid='topup-summary']").waitFor();
  }
  if (n > 2) {
    await page.locator("#topup-amount-next").click();
    await page.locator("#topup-pay").waitFor();
  }
  await settle(page);
};

const SURFACES = [
  ["billing", async () => await page.goto(`${BASE}/billing`, { waitUntil: "networkidle" })],
  [
    "org-billing",
    async () =>
      await page.goto(`${BASE}/organizations/acme-robotics/billing`, { waitUntil: "networkidle" }),
  ],
  ["topup-step1-details", async () => { await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" }); await gotoStep(1); }],
  ["topup-step2-amount", async () => { await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" }); await gotoStep(2); }],
  ["topup-step3-payment", async () => { await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" }); await gotoStep(3); }],
  [
    "topup-receipt",
    async () =>
      await page.goto(`${BASE}/billing/topup/return?reference=pr_s9_capture`, {
        waitUntil: "networkidle",
      }),
  ],
];

for (const [width, height] of [[1440, 900], [375, 667]]) {
  await page.setViewportSize({ width, height });
  for (const [name, navigate] of SURFACES) {
    await navigate();
    await live(page);
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
