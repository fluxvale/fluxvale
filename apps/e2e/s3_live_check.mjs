/* S3 live-update safety (the S2 hostile lesson): the backups panel is
 * re-rendered through its own refresh path (toggle-enabled -> refresh/2,
 * the same full-assigns re-render a run broadcast's send_update drives)
 * while the page holds an open restore confirm + a non-default dav tab.
 * The panels must keep that state, must not recreate rows, and must not
 * replay any load animation. Then the dav reveal patches the page (the
 * credential read fails on a cluster-less laptop — the flash + patch is
 * the point).
 */

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = "http://127.0.0.1:4184";
const INSTANCE_PATH = "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";
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

// State that must survive the patch: non-default tab + open confirm.
await page.locator("[data-testid='dav-tab-macos']").click();
await page.waitForTimeout(300);
await page.locator("[data-testid='restore-latest']").click();
await page.waitForTimeout(400);

const snapshot = () =>
  page.evaluate(() => {
    const runs = document.querySelector("[data-testid='backup-runs']");
    const activeTab = document.querySelector("[role='tab'][aria-selected='true']");
    return {
      runsOpacity: getComputedStyle(runs).opacity,
      runsAnimation: getComputedStyle(runs).animationName,
      runsHtml: runs.innerHTML,
      activeTab: activeTab ? activeTab.getAttribute("data-testid") : "NONE",
      flashText: (document.querySelector("#flash-group")?.textContent ?? "").trim().slice(0, 90),
    };
  });

const before = await snapshot();
const confirmBefore = await page.locator("[data-testid='destructive-confirm']").isVisible();
console.log(`before: confirm=${confirmBefore} runs=${before.runsHtml.split("data-testid").length - 1} tab=${before.activeTab} opacity=${before.runsOpacity} animation=${before.runsAnimation}`);
await page.screenshot({ path: `${outdir}/live-before-patch.png` });

// The panel's own refresh path (the form flow): toggle-enabled fires
// refresh/2 — the same re-render a run broadcast's send_update drives.
await page.locator("[data-testid='backups-enabled-toggle']").click();
await page.waitForTimeout(700);

const after = await snapshot();
const confirmAfter = await page.locator("[data-testid='destructive-confirm']").isVisible();
console.log(`after toggle patch: confirm=${confirmAfter} tab=${after.activeTab} opacity=${after.runsOpacity} animation=${after.runsAnimation}`);
console.log(`rows identical: ${before.runsHtml === after.runsHtml}`);
console.log(`flash now: "${after.flashText}"`);
await page.screenshot({ path: `${outdir}/live-after-patch.png` });

// put the setting back (the toggle is reversible)
await page.locator("[data-testid='backups-enabled-toggle']").click();
await page.waitForTimeout(500);

// The dav reveal path: cluster-less laptop -> flash error + patch.
await page.locator("[data-testid='reveal-credentials']").click();
await page.waitForTimeout(700);
const reveal = await snapshot();
const confirmReveal = await page.locator("[data-testid='destructive-confirm']").isVisible();
console.log(`after reveal patch: confirm=${confirmReveal} tab=${reveal.activeTab} opacity=${reveal.runsOpacity} animation=${reveal.runsAnimation}`);
console.log(`flash: "${reveal.flashText}"`);
await page.screenshot({ path: `${outdir}/live-after-reveal.png` });

await browser.close();
console.log("live-update check done");
