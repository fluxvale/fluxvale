/* S7 DOM measurements (AFTER server):
 *  - no-pan at 1440/1000/920/845/820/768/760/375/320, both pages
 *  - band full-bleed (x=0, width=innerWidth)
 *  - mosaic density: track count x gutter at each width; grid/wrap
 *    width at 1440 (the tell's proof: content width vs wrap width)
 *  - card lift probes: bottom-1px click reaches the target (motion on)
 *  - reduced-motion zero-delta (translate stays none, no animations)
 *  - navigation rise behavior: exactly +2 appgram-rise per mount,
 *    silent when idle
 * Raw JSON lines on stdout.
 *
 * Usage: node s7_measure.mjs   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4190";
const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const WIDTHS = [1440, 1000, 920, 845, 820, 768, 760, 375, 320];
const HEIGHT = (w) => (w <= 375 ? 700 : 900);

const browser = await chromium.launch();

// ---- session (shared cookie state) ----
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
const session = await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});
if (!session.ok()) throw new Error(`session POST failed: ${session.status()}`);

// count appgram-rise starts across navigations
await page.addInitScript(() => {
  window.__riseStarts = 0;
  window.addEventListener("animationstart", (e) => {
    if (e.animationName === "appgram-rise") window.__riseStarts++;
  });
});

const settle = (page) =>
  page.evaluate(() =>
    Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
  );

const measure = (page, width) =>
  page.evaluate((vw) => {
    const html = document.documentElement;
    const band = document.querySelector(".appgram .band");
    const wrap = document.querySelector(".appgram .wrap");
    const grid = document.querySelector("#catalog-mosaic");
    const bandRect = band?.getBoundingClientRect();
    const wrapRect = wrap?.getBoundingClientRect();
    const gridRect = grid?.getBoundingClientRect();
    const gridStyle = grid ? getComputedStyle(grid) : null;
    const wrapStyle = wrap ? getComputedStyle(wrap) : null;
    const wrapContentWidth = wrapRect
      ? wrapRect.width -
        parseFloat(wrapStyle.paddingLeft) -
        parseFloat(wrapStyle.paddingRight)
      : null;
    const tracks = gridStyle
      ? gridStyle.gridTemplateColumns.split(" ").filter(Boolean).length
      : null;
    const cards = grid ? [...grid.querySelectorAll(":scope > a")] : [];
    const firstRowRight = cards.length
      ? Math.max(...cards.filter((c) => c.getBoundingClientRect().top < gridRect.top + 2).map((c) => c.getBoundingClientRect().right))
      : null;
    return {
      width: vw,
      page: location.pathname,
      innerWidth: window.innerWidth,
      htmlScrollWidth: html.scrollWidth,
      bodyScrollWidth: document.body.scrollWidth,
      noPan: html.scrollWidth <= window.innerWidth && document.body.scrollWidth <= window.innerWidth,
      band: bandRect ? { x: bandRect.x, width: bandRect.width, fullBleed: Math.abs(bandRect.x) < 0.5 && Math.abs(bandRect.width - window.innerWidth) < 0.5 } : null,
      wrap: wrapRect ? { width: wrapRect.width, contentWidth: +wrapContentWidth.toFixed(1) } : null,
      grid: gridRect
        ? {
            contentWidth: gridRect.width,
            tracks,
            gutterPx: parseFloat(gridStyle.columnGap),
            wrapContentWidth: +wrapContentWidth.toFixed(1),
            gridVsWrapContentPct: +((gridRect.width / wrapContentWidth) * 100).toFixed(1),
            firstRowRightEdge: +firstRowRight.toFixed(1),
            wrapRightEdge: +(wrapRect.right - parseFloat(getComputedStyle(wrap).paddingRight)).toFixed(1),
          }
        : null,
    };
  }, width);

const out = (line) => console.log(JSON.stringify(line));

// ---- 1. layout sweep, both pages ----
for (const path of ["/apps", "/apps/forgejo"]) {
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: HEIGHT(width) });
    await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
    await settle(page);
    out(await measure(page, width));
  }
}

// ---- 2. card lift probe (motion on): hover translate + bottom-1px click ----
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
await settle(page);
const cards = page.locator("#catalog-mosaic > a");
const cardCount = await cards.count();
const probe = cards.nth(cardCount - 1);
const box = await probe.boundingBox();
await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(400);
const lift = await page.evaluate(() => {
  const card = [...document.querySelectorAll("#catalog-mosaic > a")].at(-1);
  const inner = card.firstElementChild;
  return {
    innerTranslate: getComputedStyle(inner).translate || getComputedStyle(inner).transform,
    cardTranslate: getComputedStyle(card).translate || "none",
  };
});
out({ probe: "hover-lift", ...lift });

// bottom-1px click on the probe card must navigate
const targetHref = await probe.getAttribute("href");
await page.mouse.click(box.x + box.width / 2, box.y + box.height - 1);
await page.waitForURL(`**${targetHref}`, { timeout: 5000 });
out({ probe: "bottom-1px-click", clicked: box.y + box.height - 1, navigatedTo: page.url(), ok: page.url().endsWith(targetHref) });

// ---- 3. navigation rise counts: mount-static pages, +2 per mount ----
await page.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
await settle(page);
const afterLoad = await page.evaluate(() => window.__riseStarts);
await page.waitForTimeout(1500);
const afterIdle = await page.evaluate(() => window.__riseStarts);
await page.click("#catalog-mosaic > a");
await page.waitForURL("**/apps/forgejo");
await settle(page);
const afterNavigate = await page.evaluate(() => window.__riseStarts);
await page.waitForTimeout(1500);
const afterNavIdle = await page.evaluate(() => window.__riseStarts);
await page.getByRole("link", { name: "Catalog" }).first().click();
await page.waitForURL("**/apps");
await settle(page);
const afterBack = await page.evaluate(() => window.__riseStarts);
out({
  probe: "navigation-rise",
  riseStartsAfterLoad: afterLoad,
  riseStartsAfterIdle: afterIdle,
  riseStartsAfterNavigate: afterNavigate,
  riseStartsAfterNavIdle: afterNavIdle,
  riseStartsAfterBack: afterBack,
});

