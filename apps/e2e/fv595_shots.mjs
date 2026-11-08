/* The resource console's captures (#595 slice 1): the domain picker
 * landing, the Ops domain page, both index tables, and one record
 * show page — light and dark, the app theme toggle both ways (the
 * admin_shell pattern). Every shot waits on the page's own testid
 * after its goto: a bounce or a 500 can never masquerade as evidence.
 * The show page rides the first flag row's View link, read from the
 * DOM — the screenshot.mjs instance-row pattern, no hardcoded ids.
 *
 * Stills only — the read surface ships no motion.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node fv595_shots.mjs <outdir>
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 * Rows: mix run ../e2e/fv595_seed.exs first (idempotent).
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4111";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv595-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// One session POST mints the cookie the admin gate reads. The
// controller answers a rejected token with a redirect, not a status —
// check where the POST landed and fail fast instead of timing out on
// the first selector.
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const signIn = await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});
if (signIn.url().includes("/sign-in")) {
  console.error("sign-in failed — check FV_TOKEN_ADMIN");
  process.exit(1);
}

async function setTheme(mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

async function shot(name, path, mode, waitOn) {
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.waitForSelector(waitOn);
  await setTheme(mode);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`captured ${name}.png`);
}

for (const mode of ["light", "dark"]) {
  await shot(`resources-domains-${mode}`, "/admin/resources", mode,
    "[data-testid='admin-resources-domains']");
  await shot(`resources-ops-domain-${mode}`, "/admin/resources/ops", mode,
    "[data-testid='admin-resources-domain']");
  // The index container always renders (the table itself only with
  // rows) — waiting on it lets the row check below give its real
  // message instead of a selector timeout.
  await shot(`resources-flags-${mode}`, "/admin/resources/ops/feature_flag", mode,
    "[data-testid='admin-resource-index']");
  await shot(`resources-rules-${mode}`, "/admin/resources/ops/access_rule", mode,
    "[data-testid='admin-resource-index']");
}

// The show page: the first flag row's View link, read from the DOM.
await page.goto(`${BASE}/admin/resources/ops/feature_flag`, { waitUntil: "networkidle" });
await page.waitForSelector("[data-testid='admin-resource-index']");
const href = await page.evaluate(() => {
  const row = document.querySelector("[data-testid^='admin-resource-view-']");
  return row ? row.getAttribute("href") : null;
});

if (href) {
  for (const mode of ["light", "dark"]) {
    await shot(`resources-show-${mode}`, href, mode,
      "[data-testid='admin-resource-show']");
  }
} else {
  console.error("no flag rows — run mix run ../e2e/fv595_seed.exs first");
  process.exit(1);
}

await ctx.close();
await browser.close();
console.log("done");
