/* The PocketID SSO offer-card screenshots (#597 S3, the owner's
 * screenshot convention): the wizard's configuration step with the
 * card in every state — offer (unticked, D7) with the multi-PocketID
 * picker, offer ticked (manual inputs hidden), mid-setup,
 * unreachable, no-custody — and the plain form (an org without a
 * PocketID: nothing renders). Light and dark each, plus a short GIF
 * of the tick (the change is the hiding — motion).
 *
 * Local dev target only. The dev server must run with
 * INSTANCES_BASE_DOMAIN=127.0.0.1.nip.io:8443 and the ERL_FLAGS CA
 * bundle (the probe stub is /tmp/opencode/fv597s3_stub.py) — see the
 * PR body's capture-notes. FV_TOKEN from fv597s3_seed.exs.
 *
 * Usage:
 *   FV_TOKEN=<jwt> node fv597s3_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN;
const APP_SLUG = process.env.FV_APP_SLUG ?? "vaultwarden";
const outdir = process.argv[2] ?? "/tmp/opencode/fv597s3-shots";
mkdirSync(outdir, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required (see fv597s3_seed.exs)");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session: POST /auth/session (the sign-in flow's own write). Fail
// fast on a rejected token (the fv492 stance).
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const response = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
const bounced = new URL(response.url()).pathname === "/sign-in";
if (!response.ok() || bounced) {
  throw new Error(`Sign-in failed (status ${response.status()}); check FV_TOKEN`);
}

const setTheme = (mode) =>
  page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

// Enter the wizard's configuration step under `org` (the picker's
// visible name), returning after the step-2 card settles.
const toStep2 = async (org) => {
  await page.goto(`${BASE}/apps/${APP_SLUG}/deploy`, { waitUntil: "networkidle" });
  await page.locator("[data-testid=version-option]").first().waitFor();
  if (org) {
    await page.locator("#deploy-org").selectOption({ label: org });
    await page.waitForTimeout(200);
  }
  await page.locator("[data-testid=version-option]").first().click();
  await page.locator("button[phx-click='to-env']").click();
  await page.locator("#env-form, #pocketid-offer").first().waitFor();
};

const capture = async (name, theme) => {
  await setTheme(theme);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}-${theme}.png`, fullPage: true });
  console.log(`captured ${name}-${theme}.png`);
};

for (const mode of ["light", "dark"]) {
  // Personal org: the offer — unticked checkbox (D7), picker over the
  // two completed PocketIDs, manual SSO inputs visible below.
  await toStep2(null);
  await page.locator("#pocketid-offer-check").waitFor();
  await capture("pocketid-offer-unticked", mode);

  // The tick: exactly the recipe's SSO_* inputs vanish (the app's
  // other inputs stay — Vaultwarden's seed carries
  // SIGNUPS_DOMAINS_WHITELIST beside the SSO_* set).
  await page.locator("#pocketid-offer-check").click();
  await page.locator("#pocketid-offer-confirmed").waitFor();
  await page.locator("#env-SIGNUPS_DOMAINS_WHITELIST").waitFor();
  await capture("pocketid-offer-ticked", mode);
  await page.locator("#pocketid-offer-check").click();

  // The other three card states, each in its own org.
  await toStep2("Halfway Team");
  await page.locator("#pocketid-mid-setup").waitFor();
  await capture("pocketid-mid-setup", mode);

  await toStep2("Offline Team");
  await page.locator("#pocketid-unreachable").waitFor();
  await capture("pocketid-unreachable", mode);

  await toStep2("Fresh Team");
  await page.locator("#pocketid-no-custody").waitFor();
  await capture("pocketid-no-custody", mode);

  // An org with no PocketID: nothing renders — the plain form (the
  // before shape, SSO_* inputs all present).
  await toStep2("Empty Team");
  await page.locator("#env-SSO_AUTHORITY").waitFor();
  await capture("pocketid-none-plain-form", mode);
}

// The tick's motion (light): hiding the manual inputs is the change.
// Video recording is a context-level option, so this rides its own
// context (session reminted through the same endpoint).
const vctx = await browser.newContext({
  viewport: { width: 900, height: 950 },
  recordVideo: { dir: outdir, size: { width: 900, height: 950 } },
});
const vpage = await vctx.newPage();
await vpage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const vcsrf = await vpage.locator('meta[name="csrf-token"]').getAttribute("content");
await vpage.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": vcsrf },
});
await vpage.goto(`${BASE}/apps/${APP_SLUG}/deploy`, { waitUntil: "networkidle" });
await vpage.locator("[data-testid=version-option]").first().click();
await vpage.locator("button[phx-click='to-env']").click();
await vpage.locator("#pocketid-offer-check").waitFor();
await vpage.evaluate(() => {
  localStorage.setItem("phx:theme", "light");
  document.documentElement.setAttribute("data-theme", "light");
  document.documentElement.setAttribute("data-theme-source", "user");
});
await vpage.waitForTimeout(400);
await vpage.locator("#pocketid-offer-check").click();
await vpage.locator("#pocketid-offer-confirmed").waitFor();
await vpage.waitForTimeout(600);
const videoPath = await vpage.video().path();
await vctx.close();
console.log(`video at ${videoPath}`);

await browser.close();
console.log("done");

