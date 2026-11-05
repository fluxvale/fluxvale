// #470 pricing calculator captures: the line-item estimate model.
// Stills (light+dark, desktop): the working-calculator mount state and
// a stacked estimate (two different setups + gateway on). Mobile: the
// stacked state. GIF: pick app -> adjust -> Add -> pick second app ->
// adjust -> Add -> remove a row (the add-stack-remove motion).
// Usage: node s470_shots.mjs <outdir> (FV_BASE optional, default the
// local dev server on port 4000).
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/s470-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// The stacked estimate: two different setups plus the gateway toggle.
async function stack(page) {
  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);

  // First setup: pick the first app (snap), nudge CPU, add.
  await page.locator("#calculator-app-filter").click();
  await page.waitForTimeout(300);
  await page.locator("[data-testid^='calculator-app-option-']").first().click();
  await page.waitForTimeout(600);
  await moveSlider(page, "#resource-cpu-cores", "2");
  await page.locator("[data-testid='calculator-add-instances']").click();
  await page.waitForTimeout(700);

  // Second setup: pick another app, nudge memory, add.
  await page.locator("#calculator-app-filter").click();
  await page.waitForTimeout(300);
  await page.locator("[data-testid^='calculator-app-option-']").nth(1).click();
  await page.waitForTimeout(600);
  await moveSlider(page, "#resource-memory-mb", "3");
  await page.locator("[data-testid='calculator-add-instances']").click();
  await page.waitForTimeout(700);

  // The org-level gateway joins the estimate once.
  await page.locator("[data-testid='service-toggle-gateway']").click();
  await page.waitForTimeout(700);
}

async function moveSlider(page, selector, value) {
  await page.locator(selector).evaluate((el, v) => {
    el.value = v;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await page.waitForTimeout(600);
}

const calc = page => page.locator("[data-testid='pricing-calculator']");

// Stills: the mount state (working calculator, gated Add), then the
// stacked estimate, light + dark.
for (const theme of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1200 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  const page = await ctx.newPage();

  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  await calc(page).scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  await calc(page).screenshot({ path: `${outdir}/calculator-${theme}.png` });
  console.log(`captured calculator-${theme}.png`);

  await stack(page);
  await calc(page).scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  await calc(page).screenshot({ path: `${outdir}/estimate-${theme}.png` });
  console.log(`captured estimate-${theme}.png`);

  await ctx.close();
}

// Mobile stills: the stacked estimate at phone width.
for (const theme of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 1100 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  const page = await ctx.newPage();

  await stack(page);
  await calc(page).scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  await calc(page).screenshot({ path: `${outdir}/estimate-mobile-${theme}.png` });
  console.log(`captured estimate-mobile-${theme}.png`);

  await ctx.close();
}

// Motion: the add-stack-remove flow (theme-independent interaction).
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 1200 },
  recordVideo: { dir: outdir, size: { width: 1440, height: 1200 } },
});
await ctx.addInitScript(() => localStorage.setItem("phx:theme", "light"));
const page = await ctx.newPage();
await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });

const box = await calc(page).evaluate((n) => {
  const r = n.getBoundingClientRect();
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
});
console.log(`calculator bbox: ${JSON.stringify(box)}`);

await calc(page).scrollIntoViewIfNeeded();
await page.waitForTimeout(700);

await stack(page);
await page.waitForTimeout(500);
await page.locator("[data-testid='estimate-remove-1']").click();
await page.waitForTimeout(900);

const video = page.video();
await ctx.close();
const webm = await video.path();

const m = 24; // margin around the calculator
const x = Math.max(0, box.x - m);
const y = Math.max(0, box.y - m);
const w = Math.min(1440 - x, box.w + 2 * m);
const h = Math.min(1200 - y, box.h + 2 * m);
const out = `${outdir}/estimate-motion-light.gif`;
execFileSync("ffmpeg", [
  "-y",
  "-i",
  webm,
  "-vf",
  `fps=12,crop=${w}:${h}:${x}:${y},scale=720:-1:flags=lanczos`,
  out,
]);
unlinkSync(webm);
console.log(`captured estimate-motion-light.gif (crop=${w}:${h}:${x}:${y})`);

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
