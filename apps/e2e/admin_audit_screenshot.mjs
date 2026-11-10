/* Audit console captures (#645, A2-S4): the section index with rows
 * (create, update, destroy, and the System tombstone on camera), the
 * resource-filtered view, the record-history deep link ARRIVED AT by
 * clicking the engine show page's History link, and the changes
 * details opened on one row. Light + dark from ONE seeded state
 * (admin_audit_seed.exs), stills only — no motion ships.
 *
 *   FV_TOKEN=… FV_FLAG_DETAIL=… node admin_audit_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv645-a2s4-shots";
mkdirSync(outdir, { recursive: true });

const ids = {
  token: process.env.FV_TOKEN ?? "",
  flagDetail: process.env.FV_FLAG_DETAIL ?? "",
};
const missing = Object.entries(ids)
  .filter(([k, v]) => !v)
  .map(([k]) => k);
if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_audit_seed.exs)`);
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

// The rise entrance animation runs about half a second — a shot taken
// inside it reads washed-out. Let the page land before capturing.
async function settle(page) {
  await page.waitForTimeout(800);
}

const browser = await chromium.launch();

// A signed-in context via the sanctioned session POST.
async function newSession(sessionToken) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: sessionToken },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(ids.token);

  // 1. The section index over the default resource (the picker's
  //    first entry): rows carry the stamp, the type badge, the action,
  //    the actor tombstone (System included), and the changes block.
  await page.goto(`${BASE}/admin/audit`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-audit-row-']");
  await page.waitForSelector("text=System", { timeout: 5000 }).catch(() => {});
  await settle(page);
  await page.screenshot({ path: `${outdir}/audit-index-${mode}.png`, fullPage: true });
  console.log(`audit-index-${mode}`);

  // 2. The changes details OPEN on one row (the JSON block in mono).
  const firstChanges = page.locator("[data-testid^='admin-audit-changes-']").first();
  await firstChanges.locator("summary").click();
  await page.waitForSelector("[data-testid^='admin-audit-changes-json-']");
  await settle(page);
  await page.screenshot({ path: `${outdir}/audit-changes-open-${mode}.png`, fullPage: true });
  console.log(`audit-changes-open-${mode}`);

  // 3. The resource-filtered view: the curated tag vocabulary's rows.
  await page.goto(`${BASE}/admin/audit?resource=tag`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-audit-row-']");
  await settle(page);
  await page.screenshot({ path: `${outdir}/audit-tag-filtered-${mode}.png`, fullPage: true });
  console.log(`audit-tag-filtered-${mode}`);

  // 4. The record-history deep link, ARRIVED AT the way an operator
  //    arrives: the engine show page's History link, clicked.
  await page.goto(`${BASE}/admin/resources/ops/feature_flag/${ids.flagDetail}`, {
    waitUntil: "networkidle",
  });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-resource-history']");
  await page.click("[data-testid='admin-resource-history']");
  await page.waitForSelector("[data-testid='admin-audit-filter-source']");
  await page.waitForSelector("[data-testid^='admin-audit-row-']");
  await settle(page);
  await page.screenshot({ path: `${outdir}/audit-record-history-${mode}.png`, fullPage: true });
  console.log(`audit-record-history-${mode}`);

  await ctx.close();
}

await browser.close();
console.log("done");
