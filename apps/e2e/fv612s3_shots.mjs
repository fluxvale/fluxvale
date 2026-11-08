/* The #612 S3 wizard screenshots (the owner's screenshot convention):
 * the deploy stepper's two changed surfaces for a DB-backed version —
 * configuration (the bundled-env note, the platform-owned url_env
 * inputs absent, APP_TOKEN still an input) and resources (the
 * honest-share disclosure, floored sliders with no 0-GB rung, the
 * under-floor quick picks gone). Light and dark each. Stills only —
 * the change is layout, not motion.
 *
 * Local dev target only. Seed the capture rows + mint the session
 * first (apps/platform): mix run ../e2e/fv612s3_seed.exs
 *
 * Usage:
 *   FV_TOKEN=<jwt> node fv612s3_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN;
const APP_SLUG = process.env.FV_APP_SLUG ?? "docmost-shot";
const outdir = process.argv[2] ?? "/tmp/opencode/fv612s3-shots";
mkdirSync(outdir, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required (see fv612s3_seed.exs)");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session: POST /auth/session (the sign-in flow's own write). Fail
// fast on a rejected token (the fv492 stance).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const response = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
const bounced = new URL(response.url()).pathname === "/sign-in";
if (!response.ok() || bounced) {
  throw new Error(`Sign-in failed (status ${response.status()}); check FV_TOKEN`);
}

const setTheme = (mode) =>
  page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

const capture = async (name, theme) => {
  await setTheme(theme);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}-${theme}.png`, fullPage: true });
  console.log(`captured ${name}-${theme}.png`);
};

for (const mode of ["light", "dark"]) {
  // Step 2 — Configuration: the bundled-env note above the form, the
  // url_env inputs never rendered, APP_TOKEN the one visible input.
  await page.goto(`${BASE}/apps/${APP_SLUG}/deploy`, { waitUntil: "networkidle" });
  await page.locator("[data-testid=version-option]").first().click();
  await page.locator("button[phx-click='to-env']").click();
  await page.locator("#bundled-env-note").waitFor();
  await page.locator("#env-APP_TOKEN").waitFor();
  await capture("wizard-env-note", mode);

  // Step 3 — Resources: the disclosure callout, the floored sliders
  // (storage starts at 10 GB — no 0 or 5 rung), the under-floor
  // quick picks gone.
  await page.locator("[data-testid=continue-env]").click();
  await page.locator("[data-testid=bundled-services-note]").waitFor();
  await page.locator("#resource-storage-gb-ticks [data-value='10']").waitFor();
  await capture("wizard-resources", mode);
}

await browser.close();
console.log("done");