await ctx.close();

// ---- 4. reduced motion: zero-delta ----
const rctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  reducedMotion: "reduce",
});
const rpage = await rctx.newPage();
await rpage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const rcsrf = await rpage.locator('meta[name="csrf-token"]').getAttribute("content");
const rsession = await rpage.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": rcsrf },
});
if (!rsession.ok()) throw new Error(`session POST failed: ${rsession.status()}`);
await rpage.goto(`${BASE}/apps`, { waitUntil: "networkidle" });
await rpage.waitForTimeout(300);
const rm = await rpage.evaluate(() => {
  const card = document.querySelector("#catalog-mosaic > a");
  const inner = card.firstElementChild;
  const rise = document.querySelector(".appgram .rise");
  const cs = getComputedStyle(rise);
  return {
    cardTranslate: getComputedStyle(card).translate || "none",
    innerTranslate: getComputedStyle(inner).translate || "none",
    riseOpacity: cs.opacity,
    riseAnimationName: cs.animationName,
    animations: document.getAnimations().length,
  };
});
out({ probe: "reduced-motion-rest", ...rm });

const rbox = await rpage.locator("#catalog-mosaic > a").first().boundingBox();
await rpage.mouse.move(rbox.x + rbox.width / 2, rbox.y + rbox.height / 2);
await rpage.waitForTimeout(400);
const rmHover = await rpage.evaluate(() => {
  const card = document.querySelector("#catalog-mosaic > a");
  return {
    cardTranslate: getComputedStyle(card).translate || "none",
    innerTranslate: getComputedStyle(card.firstElementChild).translate || "none",
    animations: document.getAnimations().length,
  };
});
out({ probe: "reduced-motion-hover", ...rmHover });

await rctx.close();
await browser.close();
