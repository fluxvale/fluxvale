/* S9 DOM measurements — the lane's fixed instrument set, applied to the
 * billing trio:
 *  - no-pan at 1440/1000/920/845/820/768/760/375/320 across every
 *    surface this slice owns (billing, org billing, wizard step 1,
 *    wizard payment step — the widest, the receipt state), and the
 *    sweep WALKS the wizard (S8's F8 lesson)
 *  - band full-bleed + single seam under the chrome header
 *  - the in-band facts' posture at every width for BOTH content
 *    extremes: the seeded healthy wallet ("No active burn") and the
 *    overdrawn wallet ("-$100.00" / "Depleted") — values inside the
 *    band, no clipped text, no value wrap
 *  - stepper wrap threshold ON THIS PAGE (bisection, the S8 lesson:
 *    the numbers exist, re-state them for the surfaces you own)
 *  - rise behavior: zero replay across wizard step patches
 *  - reduced motion on REAL elements (rest + 60ms hover sampling on
 *    the band CTA, the back link, the refund-policy link)
 *  - money figures' contrast: mono figures on their surfaces, light +
 *    dark, computed from live computed styles (token-derived via the
 *    rendered DOM, not frozen colors)
 * Raw JSON lines on stdout.
 *
 * Usage: node s9_measure.mjs   (FV_BASE, FV_TOKEN required;
 *                               S9_TOKEN_DEPLETED for the extreme arm)
 */
import { chromium } from "@playwright/test";
import { readFileSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4192";
const token = process.env.FV_TOKEN ?? "";
const tokenDepleted = process.env.S9_TOKEN_DEPLETED ?? "";
if (!token || !tokenDepleted) {
  console.error("FV_TOKEN and S9_TOKEN_DEPLETED required");
  process.exit(1);
}

const WIDTHS = [1440, 1000, 920, 845, 820, 768, 760, 375, 320];
const HEIGHT = (w) => (w <= 375 ? 760 : 900);

const browser = await chromium.launch();

// ---- sessions (cookie jars per actor) ----
async function signIn(ctx, jwt) {
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const res = await page.request.post(`${BASE}/auth/session`, {
    form: { token: jwt },
    headers: { "x-csrf-token": csrf },
  });
  if (!res.ok()) throw new Error(`session POST failed: ${res.status()}`);
  await page.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
  if (page.url().includes("/sign-in")) throw new Error("session did not take");
  return page;
}

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await signIn(ctx, token);

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

// drive the wizard to a step from a pristine load
const gotoStep = async (pg, n) => {
  if (n > 1) {
    await pg.locator("#topup-details-form input[name='details[name]']").fill("Jane Doe");
    await pg.locator("#topup-details-form input[name='details[country]']").fill("DE");
    await pg.waitForTimeout(300);
    await pg.locator("#topup-details-next").click();
  }
  if (n > 2) {
    await pg.locator("#topup-amount-form input[name='amount[dollars]']").fill("25");
    await pg.waitForTimeout(400);
    await pg.locator("#topup-amount-next").click();
  }
  await pg.waitForTimeout(400);
  await settle(pg);
};

const layoutProbe = (pg) =>
  pg.evaluate(() => {
    const html = document.documentElement;
    const band = document.querySelector(".appgram .band");
    const bandRect = band?.getBoundingClientRect();
    const bandStyle = band ? getComputedStyle(band) : null;
    const header = document.querySelector("header");
    const facts = document.querySelector("[data-testid='wallet-runway']")?.parentElement;
    const factsStyle = facts ? getComputedStyle(facts) : null;
    // every text node in the facts pair must fit HORIZONTALLY (no clip,
    // no value wrap — nowrap values overflow via scrollWidth; vertical
    // scrollHeight>clientHeight is display-size ink metrics, not a bug)
    const factsFit = facts
      ? [...facts.querySelectorAll("p")].every(
          (p) => p.scrollWidth <= p.clientWidth + 0.5,
        )
      : null;
    const balance = document.querySelector("[data-testid='wallet-balance']");
    const runway = document.querySelector("[data-testid='wallet-runway']");
    const inside =
      balance &&
      runway &&
      bandRect &&
      balance.getBoundingClientRect().bottom <= bandRect.bottom + 1 &&
      runway.getBoundingClientRect().bottom <= bandRect.bottom + 1;
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
            bandBottom: +bandRect.bottom.toFixed(1),
          }
        : null,
      chrome: {
        headerBorderBottom: header ? getComputedStyle(header).borderBottomWidth : null,
      },
      facts: facts
        ? {
            direction: factsStyle.flexDirection,
            factsFit,
            balanceText: balance?.textContent.trim().replace(/\s+/g, " "),
            balanceBottom: +balance.getBoundingClientRect().bottom.toFixed(1),
            runwayText: runway?.textContent.trim().replace(/\s+/g, " "),
            runwayBottom: +runway.getBoundingClientRect().bottom.toFixed(1),
            insideBand: !!inside,
          }
        : null,
    };
  });

