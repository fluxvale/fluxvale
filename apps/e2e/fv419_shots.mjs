/* The #419 punctuation-sweep screenshots: the surfaces the copy sweep
 * changed — settings (username/email cards), the backups panel's
 * unpaid callout, the DAV quick-start panel, and the dashboard. Light
 * AND dark for all. Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4001 FV_TOKEN_MAIN=<jwt> \
 *   FV_TOKEN_DAV=<jwt> node fv419_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN_MAIN = process.env.FV_TOKEN_MAIN;
const TOKEN_DAV = process.env.FV_TOKEN_DAV;
const outdir = process.argv[2] ?? "/tmp/opencode/fv419-shots";

if (!TOKEN_MAIN || !TOKEN_DAV) {
  console.error("FV_TOKEN_MAIN and FV_TOKEN_DAV required (see the seed script)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function signInContext(token) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

const main = await signInContext(TOKEN_MAIN);
const dav = await signInContext(TOKEN_DAV);

// Resolve each actor's instance URL off the listing.
async function instanceHref(page) {
  await page.goto(`${BASE}/instances`, { waitUntil: "networkidle" });
  return page.evaluate(() => {
    const row = document.querySelector("a[href^='/instances/']");
    return row ? row.getAttribute("href") : null;
  });
}

const mainInstance = await instanceHref(main.page);
const davInstance = await instanceHref(dav.page);

// A missing instance link means the seeded actor has no matching row —
// .filter(Boolean) below would silently drop the backups or DAV pair
// from the captures. Fail loudly before any capture starts.
if (!mainInstance || !davInstance) {
  console.error(
    `Instance listing missing a required row: main=${mainInstance ?? "none"} dav=${davInstance ?? "none"} — seed both actors' instances (see the #419 seed script) before capturing.`,
  );
  process.exit(1);
}

const shots = [
  { page: main.page, name: "settings", path: "/settings", wait: "[data-testid='settings-title']" },
  { page: main.page, name: "dashboard", path: "/", wait: null },
  { page: main.page, name: "backups", path: mainInstance, wait: "[data-testid='backups-panel']" },
  { page: dav.page, name: "dav", path: davInstance, wait: "[data-testid='file-access-panel']" },
];

// The dashboard <title> is itself a swept string, so it must be read
// while main.page still shows the dashboard — later navigations
// (backups, DAV) replace it.
let dashboardTitle = null;

for (const { page, name, path, wait } of shots) {
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    if (wait) await page.locator(wait).waitFor();
    if (name === "dashboard") dashboardTitle = await page.title();
    // The theme flip rides the root script's own attrs; a reload-free
    // set + settle, same as the #178 captures.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

// The title captured during the dashboard shot (the capture above).
console.log(`DASHBOARD_TITLE=${dashboardTitle}`);

await browser.close();
