/* Landing captures: anonymous landing stills (1440x900 + 375x700, light
 * + dark, fullPage), a reduced-motion still, and motion GIFs (load
 * reveal, scroll, hover) for the landing's CSS motion. Theme-flip
 * pattern from brand_screenshot.mjs: localStorage `phx:theme` +
 * `data-theme` evaluate + 300ms settle. GIF contexts set the theme via
 * addInitScript so a fresh navigation records the load reveal in the
 * target mode.
 *
 * Stills force the post-animation resting state (the same override the
 * landing's prefers-reduced-motion block applies) — scroll-linked
 * reveals below the fold would otherwise hollow out a fullPage capture.
 * The reduced-motion still proves the real media query does the same
 * with no injection. GIFs record the live motion; they are skipped
 * when the page has no `.landing` scope (pre-rebuild captures).
 *
 * Usage: node landing_screenshot.mjs <outdir>   (FV_BASE optional; the
 * dev server must be on a non-default port)
 */
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4172";
const outdir = process.argv[2] ?? "/tmp/opencode/fv297-landing";
mkdirSync(outdir, { recursive: true });

const RESTING_CSS = `
  .landing .rise, .landing .drop, .landing .reveal,
  .landing .px-slow, .landing .px-panel {
    animation: none !important; opacity: 1 !important; transform: none !important;
  }`;

const browser = await chromium.launch();

// ---- Stills: 1440x900 + 375x700, dark + light, fullPage ----
for (const [width, height] of [
  [1440, 900],
  [375, 700],
]) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  const page = await ctx.newPage();
  for (const mode of ["dark", "light"]) {
    await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.addStyleTag({ content: RESTING_CSS });
    await page.waitForTimeout(300);
    const name = `landing-${mode}-${width}`;
    await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
    console.log(`captured ${name}.png`);
  }
  await ctx.close();
}

// ---- Reduced-motion still: 1440 dark, real media query, no injection ----
{
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    reducedMotion: "reduce",
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.evaluate(() => {
    localStorage.setItem("phx:theme", "dark");
    document.documentElement.setAttribute("data-theme", "dark");
    document.documentElement.setAttribute("data-theme-source", "user");
  });
  await page.waitForTimeout(400);
  await page.screenshot({
    path: `${outdir}/landing-reduced-motion-dark-1440.png`,
    fullPage: true,
  });
  console.log("captured landing-reduced-motion-dark-1440.png");
  await ctx.close();
}

// ---- GIFs (only where the landing scope + its motion exist) ----
{
  const probe = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const probePage = await probe.newPage();
  await probePage.goto(`${BASE}/`, { waitUntil: "networkidle" });
  const hasLanding = (await probePage.locator(".landing").count()) > 0;
  await probe.close();
  if (!hasLanding) {
    console.log("no .landing scope — skipping motion GIFs (pre-rebuild page)");
    await browser.close();
    writeFileSync(`${outdir}/done`, new Date().toISOString());
    process.exit(0);
  }
}

const record = async (mode, name, run) => {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: outdir, size: { width: 1440, height: 900 } },
  });
  const page = await ctx.newPage();
  await page.addInitScript((m) => localStorage.setItem("phx:theme", m), mode);
  const video = page.video();
  await run(page);
  await ctx.close();
  const webm = await video.path();
  execFileSync("ffmpeg", [
    "-y",
    "-i",
    webm,
    "-vf",
    "fps=12,scale=720:-1:flags=lanczos",
    `${outdir}/${name}.gif`,
  ]);
  console.log(`captured ${name}.gif`);
};

// 1) load reveal — fresh navigation, first ~4s
await record("dark", "landing-load-dark", async (page) => {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(4000);
});

// 2) scroll — slow scroll through the first ~1200px, dark + light
const scrollRun = async (page) => {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(2000); // load reveal finishes first
  for (let i = 0; i < 24; i++) {
    await page.mouse.wheel(0, 50);
    await page.waitForTimeout(120);
  }
  await page.waitForTimeout(400);
};
await record("dark", "landing-scroll-dark", scrollRun);
await record("light", "landing-scroll-light", scrollRun);

// 3) hover — hero panel, then a bento cell, then an app card
await record("dark", "landing-hover-dark", async (page) => {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(2000);
  for (const sel of [".landing .panel", ".landing .cell", ".landing .app-card"]) {
    const el = page.locator(sel).first();
    if ((await el.count()) === 0) {
      console.log(`skip hover: ${sel} not found`);
      continue;
    }
    await el.hover();
    await page.waitForTimeout(900);
  }
});

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
