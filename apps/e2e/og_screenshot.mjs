/* OG card capture: the landing hero at exactly 1200x630 — the social
 * share card must be the product, not a logo on a color field. The
 * output IS the 1200x630 OG frame (og:image's size), dark is the
 * brand's primary mode and light rides along. Captures force the
 * post-animation resting state (same override the landing's
 * prefers-reduced-motion block applies) so nothing is mid-reveal, and
 * the theme-flip pattern from landing_screenshot.mjs. A 110px scroll
 * seats the full copy block + CTAs inside the frame (the sticky header
 * stays put, so the composition still reads as the page).
 *
 * Screenshots land at 2x (2400x1260) for crisp downscaled type; ship
 * og-default.png at exactly 1200x630 (downsample, don't ship 2x).
 *
 * Usage: node og_screenshot.mjs <outdir>   (FV_BASE optional; default
 * http://127.0.0.1:4000 — the plain `mix phx.server` port)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv302-og";
mkdirSync(outdir, { recursive: true });

const RESTING_CSS = `
  .landing .rise, .landing .drop, .landing .reveal,
  .landing .px-slow, .landing .px-panel {
    animation: none !important; opacity: 1 !important; transform: none !important;
  }`;

const browser = await chromium.launch();

// 2x scale keeps the type crisp when chat apps downscale the card.
const ctx = await browser.newContext({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 2,
});
const page = await ctx.newPage();
for (const mode of ["dark", "light"]) {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.addStyleTag({ content: RESTING_CSS });
  await page.evaluate(() => window.scrollTo(0, 110));
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/og-hero-${mode}-2x.png` });
  console.log(`captured og-hero-${mode}-2x.png`);
}
await ctx.close();
await browser.close();
