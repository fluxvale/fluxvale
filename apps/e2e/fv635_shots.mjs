// #635 capture: the settings split — /settings/access (the private
// access gateway panel alone now) and /settings/developer (the moved
// Device sign-ins and API tokens sections), desktop and phone widths,
// light and dark. Adapted from apps/e2e/screenshot.mjs's capture
// pattern (per-surface route list, never generic). Committed artifacts
// live under docs/screenshots/<PR>/.
//
// Usage: FV_TOKEN=<jwt> node fv635_shots.mjs <outdir>
// The token comes from the sibling fv635_seed.exs (a dev mix run
// one-off that also seeds the developer page's rows).
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/fv635-shots";
const TOKEN = process.env.FV_TOKEN ?? "";

if (!TOKEN) {
  console.error("FV_TOKEN required (see fv635_seed.exs)");
  process.exit(1);
}

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();

// The per-surface route list: the two split pages, nothing generic.
const shots = [
  ["settings-access", "/settings/access"],
  ["settings-developer", "/settings/developer"],
];

/**
 * Captures one page at one width in one color mode.
 * @param {string} name - the capture's base name
 * @param {string} path - the app path to capture
 * @param {number} width - viewport width (1440 desktop, 390 phone)
 * @param {"light"|"dark"} mode - the theme the toggle would pick
 */
async function capture(name, path, width, mode) {
  const context = await browser.newContext({
    viewport: { width, height: width === 390 ? 844 : 960 },
  });
  const page = await context.newPage();

  // Session through the real endpoint (the screenshot.mjs pattern):
  // the POST the sign-in flow makes, then the page ride. A bounce to
  // /sign-in fails the run (the fv595 posture) — a redirect can never
  // masquerade as evidence.
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const signIn = await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
  });
  if (signIn.url().includes("/sign-in")) {
    console.error(`sign-in failed for ${path} — check FV_TOKEN`);
    process.exit(1);
  }

  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  // The page itself, not a flash-and-leave: the account band's title
  // rides every settings surface.
  await page.locator("[data-testid='settings-title']").waitFor();
  // Flip the theme the way the toggle does; the root script owns the
  // attrs (the paid_gate pattern).
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);

  const file = `${name}-${width}-${mode}.png`;
  await page.screenshot({ path: `${OUT}/${file}`, fullPage: true });
  console.log(`captured ${file}`);
  await context.close();
}

for (const [name, path] of shots) {
  for (const width of [1440, 390]) {
    for (const mode of ["light", "dark"]) {
      await capture(name, path, width, mode);
    }
  }
}

await browser.close();
console.log("done:", OUT);
