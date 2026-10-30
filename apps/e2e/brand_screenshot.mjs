/* Brand-mark captures: the anonymous landing and a tight crop of its
 * sticky header, in both color modes — the before/after pair for the
 * brand-mark drop-in. Anonymous only (the landing's chrome is the
 * surface this change touches; no session minting here).
 *
 * Usage: node brand_screenshot.mjs <outdir>   (FV_BASE optional; the
 * dev server must be on a non-default port)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { writeFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4171";
const outdir = process.argv[2] ?? "/tmp/opencode/fv297-brand-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  // Flip the theme the way the toggle does; the root script owns the attrs.
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/landing-${mode}.png`, fullPage: true });
  await page.locator("header").screenshot({ path: `${outdir}/nav-${mode}.png` });
  console.log(`captured landing-${mode}.png + nav-${mode}.png`);
}

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
