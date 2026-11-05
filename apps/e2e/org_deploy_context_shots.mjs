/* The deploy wizard's org-context picker (#408) screenshots: the band
 * with the picker defaulting to Personal, and the band after picking
 * the team org. Light AND dark for both. Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4100 FV_TOKEN=<jwt> FV_APP_SLUG=<slug> \
 *   node org_deploy_context_shots.mjs <outdir>
 * Token + slug: mint with the sibling `org_deploy_context_seed.exs` (a
 * dev `mix run` one-off), then export them here.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4100";
const TOKEN = process.env.FV_TOKEN;
const APP_SLUG = process.env.FV_APP_SLUG;
const TEAM_NAME = process.env.FV_TEAM_NAME ?? "Acme Team";
const outdir = process.argv[2] ?? "/tmp/opencode/orgctx-shots";

if (!TOKEN || !APP_SLUG) {
  console.error("FV_TOKEN and FV_APP_SLUG required (see the seed script)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

await page.goto(`${BASE}/apps/${APP_SLUG}/deploy`, { waitUntil: "networkidle" });
await page.locator("[data-testid=deploy-org-picker]").waitFor();

for (const mode of ["light", "dark"]) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/deploy-org-picker-${mode}.png` });
  console.log(`captured deploy-org-picker-${mode}.png`);
}

// The picked state: the team org chosen — the option flips selected.
await page.selectOption("[data-testid=deploy-org-picker]", { label: TEAM_NAME });
await page.waitForTimeout(300);

for (const mode of ["light", "dark"]) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/deploy-org-picked-${mode}.png` });
  console.log(`captured deploy-org-picked-${mode}.png`);
}

await ctx.close();
await browser.close();
console.log("done:", outdir);
