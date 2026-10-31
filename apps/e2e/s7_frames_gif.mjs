/* S7 motion GIF via frame-stepped screenshots (recordVideo's fallback
 * encoder on this box writes stale frames — verified: page.url() said
 * /apps while the webm showed sign-in). Screenshots provably work, so
 * the reveal is captured by stepping: commit -> burst of viewport
 * shots across the rise, then a hover-lift pair. Assembled by ffmpeg
 * (fps=12, lanczos, per the owner GIF rule).
 *
 * Usage: node s7_frames_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4190";
const outdir = process.argv[2] ?? "/tmp/opencode/s7-gif";
mkdirSync(`${outdir}/frames`, { recursive: true, force: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 720 } });
const page = await ctx.newPage();

await page.addInitScript(() => {
  localStorage.setItem("phx:theme", "light");
  document.documentElement.setAttribute("data-theme", "light");
  document.documentElement.setAttribute("data-theme-source", "user");
});

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

// The reveal: navigate and screenshot in a tight burst — the rise runs
// --motion-slow with a 170ms stagger, so ~14 shots at ~70ms cover it.
// A failed navigation must stop the script, not shoot stale frames.
const nav = page.goto(`${BASE}/apps`, { waitUntil: "commit" });
await nav;
let n = 0;
const burst = async (prefix, times) => {
  for (let i = 0; i < times; i++) {
    await page.screenshot({
      path: `${outdir}/frames/${prefix}${String(n++).padStart(2, "0")}.png`,
    });
    await page.waitForTimeout(70);
  }
};
await burst("f", 14);

// The card lift: hover the first card, hold two frames, release.
const box = await page.locator("#catalog-mosaic > a").first().boundingBox();
await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(350);
await burst("f", 3);
await page.mouse.move(10, 10);
await page.waitForTimeout(350);
await burst("f", 3);

await ctx.close();
await browser.close();
console.log(`${n} frames in ${outdir}/frames`);
