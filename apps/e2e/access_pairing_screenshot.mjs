// The access-pairing screenshots (#273 §4.1/§4.2, the owner's
// screenshot convention): the Access tab's attached/attach sections and
// the instance page's tailnet reachability copy — before/after for the
// instance page (it changes an existing surface), both color modes.
// Authenticated pages; local dev target only.
//
// Usage:
//   FV_TOKEN=<jwt> \
//   FV_ACCESS_URL=… FV_INSTANCE_URL=… FV_CORNER_URL=… \
//   [FV_BEFORE_INSTANCE_URL=…] [FV_GIF=1] \
//   node access_pairing_screenshot.mjs <outdir>
//
// The URLs are the seeded surfaces (an :active gateway, private
// instances with AccessRoute rows, funded wallet — the #301 seed
// shape). FV_BEFORE_INSTANCE_URL points at the pre-change code serving
// the same DB (a detached main worktree) — the honest before.
import { chromium } from "@playwright/test";
import { mkdirSync, readFileSync } from "node:fs";

const BASE_AFTER = process.env.FV_AFTER_BASE ?? "http://127.0.0.1:4000";
const BASE_BEFORE = process.env.FV_BEFORE_BASE ?? "http://127.0.0.1:4001";
const tokenFile = process.env.FV_TOKEN_FILE ?? "/tmp/opencode/fv273_token.txt";
const token = process.env.FV_TOKEN ?? readFileSync(tokenFile, "utf8").trim();

const ACCESS_URL = process.env.FV_ACCESS_URL;
const INSTANCE_URL = process.env.FV_INSTANCE_URL;
const CORNER_URL = process.env.FV_CORNER_URL;
const BEFORE_INSTANCE_URL = process.env.FV_BEFORE_INSTANCE_URL;
const outdir = process.argv[2] ?? "/tmp/opencode/fv273-shots";

if (!ACCESS_URL || !INSTANCE_URL || !CORNER_URL) {
  console.error("FV_ACCESS_URL, FV_INSTANCE_URL and FV_CORNER_URL required (full URLs)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// Establish the session through the real endpoint (the POST the
// sign-in flow makes), then reuse the cookie jar for every page.
async function signIn(base) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: process.env.FV_GIF ? { dir: `${outdir}/video`, size: { width: 1440, height: 900 } } : undefined,
  });
  const page = await ctx.newPage();
  await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${base}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

async function shot(page, url, name, mode) {
  await page.goto(url, { waitUntil: "networkidle" });
  // Flip the theme the way the toggle does; the root script owns the attrs.
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`captured ${name}.png`);
}

// ---- After: the feature branch's surfaces ----

{
  const { ctx, page } = await signIn(BASE_AFTER);

  for (const mode of ["light", "dark"]) {
    await shot(page, ACCESS_URL, `access-pairing-${mode}`, mode);
  }

  // The instance page's reachability copy — after, both modes, plus
  // the public-but-attached corner (the reachability line shows
  // whatever the exposure).
  for (const mode of ["light", "dark"]) {
    await shot(page, INSTANCE_URL, `instance-tailnet-${mode}`, mode);
    await shot(page, CORNER_URL, `instance-corner-${mode}`, mode);
  }

  if (process.env.FV_GIF) {
    // The motion the PR adds: Attach → flash + the app joins the
    // attached list. Recorded, then trimmed to the element's action.
    await page.goto(ACCESS_URL, { waitUntil: "networkidle" });
    await page.waitForTimeout(800);
    await page.locator("[data-testid='access-attach-button']").first().click();
    await page.waitForTimeout(2500);
  }

  await ctx.close();
}

// ---- Before: the same surfaces on pre-change code, same data ----

if (BEFORE_INSTANCE_URL) {
  const { ctx, page } = await signIn(BASE_BEFORE);

  for (const mode of ["light", "dark"]) {
    await shot(page, BEFORE_INSTANCE_URL, `instance-tailnet-before-${mode}`, mode);
  }

  await ctx.close();
}

await browser.close();
console.log("done:", outdir);