// ---- 1. layout sweep across the owned surfaces ----
const SURFACES = {
  billing: async (pg) => {
    await pg.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
  },
  "org-billing": async (pg) => {
    await pg.goto(`${BASE}/organizations/acme-robotics/billing`, { waitUntil: "networkidle" });
  },
  "topup-step1": async (pg) => {
    await pg.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
    await gotoStep(pg, 1);
  },
  "topup-payment": async (pg) => {
    await pg.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
    await gotoStep(pg, 3);
  },
  receipt: async (pg) => {
    await pg.goto(`${BASE}/billing/topup/return?reference=pr_s9_capture`, {
      waitUntil: "networkidle",
    });
  },
};

for (const [name, nav] of Object.entries(SURFACES)) {
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: HEIGHT(width) });
    await nav(page);
    out({ probe: "layout-sweep", surface: name, width, ...(await layoutProbe(page)) });
  }
}

// ---- 2. facts posture at the extremes (overdrawn wallet) ----
const dctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const dpage = await signIn(dctx, tokenDepleted);
for (const width of WIDTHS) {
  await dpage.setViewportSize({ width, height: HEIGHT(width) });
  await dpage.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
  out({
    probe: "facts-extreme-depleted",
    width,
    ...(await layoutProbe(dpage)),
  });
}
await dctx.close();

// ---- 3. stepper wrap floor ON THIS PAGE (bisect, one-row floor) ----
const rowsAt = async (w) => {
  await page.setViewportSize({ width: w, height: 900 });
  await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
  await settle(page);
  return page.evaluate(() => {
    const ol = document.querySelector("ol[data-testid='topup-stepper']");
    if (!ol) return -1;
    return new Set([...ol.children].map((li) => Math.round(li.getBoundingClientRect().top)))
      .size;
  });
};
let lo = 300;
let hi = 760;
if ((await rowsAt(hi)) !== 1 || (await rowsAt(lo)) < 2) {
  out({ probe: "topup-wrap-floor", oneRowDownTo: null, note: "bisection bounds invalid" });
} else {
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await rowsAt(mid)) === 1) hi = mid;
    else lo = mid;
  }
  out({ probe: "topup-wrap-floor", oneRowDownTo: hi });
}

// ---- 4. rise behavior across wizard step patches ----
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
await settle(page);
const risesAtLoad = await page.evaluate(() => window.__riseStarts);
await page.waitForTimeout(1200);
const risesAfterIdle = await page.evaluate(() => window.__riseStarts);
try {
  await gotoStep(page, 2);
} catch (err) {
  const debug = await page.evaluate(() => ({
    url: location.pathname,
    h1: document.querySelector("h1")?.textContent?.trim() ?? null,
    forms: document.querySelectorAll("form").length,
    detailsForm: !!document.querySelector("#topup-details-form"),
    bodyStart: document.body.innerText.slice(0, 120).replace(/\s+/g, " "),
  }));
  out({ probe: "rise-debug", error: String(err).slice(0, 80), ...debug });
  throw err;
}
const risesAfterStep2 = await page.evaluate(() => window.__riseStarts);
// advance to payment from the amount step (gotoStep assumes a pristine
// load — the details inputs are gone once step 2 renders)
await page.locator("#topup-amount-form input[name='amount[dollars]']").fill("25");
await page.waitForTimeout(400);
await page.locator("#topup-amount-next").click();
await page.waitForTimeout(400);
await settle(page);
const risesAfterStep3 = await page.evaluate(() => window.__riseStarts);
out({
  probe: "rise-on-step-patches",
  risesAtLoad,
  risesAfterIdle,
  risesAfterStep2,
  risesAfterStep3,
  noReplay: risesAfterStep3 === risesAfterIdle,
});

