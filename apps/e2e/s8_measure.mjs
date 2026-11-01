/* S8 DOM measurements (AFTER server):
 *  - no-pan at 1440/1000/920/845/820/768/760/375/320 (the deploy page,
 *    steps 1 and 3 — the widest surfaces)
 *  - band full-bleed (x=0, width=innerWidth) + no doubled hairline
 *    under the chrome (band border-top-width 0, one seam only)
 *  - stepper marker geometry at each step state (chip boxes + rail)
 *  - picker DOM signature: the resources step's picker class attributes
 *    as rendered (the source-level byte-guard's live counterpart) +
 *    slider keyboard contract (#221): arrow keys land on rungs only
 *  - rise behavior: step transitions are LiveView patches — zero
 *    appgram-rise starts after mount, checked across three advances
 *  - reduced-motion zero-delta incl. hover transitions at 60ms sampling
 *    (the S7 lesson)
 * Raw JSON lines on stdout.
 *
 * Usage: node s8_measure.mjs   (FV_BASE, FV_TOKEN required)
 */
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4191";
const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const WIDTHS = [1440, 1000, 920, 845, 820, 768, 760, 375, 320];
const HEIGHT = (w) => (w <= 375 ? 760 : 900);
const DEPLOY = `${BASE}/apps/forgejo/deploy`;

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

// count appgram-rise starts anywhere in the page
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

const out = (line) => console.log(JSON.stringify(line));

// ---- 1. layout sweep: no-pan + band full-bleed + hairline seams ----
for (const width of WIDTHS) {
  await page.setViewportSize({ width, height: HEIGHT(width) });
  await page.goto(DEPLOY, { waitUntil: "networkidle" });
  await settle(page);
  const m = await page.evaluate(() => {
    const html = document.documentElement;
    const band = document.querySelector(".appgram .band");
    const bandRect = band?.getBoundingClientRect();
    const bandStyle = band ? getComputedStyle(band) : null;
    const header = document.querySelector("header");
    const headerBorder = header ? getComputedStyle(header).borderBottomWidth : null;
    // the stepper's chips (rendered li > span markers)
    const chips = [...document.querySelectorAll(".appgram .band ol > li > span:first-child")].map(
      (c) => {
        const r = c.getBoundingClientRect();
        return { x: +r.x.toFixed(1), y: +r.y.toFixed(1), w: +r.width.toFixed(1), h: +r.height.toFixed(1) };
      },
    );
    return {
      innerWidth: window.innerWidth,
      htmlScrollWidth: html.scrollWidth,
      bodyScrollWidth: document.body.scrollWidth,
      noPan: html.scrollWidth <= window.innerWidth && document.body.scrollWidth <= window.innerWidth,
      band: bandRect
        ? {
            x: +bandRect.x.toFixed(1),
            width: +bandRect.width.toFixed(1),
            fullBleed:
              Math.abs(bandRect.x) < 0.5 && Math.abs(bandRect.width - window.innerWidth) < 0.5,
            borderTopWidth: bandStyle.borderTopWidth,
            borderBottomWidth: bandStyle.borderBottomWidth,
          }
        : null,
      chrome: { headerBorderBottom: headerBorder },
      stepperChips: chips,
    };
  });
  out({ probe: "layout-sweep", width, ...m });
}

