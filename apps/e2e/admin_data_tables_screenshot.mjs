/* Admin data-table gallery captures (#501). Two phases, driven by
 * FV_PHASE on the seed and this script:
 *
 *   empty   — the seed strips every invite, the script shoots the
 *             honest empty (both themes);
 *   gallery — the seeded 26-invitation state (page one full, page
 *             two one row), everything else.
 *
 * The gallery: the populated table under each sort state, a
 * query-param URL SHOWN IN FRAME (an injected address pill), the
 * page controls at both boundaries, the size switch, search active
 * and search-empty (with the clear lever), a withdraw confirm OPEN
 * inside the row grammar, an orgs-surface pair (a second adopting
 * surface), a keyboard-focus still, and the narrow widths where the
 * table scrolls INTERNALLY (the probes print scrollWidth vs
 * clientWidth and throw on page-level overflow at 1024+).
 *
 * The session POST is checked for a 2xx explicitly AND the session
 * is bounce-verified: a 200 also renders for a refused token, so the
 * admin page itself is the verifier (the failure names its cause).
 *
 *   FV_PHASE=empty  node admin_data_tables_screenshot.mjs <outdir>
 *   FV_PHASE=gallery node admin_data_tables_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-datatable-shots";
mkdirSync(outdir, { recursive: true });

const PHASE = process.env.FV_PHASE ?? "gallery";

const token = process.env.FV_TOKEN ?? "";
const tokenEmpty = process.env.FV_TOKEN_EMPTY ?? "";
const tokenSeeded = process.env.FV_TOKEN_SEEDED ?? "";
const walletId = process.env.FV_WALLET ?? "";
const orgId = process.env.FV_ORG ?? "";
const gatewayId = process.env.FV_GATEWAY ?? "";

const ids =
  PHASE === "empty"
    ? { token, tokenEmpty }
    : { token, tokenEmpty, tokenSeeded, walletId, orgId, gatewayId };
const missing = Object.entries(ids)
  .filter(([k, v]) => !v)
  .map(([k]) => k);

if (missing.length) {
  console.error(`missing env: ${missing.join(", ")} (see admin_data_tables_seed.exs)`);
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

// The width probe: every .wrap band, the console root, and the
// document. Prints the numbers; throws on page-level overflow at the
// claimed widths — the table itself is ALLOWED to scroll internally
// below its floor (the md-band posture), which is what the narrow
// shots are for.
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

const WIDTHS = [480, 768, 1024, 1280, 1440];

// An in-frame URL cue (finding 13): a fixed pill styled like an
// address bar, carrying the live href — the shareable-URL headline
// rides on the frame, not a caption.
async function injectUrlPill(page) {
  await page.evaluate(() => {
    const pill = document.createElement("div");
    pill.textContent = window.location.href;
    pill.setAttribute("data-capture-url", "");
    pill.style.cssText =
      "position:fixed;top:10px;left:50%;transform:translateX(-50%);z-index:9999;" +
      "background:#1f2937;color:#f9fafb;font:12px/1 ui-monospace,monospace;" +
      "padding:7px 16px;border-radius:999px;box-shadow:0 2px 10px rgba(0,0,0,.45)";
    document.body.appendChild(pill);
  });
}

// An in-frame URL cue (finding 13): a fixed pill styled like an
// address bar, carrying the live href — added per shot below.
const browser = await chromium.launch();

// A signed-in context via the sanctioned session POST, then the page.
// Two checks AT the failure point: the POST must answer 2xx AND the
// session must actually authenticate — a 200 from the controller also
// renders for a refused token (expired, deleted account, missing env
// export), which reads as success until a mystery /sign-in bounce
// three steps later. The admin page itself is the verifier.
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

  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });

  if (page.url().includes("/sign-in")) {
    throw new Error(
      "session POST answered 2xx but the session did not authenticate — " +
        "the admin page bounced to /sign-in. Is the seed's token minted " +
        "for an account that still exists (the seed reset may have " +
        "recreated the users), and did the env export reach this run?"
    );
  }

  return { ctx, page };
}

async function atWidths(page, label) {
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await probeWidth(page, `${label}-${width}`, width >= 1024);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

for (const mode of ["light", "dark"]) {
  if (PHASE !== "gallery") break;

  const { ctx, page } = await newSession(token);

  // The default view: bare URL, newest first, a full first page.
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-people-email-']");
  await page.screenshot({
    path: `${outdir}/datatable-default-${mode}.png`,
    fullPage: true,
  });
  console.log(`default-${mode}`);

  if (PHASE === "gallery") {
    // A withdraw confirm OPEN inside the component's row grammar
    // (finding 14): the action and its consequence share one block.
    await page.click("[data-testid^='admin-people-withdraw-']");
    await page.waitForSelector("[data-testid='destructive-confirm']");
    await page.screenshot({
      path: `${outdir}/datatable-confirm-open-${mode}.png`,
      fullPage: true,
    });
    console.log(`confirm-open-${mode}`);
    await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid^='admin-people-email-']");
  }

  // The URL states the view: sorted ascending, size 50 — reloading
  // lands exactly here, and the injected pill shows the URL in frame
  // (finding 13).
  await page.goto(`${BASE}/admin/people?sort=invited_at&dir=asc&size=50`, {
    waitUntil: "networkidle",
  });
  await page.waitForSelector("[data-testid^='admin-people-email-']");
  await injectUrlPill(page);
  await page.screenshot({
    path: `${outdir}/datatable-param-view-${mode}.png`,
    fullPage: true,
  });
  console.log(`param-view-${mode}`);

  // Sort states: descending (the header carries the direction) — the
  // pair with the ascending shot above is the sort vocabulary.
  await page.goto(`${BASE}/admin/people?sort=invited_at&dir=desc`, {
    waitUntil: "networkidle",
  });
  await page.waitForSelector("[data-testid='admin-people-table-header-invited']");
  await page.screenshot({
    path: `${outdir}/datatable-sorted-desc-${mode}.png`,
    fullPage: true,
  });
  console.log(`sorted-desc-${mode}`);

  // Back to the default view for the boundary and size shots.
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-people-email-']");

  // Page boundary one: a full first page, Next armed, Prev resting.
  await page.screenshot({
    path: `${outdir}/datatable-page1-${mode}.png`,
    fullPage: true,
  });
  console.log(`page1-${mode}`);

  await page.click("[data-testid='admin-people-table-page-next']");
  await page.waitForTimeout(600);

  // Page boundary two: the last page (one row), Next retired, Prev
  // armed. The URL is the ?page=2 form the pagination pushed — the
  // pill shows it in frame.
  await injectUrlPill(page);
  await page.screenshot({
    path: `${outdir}/datatable-page2-${mode}.png`,
    fullPage: true,
  });
  console.log(`page2-${mode}`);

  // The size switch: 50 folds the two pages into one.
  await page.click("[data-testid='admin-people-table-size-50']");
  await page.waitForTimeout(600);
  await injectUrlPill(page);
  await page.screenshot({
    path: `${outdir}/datatable-size-50-${mode}.png`,
    fullPage: true,
  });
  console.log(`size-50-${mode}`);

  // Search active: the term rides the URL and the list narrows.
  await page.goto(`${BASE}/admin/people?q=datatable-capture-invite-0`, {
    waitUntil: "networkidle",
  });
  await page.waitForSelector("[data-testid^='admin-people-email-']");
  await injectUrlPill(page);
  await page.screenshot({
    path: `${outdir}/datatable-search-${mode}.png`,
    fullPage: true,
  });
  console.log(`search-${mode}`);

  // Search-empty: the honest no-match state with its clear lever.
  await page.goto(`${BASE}/admin/people?q=zzz-no-such-invite`, {
    waitUntil: "networkidle",
  });
  await page.waitForSelector("[data-testid='admin-people-search-empty']");
  await page.screenshot({
    path: `${outdir}/datatable-search-empty-${mode}.png`,
    fullPage: true,
  });
  console.log(`search-empty-${mode}`);

  // A second adopting surface (finding 14): the orgs table, same
  // component, different columns and grammar.
  await page.goto(`${BASE}/admin/orgs`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid^='admin-orgs-org-']");
  await page.screenshot({
    path: `${outdir}/datatable-orgs-${mode}.png`,
    fullPage: true,
  });
  console.log(`orgs-${mode}`);

  // Width probes on the populated table (the floor posture at every
  // claimed width), then the narrow pair with the internal scroll.
  await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(page, mode);
  await page.waitForSelector("[data-testid^='admin-people-email-']");
  await atWidths(page, `people-${mode}`);

  for (const width of [480, 768]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(400);
    await page.screenshot({
      path: `${outdir}/datatable-narrow-${mode}-${width}.png`,
      fullPage: true,
    });
    console.log(`narrow-${mode}-${width}`);
  }
  await page.setViewportSize({ width: 1440, height: 900 });

  // The keyboard-focus still (finding 15): one Tab sets keyboard
  // modality, then the programmatic focus lands the focus-visible
  // ring on the Invited sort header.
  await page.keyboard.press("Tab");
  await page.evaluate(() => {
    document.querySelector("[data-testid='admin-people-table-sort-invited_at']").focus();
  });
  await page.waitForTimeout(300);
  await page.screenshot({
    path: `${outdir}/datatable-focus-${mode}.png`,
    fullPage: false,
    clip: { x: 0, y: 60, width: 1440, height: 620 },
  });
  console.log(`focus-${mode}`);

  await ctx.close();
}

if (PHASE === "empty") {
  // The honest empty: the invites are stripped from the state, so
  // EVERY admin sees the empty list.
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession(tokenEmpty);
    await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
    await setTheme(page, mode);
    await page.waitForSelector("[data-testid='admin-people-list'] p");
    await page.screenshot({
      path: `${outdir}/datatable-empty-${mode}.png`,
      fullPage: true,
    });
    console.log(`empty-${mode}`);
    await ctx.close();
  }
}

// The per-surface width probes (#501 adoption): every adopting
// surface's populated table, both themes, all five widths, numbers
// printed. The seeded admin's reads render rows on each (the gateway
// and instance reads are member-scoped; the wallet read rides the
// platform-admin arm). Empty surfaces would be a false green — a
// dangling-header probe proves nothing — hence the seeded state.
const PROBE_SURFACES = [
  { label: "people", url: `${BASE}/admin/people`, row: "[data-testid^='admin-people-email-']" },
  { label: "billing", url: `${BASE}/admin/billing`, row: "[data-testid^='admin-billing-org-']" },
  {
    label: "moderation",
    url: `${BASE}/admin/moderation`,
    row: "[data-testid^='admin-moderation-title-']",
  },
  { label: "orgs", url: `${BASE}/admin/orgs`, row: "[data-testid^='admin-orgs-org-']" },
  {
    label: "gateways",
    url: `${BASE}/admin/gateways`,
    row: "[data-testid^='admin-gateways-host-']",
  },
  {
    label: "gateway-detail",
    url: `${BASE}/admin/gateways/${gatewayId}`,
    row: "[data-testid^='admin-gateways-domain-name-']",
  },
  {
    label: "org-detail",
    url: `${BASE}/admin/orgs/${orgId}`,
    row: "[data-testid^='admin-orgs-instance-'], [data-testid='admin-orgs-instances-empty']",
  },
  {
    label: "wallet-detail",
    url: `${BASE}/admin/billing/wallets/${walletId}`,
    row: "[data-testid^='admin-wallet-entry-'], [data-testid='admin-wallet-ledger-empty']",
  },
];

for (const mode of ["light", "dark"]) {
  if (PHASE !== "gallery") break;

  const { ctx, page } = await newSession(tokenSeeded);

  for (const surface of PROBE_SURFACES) {
    await page.goto(surface.url, { waitUntil: "networkidle" });
    await setTheme(page, mode);
    await page.waitForSelector(surface.row, { timeout: 10_000 });
    await atWidths(page, `${surface.label}-${mode}`);
  }

  await ctx.close();
}

// The sort GIF (#554 discipline): sorting IS motion. Cookie-carried
// context (no sign-in frame — the page is the first frame), a visible
// cursor dot riding the pointer to the header, two presses (ascending,
// then descending held), distinct dates in the sorted column from the
// seed, 1:1 crop keeping the H1 and the Invited column whole, and a
// two-pass palette so the dithering stays clean.
if (PHASE === "gallery") {
  const carrier = await newSession(token);
  const cookies = await carrier.ctx.cookies();
  await carrier.ctx.close();

  const gifCtx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: outdir, size: { width: 1440, height: 900 } },
  });
  await gifCtx.addCookies(cookies);
  const gifPage = await gifCtx.newPage();
  await gifPage.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
  await setTheme(gifPage, "light");
  await gifPage.waitForSelector("[data-testid^='admin-people-email-']");
  await gifPage.waitForTimeout(1200);

  // A cursor dot that rides the click: measured onto the header
  // button, pressed with a scale pulse, so the press is ON FILM.
  const box = await gifPage.locator("[data-testid='admin-people-table-sort-invited_at']").boundingBox();

  await gifPage.evaluate(({ x, y }) => {
    const dot = document.createElement("div");
    dot.setAttribute("data-capture-cursor", "");
    dot.style.cssText =
      `position:fixed;left:${x + 24}px;top:${y + 12}px;width:26px;height:26px;` +
      "border-radius:999px;background:rgba(239,68,68,.85);border:2px solid #fff;" +
      "z-index:10000;transform:translate(-50%,-50%);transition:transform 120ms ease-out;" +
      "box-shadow:0 1px 6px rgba(0,0,0,.4);pointer-events:none";
    document.body.appendChild(dot);
  }, { x: box.x, y: box.y });

  const press = () =>
    gifPage.evaluate(() => {
      const dot = document.querySelector("[data-capture-cursor]");
      dot.style.transform = "translate(-50%,-50%) scale(1.5)";
      setTimeout(() => {
        dot.style.transform = "translate(-50%,-50%) scale(1)";
      }, 160);
    });

  // The first press: Invited to ascending, held so the reorder reads.
  await press();
  await gifPage.click("[data-testid='admin-people-table-sort-invited_at']");
  await gifPage.waitForTimeout(1400);

  // The second press: descending, held.
  await press();
  await gifPage.click("[data-testid='admin-people-table-sort-invited_at']");
  await gifPage.waitForTimeout(1800);

  await gifCtx.close();
  console.log("sort-gif-webm");
}

await browser.close();
console.log("done");
