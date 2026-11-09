/* The #612 S4 takeover screenshots (the owner's screenshot
 * convention): the four surfaces this PR changes for a buyer — the
 * Umami catalog detail (two version rows: bundled $4.09, BYO $2.59),
 * the deploy stepper's configuration step (the bundled note; no
 * DATABASE_URL input; APP_SECRET the one fill), the resources step
 * (the honest-share disclosure, floored sliders), and the backups
 * panel's running-snapshot caveat on a bundled instance. Light and
 * dark each. Stills only — the change is layout and copy, not motion.
 *
 * Local dev target only. Seed the capture rows + mint the session
 * first (apps/platform): mix run ../e2e/fv609t_seed.exs
 *
 * Usage:
 *   FV_TOKEN=<jwt> FV_INSTANCE_ID=<id> node fv609t_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN;
const instanceId = process.env.FV_INSTANCE_ID;
const outdir = process.argv[2] ?? "/tmp/opencode/fv609t-shots";
mkdirSync(outdir, { recursive: true });

if (!token || !instanceId) {
  console.error("FV_TOKEN and FV_INSTANCE_ID required (see fv609t_seed.exs)");
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
  // The catalog detail: the two-row version list is the takeover made
  // visible — bundled $4.09/mo default, BYO $2.59/mo pinned below.
  await page.goto(`${BASE}/apps/umami`, { waitUntil: "networkidle" });
  await page.locator("text=3.4.1-bundled").first().waitFor();
  await capture("catalog-detail", mode);

  // Step 2 — Configuration: the bundled note above the form, no
  // DATABASE_URL input, APP_SECRET the one visible secret (filled for
  // the step's own validation before continuing on).
  await page.goto(`${BASE}/apps/umami/deploy`, { waitUntil: "networkidle" });
  await page.locator("[data-testid=version-option]").first().click();
  await page.locator("button[phx-click='to-env']").click();
  await page.locator("#bundled-env-note").waitFor();
  await page.locator("#env-APP_SECRET").waitFor();
  await capture("wizard-config", mode);
  await page.locator("#env-APP_SECRET").fill("capture-placeholder-0123456789abcdef");

  // Step 3 — Resources: the disclosure callout, the floored sliders
  // (storage starts at 10 GB — no 0 or 5 rung), the $4.09 estimate.
  await page.locator("[data-testid=continue-env]").click();
  await page.locator("[data-testid=bundled-services-note]").waitFor();
  await page.locator("#resource-storage-gb-ticks [data-value='10']").waitFor();
  await capture("wizard-resources", mode);

  // The backups panel on a bundled instance: the running-snapshot
  // caveat under the schedule line (staged setting; the panel's
  // configured view).
  await page.goto(`${BASE}/instances/${instanceId}`, { waitUntil: "networkidle" });
  await page.locator("[data-testid=backup-db-caveat]").waitFor();
  await capture("backups-caveat", mode);
}

await browser.close();
console.log("done");
