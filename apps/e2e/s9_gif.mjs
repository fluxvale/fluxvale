/* S9 motion captures: the change is motion (the grammar's container
 * rise lands on the billing trio), so a short GIF rides the stills.
 * Two clips, 1440x900 light:
 *   1. /billing page load — the band + sections rise once
 *   2. the top-up wizard details → amount step patch — the frame stays,
 *      no rise replay inside the steps (the S8-measured pattern)
 * recordVideo per clip → webm; trimmed to the motion by ffmpeg.
 *
 * Usage: node s9_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4192";
const outdir = process.argv[2] ?? "/tmp/opencode/s9-gif";
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
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);

// Clip 1: the billing page load reveal.
await page.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
await page.waitForTimeout(2500);

// Clip 2: the wizard step transition — load at details, advance to
// amount, hold. The band must not replay its rise on the patch.
await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
await page.waitForTimeout(2000);
await page.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe");
await page.locator("#topup-details-form input[name='details[country]']").fill("DE");
await page.waitForTimeout(300);
await page.locator("#topup-details-next").click();
await page.waitForTimeout(2500);

await ctx.close();
await browser.close();
console.log(`webm clips written to ${outdir} — trim with:
  ffmpeg -i in.webm -vf "fps=12,scale=720:-1:flags=lanczos" out.gif`);
