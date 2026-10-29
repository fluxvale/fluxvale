// The access wake interstitials' screenshots (ADR-0039 §6, the owner's
// screenshot convention): the two pages this surface serves — the wake
// page and the 503 status page. Anonymous endpoints (no session); the
// wake page carries dark-mode media queries, the status page does not
// (one light capture + a PR-body note). Local dev target only.
//
// Usage: FV_WAKE_URL=… FV_STATUS_URL=… node access_wake_screenshot.mjs <outdir>
// The URLs are the seeded pairings (gateway :active, private instance
// :sleeping / :stopped, AccessRoute rows) — see the #301 PR body for
// the seed shape.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const WAKE_URL = process.env.FV_WAKE_URL;
const STATUS_URL = process.env.FV_STATUS_URL;
const outdir = process.argv[2] ?? "/tmp/opencode/fv301-shots";

if (!WAKE_URL || !STATUS_URL) {
  console.error("FV_WAKE_URL and FV_STATUS_URL required (full URLs)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function shot(path, url, colorScheme) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    colorScheme,
  });
  const page = await ctx.newPage();
  const resp = await page.goto(url, { waitUntil: "networkidle" });
  console.log(path, "→", resp.status());
  await page.screenshot({ path: `${outdir}/${path}`, fullPage: true });
  await ctx.close();
}

// The modes to capture, comma-separated: wake-light, wake-dark,
// status-light. The wake arm lands `:error` when the local cluster
// can't scale the seeded instance (no real deployment behind the row),
// so only the FIRST wake capture per :sleeping reset renders the true
// sleeping-arm page — run one wake mode per reset. status-light is the
// default: it needs no reset.
const modes = (process.env.FV_MODES ?? "status-light").split(",");

for (const mode of modes) {
  switch (mode.trim()) {
    case "wake-light":
      await shot("wake-light.png", WAKE_URL, "light");
      break
    case "wake-dark":
      await shot("wake-dark.png", WAKE_URL, "dark");
      break
    case "status-light":
      await shot("status-light.png", STATUS_URL, "light");
      break
    default:
      console.error(`unknown mode: ${mode}`);
  }
}

await browser.close();
console.log("done:", outdir);
