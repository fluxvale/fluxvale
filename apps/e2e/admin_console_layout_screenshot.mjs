/* The console layout captures (#593, flush sidebar / maximized
 * content): every admin live surface — people, catalog, the sizes
 * ladder, both edit forms, the wallets list and wallet detail (#571),
 * feedback moderation (#592) — at the operator widths, light and dark.
 *
 * Before/after: the script is width- and surface-faithful, not
 * state-ful — run it on the base commit for the "before" set and on
 * the branch for the "after" set (the outdir arg keeps them apart).
 * The edit-form routes are scraped from the populated catalog pages
 * by testid, so the shots ride real seeded ids, never invented ones.
 *
 * Widths: 1920 (wide desktop), 1440 (desktop/laptop), 768 (the md
 * floor where the sidebar first sits beside the content), 480
 * (narrow — the sidebar stacks). Light+dark on the two primary
 * widths; light on the narrow pair (the responsive contract is
 * theme-invariant).
 *
 * The shell-capture contracts carry over from
 * admin_shell_screenshot.mjs: every shot waits on
 * [data-testid='admin-sidebar'] after goto (a 500 or a bounce can
 * never masquerade as evidence), the theme flip is the app toggle's
 * own localStorage key, and stills only — nothing here moves. Local
 * dev target only.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node admin_console_layout_screenshot.mjs <outdir>
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4111";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv593-console-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// One session POST mints the cookie the admin gate reads (the
// screenshot.mjs pattern). One context per width, both themes per
// context — the theme flips without a reload. The guard is
// redirect-aware: SessionController answers BOTH arms with a 302 —
// success to the return path, failure back to /sign-in — and
// Playwright follows redirects by default, so a plain ok() would
// read the bounced sign-in page's 200 as success (CodeRabbit, #596).
async function signedIn(width, height) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const session = await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
    maxRedirects: 0,
  });
  const location = session.headers()["location"] ?? "";
  if (session.status() !== 302 || location.includes("/sign-in")) {
    throw new Error(
      `sign-in POST did not mint a session (${session.status()} ${location}) — bad FV_TOKEN_ADMIN?`,
    );
  }
  return { ctx, page };
}

// The theme flip the toggle does; the root script owns the attrs.
async function setTheme(page, mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

// goto + the page-mounted assertion + theme, then the still. The
// sidebar wait is the anti-500 contract — see the header.
async function shot(page, name, path, mode, fullPage = true) {
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  await setTheme(page, mode);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage });
  console.log(`captured ${name}.png`);
}

// The edit forms and the wallet detail ride real ids scraped off
// the populated surfaces — the first Edit/wallet link's href on each
// parent page. An empty catalog fails loudly here (the shot loop
// below would otherwise navigate to "null" and time out on a sidebar
// that page can never render).
async function editPaths(page) {
  await page.goto(`${BASE}/admin/catalog`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  const versionHref = await page
    .locator("[data-testid^='admin-version-edit-']")
    .first()
    .getAttribute("href");

  await page.goto(`${BASE}/admin/catalog/sizes`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  const sizeHref = await page
    .locator("[data-testid^='admin-size-edit-']")
    .first()
    .getAttribute("href");

  await page.goto(`${BASE}/admin/billing`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  const walletHref = await page
    .locator("[data-testid^='admin-billing-org-link-']")
    .first()
    .getAttribute("href");

  for (const [name, href] of [
    ["version", versionHref],
    ["size", sizeHref],
    ["wallet detail", walletHref],
  ]) {
    if (!href) {
      throw new Error(`no ${name} link found — is the dev catalog/wallet data seeded?`);
    }
  }

  return { versionHref, sizeHref, walletHref };
}

// The scrape rides the first desktop context's page before its shots.
// The wallets surfaces (#571) and moderation (#592) join the set —
// they landed after the captures began, wired into the console lane
// in this PR's rebases.
const desktop = await signedIn(1440, 900);
const { versionHref, sizeHref, walletHref } = await editPaths(desktop.page);
console.log(`edit routes: ${versionHref} ${sizeHref} ${walletHref}`);

const surfaces = [
  ["people", "/admin/people"],
  ["catalog", "/admin/catalog"],
  ["sizes", "/admin/catalog/sizes"],
  ["version-edit", versionHref],
  ["size-edit", sizeHref],
  ["billing", "/admin/billing"],
  ["wallet-detail", walletHref],
  ["moderation", "/admin/moderation"],
];

for (const mode of ["light", "dark"]) {
  for (const [name, path] of surfaces) {
    await shot(desktop.page, `console-${name}-1440-${mode}`, path, mode);
  }
}
await desktop.ctx.close();

const wide = await signedIn(1920, 1080);
for (const mode of ["light", "dark"]) {
  for (const [name, path] of surfaces) {
    await shot(wide.page, `console-${name}-1920-${mode}`, path, mode);
  }
}
await wide.ctx.close();

// The narrow contract, light only: 768 is the md floor (sidebar
// beside content), 480 stacks them (the #568 responsive shape).
const w768 = await signedIn(768, 900);
await shot(w768.page, "console-people-768-light", "/admin/people", "light");
await w768.ctx.close();

const w480 = await signedIn(480, 900);
await shot(w480.page, "console-people-480-light", "/admin/people", "light");
await w480.ctx.close();

await browser.close();
console.log("done:", outdir);
