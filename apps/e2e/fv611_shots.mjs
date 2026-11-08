// #611 S2 capture: the rebuilt public app page hero at PikaPods depth.
// A deliberate capture economy, narrower than the plan's S2 done-when
// (every app at both widths and modes): Forgejo + Kavita — the pair
// with the deepest curation — get the full 1440/390 light/dark
// matrix, each remaining app gets one 1440 light frame (Umami, #587,
// is the minimum-contract page). Adapted from apps/e2e/screenshot.mjs's
// capture pattern (per-surface route list, never generic). Committed
// artifacts live under docs/screenshots/<PR>/.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.BASE_URL ?? "http://localhost:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/fv611-shots";
const UA = "fluxvale-capture/611";

const full = ["forgejo", "kavita"];
const rest = ["memos", "vaultwarden", "pocket-id", "actualbudget", "umami"];

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();

/**
 * Captures one catalog hero page.
 * @param {string} slug - the app's catalog slug
 * @param {number} width - viewport width (1440 desktop, 390 phone)
 * @param {"light"|"dark"} scheme - the context's color scheme
 */
async function capture(slug, width, scheme) {
  const context = await browser.newContext({
    colorScheme: scheme,
    viewport: { width, height: width === 390 ? 844 : 960 },
    userAgent: UA,
  });
  const page = await context.newPage();
  await page.goto(`${BASE}/catalog/${slug}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(400);
  const name = `catalog-hero-${slug}-${width}-${scheme}.png`;
  await page.screenshot({ path: `${OUT}/${name}`, fullPage: true });
  console.log(`captured ${name}`);
  await context.close();
}

for (const slug of full) {
  for (const width of [1440, 390]) {
    for (const scheme of ["light", "dark"]) {
      await capture(slug, width, scheme);
    }
  }
}

for (const slug of rest) {
  await capture(slug, 1440, "light");
}

await browser.close();
