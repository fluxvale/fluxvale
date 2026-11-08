// #611 S3 motion capture: the page's two new motions in one short
// video — the FAQ accordion's chevron rotation on open/close, and the
// linked card's hover lift (the browse card; the seeded catalog has
// one app per category, so no peer cards render). Light mode: the
// transforms are theme-independent. Output: webm for the ffmpeg GIF
// pass (the repo's hover_gif.mjs pattern).
import { chromium, devices } from "@playwright/test";

const BASE = process.env.BASE_URL ?? "http://localhost:4000";
const OUT = process.argv[2] ?? "/tmp/opencode/fv611s3-shots";

const browser = await chromium.launch();
const context = await browser.newContext({
  ...devices["Desktop Chrome"],
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: OUT, size: { width: 1440, height: 900 } },
  userAgent: "fluxvale-capture/611-s3",
});

const page = await context.newPage();
await page.goto(`${BASE}/catalog/forgejo`, { waitUntil: "networkidle" });
await page.waitForTimeout(400);

// The setup column's first closed row: click open (chevron rotates),
// wait out the transition, click closed.
const row = page.locator('[data-testid="faq-setup-column"] details').first();
await row.locator("summary").click();
await page.waitForTimeout(700);
await row.locator("summary").click();
await page.waitForTimeout(700);

// The browse card's hover lift, into and out of the hover.
const card = page.locator('[data-testid="browse-card"]');
await card.hover();
await page.waitForTimeout(700);
await page.mouse.move(720, 200);
await page.waitForTimeout(700);

// recordVideo writes on close.
await context.close();
await browser.close();
console.log(`video written under ${OUT}`);
