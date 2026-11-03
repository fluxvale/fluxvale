// Positioning-pass captures (#365): anonymous landing + public catalog
// stills (1440x900, light + dark, fullPage) — the surfaces whose copy
// the pass retires. Same mechanics as landing_screenshot.mjs: theme via
// localStorage `phx:theme` + `data-theme` evaluate + 300ms settle, and
// the resting-state CSS override so scroll reveals can't hollow out a
// fullPage capture.
//
// Usage: node positioning_screenshot.mjs <outdir>   (FV_BASE optional;
// default http://127.0.0.1:4172 — the lane convention, sibling lanes
// share the machine)
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4172";
const outdir = process.argv[2] ?? "/tmp/opencode/fv365-shots";
mkdirSync(outdir, { recursive: true });

const RESTING_CSS = `
  .landing .rise, .landing .drop, .landing .reveal,
  .landing .px-slow, .landing .px-panel {
    animation: none !important; opacity: 1 !important; transform: none !important;
  }`;

const shots = [
  ["landing", "/"],
  ["catalog", "/catalog"],
];

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

for (const mode of ["light", "dark"]) {
  for (const [name, path] of shots) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.addStyleTag({ content: RESTING_CSS });
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await ctx.close();
await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
