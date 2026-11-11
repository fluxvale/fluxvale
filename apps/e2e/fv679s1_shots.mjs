/* #679 slice 1 captures: the file-access panel's quick-start now
 * states Kavita's folder-layout contract — the source-folder note (one
 * subfolder per book or series) and the after-upload note naming the
 * instance's <mount_path>/library/books. One storybook story surface,
 * light and dark. Every shot waits on the component's own markup
 * (.mono-panel) after its goto: a bounce or a 500 can never masquerade
 * as evidence.
 *
 * Port 4179: sibling dev servers on this box claim 4000/4181; override
 * with FV_BASE.
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
  // localStorage and a bare data-theme flip only half-apply here. The
  // storybook's own color-mode dropdown is the working mechanism; the
  // mode argument matches its Light/Dark options. story_live toggles
  // the psb:dark sandbox class on <html> (dark adds it, light drops
  // it), so the flip is assertable — a broken selector can never write
  // a light PNG named -dark.png.
  await page.locator("button", { hasText: "Pick a color mode" }).first().click();
  const dropdown = page.locator("#psb-colormode-dropdown");
  await dropdown.waitFor();
  await dropdown.locator("a", { hasText: mode }).first().click();
  const wantDark = mode === "dark";
  await page.waitForFunction(
    (want) => document.documentElement.classList.contains("psb:dark") === want,
    wantDark,
    { timeout: 5000 },
  );
}

// fullPage stays viewport-sized here — the storybook scrolls in an
// inner container — and the preview column is width-constrained to a
// few hundred px, clipping the 1137px connect line mid-token at any
// viewport. Give the panel its full content width instead: un-clip the
// ancestors, fit the panel to its widest child, widen the viewport
// around it, then capture its box. Every command renders whole and
// both shared notes stay in frame.

// Idempotent: clears width/overflow constraints up the ancestor chain
// and fits the panel to its widest child.
const unclipAndFit = () => {
  const panel = document.querySelector(".mono-panel");
  let node = panel;
  while (node && node !== document.body) {
    node.style.overflow = "visible";
    node.style.maxWidth = "none";
    node = node.parentElement;
  }
  panel.style.width = "max-content";
  panel.style.minWidth = "100%";
  // mono-panel's own background is transparent in the storybook
  // sandbox (the app provides the sunken backdrop via a parent), so
  // the page behind it bleeds through once it overflows its column.
  // Give it the app's real panel token — opaque in both themes.
  panel.style.backgroundColor = "var(--panel)";
  const r = panel.getBoundingClientRect();
  return { width: r.width, height: r.height, x: r.x, y: r.y };
};

const measure = () => {
  const r = document.querySelector(".mono-panel").getBoundingClientRect();
  return { width: r.width, height: r.height, x: r.x, y: r.y };
};

// mono-panel's own background is transparent in the storybook sandbox
// (the app provides the sunken backdrop via a parent), so the sidebar
// and source pane bleed through it once it overflows their space.
// Hide everything that is neither the panel nor its ancestors — the
// capture then shows the component against the bare page background.
const isolateChrome = () => {
  const panel = document.querySelector(".mono-panel");
  const keep = new Set();
  let n = panel;
  while (n && n !== document.body) {
    keep.add(n);
    n = n.parentElement;
  }
  keep.add(panel);
  for (const el of panel.querySelectorAll("*")) keep.add(el);
  for (const el of document.body.querySelectorAll("*")) {
    if (keep.has(el)) continue; // panel ancestor or the panel itself
    if (el.contains(panel)) continue; // hiding this would hide the panel
    el.style.visibility = "hidden";
  }
};

for (const mode of ["light", "dark"]) {
  const modeCtx = await browser.newContext({ viewport: { width: 1024, height: 900 } });
  const modePage = await modeCtx.newPage();
  await signIn(modePage);
  await modePage.goto(`${BASE}/storybook/components/dav_snippet`, { waitUntil: "networkidle" });
  const panel = modePage.locator(".mono-panel").first();
  await panel.waitFor();
  await setTheme(modePage, mode);
  // max-content against fallback fonts under-measures the mono
  // command lines — wait for the real fonts before fitting.
  await modePage.evaluate(() => document.fonts.ready);

  const fitted = await modePage.evaluate(unclipAndFit);

  await modePage.setViewportSize({
    width: Math.max(1024, Math.ceil(fitted.width) + 800),
    height: Math.max(900, Math.ceil(fitted.y + fitted.height) + 200),
  });
  await modePage.waitForTimeout(300);
  await modePage.evaluate(unclipAndFit);
  await modePage.evaluate(isolateChrome);

  // The widened content column re-centers; a wider-than-column panel
  // can land at negative x, which the screenshot clamps. Nudge it into
  // the viewport with a margin, then require a settled box — the clip
  // must sit fully inside the viewport surface (overflow is visible,
  // so the surface is exactly the viewport).
  let box = await modePage.evaluate(measure);
  box = await modePage.evaluate((b) => {
    const panel = document.querySelector(".mono-panel");
    if (b.x < 0) panel.style.marginLeft = `${20 - b.x}px`;
    const r = panel.getBoundingClientRect();
    return { width: r.width, height: r.height, x: r.x, y: r.y };
  }, box);

  const settled = await modePage.evaluate(measure);
  const stable = ["x", "y", "width", "height"].every(
    (k) => Math.abs(settled[k] - box[k]) < 1,
  );
  if (!stable || box.x < 0 || box.y < 0) {
    console.error(`panel box unsettled or escaped: ${JSON.stringify({ box, settled })}`);
    process.exit(1);
  }

  await modePage.screenshot({
    path: `${outdir}/kavita-layout-note-${mode}.png`,
    clip: { x: box.x, y: box.y, width: box.width, height: box.height },
  });
  console.log(`captured kavita-layout-note-${mode}.png`);
  await modeCtx.close();
}

await browser.close();
console.log("done");
