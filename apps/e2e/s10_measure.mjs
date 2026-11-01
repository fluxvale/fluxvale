/* S10 DOM measurements — the lane's fixed instrument set, applied to
 * the org settings cluster:
 *  - no-pan at 1440/1000/920/845/820/768/760/375/320 across every
 *    surface this slice owns (org settings, org members, the access
 *    page's three states, the personal /settings/access frame)
 *  - band full-bleed + single seam under the chrome header
 *  - the tab underline's exactly-one-active per page (aria-current +
 *    the --focus border, one tab only)
 *  - the org mark UNIFIED: computed classes match the org home's mark
 *    on every surface (the S6 follow-up this slice closes)
 *  - the shared tab rail's wrap threshold, measured on every consumer
 *    (the S8 lesson: the numbers exist, re-state them) — bisection to
 *    the one-row floor
 *  - mono-panel contrast on sunken, light + dark, computed from live
 *    computed styles (token-derived via the rendered DOM)
 *  - reduced motion on REAL elements (rest + 60ms hover sampling on
 *    the tab links and the band's back link)
 * Raw JSON lines on stdout.
 *
 * Usage: node s10_measure.mjs   (FV_BASE, FV_TOKEN, S10_SLUG,
 *                                S10_SLUG_EMPTY, S10_SLUG_ENABLED)
 */
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4193";
const token = process.env.FV_TOKEN ?? "";
const slug = process.env.S10_SLUG ?? "";
const slugEmpty = process.env.S10_SLUG_EMPTY ?? "";
const slugEnabled = process.env.S10_SLUG_ENABLED ?? "";
if (!token || !slug || !slugEmpty || !slugEnabled) {
  console.error("FV_TOKEN, S10_SLUG, S10_SLUG_EMPTY, S10_SLUG_ENABLED required");
  process.exit(1);
}

const WIDTHS = [1440, 1000, 920, 845, 820, 768, 760, 375, 320];
const HEIGHT = (w) => (w <= 375 ? 760 : 900);

const live = (pg) =>
  pg.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

const browser = await chromium.launch();

async function signIn(ctx) {
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const res = await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  if (!res.ok()) throw new Error(`session POST failed: ${res.status()}`);
  await page.goto(`${BASE}/`, { waitUntil: "networkidle" });
  if (page.url().includes("/sign-in")) throw new Error("session did not take");
  await live(page);
  return page;
}

const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await signIn(ctx);

const settle = (pg) =>
  pg.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter(
          (a) =>
            !a.effect ||
            Number.isFinite(a.effect.getComputedTiming().duration ?? 0),
        )
        .map((a) => a.finished.catch(() => {})),
    ),
  );

const out = (line) => console.log(JSON.stringify(line));

// ---- 1. layout sweep: no-pan, band, seams, tabs, the unified mark ----
const layoutProbe = (pg) =>
  pg.evaluate(() => {
    const html = document.documentElement;
    const band = document.querySelector(".appgram .band");
    const bandRect = band?.getBoundingClientRect();
    const bandStyle = band ? getComputedStyle(band) : null;
    const header = document.querySelector("header");
    const headerRect = header?.getBoundingClientRect();

    // The active tab: exactly one aria-current=page link, and its
    // underline is the --focus token's 2px.
    const tabs = [...document.querySelectorAll("[data-testid='org-settings-tabs'] a")];
    const current = tabs.filter((a) => a.getAttribute("aria-current") === "page");
    const focusUnderlines = tabs.filter((a) =>
      [...a.classList].some((c) => c.startsWith("border-focus")),
    );

    // The org mark vs the org home's row-chip treatment (S6 follow-up):
    // same computed class list on every surface.
    const mark = document.querySelector(".appgram .band .grid.rounded-panel");
    const markClasses = mark ? [...mark.classList].sort().join(" ") : null;

    // mono panels present (the access pages) — count + first label
    const panels = [...document.querySelectorAll(".appgram .mono-panel")];

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
            // Single seam: the band's own top edge must carry NO border
            // (the chrome header's border-b is the top hairline); its
            // bottom edge carries the one 1px seam.
            borderTopWidth: bandStyle.borderTopWidth,
            borderBottomWidth: bandStyle.borderBottomWidth,
            bandBottom: +bandRect.bottom.toFixed(1),
            headerBottom: headerRect ? +headerRect.bottom.toFixed(1) : null,
            flushUnderHeader:
              headerRect && bandRect
                ? Math.abs(bandRect.top - headerRect.bottom) < 1
                : null,
          }
        : null,
      tabs: tabs.length
        ? {
            total: tabs.length,
            ariaCurrent: current.length,
            focusUnderline: focusUnderlines.length,
            oneRow:
              new Set(tabs.map((a) => Math.round(a.getBoundingClientRect().top))).size === 1,
          }
        : null,
      markClasses,
      monoPanels: panels.length,
    };
  });

const SURFACES = {
  "org-settings": `${BASE}/organizations/${slug}/settings`,
  "org-members": `${BASE}/organizations/${slug}/settings/members`,
  "access-empty": `${BASE}/organizations/${slugEmpty}/settings/access`,
  "access-enabled": `${BASE}/organizations/${slugEnabled}/settings/access`,
  "access-pairings": `${BASE}/organizations/${slug}/settings/access`,
  "access-personal": `${BASE}/settings/access`,
};

