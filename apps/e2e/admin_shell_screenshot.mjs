/* The admin shell's captures (ADR-0027 Am. 4, #501): the section
 * sidebar beside the live surfaces, POPULATED — the people list rides
 * its four invitation states, the catalog its real seeded apps. Light
 * and dark for the two sections, the sizes ladder as the sub-page
 * showing the active-state persistence (both themes), the sidebar
 * element itself with the Coming entries and the deep debugging
 * group, the narrow shape (below md the sidebar stacks above the
 * content — the #568 idiom's responsive contract), and the 768/900
 * widths the band beside the nav actually lives at.
 *
 * Every shot waits on [data-testid='admin-sidebar'] after its goto:
 * a 500 or a bounce can never masquerade as evidence (the catalog
 * 500-lesson from the first review round).
 *
 * The shell rides the app chrome, so the light/dark split is the app
 * theme toggle (localStorage phx:theme), not prefers-color-scheme.
 * Stills only — nothing here moves. Local dev target only.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node admin_shell_screenshot.mjs <outdir>
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4111";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-shell-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// One session POST mints the cookie the admin gate reads (the
// screenshot.mjs pattern). One context per width, both themes per
// context — the theme flips without a reload.
async function signedIn(width, height) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
  });
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

// Desktop: the populated sections in both themes, plus the widths the
// band beside the nav lives at (768 is the md floor, 900 the mid-band).
const desktop = await signedIn(1440, 900);
const page = desktop.page;

for (const mode of ["light", "dark"]) {
  await shot(page, `admin-people-${mode}`, "/admin/people", mode);
  await shot(page, `admin-catalog-${mode}`, "/admin/catalog", mode);
  await shot(page, `admin-catalog-sizes-${mode}`, "/admin/catalog/sizes", mode);
}

// The sidebar element itself, cropped: the Coming entries (inline
// badges) and the deep debugging group up close.
await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
await page.waitForSelector("[data-testid='admin-sidebar']");
await setTheme(page, "light");
await page.locator("[data-testid='admin-sidebar']").screenshot({
  path: `${outdir}/admin-sidebar-coming-light.png`,
});
console.log("captured admin-sidebar-coming-light.png");
await desktop.ctx.close();

// The band widths: the populated people list beside the nav at the md
// floor and mid-band (no horizontal scroll expected at either).
const w768 = await signedIn(768, 900);
await shot(w768.page, "admin-people-768-light", "/admin/people", "light");
await w768.ctx.close();

const w900 = await signedIn(900, 900);
await shot(w900.page, "admin-people-band-900-light", "/admin/people", "light");
await w900.ctx.close();

// The narrow shape: below md the sidebar stacks above the content
// (the #568 responsive contract, with the debug copy hidden there).
const narrow = await signedIn(480, 900);
await shot(narrow.page, "admin-narrow-light", "/admin/people", "light");
await narrow.ctx.close();

await browser.close();
console.log("done:", outdir);
