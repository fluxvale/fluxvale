/* S7 density + cliff sweep (hostile-341 F1/F2/F3 re-measurement):
 * auto-fit mosaic, fill% measured per app-count x width — not
 * seed-shaped. Cards beyond the n under test are display:none'd (they
 * stop being grid items, so auto-fit re-fits) and the page is reloaded
 * between widths. Also: the cliff sweep (479/480/520/560) — track
 * count, min cell width, eyebrow and name line counts at the narrowest
 * 2-up cells. Raw JSON lines on stdout.
 *
 * Usage: node s7_density.mjs   (FV_BASE, FV_TOKEN required; the target
 * catalog must hold >= 11 apps — stage with s7_stage.exs)
 */
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4190";
const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const NS = [1, 2, 3, 7, 11];
const WIDTHS = [1440, 1024, 768, 560, 480, 375, 320];
const CLIFF_WIDTHS = [479, 480, 520, 560];
const HEIGHT = (w) => (w <= 375 ? 700 : 900);

const out = (line) => console.log(JSON.stringify(line));

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);

const measure = (page, width, n) =>
  page.evaluate(
    ({ vw, n }) => {
      const html = document.documentElement;
      const grid = document.querySelector("#catalog-mosaic");
      const wrap = grid?.closest(".wrap");
      if (!grid || !wrap) return { width: vw, n, error: "no grid" };
      const cards = [...grid.querySelectorAll(":scope > a")];
      const visible = cards.slice(0, n);
      visible.forEach((c) => (c.style.display = ""));
      cards.slice(n).forEach((c) => (c.style.display = "none"));

      const gridRect = grid.getBoundingClientRect();
      // auto-fit collapses unused tracks to 0px but still lists them —
      // the used track count is the non-zero entries.
      const trackCount = getComputedStyle(grid)
        .gridTemplateColumns.split(" ")
        .filter((t) => parseFloat(t) > 0).length;
      const rows = new Map();
      for (const card of visible) {
        const r = card.getBoundingClientRect();
        const top = Math.round(r.top);
        const rowTop = [...rows.keys()].find((t) => Math.abs(t - top) < 4) ?? top;
        rows.set(rowTop, [...(rows.get(rowTop) ?? []), r]);
      }
      const rowTops = [...rows.keys()].sort((a, b) => a - b);
      const lastRow = rows.get(rowTops[rowTops.length - 1]);
      const lastRowWidth =
        lastRow.reduce((sum, r) => sum + r.width, 0) + (lastRow.length - 1) * 16;
      const cellWidth = visible[0].getBoundingClientRect().width;

      const eyebrowLines = visible.map(
        (c) => c.querySelector("p.eyebrow").getClientRects().length,
      );
      const nameLines = visible.map(
        (c) => c.querySelector("h2").getClientRects().length,
      );

      return {
        width: vw,
        n,
        tracks: trackCount,
        rows: rowTops.length,
        cellWidth: +cellWidth.toFixed(1),
        gridWidth: +gridRect.width.toFixed(1),
        lastRowFill: +((lastRowWidth / gridRect.width) * 100).toFixed(1),
        lastRowCards: lastRow.length,
        noPan: html.scrollWidth <= window.innerWidth,
        eyebrowLinesMax: Math.max(...eyebrowLines),
        nameLinesMax: Math.max(...nameLines),
      };
    },
    { vw: width, n },
  );

// ---- fill table: n x width ----
for (const width of WIDTHS) {
  await page.setViewportSize({ width, height: HEIGHT(width) });
  await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  for (const n of NS) {
    out(await measure(page, width, n));
  }
}

// ---- cliff sweep: 479/480/520/560, full catalog ----
for (const width of CLIFF_WIDTHS) {
  await page.setViewportSize({ width, height: 900 });
  await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  out(await measure(page, width, 11));
}

await ctx.close();
await browser.close();
