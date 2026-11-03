/* #364 motion capture: the country combobox's type → filter → select
 * motion IS the change, so a short GIF rides the stills. Built the S7
 * way — recordVideo's fallback encoder on this box writes stale frames
 * (verified twice on this run: the webm froze mid-typing while the
 * page had long committed the selection), so the motion is captured by
 * stepping screenshots through it and assembling with ffmpeg
 * (fps=12-equivalent pacing, lanczos, per the owner GIF rule).
 *
 * The clip, 1440x900 light, cropped to the details card:
 *   focus the query → type "phi" → the listbox filters to the
 *   Philippines → click the row → the control reads "Philippines (PH)".
 *
 * Usage: node s364_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 * Assemble with the ffmpeg line printed at the end.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4192";
const outdir = process.argv[2] ?? "/tmp/opencode/s364-gif";
mkdirSync(`${outdir}/frames`, { recursive: true, force: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
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

await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
await page.waitForFunction(
  () =>
    document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
  null,
  { timeout: 15_000 },
);
await page.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe");

let n = 0;
const shot = async (path) => {
  // Chromium can refuse a capture mid-frame; one retry after a beat.
  try {
    await page.screenshot({ path });
  } catch {
    await page.waitForTimeout(120);
    await page.screenshot({ path });
  }
};
const frame = async () => {
  await shot(`${outdir}/frames/f${String(n++).padStart(2, "0")}.png`);
};
const hold = async (times) => {
  for (let i = 0; i < times; i++) {
    await frame();
    await page.waitForTimeout(90);
  }
};

// The motion: focus → type letter by letter (the listbox filters on
// each change) → hold on the filtered row → Enter commits.
const query = page.locator("#country-query");
await query.click();
await page.waitForTimeout(250);
await hold(2);

await query.pressSequentially("p", { delay: 0 });
await page.waitForTimeout(250);
await frame();
await query.pressSequentially("h", { delay: 0 });
await page.waitForTimeout(250);
await frame();
await query.pressSequentially("i", { delay: 0 });
await page.locator("#country-listbox").waitFor();
await page
  .locator("#country-option-0")
  .filter({ hasText: "Philippines" })
  .waitFor({ timeout: 5_000 });
await page.waitForTimeout(300);
await hold(5);

// The select: a click on the row (the keyboard path is unit-tested;
// the screencast needs a deterministic gesture).
await page.locator("#country-option-0").click();
await page.locator("#country-listbox").waitFor({ state: "detached" });
await page.waitForTimeout(350);
await hold(6);

// The crop frame — the details card, measured once.
const card = await page
  .locator("section.wrap .rounded-panel")
  .first()
  .boundingBox();
const x = Math.max(0, Math.round(card.x) - 16);
const y = Math.max(0, Math.round(card.y) - 16);
const w = Math.min(1440 - x, Math.round(card.width) + 32);
const h = Math.min(900 - y, Math.round(card.height) + 32);

await ctx.close();
await browser.close();
console.log(`${n} frames in ${outdir}/frames; card crop ${w}:${h}:${x}:${y}`);
console.log(`assemble with:
  ffmpeg -y -framerate 7 -i ${outdir}/frames/f%02d.png -vf "crop=${w}:${h}:${x}:${y},scale=720:-1:flags=lanczos" ${outdir}/s364-country-combobox.gif`);
