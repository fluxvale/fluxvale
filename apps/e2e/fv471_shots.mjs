/* fv471 captures: the primary button on the home hero, /pricing, and
 * /feedback/new (composer), plus the board header spacing — light AND
 * dark, labelled before/after via FV_LABEL. The pricing billing-model
 * card gets its own clipped still (the #472 copy evidence).
 *
 * Composer stills are signed in (the paid capture user from
 * fv_t5_seed.exs — FV_T5_TOKEN); the rest are anonymous.
 *
 * Usage: FV_BASE=http://127.0.0.1:4000 FV_LABEL=before [FV_T5_TOKEN=jwt] \
 *   node fv471_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const label = process.env.FV_LABEL ?? "before";
const token = process.env.FV_T5_TOKEN ?? "";
const outdir = process.argv[2] ?? `/tmp/opencode/fv471-${label}`;
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function themedContext(mode, { signedIn } = {}) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    // The landing's scroll-revealed sections stay blank in full-page
    // captures (nothing scrolls); reduced motion reveals them.
    reducedMotion: "reduce",
  });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), mode);

  if (signedIn) {
    const page = await ctx.newPage();
    await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
    await page.request.post(`${BASE}/auth/session`, {
      form: { token },
      headers: { "x-csrf-token": csrf },
    });
    await page.close();
  }
  return ctx;
}

async function still(name, path, mode, { signedIn = false, clip = null, fullPage = true } = {}) {
  const ctx = await themedContext(mode, { signedIn });
  const page = await ctx.newPage();
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  if (clip) {
    await page.locator(clip).screenshot({ path: `${outdir}/${name}-${mode}.png` });
  } else {
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage });
  }
  console.log(`captured ${name}-${mode}.png`);
  await ctx.close();
}

const routes = [
  ["home-hero", "/"],
  ["pricing", "/pricing"],
  ["board", "/feedback"],
];

for (const [name, path] of routes) {
  for (const mode of ["light", "dark"]) {
    await still(name, path, mode);
  }
}

// The composer's primary submit only renders for a signed-in paid user,
// and a stale token silently lands on the anonymous page — assert the
// form is really there before calling a capture evidence.
if (token) {
  for (const mode of ["light", "dark"]) {
    const ctx = await themedContext(mode, { signedIn: true });
    const page = await ctx.newPage();
    await page.goto(`${BASE}/feedback/new`, { waitUntil: "networkidle" });
    await page.waitForTimeout(600);
    await page
      .locator("#composer-form button[type='submit']")
      .waitFor({ state: "visible", timeout: 10_000 });
    await page.screenshot({ path: `${outdir}/composer-${mode}.png`, fullPage: true });
    console.log(`captured composer-${mode}.png`);
    await ctx.close();
  }
}

// Clipped evidence: the billing copy card (#472) and the board header
// (the spacing fix's exact surface).
for (const mode of ["light", "dark"]) {
  await still("billing-card", "/pricing", mode, {
    clip: '[data-testid="pricing-billing-model"]',
  });
  await still("board-header", "/feedback", mode, {
    clip: "header:has(h1)",
  });
}

await browser.close();
console.log(`done: ${label}`);
