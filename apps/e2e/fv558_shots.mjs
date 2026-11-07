/* #558's captures: storage decoupled from the size labels — the
 * deploy stepper's resources step (storage as its own control), the
 * /pricing calculator (storage section + dimension labels), a catalog
 * app page (compute + storage badges priced separately), the admin
 * size ladder (compute classes, no stopped column), and the landing
 * band (compute floor + per-GB storage copy). Both app theme modes.
 * Local dev target only.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node fv558_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4100";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv558-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required");
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

const shoot = async (name, fn) => {
  for (const mode of ["light", "dark"]) {
    await fn();
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: false });
    console.log(`captured ${name}-${mode}.png`);
  }
};

// 1. The deploy stepper's resources step: quick picks (compute-only
// allocation text + compute price) and the sliders with storage in
// its own bordered section.
await shoot("deploy-resources", async () => {
  await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
  await page.locator("[data-testid='version-option']").first().check();
  await page.locator("[data-testid='continue-version']").click();
  await page.locator("[data-testid='continue-env']").click();
  await page.waitForSelector("[data-testid='allocation-storage-group']");
  await page
    .locator("[data-testid='allocation-storage-group']")
    .scrollIntoViewIfNeeded();
});

// 2. The calculator: its storage section with the per-GB note, and
// the total pricing both axes.
await shoot("pricing-calculator", async () => {
  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await page.locator("[data-testid='pricing-calculator']").scrollIntoViewIfNeeded();
});

// 3. A catalog app page: version badges — price (compute + default
// storage), stopped (the axis alone), and the storage-default badge.
await shoot("catalog-app", async () => {
  await page.goto(`${BASE}/apps/forgejo`, { waitUntil: "networkidle" });
});

// 4. The admin size ladder: compute classes, no stopped column.
await shoot("admin-sizes", async () => {
  await page.goto(`${BASE}/admin/catalog/sizes`, { waitUntil: "networkidle" });
});

// 5. The landing band: "Compute starts at … plus per-GB storage".
await shoot("landing", async () => {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.locator("text=Compute starts at").first().scrollIntoViewIfNeeded();
});

await browser.close();
console.log("done");
