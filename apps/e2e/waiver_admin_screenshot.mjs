/* The paywall waiver's admin capture: the /admin wallet edit form showing
 * the paywall_waived checkbox (the one boolean an operator flips to pass
 * the paid gate for a designated org). The admin surface (AshAdmin) ships
 * its own stylesheet, so its light/dark split rides prefers-color-scheme —
 * captured with Playwright colorScheme contexts, not the app theme toggle.
 * Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4101 FV_TOKEN_ADMIN=<jwt> \
 *   FV_WALLET_ID=<uuid> node waiver_admin_screenshot.mjs <outdir>
 * Token + id: mint with the sibling `waiver_admin_seed.exs` (a dev
 * `mix run` one-off — the seed platform admin and one never-paid org's
 * wallet), then export them here.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4101";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const WALLET_ID = process.env.FV_WALLET_ID;
const outdir = process.argv[2] ?? "/tmp/opencode/fv305-admin-shots";

if (!TOKEN || !WALLET_ID) {
  console.error("FV_TOKEN_ADMIN and FV_WALLET_ID required (see the seed script)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// The edit form's URL — AshAdmin's own shape (data_table's admin_path):
// the wallet row's update form for the :set_waiver action, whose form is
// exactly the paywall_waived checkbox.
const editUrl =
  `${BASE}/admin?domain=Billing&resource=Wallet&action_type=update` +
  `&action=set_waiver&table=billing_wallets&primary_key=${WALLET_ID}`;

for (const mode of ["light", "dark"]) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    colorScheme: mode,
  });
  const page = await ctx.newPage();

  // One signed-in context — the session POST mints the cookie the admin
  // gate reads (the paid_gate_screenshot.mjs pattern).
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
  });

  await page.goto(editUrl, { waitUntil: "networkidle" });

  // The checkbox is the whole point — refuse to capture a page without it.
  await page.waitForSelector('input[type="checkbox"]', { timeout: 10_000 });

  await page.screenshot({ path: `${outdir}/paywall-waiver-admin-edit-${mode}.png`, fullPage: true });
  console.log(`captured paywall-waiver-admin-edit-${mode}.png`);

  await ctx.close();
}

await browser.close();
console.log("done:", outdir);
