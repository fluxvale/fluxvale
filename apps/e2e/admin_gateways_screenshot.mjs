/* Admin gateways surface captures (#501). Deterministic: one seeded
 * state (admin_gateways_seed.exs resets its own rows first), light and
 * dark shot from the SAME state. Read-only surface: stills only, no
 * motion. The width probes print scrollWidth vs clientWidth for the
 * content band at 1024 / 1280 / 1440 — the no-min-width-floor
 * contract, numbers in the PR.
 *
 * Three sessions: the member admin (list + detail + the hidden-id arm),
 * the gateway-less admin (the honest empty), and the org-less admin
 * (the scope note).
 *
 *   node admin_gateways_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-gateways-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const tokenEmpty = process.env.FV_TOKEN_EMPTY ?? "";
const tokenOrgless = process.env.FV_TOKEN_ORGLESS ?? "";
const gatewayDetail = process.env.FV_GATEWAY_DETAIL ?? "";
const gatewayHidden = process.env.FV_GATEWAY_HIDDEN ?? "";

const ids = { token, tokenEmpty, tokenOrgless, gatewayDetail, gatewayHidden };
const missing = Object.entries(ids).filter(([k, v]) => !v).map(([k]) => k);

if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_gateways_seed.exs)`);
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
// the lane's three widths. Prints the numbers; throws on overflow.
async function probeWidth(page, label) {
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
async function newSession(sessionToken) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: sessionToken },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

// The member admin: the populated list, the search arm, the detail,
// and the hidden-id flash.
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(token);

  // The gateway table: attention pinned first, then the state
  // vocabulary (Connected / Connecting / Suspended / Removing). The
  // stranger org's gateway is deliberately absent from this frame.
  await page.goto(`${BASE}/admin/gateways`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-gateways-host-']");
  await page.screenshot({ path: `${outdir}/admin-gateways-table-${mode}.png`, fullPage: true });
  console.log(`table-${mode}`);

  // Width probes: the no-min-width-floor contract, numbers printed.
  for (const width of [1024, 1280, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await probeWidth(page, `gateways-${mode}-${width}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // Search: past the edge — the honest no-match state.
  const searchBox = page.locator("[data-testid='admin-gateways-search-input']");
  await searchBox.fill("zzz-no-such-gateway");
  await page.waitForTimeout(600);
  await page.screenshot({
    path: `${outdir}/admin-gateways-search-empty-${mode}.png`,
    fullPage: true,
  });
  console.log(`search-empty-${mode}`);
  await searchBox.fill("");
  await page.waitForTimeout(600);

  // The detail: facts card, THE credential-references card (names,
  // never keys), and the domains in their verification states.
  await page.goto(`${BASE}/admin/gateways/${gatewayDetail}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-secret-card']");
  await page.waitForSelector("[data-testid^='admin-gateways-domain-state-']");
  await page.screenshot({
    path: `${outdir}/admin-gateways-detail-${mode}.png`,
    fullPage: true,
  });
  console.log(`detail-${mode}`);
  await probeWidth(page, `detail-${mode}-1440`);

  // The missing arm: a stranger org's gateway id reads exactly like an
  // unknown id — one flash, back to the list.
  await page.goto(`${BASE}/admin/gateways/${gatewayHidden}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-gateways']");
  await page.screenshot({
    path: `${outdir}/admin-gateways-not-listed-${mode}.png`,
    fullPage: true,
  });
  console.log(`not-listed-${mode}`);

  await ctx.close();
}

// The gateway-less admin: the honest empty state.
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(tokenEmpty);
  await page.goto(`${BASE}/admin/gateways`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-empty']");
  await page.screenshot({ path: `${outdir}/admin-gateways-empty-${mode}.png`, fullPage: true });
  console.log(`empty-${mode}`);
  await ctx.close();
}

// The org-less admin: the scope note (the membership probe's answer).
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(tokenOrgless);
  await page.goto(`${BASE}/admin/gateways`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-scope-note']");
  await page.screenshot({ path: `${outdir}/admin-gateways-scope-note-${mode}.png`, fullPage: true });
  console.log(`scope-note-${mode}`);
  await ctx.close();
}

// The sidebar with the gateways entry live: shot from a people page
// like the earlier flips' capture. On this branch the orgs entry is
// still its Coming placeholder — that flip belongs to the open orgs
// slice (#603); when it merges, the Coming list empties completely.
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(token);
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-nav-gateways']");
  await page.screenshot({ path: `${outdir}/admin-sidebar-flip-${mode}.png`, fullPage: true });
  console.log(`sidebar-flip-${mode}`);
  await ctx.close();
}

await browser.close();
console.log("done");
