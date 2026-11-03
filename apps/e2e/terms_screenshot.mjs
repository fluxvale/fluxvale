// Terms/AUP captures (#365): both policy pages (1440x900, light + dark,
// fullPage), the two footers (landing + chrome, element clips), and —
// when FV_TOKEN is set — the top-up notice clips (before/after the
// surface changed). Theme-flip pattern from screenshot.mjs: localStorage
// `phx:theme` + `data-theme` evaluate + 300ms settle.
//
// Usage: node terms_screenshot.mjs <outdir>   (FV_BASE optional;
// default http://127.0.0.1:4172 — the lane convention; FV_TOKEN optional,
// minted locally through the same JWT the sign-in flow mints — no test
// backdoors in the app)
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4172";
const outdir = process.argv[2] ?? "/tmp/opencode/fv365-terms";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session: the POST the sign-in flow makes, then reuse the cookie jar.
if (token) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
}

const flipThemeOn = (target, m) =>
  target.evaluate((mode) => {
    localStorage.setItem("phx:theme", mode);
    document.documentElement.setAttribute("data-theme", mode);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, m);

// ---- Policy pages: fullPage, light + dark (anonymous — they are
// public surfaces; the assertions in policies.spec.ts are anonymous too)
const anonCtx0 = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const anonPage0 = await anonCtx0.newPage();
for (const [name, path] of [
  ["terms", "/policies/terms"],
  ["aup", "/policies/acceptable-use"],
]) {
  for (const mode of ["light", "dark"]) {
    await anonPage0.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await flipThemeOn(anonPage0, mode);
    await anonPage0.waitForTimeout(300);
    await anonPage0.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
    console.log(`captured ${name}-${mode}.png`);
  }
}
await anonCtx0.close();

// ---- Footers: element clips, light + dark ----
// The landing is a visitor surface — "/" is the dashboard for a
// resolved session (screenshot.mjs's anonymous-context rule), so its
// footer capture rides a separate anonymous context.
const anonCtx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const anonPage = await anonCtx.newPage();

const footerShots = [
  ["footer-landing", "/", "footer", anonPage],
  ["footer-chrome", "/catalog", "footer", page],
];
for (const [name, path, selector, target] of footerShots) {
  for (const mode of ["light", "dark"]) {
    await target.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await flipThemeOn(target, mode);
    await target.waitForTimeout(300);
    const footer = target.locator(selector).last();
    await footer.scrollIntoViewIfNeeded();
    await footer.screenshot({ path: `${outdir}/${name}-${mode}.png` });
    console.log(`captured ${name}-${mode}.png`);
  }
}

// ---- Top-up notice: element clip, light + dark (needs the session) ----
// The notice lives on the wizard's amount step; the details form comes
// first — fill it and submit (local UI action; no payment is started).
if (token) {
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
    await flipThemeOn(page, mode);
    if (await page.locator("#topup-details-form").count()) {
      await page.fill("#topup-details-form input[name='details[name]']", "Jane Doe");
      await page.fill(
        "#topup-details-form input[name='details[email]']",
        "jane@example.com",
      );
      await page.fill("#topup-details-form input[name='details[country]']", "DE");
      await page.locator("#topup-details-form").dispatchEvent("submit");
      await page.waitForURL(/topup/, { timeout: 15000 });
    }
    await page.locator("[data-testid='topup-notice']").first().waitFor({ timeout: 15000 });
    await page.waitForTimeout(300);
    const notice = page.locator("[data-testid='topup-notice']").first();
    await notice.scrollIntoViewIfNeeded();
    const box = await notice.boundingBox();
    await page.screenshot({
      path: `${outdir}/topup-${mode}.png`,
      clip: {
        x: Math.max(0, box.x - 24),
        y: Math.max(0, box.y - 24),
        width: Math.min(1440, box.width + 48),
        height: box.height + 48,
      },
    });
    console.log(`captured topup-${mode}.png`);
  }
} else {
  console.log("no FV_TOKEN — skipped the top-up notice captures");
}

await anonCtx.close();

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
