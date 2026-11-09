/* Operator storage-request queue captures (#250). Deterministic: one
 * seeded state (admin_storage_requests_seed.exs), light and dark from
 * the same state; the live insert GIF records the queue while the
 * member API creates a third request, so the sidebar badge and the row
 * move over PubSub with no reload.
 *
 *   node admin_storage_requests_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv250-s5-shots";
mkdirSync(outdir, { recursive: true });
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const pat = process.env.FV_PAT ?? "";
const liveInstanceId = process.env.FV_LIVE_INSTANCE_ID ?? "";

const missing = Object.entries({ token, pat, liveInstanceId })
  .filter(([, value]) => !value)
  .map(([key]) => key);

if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_storage_requests_seed.exs)`);
  process.exit(1);
}

async function setTheme(page, mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

const browser = await chromium.launch();

async function newSession({ video = false } = {}) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    ...(video ? { recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } } : {}),
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

async function cookieSession(startUrl, { video = false } = {}) {
  const warm = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const warmPage = await warm.newPage();
  await warmPage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await warmPage.locator('meta[name="csrf-token"]').getAttribute("content");
  await warmPage.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  const cookies = await warm.cookies(BASE);
  await warm.close();

  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    ...(video ? { recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } } : {}),
  });
  await ctx.addCookies(cookies);
  const page = await ctx.newPage();
  await page.goto(startUrl, { waitUntil: "networkidle" });
  return { ctx, page };
}

// -- Stills: the queue and an expanded decision detail, both themes. --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();

  await page.goto(`${BASE}/admin/storage-requests`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-storage-requests-instance-']");
  await page.screenshot({
    path: `${outdir}/admin-storage-requests-queue-${mode}.png`,
    fullPage: true,
  });
  console.log(`queue-${mode}`);

  await page.locator("[data-testid^='admin-storage-requests-expand-']").first().click();
  await page.waitForSelector("[data-testid^='admin-storage-requests-detail-']");
  await page.waitForTimeout(300);
  await page.screenshot({
    path: `${outdir}/admin-storage-requests-detail-${mode}.png`,
    fullPage: true,
  });
  console.log(`detail-${mode}`);

  await ctx.close();
}

// -- The motion: a member request lands on the open queue, badge and row
// both move. The member API is the real write path (S2's route), so the
// PubSub notification is the one a production request emits. --
const { ctx: gifCtx, page: gifPage } = await cookieSession(
  `${BASE}/admin/storage-requests`,
  { video: true },
);

await setTheme(gifPage, "light");
await gifPage.waitForSelector("[data-testid^='admin-storage-requests-instance-']");
await gifPage.waitForTimeout(1200);

const response = await gifPage.request.post(
  `${BASE}/api/v1/instances/${liveInstanceId}/storage-requests`,
  {
    headers: {
      authorization: `Bearer ${pat}`,
      "content-type": "application/vnd.api+json",
    },
    data: {
      data: {
        type: "storage_request",
        attributes: { requested_gb: 300, reason: "Quarter-end archives" },
      },
    },
  },
);

if (!response.ok()) {
  console.error(`live insert failed: ${response.status()} ${await response.text()}`);
  await gifCtx.close();
  process.exit(1);
}

await gifPage.waitForFunction(
  () => document.body.innerText.includes("Quarter-end archives"),
  { timeout: 10_000 },
);
await gifPage.waitForTimeout(1500);

const video = gifPage.video();
await gifCtx.close();
const webm = await video.path();

execFileSync(
  "ffmpeg",
  [
    "-y",
    "-i",
    webm,
    "-vf",
    "fps=12,scale=720:-1:flags=lanczos",
    `${outdir}/admin-storage-requests-live-badge.gif`,
  ],
  { stdio: "ignore" },
);
console.log("live-badge gif");

await browser.close();
