/* S3 DOM measurements — raw numbers for the PR body.
 * Hardened per the #328 re-review:
 * - refuses to measure a /sign-in redirect (session failure)
 * - tolerates the no-runs state (the tone-word sections key off rows
 *   existing and report their absence instead of throwing)
 * - the motion section really emulates prefers-reduced-motion and counts
 *   animation/transition STARTS during a tab switch (names alone can
 *   hide a running animation)
 * - measures the .mono-panel SHELLS, not children found through them
 *
 * 1. no horizontal pan at 1440/1000/920/375
 * 2. mono-panel shells' computed font-family
 * 3. tab active states: exactly one amber underline per tablist
 * 4. flow-panel alignment with the availability card
 * 5. motion: starts observed during a tab switch, reduce vs no-preference
 */

import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4184";
const INSTANCE_PATH =
  process.env.FV_INSTANCE ?? "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// One live-socket assertion, the S7 lesson (same helper as s9/s10):
// the dav-tab drives below ride the socket — firing them into a dead
// page measures the wrong tab state (hostile-357 F6).
const live = (pg) =>
  pg.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: process.env.FV_TOKEN ?? "" },
  headers: { "x-csrf-token": csrf },
});

await page.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
await live(page);

// Session + surface guard: never measure the wrong page.
if (page.url().includes("/sign-in")) {
  console.error(`session failed — landed on ${page.url()}`);
  process.exit(1);
}
await page
  .locator("[data-testid='backups-panel']")
  .waitFor({ state: "visible", timeout: 10_000 });

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

console.log("\n=== 2. mono-panel SHELLS' computed font-family ===");
const shells = await page.evaluate(() =>
  [...document.querySelectorAll(".mono-panel")].map((el) => ({
    label: el.querySelector(".mono-panel-label")?.textContent.trim() ?? "(no label)",
    font: getComputedStyle(el).fontFamily,
  }))
);
if (shells.length === 0) console.log("  no .mono-panel shells on the page");
for (const s of shells) console.log(`  [${s.label}]: ${s.font}`);

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
  const left = (sel) => document.querySelector(sel)?.getBoundingClientRect().left ?? null;
  return {
    availabilityCard: left("[data-testid='availability-card']"),
    backupsPanel: left("[data-testid='backups-panel']"),
    davPanel: left("[data-testid='file-access-panel']"),
  };
});
console.log(JSON.stringify(edges));

console.log("\n=== 5. motion: animation/transition STARTS during a tab switch ===");
async function startsDuringSwitch(reduced) {
  await page.emulateMedia({ reducedMotion: reduced ? "reduce" : "no-preference" });
  await page.waitForTimeout(300);
  return page.evaluate(async () => {
    const rail = document.querySelector("[data-testid='dav-platform-tabs']");
    const shells = [...document.querySelectorAll(".mono-panel")];
    const watched = [rail, ...shells];
    let starts = 0;
    const onStart = () => starts++;
    // transitionrun/start + animationstart on the rail and both shells
    for (const el of watched) {
      el.addEventListener("transitionrun", onStart, true);
      el.addEventListener("transitionstart", onStart, true);
      el.addEventListener("animationstart", onStart, true);
    }
    const reduceNote = matchMedia("(prefers-reduced-motion: reduce)").matches;
    // switch to windows and back (two state changes = the fade's moment)
    const win = document.querySelector("[data-testid='dav-tab-windows']");
    const nix = document.querySelector("[data-testid='dav-tab-linux']");
    win.click();
    await new Promise((r) => setTimeout(r, 400));
    nix.click();
    await new Promise((r) => setTimeout(r, 400));
    for (const el of watched) {
      el.removeEventListener("transitionrun", onStart, true);
      el.removeEventListener("transitionstart", onStart, true);
      el.removeEventListener("animationstart", onStart, true);
    }
    return { starts, reduceNote, railTransition: getComputedStyle(rail).transitionDuration };
  });
}
const active = await startsDuringSwitch(false);
console.log(`no-preference: starts=${active.starts} (rail transition ${active.railTransition})`);
const reduced = await startsDuringSwitch(true);
console.log(`reduce:        starts=${reduced.starts} (media reported reduce=${reduced.reduceNote})`);
await page.emulateMedia({ reducedMotion: null });

await browser.close();
console.log("\nmeasurements done");
