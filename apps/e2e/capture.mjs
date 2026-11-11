/* The ONE canonical capture tool (#510 P2). Any screenshot or GIF
 * source material for a PR is captured through this — one-off capture
 * scratch never merges (it lives outside the repo, e.g. /tmp/opencode,
 * swept at lane close). Per-surface route lists are the invoker's
 * concern: loop this tool in shell, don't fork it into a script.
 *
 * Replaces the two retired kernels (screenshot.mjs, #178; and
 * access_wake_screenshot.mjs, #301) with their behaviors preserved:
 * the real sign-in POST for auth (no test backdoors — mint a session
 * token the *_seed.exs way), the phx:theme localStorage flip AND the
 * prefers-color-scheme context, networkidle + settle, full-page
 * stills, 1440x900. Self-signed TLS is accepted for local origins
 * only (localhost, *.lvh.me); deployed environments must present a
 * valid cert.
 *
 * Usage:
 *   node capture.mjs <url>... [options]
 *   node capture.mjs https://127.0.0.1:4000/about --theme dark
 *   node capture.mjs https://app.fluxvale.lvh.me/ --token "$FV_TOKEN"
 *   node capture.mjs https://app.fluxvale.lvh.me/apps --click "text=New app" --name apps-new
 *
 * Options:
 *   --out <dir>       output directory (default /tmp/opencode/capture)
 *   --name <slug>     file base name; single URL only (default: from
 *                     the URL path, e.g. /apps/forgejo -> apps-forgejo)
 *   --viewport <WxH>  default 1440x900
 *   --theme <mode>    light | dark | both (default both)
 *   --token <jwt>     session token (or FV_TOKEN env) — signs in
 *                     through POST /auth/session, then reuses the
 *                     cookie jar for every URL (same origin only;
 *                     cookies don't cross origins)
 *   --wait <ms>       settle after load, after each click, and after
 *                     the theme flip (default 300)
 *   --wait-until <e>  goto event: networkidle (default) | load |
 *                     domcontentloaded
 *   --click <sel>     click-through step (repeatable, applied in
 *                     order — to EVERY url in the run)
 *   --mask <sel>      mask the element out of the shot, pixel-level
 *                     (repeatable) — never capture a secret
 *   --viewport-shot   capture the viewport only (default: full page)
 */
import { parseArgs } from "node:util";
import { mkdirSync } from "node:fs";
import { chromium } from "@playwright/test";

const { values, positionals: urls } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: "string", default: "/tmp/opencode/capture" },
    name: { type: "string" },
    viewport: { type: "string", default: "1440x900" },
    theme: { type: "string", default: "both" },
    token: { type: "string" },
    wait: { type: "string", default: "300" },
    "wait-until": { type: "string", default: "networkidle" },
    click: { type: "string", multiple: true },
    mask: { type: "string", multiple: true },
    "viewport-shot": { type: "boolean", default: false },
    help: { type: "boolean", default: false },
  },
});

const sanitize = (slug) => slug.replace(/[^a-zA-Z0-9-]+/g, "-");

if (values.help) {
  console.log("node capture.mjs <url>... [--out dir] [--name slug] [--viewport WxH] [--theme light|dark|both] [--token jwt] [--wait ms] [--wait-until event] [--click sel]... [--mask sel]... [--viewport-shot]");
  process.exit(0);
}

if (urls.length === 0) {
  console.error("usage: node capture.mjs <url>... (see --help / the header comment)");
  process.exit(1);
}
for (const url of urls) {
  if (!/^https?:\/\//.test(url)) {
    console.error(`full URL required (got "${url}") — no implicit base, wrong-target captures are worse than typing the origin`);
    process.exit(1);
  }
}
if (!["light", "dark", "both"].includes(values.theme)) {
  console.error(`--theme must be light | dark | both (got "${values.theme}")`);
  process.exit(1);
}
const viewport = /^(\d+)x(\d+)$/.exec(values.viewport);
if (!viewport) {
  console.error(`--viewport must be <WxH>, e.g. 1440x900 (got "${values.viewport}")`);
  process.exit(1);
}
const settle = Number(values.wait);
if (!Number.isInteger(settle) || settle < 0) {
  console.error(`--wait must be a non-negative integer of ms (got "${values.wait}")`);
  process.exit(1);
}
if (!["networkidle", "load", "domcontentloaded"].includes(values["wait-until"])) {
  console.error(`--wait-until must be networkidle | load | domcontentloaded (got "${values["wait-until"]}")`);
  process.exit(1);
}
if (values.name) {
  values.name = sanitize(values.name);
}
if (values.name && urls.length > 1) {
  console.error("--name needs a single URL (multi-URL runs derive names from each path)");
  process.exit(1);
}
// "--token $FV_TOKEN" with the env unset must not fall through to
// anonymous captures labeled authenticated — the #178 kernel refused
// an absent token by construction.
if (values.token === "") {
  console.error("--token passed empty (unset env?) — omit it for public pages, pass a real one for authenticated");
  process.exit(1);
}
const token = values.token ?? process.env.FV_TOKEN ?? "";

