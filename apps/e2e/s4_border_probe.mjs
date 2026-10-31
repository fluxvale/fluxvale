import { chromium } from "@playwright/test";
const BASE = process.argv[2] ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
const browser = await chromium.launch();
for (const mode of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, { form: { token: TOKEN }, headers: { "x-csrf-token": csrf } });
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  const out = await page.evaluate(() => {
    const grab = (sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;
      const cs = getComputedStyle(el);
      return { border: cs.borderTopColor, shadow: cs.boxShadow === "none" ? "none" : "shadow-sm/md" };
    };
    return {
      balanceCard: grab("[data-testid='dashboard-balance']"),
      dashboardRow: grab("[data-testid='instance-row']"),
      indexRow: null,
    };
  });
  console.log(`MEASURE borders ${mode} ` + JSON.stringify(out));
  await ctx.close();
}
await browser.close();
