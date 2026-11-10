// S7 final page captures: /catalog/<slug> light and dark at two
// viewports, fullPage, signed out, against the branch running locally
// (staging serves main, so the new seed only exists here).
// Output: <outdir>/<slug>/<slug>-<viewport>-<theme>.png
// Usage: FV_BASE=http://127.0.0.1:4000 node s7_page_shots.mjs [outdir]
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/611-page-shots";
const UA = "fluxvale-capture/611-s7";

const slugs = [
  "forgejo", "kavita", "memos", "vaultwarden", "pocket-id",
  "actualbudget", "umami", "vikunja", "docmost",
];
const viewports = [
  { w: 1440, h: 900, name: "1440x900" },
  { w: 390, h: 844, name: "390x844" },
];

mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
let count = 0;

for (const vp of viewports) {
  for (const theme of ["light", "dark"]) {
    const context = await browser.newContext({
      viewport: { width: vp.w, height: vp.h },
      colorScheme: theme,
      userAgent: UA,
    });
    const page = await context.newPage();
    for (const slug of slugs) {
      mkdirSync(`${OUT}/${slug}`, { recursive: true });
      const file = `${OUT}/${slug}/${slug}-${vp.name}-${theme}.png`;
      const resp = await page.goto(`${BASE}/catalog/${slug}`, { waitUntil: "networkidle", timeout: 60_000 });
      // goto resolves on networkidle even for 4xx/5xx — gate the status.
      if (!resp || !resp.ok()) throw new Error(`${slug}: HTTP ${resp ? resp.status() : "no response"}`);
      await page.waitForTimeout(600);
      await page.screenshot({ path: file, fullPage: true });
      count++;
      console.log(`captured ${slug} ${vp.name} ${theme}`);
    }
    await context.close();
  }
}
await browser.close();
console.log(`total: ${count}`);
