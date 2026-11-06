// The Pocket ID catalog-wave screenshots (#492, the owner's screenshot
// convention): the new Identity category on the authed catalog, the
// public detail page, the deploy stepper's three steps (version price,
// the required Encryption key field, the micro recommendation), and the
// pricing calculator chooser (logo option, snapped recommendation) —
// light and dark.
//
// Authenticated pages ride a minted dev session (fv492_session.exs
// posture); local dev target only. FV_TOKEN=<jwt> required.
//
// No secret is ever captured: the Encryption key field is a password
// input, and the only value ever typed into it is a visible placeholder
// string that renders as dots.
//
// Usage:
//   FV_TOKEN=<jwt> node fv492_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv492-pocketid-shots";
mkdirSync(outdir, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
  process.exit(1);
}

// The deploy stepper's drive fills a placeholder: the field is REQUIRED
// (the create refuses without it), and a password input renders dots,
// so no value is ever visible in a capture. The step-2 capture is taken
// BEFORE the fill: the empty required field and its recipe text are the
// story.
const KEY_PLACEHOLDER = "fv492-capture-placeholder";

const browser = await chromium.launch();

// Session: POST /auth/session (the sign-in flow's own write), then the
// cookie jar carries every capture. Fail fast on a rejected token: a
// silent continue would capture sign-in pages and call them captures.
const signIn = async (ctx) => {
  const page = await ctx.newPage();
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
  return page;
};

const captureAll = async (page, theme) => {
  const settle = () => page.waitForTimeout(500);
  const shot = (name) => page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });

  // The authed catalog grid (the Identity category) + the public detail
  // page.
  await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
  await page.getByText("Identity", { exact: true }).first().scrollIntoViewIfNeeded();
  await settle();
  await shot(`fv492-${theme}-1-catalog`);
  await page.goto(`${BASE}/catalog/pocket-id`, { waitUntil: "networkidle" });
  await settle();
  await shot(`fv492-${theme}-2-public-detail`);

  // The deploy stepper, step by step (LiveView patches; the testids are
  // the steps' own).
  await page.goto(`${BASE}/apps/pocket-id/deploy`, { waitUntil: "networkidle" });
  await settle();
  await page.getByTestId("version-option").first().check();
  await shot(`fv492-${theme}-3-version`);
  await page.getByTestId("continue-version").click();
  await page.locator("#env-form").waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-4-config`);
  await page.locator("#env-ENCRYPTION_KEY").fill(KEY_PLACEHOLDER);
  await page.getByTestId("continue-env").click();
  await page.getByTestId("recommended-allocation").waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-5-resources`);

  // The pricing calculator: chooser open with the query typed, then the
  // snapped recommendation after the pick.
  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await settle();
  await page.locator("#calculator-app-filter").click();
  await page.locator("#calculator-app-filter").fill("pocket");
  await page
    .locator("[data-testid='calculator-app-option-pocket-id']")
    .waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-6-chooser`);
  await page.locator("[data-testid='calculator-app-option-pocket-id']").click();
  await page
    .locator("[data-testid='calculator-app-recommendation']")
    .waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-7-snapped`);
};

// One context per theme: the theme rides the app's own control (the
// root layout applies it from localStorage before paint), and
// localStorage is origin-scoped per context, so setting it once holds
// for every navigation in that context.
for (const theme of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
  const page = await signIn(ctx);
  await page.evaluate((t) => {
    localStorage.setItem("phx:theme", t);
    document.documentElement.setAttribute("data-theme", t);
  }, theme);
  await captureAll(page, theme);
  console.log(`done: ${theme}`);
  await ctx.close();
}

await browser.close();
console.log(`captured to ${outdir}`);
