/* S8 captures: the deploy wizard (/apps/forgejo/deploy) — every step
 * (version, configuration, resources WITH the picker visible, name) at
 * 1440x900 + 375x667, light + dark, fullPage. S8_LABEL ("before"/"after")
 * names the files; theme is re-selected before EVERY shot and animations
 * are settled first so no shot catches content mid-reveal.
 *
 * The picker is visible on the resources step (quick picks + sliders);
 * nothing in the script interacts with it beyond the Continue buttons.
 *
 * Usage: node s8_capture.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4191";
const label = process.env.S8_LABEL ?? "after";
const outdir = process.argv[2] ?? `/tmp/opencode/s8-shots-${label}`;
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const settle = (page) =>
  page.evaluate(() =>
    Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
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
// A silently-dead session renders /sign-in under deploy filenames —
// verify the app actually knows us before the first shot.
await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
if (page.url().includes("/sign-in")) throw new Error("session did not take — check FV_TOKEN");

// Drive the wizard to a step: 1 = version, 2 = configuration,
// 3 = resources (picker), 4 = name. Each advance waits for the patch.
const gotoStep = async (n) => {
  if (n > 1) {
    await page.locator("[data-testid='version-option']").first().click();
    await page.locator("[data-testid='continue-version']").click();
  }
  if (n > 2) {
    await page.locator("[data-testid='continue-env']").click();
  }
  if (n > 3) {
    await page.locator("[data-testid='continue-resources']").click();
  }
  await page.waitForTimeout(400);
  await settle(page);
};

// The two viewports; every (step, width, theme) combination. Each step
// starts from a fresh load — the wizard's steps are one-shot state, so
// gotoStep is only valid from a pristine step 1.
for (const [width, height] of [[1440, 900], [375, 667]]) {
  await page.setViewportSize({ width, height });
  for (const step of [1, 2, 3, 4]) {
    await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
    await gotoStep(step);
    const stepNames = { 1: "step1-version", 2: "step2-config", 3: "step3-resources", 4: "step4-name" };
    for (const mode of ["light", "dark"]) {
      await page.evaluate((m) => {
        localStorage.setItem("phx:theme", m);
        document.documentElement.setAttribute("data-theme", m);
        document.documentElement.setAttribute("data-theme-source", "user");
      }, mode);
      await page.waitForTimeout(250);
      await settle(page);
      const file = `${outdir}/${label}-${stepNames[step]}-${width}-${mode}.png`;
      await page.screenshot({ path: file, fullPage: true });
      console.log(`captured ${file}`);
    }
  }
}

await ctx.close();
await browser.close();
