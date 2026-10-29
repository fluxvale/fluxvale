/* Design-system screenshots (#178): capture the storybook and the
 * migrated surfaces in both color modes. Local dev target only
 * (127.0.0.1:4000), driven by a minted session cookie passed via
 * FV_TOKEN (produced by /tmp/opencode/fv178_session.exs through the
 * same JWT the sign-in flow mints — no test backdoors in the app).
 *
 * Usage: node screenshot.mjs <outdir>   (FV_TOKEN=<jwt> required for
 * the authenticated pages; unauthenticated pages always captured)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { writeFileSync } from "node:fs";

// Base URL overridable for high-port dev runs (FV_BASE=…); 4000 stays
// the plain `mix phx.server` default (T7 harness refresh).
const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv178-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
  process.exit(1);
}

// Establish the session through the real endpoint (the POST the
// sign-in flow makes), then reuse the cookie jar for every page.
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });

// 1. session: POST /auth/session (needs csrf from a fetched page)
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page
  .locator('meta[name="csrf-token"]')
  .getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

const shots = [
  // "/" is the dashboard for a resolved session (#205) — the landing
  // page itself lives at /about (canonical to /). T7 refresh: the Grove
  // surfaces since this list was written (#277): dashboard, instances
  // show, billing top-up, sign-in.
  ["dashboard", "/", true],
  ["landing", "/about", false],
  ["catalog-public", "/catalog", false],
  ["catalog-public-show", "/catalog/forgejo", false],
  ["catalog", "/apps", true],
  ["catalog-show", "/apps/forgejo", true],
  ["instances", "/instances", true],
  ["billing", "/billing", true],
  ["billing-topup", "/billing/topup", true],
  ["storybook-foundations", "/storybook/foundations", true],
  ["storybook-button", "/storybook/components/button", true],
  ["storybook-input", "/storybook/components/input", true],
  ["storybook-status-badge", "/storybook/components/status_badge", true],
  ["storybook-table", "/storybook/components/table", true],
];

for (const mode of ["light", "dark"]) {
  for (const [name, path] of shots) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    // Flip the theme the way the toggle does; the root script owns the attrs.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

// Sign-in rides an anonymous context — the authenticated chrome (user
// menu) is not the surface a visitor sees (T7 refresh).
const anonCtx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const anonPage = await anonCtx.newPage();
for (const mode of ["light", "dark"]) {
  await anonPage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  await anonPage.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await anonPage.waitForTimeout(300);
  await anonPage.screenshot({ path: `${outdir}/sign-in-${mode}.png`, fullPage: true });
  console.log(`captured sign-in-${mode}.png`);
}
await anonCtx.close();

// Instance show: the first row's href, when the actor has rows
// (staged data is per-environment; skip cleanly without it).
await page.goto(`${BASE}/instances`, { waitUntil: "networkidle" });
const rowHref = await page.evaluate(() => {
  const row = document.querySelector("[data-testid='instance-row']");
  return row ? row.getAttribute("href") : null;
});

if (rowHref) {
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${rowHref}`, { waitUntil: "networkidle" });
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/instances-show-${mode}.png`, fullPage: true });
    console.log(`captured instances-show-${mode}.png`);
  }
} else {
  console.log("skipped instances-show (no instance rows for this actor)");
}

// Storybook overview (sidebar) at default theme
await page.goto(`${BASE}/storybook`, { waitUntil: "networkidle" });
await page.screenshot({ path: `${outdir}/storybook-overview.png`, fullPage: true });
console.log("captured storybook-overview.png");

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
