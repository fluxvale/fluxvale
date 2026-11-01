/* S7 captures: the authed catalog browse (/apps) + app detail
 * (/apps/forgejo), 1440x900 + 375x667, light + dark, fullPage.
 * S7_LABEL ("before"/"after") names the files; theme is re-selected
 * before EVERY shot and the rise is settled first so no shot catches
 * content mid-reveal.
 *
 * Usage: node s7_capture.mjs <outdir>   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4190";
const label = process.env.S7_LABEL ?? "after";
const outdir = process.argv[2] ?? `/tmp/opencode/s7-shots-${label}`;
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const settle = (page) =>
  page.evaluate(() =>
    Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
  );

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);
// A silently-dead session renders /sign-in under catalog filenames —
// verify the app actually knows us before the first shot.
await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
if (page.url().includes("/sign-in")) throw new Error("session did not take — check FV_TOKEN");

const shots = [
  ["catalog", "/apps", 1440, 900],
  ["catalog", "/apps", 375, 667],
  ["catalog-show", "/apps/forgejo", 1440, 900],
  ["catalog-show", "/apps/forgejo", 375, 667],
  // The zero-versions state (hostile-341 F7): no band CTA, an empty
  // state under the Versions heading — only exists on staged catalogs.
  ["catalog-show-empty", "/apps/unreleased-thing", 1440, 900],
];

for (const [name, path, width, height] of shots) {
  await page.setViewportSize({ width, height });
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  for (const mode of ["light", "dark"]) {
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(250);
    await settle(page);
    const file = `${outdir}/${label}-${name}-${width}-${mode}.png`;
    await page.screenshot({ path: file, fullPage: true });
    console.log(`captured ${file}`);
  }
}

await ctx.close();
await browser.close();
