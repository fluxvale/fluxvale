/* The paid-once gate's panel screenshots: the two blocked surfaces the
 * paid-wallet gate adds copy to — (a) the empty state's paid-gate
 * callout (a never-paid org holding only its welcome credit) and (b)
 * the suspended panel's top-up line (resume would be Forbidden). Light
 * AND dark for both. Local dev target only.
 *
 * Usage: FV_BASE=http://127.0.0.1:4101 FV_TOKEN_A=<jwt> FV_TOKEN_B=<jwt> \
 *   node paid_gate_screenshot.mjs <outdir>
 * Tokens: mint both with the sibling `paid_gate_seed.exs` (a dev
 * `mix run` one-off — creates the two never-paid users and seeds the
 * :suspended gateway row), then export them here.
 * Token A: never-paid user, NO gateway (the empty state). Token B:
 * never-paid user WITH a seeded :suspended gateway row (dev-only data —
 * the create action needs the provider, which no dev cluster runs).
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4101";
const TOKEN_A = process.env.FV_TOKEN_A;
const TOKEN_B = process.env.FV_TOKEN_B;
const outdir = process.argv[2] ?? "/tmp/opencode/fv305-shots";

if (!TOKEN_A || !TOKEN_B) {
  console.error("FV_TOKEN_A and FV_TOKEN_B required (see the seed script)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

// One signed-in context per user — the session POST mints the cookie
// the panel reads (the screenshot.mjs pattern).
async function signInContext(token) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

const emptyState = await signInContext(TOKEN_A);
const suspended = await signInContext(TOKEN_B);

const shots = [
  ["paid-gate-empty-state", "/settings/access", emptyState.page],
  ["paid-gate-suspended", "/settings/access", suspended.page],
];

for (const mode of ["light", "dark"]) {
  for (const [name, path, page] of shots) {
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    // Flip the theme the way the toggle does; the root script owns the attrs.
    await page.evaluate((m) => {
      localStorage.setItem("phx:theme", m);
      document.documentElement.setAttribute("data-theme", m);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, mode);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}

await emptyState.ctx.close();
await suspended.ctx.close();
await browser.close();
console.log("done:", outdir);
