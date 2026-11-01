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

// Playwright records per PAGE, and a page's video finalizes on close —
// so each clip gets its own page (and its own file, renamed on close);
// one shared page used to record sign-in + both clips into a single
// WebM (CodeRabbit #351).
// One live-socket assertion, the S7 lesson (see s9_capture.mjs).
const live = (page) =>
  page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

const signIn = async (page) => {
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const session = await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);
};

const saveClip = async (page, name) => {
  const video = page.video();
  await page.close();
  const recorded = await video.path();
  const target = `${outdir}/${name}.webm`;
  const { renameSync } = await import("node:fs");
  renameSync(recorded, target);
  console.log(`clip written: ${target}`);
};

// Clip 1: the billing page load reveal.
const billing = await ctx.newPage();
await signIn(billing);
await billing.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
await live(billing);
await billing.waitForTimeout(2500);
await saveClip(billing, "s9-band-rise");

// Clip 2: the wizard step transition — load at details, advance to
// amount, hold. The band must not replay its rise on the patch.
const wizard = await ctx.newPage();
await signIn(wizard);
await wizard.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
await live(wizard);
await wizard.waitForTimeout(2000);
await wizard.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe");
await wizard.locator("#topup-details-form input[name='details[country]']").fill("DE");
await wizard.waitForTimeout(300);
await wizard.locator("#topup-details-next").click();
await wizard.waitForTimeout(2500);
await saveClip(wizard, "s9-step-transition");

await ctx.close();
await browser.close();
console.log(`trimmed with:
  ffmpeg -i s9-band-rise.webm -vf "fps=12,scale=720:-1:flags=lanczos" s9-band-rise.gif
  ffmpeg -i s9-step-transition.webm -vf "fps=12,scale=720:-1:flags=lanczos" s9-step-transition.gif`);
