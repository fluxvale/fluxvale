// S7 capture (issue #611, runbook §4 Phase B): two 1440x900 frames per
// app from the app's persistent profile. A shot that lands on a login
// or setup route fails the run and writes nothing — the browser
// context still closes (throw, not exit).
// Usage: node s7_capture.mjs <slug> <url1> <url2> <outdir> [screen1] [screen2]
// screen names default to the URL's last path segment; the runbook §3
// names win when given explicitly.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const [slug, url1, url2, outdir, name1, name2] = process.argv.slice(2);
if (!slug || !url1 || !url2 || !outdir) {
  console.error("usage: node s7_capture.mjs <slug> <url1> <url2> <outdir> [screen1] [screen2]");
  process.exit(2);
}

const shotName = (url, name) => {
  if (name) return name.endsWith(".png") ? name : `${name}.png`;
  const seg = new URL(url).pathname.split("/").filter(Boolean).pop() ?? "screen";
  return seg.endsWith(".png") ? seg : `${seg}.png`;
};

const targets = [
  { url: url1, screen: shotName(url1, name1) },
  { url: url2, screen: shotName(url2, name2) },
];

// Logged-out / setup markers across the nine apps. Any hit means the
// profile's session died and the capture must fail loudly. Hash-router
// clients keep the base URL, so the lock/unlock routes are matched on
// the hash too — plus a content-level check below, because route
// matching alone is not enough for them.
const LOGGED_OUT = [
  /\/user\/login/, /\/user\/sign_up/, // forgejo
  /\/sign_in/, // generic
  /\/_signup/, /\/login/, // memos, vikunja
  /#\/register/, /#\/login/, /#\/signin/, // hash routers (vaultwarden, kavita)
  /#\/lock/, /#\/unlock/, // vaultwarden locked vault (master-password prompt)
  /\/setup/, /\/instances\/setup/, // docmost, pocket-id setup
  /\/settings\/password/, // actualbudget first-run claim
];

// Content-level logged-out / locked markers: text the page shows when
// a session gate is up, matched regardless of URL.
const LOGGED_OUT_TEXT = [
  /enter your master password/i, // vaultwarden lock screen
  /your vault is locked/i, // vaultwarden lock heading
];

const profile = `/tmp/opencode/s7-profiles/${slug}`;
mkdirSync(`${outdir}/${slug}`, { recursive: true });

const context = await chromium.launchPersistentContext(profile, {
  viewport: { width: 1440, height: 900 },
  userAgent: "fluxvale-capture/611-s7",
  ignoreHTTPSErrors: true,
});
const page = context.pages()[0] ?? (await context.newPage());

try {
  for (const { url, screen } of targets) {
    // networkidle never settles on apps that keep SSE or long-poll
    // connections open (Forgejo does), so goto on load and give
    // networkidle a best-effort window before the fixed settle.
    await page.goto(url, { waitUntil: "load", timeout: 60_000 }).then((r) => {
      // goto resolves on load even for 4xx/5xx — a screenshot of an
      // error page would sail through the logged-out gates.
      if (r && r.status() >= 400) throw new Error(`${slug}/${screen}: navigation returned HTTP ${r.status()}`);
    });
    await Promise.race([
      page.waitForLoadState("networkidle").catch(() => {}),
      page.waitForTimeout(8_000),
    ]);
    await page.waitForTimeout(600);

    const landed = page.url();
    if (LOGGED_OUT.some((re) => re.test(landed))) {
      throw new Error(`${slug}/${screen}: landed on a login or setup route: ${landed}`);
    }
    // SPA hash routers keep the base URL; check the DOM too.
    const bodyText = (await page.locator("body").innerText().catch(() => "")).slice(0, 4000);
    const domLoggedOut = /\b(sign in|log in)\b.{0,40}\bpassword\b/i.test(bodyText) ||
      /\bcreate your account\b/i.test(bodyText) ||
      /\bdoes not exist, has been removed\b/i.test(bodyText) || // forgejo 404 (private repo, logged out)
      (await page.locator("a[href^='/user/login']").count()) > 0 || // forgejo header when signed out
      LOGGED_OUT_TEXT.some((re) => re.test(bodyText)); // locked-vault prompts
    if (domLoggedOut) {
      throw new Error(`${slug}/${screen}: page renders a login, signup, or lock form`);
    }

    await page.screenshot({ path: `${outdir}/${slug}/${screen}` });
    console.log(`captured ${slug}/${screen}`);
  }
} finally {
  await context.close();
}
