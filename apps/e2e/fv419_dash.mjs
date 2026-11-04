/* The #419 dashboard capture: one token, the dashboard in light+dark. */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN = process.env.FV_TOKEN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv419-dash";
mkdirSync(outdir, { recursive: true });
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, { form: { token: TOKEN }, headers: { "x-csrf-token": csrf } });
for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/dashboard-${mode}.png`, fullPage: true });
  console.log(`captured dashboard-${mode}.png`);
}
console.log(`DASHBOARD_TITLE=${await page.title()}`);
await browser.close();
