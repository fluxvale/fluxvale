// Invite-surface captures (slice 4 of #408): the Members tab invite
// form + pending queue (owner session) and the /invitations/accept
// landing in its matched state (invitee session), light + dark.
// FV_BASE, OWNER_TOKEN, INVITEE_TOKEN, ACCEPT_PATH, ORG_PATH envs.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4100";
const outdir = process.argv[2] ?? "/tmp/opencode/fv329-shots";
mkdirSync(outdir, { recursive: true });

const ORG_PATH = process.env.ORG_PATH ?? "/organizations/northwind-labs/settings/members";
const ACCEPT_PATH = process.env.ACCEPT_PATH ?? "/invitations/accept?token=fv329-screenshot-token-material";

const browser = await chromium.launch();
const viewport = { width: 1440, height: 900 };

// sessionFor: establish a session through the real endpoint (the POST
// the sign-in flow makes), reusing the cookie jar per actor.
async function sessionFor(token) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

const owner = await sessionFor(process.env.OWNER_TOKEN);
const invitee = await sessionFor(process.env.INVITEE_TOKEN);

const shots = [
  [owner.page, "members-invite-form", ORG_PATH],
  [invitee.page, "accept-matched", ACCEPT_PATH],
];

for (const mode of ["light", "dark"]) {
  for (const [page, name, path] of shots) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    // Flip the theme the way the toggle does; the root script owns the attrs.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await browser.close();
