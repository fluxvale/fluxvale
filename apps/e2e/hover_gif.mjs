/* Element-cropped hover GIFs: one per lifted element (hero panel, first
 * bento cell, first app card), cropped 1:1 to the element's bounding box
 * (+40px margin) so the 3-4px lift is visible. recordVideo runs at
 * 1440x900; each video is cropped with the element's logged bbox. Only
 * .rise/.drop are neutralized — scroll-reveals run as shipped.
 *
 * Usage: node hover_gif.mjs <outdir>   (FV_BASE optional)
 */
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4172";
const outdir = process.argv[2] ?? "/tmp/opencode/fv297-hover";
mkdirSync(outdir, { recursive: true });

const targets = [
  ["panel", ".landing .panel"],
  ["cell", ".landing .cell"],
  ["card", ".landing .app-card"],
];

const browser = await chromium.launch();

for (const [name, sel] of targets) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: outdir, size: { width: 1440, height: 900 } },
  });
  const page = await ctx.newPage();
  await page.addInitScript(
    () => localStorage.setItem("phx:theme", "dark"),
  );
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  // Neutralize only the time-based load reveals; scroll-reveals stay.
  await page.addStyleTag({
    content: ".landing .rise,.landing .drop{animation:none!important;opacity:1!important;transform:none!important}",
  });
  const el = page.locator(sel).first();
  await el.scrollIntoViewIfNeeded();
  await page.mouse.move(10, 10);
  await page.waitForTimeout(500);

  const box = await el.evaluate((n) => {
    const r = n.getBoundingClientRect();
    return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  });
  console.log(`${name} bbox: ${JSON.stringify(box)}`);

  await el.hover();
  await page.waitForTimeout(900);
  await page.mouse.move(10, 10);
  await page.waitForTimeout(900);

  const video = page.video();
  await ctx.close();
  const webm = await video.path();

  const m = 40; // margin around the element
  const x = Math.max(0, box.x - m);
  const y = Math.max(0, box.y - m);
  const w = Math.min(1440 - x, box.w + 2 * m);
  const h = Math.min(900 - y, box.h + 2 * m);
  const out = `${outdir}/after-landing-hover-${name}-dark.gif`;
  execFileSync("ffmpeg", [
    "-y", "-i", webm,
    "-vf", `fps=12,crop=${w}:${h}:${x}:${y}`,
    out,
  ]);
  unlinkSync(webm);
  console.log(`captured after-landing-hover-${name}-dark.gif (crop=${w}:${h}:${x}:${y})`);
}

await browser.close();
writeFileSync(`${outdir}/done`, new Date().toISOString());
