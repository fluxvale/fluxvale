/* S3 captures: instance show backups + WebDAV panels, before/after.
 * Pattern per apps/e2e/screenshot.mjs (#178): session via the real
 * POST /auth/session with a minted JWT (FV_TOKEN), FV_BASE picks the
 * dev server (after = 4184, before = 4185 — same dev DB, old UI).
 *
 * Usage: node s3_panels_screenshot.mjs <outdir> <phase>
 *   phase "unconfigured": page load states + the open setup form
 *   phase "configured":   setting + history present (run
 *                         stage_s3_backups.exs first), tabs, confirm
 */

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4184";
const INSTANCE_PATH = process.env.FV_INSTANCE ?? "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";
const outdir = process.argv[2] ?? "/tmp/opencode/s3-shots";
const phase = process.argv[3] ?? "configured";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// 1. session: POST /auth/session (needs csrf from a fetched page)
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

async function setMode(mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

async function openInstance() {
  await page.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
}

async function fullShot(name) {
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`captured ${name}.png`);
}

async function panelsShot(name) {
  // Both panels region: from the availability card's top through the
  // page bottom — the flow section the panels live in.
  const first = page.locator("[data-testid='availability-card']");
  const box = await first.boundingBox();
  await page.screenshot({
    path: `${outdir}/${name}.png`,
    clip: { x: 0, y: box.y - 12, width: 1440, height: 20000 },
    fullPage: true,
  });
  console.log(`captured ${name}.png`);
}

await openInstance();

if (phase === "unconfigured") {
  for (const mode of ["light", "dark"]) {
    await setMode(mode);
    await fullShot(`s3-unconfigured-1440-${mode}`);
  }

  // The no-bucket setup state: the panel's own open-settings action.
  await page.locator("[data-testid='backups-setup']").click();
  await page.waitForTimeout(500);
  for (const mode of ["light", "dark"]) {
    await setMode(mode);
    await panelsShot(`s3-setup-form-1440-${mode}`);
  }
}

if (phase === "configured") {
  for (const mode of ["light", "dark"]) {
    await setMode(mode);
    await fullShot(`s3-configured-1440-${mode}`);
  }

  // Dav quick-start on every platform tab (server-held active tab).
  for (const key of ["windows", "macos", "linux"]) {
    await page.locator(`[data-testid='dav-tab-${key}']`).click();
    await page.waitForTimeout(400);
    await panelsShot(`s3-dav-tab-${key}-1440-light`);
  }
  // leave macos active for the 375 shots (a non-default tab survives
  // the narrow viewport)
  await page.locator("[data-testid='dav-tab-macos']").click();
  await page.waitForTimeout(300);

  // Mobile: 375 wide, both panels visible (full page).
  await page.setViewportSize({ width: 375, height: 800 });
  await page.waitForTimeout(400);
  for (const mode of ["light", "dark"]) {
    await setMode(mode);
    await fullShot(`s3-configured-375-${mode}`);
  }

  // Desktop again for the pending confirm.
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.waitForTimeout(400);
  await page.locator("[data-testid='restore-latest']").click();
  await page.waitForTimeout(500);
  for (const mode of ["light", "dark"]) {
    await setMode(mode);
    await panelsShot(`s3-restore-confirm-1440-${mode}`);
  }
}

await browser.close();
console.log("done");
