/* S4 captures: the dashboard on the app-wide grammar, before/after.
 * Pattern per apps/e2e/s3_panels_screenshot.mjs (#178 line): session via
 * the real POST /auth/session with a minted JWT, FV_BASE picks the dev
 * server (after = 4186, before = 4187 — same dev DB).
 *
 * THE S3 LESSON, ENFORCED: the theme is selected IMMEDIATELY before
 * every shot (setMode right next to the screenshot call) — a theme
 * loop's last mode must never leak into named-light captures.
 *
 * Usage: node s4_capture.mjs <outdir> <tag> <phase>
 *   e.g. node s4_capture.mjs /tmp/opencode/s4-shots after populated
 */

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/s4-shots";
const tag = process.argv[3] ?? "after";
const phase = process.argv[4] ?? "populated";
mkdirSync(outdir, { recursive: true });

if (!TOKEN) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();

async function capture(userToken, label) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  // 1. session: POST /auth/session (needs csrf from a fetched page)
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: userToken },
    headers: { "x-csrf-token": csrf },
  });

  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);

  // The session POST can silently fail — a /sign-in redirect here would
  // capture the wrong surface under the right filename. Refuse loudly.
  const url = page.url();
  if (url.includes("/sign-in")) {
    throw new Error(`session failed — landed on ${url} instead of the dashboard`);
  }
  await page.locator("[data-testid='dashboard-balance'], h1").first().waitFor({ state: "visible" });
  // let the .rise settle (300ms + 100ms delay + margin)
  await page.waitForTimeout(600);

  async function setMode(mode) {
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
  }

  async function shot(name) {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
    console.log(`captured ${name}.png`);
  }

  // Desktop 1440 — theme selected immediately before each capture.
  await setMode("light");
  await shot(`s4-dash-${label}-1440-light`);
  await setMode("dark");
  await shot(`s4-dash-${label}-1440-dark`);

  // Mobile 375.
  await page.setViewportSize({ width: 375, height: 800 });
  await page.waitForTimeout(500);
  await setMode("light");
  await shot(`s4-dash-${label}-375-light`);
  await setMode("dark");
  await shot(`s4-dash-${label}-375-dark`);

  await ctx.close();
}

if (phase === "populated") {
  await capture(TOKEN, `${tag}-populated`);
} else {
  await capture(TOKEN, `${tag}-fresh`);
}

await browser.close();
console.log("done");
