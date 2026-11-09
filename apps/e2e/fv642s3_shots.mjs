/* #642 S3 capture: the Google door on /sign-in — the button below the
 * "or" divider, light + dark (the arm renders only with flag row +
 * creds present; the dev server for this capture boots with dummy
 * GOOGLE_CLIENT_ID/SECRET and a seeded flag row — see the PR's capture
 * notes). Per-surface route list, never generic (the screenshot.mjs
 * pattern). Committed artifacts live under docs/screenshots/<PR>/.
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4462";
const OUT = process.argv[2] ?? "/tmp/opencode/fv642s3-shots";

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();

for (const scheme of ["light", "dark"]) {
  const context = await browser.newContext({
    colorScheme: scheme,
    viewport: { width: 1440, height: 900 },
    userAgent: "fluxvale-capture/642-s3",
  });
  const page = await context.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  await page.waitForTimeout(400);

  const button = page.locator('[data-testid="google-sign-in"]');
  if (!(await button.isVisible())) {
    console.error(`google-sign-in button not visible (${scheme}) — flag/creds off?`);
    process.exit(1);
  }

  await page.screenshot({ path: `${OUT}/sign-in-google-${scheme}.png`, fullPage: true });
  console.log(`captured sign-in-google-${scheme}.png`);
  await context.close();
}

await browser.close();
