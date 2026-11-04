// #397 pricing calculator captures: the calculator section (light+dark
// stills) plus a GIF of the chip/slider motion (recordVideo → ffmpeg,
// cropped to the calculator card; the motion is theme-independent, so
// one GIF). Usage: node pricing_calculator_shots.mjs <outdir>
// (FV_BASE optional, default the local dev server on port 4000).
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/pricing-calculator-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// Stills: the calculator block, light + dark.
for (const theme of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  const calc = page.locator("[data-testid='pricing-calculator']");
  await calc.scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  await calc.screenshot({ path: `${outdir}/calculator-${theme}.png` });
  console.log("captured", `calculator-${theme}.png`);
  await ctx.close();
}

// Motion: size chips, a slider rung step, an app pick, back to small —
// repricing live through every step.
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 1100 },
  recordVideo: { dir: outdir, size: { width: 1440, height: 1100 } },
});
await ctx.addInitScript(() => localStorage.setItem("phx:theme", "light"));
const page = await ctx.newPage();
await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
const calc = page.locator("[data-testid='pricing-calculator']");
await calc.scrollIntoViewIfNeeded();
await page.waitForTimeout(700);

const box = await calc.evaluate((n) => {
  const r = n.getBoundingClientRect();
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
});
console.log(`calculator bbox: ${JSON.stringify(box)}`);

await page.locator("[data-testid='size-chip-micro']").click();
await page.waitForTimeout(800);
await page.locator("[data-testid='size-chip-pro']").click();
await page.waitForTimeout(800);

const cpu = page.locator("#resource-cpu-cores");
await cpu.evaluate((el) => {
  el.value = "0";
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
});
await page.waitForTimeout(800);

const appChip = page.locator("[data-testid^='app-chip-']").first();
if ((await appChip.count()) > 0) {
  await appChip.click();
  await page.waitForTimeout(900);
}

await page.locator("[data-testid='size-chip-small']").click();
await page.waitForTimeout(800);

const video = page.video();
await ctx.close();
const webm = await video.path();

const m = 24; // margin around the calculator
const x = Math.max(0, box.x - m);
const y = Math.max(0, box.y - m);
const w = Math.min(1440 - x, box.w + 2 * m);
const h = Math.min(1100 - y, box.h + 2 * m);
const out = `${outdir}/calculator-motion-light.gif`;
execFileSync("ffmpeg", [
  "-y",
  "-i",
  webm,
  "-vf",
  `fps=12,crop=${w}:${h}:${x}:${y},scale=720:-1:flags=lanczos`,
  out,
]);
unlinkSync(webm);
console.log(`captured calculator-motion-light.gif (crop=${w}:${h}:${x}:${y})`);

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
