// Local wake-page capture for the private-access proof (#273).
//
// Unlike the #301 capture helper, this one talks to the local proof's
// live endpoint directly and tolerates the local self-signed Traefik
// certificate; the app hostname is mapped to 127.0.0.1 because this box
// has no wildcard *.lvh.me resolver. It waits for the waking-page
// test id instead of networkidle so the page's 2s meta refresh does not
// race the screenshot.
//
// Usage: node access_wake_local_proof.mjs <wake-url> <outdir> <light|dark>
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { URL } from "node:url";

const [wakeUrl, outdir, mode = "light"] = process.argv.slice(2);

if (!wakeUrl || !outdir) {
  console.error("usage: node access_wake_local_proof.mjs <wake-url> <outdir> <light|dark>");
  process.exit(2);
}

mkdirSync(outdir, { recursive: true });

const parsed = new URL(wakeUrl);
const localHosts = new Set(["localhost", "127.0.0.1", "::1"]);
const args = localHosts.has(parsed.hostname)
  ? []
  : [`--host-resolver-rules=MAP ${parsed.hostname} 127.0.0.1`];

const browser = await chromium.launch({ args });
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  colorScheme: mode === "dark" ? "dark" : "light",
  ignoreHTTPSErrors: true,
});
const page = await context.newPage();

const response = await page.goto(wakeUrl, { waitUntil: "domcontentloaded" });
await page.waitForSelector('[data-testid="access-waking-page"]', { timeout: 15000 });

const path = `${outdir}/private-access-wake-${mode}.png`;
await page.screenshot({ path, fullPage: true });

console.log(`${path} ← HTTP ${response.status()} ${wakeUrl} (${mode})`);

await browser.close();
