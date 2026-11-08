// #532 confirm-block a11y visuals: the storybook's two variations in
// both color modes, plus a focus-ring frame (Tab onto the confirm's
// action). Local dev target only, driven by the storybook's own color
// mode toggle — no app session, no backdoors.
//
// Usage: FV_BASE=http://127.0.0.1:4001 node fv532_shots.mjs <outdir>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv532-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

for (const mode of ["light", "dark"]) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/storybook/components/confirm_block`, { waitUntil: "networkidle" });
  await page.waitForTimeout(500);

  if (mode === "dark") {
    // The header color-mode dropdown's Dark item (the menu is a
    // client-side popover; dispatch its click directly).
    await page.evaluate(() =>
      document.querySelector('#psb-colormode-dropdown a[phx-click*="dark"]').click(),
    );
    await page.waitForTimeout(800);
  }

  await page.screenshot({
    path: `${outdir}/confirm-${mode}.png`,
    animations: "disabled",
  });
  console.log("captured", `confirm-${mode}.png`);

  // Keyboard focus on the destructive action, both modes: the ring is
  // a token (outline-focus) drawn on the action strip's panel. Tab to
  // it rather than .focus(), so :focus-visible actually matches.
  await page.mouse.click(5, 500);
  for (let i = 0; i < 60; i++) {
    await page.keyboard.press("Tab");
    const hit = await page.evaluate(
      () => document.activeElement?.dataset?.testid === "story-stop-confirm",
    );
    if (hit) break;
  }
  await page.waitForTimeout(150);
  await page.screenshot({
    path: `${outdir}/confirm-${mode}-focus.png`,
    animations: "disabled",
  });
  console.log("captured", `confirm-${mode}-focus.png`);

  await ctx.close();
}

await browser.close();
