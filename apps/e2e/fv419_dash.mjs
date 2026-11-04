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

// Reject failed sign-ins before capturing: an expired FV_TOKEN gets the
// session POST's failure redirect, and "/" would then silently save the
// anonymous landing as the dashboard shots. Require a dashboard-only
// element before any capture.
await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
try {
  await page.locator("[data-testid='dashboard-balance']").waitFor({ timeout: 10_000 });
} catch {
  console.error(
    "Sign-in failed: no dashboard rendered after the session POST — is FV_TOKEN expired or wrong? (the failure arm redirects to /sign-in, and '/' serves the anonymous landing)"
  );
  process.exit(1);
}
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
