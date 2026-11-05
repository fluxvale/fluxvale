/* Element-level crops of every primary button on the composer + board,
 * both themes — the before/after comparison for the #471 diagnosis. */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const label = process.env.FV_LABEL ?? "crop";
const token = process.env.FV_T5_TOKEN ?? "";
const outdir = process.argv[2] ?? `/tmp/opencode/fv471-${label}-crops`;
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function shot(mode, pagePath, selector, name, signedIn = false) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), mode);
  const page = await ctx.newPage();

  if (signedIn) {
    if (!token) {
      console.error(`skipping ${name}: signed-in capture needs FV_T5_TOKEN`);
      await ctx.close();
      return;
    }
    await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
    await page.request.post(`${BASE}/auth/session`, {
      form: { token },
      headers: { "x-csrf-token": csrf },
    });
  }

  await page.goto(`${BASE}${pagePath}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
  await page.locator(selector).first().screenshot({ path: `${outdir}/${name}.png` });
  console.log(`captured ${name}`);
  await ctx.close();
}

for (const mode of ["light", "dark"]) {
  // The board's composer CTA and the composer's submit button.
  await shot(mode, "/feedback", "[data-testid='composer-cta']", `board-cta-${mode}`);
  await shot(mode, "/feedback/new", "#composer-form button[type='submit']", `composer-submit-${mode}`, true);
}

await browser.close();
