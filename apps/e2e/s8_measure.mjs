/* S8 DOM measurements (AFTER server) — hostile-348 revisions:
 *  - no-pan at 1440/1000/920/845/820/768/760/375/320, and the sweep
 *    WALKS the steps: every width is measured at step 1 AND step 3
 *    (the resources step — the widest; hostile-348 F8)
 *  - band full-bleed (x=0, width=innerWidth) + no doubled hairline
 *    under the chrome (band border-top-width 0, one seam only)
 *  - stepper marker geometry at each step state; state is re-derived
 *    from the CHIP's border token via in-page probe elements carrying
 *    the component's exact class strings (border-line-success = done,
 *    border-focus = current, border-line = todo) — never a hardcoded
 *    label rgb that a fix commit can silently replace (hostile-348 F2)
 *  - picker DOM signature + slider keyboard contract (#221)
 *  - rise behavior: zero replay across step patches
 *  - reduced motion on REAL elements (the step card is probed via the
 *    rendered rounded-panel node — `.appgram .card` matches zero
 *    elements here because <.card> emits no card class; hostile-348
 *    F3/F7), plus honest 60ms samples for a version-row hover (this
 *    slice's surface — must be 0) and a slider move (the picker's tick
 *    spans inherit transitions from the untouchable picker: improved
 *    vs base's 9, disclosed, not zero — hostile-348 F3)
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

const settle = (pg) =>
  pg.evaluate(() =>
    Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
  );

const out = (line) => console.log(JSON.stringify(line));

// advance the wizard to step n from a pristine load (steps are
// one-shot state; the caller reloads per scenario)
const gotoStep = async (pg, n) => {
  if (n > 1) {
    await pg.locator("[data-testid='version-option']").first().click();
    await pg.locator("[data-testid='continue-version']").click();
  }
  if (n > 2) await pg.locator("[data-testid='continue-env']").click();
  if (n > 3) await pg.locator("[data-testid='continue-resources']").click();
  await pg.waitForTimeout(300);
  await settle(pg);
};

// ---- 1. layout sweep: no-pan on steps 1 AND 3, band seams ----
for (const width of WIDTHS) {
  await page.setViewportSize({ width, height: HEIGHT(width) });
  const perStep = {};
  for (const step of [1, 3]) {
    await page.goto(DEPLOY, { waitUntil: "networkidle" });
    await gotoStep(page, step);
    perStep[`step${step}`] = await page.evaluate(() => {
      const html = document.documentElement;
      const band = document.querySelector(".appgram .band");
      const bandRect = band?.getBoundingClientRect();
      const bandStyle = band ? getComputedStyle(band) : null;
      const header = document.querySelector("header");
      return {
        innerWidth: window.innerWidth,
        htmlScrollWidth: html.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
        noPan:
          html.scrollWidth <= window.innerWidth &&
          document.body.scrollWidth <= window.innerWidth,
        band: bandRect
          ? {
              x: +bandRect.x.toFixed(1),
              width: +bandRect.width.toFixed(1),
              fullBleed:
                Math.abs(bandRect.x) < 0.5 &&
                Math.abs(bandRect.width - window.innerWidth) < 0.5,
              borderTopWidth: bandStyle.borderTopWidth,
              borderBottomWidth: bandStyle.borderBottomWidth,
            }
          : null,
        chrome: {
          headerBorderBottom: header ? getComputedStyle(header).borderBottomWidth : null,
        },
      };
    });
  }
  out({ probe: "layout-sweep", width, ...perStep });
}

// ---- 2. stepper marker geometry at each step state ----
const stepNames = { 1: "version", 2: "configuration", 3: "resources", 4: "name" };
for (const step of [1, 2, 3, 4]) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(DEPLOY, { waitUntil: "networkidle" });
  await gotoStep(page, step);
  const geo = await page.evaluate(() => {
    // probe chips carrying the component's exact class strings; the
    // classifier compares the live chips' computed borders against
    // these token-resolved references
    const ol = document.querySelector(".appgram .band ol");
    const mk = (cls) => {
      const el = document.createElement("span");
      el.className = cls;
      el.style.display = "none";
      ol.appendChild(el);
      const s = getComputedStyle(el);
      const out = { border: s.borderColor, bg: s.backgroundColor };
      el.remove();
      return out;
    };
    const tokens = {
      done: mk("border-line-success bg-success-muted"),
      current: mk("border-focus bg-focus/10"),
      todo: mk("border-line bg-panel"),
    };
    const items = [...ol.children].filter((li) => li.tagName === "LI");
    return items.map((li) => {
      const chip = li.querySelector("span:first-child");
      const rail = li.querySelector("span[aria-hidden='true']");
      const chipStyle = chip ? getComputedStyle(chip) : null;
      const state =
        chipStyle && chipStyle.borderColor === tokens.current.border
          ? "current"
          : chipStyle && chipStyle.borderColor === tokens.done.border
            ? "done"
            : chipStyle && chipStyle.borderColor === tokens.todo.border
              ? "todo"
              : `unknown:${chipStyle?.borderColor}`;
      const railStyle = rail ? getComputedStyle(rail) : null;
      const railRect = rail ? rail.getBoundingClientRect() : null;
      const railOn = rail && railStyle.display !== "none";
      return {
        label: li.textContent.trim().replace(/\s+/g, " "),
        state,
        hasCheckGlyph: !!chip.querySelector(".hero-check"),
        labelColor: getComputedStyle(li).color,
        chipBorder: chipStyle?.borderColor,
        chipBg: chipStyle?.backgroundColor,
        railVisible: railOn,
        railWidth: railOn ? +railRect.width.toFixed(1) : null,
        railHeight: railOn ? +railRect.height.toFixed(1) : null,
      };
    });
  });
  out({ probe: "stepper-geometry", atStep: step, id: stepNames[step], items: geo });
}

// ---- 3. wrap floors: first viewport width (top-down) where the
// stepper <ol> wraps to 2 rows. Wrap is monotonic in width, so bisect.
const wrapFloor = async (pg, url, olSelector) => {
  const rowsAt = async (w) => {
    await pg.setViewportSize({ width: w, height: 900 });
    await pg.goto(url, { waitUntil: "networkidle" });
    await settle(pg);
    return pg.evaluate((sel) => {
      const ol = document.querySelector(sel);
      if (!ol) return -1;
      return new Set([...ol.children].map((li) => Math.round(li.getBoundingClientRect().top)))
        .size;
    }, olSelector);
  };
  let lo = 300; // wraps here (assumed)
  let hi = 760; // one row here (assumed)
  if ((await rowsAt(hi)) !== 1 || (await rowsAt(lo)) < 2) return null;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await rowsAt(mid)) === 1) hi = mid;
    else lo = mid;
  }
  return hi; // the narrowest width that still holds ONE row
};

out({ probe: "deploy-wrap-floor", oneRowDownTo: await wrapFloor(page, DEPLOY, ".appgram .band ol") });
out({
  probe: "topup-wrap-floor",
  oneRowDownTo: await wrapFloor(page, `${BASE}/billing/topup`, "ol[data-testid='topup-stepper']"),
});

// ---- 4. picker DOM signature + slider keyboard contract (#221) ----
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(DEPLOY, { waitUntil: "networkidle" });
await gotoStep(page, 3);

const signature = await page.evaluate(() => {
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

const cpu = page.locator("input[type='range'][data-testid='resource-cpu']");
await cpu.focus();
const readoutText = () =>
  page.evaluate(() => {
    const input = document.querySelector(
      "input[type='range'][data-testid='resource-cpu']",
    );
    const header = input.closest("div").firstElementChild;
    const span = header.querySelector("span[aria-hidden='true']");
    return span ? span.textContent.trim() : null;
  });
const rungs = ["0.25", "0.5", "1", "2", "4", "6", "8"];
const idxAt = () => cpu.evaluate((el) => Number(el.value));
const beforeIdx = await idxAt();
const beforeReadout = await readoutText();
await page.keyboard.press("ArrowRight");
await page.waitForTimeout(250);
const oneIdx = await idxAt();
const oneReadout = await readoutText();
await page.keyboard.press("ArrowRight");
await page.waitForTimeout(250);
const twoIdx = await idxAt();
const twoReadout = await readoutText();
await page.keyboard.press("ArrowLeft");
await page.waitForTimeout(250);
const backIdx = await idxAt();
const backReadout = await readoutText();
out({
  probe: "slider-keyboard-rungs",
  rungs,
  steps: [
    { idx: beforeIdx, rung: rungs[beforeIdx], readout: beforeReadout },
    { idx: oneIdx, rung: rungs[oneIdx], readout: oneReadout },
    { idx: twoIdx, rung: rungs[twoIdx], readout: twoReadout },
    { idx: backIdx, rung: rungs[backIdx], readout: backReadout },
  ],
  oneIndexPerPress: oneIdx === beforeIdx + 1 && twoIdx === oneIdx + 1 && backIdx === twoIdx - 1,
  everyStopIsARung: [beforeIdx, oneIdx, twoIdx, backIdx].every(
    (i) => i >= 0 && i < rungs.length,
  ),
  readoutsMatchRungs:
    beforeReadout === `${rungs[beforeIdx]} cores` &&
    oneReadout === `${rungs[oneIdx]} cores` &&
    twoReadout === `${rungs[twoIdx]} cores` &&
    backReadout === `${rungs[backIdx]} cores`,
});

// ---- 5. rise behavior across step patches ----
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

// ---- 6. reduced motion: REAL elements, honest numbers ----
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
// the real step card: <.card> emits no `card` class (hostile-348
// F3/F7), so probe the rendered rounded-panel node and say so
const rm = await rpage.evaluate(() => {
  const rise = document.querySelector(".appgram .rise");
  const stepsSection = document.querySelectorAll(".appgram section")[1];
  const card = stepsSection ? stepsSection.querySelector(".rounded-panel.border") : null;
  const backLink = document.querySelector(".appgram .band a, .appgram .band button");
  return {
    cardFound: !!card,
    cardBorder: card ? getComputedStyle(card).borderColor : null,
    cardTranslate: card ? getComputedStyle(card).translate : "none",
    riseOpacity: rise ? getComputedStyle(rise).opacity : null,
    riseAnimationName: rise ? getComputedStyle(rise).animationName : null,
    animations: document.getAnimations().length,
    backLinkTransition: backLink ? getComputedStyle(backLink).transitionProperty : null,
  };
});
out({ probe: "reduced-motion-rest", ...rm });

// 60ms transition watcher: install first, fire, then read
const watch60ms = async (pg, fire) => {
  const pending = pg.evaluate(
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
  await fire();
  return pending;
};

// hover a version row (this slice's surface — the removed
// transition-colors must hold: 0 running)
const rmHover = await watch60ms(rpage, () =>
  rpage.locator("label[for^='version-']").first().hover(),
);
out({ probe: "reduced-motion-hover-60ms", surface: "version row (this slice)", ...rmHover });

// move a slider one rung under reduced motion: the tick spans'
// transitions are inherited from the untouchable picker — the honest
// number, disclosed (base measured 9; hostile-348 F3)
await gotoStep(rpage, 3);
const rcpu = rpage.locator("input[type='range'][data-testid='resource-cpu']");
await rcpu.focus();
const rmSlider = await watch60ms(rpage, () => rpage.keyboard.press("ArrowRight"));
out({
  probe: "reduced-motion-slider-move-60ms",
  surface: "picker tick spans (inherited from the guarded picker)",
  ...rmSlider,
});

await rctx.close();
await browser.close();
