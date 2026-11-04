/* Roadmap screenshots (#412 T9): the roadmap page, light + dark,
 * full resolution (fullPage). Anonymous surface — no session needed
 * (the feedback lane's pattern). The starter posts come from the
 * promotable seed (Seeds.seed_feedback!/0), so a fresh `mix setup` dev
 * server has them.
 *
 * Usage: node roadmap_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/roadmap-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function capture(name, path, mode, viewport) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
  console.log(`captured ${name}-${mode}.png`);
  await ctx.close();
}

for (const mode of ["light", "dark"]) {
  await capture("roadmap", "/roadmap", mode, { width: 1440, height: 900 });
}

await browser.close();
