/* #408 motion capture: the creation page's derive-as-you-type IS the
 * change — typing the name moves the address line on every keystroke —
 * so a short GIF rides the stills. Built the #364 way: recordVideo's
 * fallback encoder on this box writes stale frames, so the motion is
 * captured by stepping screenshots through it and assembling with
 * ffmpeg (720px, lanczos, per the owner GIF rule).
 *
 * The clip, 1440x900 light, cropped to the form card:
 *   focus the name → type "Acme Robotics" letter by letter → the
 *   preview line derives "/organizations/acme-robotics" live → hold.
 *   Assembled at a 7fps input rate — the owner rule's fps=12 figure is
 *   for video-to-gif conversion; frame-stepped shots pace by -framerate.
 *
 * Usage: node org_new_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 * Assemble with the ffmpeg line printed at the end.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv408-gif";
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

await page.goto(`${BASE}/organizations/new`, { waitUntil: "networkidle" });
await page.waitForFunction(
  () =>
    document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
  null,
  { timeout: 15_000 },
);

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

// The motion: focus → type letter by letter (each keystroke's
// phx-change re-derives the address server-side) → hold on the result.
const name = page.getByTestId("org-new-name-input");
await name.click();
await page.waitForTimeout(250);
await hold(2);

for (const ch of "Acme") {
  await name.pressSequentially(ch, { delay: 0 });
  await page.waitForTimeout(250);
  await frame();
}

await page
  .getByTestId("slug-preview")
  .filter({ hasText: "/organizations/acme" })
  .waitFor({ timeout: 10_000 });

for (const ch of " Robotics") {
  await name.pressSequentially(ch, { delay: 0 });
  await page.waitForTimeout(250);
  await frame();
}

await page
  .getByTestId("slug-preview")
  .filter({ hasText: "/organizations/acme-robotics" })
  .waitFor({ timeout: 10_000 });
await page.waitForTimeout(300);
await hold(6);

// The crop frame — the form card, measured once.
const card = await page.locator("#org-new-card").boundingBox();
const x = Math.max(0, Math.round(card.x) - 16);
const y = Math.max(0, Math.round(card.y) - 16);
const w = Math.min(1440 - x, Math.round(card.width) + 32);
const h = Math.min(900 - y, Math.round(card.height) + 32);

await ctx.close();
await browser.close();
console.log(`${n} frames in ${outdir}/frames; card crop ${w}:${h}:${x}:${y}`);
console.log(`assemble with:
  ffmpeg -y -framerate 7 -i ${outdir}/frames/f%02d.png -vf "crop=${w}:${h}:${x}:${y},scale=720:-1:flags=lanczos" ${outdir}/org-new-derive.gif`);