for (const [name, url] of Object.entries(SURFACES)) {
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: HEIGHT(width) });
    await page.goto(url, { waitUntil: "networkidle" });
    await live(page);
    out({ probe: "layout-sweep", surface: name, width, ...(await layoutProbe(page)) });
  }
}

// ---- 2. the mark's home reference: exact class match vs the org home ----
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(`${BASE}/organizations/${slug}`, { waitUntil: "networkidle" });
await live(page);
const homeMark = await page.evaluate(() => {
  const mark = document.querySelector(".appgram .band .grid.rounded-panel");
  return mark ? [...mark.classList].sort().join(" ") : null;
});
out({ probe: "org-home-mark-reference", classes: homeMark });
for (const [name, url] of Object.entries(SURFACES)) {
  if (name === "access-personal") continue; // the account band has no org mark
  await page.goto(url, { waitUntil: "networkidle" });
  await live(page);
  const probe = await layoutProbe(page);
  out({
    probe: "mark-unified",
    surface: name,
    matchesHome: probe.markClasses === homeMark,
    classes: probe.markClasses,
  });
}

// ---- 3. the shared tab rail's wrap threshold (bisection, the S8
// lesson): one-row floor per consumer page ----
const rowsAt = async (w, url) => {
  await page.setViewportSize({ width: w, height: 900 });
  await page.goto(url, { waitUntil: "networkidle" });
  await settle(page);
  return page.evaluate(() => {
    const tabs = [...document.querySelectorAll("[data-testid='org-settings-tabs'] a")];
    if (!tabs.length) return -1;
    return new Set(tabs.map((a) => Math.round(a.getBoundingClientRect().top))).size;
  });
};

for (const [name, url] of Object.entries(SURFACES)) {
  if (name === "access-personal") continue; // no tab rail on the personal frame
  let lo = 160;
  let hi = 760;
  if ((await rowsAt(hi, url)) !== 1 || (await rowsAt(lo, url)) < 2) {
    // The floor may sit below lo (the rail may never wrap): report the
    // one-row fact at the probed floor instead of a bogus bisection.
    const oneRowAtLo = (await rowsAt(lo, url)) === 1;
    out({
      probe: "tab-wrap-floor",
      surface: name,
      oneRowDownTo: oneRowAtLo ? lo : null,
      note: oneRowAtLo ? `one row at ${lo}px — floor below the probe range` : "bounds invalid",
    });
  } else {
    while (hi - lo > 1) {
      const mid = Math.floor((lo + hi) / 2);
      if ((await rowsAt(mid, url)) === 1) hi = mid;
      else lo = mid;
    }
    out({ probe: "tab-wrap-floor", surface: name, oneRowDownTo: hi });
  }
}

// ---- 4. mono-panel contrast on sunken, both themes ----
const contrastProbe = (pg) =>
  pg.evaluate(() => {
    const lum = (color) => {
      const rgb = color.match(/\d+(\.\d+)?/g).slice(0, 3).map(Number);
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
      pick("[data-testid='access-gateway-card']", "mono panel (ink-muted base)"),
      pick("[data-testid='access-hostname']", "hostname value (text-ink)"),
      pick("[data-testid='access-billing-line']", "rate value (ink-muted)"),
      pick(".mono-panel-label", "panel label (ink-subtle)"),
      pick("[data-testid='access-attached-address']", "attached address (text-ink)"),
    ].filter(Boolean);
  });

for (const mode of ["light", "dark"]) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(SURFACES["access-pairings"], { waitUntil: "networkidle" });
  await live(page);
  out({
    probe: "mono-contrast",
    theme: mode,
    surface: "access-pairings",
    items: await contrastProbe(page),
  });
  await page.goto(SURFACES["access-enabled"], { waitUntil: "networkidle" });
  await live(page);
  out({
    probe: "mono-contrast",
    theme: mode,
    surface: "access-enabled",
    items: await contrastProbe(page),
  });
}

// ---- 5. reduced motion: rest + honest 60ms hover sampling ----
const rctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  reducedMotion: "reduce",
});
const rpage = await signIn(rctx);
await rpage.goto(SURFACES["org-settings"], { waitUntil: "networkidle" });
await live(rpage);
await rpage.waitForTimeout(300);
const rmRest = await rpage.evaluate(() => {
  const rise = document.querySelector(".appgram .rise");
  const band = document.querySelector(".appgram .band");
  const tab = document.querySelector("[data-testid='org-settings-tabs'] a");
  return {
    surface: "org-settings band + rise + tab",
    riseOpacity: rise ? getComputedStyle(rise).opacity : null,
    riseAnimationName: rise ? getComputedStyle(rise).animationName : null,
    animations: document.getAnimations().length,
    bandBorderBottom: band ? getComputedStyle(band).borderBottomWidth : null,
    tabTransition: tab ? getComputedStyle(tab).transitionDuration : null,
  };
});
out({ probe: "reduced-motion-rest", ...rmRest });

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

for (const [name, url, sel] of [
  ["org-settings tab link", SURFACES["org-settings"], "[data-testid='org-settings-tab-members']"],
  ["band back link", SURFACES["org-settings"], "[data-testid='org-back']"],
  ["personal back link", SURFACES["access-personal"], "[data-testid='settings-access-back']"],
]) {
  await rpage.goto(url, { waitUntil: "networkidle" });
  const res = await watch60ms(rpage, () => rpage.locator(sel).first().hover());
  out({ probe: "reduced-motion-hover-60ms", surface: name, ...res });
}

await rctx.close();
await browser.close();
