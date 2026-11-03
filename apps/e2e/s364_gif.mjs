/* #364 motion capture: the country combobox's type → filter → select
 * motion IS the change, so a short GIF rides the stills. One clip,
 * 1440x900 light: on the wizard's details step, type "phi" into the
 * country query, the listbox filters to the Philippines, Enter commits
 * it and the control reads "Philippines (PH)".
 *
 * The clip is cropped to the details card (bounding box measured in
 * the browser) so the motion reads at GIF scale; the ffmpeg crop
 * string prints at the end.
 *
 * Usage: node s364_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync, renameSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4192";
const outdir = process.argv[2] ?? "/tmp/opencode/s364-gif";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: outdir, size: { width: 1440, height: 900 } },
});

// One live-socket assertion, the S7 lesson (see s9_capture.mjs).
const live = (page) =>
  page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);

await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
await live(page);
await page.waitForTimeout(1500);

// The motion: type the query letter by letter (the listbox filters on
// each change), then commit with Enter.
await page.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe", { timeout: 5_000 });
const query = page.locator("#country-query");
await query.click();
await query.pressSequentially("phi", { delay: 150 });
await page.locator("#country-listbox").waitFor();
await page.waitForTimeout(600);

// Measure the details card before the Enter commit — the crop frame
// is the motion's stage.
const card = await page.locator(".card").first().boundingBox();
await page.keyboard.press("Enter");
await page.locator("#country-listbox").waitFor({ state: "detached" });
await page.waitForTimeout(1000);

const video = page.video();
await page.close();
const recorded = await video.path();
const target = `${outdir}/s364-country-combobox.webm`;
renameSync(recorded, target);
console.log(`clip written: ${target}`);

// Crop to the details card (clamped to the frame, small margins) so
// the GIF reads at 720px wide.
const x = Math.max(0, Math.round(card.x) - 16);
const y = Math.max(0, Math.round(card.y) - 16);
const w = Math.min(1440 - x, Math.round(card.width) + 32);
const h = Math.min(900 - y, Math.round(card.height) + 32);
console.log(`card: x=${x} y=${y} w=${w} h=${h}`);
console.log(`convert with:
  ffmpeg -i ${target} -vf "fps=12,crop=${w}:${h}:${x}:${y},scale=720:-1:flags=lanczos" ${outdir}/s364-country-combobox.gif`);

await ctx.close();
await browser.close();
