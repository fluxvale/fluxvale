/* Admin gateways surface captures (#501, review round 2). One seeded
 * state (admin_gateways_seed.exs resets its own rows first), light and
 * dark shot from the SAME state. Read-only surface: stills only, no
 * motion. The width probes print scrollWidth vs clientWidth for EVERY
 * content band on the page (the hero band was a false green — the
 * review's finding) plus the console root and the document, at 480 /
 * 768 / 1024 / 1280 / 1440 where the surface claims them; the script
 * throws on overflow.
 *
 * Four sessions: the member admin (list + detail + the non-connected
 * detail + the domains-empty detail + the hidden-id arm), the
 * gateway-less admin (the filter-scoped empty), and the org-less admin
 * (the scope note).
 *
 *   node admin_gateways_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-gw-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
const tokenEmpty = process.env.FV_TOKEN_EMPTY ?? "";
const tokenOrgless = process.env.FV_TOKEN_ORGLESS ?? "";
const gatewayDetail = process.env.FV_GATEWAY_DETAIL ?? "";
const gatewayAttention = process.env.FV_GATEWAY_ATTENTION ?? "";
const gatewayNoDomains = process.env.FV_GATEWAY_NODOMAINS ?? "";
const gatewayHidden = process.env.FV_GATEWAY_HIDDEN ?? "";

const ids = {
  token,
  tokenEmpty,
  tokenOrgless,
  gatewayDetail,
  gatewayAttention,
  gatewayNoDomains,
  gatewayHidden,
};
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

// The width probe: EVERY .wrap on the page (the hero band AND the
// content band — querySelector's first-match hero band was the false
// green), the console root, and the document. Prints the numbers;
// throws on overflow at the lane's claimed widths. The narrow shots
// (480/768) print informational numbers without gating — the fixed
// grid tracks are allowed to ride their own scroll there.
async function probeWidth(page, label, gate) {
  const numbers = await page.evaluate(() => {
    const wraps = [...document.querySelectorAll(".wrap")];
    const console_root = document.querySelector(".appgram.console");
    const doc = document.documentElement;
    return {
      bands: wraps.map(
        (band, i) => `wrap${i}:${band.scrollWidth}==${band.clientWidth}`
      ),
      console_root: console_root
        ? `console:${console_root.scrollWidth}==${console_root.clientWidth}`
        : "no-console",
      doc: `doc:${doc.scrollWidth}==${doc.clientWidth}`,
    };
  });
  const line = [...numbers.bands, numbers.console_root, numbers.doc].join(" ");
  console.log(`width[${label}] ${line}`);
  for (const part of line.split(" ")) {
    const [measured, client] = part.split(":").pop().split("==");
    if (gate && measured !== client) {
      throw new Error(`horizontal overflow at ${label}: ${part}`);
    }
  }
}

const LIST_WIDTHS = [480, 768, 1024, 1280, 1440];
const DETAIL_WIDTHS = [480, 768, 1024, 1280, 1440];

const browser = await chromium.launch();

// A signed-in context via the sanctioned session POST, then the page.
// The POST is checked for a 2xx EXPLICITLY, at the failure point: an
// expired or missing token, a CSRF mismatch, or a refused role each
// answer non-2xx with a body that names the cause, and a silent
// hand-wave here used to surface much later as a mystery redirect to
// /sign-in. The check reads the status and the body, so the seed's
// token is the first suspect named.
async function newSession(sessionToken) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const posted = await page.request.post(`${BASE}/auth/session`, {
    form: { token: sessionToken },
    headers: { "x-csrf-token": csrf },
  });

  if (!posted.ok()) {
    const cause = (await posted.text()).slice(0, 400).replace(/\s+/g, " ").trim();
    throw new Error(
      `session POST failed: HTTP ${posted.status()} ${posted.statusText()} — ` +
        `is the seed's session token expired, missing, or for a demoted account? Body: ${cause}`
    );
  }

  return { ctx, page };
}

async function atWidths(page, label, widths) {
  for (const width of widths) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await probeWidth(page, `${label}-${width}`, width >= 1024);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

// The member admin: the populated list, the search arm, the connected
// detail (all five domain states), the non-connected detail (the
// credential card beside the reconnect message), the domains-empty
// detail, and the hidden-id arm.
for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(token);

  // The gateway table: the state-keyed attention pin, then the state
  // vocabulary with its shape cues. The stranger org's gateway is
  // deliberately absent from this frame.
  await page.goto(`${BASE}/admin/gateways`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-gateways-host-']");
  await page.screenshot({ path: `${outdir}/admin-gateways-table-${mode}.png`, fullPage: true });
  console.log(`table-${mode}`);

  await atWidths(page, `gateways-${mode}`, LIST_WIDTHS);

  // The narrow pair for the list.
  for (const width of [480, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await page.screenshot({
      path: `${outdir}/admin-gateways-table-${mode}-${width}.png`,
      fullPage: true,
    });
    console.log(`table-${mode}-${width}`);
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

  // The connected detail: facts, THE credential-references card, and
  // the org's domains in all five verification states.
  await page.goto(`${BASE}/admin/gateways/${gatewayDetail}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-secret-card']");
  await page.waitForSelector("[data-testid^='admin-gateways-domain-state-']");
  await page.screenshot({
    path: `${outdir}/admin-gateways-detail-${mode}.png`,
    fullPage: true,
  });
  console.log(`detail-${mode}`);

  await atWidths(page, `detail-${mode}`, DETAIL_WIDTHS);

  // The narrow pair for the detail.
  for (const width of [480, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await page.screenshot({
      path: `${outdir}/admin-gateways-detail-${mode}-${width}.png`,
      fullPage: true,
    });
    console.log(`detail-${mode}-${width}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // The non-connected detail: the reconnect copy and the credential
  // card side by side — where the trust copy matters most.
  await page.goto(`${BASE}/admin/gateways/${gatewayAttention}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-gateways-secret-card']");
  await page.screenshot({
    path: `${outdir}/admin-gateways-detail-attention-${mode}.png`,
    fullPage: true,
  });
  console.log(`detail-attention-${mode}`);

  // The domains-empty detail.
  await page.goto(`${BASE}/admin/gateways/${gatewayNoDomains}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-gateways-domains-empty']");
  await page.screenshot({
    path: `${outdir}/admin-gateways-detail-nodomains-${mode}.png`,
    fullPage: true,
  });
  console.log(`detail-nodomains-${mode}`);

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

// The gateway-less admin: the filter-scoped empty.
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
