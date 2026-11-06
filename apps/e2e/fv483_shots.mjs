// The API tokens screenshots (#483, the owner's screenshot
// convention): the new section on the settings/access panel — the
// empty state, the create form, the once-only reveal after a mint,
// and the listed rows — light and dark.
//
// Authenticated pages; local dev target only. FV_TOKEN=<jwt> required
// (the fv483_session.exs mint).
//
// The reveal's raw value is MASKED before every capture — the owner
// convention is "never capture a secret", and a real mint's raw value
// is exactly the artifact class the hash-only design never persists.
//
// Usage:
//   FV_TOKEN=<jwt> node fv483_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const outdir = process.argv[2] ?? "/tmp/opencode/fv483-shots";
mkdirSync(outdir, { recursive: true });

if (!token) {
  console.error("FV_TOKEN required for authenticated surfaces");
  process.exit(1);
}

const MASK = "fvpat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 1100 } });

// Mask at insert time (the GIF script's posture): an init-script
// MutationObserver masks the reveal nodes on every mutation BEFORE the
// next paint, so even an un-timed screenshot cannot carry the raw.
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

// Session: POST /auth/session (the sign-in flow's own write), then the
// cookie jar carries every capture.
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

const PANEL = `${BASE}/settings/access`;

const maskReveal = () =>
  page.evaluate((masked) => {
    const value = document.querySelector("[data-testid='api-token-reveal-value']");
    const copy = document.querySelector("[data-testid='api-token-reveal-copy']");
    if (value) value.textContent = masked;
    if (copy) copy.setAttribute("data-copy-value", masked);
  }, MASK);

const capture = async (name) => {
  await page.goto(PANEL, { waitUntil: "networkidle" });
  await page.locator("[data-testid='api-tokens']").scrollIntoViewIfNeeded();
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`shot: ${name}`);
};

for (const theme of ["light", "dark"]) {
  await page.emulateMedia({ colorScheme: theme });
  await capture(`tokens-empty-${theme}`);
}

// After state: mint a token through the real form — the reveal is the
// capture's point (the once-only shape, the copy affordance, the
// warning), masked before the shot. Light first, then dark re-mints.
await page.emulateMedia({ colorScheme: "light" });
await page.goto(PANEL, { waitUntil: "networkidle" });
await page.locator("[data-testid='api-token-create']").waitFor({ state: "visible" });
await page.waitForTimeout(600);
await page.locator("[data-testid='api-tokens']").scrollIntoViewIfNeeded();

await page.fill("[data-testid='api-token-name-input']", "ci deploys");
await page.locator("input[value='instances:read']").check();
await page.locator("input[value='wallet:read']").check();
await page.click("[data-testid='api-token-create']");
await page.locator("[data-testid='api-token-reveal']").waitFor({ state: "visible" });
await maskReveal();
await page.waitForTimeout(400);
await page.screenshot({ path: `${outdir}/tokens-reveal-light.png`, fullPage: true });
console.log("shot: tokens-reveal-light");

// Dismiss, capture the listed row (metadata only, no raw value).
await page.click("[data-testid='api-token-reveal-done']");
await page.waitForTimeout(400);
await page.screenshot({ path: `${outdir}/tokens-listed-light.png`, fullPage: true });
console.log("shot: tokens-listed-light");

// Dark after state: another mint so the reveal is visible there too.
await page.emulateMedia({ colorScheme: "dark" });
await page.goto(PANEL, { waitUntil: "networkidle" });
await page.locator("[data-testid='api-token-create']").waitFor({ state: "visible" });
await page.waitForTimeout(600);
await page.locator("[data-testid='api-tokens']").scrollIntoViewIfNeeded();
await page.fill("[data-testid='api-token-name-input']", "terraform plan");
await page.locator("input[value='instances:write']").check();
await page.click("[data-testid='api-token-create']");
await page.locator("[data-testid='api-token-reveal']").waitFor({ state: "visible" });
await maskReveal();
await page.waitForTimeout(400);
await page.screenshot({ path: `${outdir}/tokens-reveal-dark.png`, fullPage: true });
console.log("shot: tokens-reveal-dark");

await page.click("[data-testid='api-token-reveal-done']");
await page.waitForTimeout(400);
await page.screenshot({ path: `${outdir}/tokens-listed-dark.png`, fullPage: true });
console.log("shot: tokens-listed-dark");

await ctx.close();
await browser.close();
console.log("done");
