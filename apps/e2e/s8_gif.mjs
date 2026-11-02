/* S8 GIF: a step transition — the motion this slice touches. Records
 * the wizard advancing version → configuration → resources (two
 * LiveView patches, the band's rise settled first so only the step
 * swap is on tape). The rise/transition NOT replaying per patch is the
 * measured claim (s8_measure.mjs); the GIF shows what a transition
 * actually looks like.
 *
 * The tape includes sign-in + navigation; trim it at conversion (the
 * shipped GIF used -ss 3.6):
 *   ffmpeg -y -ss 3.6 -i page@<hash>.webm \
 *     -vf "fps=12,scale=720:-1:flags=lanczos" s8-step-transition.gif
 *
 * Usage: node s8_gif.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 * ffmpeg converts the webm → gif afterwards.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4191";
const outdir = process.argv[2] ?? "/tmp/opencode/s8-gif";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 860 },
  recordVideo: { dir: outdir, size: { width: 1440, height: 860 } },
});
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);

// One live-socket assertion, the S7 lesson (same helper as s9/s10):
// the step clicks below ride the socket — firing them into a dead
// page tapes a wizard that never advances.
const live = (pg) =>
  pg.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
await live(page);
// let the mount rise finish before the tape's real content
await page.waitForTimeout(1800);

// transition 1: version → configuration (band stepper 1→2, card swap)
await page.locator("[data-testid='version-option']").first().click();
await page.locator("[data-testid='continue-version']").click();
await page.evaluate(() => window.scrollTo({ top: 0 }));
await page.waitForTimeout(1500);

// transition 2: configuration → resources (the picker arrives)
await page.locator("[data-testid='continue-env']").click();
await page.evaluate(() => window.scrollTo({ top: 0 }));
await page.waitForTimeout(1500);

await ctx.close();
await browser.close();
console.log(`webm at ${outdir}`);