// ---- 2. stepper marker geometry at each step state ----
const stepNames = { 1: "version", 2: "configuration", 3: "resources", 4: "name" };
for (const step of [1, 2, 3, 4]) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(DEPLOY, { waitUntil: "networkidle" });
  if (step > 1) {
    await page.locator("[data-testid='version-option']").first().click();
    await page.locator("[data-testid='continue-version']").click();
  }
  if (step > 2) await page.locator("[data-testid='continue-env']").click();
  if (step > 3) await page.locator("[data-testid='continue-resources']").click();
  await page.waitForTimeout(300);
  await settle(page);
  const geo = await page.evaluate(() => {
    const items = [...document.querySelectorAll(".appgram .band ol > li")];
    return items.map((li) => {
      const chip = li.querySelector("span:first-child");
      const rail = li.querySelector("span[aria-hidden='true']");
      const liStyle = getComputedStyle(li);
      const chipStyle = chip ? getComputedStyle(chip) : null;
      const railRect = rail ? rail.getBoundingClientRect() : null;
      return {
        label: li.textContent.trim(),
        state:
          liStyle.color === "rgb(0, 123, 101)"
            ? "done"
            : liStyle.fontWeight >= 600
              ? "current"
              : "todo",
        chipBorder: chipStyle?.borderColor,
        chipBg: chipStyle?.backgroundColor,
        railWidth: railRect ? +railRect.width.toFixed(1) : null,
        railHeight: railRect ? +railRect.height.toFixed(1) : null,
      };
    });
  });
  out({ probe: "stepper-geometry", atStep: step, id: stepNames[step], items: geo });
}

// ---- 3. picker DOM signature + slider keyboard contract (#221) ----
await page.goto(DEPLOY, { waitUntil: "networkidle" });
await page.locator("[data-testid='version-option']").first().click();
await page.locator("[data-testid='continue-version']").click();
await page.locator("[data-testid='continue-env']").click();
await page.waitForTimeout(300);
await settle(page);

const signature = await page.evaluate(() => {
  // the picker's rendered class signature: quick picks, slider rows,
  // readouts — everything between the form tag's quick-picks group and
  // its price readout, plus the three range inputs themselves.
  const form = document.querySelector("#resources-form");
  const nodes = [
    ...form.querySelectorAll("[data-testid^='preset-']"),
    ...form.querySelectorAll("input[type='range']"),
    ...form.querySelectorAll("[data-testid='recommended-allocation']"),
    ...form.querySelectorAll("[data-testid='resources-price']"),
  ];
  return nodes.map((n) => ({
    tag: n.tagName.toLowerCase(),
    testid: n.dataset.testid ?? null,
    cls: n.getAttribute("class"),
  }));
});
out({ probe: "picker-dom-signature", signature });

// keyboard: focus the CPU slider, read the value, ArrowRight once —
// the value must land on the NEXT RUNG (index+1), never between. The
// slider emits INDICES (the LiveView owns the rung array, #221), so
// the contract reads two ways: the index moves exactly ±1 per press,
// and the visible readout names the rung VALUE at every stop.
const cpu = page.locator("input[type='range'][data-testid='resource-cpu']");
await cpu.focus();
const readIndex = () => cpu.evaluate((el) => el.value);
const readoutText = () =>
  page.evaluate(() => {
    const input = document.querySelector(
      "input[type='range'][data-testid='resource-cpu']",
    );
    // the slider's header row: label + the aria-hidden value readout
    const header = input.closest("div").firstElementChild;
    const span = header.querySelector("span[aria-hidden='true']");
    return span ? span.textContent.trim() : null;
  });
