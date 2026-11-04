/* Feedback board screenshots (#412 T4): the board and a post page,
 * light + dark. Anonymous surfaces — no session minting needed (the
 * blog lane's pattern). The starter posts come from the promotable
 * seed (Seeds.seed_feedback!/0), so a fresh `mix setup` dev server has
 * them.
 *
 * Usage: node feedback_screenshot.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/feedback-shots";
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
  ["feedback-board", "/feedback"],
  // The completed terraform-provider post: badge, counters, a real body.
  ["feedback-post", "/feedback/terraform-provider-for-instance-management"],
];

for (const [name, path] of surfaces) {
  for (const mode of ["light", "dark"]) {
    await capture(name, path, mode, { width: 1440, height: 900 });
  }
}

await browser.close();
