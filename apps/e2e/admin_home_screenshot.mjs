/* The admin console's capture (ADR-0027 Am. 3, #501): the /admin home
 * — the operator console's surface map — in both app theme modes. The
 * home rides the app chrome, so its light/dark split is the app theme
 * toggle (localStorage phx:theme), not prefers-color-scheme.
 * Local dev target only.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node admin_home_screenshot.mjs <outdir>
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4111";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-admin-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// One signed-in context — the session POST mints the cookie the admin
// gate reads (the screenshot.mjs pattern).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/admin`, { waitUntil: "networkidle" });
  // Flip the theme the way the toggle does; the root script owns the attrs.
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/admin-home-${mode}.png`, fullPage: true });
  console.log(`captured admin-home-${mode}.png`);
}

await browser.close();
console.log("done:", outdir);
