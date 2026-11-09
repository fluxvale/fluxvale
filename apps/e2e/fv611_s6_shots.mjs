/* #611 S6 capture: the authenticated app page (/apps/forgejo) at parity
 * with the public catalog page, light and dark, desktop and mobile.
 * Signs in through the sanctioned session POST with a dev-minted JWT
 * (FV_TOKEN, see AshAuthentication.Jwt.token_for_user/1) — no test
 * backdoor. The committed artifacts live under docs/screenshots/<pr>/;
 * pass that dir as argv[2].
 *
 *   FV_TOKEN=<jwt> FV_BASE=http://127.0.0.1:4002 \
 *     node apps/e2e/fv611_s6_shots.mjs /tmp/opencode/fv611-s6-shots
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const token = process.env.FV_TOKEN ?? "";
const OUT = process.argv[2] ?? "/tmp/opencode/fv611-s6-shots";

if (!token) {
  console.error("missing FV_TOKEN (mint one with AshAuthentication.Jwt.token_for_user/1)");
  process.exit(1);
}

mkdirSync(OUT, { recursive: true });

const viewports = [
  { name: "1440", width: 1440, height: 900 },
  { name: "390", width: 390, height: 844 },
];

const browser = await chromium.launch();

for (const vp of viewports) {
  for (const scheme of ["light", "dark"]) {
    const ctx = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
      userAgent: "fluxvale-capture/611-s6",
    });
    const page = await ctx.newPage();

    await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
    const resp = await page.request.post(`${BASE}/auth/session`, {
      form: { token },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    });
    if (!resp.ok() && resp.status() !== 302) {
      console.error(`session write failed: ${resp.status()} ${await resp.text()}`);
      process.exit(1);
    }

    await page.goto(`${BASE}/apps/forgejo`, { waitUntil: "networkidle" });
    await page.evaluate((mode) => {
      localStorage.setItem("phx:theme", mode);
      document.documentElement.setAttribute("data-theme", mode);
      document.documentElement.setAttribute("data-theme-source", "user");
    }, scheme);
    await page.waitForTimeout(400);

    // The session POST leaves a "Signed in" flash on the first render —
    // the page, not the toast, is the capture.
    for (const kind of ["info", "error"]) {
      const close = page.locator(`#flash-${kind} button[aria-label='close']`);
      if (await close.count()) {
        await close.click();
        await page.locator(`#flash-${kind}`).waitFor({ state: "detached" });
      }
    }

    const h1 = await page.locator("h1").first().innerText();
    if (!/hosting$/.test(h1)) {
      console.error(`unexpected H1 on /apps/forgejo: ${h1}`);
      process.exit(1);
    }

    await page.screenshot({
      path: `${OUT}/apps-forgejo-${vp.name}-${scheme}.png`,
      fullPage: true,
    });
    console.log(`captured apps-forgejo-${vp.name}-${scheme}.png`);
    await ctx.close();
  }
}

await browser.close();
