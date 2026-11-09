/* The member storage-request card screenshots (#250 S4, the owner's
 * screenshot convention): the boundary row, the inline form, the open
 * request card, and the rejection card — light and dark each — plus a
 * short GIF of form -> submit -> status (the change is motion).
 *
 * Local dev target only. Stage the rows with fv250s4_seed.exs, then:
 *   FV_TOKEN=… FV_FREE=… FV_REQUESTED=… FV_REJECTED=… \
 *     node fv250s4_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? process.env.TOKEN;
const freeId = process.env.FV_FREE;
const requestedId = process.env.FV_REQUESTED;
const rejectedId = process.env.FV_REJECTED;
const outdir = process.argv[2] ?? "/tmp/opencode/fv250s4-shots";

mkdirSync(outdir, { recursive: true });
mkdirSync(`${outdir}/video`, { recursive: true });

if (!token || !freeId || !requestedId || !rejectedId) {
  console.error("FV_TOKEN, FV_FREE, FV_REQUESTED, and FV_REJECTED are required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session: POST /auth/session (the sign-in flow's own write).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const response = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
const bounced = new URL(response.url()).pathname === "/sign-in";
if (!response.ok() || bounced) {
  throw new Error(`Sign-in failed (status ${response.status()}); check FV_TOKEN`);
}

// The pristine signed-in state (no theme choice yet) — the GIF records
// in its own context and must not inherit the stills' last dark theme.
const signedInState = await ctx.storageState();

const setTheme = (target, mode) =>
  target.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

const card = () => page.locator("[data-testid='storage-card']");

const gotoInstance = async (id) => {
  await page.goto(`${BASE}/instances/${id}`, { waitUntil: "networkidle" });
  await card().waitFor();
};

const captureCard = async (name, mode) => {
  await setTheme(page, mode);
  await page.waitForTimeout(300);
  await card().screenshot({ path: `${outdir}/${name}-${mode}.png` });
  console.log(`captured ${name}-${mode}.png`);
};

for (const mode of ["light", "dark"]) {
  // The boundary row with nothing requested.
  await gotoInstance(freeId);
  await captureCard("storage-card", mode);

  // The inline form, carrying a real target and reason so the live
  // projection and the copy are both visible.
  await gotoInstance(freeId);
  await page.locator("[data-testid='storage-request-open']").click();
  await page.locator("#storage-request-form").waitFor();
  await page.locator("#storage_request_requested_gb").fill("200");
  await page.locator("#storage_request_reason").fill(
    "We're archiving this year's field recordings and need room to keep them."
  );
  await page.waitForTimeout(400);
  await captureCard("storage-form", mode);

  // The open request: awaiting review.
  await gotoInstance(requestedId);
  await captureCard("storage-status", mode);

  // The terminal rejection: the operator's feedback, verbatim.
  await gotoInstance(rejectedId);
  await captureCard("storage-rejected", mode);
}

await ctx.close();

// The GIF: form -> submit -> status, cropped to the card.
const videoCtx = await browser.newContext({
  viewport: { width: 900, height: 820 },
  storageState: signedInState,
  recordVideo: { dir: `${outdir}/video`, size: { width: 900, height: 820 } },
});
const videoPage = await videoCtx.newPage();

await videoPage.goto(`${BASE}/instances/${freeId}`, { waitUntil: "networkidle" });
await setTheme(videoPage, "light");
await videoPage.locator("[data-testid='storage-card']").scrollIntoViewIfNeeded();
// Let the LiveView connect settle on the light theme before the motion
// is recorded (the early frames are the server-rendered pre-connect
// paint, and the trim starts at the first interesting frame).
await videoPage.waitForTimeout(1800);

await videoPage.locator("[data-testid='storage-request-open']").click();
await videoPage.locator("#storage-request-form").waitFor();
await videoPage.waitForTimeout(500);
await videoPage.locator("#storage_request_requested_gb").fill("250");
await videoPage.locator("#storage_request_reason").fill("Room for the media archive.");
await videoPage.waitForTimeout(900);

const box = await videoPage.locator("[data-testid='storage-card']").boundingBox();

await videoPage.locator("[data-testid='storage-request-submit']").click();
await videoPage.locator("[data-testid='storage-request-status']").waitFor();
await videoPage.waitForTimeout(600);

const video = videoPage.video();
await videoPage.close();
const videoPath = await video.path();
await videoCtx.close();

const cropW = Math.floor(Math.min(box.width, 900) / 2) * 2;
const cropH = Math.floor(Math.min(box.height, 820 - Math.max(0, box.y)) / 2) * 2;
const cropX = Math.max(0, Math.floor(box.x / 2) * 2);
const cropY = Math.max(0, Math.floor(box.y / 2) * 2);

execFileSync("ffmpeg", [
  "-y",
  "-ss",
  "0.5",
  "-i",
  videoPath,
  "-vf",
  `fps=12,crop=${cropW}:${cropH}:${cropX}:${cropY},scale=720:-1:flags=lanczos`,
  `${outdir}/storage-request.gif`,
]);

console.log("captured storage-request.gif");
await browser.close();