const rungs = ["0.25", "0.5", "1", "2", "4", "6", "8"];
const beforeIdx = await readIndex();
const beforeRung = rungs[Number(beforeIdx)];
const beforeReadout = await readoutText();
await page.keyboard.press("ArrowRight");
await page.waitForTimeout(250);
const oneIdx = await readIndex();
const oneRung = rungs[Number(oneIdx)];
const oneReadout = await readoutText();
await page.keyboard.press("ArrowRight");
await page.waitForTimeout(250);
const twoIdx = await readIndex();
const twoRung = rungs[Number(twoIdx)];
const twoReadout = await readoutText();
await page.keyboard.press("ArrowLeft");
await page.waitForTimeout(250);
const backIdx = await readIndex();
const backRung = rungs[Number(backIdx)];
const backReadout = await readoutText();
out({
  probe: "slider-keyboard-rungs",
  rungs,
  steps: [
    { idx: beforeIdx, rung: beforeRung, readout: beforeReadout },
    { idx: oneIdx, rung: oneRung, readout: oneReadout },
    { idx: twoIdx, rung: twoRung, readout: twoReadout },
    { idx: backIdx, rung: backRung, readout: backReadout },
  ],
  oneIndexPerPress:
    Number(oneIdx) === Number(beforeIdx) + 1 &&
    Number(twoIdx) === Number(oneIdx) + 1 &&
    Number(backIdx) === Number(twoIdx) - 1,
  everyStopIsARung:
    rungs.includes(beforeRung) &&
    rungs.includes(oneRung) &&
    rungs.includes(twoRung) &&
    rungs.includes(backRung),
  readoutsMatchRungs:
    beforeReadout === `${beforeRung} cores` &&
    oneReadout === `${oneRung} cores` &&
    twoReadout === `${twoRung} cores` &&
    backReadout === `${backRung} cores`,
});

// ---- 4. rise behavior across step patches ----
await page.goto(DEPLOY, { waitUntil: "networkidle" });
await settle(page);
const risesAtLoad = await page.evaluate(() => window.__riseStarts);
await page.waitForTimeout(1200);
const risesAfterIdle = await page.evaluate(() => window.__riseStarts);
await page.locator("[data-testid='version-option']").first().click();
await page.locator("[data-testid='continue-version']").click();
await page.waitForTimeout(400);
const risesAfterStep2 = await page.evaluate(() => window.__riseStarts);
await page.locator("[data-testid='continue-env']").click();
await page.waitForTimeout(400);
const risesAfterStep3 = await page.evaluate(() => window.__riseStarts);
await page.locator("[data-testid='continue-resources']").click();
await page.waitForTimeout(400);
const risesAfterStep4 = await page.evaluate(() => window.__riseStarts);
out({
  probe: "rise-on-step-patches",
  risesAtLoad,
  risesAfterIdle,
  risesAfterStep2,
  risesAfterStep3,
  risesAfterStep4,
  noReplay: risesAfterStep4 === risesAfterIdle,
});

await ctx.close();

// ---- 5. reduced motion: zero-delta, hover sampled at 60ms ----
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
await rpage.goto(DEPLOY, { waitUntil: "networkidle" });
await rpage.waitForTimeout(300);
const rm = await rpage.evaluate(() => {
  const rise = document.querySelector(".appgram .rise");
  const card = document.querySelector(".appgram .card");
  const backLink = document.querySelector(".appgram .band a, .appgram .band button");
  return {
    riseOpacity: rise ? getComputedStyle(rise).opacity : null,
    riseAnimationName: rise ? getComputedStyle(rise).animationName : null,
    cardTranslate: card ? getComputedStyle(card).translate : "none",
    animations: document.getAnimations().length,
    backLinkTransition: backLink ? getComputedStyle(backLink).transitionProperty : null,
  };
});
out({ probe: "reduced-motion-rest", ...rm });

// hover a version label row (a non-card interactive surface) and a
// quick-pick button's neighbor region — sample every frame for 60ms.
await rpage.locator("label[for^='version-']").first().hover();
const rmHover = await rpage.evaluate(
  () =>
    new Promise((resolve) => {
      const t0 = performance.now();
      const sample = () => {
        const anims = document
          .getAnimations()
          .filter((a) => a instanceof CSSTransition || a instanceof CSSAnimation);
        if (anims.length > 0 || performance.now() - t0 >= 60) {
          resolve({
            atMs: Math.round(performance.now() - t0),
            animations: anims.length,
            props: anims.map((a) => a.transitionProperty || a.animationName),
          });
        } else {
          requestAnimationFrame(sample);
        }
      };
      requestAnimationFrame(sample);
    }),
);
out({ probe: "reduced-motion-hover-60ms", ...rmHover });

await rctx.close();
await browser.close();
