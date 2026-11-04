// #440 captures: the calculator-as-surface before/after — stills
// (light+dark, desktop+mobile, full page) plus one GIF of the new
// interaction on the AFTER build (dropdown select, slider move, toggle
// on). AFTER server = the feature branch dev server (port 4000);
// BEFORE server = main's dev server (port 4100). Same dev DB, so the
// seeds agree; only the code differs.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const AFTER = process.env.FV_AFTER ?? "http://127.0.0.1:4000";
const BEFORE = process.env.FV_BEFORE ?? "http://127.0.0.1:4100";
const outdir = process.argv[2] ?? "/tmp/opencode/s440-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function themedContext(theme, viewport, video) {
  const ctx = await browser.newContext({
    viewport,
    recordVideo: video ? { dir: video.dir, size: video.size } : undefined,
  });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  return ctx;
}

async function shot(ctx, url, file) {
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  await page.screenshot({ path: file, fullPage: true });
  await page.close();
  console.log("captured", file);
}

// Full-page pricing stills (desktop + mobile, light + dark, before+after).
for (const theme of ["light", "dark"]) {
  for (const [label, base] of [
    ["before", BEFORE],
    ["after", AFTER],
  ]) {
    const desk = await themedContext(theme, { width: 1440, height: 900 });
    await shot(desk, `${base}/pricing`, `${outdir}/pricing-${label}-${theme}.png`);
    await desk.close();

    const mobile = await themedContext(theme, { width: 375, height: 812 });
    await shot(
      mobile,
      `${base}/pricing`,
      `${outdir}/pricing-${label}-mobile-${theme}.png`,
    );
    await mobile.close();
  }
}

// The interaction GIF: on the AFTER build, pick an app from the native
// dropdown, move the CPU slider, then toggle the gateway on — the three
// moves the page now prices live.
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });
const ctx = await themedContext("light", { width: 1280, height: 900 }, {
  dir: videoDir,
  size: { width: 1280, height: 900 },
});
const page = await ctx.newPage();
await page.goto(`${AFTER}/pricing`, { waitUntil: "networkidle" });
await page.waitForTimeout(1000);
await page.locator("#calculator").scrollIntoViewIfNeeded();
await page.waitForTimeout(800);

// 1. Dropdown select: the first real app option (skip the prompt).
const appSlug = await page
  .locator("#calculator-app-select option:not([value=''])")
  .first()
  .getAttribute("value");
await page.selectOption("#calculator-app-select", appSlug);
await page.waitForTimeout(1200);

// 2. Slider move: the CPU range input addresses its ladder by index.
await page.getByTestId("resource-cpu").fill("3");
await page.waitForTimeout(1200);

// 3. Toggle the gateway on: its accessor cents join the hero total.
await page.check('input[name="services[gateway]"]');
await page.waitForTimeout(1500);

await page.close();
await ctx.close();
console.log("recorded interaction video");

await browser.close();
