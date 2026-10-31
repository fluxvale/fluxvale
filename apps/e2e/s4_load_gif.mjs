/* S4 load-reveal GIF: the .rise page reveal on the dashboard (band +
 * cards + rows, staggered). Playwright recordVideo -> webm, trimmed to
 * the motion, then ffmpeg -> gif (mechanics per the owner GIF rule).
 *
 * The theme is pinned LIGHT via addInitScript (before any page script)
 * — the capture's named mode is the mode it records.
 *
 * Usage: node s4_load_gif.mjs <outdir>
 */

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/s4-shots";
mkdirSync(outdir, { recursive: true });

if (!TOKEN) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: `${outdir}/video`, size: { width: 1440, height: 900 } },
});
const page = await ctx.newPage();

// theme pinned before any page script runs
await page.addInitScript(() => {
  localStorage.setItem("phx:theme", "light");
  document.documentElement.setAttribute("data-theme", "light");
  document.documentElement.setAttribute("data-theme-source", "user");
});

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

// The reveal: navigation to / records the .rise stagger.
await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
await page.waitForTimeout(2500);

if (page.url().includes("/sign-in")) throw new Error("session failed");

const videoPath = await page.video().path();
await ctx.close();
await browser.close();
console.log(`webm at ${videoPath}`);
