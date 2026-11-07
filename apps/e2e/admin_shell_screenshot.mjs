/* The admin shell's captures (ADR-0027 Am. 4, #501): the section
 * sidebar beside the live surfaces — people (light + dark), catalog
 * (light + dark), the sizes ladder as a sub-page showing the
 * active-state persistence, the sidebar element itself with the
 * Coming entries and the deep debugging group, and the narrow-viewport
 * shape (the sidebar stacks above the content below md — the #568
 * idiom's responsive contract). The shell rides the app chrome, so
 * the light/dark split is the app theme toggle (localStorage
 * phx:theme), not prefers-color-scheme. Stills only — the #568
 * capture set was stills; nothing here moves. Local dev target only.
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
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// One signed-in context — the session POST mints the cookie the admin
// gate reads (the admin_home_screenshot.mjs pattern).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

// The theme flip the toggle does; the root script owns the attrs.
async function setTheme(mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

async function fullPage(name, url, mode) {
  await page.goto(url, { waitUntil: "networkidle" });
  await setTheme(mode);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`captured ${name}.png`);
}

// People in both themes — the shell with the live sections, the Coming
// entries, and the deep debugging group all in frame.
await fullPage("admin-people-light", `${BASE}/admin/people`, "light");
await fullPage("admin-people-dark", `${BASE}/admin/people`, "dark");

// Catalog in both themes; the sizes ladder is the sub-page proof that
// the catalog entry stays marked off its own route.
await fullPage("admin-catalog-light", `${BASE}/admin/catalog`, "light");
await fullPage("admin-catalog-dark", `${BASE}/admin/catalog`, "dark");
await fullPage("admin-catalog-sizes-light", `${BASE}/admin/catalog/sizes`, "light");

// The sidebar element itself, cropped: the Coming entries and the deep
// debugging group up close.
await page.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
await setTheme("light");
await page.locator("[data-testid='admin-sidebar']").screenshot({
  path: `${outdir}/admin-sidebar-coming-light.png`,
});
console.log("captured admin-sidebar-coming-light.png");

// The narrow shape: below md the sidebar stacks above the content
// (the #568 responsive contract).
const narrow = await browser.newContext({ viewport: { width: 480, height: 900 } });
const narrowPage = await narrow.newPage();
await narrowPage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const narrowCsrf = await narrowPage.locator('meta[name="csrf-token"]').getAttribute("content");
await narrowPage.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": narrowCsrf },
});
await narrowPage.goto(`${BASE}/admin/people`, { waitUntil: "networkidle" });
await narrowPage.evaluate((m) => {
  localStorage.setItem("phx:theme", m);
  document.documentElement.setAttribute("data-theme", m);
  document.documentElement.setAttribute("data-theme-source", "user");
}, "light");
await narrowPage.waitForTimeout(300);
await narrowPage.screenshot({ path: `${outdir}/admin-narrow-light.png`, fullPage: true });
console.log("captured admin-narrow-light.png");
await narrow.close();

await browser.close();
console.log("done:", outdir);
