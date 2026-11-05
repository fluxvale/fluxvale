/* fv472 captures: the pricing billing-model card (the wallet-copy
 * change), light AND dark, labelled before/after via FV_LABEL. The
 * after server = the feature branch dev server (FV_BASE, default
 * :4200); the before server = main's (FV_BEFORE, optional).
 *
 * Usage: FV_BASE=http://127.0.0.1:4200 FV_LABEL=after node fv472_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4200";
const BEFORE = process.env.FV_BEFORE ?? "";
const label = process.env.FV_LABEL ?? "after";
const outdir = process.argv[2] ?? `/tmp/opencode/fv472-${label}`;
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function card(mode, base, name) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), mode);
  const page = await ctx.newPage();
  await page.goto(`${base}/pricing`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  await page
    .locator('[data-testid="pricing-billing-model"]')
    .screenshot({ path: `${outdir}/${name}-${mode}.png` });
  console.log(`captured ${name}-${mode}.png`);
  await ctx.close();
}

for (const mode of ["light", "dark"]) {
  await card(mode, BASE, label);
  if (BEFORE) await card(mode, BEFORE, "before");
}

await browser.close();
