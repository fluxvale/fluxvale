/* #679 slice 1 captures: the file-access panel's quick-start now
 * states Kavita's folder-layout contract — the source-folder note (one
 * subfolder per book or series) and the after-upload note naming the
 * concrete Kavita path. One storybook story surface, light and dark.
 * Every shot waits on the component's own markup (.mono-panel) after
 * its goto: a bounce or a 500 can never masquerade as evidence.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node fv679s1_shots.mjs <outdir>
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4179";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv679s1-shots";

if (!TOKEN) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function signIn(page) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const res = await page.request.post(`${BASE}/auth/session`, {
    form: { token: TOKEN },
    headers: { "x-csrf-token": csrf },
  });
  if (res.url().includes("/sign-in")) {
    console.error("sign-in failed — check FV_TOKEN_ADMIN");
    process.exit(1);
  }
}

async function setTheme(page, mode) {
  // The storybook's layout does not load the app's theme hook —
  // localStorage and a bare data-theme flip only half-apply here (the
  // app's colors transition, storybook chrome stays light). The
  // storybook's own color-mode dropdown is the working mechanism;
  // the mode argument matches its Light/Dark options.
  await page.locator("button", { hasText: "Pick a color mode" }).first().click();
  const dropdown = page.locator("#psb-colormode-dropdown");
  await dropdown.waitFor();
  await dropdown.locator("a", { hasText: mode }).first().click();
  await page.waitForTimeout(500);
}

// fullPage stays viewport-sized here — the storybook scrolls in an
// inner container, so the after-upload note falls below the fold.
// The component root (.mono-panel) holds every step and both shared
// notes; shooting the element keeps the whole contract in frame.
for (const mode of ["light", "dark"]) {
  const modeCtx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const modePage = await modeCtx.newPage();
  await signIn(modePage);
  await modePage.goto(`${BASE}/storybook/components/dav_snippet`, { waitUntil: "networkidle" });
  const panel = modePage.locator(".mono-panel").first();
  await panel.waitFor();
  await setTheme(modePage, mode);
  await panel.screenshot({ path: `${outdir}/kavita-layout-note-${mode}.png` });
  console.log(`captured kavita-layout-note-${mode}.png`);
  await modeCtx.close();
}

await browser.close();
console.log("done");
