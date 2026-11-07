/* Admin wallets surface captures (#501). Deterministic: one seeded
 * state (admin_billing_seed.exs resets its own rows first), light and
 * dark shot from the SAME state — the one goodwill post lands in the
 * light pass and both passes then shoot the same posted state. No
 * stale toasts (each is dismissed between steps). The waiver reveal
 * GIF records on a cookie-carried context (no sign-in lead-in) and is
 * cropped to the waiver card at native scale. The before/after pair
 * talks about ONE named org (Beacon Works): the AshAdmin checked box
 * is the before, the removal confirm is the after.
 *
 *   node admin_billing_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv571-shots";
mkdirSync(outdir, { recursive: true });
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const healthyId = process.env.FV_HEALTHY_WALLET_ID ?? "";
const waivedId = process.env.FV_WAIVED_WALLET_ID ?? "";
const negativeId = process.env.FV_NEGATIVE_WALLET_ID ?? "";
const emptyId = process.env.FV_EMPTY_WALLET_ID ?? "";
const pairId = process.env.FV_PAIR_WALLET_ID ?? "";

const ids = { token, healthyId, waivedId, negativeId, emptyId, pairId };
const missing = Object.entries(ids).filter(([k, v]) => !v).map(([k]) => k);

if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_billing_seed.exs)`);
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

// A signed-in context via the sanctioned session POST, then the page.
async function newSession({ video = false } = {}) {
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
}

// A context that opens straight on a URL (cookie carried over): the
// GIF's recording starts on the page, with no sign-in lead-in.
async function cookieSession(startUrl, { video = false } = {}) {
  const warm = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const warmPage = await warm.newPage();
  await warmPage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await warmPage.locator('meta[name="csrf-token"]').getAttribute("content");
  await warmPage.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  const cookies = await warm.cookies(BASE);
  await warm.close();

  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    ...(video ? { recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } } : {}),
  });
  await ctx.addCookies(cookies);
  const page = await ctx.newPage();
  await page.goto(startUrl, { waitUntil: "networkidle" });
  return { ctx, page };
}

const dismissFlash = async (page, kind) => {
  const close = page.locator(`#${kind} button[aria-label='close']`);
  if (await close.count()) {
    await close.click();
    await page.locator(`#${kind}`).waitFor({ state: "detached" });
  }
};

// -- Phase A: the no-write state set, light and dark from the same
// state. The goodwill form capture is a REAL form state (typed amount,
// live dollar echo), dismissed after each shot. --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();

  // The wallet table: negative (destroy clock with the deadline), waived.
  await page.goto(`${BASE}/admin/billing`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-billing-org-']");
  await page.screenshot({ path: `${outdir}/admin-billing-table-${mode}.png`, fullPage: true });
  console.log(`table-${mode}`);

  // Search: past the edge.
  const searchBox = page.locator("[data-testid='admin-billing-search-input']");
  await searchBox.fill("zzz-no-such-org");
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${outdir}/admin-billing-search-empty-${mode}.png`, fullPage: true });
  console.log(`search-empty-${mode}`);
  await searchBox.fill("");
  await page.waitForTimeout(600);

  // The healthy detail: facts, ledger with the reversal pair.
  await page.goto(`${BASE}/admin/billing/wallets/${healthyId}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-wallet-entry-']");
  await page.screenshot({ path: `${outdir}/admin-wallet-detail-${mode}.png`, fullPage: true });
  console.log(`detail-${mode}`);

  // The goodwill form, real state: typed amount, live dollar echo.
  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("500");
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${outdir}/admin-wallet-goodwill-form-${mode}.png`, fullPage: true });
  console.log(`goodwill-form-${mode}`);
  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("");

  // Fractional cents: the honest server refusal. The input's step=1
  // would block the value in the browser, so this one step drops the
  // constraint (AFTER the echo patch from the clears settles, or the
  // fresh form node loses the attribute) — the point is the server's
  // copy, not the browser's.
  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("5.50");
  await page.waitForTimeout(600);
  await page.evaluate(() =>
    document.getElementById("admin-wallet-goodwill-form").setAttribute("novalidate", "")
  );
  await page.locator("[data-testid='admin-wallet-goodwill-submit']").click();

  try {
    await page.locator("#flash-error").waitFor({ timeout: 10_000 });
  } catch (e) {
    await page.screenshot({ path: `${outdir}/debug-fractional-${mode}.png`, fullPage: true });
    console.log("url:", page.url());
    console.log(
      "form present:",
      await page.evaluate(() => Boolean(document.getElementById("admin-wallet-goodwill-form")))
    );
    throw e;
  }
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-wallet-goodwill-fractional-${mode}.png`, fullPage: true });
  console.log(`goodwill-fractional-${mode}`);
  await dismissFlash(page, "flash-error");
  await page.evaluate(() =>
    document.getElementById("admin-wallet-goodwill-form").removeAttribute("novalidate")
  );
  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("");

  // The waiver confirm still (the waive direction on the healthy org).
  await page.locator("[data-testid='admin-wallet-waiver-flip']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-wallet-waiver-confirm-${mode}.png`, fullPage: true });
  console.log(`waiver-confirm-${mode}`);
  await page.locator("[data-testid='admin-wallet-waiver-cancel']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor({ state: "detached" });

  // The reversal confirm on the adjustment credit's lever.
  const reverse = page.locator("[data-testid^='admin-wallet-reverse-']").first();
  await reverse.click();
  await page.locator("[data-testid='admin-wallet-reverse-confirm']").waitFor();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-wallet-reverse-confirm-${mode}.png`, fullPage: true });
  console.log(`reverse-confirm-${mode}`);
  await page.locator("[data-testid='admin-wallet-reverse-cancel']").click();
  await page.locator("[data-testid='admin-wallet-reverse-confirm']").waitFor({ state: "detached" });

  // The negative wallet detail: the destroy clock with the deadline.
  await page.goto(`${BASE}/admin/billing/wallets/${negativeId}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-wallet-destroy-clock']");
  await page.screenshot({ path: `${outdir}/admin-wallet-negative-detail-${mode}.png`, fullPage: true });
  console.log(`negative-detail-${mode}`);

  // The ledger's empty state.
  await page.goto(`${BASE}/admin/billing/wallets/${emptyId}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-wallet-ledger-empty']");
  await page.screenshot({ path: `${outdir}/admin-wallet-ledger-empty-${mode}.png`, fullPage: true });
  console.log(`ledger-empty-${mode}`);

  // The remove-waiver confirm (the unpaid waived org: closes again).
  await page.goto(`${BASE}/admin/billing/wallets/${waivedId}`, { waitUntil: "networkidle" });
  await page.locator("[data-testid='admin-wallet-waiver-flip']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-waiver-remove-confirm-${mode}.png`, fullPage: true });
  console.log(`remove-confirm-${mode}`);
  await page.locator("[data-testid='admin-wallet-waiver-cancel']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor({ state: "detached" });

  await ctx.close();
}

// -- Phase B: the ONE goodwill post (the keyless post's own warning
// demonstrated by NOT doing it twice). Light opens the confirm and
// posts; dark then shoots the SAME posted state. --
// The wallet page's render occasionally races a fresh context's first
// navigation; a failed render retries on a fresh session rather than
// shipping a half-state.
async function openGoodwill(mode) {
  for (const attempt of [1, 2, 3]) {
    const { ctx, page } = await newSession();
    await page.goto(`${BASE}/admin/billing/wallets/${healthyId}`, { waitUntil: "networkidle" });
    await setTheme(page, mode);
    await page.waitForTimeout(1500);

    // The form carries an id, not a testid.
    if ((await page.locator("#admin-wallet-goodwill-form").count()) > 0) {
      return { ctx, page };
    }

    console.log(`goodwill-${mode}: attempt ${attempt} missed the form, retrying`);
    await page.screenshot({ path: `${outdir}/debug-goodwill-${mode}-${attempt}.png`, fullPage: true });
    console.log("url:", page.url());
    await ctx.close();
  }

  throw new Error(`the goodwill form never rendered (${mode})`);
}

for (const mode of ["light", "dark"]) {
  const { ctx, page } = await openGoodwill(mode);
  await page.waitForTimeout(500);

  await page.locator("[data-testid='admin-wallet-goodwill-amount']").fill("500");
  await page.waitForTimeout(600);

  if (mode === "light") {
    await page.locator("[data-testid='admin-wallet-goodwill-submit']").click();
    await page.locator("[data-testid='admin-wallet-goodwill-confirm']").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-wallet-goodwill-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`goodwill-confirm-${mode}`);

    await page.locator("[data-testid='admin-wallet-goodwill-confirm']").click();
    await page.locator("#flash-info").waitFor();
    await page.waitForTimeout(400);
  } else {
    // The dark pass opens the same confirm, cancels it (the post
    // already exists from the light pass), and shoots the posted state.
    await page.locator("[data-testid='admin-wallet-goodwill-submit']").click();
    await page.locator("[data-testid='admin-wallet-goodwill-confirm']").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-wallet-goodwill-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`goodwill-confirm-${mode}`);

    await page.locator("[data-testid='admin-wallet-goodwill-cancel']").click();
    await page.locator("[data-testid='admin-wallet-goodwill-confirm']").waitFor({ state: "detached" });
    await page.waitForTimeout(400);
  }

  await page.screenshot({ path: `${outdir}/admin-wallet-goodwill-posted-${mode}.png`, fullPage: true });
  console.log(`goodwill-posted-${mode}`);
  await dismissFlash(page, "flash-info");

  await ctx.close();
}

// -- The sidebar's live wallets entry (the cards-era home card is
// retired): the linked entry beside the still-Coming ones. --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-nav-wallets']");
  await page.screenshot({ path: `${outdir}/admin-sidebar-flip-${mode}.png`, fullPage: true });
  console.log(`sidebar-flip-${mode}`);
  await ctx.close();
}

// -- The before/after pair: ONE named org (Beacon Works, waived and
// paid). The before is the AshAdmin checked checkbox (shot by the
// sibling waiver_admin_screenshot.mjs against FV_PAIR_WALLET_ID); the
// after is this surface's removal confirm. --
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();
  await page.goto(`${BASE}/admin/billing/wallets/${pairId}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.locator("[data-testid='admin-wallet-waiver-flip']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-waiver-after-confirm-${mode}.png`, fullPage: true });
  console.log(`after-confirm-${mode}`);
  await page.locator("[data-testid='admin-wallet-waiver-cancel']").click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor({ state: "detached" });
  await ctx.close();
}

// -- The waiver-confirm reveal GIF: cookie-carried context (the
// recording opens ON the page), a real press, the panel held, Cancel.
// The waiver card's box is printed for the crop. --
{
  const url = `${BASE}/admin/billing/wallets/${healthyId}`;
  const { ctx, page } = await cookieSession(url, { video: true });
  await setTheme(page, "light");
  await page.waitForSelector("[data-testid='admin-wallet-waiver-card']");

  const card = page.locator("[data-testid='admin-wallet-waiver-card']");
  await card.scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);

  const flip = page.locator("[data-testid='admin-wallet-waiver-flip']");
  await flip.hover();
  await page.waitForTimeout(400);
  const box = await flip.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.up();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor();
  await page.waitForTimeout(1800);

  // The crop: the card's box WITH THE PANEL OPEN (the panel is the
  // point), padded, clamped to the viewport.
  const cardBox = await card.boundingBox();
  const crop = {
    x: Math.max(0, Math.floor(cardBox.x - 24)),
    y: Math.max(0, Math.floor(cardBox.y - 24)),
    width: Math.min(1440, Math.ceil(cardBox.width + 48)),
    height: Math.min(900, Math.ceil(cardBox.height + 48)),
  };

  const cancel = page.locator("[data-testid='admin-wallet-waiver-cancel']");
  const cancelBox = await cancel.boundingBox();
  await page.mouse.move(cancelBox.x + cancelBox.width / 2, cancelBox.y + cancelBox.height / 2, {
    steps: 8,
  });
  await cancel.click();
  await page.locator("[data-testid='admin-wallet-waiver-confirm']").waitFor({ state: "detached" });
  await page.waitForTimeout(500);

  writeFileSync(`${outdir}/gif_crop.txt`, JSON.stringify(crop));
  console.log(`crop ${JSON.stringify(crop)}`);

  const video = await page.video().path();
  await ctx.close();
  console.log(`recorded ${video}`);
}

await browser.close();
console.log("done");
