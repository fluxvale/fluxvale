/* Cross-org console captures (#644 A1-S2, the doctrine's first
 * surface): the gateways index with #613's attention clock and the
 * stranger org's row, the gateway detail with the key-age stamp and
 * tailnet claims, the org detail with its domains card (member org
 * AND stranger org — the rows the gateway-scoped view could not
 * answer for), and the people list. Light + dark from ONE seeded
 * state (admin_crossorg_seed.exs), stills only — no motion ships.
 *
 *   FV_TOKEN=… FV_GATEWAY_DETAIL=… FV_GATEWAY_ATTENTION=… \
 *   FV_ORG_DETAIL=… FV_ORG_DETAIL_STRANGER=… \
 *   node admin_crossorg_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv644-a1s2-shots";
mkdirSync(outdir, { recursive: true });

const ids = {
  token: process.env.FV_TOKEN ?? "",
  gatewayDetail: process.env.FV_GATEWAY_DETAIL ?? "",
  gatewayAttention: process.env.FV_GATEWAY_ATTENTION ?? "",
  orgDetail: process.env.FV_ORG_DETAIL ?? "",
  orgDetailStranger: process.env.FV_ORG_DETAIL_STRANGER ?? "",
};
const missing = Object.entries(ids).filter(([k, v]) => !v).map(([k]) => k);
if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_crossorg_seed.exs)`);
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

// The gateways lane's width probe (every .wrap band + the console root
// + the document), informational here: the layouts are the lane's own,
// and the only new chrome is the clock under a badge and the domains
// card — both inside existing tracks.
async function probeWidth(page, label) {
  const numbers = await page.evaluate(() => {
    const wraps = [...document.querySelectorAll(".wrap")];
    const console_root = document.querySelector(".appgram.console");
    const doc = document.documentElement;
    return {
      bands: wraps.map((band, i) => `wrap${i}:${band.scrollWidth}==${band.clientWidth}`),
      console_root: console_root
        ? `console:${console_root.scrollWidth}==${console_root.clientWidth}`
        : "no-console",
      doc: `doc:${doc.scrollWidth}==${doc.clientWidth}`,
    };
  });
  const line = [...numbers.bands, numbers.console_root, numbers.doc].join(" ");
  console.log(`width[${label}] ${line}`);
}

const browser = await chromium.launch();

// A signed-in context via the sanctioned session POST.
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

for (const mode of ["light", "dark"]) {
  const { ctx, page } = await newSession(ids.token);

  // The gateways table: every org's gateways — the stranger org's row
  // is the cross-org pin on camera — with #613's attention clock under
  // the needs-attention badge.
  await page.goto(`${BASE}/admin/gateways`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-gateways-host-']");
  await page.waitForSelector("[data-testid^='admin-gateways-attention-since-']");
  await page.screenshot({ path: `${outdir}/admin-gateways-${mode}.png`, fullPage: true });
  console.log(`gateways-${mode}`);
  await probeWidth(page, `gateways-${mode}`);

  // The connected detail: the #613 facts (the key-age stamp with its
  // 90-day copy, the tailnet claims) beside the credential card.
  await page.goto(`${BASE}/admin/gateways/${ids.gatewayDetail}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-secret-card']");
  await page.waitForSelector("[data-testid='admin-gateways-claims-list']");
  await page.screenshot({ path: `${outdir}/admin-gateway-detail-${mode}.png`, fullPage: true });
  console.log(`gateway-detail-${mode}`);
  await probeWidth(page, `gateway-detail-${mode}`);

  // The attention detail: the clock as its own fact, under the state
  // and beside the reconnect message.
  await page.goto(`${BASE}/admin/gateways/${ids.gatewayAttention}`, {
    waitUntil: "networkidle",
  });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-gateways-detail-attention-since']");
  await page.screenshot({
    path: `${outdir}/admin-gateway-detail-attention-${mode}.png`,
    fullPage: true,
  });
  console.log(`gateway-detail-attention-${mode}`);

  // The member org detail: the strip, the instances table, and the
  // domains card (the minted platform row + a pending and a verified
  // custom row).
  await page.goto(`${BASE}/admin/orgs/${ids.orgDetail}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-orgs-detail-domains']");
  await page.waitForSelector("[data-testid^='admin-orgs-domain-name-']");
  await page.screenshot({ path: `${outdir}/admin-org-detail-${mode}.png`, fullPage: true });
  console.log(`org-detail-${mode}`);
  await probeWidth(page, `org-detail-${mode}`);

  // The stranger org detail: an org the admin does not belong to, its
  // instance and its minted platform domain on camera — #644's
  // done-when, the surface that used to answer "not a member of this
  // org".
  await page.goto(`${BASE}/admin/orgs/${ids.orgDetailStranger}`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid='admin-orgs-detail-domains']");
  await page.waitForSelector("[data-testid^='admin-orgs-domain-name-']");
  await page.screenshot({
    path: `${outdir}/admin-org-detail-stranger-${mode}.png`,
    fullPage: true,
  });
  console.log(`org-detail-stranger-${mode}`);

  // The people list: the invitation rows, one accepted by the owner of
  // a foreign org.
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-people-email-']");
  await page.screenshot({ path: `${outdir}/admin-people-${mode}.png`, fullPage: true });
  console.log(`people-${mode}`);

  await ctx.close();
}

await browser.close();
console.log("done");
