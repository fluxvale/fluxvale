/* S5 BEFORE-captures (pre-change server, BASE=http://127.0.0.1:4189):
 * the open switcher on / and /settings, light + dark. Same walker
 * session as the after-shots (WALKER_TOKEN).
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4189";
const outdir = process.argv[2] ?? "/tmp/opencode/s5-shots-before";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: process.env.WALKER_TOKEN },
  headers: { "x-csrf-token": csrf },
});

const setTheme = (page, mode) =>
  page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

const shot = async (name, path, openSwitcher) => {
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  for (const mode of ["light", "dark"]) {
    await setTheme(page, mode);
    await page.waitForTimeout(250);
    if (openSwitcher) {
      await page.locator("[data-testid='org-switcher-button']").click();
      await page.waitForTimeout(250);
    }
    await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
    if (openSwitcher) await page.keyboard.press("Escape");
  }
};

await shot("before-switcher-open", "/", true);
await shot("before-settings", "/settings", false);

// The pre-change /settings/access is an unrouteable path — record what
// it answers for the table.
await page.goto(`${BASE}/settings/access`, { waitUntil: "networkidle" });
console.log("before /settings/access ->", page.url(), await page.title());

await ctx.close();
await browser.close();
