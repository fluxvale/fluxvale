// #557 type-system visual gate: the six gate surfaces in both app
// themes, plus a narrow-viewport landing still (display-face boundary
// check). Local dev target (127.0.0.1:4000), session via the real
// sign-in POST (the screenshot.mjs pattern).
//
// Usage: FV_TOKEN_ADMIN=<jwt> FV_TOKEN_USER=<jwt> \
//   INSTANCE_PATH=/instances/<id> node fv557_type_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN_ADMIN = process.env.FV_TOKEN_ADMIN ?? "";
const TOKEN_USER = process.env.FV_TOKEN_USER ?? "";
const INSTANCE_PATH = process.env.INSTANCE_PATH ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv557-shots";
mkdirSync(outdir, { recursive: true });

if (!TOKEN_ADMIN || !TOKEN_USER || !INSTANCE_PATH) {
  console.error("FV_TOKEN_ADMIN, FV_TOKEN_USER and INSTANCE_PATH required");
  process.exit(1);
}

const browser = await chromium.launch();

async function signedIn(token, theme) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
}

// [name, path, token, waitFor]
const surfaces = [
  ["landing", "/about", null],
  ["pricing-calculator", "/pricing", null],
  ["deploy-stepper", "/apps/forgejo/deploy", TOKEN_USER],
  ["instance", INSTANCE_PATH, TOKEN_USER],
  ["admin-console", "/admin", TOKEN_ADMIN],
  ["settings", "/settings", TOKEN_USER],
];

for (const [name, path, token] of surfaces) {
  for (const theme of ["light", "dark"]) {
    const maker = token ? () => signedIn(token, theme) : null;
    let ctx, page;
    if (maker) {
      ({ ctx, page } = await maker());
    } else {
      ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
      await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
      page = await ctx.newPage();
    }
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await page.waitForTimeout(900);
    await page.screenshot({ path: `${outdir}/${name}-${theme}.png`, fullPage: false });
    console.log("captured", `${name}-${theme}.png`);
    await ctx.close();
  }
}

// Display boundary: the hero at a narrow viewport — Instrument Serif
// must still read as display type, never collapse into body text.
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), "light");
const page = await ctx.newPage();
await page.goto(`${BASE}/about`, { waitUntil: "networkidle" });
await page.waitForTimeout(900);
await page.screenshot({ path: `${outdir}/landing-mobile-light.png` });
console.log("captured", "landing-mobile-light.png");
await ctx.close();

await browser.close();
