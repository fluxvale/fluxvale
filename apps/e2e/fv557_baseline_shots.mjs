// Baseline-vs-branch capture for the #557 review findings: admin
// console, settings, landing hero — the surfaces where the hostile
// review flagged possible pre-existing issues. FV_BASE decides which
// server is captured.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN_ADMIN = process.env.FV_TOKEN_ADMIN ?? "";
const TOKEN_USER = process.env.FV_TOKEN_USER ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv557-baseline-shots";
mkdirSync(outdir, { recursive: true });

if (!TOKEN_ADMIN || !TOKEN_USER) {
  console.error("FV_TOKEN_ADMIN and FV_TOKEN_USER required");
  process.exit(1);
}

const browser = await chromium.launch();

async function signedIn(token, theme) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const res = await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  // A rejected token lands on /sign-in and produces signed-out captures
  // that look plausible — refuse to capture instead.
  if (!res.ok() || res.url().includes("/sign-in")) {
    console.error(`session rejected for ${BASE} (${res.status()})`);
    process.exit(1);
  }
  return { ctx, page };
}

const shots = [
  ["admin-console", "/admin", TOKEN_ADMIN],
  ["settings", "/settings", TOKEN_USER],
  ["landing", "/about", null],
];

for (const [name, path, token] of shots) {
  let ctx, page;
  if (token) {
    ({ ctx, page } = await signedIn(token, "light"));
  } else {
    ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), "light");
    page = await ctx.newPage();
  }
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(900);
  await page.screenshot({
    path: `${outdir}/${name}.png`,
    animations: "disabled",
  });
  console.log("captured", `${name}.png`);
  await ctx.close();
}

// The mobile hero on this base too (the measure finding).
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), "light");
const page = await ctx.newPage();
await page.goto(`${BASE}/about`, { waitUntil: "networkidle" });
await page.waitForTimeout(900);
await page.screenshot({ path: `${outdir}/landing-mobile.png`, animations: "disabled" });
console.log("captured", "landing-mobile.png");
await ctx.close();

await browser.close();
