/* Docs lane screenshots (ADR-0044): /docs index, a section page, and
 * an article, light + dark, plus one narrow-viewport article shot for
 * the stacked sidebar. Also re-captures the blog post page as the
 * prose-extraction regression check (markdown.css's .md-body now
 * styles both lanes). Anonymous surfaces — no session minting needed
 * (blog_screenshot.mjs's pattern).
 *
 * Usage: FV_BASE=http://127.0.0.1:4107 node docs_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/docs-shots";
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
  ["docs-index", "/docs"],
  ["docs-section", "/docs/guides"],
  ["docs-page", "/docs/guides/backups"],
  // The prose-extraction regression check: the blog article rides the
  // same .md-body rules since ADR-0044.
  ["blog-post", "/blog/introducing-fluxvale"],
];

for (const [name, path] of surfaces) {
  for (const mode of ["light", "dark"]) {
    await capture(name, path, mode, { width: 1440, height: 900 });
  }
}

// Narrow-viewport reading: the sidebar stacks above the article.
await capture("docs-page-narrow", "/docs/guides/backups", "light", { width: 390, height: 844 });

await browser.close();
