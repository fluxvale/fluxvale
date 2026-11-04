// #396 pricing page captures: the page (light+dark, desktop+mobile),
// plus before/after of the landing band and nav. AFTER server = the
// feature branch dev server (port 4000); BEFORE server = the main
// checkout's dev server (port 4100, pre-#396 code).
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const AFTER = process.env.FV_AFTER ?? "http://127.0.0.1:4000";
const BEFORE = process.env.FV_BEFORE ?? "http://127.0.0.1:4100";
const outdir = process.argv[2] ?? "/tmp/opencode/pricing-shots";
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function themedContext(theme, viewport) {
  const ctx = await browser.newContext({ viewport });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
  return ctx;
}

async function shot(ctx, url, file, fn) {
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  await fn(page, file);
  await page.close();
  console.log("captured", file);
}

// Full-page pricing shots (desktop + mobile, light + dark).
for (const theme of ["light", "dark"]) {
  const desk = await themedContext(theme, { width: 1440, height: 900 });
  await shot(desk, `${AFTER}/pricing`, `${outdir}/pricing-page-${theme}.png`, (page, f) =>
    page.screenshot({ path: f, fullPage: true })
  );
  await desk.close();

  const mobile = await themedContext(theme, { width: 375, height: 812 });
  await shot(mobile, `${AFTER}/pricing`, `${outdir}/pricing-mobile-${theme}.png`, (page, f) =>
    page.screenshot({ path: f, fullPage: true })
  );
  await mobile.close();
}

// Landing band + nav, before and after (the band's capsule straddles
// the seam, so the clip scrolls the band into view as a viewport shot).
async function landingRegion(base, theme, region, label) {
  const ctx = await themedContext(theme, { width: 1440, height: 820 });
  await shot(ctx, `${base}/`, `${outdir}/${label}-${theme}.png`, async (page, f) => {
    if (region === "band") {
      await page.locator("section.pricing-band").scrollIntoViewIfNeeded();
      await page.waitForTimeout(700);
      await page.screenshot({ path: f });
    } else {
      await page.locator("header").screenshot({ path: f });
    }
  });
  await ctx.close();
}

for (const theme of ["light", "dark"]) {
  await landingRegion(BEFORE, theme, "band", "landing-band-before");
  await landingRegion(BEFORE, theme, "nav", "landing-nav-before");
  await landingRegion(AFTER, theme, "band", "landing-band-after");
  await landingRegion(AFTER, theme, "nav", "landing-nav-after");
}

await browser.close();
