/* The Kavita catalog page's captures (#679 slice 2): the caveats
 * panel carrying the library folder-layout fact, light and dark. The
 * page is public — no sign-in. Every shot waits on the new caveat's
 * own list item after the goto: a stale seed or a 500 can never
 * masquerade as evidence.
 *
 * Port 4181 (not the 4000 default): sibling dev servers on this box
 * claim 4000 and 4179.
 *
 * Usage: node fv679s2_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4181";
const outdir = process.argv[2] ?? "/tmp/opencode/fv679s2-shots";

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function setTheme(page, mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  userAgent: "fluxvale-capture/679",
});
const page = await ctx.newPage();

for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/catalog/kavita`, { waitUntil: "networkidle" });
  // The caveats panel ("Worth knowing") with the #679 layout fact in it.
  await page.waitForSelector("li:has-text('subfolders of the library folder')");
  await setTheme(page, mode);
  await page.screenshot({
    path: `${outdir}/kavita-catalog-caveat-${mode}.png`,
    fullPage: true,
  });
  console.log(`captured kavita-catalog-caveat-${mode}.png`);
}

await ctx.close();
await browser.close();
console.log("done");
