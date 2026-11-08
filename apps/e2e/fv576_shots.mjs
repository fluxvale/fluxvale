// #576 capture: the Umami catalog surfaces (public /catalog grid +
// /catalog/umami detail), light and dark, plus the landing with the
// analytics env set (visual proof: the tracked page shows no banner).
// Adapted from apps/e2e/screenshot.mjs's capture pattern (per-surface
// route list, never generic). The committed artifacts live under
// docs/screenshots/587/ (the PR number) with the -tracked suffix on
// the landing shots; pass that dir as argv[1] to overwrite in place.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.BASE_URL ?? "http://localhost:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/fv576-shots";
const UA = "fluxvale-capture/576";

const routes = [
  { name: "catalog", path: "/catalog" },
  { name: "detail", path: "/catalog/umami" },
  { name: "landing-tracked", path: "/" },
];

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
for (const scheme of ["light", "dark"]) {
  const context = await browser.newContext({
    colorScheme: scheme,
    viewport: { width: 1440, height: 960 },
    userAgent: UA,
  });
  const page = await context.newPage();
  for (const route of routes) {
    await page.goto(`${BASE}${route.path}`, { waitUntil: "networkidle" });
    await page.waitForTimeout(400);
    await page.screenshot({
      path: `${OUT}/${scheme}-${route.name}.png`,
      fullPage: route.name !== "catalog",
    });
    console.log(`captured ${scheme}-${route.name}.png`);
  }
  await context.close();
}
await browser.close();