// ---- 5. money contrast: mono figures on their surfaces, both themes ----
// ratio = (L1 + 0.05) / (L2 + 0.05) over the live computed colors; the
// effective background walks ancestors to the first painted fill.
const contrastProbe = (pg) =>
  pg.evaluate(() => {
    const lum = (color) => {
      let rgb;
      if (color.startsWith("oklch")) {
        // oklch(L C H) -> sRGB (the dark theme's success/danger tokens
        // are oklch; a naive numeric parse would misreport them)
        const [L, C, Hdeg] = color
          .match(/oklch\(([^)]+)\)/)[1]
          .split(/[\s,]+/)
          .slice(0, 3)
          .map(Number);
        const h = (Hdeg * Math.PI) / 180;
        const a = C * Math.cos(h);
        const b = C * Math.sin(h);
        const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
        const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
        const s_ = L - 0.0894841775 * a - 1.291485548 * b;
        const l = l_ ** 3;
        const m = m_ ** 3;
        const s = s_ ** 3;
        const lin = [
          4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
          -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
          -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
        ];
        rgb = lin.map((c) => {
          c = Math.min(Math.max(c, 0), 1);
          const g = c <= 0.0031308 ? 12.92 * c : 1.055 * (c ** (1 / 2.4)) - 0.055;
          return g * 255;
        });
      } else {
        rgb = color
          .match(/\d+(\.\d+)?/g)
          .slice(0, 3)
          .map(Number);
      }
      const f = (c) => {
        c /= 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      };
      return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]);
    };
    const ratio = (fg, bg) => {
      const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x);
      return +((a + 0.05) / (b + 0.05)).toFixed(2);
    };
    const bgOf = (el) => {
      let node = el;
      while (node && node !== document.documentElement) {
        const bg = getComputedStyle(node).backgroundColor;
        if (bg && !bg.startsWith("rgba(0, 0, 0, 0")) return bg;
        node = node.parentElement;
      }
      return "rgb(255, 255, 255)";
    };
    const pick = (sel, name) => {
      const el = document.querySelector(sel);
      if (!el) return { name, missing: true };
      const fg = getComputedStyle(el).color;
      return { name, fg, bg: bgOf(el), ratio: ratio(fg, bgOf(el)) };
    };
    return [
      pick("[data-testid='wallet-balance'] p.mt-1\\.5", "band balance value"),
      pick("[data-testid='wallet-runway'] p.mt-1\\.5", "band runway value"),
      pick("[data-testid='wallet-runway'] p.mt-1", "runway hint"),
      pick("[data-testid='ledger-row'] span.font-mono.text-success", "ledger credit"),
      pick("[data-testid='ledger-row'] span.font-mono.text-danger", "ledger debit"),
      pick(
        "[data-testid='ledger-row'] span.font-mono.text-ink-muted",
        "ledger timestamp (mono)",
      ),
      pick("[data-testid='topup-total'] span.font-mono", "wizard total (mono)"),
      pick(
        "[data-testid='topup-new-balance'] span.font-mono",
        "wizard new balance (mono)",
      ),
      pick(
        "[data-testid='topup-confirmation-completed'] + p span.font-mono",
        "receipt credit (mono)",
      ),
    ].filter(Boolean);
  });

const CONTRAST_SURFACES = {
  billing: `${BASE}/billing`,
  "topup-payment": null, // driven
  receipt: `${BASE}/billing/topup/return?reference=pr_s9_capture`,
};

for (const mode of ["light", "dark"]) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);

  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`${BASE}/billing`, { waitUntil: "networkidle" });
  out({ probe: "money-contrast", theme: mode, surface: "billing", items: await contrastProbe(page) });

  await page.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
  await gotoStep(page, 3);
  out({
    probe: "money-contrast",
    theme: mode,
    surface: "topup-payment",
    items: await contrastProbe(page),
  });

  await page.goto(`${BASE}/billing/topup/return?reference=pr_s9_capture`, {
    waitUntil: "networkidle",
  });
  out({
    probe: "money-contrast",
    theme: mode,
    surface: "receipt",
    items: (await contrastProbe(page)).filter((i) => i.name.includes("receipt credit")),
  });
}

// ---- 6. reduced motion: rest + honest 60ms hover sampling ----
const rctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  reducedMotion: "reduce",
});
const rpage = await signIn(rctx, token);
await rpage.waitForTimeout(300);
const rm = await rpage.evaluate(() => {
  const rise = document.querySelector(".appgram .rise");
  const band = document.querySelector(".appgram .band");
  const facts = document.querySelector("[data-testid='wallet-balance']");
  return {
    surface: "billing band + facts",
    riseOpacity: rise ? getComputedStyle(rise).opacity : null,
    riseAnimationName: rise ? getComputedStyle(rise).animationName : null,
    animations: document.getAnimations().length,
    factsFound: !!facts,
    bandBorderBottom: band ? getComputedStyle(band).borderBottomWidth : null,
  };
});
out({ probe: "reduced-motion-rest", ...rm });

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

const rmCta = await watch60ms(rpage, () => rpage.locator("#add-credits").hover());
out({ probe: "reduced-motion-hover-60ms", surface: "band CTA (Add credits)", ...rmCta });

const rmRefund = await watch60ms(rpage, () =>
  rpage.locator("a[data-testid='topup-refund-policy']").hover(),
);
out({ probe: "reduced-motion-hover-60ms", surface: "refund-policy link", ...rmRefund });

await rpage.goto(`${BASE}/billing/topup`, { waitUntil: "networkidle" });
const rmBack = await watch60ms(rpage, () =>
  rpage.locator(".appgram .band a").first().hover(),
);
out({ probe: "reduced-motion-hover-60ms", surface: "wizard back link", ...rmBack });

await rctx.close();
await browser.close();
