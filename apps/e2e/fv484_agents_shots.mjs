// #484 W5 capture: the agent quickstart — the new /settings/agents
// page and the developer settings page that links it one click from
// the mint (#638 moved the API tokens section to /settings/developer).
// Light + dark, authenticated session through the real sign-in POST
// (FV_TOKEN from fv484_agents_session.exs, minted the *_seed.exs
// way). Per-surface route list, never generic. Committed artifacts
// live under docs/screenshots/<PR>/.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/fv484-shots";

mkdirSync(OUT, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
  process.exit(1);
}

const shots = [
  ["agents-quickstart", "/settings/agents"],
  ["tokens-panel", "/settings/developer"],
];

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });

// Session through the real endpoint (the POST the sign-in flow
// makes), then reuse the cookie jar for every page. The POST is
// asserted 2xx before any capture: a rejected login would otherwise
// silently shoot unauthenticated pages (CodeRabbit GNsF).
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page
  .locator('meta[name="csrf-token"]')
  .getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) {
  console.error(`session POST rejected: ${session.status()} — not capturing`);
  process.exit(1);
}

for (const mode of ["light", "dark"]) {
  for (const [name, path] of shots) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    // Flip the theme the way the toggle does; the root script owns
    // the attrs.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    // Animations disabled: deterministic captures past theme
    // transitions (CodeRabbit GNsE).
    await page.screenshot({
      path: `${OUT}/${name}-${mode}.png`,
      fullPage: true,
      animations: "disabled",
    });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await browser.close();
