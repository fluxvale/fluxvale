/* Feedback interactive-layer captures (#412 T5): the vote island, the
 * comments island, and the composer, in light AND dark, at full
 * viewport resolution (stills are the verification evidence), plus one
 * short GIF of the motion (the vote toggle casting and retracting).
 *
 * Needs the capture data from /tmp/opencode/fv_t5_seed.exs (mix run in
 * apps/platform) — FV_T5_TOKEN, FV_T5_SLUG ride the env. The session is
 * established through the real endpoint (the screenshot.mjs pattern).
 *
 * Usage: FV_T5_TOKEN=<jwt> FV_T5_SLUG=<slug> node fv_t5_capture.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv-t5-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_T5_TOKEN ?? "";
const slug = process.env.FV_T5_SLUG ?? "";
if (!token || !slug) {
  console.error("FV_T5_TOKEN and FV_T5_SLUG required (run fv_t5_seed.exs)");
  process.exit(1);
}

const browser = await chromium.launch();

async function signedInContext(mode) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });

  // Theme rides localStorage (the feedback_screenshot.mjs pattern).
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

  return ctx;
}

async function still(name, path, mode, settle) {
  const ctx = await signedInContext(mode);
  const page = await ctx.newPage();
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  if (settle) {
    await settle(page);
  }
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
  console.log(`captured ${name}-${mode}.png`);
  await ctx.close();
}

// Stills: the post page carries the vote island AND the comments island
// (list + form); the composer still carries the typed title with the
// similar-posts nudge showing.
for (const mode of ["light", "dark"]) {
  await still("vote-comments-island", `/feedback/${slug}`, mode, async (page) => {
    // Expand the comment form's region: focus the textarea so the still
    // shows the form the actor gets.
    await page.locator("[data-testid='comment-body']").click();
  });
}

for (const mode of ["light", "dark"]) {
  await still("composer", "/feedback/new", mode, async (page) => {
    await page.locator("[data-testid='composer-title']").fill("add scheduled backups");
    await page.waitForSelector("[data-testid='similar-posts']");
    await page.waitForTimeout(300);
  });
}

// The motion: the vote toggle casting (count moves, button flips to the
// voted state) and retracting again. Its own context so recordVideo
// rides it; trimmed to the motion at conversion time.
{
  const videoCtx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: `${outdir}/raw`, size: { width: 1440, height: 900 } },
  });
  const vpage = await videoCtx.newPage();
  await vpage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await vpage.locator('meta[name="csrf-token"]').getAttribute("content");
  await vpage.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  await vpage.evaluate(() => {
    localStorage.setItem("phx:theme", "light");
    document.documentElement.setAttribute("data-theme", "light");
    document.documentElement.setAttribute("data-theme-source", "user");
  });
  await vpage.goto(`${BASE}/feedback/${slug}`, { waitUntil: "networkidle" });
  await vpage.waitForSelector("[data-testid='vote-toggle']");
  await vpage.waitForTimeout(800);

  await vpage.locator("[data-testid='vote-toggle']").click();
  await vpage.waitForTimeout(1600);
  await vpage.locator("[data-testid='vote-toggle']").click();
  await vpage.waitForTimeout(1600);

  await videoCtx.close();
  console.log("captured vote-toggle.webm (raw)");
}

await browser.close();
