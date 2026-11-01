/* The backup paid-gate's panel screenshots: the two surfaces the
 * wallet gates add copy to — (a) the unconfigured setup card's
 * never-paid callout and (b) the "Back up now" refusal at zero balance
 * (paid once, drained). Light AND dark for both. Local dev target
 * only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4102 FV_TOKEN_A=<jwt> FV_TOKEN_B=<jwt> \
 *   node backup_gate_screenshot.mjs <outdir>
 * Tokens: mint both with the sibling `backup_gate_seed.exs` (a dev
 * `mix run` one-off), then export them here.
 * Token A: never-paid user, deployed instance, NO settings row.
 * Token B: paid-once user at zero balance, deployed instance WITH a
 * settings row — the script clicks "Back up now" and captures the
 * refusal.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4102";
const TOKEN_A = process.env.FV_TOKEN_A;
const TOKEN_B = process.env.FV_TOKEN_B;
const outdir = process.argv[2] ?? "/tmp/opencode/fv305-shots";

if (!TOKEN_A || !TOKEN_B) {
  console.error("FV_TOKEN_A and FV_TOKEN_B required (see the seed script)");
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

// Both land on their own instance page (one instance each).
for (const { page } of [unconfigured, drained]) {
  await page.goto(`${BASE}/instances`, { waitUntil: "networkidle" });
  await page.locator("a[href^='/instances/']").first().click();
  await page.locator("[data-testid=backups-panel]").waitFor();
}

// (b) click "Back up now" so the refusal callout is on the page, then
// back to the top — a fullPage shot while scrolled paints the sticky
// header mid-page over the content.
await drained.page.locator("[data-testid=back-up-now]").click();
await drained.page.locator("[data-testid=backups-error]").waitFor();
await drained.page.evaluate(() => window.scrollTo(0, 0));
await drained.page.waitForTimeout(300);

const shots = [
  ["backup-paid-gate-setup", unconfigured.page],
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
await browser.close();
console.log("done:", outdir);
