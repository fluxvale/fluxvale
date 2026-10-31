/* S4 DOM measurements — the spec's raw-output verification.
 * Sections (each prints one JSON line, prefixed MEASURE):
 *   layout       — no-pan, band full-bleed, in-band placement (Balance's
 *                  bottom vs the band's bottom line: inside, clearance
 *                  stated), runway anchor, rows/wrap alignment (per viewport)
 *   reduced      — reduced-motion: rise killed at first paint, zero delta
 *   live         — broadcast through the app's own Stop control:
 *                  container/row/runway NODE identity (expando survives),
 *                  rise animation not replayed (playState stays finished);
 *                  restore runs in finally — a throw mid-probe never
 *                  strands the instance stopped (CodeRabbit finding)
 *
 * Usage: FV_TOKEN=... FV_INSTANCE=<running instance id> \
 *        node s4_dom_measure.mjs <base>
 */

import { chromium } from "@playwright/test";

const BASE = process.argv[2] ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
const INSTANCE = process.env.FV_INSTANCE ?? "";
const SHAPE = process.env.FV_SHAPE ?? "";
const LAYOUT_ONLY = process.env.FV_LAYOUT_ONLY === "1";

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
    const rowsSection = document.querySelector(
      "section[aria-labelledby='dashboard-instances-title']"
    );
    const bandWrap = band?.querySelector(".wrap");
    const firstRow = document.querySelector("[data-testid='instance-row']");
    const runwayValue = runway?.querySelector("p:nth-of-type(2)");

    const r = (el) => {
      if (!el) return null;
      const b = el.getBoundingClientRect();
      return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, width: b.width };
    };

    // Line count of the runway value: wrapped text paints >1 client
    // rect. The band's height must never depend on this being >1 (F1).
    const valueLines = runwayValue
      ? runwayValue.getClientRects().length
      : null;
    const valueRect = runwayValue ? r(runwayValue) : null;

    return {
      viewport: { w: window.innerWidth, h: window.innerHeight },
      noPan: document.documentElement.scrollWidth <= window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      band: r(band),
      bandH: band ? Math.round(band.getBoundingClientRect().height * 10) / 10 : null,
      bandIsFullBleed: band ? band.getBoundingClientRect().left === 0 &&
        Math.abs(band.getBoundingClientRect().width - window.innerWidth) < 1 : null,
      balance: r(balance),
      // In-band placement (render-exact): the card is INSIDE the band —
      // its bottom sits above the band's bottom line, clearance stated.
      balanceInsideBand: band && balance
        ? balance.getBoundingClientRect().top >= band.getBoundingClientRect().top &&
          balance.getBoundingClientRect().bottom <= band.getBoundingClientRect().bottom
        : null,
      balanceTopInset: band && balance
        ? balance.getBoundingClientRect().top - band.getBoundingClientRect().top
        : null,
      balanceClearance: band && balance
        ? band.getBoundingClientRect().bottom - balance.getBoundingClientRect().bottom
        : null,
      runway: r(runway),
      runwayValueLines: valueLines,
      runwayValueNoWrap: valueRect && runwayValue
        ? runwayValue.scrollHeight <= Math.ceil(parseFloat(getComputedStyle(runwayValue).fontSize) * 1.3)
        : null,
      runwayValueText: runwayValue?.textContent.trim(),
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

// ---- 1. layout at the sweep widths (includes the 846→760 window the
// first harness stepped over — hostile F1) -------------------------------

const widths = [
  [1440, 900],
  [1000, 900],
  [920, 900],
  [900, 900],
  [899, 900],
  [845, 900],
  [844, 390],
  [820, 900],
  [768, 1024],
  [760, 900],
  [375, 800],
];

for (const [w, h] of widths) {
  const m = await layoutAt(browser, w, h);
  console.log(
    "MEASURE layout " +
      (SHAPE ? `shape=${SHAPE} ` : "") +
      JSON.stringify(m)
  );
}

// ---- 1b. hover-lift dead band: the link's own box must stay put ----
// (hostile F5) The grammar's a.card lift moves the link's own box,
// opening a 3px dead band at the row's bottom edge (#277 T5a/T7 exists
// because of exactly this). These rows lift an inner wrapper; a click
// 1px inside the link's bottom edge must NAVIGATE — hovered+settled
// and cold. (Skipped in FV_LAYOUT_ONLY mode — the wallet-shape sweep
// runs only section 1 per shape.)
if (!LAYOUT_ONLY) {
  {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  for (const hoverFirst of [true, false]) {
    await signIn(page);
    await page.locator("[data-testid='instance-row']").first().scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);

    const row = page.locator("[data-testid='instance-row']").first();
    const box = await row.boundingBox();
    const px = box.x + box.width / 2;
    const py = box.y + box.height - 1; // 1px inside the link's bottom edge

    if (hoverFirst) {
      await page.mouse.move(px, py);
      await page.waitForTimeout(400); // let the lift settle
    }

    await page.mouse.down();
    await page.mouse.up();
    await page.waitForTimeout(800);

    const navigated = !page.url().match(/\/$/);
    console.log(
      "MEASURE clickdeadband " +
        JSON.stringify({ hoverFirst, clickY: "bottom-1px", navigated })
    );

    if (!navigated) {
      console.log("ERROR clickdeadband: bottom-1px click did not navigate");
      process.exit(1);
    }
  }

  await ctx.close();
}
}

