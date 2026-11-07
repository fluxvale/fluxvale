/* Admin wallets surface captures (#501): the full state set in both
 * themes, plus the waiver-confirm reveal GIF (the reveal is motion).
 * Local dev target only (127.0.0.1:4000), driven by a minted session
 * token (FV_TOKEN, printed by admin_billing_seed.exs — no test
 * backdoors in the app).
 *
 *   node admin_billing_screenshot.mjs <outdir>
 *
 * Stages: the wallet table (negative + waived rows), the wallet detail
 * with its ledger and reversal pair, the goodwill form and its posted
 * row (a small credit posts — dev DB only), the reversal confirm, the
 * search empty state, the ledger empty state, the home card Open, and
 * the waiver reveal GIF.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-billing-shots";
mkdirSync(outdir, { recursive: true });
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const healthyId = process.env.FV_HEALTHY_WALLET_ID ?? "";
const waivedId = process.env.FV_WAIVED_WALLET_ID ?? "";
const negativeId = process.env.FV_NEGATIVE_WALLET_ID ?? "";
const emptyId = process.env.FV_EMPTY_WALLET_ID ?? "";

if (!token || !healthyId || !waivedId || !negativeId || !emptyId) {
  console.error(
    "FV_TOKEN, FV_HEALTHY_WALLET_ID, FV_WAIVED_WALLET_ID, FV_NEGATIVE_WALLET_ID and FV_EMPTY_WALLET_ID required (see admin_billing_seed.exs)"
  );
  process.exit(1);
}

async function setTheme(page, mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

const browser = await chromium.launch();

const newSession = async ({ video = false } = {}) => {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    ...(video ? { recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } } : {}),
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
};

for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();

  // -- the wallet table: negative (destroy clock) and waived rows --
  await page.goto(`${BASE}/admin/billing`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-billing-org-']");
  await page.screenshot({ path: `${outdir}/admin-billing-table-${mode}.png`, fullPage: true });
  console.log(`captured admin-billing-table-${mode}.png`);

  // -- search: past the edge (the honest empty state) --
  const searchBox = page.locator("[data-testid='admin-billing-search-input']");
  await searchBox.fill("zzz-no-such-org");
  await page.waitForTimeout(600);
  await page.screenshot({
    path: `${outdir}/admin-billing-search-empty-${mode}.png`,
    fullPage: true,
  });
  console.log(`captured admin-billing-search-empty-${mode}.png`);
  await searchBox.fill("");
  await page.waitForTimeout(600);

  // -- the healthy wallet detail: facts, ledger, reversal pair --
  await page.goto(`${BASE}/admin/billing/wallets/${healthyId}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-wallet-entry-']");
  await page.screenshot({ path: `${outdir}/admin-wallet-detail-${mode}.png`, fullPage: true });
  console.log(`captured admin-wallet-detail-${mode}.png`);

  // -- the ledger's empty state --
  await page.goto(`${BASE}/admin/billing/wallets/${emptyId}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-wallet-ledger-empty']");
  await page.screenshot({ path: `${outdir}/admin-wallet-ledger-empty-${mode}.png`, fullPage: true });
  console.log(`captured admin-wallet-ledger-empty-${mode}.png`);

  await ctx.close();
}

// -- the goodwill post + reversal confirm (posts land in the dev DB;
// run after the list captures so they carry no leftovers) --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();

  await page.goto(`${BASE}/admin/billing/wallets/${healthyId}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("#admin-wallet-goodwill-form");

  // The goodwill form and its fence, pre-submit.
  await page.screenshot({ path: `${outdir}/admin-wallet-goodwill-form-${mode}.png`, fullPage: true });
  console.log(`captured admin-wallet-goodwill-form-${mode}.png`);

  // Post 500 cents: the flash names the contract, the row lands on top.
  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("500");
  await page.locator("[data-testid='admin-wallet-goodwill-submit']").click();
  await page.locator("#flash-info").waitFor();
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/admin-wallet-goodwill-posted-${mode}.png`, fullPage: true });
  console.log(`captured admin-wallet-goodwill-posted-${mode}.png`);

  // The reversal confirm on the just-posted row.
  const reverse = page.locator("[data-testid^='admin-wallet-reverse-']").first();
  await reverse.click();
  await page.locator("[data-testid='admin-wallet-reverse-confirm']").waitFor();
  await page.waitForTimeout(300);
  await page.screenshot({
    path: `${outdir}/admin-wallet-reverse-confirm-${mode}.png`,
    fullPage: true,
  });
  console.log(`captured admin-wallet-reverse-confirm-${mode}.png`);
  await page.locator("[data-testid='admin-wallet-reverse-cancel']").click();
  await page.locator("[data-testid='admin-wallet-reverse-confirm']").waitFor({ state: "detached" });

  await ctx.close();
}

// -- the home card in its Open state --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();
  await page.goto(`${BASE}/admin`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-surface-wallets']");
  await page.screenshot({ path: `${outdir}/admin-home-card-${mode}.png`, fullPage: true });
  console.log(`captured admin-home-card-${mode}.png`);
  await ctx.close();
}

// -- the waiver-confirm reveal GIF: a real press on the flip, the
// pressed state visible, the contract panel revealed and HELD, then
// Cancel closing it. (The healthy wallet is the waive direction, the
// contract copy; the reveal CANCELS, so no waiver lands.) --
{
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } },
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  await page.goto(`${BASE}/admin/billing/wallets/${healthyId}`, { waitUntil: "networkidle" });
  await setTheme(page, "light");

  const flip = page.locator("[data-testid='admin-wallet-waiver-flip']");
  await flip.scrollIntoViewIfNeeded();
  await page.waitForTimeout(300);
  await flip.hover();
  await page.waitForTimeout(400);
  const box = await flip.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.up();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor();
  await page.waitForTimeout(1500);

  const cancel = page.locator("[data-testid='admin-wallet-waiver-cancel']");
  const cancelBox = await cancel.boundingBox();
  await page.mouse.move(cancelBox.x + cancelBox.width / 2, cancelBox.y + cancelBox.height / 2, {
    steps: 8,
  });
  await cancel.click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor({ state: "detached" });
  await page.waitForTimeout(500);

  const video = await page.video().path();
  await ctx.close();
  console.log(`recorded ${video}`);
}

await browser.close();
console.log("done");
