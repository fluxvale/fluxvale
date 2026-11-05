/* The de-socialized org creation page (#408): one input, the name, and
 * the address derived live beneath it. Local dev target only, driven by
 * a minted session JWT passed via FV_TOKEN (org_new_seed.exs; the
 * script POSTs it to /auth/session to mint the cookie it keeps);
 * light + dark. The captures type a name and hold — never submit — so
 * the motion GIF (org_new_gif.mjs) carries the derivation story.
 *
 * Usage: node org_new_screenshot.mjs <outdir>   (FV_TOKEN=<jwt>)
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv408-shots";
mkdirSync(outdir, { recursive: true });

const token = process.env.FV_TOKEN ?? "";
if (!token) {
  console.error("FV_TOKEN required");
  process.exit(1);
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

// Session through the real endpoint, then reuse the cookie jar.
await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
await page.request.post(`${BASE}/auth/session`, {
  form: { token },
  headers: { "x-csrf-token": csrf },
});

for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/organizations/new`, { waitUntil: "networkidle" });
  await page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]")?.classList.contains("phx-connected"),
    null,
    { timeout: 15_000 },
  );

  // Type the name and wait out the validate round trip so the preview
  // reads the derived address (client-side only, no submit).
  await page.getByTestId("org-new-name-input").fill("Acme Robotics");
  await page
    .getByTestId("slug-preview")
    .waitFor({ state: "visible" });
  await page
    .getByTestId("slug-preview")
    .filter({ hasText: "/organizations/acme-robotics" })
    .waitFor({ timeout: 10_000 });

  // Flip the theme the way the toggle does; the root script owns the attrs.
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${outdir}/org-new-${mode}.png`, fullPage: true });
  console.log(`captured org-new-${mode}.png`);
}

await browser.close();