// ---- 2. reduced motion: the kill switch, zero delta -----------------------

if (!LAYOUT_ONLY) {
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
      balanceInsideBand:
        balance.getBoundingClientRect().bottom <= band.getBoundingClientRect().bottom,
      balanceClearance:
        band.getBoundingClientRect().bottom - balance.getBoundingClientRect().bottom,
    };
  });
  console.log(
    "MEASURE reduced " +
      JSON.stringify({ early, late, note: "no animation; card inside the band, clearance stated" })
  );
  await ctx.close();
}

// ---- 3. live update: broadcast must not replay the rise -------------------

if (!LAYOUT_ONLY) {
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
  // PubSub): stop the running instance from its show page. The restore
  // below runs in `finally` — CodeRabbit's single finding on the first
  // push: a throw mid-probe must never strand the instance stopped, and
  // a missing restore control must fail loudly, not skip silently.
  const page2 = await ctx.newPage();
  let probe = {};
  let restoreFailed = null;

  try {
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

    probe = await page.evaluate(
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
        };
      },
      INSTANCE
    );
  } finally {
    // Restore through the show page's own controls, or fail loudly — no
    // silent skip that leaves the instance stranded. Start/wake cover
    // stopped/sleeping; retry-deploy covers the dev-sentinel stop that
    // lands :error (no real cluster behind it). None found -> the run
    // fails loudly AFTER the measurement line prints below.
    await page2.goto(`${BASE}/instances/${INSTANCE}`, { waitUntil: "networkidle" });

    const restoreCandidates = [
      ["start", page2.locator("[data-testid='start-button']")],
      ["wake", page2.locator("[data-testid='wake-button']")],
      ["deploy", page2.locator("[data-testid='deploy-button']")],
    ];

    let clicked = null;

    for (const [name, loc] of restoreCandidates) {
      if ((await loc.count()) > 0) {
        await loc.click();
        clicked = name;
        break;
      }
    }

    if (clicked) {
      await page2.waitForTimeout(500);
    } else {
      restoreFailed =
        "live-probe restore failed: no start/wake/deploy control on the show page — instance may be stranded";
    }
  }

  console.log(
    "MEASURE live " + JSON.stringify({ before, after: probe, restore: restoreFailed ?? "ok" })
  );

  if (restoreFailed) {
    console.error("ERROR " + restoreFailed);
    process.exit(1);
  }

  await ctx.close();
  await browser2.close();
}

await browser.close();
console.log("done");
