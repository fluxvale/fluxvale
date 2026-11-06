// The Memos catalog-wave screenshots (#492, the owner's screenshot
// convention): the new Productivity category on the authed catalog, the
// public detail page, the deploy stepper's three steps (version price,
// the empty-schema Configuration step, the micro recommendation), and
// the pricing calculator chooser (logo option, snapped recommendation) —
// light and dark. Local dev target only; fv492_session.exs mints the
// session (mix run ../e2e/fv492_session.exs from apps/platform).
//
// Nothing secret is ever captured: Memos has no configuration inputs at
// all, so the stepper carries no field to mask.
//
// Usage:
//   FV_TOKEN=<jwt> node fv492_memos_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv492-memos-shots";
mkdirSync(outdir, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
  process.exit(1);
}

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

  // The authed catalog grid (the Productivity category) + the public
  // detail page.
  await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
  await page.getByText("Productivity", { exact: true }).first().scrollIntoViewIfNeeded();
  await settle();
  await shot(`fv492-${theme}-1-catalog`);
  await page.goto(`${BASE}/catalog/memos`, { waitUntil: "networkidle" });
  await settle();
  await shot(`fv492-${theme}-2-public-detail`);

  // The deploy stepper, step by step (LiveView patches; the testids are
  // the steps' own). Step 2 is the empty-schema Configuration step —
  // "Nothing to configure for this app." is the honest story for a
  // zero-input app.
  await page.goto(`${BASE}/apps/memos/deploy`, { waitUntil: "networkidle" });
  await settle();
  await page.getByTestId("version-option").first().check();
  await shot(`fv492-${theme}-3-version`);
  await page.getByTestId("continue-version").click();
  await page.getByText("Nothing to configure for this app.").waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-4-config`);
  await page.getByTestId("continue-env").click();
  await page.getByTestId("recommended-allocation").waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-5-resources`);

  // The pricing calculator: chooser open with the query typed, then the
  // snapped recommendation after the pick.
  await page.goto(`${BASE}/pricing`, { waitUntil: "networkidle" });
  await settle();
  await page.locator("#calculator-app-filter").click();
  await page.locator("#calculator-app-filter").fill("memos");
  await page
    .locator("[data-testid='calculator-app-option-memos']")
    .waitFor({ state: "visible" });
  await settle();
  await shot(`fv492-${theme}-6-chooser`);
  await page.locator("[data-testid='calculator-app-option-memos']").click();
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
