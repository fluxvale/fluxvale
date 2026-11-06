/* #507 screenshots: the backups panel of the instance page, both
 * states (unconfigured / configured), both color modes. Local dev
 * target only (FV_BASE), session minted via FV_TOKEN through the real
 * sign-in POST — no test backdoors (the #178 harness pattern).
 *
 * Usage: FV_TOKEN=<jwt> FV_UNCONFIGURED=<id> FV_CONFIGURED=<id> \
 *          FV_BASE=http://127.0.0.1:4010 node fv507_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4010";
const outdir = process.argv[2] ?? "/tmp/opencode/fv507-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const unconfigured = process.env.FV_UNCONFIGURED ?? "";
const configured = process.env.FV_CONFIGURED ?? "";

if (!token || !unconfigured || !configured) {
  console.error("FV_TOKEN, FV_UNCONFIGURED, FV_CONFIGURED required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session through the real endpoint (the POST the sign-in flow makes).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

const shots = [
  ["backups-unconfigured", unconfigured],
  ["backups-configured", configured],
];

for (const mode of ["light", "dark"]) {
  for (const [name, id] of shots) {
    await page.goto(`${BASE}/instances/${id}`, { waitUntil: "networkidle" });
    // Flip the theme the way the toggle does; the root script owns the attrs.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    // The backups panel is the surface under review — capture it whole.
    const panel = page.locator("[data-testid='backups-panel']");
    await panel.screenshot({ path: `${outdir}/${name}-${mode}.png` });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await browser.close();
