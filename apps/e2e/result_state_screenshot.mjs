/* Top-up result states (#377): the three confirmation cards after a
 * Polar checkout return — success (amount + resulting balance),
 * confirming (webhook still in flight), not-found (unknown
 * checkout_id). Local dev target only, driven by a minted session
 * cookie passed via FV_TOKEN (result_state_seed.exs); light + dark.
 * Still surface — no motion to capture.
 *
 * Usage: node result_state_screenshot.mjs <outdir>   (FV_TOKEN=<jwt>)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv377-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const shots = [
  ["result-success", `/billing/topup/return?checkout_id=${process.env.FV_CHECKOUT_DONE}`],
  ["result-confirming", `/billing/topup/return?checkout_id=${process.env.FV_CHECKOUT_PENDING}`],
  ["result-not-found", "/billing/topup/return?checkout_id=co_cap_none"],
];

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session through the real endpoint, then reuse the cookie jar.
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page
  .locator('meta[name="csrf-token"]')
  .getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

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

await browser.close();
