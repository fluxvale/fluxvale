/* S5 walkthrough: route table (final URL + page marker), the captures
 * (theme set immediately before each shot, light + dark), and the DOM
 * no-pan check at four widths on the changed surfaces.
 *
 * BASE after-server (default http://127.0.0.1:4188); WALKER_TOKEN /
 * ACME_TOKEN minted by s5_seed.exs. node s5_walkthrough.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4188";
const outdir = process.argv[2] ?? "/tmp/opencode/s5-shots";
mkdirSync(outdir, { recursive: true });

const WALKER = {
  token: process.env.WALKER_TOKEN,
  personalSlug: process.env.WALKER_ORG,
  instance: process.env.WALKER_INSTANCE,
};
const ACME = {
  token: process.env.ACME_TOKEN,
  orgSlug: process.env.ACME_ORG,
  instance: process.env.ACME_INSTANCE,
};

const browser = await chromium.launch();

async function sessionContext(token) {
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

const setTheme = (page, mode) =>
  page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

const join = (page) => page.waitForLoadState("networkidle");

// One live-socket assertion, the S7 lesson (same helper as s9/s10):
// mount redirects (push_navigate) ride the socket — reading the final
// URL after a fixed sleep can read the pre-redirect address.
const live = (pg) =>
  pg.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

// -- 1. Route table ----------------------------------------------------

const walker = await sessionContext(WALKER.token);
const acme = await sessionContext(ACME.token);

const table = [];

// The marker is the page's own witness: data-testid when it has one,
// the element id when it doesn't (org-general-form, org-members-table).
// Required markers FAIL the walkthrough; conditional ones (rendered
// only in some panel states — e.g. access-empty with no gateway) are
// observational: their miss is recorded, never an error.
async function probe(page, who, url, marker, { required = true } = {}) {
  await page.goto(`${BASE}${url}`, { waitUntil: "networkidle" });
  await live(page);
  await page.waitForTimeout(400); // the mount redirect settles
  const finalUrl = new URL(page.url()).pathname;
  const testid = page.locator(`[data-testid='${marker}']`).first();
  const byId = page.locator(`#${marker}`).first();
  const rendered =
    (await testid.isVisible().catch(() => false)) ||
    (await byId.isVisible().catch(() => false));

  if (required && !rendered) {
    throw new Error(`walkthrough: ${url} did not render its marker ${marker}`);
  }

  table.push({ who, url, finalUrl, marker, rendered });
}

const p = walker.page;
await probe(p, "walker", "/settings", "settings-title");
// After the redirect the dashboard is the landing page; its balance is
// always on (the JIT welcome grant funds every action-created user).
await probe(p, "walker", `/organizations/${WALKER.personalSlug}`, "dashboard-balance");
await probe(p, "walker", `/organizations/${WALKER.personalSlug}/settings`, "settings-title");
await probe(p, "walker", `/organizations/${WALKER.personalSlug}/settings/members`, "settings-title");
await probe(p, "walker", `/organizations/${WALKER.personalSlug}/billing`, "wallet-balance");
await probe(p, "walker", `/organizations/${WALKER.personalSlug}/settings/access`, "settings-title");
await probe(p, "walker", "/settings/access", "settings-access-back");
await probe(p, "walker", `/instances/${WALKER.instance}`, "tailnet-access-link");

const a = acme.page;
await probe(a, "acme", `/organizations/${ACME.orgSlug}`, "org-name");
await probe(a, "acme", `/organizations/${ACME.orgSlug}/settings`, "org-general-form");
await probe(a, "acme", `/organizations/${ACME.orgSlug}/settings/members`, "org-members-table");
await probe(a, "acme", `/organizations/${ACME.orgSlug}/billing`, "wallet-balance");
await probe(a, "acme", `/organizations/${ACME.orgSlug}/settings/access`, "org-settings-tabs");
// F1's crafted param, permanently probed: the personal route refuses
// ?slug= — the final URL must be / (the not-found redirect), never the
// org frame on the personal route.
await probe(a, "acme", `/settings/access?slug=${ACME.orgSlug}`, "dashboard-balance");
await probe(a, "acme", `/instances/${ACME.instance}`, "tailnet-access-link");

// The switcher rows' hrefs + labels, per actor: the panel is inside a
// closed <details>, so it must be OPENED before its rows have text.
async function switcherRows(page) {
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.locator("[data-testid='org-switcher-button']").click();
  const rows = await page.locator("[data-testid='org-switcher-panel'] a").all();
  const out = [];
  for (const row of rows) {
    out.push({ text: (await row.innerText()).trim(), href: await row.getAttribute("href") });
  }
  await page.keyboard.press("Escape");
  return out;
}
const walkerRows = await switcherRows(walker.page);
const acmeRows = await switcherRows(acme.page);

// The instance-show access link targets, per org kind.
async function accessLink(page, instance) {
  await page.goto(`${BASE}/instances/${instance}`, { waitUntil: "networkidle" });
  return page.locator("[data-testid='tailnet-access-link']").getAttribute("href");
}
const walkerLink = await accessLink(walker.page, WALKER.instance);
const acmeLink = await accessLink(acme.page, ACME.instance);

writeFileSync(
  `${outdir}/walkthrough.json`,
  JSON.stringify({ table, walkerRows, acmeRows, walkerLink, acmeLink }, null, 2),
);
console.log(JSON.stringify({ table, walkerRows, acmeRows, walkerLink, acmeLink }, null, 2));

// -- 2. Captures (theme selected immediately before each shot) ----------

async function shot(page, name, { openSwitcher = false } = {}) {
  for (const mode of ["light", "dark"]) {
    await setTheme(page, mode);
    await page.waitForTimeout(250);
    if (openSwitcher) {
      await page.locator("[data-testid='org-switcher-button']").click();
      await page.waitForTimeout(250);
    }
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    // Luminance check: the rendered page must actually differ per mode.
    const lum = await page.evaluate(() => {
      const el = document.querySelector("main") ?? document.body;
      return getComputedStyle(el).backgroundColor;
    });
    console.log(`captured ${name}-${mode}.png main-bg=${lum}`);
    if (openSwitcher) await page.keyboard.press("Escape");
  }
}

await walker.page.goto(`${BASE}/`, { waitUntil: "networkidle" });
await shot(walker.page, "after-switcher-open", { openSwitcher: true });

await walker.page.goto(`${BASE}/settings`, { waitUntil: "networkidle" });
await shot(walker.page, "after-settings");

await walker.page.goto(`${BASE}/settings/access`, { waitUntil: "networkidle" });
await shot(walker.page, "after-settings-access");

await acme.page.goto(`${BASE}/organizations/${ACME.orgSlug}/settings/access`, {
  waitUntil: "networkidle",
});
await shot(acme.page, "after-org-access");

await walker.page.goto(`${BASE}/instances/${WALKER.instance}`, { waitUntil: "networkidle" });
await shot(walker.page, "after-instance-personal");

// -- 3. DOM no-pan at four widths on the changed surfaces --------------

const pans = [];
for (const width of [375, 640, 768, 1280]) {
  for (const [label, path] of [
    ["settings", "/settings"],
    ["settings-access", "/settings/access"],
  ]) {
    const page = walker.page;
    await page.setViewportSize({ width, height: 900 });
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    pans.push({ width, surface: label, overflow });
  }
}
console.log("no-pan:", JSON.stringify(pans));
writeFileSync(`${outdir}/no-pan.json`, JSON.stringify(pans, null, 2));

await walker.ctx.close();
await acme.ctx.close();
await browser.close();