// The local stack serves self-signed Traefik TLS; everywhere else a
// valid cert is part of the capture's honesty. Same gate as the
// suite's config (ignoreHTTPSErrors: isLocal).
const isLocalOrigin = (url) => {
  const host = new URL(url).hostname;
  return (
    host === "localhost" ||
    host === "127.0.0.1" ||
    host === "[::1]" ||
    host.endsWith(".lvh.me")
  );
};
const insecure = urls.every(isLocalOrigin);
if (token) {
  const origins = new Set(urls.map((url) => new URL(url).origin));
  if (origins.size > 1) {
    console.error(`token given with ${origins.size} distinct origins — session cookies are per-origin; run once per origin`);
    process.exit(1);
  }
}

const modes = values.theme === "both" ? ["light", "dark"] : [values.theme];
const outdir = values.out;
mkdirSync(outdir, { recursive: true });

// Multi-URL runs may repeat a path across origins; suffix only the
// actual collisions so single-URL names stay clean, and re-check every
// candidate (t, t, t-1 must not produce two t-1 files).
const names = urls.map((url) => ({ url, name: values.name ?? null }));
for (const entry of names) {
  if (entry.name) continue;
  const path = new URL(entry.url).pathname.replace(/^\/+|\/+$/g, "");
  entry.name = path === "" ? "root" : path.split("/").join("-");
}
const taken = new Set();
for (const entry of names) {
  const base = entry.name;
  let candidate = base;
  let n = 0;
  while (taken.has(candidate)) {
    n += 1;
    candidate = `${base}-${n}`;
  }
  entry.name = candidate;
  taken.add(candidate);
}

const browser = await chromium.launch();
try {
  // One context per mode (fresh localStorage, correct
  // prefers-color-scheme — the #301 media-query posture); within it,
  // the session cookie established once covers every URL (the #178
  // posture).
  for (const mode of modes) {
    const ctx = await browser.newContext({
      viewport: { width: Number(viewport[1]), height: Number(viewport[2]) },
      colorScheme: mode,
      ignoreHTTPSErrors: insecure,
    });
    const page = await ctx.newPage();

    if (token) {
      const origin = new URL(urls[0]).origin;
      await page.goto(`${origin}/sign-in`, { waitUntil: values["wait-until"] });
      const csrf = await page
        .locator('meta[name="csrf-token"]')
        .getAttribute("content");
      const resp = await page.request.post(`${origin}/auth/session`, {
        form: { token },
        headers: { "x-csrf-token": csrf ?? "" },
      });
      // Success redirects to /, failure back to /sign-in — follow and
      // see where it lands; a silent failure would ship anonymous
      // captures labeled as authenticated.
      if (new URL(resp.url()).pathname !== "/") {
        console.error(`sign-in failed (${resp.status()}, landed on ${resp.url()}) — mint a fresh token the *_seed.exs way`);
        process.exit(1);
      }
      console.log(`signed in (${mode})`);
    } else {
      // Always say which auth state the captures ride — an anonymous
      // run must never read as authenticated pages (#312's rule).
      console.log(`anonymous context, no token (${mode})`);
    }

    for (const { url, name } of names) {
      const resp = await page.goto(url, { waitUntil: values["wait-until"] });
      console.log(`${url} → ${resp ? resp.status() : "(no response)"}`);
      await page.waitForTimeout(settle);

      for (const selector of values.click ?? []) {
        await page.locator(selector).first().click();
        await page.waitForTimeout(settle);
        console.log(`clicked ${selector}`);
      }

      // Flip the theme the way the toggle does; the root script owns
      // the attrs. Harmless on pages that key off prefers-color-scheme
      // only (the context already carries the right scheme).
      await page.evaluate((m) => {
        localStorage.setItem("phx:theme", m);
        document.documentElement.setAttribute("data-theme", m);
        document.documentElement.setAttribute("data-theme-source", "user");
      }, mode);
      await page.waitForTimeout(settle);

      // A mask selector that matches nothing masks nothing — Playwright
      // is fail-open here, and this tool's mask exists for the
      // never-capture-a-secret rule. A typo must fail loudly, not ship
      // the secret.
      for (const selector of values.mask ?? []) {
        if ((await page.locator(selector).count()) === 0) {
          console.error(`--mask "${selector}" matches nothing on ${url} — refusing to capture unmasked`);
          process.exit(1);
        }
      }
      const masks = (values.mask ?? []).map((selector) => page.locator(selector).first());
      const file = `${outdir}/${name}-${mode}.png`;
      await page.screenshot({
        path: file,
        fullPage: !values["viewport-shot"],
        mask: masks,
      });
      console.log(`captured ${file}`);
    }

    await ctx.close();
  }
} finally {
  await browser.close();
}
