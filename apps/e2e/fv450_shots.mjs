/* The #450 copy-sweep screenshots: the two surfaces the PR closes on —
 * the org switcher's personal row (panel open on the dashboard) and the
 * welcome-credits banner. Light AND dark. Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4005 FV_TOKEN_MAIN=<jwt> \
 *   node fv450_shots.mjs <outdir>
 *
 * Mint FV_TOKEN_MAIN with fv450_session.exs (run from apps/platform:
 * `mix run ../e2e/fv450_session.exs`); the actor it provisions carries
 * the banner's preconditions (welcome credit, zero instances).
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN_MAIN = process.env.FV_TOKEN_MAIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv450-shots";

if (!TOKEN_MAIN) {
  console.error("FV_TOKEN_MAIN required (mint one with fv450_session.exs)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN_MAIN },
  headers: { "x-csrf-token": csrf },
});

const shots = [
  // The banner callout on a fresh account's dashboard (balance > 0,
  // zero instances) — the surface the em-dash retired from.
  { name: "banner", path: "/", wait: "text=Welcome credits ready", openSwitcher: false },
  // The switcher panel open: the personal row with its label.
  {
    name: "switcher",
    path: "/",
    wait: "[data-testid='org-switcher']",
    openSwitcher: true,
  },
];

for (const { name, path, wait, openSwitcher } of shots) {
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await page.locator(wait).first().waitFor();
    if (openSwitcher) {
      await page.locator("[data-testid='org-switcher'] summary").click();
      await page
        .locator("[data-testid='org-switcher-panel']")
        .waitFor();
      // let the open transition settle
      await page.waitForTimeout(400);
    }
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await browser.close();
