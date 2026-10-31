/* F2 evidence: after un-nesting, the runway rides the band's single
 * reveal — no own animation, and its travel equals the Balance card's
 * (they arrive together). Samples per-frame from first paint. */

import { chromium } from "@playwright/test";

const BASE = process.argv[2] ?? "http://127.0.0.1:4186";
const TOKEN = process.env.FV_TOKEN ?? "";
if (!TOKEN) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});

// instrument BEFORE the reveal: sample every frame
await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });

const samples = await page.evaluate(
  () =>
    new Promise((resolve) => {
      const runway = document.querySelector("[data-testid='dashboard-runway']");
      const balance = document.querySelector("[data-testid='dashboard-balance']");
      const out = [];
      const t0 = performance.now();
      let lastRunTy = null;
      let lastBalTy = null;
      let maxRun = 0;
      let maxBal = 0;
      let minRunOp = 1;
      let minBalOp = 1;

      function sample() {
        const t = Math.round(performance.now() - t0);
        const rEl = runway.getBoundingClientRect();
        const bEl = balance.getBoundingClientRect();
        const cs = getComputedStyle(runway);
        const csb = getComputedStyle(balance);
        if (lastRunTy !== null) maxRun = Math.max(maxRun, lastRunTy - rEl.top);
        if (lastBalTy !== null) maxBal = Math.max(maxBal, lastBalTy - bEl.top);
        // effective opacity = product of ancestors' opacities
        let op = 1;
        let el = runway;
        while (el && el !== document.documentElement) {
          op *= parseFloat(getComputedStyle(el).opacity);
          el = el.parentElement;
        }
        minRunOp = Math.min(minRunOp, op);
        op = 1;
        el = balance;
        while (el && el !== document.documentElement) {
          op *= parseFloat(getComputedStyle(el).opacity);
          el = el.parentElement;
        }
        minBalOp = Math.min(minBalOp, op);
        lastRunTy = rEl.top;
        lastBalTy = bEl.top;
        if (t < 40 && t <= 8) {
          out.push({ t, runwayEffOp: +op.toFixed(3) });
        }
        if (t < 500) requestAnimationFrame(sample);
        else {
          resolve({
            runwayOwnAnimations: runway.getAnimations().length,
            runwayAnimationName: cs.animationName,
            maxRunwayTravelPx: +maxRun.toFixed(2),
            maxBalanceTravelPx: +maxBal.toFixed(2),
            minRunwayEffOpacity: +minRunOp.toFixed(3),
            minBalanceEffOpacity: +minBalOp.toFixed(3),
            early: out,
          });
        }
      }
      requestAnimationFrame(sample);
    })
);

console.log("MEASURE risetiming " + JSON.stringify(samples));

await browser.close();
