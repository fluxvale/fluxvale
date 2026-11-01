/* Spot probes for the hostile-348 fixes: stepper row counts at the
 * narrow widths (the 3-row regression must be gone) and the deploy h1
 * text (F9 — the visible "Deploy" prefix back in the heading).
 * Usage: node s8_spot.mjs (FV_BASE, FV_TOKEN)
 */
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4191";
const token = process.env.FV_TOKEN ?? "";
const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error("session failed");

for (const w of [344, 320, 375]) {
  await page.setViewportSize({ width: w, height: 760 });
  await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
  const rows = await page.evaluate(
    () =>
      new Set(
        [...document.querySelectorAll(".appgram .band ol > li")].map((li) =>
          Math.round(li.getBoundingClientRect().top),
        ),
      ).size,
  );
  const stubs = await page.evaluate(() =>
    [...document.querySelectorAll(".appgram .band ol span[aria-hidden='true']")]
      .map((s) => ({ display: getComputedStyle(s).display }))
      .filter((s) => s.display !== "none").length,
  );
  console.log(JSON.stringify({ probe: "deploy-rows", width: w, rows, visibleStubs: stubs }));
}

await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(`${BASE}/apps/forgejo/deploy`, { waitUntil: "networkidle" });
const h1 = await page.evaluate(() => ({
  text: document.querySelector(".appgram h1").textContent.trim().replace(/\s+/g, " "),
  nameTreatment: getComputedStyle(
    [...document.querySelector(".appgram h1").childNodes].filter(
      (n) => n.nodeType === 3 || n.textContent.trim() !== "Deploy",
    )[0]?.parentElement ?? document.querySelector(".appgram h1"),
  ).fontSize,
}));
console.log(JSON.stringify({ probe: "deploy-h1", ...h1 }));

const topup = await page.evaluate(async () => true);
await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
const topupState = await page.evaluate(() => ({
  path: location.pathname,
  hasStepper: !!document.querySelector("ol[data-testid='topup-stepper']"),
}));
console.log(JSON.stringify({ probe: "topup-page", ...topupState }));

await browser.close();
