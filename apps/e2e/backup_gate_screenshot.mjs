/* The backup paid-gate's panel screenshots: the surfaces the wallet
 * gates add copy to — (a) the unconfigured setup card's never-paid
 * callout, (b) the configured card's paid-but-empty callout, (c) the
 * configured card's never-paid callout (the legacy/lapsed shape), and
 * (d) the "Back up now" refusal at zero balance. Light AND dark for
 * all. Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4000 FV_TOKEN_A=<jwt> FV_TOKEN_B=<jwt> \
 *   FV_TOKEN_C=<jwt> node backup_gate_screenshot.mjs <outdir>
 * Tokens: mint all three with the sibling `backup_gate_seed.exs` (a dev
 * `mix run` one-off), then export them here.
 * Token A: never-paid user, deployed instance, NO settings row.
 * Token B: paid-once user at zero balance, deployed instance WITH a
 * settings row — the script also clicks "Back up now" and captures the
 * refusal.
 * Token C: never-paid user WITH a settings row.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN_A = process.env.FV_TOKEN_A;
const TOKEN_B = process.env.FV_TOKEN_B;
const TOKEN_C = process.env.FV_TOKEN_C;
const outdir = process.argv[2] ?? "/tmp/opencode/fv305-shots";

if (!TOKEN_A || !TOKEN_B || !TOKEN_C) {
  console.error("FV_TOKEN_A, FV_TOKEN_B and FV_TOKEN_C required (see the seed script)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function signInContext(token) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

const unconfigured = await signInContext(TOKEN_A);
const drained = await signInContext(TOKEN_B);
const configuredUnpaid = await signInContext(TOKEN_C);

// All three land on their own instance page (one instance each).
for (const { page } of [unconfigured, drained, configuredUnpaid]) {
  await page.goto(`${BASE}/instances`, { waitUntil: "networkidle" });
  await page.locator("a[href^='/instances/']").first().click();
  await page.locator("[data-testid=backups-panel]").waitFor();
}

// (d) click "Back up now" so the refusal callout is on the page, then
// back to the top — a fullPage shot while scrolled paints the sticky
// header mid-page over the content.
await drained.page.locator("[data-testid=back-up-now]").click();
await drained.page.locator("[data-testid=backups-error]").waitFor();
await drained.page.evaluate(() => window.scrollTo(0, 0));
await drained.page.waitForTimeout(300);

const shots = [
  ["backup-paid-gate-setup", unconfigured.page],
  ["backup-paid-gate-config-empty", drained.page],
  ["backup-paid-gate-config-unpaid", configuredUnpaid.page],
  ["backup-paid-gate-run-refusal", drained.page],
];

for (const mode of ["light", "dark"]) {
  for (const [name, page] of shots) {
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

await unconfigured.ctx.close();
await drained.ctx.close();
await configuredUnpaid.ctx.close();
await browser.close();
console.log("done:", outdir);
