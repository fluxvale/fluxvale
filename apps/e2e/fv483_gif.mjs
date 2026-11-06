// The #483 motion capture: just the create → reveal moment (the
// once-only warning appearing is the motion in this surface). Short
// and single-page so the trim is trivial. The raw value is MASKED as
// soon as the reveal is up — the motion (the callout's entrance) is
// what the recording is for, never the secret itself.
//
// Usage: FV_TOKEN=<jwt> node fv483_gif.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv483-gif";
mkdirSync(`${outdir}/video`, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const MASK = "fvpat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

const browser = await chromium.launch();

// Mask at insert time, not after: an init-script MutationObserver
// masks the reveal nodes on every mutation BEFORE the next paint, so
// no recorded frame ever carries the raw value (the after-the-fact
// evaluate can only cover frames from its own call onward).
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: `${outdir}/video`, size: { width: 1440, height: 900 } },
});
await ctx.addInitScript((masked) => {
  const mask = () => {
    const value = document.querySelector("[data-testid='api-token-reveal-value']");
    if (value && value.textContent !== masked) value.textContent = masked;
    const copy = document.querySelector("[data-testid='api-token-reveal-copy']");
    if (copy && copy.getAttribute("data-copy-value") !== masked) {
      copy.setAttribute("data-copy-value", masked);
    }
  };
  new MutationObserver(mask).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    characterData: true,
  });
}, MASK);

const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

await page.goto(`${BASE}/settings/access`, { waitUntil: "networkidle" });
await page.locator("[data-testid='api-token-create']").waitFor({ state: "visible" });
await page.waitForTimeout(500);

// Crop to the section: scroll it into view, then drive the form.
await page.locator("[data-testid='api-token-name-input']").scrollIntoViewIfNeeded();
await page.waitForTimeout(600);
await page.fill("[data-testid='api-token-name-input']", "ci deploys");
await page.locator("input[value='instances:read']").check();
await page.waitForTimeout(400);
await page.click("[data-testid='api-token-create']");
await page.locator("[data-testid='api-token-reveal']").waitFor({ state: "visible" });

// Belt and braces: the observer masks at mutation time; this covers
// the same nodes directly.
await page.evaluate((masked) => {
  const value = document.querySelector("[data-testid='api-token-reveal-value']");
  const copy = document.querySelector("[data-testid='api-token-reveal-copy']");
  if (value) value.textContent = masked;
  if (copy) copy.setAttribute("data-copy-value", masked);
}, MASK);

await page.waitForTimeout(2500);

await ctx.close();
await browser.close();
console.log("gif source recorded");
