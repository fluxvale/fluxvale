// Member-lifecycle captures (slice 5 of #408): the Members tab's new
// affordances — owner view (role controls, Remove, Leave, invite
// surface) and member view (roster + Leave only), light + dark.
// FV_BASE, OWNER_TOKEN, MEMBER_TOKEN, ORG_PATH envs.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4100";
const outdir = process.argv[2] ?? "/tmp/opencode/fv329-members-shots";
mkdirSync(outdir, { recursive: true });

const ORG_PATH = process.env.ORG_PATH;

if (!ORG_PATH || !process.env.OWNER_TOKEN || !process.env.MEMBER_TOKEN) {
  console.error("ORG_PATH, OWNER_TOKEN and MEMBER_TOKEN are required");
  process.exit(1);
}

const browser = await chromium.launch();
const viewport = { width: 1440, height: 900 };

// sessionFor: establish a session through the real endpoint (the POST
// the sign-in flow makes), reusing the cookie jar per actor.
async function sessionFor(token) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const session = await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });

  // Fail fast: a bad token or CSRF answer would otherwise capture the
  // sign-in page and still print "captured ...png".
  if (!session.ok()) {
    console.error(
      `session setup failed (POST /auth/session -> ${session.status()}) — refusing to capture the wrong page`,
    );
    process.exit(1);
  }
  return { ctx, page };
}

const owner = await sessionFor(process.env.OWNER_TOKEN);
const member = await sessionFor(process.env.MEMBER_TOKEN);

const shots = [
  [owner.page, "members-owner", ORG_PATH],
  [member.page, "members-member", ORG_PATH],
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
