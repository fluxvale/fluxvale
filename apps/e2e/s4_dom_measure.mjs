/* S4 DOM measurements — the spec's raw-output verification.
 * Sections (each prints one JSON line, prefixed MEASURE):
 *   layout       — no-pan, band full-bleed, straddle delta + token,
 *                  runway anchor, rows/wrap alignment (per viewport)
 *   reduced      — reduced-motion: rise killed at first paint, zero delta
 *   live         — broadcast through the app's own Stop control:
 *                  container/row/runway NODE identity (expando survives),
 *                  rise animation not replayed (playState stays finished)
 *
 * Usage: FV_TOKEN=... FV_INSTANCE=<running instance id> \
 *        node s4_dom_measure.mjs <base>
 */

import { chromium } from "@playwright/test";

const BASE = process.argv[2] ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
const INSTANCE = process.env.FV_INSTANCE ?? "";

if (!TOKEN || !INSTANCE) {
  console.error("FV_TOKEN and FV_INSTANCE required");
  process.exit(1);
}

const browser = await chromium.launch();

// ---- helpers ------------------------------------------------------------

async function signIn(page) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
  });
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(700);
  if (page.url().includes("/sign-in")) throw new Error("session failed");
}

async function layoutAt(browser, width, height) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  const page = await ctx.newPage();
  await signIn(page);

  const data = await page.evaluate(() => {
    const band = document.querySelector(".appgram .band");
    const balance = document.querySelector("[data-testid='dashboard-balance']");
    const runway = document.querySelector("[data-testid='dashboard-runway']");
    const rowsSection = document.querySelector("section.wrap");
    const bandWrap = band?.querySelector(".wrap");
    const firstRow = document.querySelector("[data-testid='instance-row']");
    const appgram = document.querySelector(".appgram");

    const r = (el) => {
      if (!el) return null;
      const b = el.getBoundingClientRect();
      return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, width: b.width };
    };

    const token = appgram
      ? getComputedStyle(appgram).getPropertyValue("--straddle-y").trim()
      : null;

    return {
      viewport: { w: window.innerWidth, h: window.innerHeight },
      noPan: document.documentElement.scrollWidth <= window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      band: r(band),
      bandIsFullBleed: band ? band.getBoundingClientRect().left === 0 &&
        Math.abs(band.getBoundingClientRect().width - window.innerWidth) < 1 : null,
      balance: r(balance),
      straddleToken: token,
      straddleDelta: band && balance
        ? balance.getBoundingClientRect().bottom - band.getBoundingClientRect().bottom
        : null,
      balanceInsideBand: band && balance
        ? balance.getBoundingClientRect().top >= band.getBoundingClientRect().top &&
          balance.getBoundingClientRect().bottom <= band.getBoundingClientRect().bottom
        : null,
      runway: r(runway),
      runwayAboveBandBottom: band && runway
        ? runway.getBoundingClientRect().bottom < band.getBoundingClientRect().bottom
        : null,
      runwayClearance: band && runway
        ? band.getBoundingClientRect().bottom - runway.getBoundingClientRect().bottom
        : null,
      rowsSection: r(rowsSection),
      bandWrap: r(bandWrap),
      firstRow: r(firstRow),
      rowsLeftAlignedWithBandWrap:
        bandWrap && firstRow && balance
          ? Math.abs(firstRow.getBoundingClientRect().left - balance.getBoundingClientRect().left) < 1
          : null,
      wrapLeftMatch: bandWrap && rowsSection
        ? Math.abs(
            rowsSection.getBoundingClientRect().left - bandWrap.getBoundingClientRect().left
          ) < 1
          : null,
    };
  });

  await ctx.close();
  return { viewport: `${width}x${height}`, ...data };
}

// ---- 1. layout at the spec's widths --------------------------------------

const widths = [
  [1440, 900],
  [1000, 900],
  [920, 900],
  [375, 800],
];

for (const [w, h] of widths) {
  const m = await layoutAt(browser, w, h);
  console.log("MEASURE layout " + JSON.stringify(m));
}

// ---- 2. reduced motion: the kill switch, zero delta -----------------------

