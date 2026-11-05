/* Feedback tag-filter screenshots (#412 T10): the board's tag filter and
 * a tagged post page, light + dark. Anonymous surfaces — no session
 * minting needed (the blog lane's pattern). The tags and the tagged
 * posts come from the seeds: `seed_tags!/0` arms the vocabulary and the
 * demo posts (DEMO_SEEDS_ENABLED posture) carry pairings, so a fresh
 * `mix setup` dev server has them.
 *
 * Usage: node feedback_tags_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/feedback-tags-shots";
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
  // The board: status chips, the tag filter chips beside them, rows with
  // their tag chips.
  ["feedback-board-tags", "/feedback"],
  // A tagged post: the kavita tag chip and the /apps/kavita cross-link
  // (a tag whose slug matches a catalog app).
  [
    "feedback-post-tagged",
    "/feedback/kavita-continue-reading-sync-across-devices",
  ],
];

for (const [name, path] of surfaces) {
  for (const mode of ["light", "dark"]) {
    await capture(name, path, mode, { width: 1440, height: 900 });
  }
}

await browser.close();
