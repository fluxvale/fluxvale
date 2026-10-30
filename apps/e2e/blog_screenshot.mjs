/* Blog lane screenshots (#323): /blog and the example post, light +
 * dark, plus one narrow-viewport post shot for the responsive measure.
 * Anonymous surfaces — no session minting needed (screenshot.mjs's
 * anonymous-context pattern, T7 refresh).
 *
 * Usage: node blog_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv323-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function capture(name, path, mode, viewport) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
  console.log(`captured ${name}-${mode}.png`);
  await ctx.close();
}

const surfaces = [
  ["blog-index", "/blog"],
  ["blog-post", "/blog/example-post"],
];

for (const [name, path] of surfaces) {
  for (const mode of ["light", "dark"]) {
    await capture(name, path, mode, { width: 1440, height: 900 });
  }
}

// Narrow-viewport reading: the measure and the stacked index row.
for (const mode of ["light"]) {
  await capture("blog-post-narrow", "/blog/example-post", mode, { width: 390, height: 844 });
}

await browser.close();
