/* S3 live-update safety (the S2 hostile lesson): the backups panel is
 * re-rendered through its own refresh path (toggle-enabled -> refresh/2,
 * the same full-assigns re-render a run broadcast's send_update drives)
 * while the page holds an open restore confirm + a non-default dav tab.
 * Hardened per the #328 re-review:
 * - FV_BASE / FV_INSTANCE accepted
 * - refuses a /sign-in redirect (session failure)
 * - waits for the toggle's RESULT (the notice callout), not a fixed sleep
 * - row identity checked by DOM NODE (expando on the element), not
 *   innerHTML — a byte-equal innerHTML can hide replaced nodes
 */

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4184";
const INSTANCE_PATH =
  process.env.FV_INSTANCE ?? "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";
const outdir = process.argv[2] ?? "/tmp/opencode/s3-live";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: process.env.FV_TOKEN ?? "" },
  headers: { "x-csrf-token": csrf },
});

await page.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
await page.waitForTimeout(500);

if (page.url().includes("/sign-in")) {
  console.error(`session failed — landed on ${page.url()}`);
  process.exit(1);
}
await page
  .locator("[data-testid='backups-panel']")
  .waitFor({ state: "visible", timeout: 10_000 });

// State that must survive the patch: non-default tab + open confirm.
await page.locator("[data-testid='dav-tab-macos']").click();
await page.waitForTimeout(300);
await page.locator("[data-testid='restore-latest']").click();
await page.locator("[data-testid='destructive-confirm']").waitFor({ state: "visible" });

// Tag every run row's DOM node (expando). A patch that REPLACES a row
// produces a fresh node with no tag — innerHTML equality can't see that.
await page.evaluate(() => {
  window.__rowTags = new WeakMap();
  document
    .querySelectorAll("[data-testid='backup-run']")
    .forEach((row, i) => window.__rowTags.set(row, i));
});

const before = await page.evaluate(() => {
  const runs = document.querySelector("[data-testid='backup-runs']");
  const activeTab = document.querySelector("[role='tab'][aria-selected='true']");
  return {
    runsOpacity: getComputedStyle(runs).opacity,
    runsAnimation: getComputedStyle(runs).animationName,
    rowCount: document.querySelectorAll("[data-testid='backup-run']").length,
    activeTab: activeTab ? activeTab.getAttribute("data-testid") : "NONE",
  };
});
console.log(`before: confirm=true rows=${before.rowCount} tab=${before.activeTab} opacity=${before.runsOpacity} animation=${before.runsAnimation}`);
await page.screenshot({ path: `${outdir}/live-before-patch.png` });

// The panel's own refresh path (the form flow): toggle-enabled fires
// refresh/2 — the same re-render a run broadcast's send_update drives.
await page.locator("[data-testid='backups-enabled-toggle']").click();
// Wait for the toggle's RESULT — the notice callout the handler assigns —
// not a fixed sleep.
await page
  .locator("[data-testid='backups-notice']")
  .waitFor({ state: "visible", timeout: 10_000 });

const after = await page.evaluate(() => {
  const runs = document.querySelector("[data-testid='backup-runs']");
  const activeTab = document.querySelector("[role='tab'][aria-selected='true']");
  const rows = [...document.querySelectorAll("[data-testid='backup-run']")];
  return {
    runsOpacity: getComputedStyle(runs).opacity,
    runsAnimation: getComputedStyle(runs).animationName,
    activeTab: activeTab ? activeTab.getAttribute("data-testid") : "NONE",
    rows,
    survived: rows.filter((r) => window.__rowTags.has(r)).length,
    confirmVisible: !!document.querySelector("[data-testid='destructive-confirm']"),
  };
});
console.log(`after toggle patch: confirm=${after.confirmVisible} tab=${after.activeTab} opacity=${after.runsOpacity} animation=${after.runsAnimation}`);
console.log(`row NODE identity: ${after.survived}/${after.rows.length} rows are the same DOM nodes (expando-held)`);
await page.screenshot({ path: `${outdir}/live-after-patch.png` });

// put the setting back (the toggle is reversible) — wait for the
// button's own label to flip back, the render-side result of the resume
await page.locator("[data-testid='backups-enabled-toggle']").click();
await page
  .locator("[data-testid='backups-enabled-toggle']", { hasText: "Pause backups" })
  .waitFor({ timeout: 10_000 });

// The dav reveal path: cluster-less laptop -> flash error + patch.
await page.locator("[data-testid='reveal-credentials']").click();
await page.waitForTimeout(700);
const reveal = await page.evaluate(() => {
  const activeTab = document.querySelector("[role='tab'][aria-selected='true']");
  const flash = document.querySelector("#flash-group");
  return {
    activeTab: activeTab ? activeTab.getAttribute("data-testid") : "NONE",
    flashText: (flash?.textContent ?? "").trim().slice(0, 60),
    confirmVisible: !!document.querySelector("[data-testid='destructive-confirm']"),
  };
});
console.log(`after reveal patch: confirm=${reveal.confirmVisible} tab=${reveal.activeTab}`);
console.log(`flash: "${reveal.flashText}..."`);
await page.screenshot({ path: `${outdir}/live-after-reveal.png` });

await browser.close();
console.log("live-update check done");
