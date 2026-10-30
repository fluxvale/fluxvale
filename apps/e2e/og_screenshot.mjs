/* OG card capture: the landing hero at exactly 1200x630 — the dark
 * output IS the ship artifact (cp og-default.png to
 * apps/platform/priv/static/images/og-default.png).
 *
 * Mechanics: 1200x630 viewport at deviceScaleFactor 2, then a Lanczos
 * downsample to the exact og:image size (ImageMagick, `-strip` keeps
 * reruns byte-stable — don't ship the 2x). A 110px scroll seats the
 * full copy block + CTAs inside the frame — retune it if the hero's
 * clamps or header height change; the in-frame guard below fails the
 * run instead of shipping a clipped card. Captures force the
 * post-animation resting state (the landing's own prefers-reduced-motion
 * override) and pin both themes; dark ships (brand preference), light
 * rides along as evidence.
 *
 * Requires: the anonymous landing on the dev server (the script fails
 * loudly if the page has no `.landing` scope), `magick` on PATH.
 *
 * Usage: node og_screenshot.mjs <outdir>   (FV_BASE optional; default
 * http://127.0.0.1:4000 — the plain `mix phx.server` port)
 */
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv302-og";
mkdirSync(outdir, { recursive: true });

// The landing's own prefers-reduced-motion rule (landing.css) — the
// same override landing_screenshot.mjs uses for fullPage stills.
const RESTING_CSS = `
  .landing .rise, .landing .drop, .landing .reveal,
  .landing .px-slow, .landing .px-panel {
    animation: none !important; opacity: 1 !important; transform: none !important;
  }`;

// The composition only works if these stay inside the 1200x630 frame:
// the eyebrow clears the sticky header, the CTAs and the float chip
// clear the bottom edge.
const IN_FRAME = `(() => {
  const frame = { top: 56, bottom: 630 };
  const rect = (sel) => document.querySelector(sel)?.getBoundingClientRect();
  const eyebrow = rect(".hero-copy .eyebrow");
  const ctas = rect(".hero-ctas");
  const chip = rect(".float-chip");
  const fail = [];
  if (!eyebrow || eyebrow.top < frame.top) fail.push(".eyebrow under the header");
  if (!ctas || ctas.bottom > frame.bottom) fail.push(".hero-ctas clipped at the bottom");
  if (!chip || chip.bottom > frame.bottom) fail.push(".float-chip clipped at the bottom");
  return fail;
})()`;

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 2,
});
const page = await ctx.newPage();

await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
if ((await page.locator(".landing").count()) === 0) {
  console.error(`no .landing scope at ${BASE}/ — is this the anonymous landing?`);
  process.exit(1);
}

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
  const fail = await page.evaluate(IN_FRAME);
  if (fail.length > 0) {
    console.error(`composition broken (${mode}): ${fail.join("; ")}`);
    process.exit(1);
  }
  await page.screenshot({ path: `${outdir}/og-hero-${mode}-2x.png` });
  console.log(`captured og-hero-${mode}-2x.png`);
}
await ctx.close();
await browser.close();

for (const mode of ["dark", "light"]) {
  const out = mode === "dark" ? "og-default.png" : "og-hero-light.png";
  execFileSync("magick", [
    `${outdir}/og-hero-${mode}-2x.png`,
    "-filter", "Lanczos",
    "-resize", "1200x630!",
    "-strip",
    // IM re-stamps date chunks on write — exclude them or reruns are
    // never byte-stable.
    "-define", "png:exclude-chunk=date,time",
    `${outdir}/${out}`,
  ]);
  console.log(`downsampled ${out} (1200x630)`);
}

writeFileSync(`${outdir}/done`, new Date().toISOString());
