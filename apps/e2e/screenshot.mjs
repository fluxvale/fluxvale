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

const BASE = "http://127.0.0.1:4000";
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
  ["landing", "/", false],
  ["catalog-public", "/catalog", false],
  ["catalog-public-show", "/catalog/forgejo", false],
  ["catalog", "/apps", true],
  ["catalog-show", "/apps/forgejo", true],
  ["instances", "/instances", true],
  ["billing", "/billing", true],
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

// Storybook overview (sidebar) at default theme
await page.goto(`${BASE}/storybook`, { waitUntil: "networkidle" });
await page.screenshot({ path: `${outdir}/storybook-overview.png`, fullPage: true });
console.log("captured storybook-overview.png");

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
