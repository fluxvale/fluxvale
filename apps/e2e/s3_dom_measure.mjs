/* S3 DOM measurements — raw numbers for the PR body.
 * 1. no horizontal pan (scrollWidth vs clientWidth) at 1440/1000/920/375
 * 2. mono panels' computed font-family (the mono stack)
 * 3. tab active states: exactly one platform tab carries the amber
 *    underline (2px, --focus token), per tablist
 * 4. flow-panel alignment: backups/dav cards share the availability
 *    card's left edge
 * 5. reduced-motion: no animation/transition on the panels' new shells
 */

import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4184";
const INSTANCE_PATH = process.env.FV_INSTANCE ?? "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: process.env.FV_TOKEN ?? "" },
  headers: { "x-csrf-token": csrf },
});

await page.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
await page.waitForTimeout(500);

console.log("=== 1. horizontal pan (document scrollWidth - clientWidth; 0 = no pan) ===");
for (const width of [1440, 1000, 920, 375]) {
  await page.setViewportSize({ width, height: 900 });
  await page.waitForTimeout(300);
  const pan = await page.evaluate(() => ({
    doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    body: document.body.scrollWidth - document.body.clientWidth,
  }));
  console.log(
    `width=${width}: document delta=${pan.doc}px body delta=${pan.body}px`
  );
}

await page.setViewportSize({ width: 1440, height: 900 });
await page.waitForTimeout(300);

console.log("\n=== 2. mono panels' computed font-family ===");
const fonts = await page.evaluate(() => {
  const pick = (sel) => {
    const el = document.querySelector(sel);
    return el ? getComputedStyle(el).fontFamily : "NOT FOUND";
  };
  return {
    backupsRunsPanel: pick("[data-testid='backup-runs']") === "NOT FOUND"
      ? getComputedStyle(document.querySelector(".mono-panel")).fontFamily
      : getComputedStyle(document.querySelector("[data-testid='backup-runs']").closest(".mono-panel")).fontFamily,
    davSnippet: getComputedStyle(document.querySelector("[data-testid='dav-platform-tabs']").closest(".mono-panel")).fontFamily,
    davTabLabel: getComputedStyle(document.querySelector("[data-testid='dav-tab-linux']")).fontFamily,
    runRow: getComputedStyle(document.querySelector("[data-testid='backup-run']")).fontFamily,
  };
});
for (const [k, v] of Object.entries(fonts)) console.log(`${k}: ${v}`);

console.log("\n=== 3. tab underline states (exactly one active per tablist) ===");
for (const key of ["linux", "windows", "macos"]) {
  await page.locator(`[data-testid='dav-tab-${key}']`).click();
  await page.waitForTimeout(400);
  const state = await page.evaluate(() => {
    const tabs = [...document.querySelectorAll("[data-testid='dav-platform-tabs'] [role='tab']")];
    return tabs.map((t) => {
      const cs = getComputedStyle(t);
      return {
        tab: t.getAttribute("data-testid"),
        ariaSelected: t.getAttribute("aria-selected"),
        borderBottomWidth: cs.borderBottomWidth,
        borderBottomColor: cs.borderBottomColor,
      };
    });
  });
  const underlined = state.filter(
    (t) => t.borderBottomWidth === "2px" && t.borderBottomColor !== "rgba(0, 0, 0, 0)"
  );
  console.log(`active=${key}: underlined=${underlined.map((t) => t.tab).join(",")} count=${underlined.length}`);
  for (const t of state) {
    console.log(`  ${t.tab}: aria-selected=${t.ariaSelected} border-b=${t.borderBottomWidth} ${t.borderBottomColor}`);
  }
}

console.log("\n=== 4. flow-panel left edges (px; must match the availability card) ===");
const edges = await page.evaluate(() => {
  const left = (sel) => document.querySelector(sel).getBoundingClientRect().left;
  return {
    availabilityCard: left("[data-testid='availability-card']"),
    backupsPanel: left("[data-testid='backups-panel']"),
    davPanel: left("[data-testid='file-access-panel']"),
  };
});
console.log(JSON.stringify(edges));

console.log("\n=== 5. motion on the panels' shells (reduced-motion zero-delta: no new animation) ===");
const motion = await page.evaluate(() => {
  const info = (sel) => {
    const el = document.querySelector(sel);
    if (!el) return "NOT FOUND";
    const cs = getComputedStyle(el);
    return `animation=${cs.animationName} transition=${cs.transitionProperty}`;
  };
  return {
    backupsShellCard: info("[data-testid='backups-panel'] > .card"),
    davShellCard: info("[data-testid='file-access-panel']"),
    runsMonoPanel: info("[data-testid='backup-runs']"),
    davMonoPanel: info("[data-testid='dav-platform-tabs']"),
  };
});
for (const [k, v] of Object.entries(motion)) console.log(`${k}: ${v}`);

await browser.close();
console.log("\nmeasurements done");
