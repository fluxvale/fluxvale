/* #642 S4 capture: the policy pages carrying the Google copy — the
 * privacy card and the terms clause, light + dark. Anonymous pages;
 * a plain dev server on the slice branch serves them. Per-surface
 * route list, never generic (the screenshot.mjs pattern). Artifacts
 * live under docs/screenshots/<PR>/.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4464";
const OUT = process.argv[2] ?? "/tmp/opencode/fv642s4-shots";

mkdirSync(OUT, { recursive: true });

const surfaces = [
  { path: "/policies/privacy", name: "privacy-google", testid: "privacy-policy", must: ["Sign in with Google", "Nothing from your Google account"] },
  { path: "/policies/terms", name: "terms-google", testid: "terms-of-service", must: ["You may sign in with a Google account"] },
];

const browser = await chromium.launch();

for (const scheme of ["light", "dark"]) {
  const context = await browser.newContext({
    colorScheme: scheme,
    viewport: { width: 1440, height: 900 },
    userAgent: "fluxvale-capture/642-s4",
  });
  const page = await context.newPage();

  for (const surface of surfaces) {
    await page.goto(`${BASE}${surface.path}`, { waitUntil: "networkidle" });
    await page.waitForTimeout(300);

    const body = await page.locator("body").innerText();
    for (const phrase of surface.must) {
      if (!body.includes(phrase)) {
        console.error(`${surface.name} (${scheme}): copy missing "${phrase}" — wrong branch?`);
        process.exit(1);
      }
    }

    await page.screenshot({ path: `${OUT}/${surface.name}-${scheme}.png`, fullPage: true });
    console.log(`captured ${surface.name}-${scheme}.png`);
  }

  await context.close();
}

await browser.close();
