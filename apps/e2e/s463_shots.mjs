// #463 captures: the pricing change order on /pricing — stills (light +
// dark, desktop + mobile) with the recommendation line and the search
// panel open, plus one GIF of the motion: filter the chooser, pick an
// app, drift a slider, restore with "Use recommended", and raise the
// quantity. AFTER server = the feature branch dev server (port 4000);
// BEFORE server = main's dev server (port 4100), optional via FV_BEFORE.
import { chromium } from "@playwright/test";
import { mkdirSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";

const AFTER = process.env.FV_AFTER ?? "http://127.0.0.1:4000";
const BEFORE = process.env.FV_BEFORE ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/s463-shots";
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

async function openCalculator(ctx) {
  const page = await ctx.newPage();
  await page.goto(`${AFTER}/pricing`, { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  await page.locator("#calculator").scrollIntoViewIfNeeded();
  await page.waitForTimeout(500);
  return page;
}

async function pickFirstApp(page, text = "for") {
  await page.fill("#calculator-app-filter", text);
  await page.waitForTimeout(500);
  await page.locator("[data-testid^='calculator-app-option-']").first().click();
  await page.waitForTimeout(800);
}

// AFTER stills: an app selected so the recommendation line is visible,
// and a second still with the search panel open.
for (const theme of ["light", "dark"]) {
  const desk = await themedContext(theme, { width: 1440, height: 900 });
  const page = await openCalculator(desk);
  await pickFirstApp(page);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/pricing-after-${theme}.png`, fullPage: true });
  await page.close();

  const filtered = await openCalculator(desk);
  await filtered.fill("#calculator-app-filter", "for");
  await filtered.waitForTimeout(500);
  await filtered.screenshot({
    path: `${outdir}/pricing-search-open-${theme}.png`,
    fullPage: false,
  });
  await filtered.close();
  await desk.close();

  const mobile = await themedContext(theme, { width: 375, height: 812 });
  const phone = await openCalculator(mobile);
  await pickFirstApp(phone);
  await phone.evaluate(() => window.scrollTo(0, 0));
  await phone.waitForTimeout(400);
  await phone.screenshot({
    path: `${outdir}/pricing-after-mobile-${theme}.png`,
    fullPage: true,
  });
  await phone.close();
  await mobile.close();
}

// BEFORE stills when a main-branch server is provided.
if (BEFORE) {
  for (const theme of ["light", "dark"]) {
    const ctx = await themedContext(theme, { width: 1440, height: 900 });
    const page = await ctx.newPage();
    await page.goto(`${BEFORE}/pricing`, { waitUntil: "networkidle" });
    await page.waitForTimeout(800);
    await page.screenshot({ path: `${outdir}/pricing-before-${theme}.png`, fullPage: true });
    await page.close();
    await ctx.close();
  }
}

// The motion GIF: filter, pick, drift, restore, quantity.
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });
const ctx = await themedContext("light", { width: 1280, height: 1450 }, {
  dir: videoDir,
  size: { width: 1280, height: 1450 },
});
const page = await openCalculator(ctx);

await page.click("#calculator-app-filter");
await page.waitForTimeout(400);
await page.type("#calculator-app-filter", "for", { delay: 120 });
await page.waitForTimeout(900);
await page.locator("[data-testid^='calculator-app-option-']").first().click();
await page.waitForTimeout(1200);

// Drift the CPU slider so the line offers "Use recommended".
await page.getByTestId("resource-cpu").fill("3");
await page.waitForTimeout(1000);
await page.click("#calculator-use-recommended");
await page.waitForTimeout(1200);

// Two more instances: the hero multiplies, the org services do not.
await page.click("#calculator-quantity-increase");
await page.waitForTimeout(700);
await page.click("#calculator-quantity-increase");
await page.waitForTimeout(1500);

const video = page.video();
await page.close();
await ctx.close();

const webm = await video.path();
const out = `${outdir}/pricing-change-order.gif`;
execFileSync("ffmpeg", [
  "-y",
  "-i",
  webm,
  "-vf",
  "fps=12,scale=720:-1:flags=lanczos",
  out,
]);
unlinkSync(webm);
console.log(`captured ${out}`);

await browser.close();