{
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: "reduce" });
  const page = await ctx.newPage();
  await signIn(page);

  // Probe at FIRST PAINT of the live view (rise would hold opacity 0 at
  // start if the kill switch didn't win) and again after settle.
  await page.waitForSelector(".appgram .band");
  const early = await page.evaluate(() => {
    const rise = document.querySelector(".appgram .rise");
    const card = document.querySelector(".appgram .card");
    const cs = (el) => el && getComputedStyle(el);
    return {
      riseAnimation: cs(rise)?.animationName,
      riseOpacity: cs(rise)?.opacity,
      riseTransform: cs(rise)?.transform,
      cardTransition: cs(card)?.transitionProperty,
      cardTranslate: cs(card)?.translate,
    };
  });
  await page.waitForTimeout(800);
  const late = await page.evaluate(() => {
    const rise = document.querySelector(".appgram .rise");
    const balance = document.querySelector("[data-testid='dashboard-balance']");
    const band = document.querySelector(".appgram .band");
    const cr = (el) => {
      const b = el.getBoundingClientRect();
      return { top: Math.round(b.top * 10) / 10, bottom: Math.round(b.bottom * 10) / 10 };
    };
    return {
      riseOpacity: getComputedStyle(rise).opacity,
      balance: cr(balance),
      band: cr(band),
      straddleDelta:
        balance.getBoundingClientRect().bottom - band.getBoundingClientRect().bottom,
    };
  });
  console.log(
    "MEASURE reduced " + JSON.stringify({ early, late, note: "delta must equal the token, no animation" })
  );
  await ctx.close();
}

// ---- 3. live update: broadcast must not replay the rise -------------------

{
  const browser2 = await chromium.launch();
  const ctx = await browser2.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page);

  // Node identity via expando (the #328-re-review lesson: DOM NODE, not
  // innerHTML — a byte-equal innerHTML can hide replaced nodes).
  await page.evaluate((instanceId) => {
    const container = document.getElementById("dashboard-instances");
    const row = document.querySelector(`#instances-${instanceId}`);
    const runway = document.querySelector("[data-testid='dashboard-runway']");
    container.__s4probe = "container-node";
    if (row) row.__s4probe = "row-node";
    if (runway) runway.__s4probe = "runway-node";
  }, INSTANCE);

  const before = await page.evaluate((instanceId) => {
    const anims = (sel) =>
      Array.from(document.querySelectorAll(sel)).flatMap((el) =>
        el.getAnimations().map((a) => ({ state: a.playState, name: a.animationName }))
      );
    return {
      riseAnims: anims(".appgram .rise"),
      runwayText: document.querySelector("[data-testid='dashboard-runway']")?.textContent.trim(),
      rowText: document.querySelector(`#instances-${instanceId}`)?.textContent.trim(),
    };
  }, INSTANCE);

  // Drive the broadcast through the app's own control (the server is the
  // publisher — a second mix run process couldn't reach this node's
  // PubSub): stop the running instance from its show page.
  const page2 = await ctx.newPage();
  await page2.goto(`${BASE}/instances/${INSTANCE}`, { waitUntil: "networkidle" });
  await page2.locator("[data-testid='stop-button']").click();
  await page2.locator("[data-testid='status-message']").waitFor({ state: "visible" });
  // wait for the transition to settle somewhere past :running
  await page2.waitForFunction(
    () => !document.body.textContent.includes("Running"),
    null,
    { timeout: 15000 }
  );

  // Give the dashboard's own patch a beat.
  await page.bringToFront();
  await page.waitForTimeout(1200);

  const after = await page.evaluate(
    (instanceId) => {
      const container = document.getElementById("dashboard-instances");
      const row = document.querySelector(`#instances-${instanceId}`);
      const runway = document.querySelector("[data-testid='dashboard-runway']");
      const anims = (sel) =>
        Array.from(document.querySelectorAll(sel)).flatMap((el) =>
          el.getAnimations().map((a) => ({ state: a.playState, name: a.animationName }))
        );
      return {
        containerIdentity: container.__s4probe === "container-node",
        rowIdentity: row ? row.__s4probe === "row-node" : null,
        runwayIdentity: runway ? runway.__s4probe === "runway-node" : null,
        riseAnims: anims(".appgram .rise"),
        runwayText: runway?.textContent.trim(),
        rowText: row?.textContent.trim().replace(/\s+/g, " "),
        rowBadge: row?.textContent.includes("Stopped") || row?.textContent.includes("Stopping"),
      };
    },
    INSTANCE
  );

  console.log("MEASURE live " + JSON.stringify({ before, after }));

  // restore: start it back (the show page's state machine allows it from
  // wherever stop landed)
  await page2.goto(`${BASE}/instances/${INSTANCE}`, { waitUntil: "networkidle" });
  const startBtn = page2.locator("[data-testid='start-button']");
  const wakeBtn = page2.locator("[data-testid='wake-button']");
  if (await startBtn.count()) await startBtn.click();
  else if (await wakeBtn.count()) await wakeBtn.click();
  await ctx.close();
  await browser2.close();
}

await browser.close();
console.log("done");
