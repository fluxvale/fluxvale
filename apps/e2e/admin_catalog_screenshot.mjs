/* The admin catalog surgery surface's captures (#501 slice C): the
 * catalog list, the size ladder, a size edit with the freeze lock
 * visible, and a version edit with the coherence copy — in both app
 * theme modes. The surfaces ride the app chrome, so the light/dark
 * split is the app theme toggle (localStorage phx:theme), not
 * prefers-color-scheme. Local dev target only.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node admin_catalog_screenshot.mjs <outdir>
 * Token: mint with a dev `mix run` one-off against the seeded DB —
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
// gate reads (the admin_shell_screenshot.mjs pattern).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

const shoot = async (name, fn) => {
  for (const mode of ["light", "dark"]) {
    await fn();
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
};

// 1. The home with the flipped catalog card.
await shoot("admin-home", async () => {
  await page.goto(`${BASE}/admin`, { waitUntil: "networkidle" });
});

// 2. The catalog surgery list.
await shoot("admin-catalog", async () => {
  await page.goto(`${BASE}/admin/catalog`, { waitUntil: "networkidle" });
});

// 3. The size ladder.
await shoot("admin-sizes", async () => {
  await page.goto(`${BASE}/admin/catalog/sizes`, { waitUntil: "networkidle" });
});

// 4. A size edit with the freeze lock visible (a referenced size).
const sizeHref = await page
  .locator("[data-testid='admin-size-edit-small']")
  .getAttribute("href");
await shoot("admin-size-locked", async () => {
  await page.goto(`${BASE}${sizeHref}`, { waitUntil: "networkidle" });
});

// 5. A version edit with the coherence copy: a drift edit shows the
// pre-submit mismatch before any save.
await page.goto(`${BASE}/admin/catalog`, { waitUntil: "networkidle" });
const versionHref = await page
  .locator("[data-testid^='admin-version-edit-']")
  .first()
  .getAttribute("href");
await shoot("admin-version-mismatch", async () => {
  await page.goto(`${BASE}${versionHref}`, { waitUntil: "networkidle" });
  await page.locator("[data-testid='admin-version-memory']").fill("4096");
  // The change event rides LiveView's phx-change; wait for the callout.
  await page
    .locator("[data-testid='admin-version-coherence-mismatch']")
    .waitFor({ state: "visible", timeout: 5000 });
});

await browser.close();
console.log("done:", outdir);
