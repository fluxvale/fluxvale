/* Admin orgs surface captures (#501). Deterministic: one seeded state
 * (admin_orgs_seed.exs resets its own rows first), light and dark shot
 * from the SAME state. Read-only surface: stills only, no motion. The
 * width probes print scrollWidth vs clientWidth for the content band
 * at 1024 / 1280 / 1440 — the no-min-width-floor contract, numbers in
 * the PR.
 *
 *   node admin_orgs_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-orgs-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const orgInstances = process.env.FV_ORG_INSTANCES ?? "";
const orgEmpty = process.env.FV_ORG_EMPTY ?? "";
const orgHidden = process.env.FV_ORG_HIDDEN ?? "";
const orgNoWallet = process.env.FV_ORG_NOWALLET ?? "";

const ids = { token, orgInstances, orgEmpty, orgHidden, orgNoWallet };
const missing = Object.entries(ids).filter(([k, v]) => !v).map(([k]) => k);

if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_orgs_seed.exs)`);
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

// The width probe: the content band must not scroll horizontally at
// the lane's three widths. Waits out the font swap first (fallback
// metrics measure 2px wide mid-load, the settled layout does not).
// Prints the numbers; throws on overflow.
async function probeWidth(page, label) {
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(200);
  const numbers = await page.evaluate(() => {
    const band = document.querySelector(".wrap");
    const doc = document.documentElement;
    return {
      label_band: band ? `${band.scrollWidth}==${band.clientWidth}` : "no-band",
      label_doc: `${doc.scrollWidth}==${doc.clientWidth}`,
    };
  });
  console.log(`width[${label}] band ${numbers.label_band} doc ${numbers.label_doc}`);
  if (numbers.label_band.split("==")[0] !== numbers.label_band.split("==")[1]) {
    throw new Error(`horizontal overflow at ${label}: ${numbers.label_band}`);
  }
  if (numbers.label_doc.split("==")[0] !== numbers.label_doc.split("==")[1]) {
    throw new Error(`document overflow at ${label}: ${numbers.label_doc}`);
  }
}

const browser = await chromium.launch();

// A signed-in context via the sanctioned session POST, then the page.
async function newSession() {
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

for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();

  // The org table: negative (destroy clock with the deadline), zero,
  // positive — the wallet-seam scope copy above it.
  await page.goto(`${BASE}/admin/orgs`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-orgs-org-']");
  await page.screenshot({ path: `${outdir}/admin-orgs-table-${mode}.png`, fullPage: true });
  console.log(`table-${mode}`);

  // Width probes: the no-min-width-floor contract, numbers printed.
  for (const width of [1024, 1280, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await probeWidth(page, `orgs-${mode}-${width}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // Search: past the edge — the honest no-match state.
  const searchBox = page.locator("[data-testid='admin-orgs-search-input']");
  await searchBox.fill("zzz-no-such-org");
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${outdir}/admin-orgs-search-empty-${mode}.png`, fullPage: true });
  console.log(`search-empty-${mode}`);
  await searchBox.fill("");
  await page.waitForTimeout(600);

  // The detail with instances: the lifecycle strip, the sleep note,
  // the wallet summary card. The detail grid probes at the lane's
  // three widths too (the list is not the only grid on the surface).
  await page.goto(`${BASE}/admin/orgs/${orgInstances}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-orgs-instance-']");
  await page.screenshot({ path: `${outdir}/admin-orgs-detail-instances-${mode}.png`, fullPage: true });
  console.log(`detail-instances-${mode}`);

  for (const width of [1024, 1280, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await probeWidth(page, `detail-instances-${mode}-${width}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // The instances' empty state (a member org that deployed nothing).
  await page.goto(`${BASE}/admin/orgs/${orgEmpty}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-orgs-instances-empty']");
  await page.screenshot({ path: `${outdir}/admin-orgs-detail-empty-${mode}.png`, fullPage: true });
  console.log(`detail-empty-${mode}`);

  // The cross-org org detail (a non-member org with an instance of its
  // own — the table and strip render where the scope note used to,
  // under the blanket bypass).
  await page.goto(`${BASE}/admin/orgs/${orgHidden}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-orgs-instance-']");
  await page.screenshot({ path: `${outdir}/admin-orgs-detail-crossorg-${mode}.png`, fullPage: true });
  console.log(`detail-crossorg-${mode}`);

  // The no-wallet note (a team org that never touched billing).
  await page.goto(`${BASE}/admin/orgs/${orgNoWallet}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-orgs-detail-no-wallet']");
  await page.screenshot({ path: `${outdir}/admin-orgs-detail-nowallet-${mode}.png`, fullPage: true });
  console.log(`detail-nowallet-${mode}`);

  await ctx.close();
}

// The sidebar with the orgs entry live: the linked entry beside the
// still-Coming gateways, shot from a people page like the wallets
// flip's capture.
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession();
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-nav-orgs']");
  await page.screenshot({ path: `${outdir}/admin-sidebar-flip-${mode}.png`, fullPage: true });
  console.log(`sidebar-flip-${mode}`);
  await ctx.close();
}

// The narrow pair, light only (the #596 precedent): 768 is the md
// floor where the sidebar first sits beside the content, 480 stacks
// them. Contexts born AT the width (a resize after load reflows the
// grid mid-measure — #596 creates its narrow sessions the same way).
// List and detail — the responsive contract rides both.
for (const width of [768, 480]) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });

  await page.goto(`${BASE}/admin/orgs`, { waitUntil: "networkidle" });
  // attached, not visible: at 480 the first cell can collapse to a
  // zero box mid-stream-patch (the render race), and the screenshot
  // needs presence, not visibility.
  await page.waitForSelector("[data-testid^='admin-orgs-org-']", { state: "attached" });
  await page.waitForTimeout(600);
  await probeWidth(page, `orgs-narrow-${width}`);
  await page.screenshot({ path: `${outdir}/admin-orgs-table-${width}-light.png`, fullPage: true });
  console.log(`table-${width}`);

  await page.goto(`${BASE}/admin/orgs/${orgInstances}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-orgs-instance-']", { state: "attached" });
  await page.waitForTimeout(600);
  await probeWidth(page, `detail-narrow-${width}`);
  await page.screenshot({
    path: `${outdir}/admin-orgs-detail-instances-${width}-light.png`,
    fullPage: true,
  });
  console.log(`detail-instances-${width}`);

  await ctx.close();
}

await browser.close();
console.log("done");
