/* #328 hostile-fix re-verification:
 * A. live contrast of the tone words (canvas-resolved, both modes)
 * B. forced-colors: active tab distinguishability (emulated)
 * C. hover lift: no lift on the backups shell + availability card; a
 *    link-card fixture (a.card) still lifts
 * D. tab rail fit at 320px and at 200% root font zoom (+ one underline)
 */

import { chromium } from "@playwright/test";

const BASE = "http://127.0.0.1:4184";
const INSTANCE_PATH = "/instances/01a18f45-9fab-7862-9e8d-d2430c92e188";

// WCAG relative luminance, for reporting the shipped pairs
const oklchToRgb = (L, C, H) => {
  const h = (H * Math.PI) / 180;
  const a = C * Math.cos(h);
  const b = C * Math.sin(h);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  let r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  let bb = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  const gamma = (c) => {
    c = Math.min(1, Math.max(0, c));
    return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
  };
  return [gamma(r), gamma(g), gamma(bb)].map((c) => Math.round(c * 255));
};
const parseColor = (str) => {
  if (str.startsWith("oklch")) {
    const nums = str.match(/[\d.]+/g).map(Number);
    return oklchToRgb(nums[0], nums[1], nums[2]);
  }
  return str.match(/\d+/g).map(Number);
};
const lum = (colorStr) => {
  const [r, g, b] = parseColor(colorStr);
  const f = (c) => {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const ratio = (a, b) => {
  const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
  return ((l1 + 0.05) / (l2 + 0.05)).toFixed(2);
};

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: process.env.FV_TOKEN ?? "" },
  headers: { "x-csrf-token": csrf },
});

async function setMode(mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

await page.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
await page.waitForTimeout(500);

console.log("=== A. tone words on the sunken panel (live DOM, canvas-resolved) ===");
for (const mode of ["light", "dark"]) {
  await setMode(mode);
  const words = await page.evaluate(() => {
    const out = [];
    for (const el of document.querySelectorAll("[data-testid='backup-run'] > span:first-child")) {
      out.push({
        word: el.textContent.trim(),
        color: getComputedStyle(el).color,
        cls: el.className,
      });
    }
    const panel = document.querySelector("[data-testid='backup-runs']").closest(".mono-panel");
    return { words: out, surface: getComputedStyle(panel).backgroundColor };
  });
  const succ = words.words.find((w) => /Finished/.test(w.word));
  const fail = words.words.find((w) => /Failed|Queued|Running/.test(w.word));
  console.log(`[${mode}] surface=${words.surface}`);
  for (const w of words.words) {
    console.log(
      `  "${w.word}" ${w.color} ${ratio(w.color, words.surface)}:1  (${w.cls.trim()})`
    );
  }
}

console.log("\n=== B. forced-colors: active — active tab distinguishable ===");
const fcPage = await ctx.newPage();
await fcPage.emulateMedia({ forcedColors: "active" });
await fcPage.goto(`${BASE}${INSTANCE_PATH}`, { waitUntil: "networkidle" });
await fcPage.waitForTimeout(500);
const fc = await fcPage.evaluate(() => {
  const tabs = [...document.querySelectorAll("[data-testid='dav-platform-tabs'] [role='tab']")];
  return tabs.map((t) => {
    const cs = getComputedStyle(t);
    return {
      tab: t.getAttribute("data-testid"),
      sel: t.getAttribute("aria-selected"),
      text: cs.color,
      borderB: cs.borderBottomColor,
    };
  });
});
for (const t of fc) console.log(`  ${t.tab} sel=${t.sel} text=${t.text} border-b=${t.borderB}`);
const active = fc.find((t) => t.sel === "true");
const inactives = fc.filter((t) => t.sel !== "true");
const activeVisible = active.borderB !== "rgba(0, 0, 0, 0)";
const inactiveInvisible = inactives.every((t) => t.borderB === "rgba(0, 0, 0, 0)");
console.log(`  active underline visible: ${activeVisible}; inactive underlines gone: ${inactiveInvisible} -> distinguishable: ${activeVisible && inactiveInvisible}`);

console.log("\n=== C. hover lift: form panels never lift; a link-card lifts ===");
await setMode("light");
async function liftOf(selector) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    el.scrollIntoView({ block: "center" });
    return getComputedStyle(el).translate;
  }, selector);
}
const targets = [
  ["availability card", "[data-testid='availability-card']"],
  ["backups shell", "[data-testid='backups-panel'] > div"],
  ["dav shell", "[data-testid='file-access-panel']"],
];
for (const [name, sel] of targets) {
  const before = await liftOf(sel);
  const box = await page.locator(sel).boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.waitForTimeout(400);
  const after = await page.evaluate((s) => getComputedStyle(document.querySelector(s)).translate, sel);
  console.log(`  ${name}: rest="${before}" hover="${after}" -> lifts: ${after !== "none" && after !== "0px"}`);
}
// fixture: a card that IS the link (the narrowed rule's subject) —
// real pointer hover, then remove
const realFixture = await (async () => {
  const handle = await page.evaluateHandle(() => {
    const host = document.querySelector("[data-testid='availability-card']").parentElement;
    const a = document.createElement("a");
    a.href = "#";
    a.className = "card block p-4 text-ink";
    a.id = "link-card-fixture";
    a.textContent = "link-card fixture";
    host.appendChild(a);
    a.scrollIntoView({ block: "center" });
    return a;
  });
  const box = await handle.asElement().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.waitForTimeout(400);
  const t = await page.evaluate(() => getComputedStyle(document.querySelector("#link-card-fixture")).translate);
  await page.evaluate(() => document.querySelector("#link-card-fixture").remove());
  return t;
})();
console.log(`  link-card fixture under a real hover: translate="${realFixture}" -> lifts: ${realFixture !== "none" && realFixture !== "0px"}`);

console.log("\n=== D. tab rail fit: 320px and 200% root font ===");
async function railFit(width, rootFontPx) {
  await page.setViewportSize({ width, height: 900 });
  await page.evaluate((px) => (document.documentElement.style.fontSize = `${px}px`), rootFontPx);
  await page.waitForTimeout(400);
  return page.evaluate(() => {
    const rail = document.querySelector("[data-testid='dav-platform-tabs']");
    const railRect = rail.getBoundingClientRect();
    const tabs = [...rail.querySelectorAll("[role='tab']")];
    const lastRight = Math.max(...tabs.map((t) => t.getBoundingClientRect().right));
    const underlined = tabs.filter((t) => {
      const cs = getComputedStyle(t);
      return cs.borderBottomWidth === "2px" && cs.borderBottomColor !== "rgba(0, 0, 0, 0)";
    });
    return {
      railScrollW: rail.scrollWidth,
      railClientW: rail.clientWidth,
      overflow: rail.scrollWidth - rail.clientWidth,
      lastTabPastRail: +(lastRight - railRect.right).toFixed(1),
      underlinedCount: underlined.length,
      docPan: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    };
  });
}
for (const [w, root, label] of [[320, 16, "320px @root16"], [375, 32, "375px @200% root (32px)"], [320, 32, "320px @200% root (32px)"]]) {
  const r = await railFit(w, root);
  console.log(
    `  ${label}: rail scroll=${r.railScrollW} client=${r.railClientW} overflow=${r.overflow} lastTabPastRail=${r.lastTabPastRail}px underlined=${r.underlinedCount} docPan=${r.docPan}px`
  );
}
await page.evaluate(() => (document.documentElement.style.fontSize = ""));
await page.setViewportSize({ width: 1440, height: 900 });

await browser.close();
console.log("\nre-verification probes done");
