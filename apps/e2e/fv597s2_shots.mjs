// The PocketID custody-card screenshots (#597 S2, the owner's
// screenshot convention): the intake card (no custody yet), the
// verified card (staged custody row — a Secret NAME only, no key
// anywhere), and the replace-open state — light and dark each.
//
// Authenticated pages ride a minted dev session (fv597s2_seed.exs
// posture); local dev target only. FV_TOKEN, FV_VERIFIED, FV_FRESH
// (instance ids) required.
//
// No secret is ever captured: the intake field is a password input,
// and nothing is ever typed into it.
//
// Usage (after `mix run ../e2e/fv597s2_seed.exs`):
//   FV_TOKEN=<jwt> FV_VERIFIED=<id> FV_FRESH=<id> node fv597s2_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const verifiedId = process.env.FV_VERIFIED ?? "";
const freshId = process.env.FV_FRESH ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv597s2-shots";
mkdirSync(outdir, { recursive: true });

if (!token || !verifiedId || !freshId) {
  console.error("FV_TOKEN, FV_VERIFIED and FV_FRESH are all required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });

// Session: POST /auth/session (the sign-in flow's own write). Fail
// fast on a rejected token (the fv492 stance).
const page = await ctx.newPage();
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

const capture = async (name, path, theme, act) => {
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  if (act) await act();
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, theme);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}-${theme}.png`, fullPage: true });
  console.log(`captured ${name}-${theme}.png`);
};

for (const mode of ["light", "dark"]) {
  await capture("pocketid-custody-intake", `/instances/${freshId}`, mode);
  await capture("pocketid-custody-verified", `/instances/${verifiedId}`, mode);
  // The replace-open state: the real button, pure LiveView state.
  await capture(
    "pocketid-custody-replace",
    `/instances/${verifiedId}`,
    mode,
    async () => {
      await page.getByTestId("pocketid-replace-toggle").click();
      await page.locator("#pocketid-key-form").waitFor({ state: "visible" });
    }
  );
}

await browser.close();
console.log("done");
