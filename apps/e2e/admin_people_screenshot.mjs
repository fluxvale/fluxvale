/* Admin people surface captures (#501): the full state set in both
 * themes, plus the withdraw-confirm reveal GIF (the reveal is motion).
 * Local dev target only (127.0.0.1:4000), driven by a minted session
 * cookie passed via FV_TOKEN (produced through the same JWT the
 * sign-in flow mints — no test backdoors in the app).
 *
 * Two phases, driven by the dev-data script this tooling assumes
 * (fv501_capture_seed.exs in the operator's scratch):
 *
 *   node admin_people_screenshot.mjs <outdir> empty
 *     — against SEED_EMPTY=1 data: the no-invitations empty state.
 *
 *   node admin_people_screenshot.mjs <outdir> full
 *     — against the staged data (pending, accepted, withdrawn,
 *       expired): the list, the inline confirm, the form's honest
 *       flashes, search both ways, and the reveal GIF.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-shots";
const phase = process.argv[3] ?? "full";
mkdirSync(outdir, { recursive: true });
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
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

if (phase === "empty") {
  for (const mode of ["light", "dark"]) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
    await page.request.post(`${BASE}/auth/session`, {
      form: { token },
      headers: { "x-csrf-token": csrf },
    });
    await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
    await setTheme(page, mode);
    await page.screenshot({ path: `${outdir}/admin-people-empty-${mode}.png`, fullPage: true });
    console.log(`captured admin-people-empty-${mode}.png`);
    await ctx.close();
  }
}

if (phase === "full") {
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

  // The no-write captures run for BOTH modes before the flash steps:
  // the flash steps each add a row, and a mode's list capture must not
  // carry the other mode's leftovers.
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();

    // -- the seeded list: pending, accepted, withdrawn, expired --
    await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
    // A 500 or a bounce must never masquerade as a capture: the
    // sidebar testid is the page-mounted assertion (Am. 4's shell).
    await page.waitForSelector("[data-testid='admin-sidebar']");
    await setTheme(page, mode);
    await page.waitForSelector("[data-testid^='admin-people-email-']");
    await page.screenshot({ path: `${outdir}/admin-people-${mode}.png`, fullPage: true });
    console.log(`captured admin-people-${mode}.png`);

    // -- the inline withdraw confirm, expanded under its row --
    await page.locator("[data-testid^='admin-people-withdraw-']").first().click();
    await page.locator("[data-testid='destructive-confirm']").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-people-withdraw-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-withdraw-confirm-${mode}.png`);
    await page.locator("[data-testid='admin-people-withdraw-cancel']").click();
    await page.locator("[data-testid='destructive-confirm']").waitFor({ state: "detached" });

    // -- search: filtered down, then past the edge --
    const searchBox = page.locator("[data-testid='admin-people-search-input']");
    await searchBox.fill("pending-invite");
    await page.waitForTimeout(600);
    await page.screenshot({
      path: `${outdir}/admin-people-search-filtered-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-search-filtered-${mode}.png`);

    await searchBox.fill("zzz-no-such-invitation");
    await page.waitForTimeout(600);
    await page.screenshot({
      path: `${outdir}/admin-people-search-empty-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-search-empty-${mode}.png`);

    await ctx.close();
  }

  // -- the reveal GIF: cause and effect, then the reveal HELD --
  // (a real press on Withdraw, cursor hover + the pressed state, the
  // panel revealed under the row and held, then Cancel closing it).
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
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, "light");

  const pendingRow = page
    .locator("#admin-people-table > div", { hasText: "pending-invite@example.com" })
    .first();
  const withdraw = pendingRow.locator("[data-testid^='admin-people-withdraw-']");
  await withdraw.hover();
  await page.waitForTimeout(400);
  // Park the row at a fixed height so the panel below it (with its
  // action strip) stays inside the video crop.
  const rowBox = await pendingRow.boundingBox();
  await page.mouse.wheel(0, rowBox.y - 640);
  await page.waitForTimeout(300);
  const box = await withdraw.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 8 });
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.up();
  await page.locator("[data-testid='destructive-confirm']").waitFor();
  await page.waitForTimeout(1500);
  const cancel = pendingRow.locator("[data-testid='admin-people-withdraw-cancel']");
  const cancelBox = await cancel.boundingBox();
  await page.mouse.move(cancelBox.x + cancelBox.width / 2, cancelBox.y + cancelBox.height / 2, {
    steps: 8,
  });
  await cancel.click();
  await page.locator("[data-testid='destructive-confirm']").waitFor({ state: "detached" });
  await page.waitForTimeout(500);

  const video = await page.video().path();
  await ctx.close();
  console.log(`recorded ${video}`);

  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();

    // -- the invite form's honest flashes (each success adds a row;
    // they run after the list captures above) --
    const emailBox = page.locator("[data-testid='admin-people-invite-email']");
    await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
    await setTheme(page, mode);

    const dismissFlash = async (kind) => {
      const close = page.locator(`#${kind} button[aria-label='close']`);
      if (await close.count()) {
        await close.click();
        await page.locator(`#${kind}`).waitFor({ state: "detached" });
      }
    };

    // A live account's address: the already-active refusal.
    await emailBox.fill("admin@fluxvale.com");
    await page.locator("[data-testid='admin-people-invite-submit']").click();
    await page.locator("#flash-error").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-people-already-active-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-already-active-${mode}.png`);
    await dismissFlash("flash-error");

    // An unsendable address: refused before anything is written. The
    // form carries native email validation, so it is dropped for this
    // one step — the point is the server's refusal, not the browser's.
    await page.evaluate(() =>
      document.getElementById("admin-people-invite-form").setAttribute("novalidate", "")
    );
    await emailBox.fill("not-an-address");
    await page.locator("[data-testid='admin-people-invite-submit']").click();
    await page.locator("#flash-error").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-people-invalid-address-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-invalid-address-${mode}.png`);
    await dismissFlash("flash-error");

    // A fresh address: the success flash (the row appears with it).
    // The address is unique per run, so the copy is the fresh-invite
    // branch, not a re-issue of a previous run's row.
    await emailBox.fill(`fresh-invite-${mode}-${Date.now()}@example.com`);
    await page.locator("[data-testid='admin-people-invite-submit']").click();
    await page.locator("#flash-info").waitFor();
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-people-invite-flash-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-people-invite-flash-${mode}.png`);

    await ctx.close();
  }

}

await browser.close();
console.log("done");
