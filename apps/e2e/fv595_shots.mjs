/* The resource console's captures (#595 slice 1: reads; slice 2: the
 * write surfaces and the domain-grouped sidebar). Every shot waits on
 * the page's own testid after its goto: a bounce or a 500 can never
 * masquerade as evidence. The show page rides the first flag row's
 * View link, read from the DOM — no hardcoded ids.
 *
 * Parts (second argv): stills (default) captures the read surfaces,
 * the write surfaces, and the sidebar with its open domain group —
 * light and dark. pricing captures slice 3's Pricing and Billing
 * surfaces (both indexes, the size create form, the waiver and
 * goodwill forms) — light and dark. gif-light / gif-dark each record
 * the confirm-then-destroy motion on the seed's sacrificial
 * write_path_demo row (recordVideo -> ffmpeg, cropped to the content
 * column right of the sidebar); re-run the seed between the two.
 *
 * Usage: FV_TOKEN_ADMIN=<jwt> node fv595_shots.mjs <outdir> [part]
 * Token: mint with a dev `mix run` one-off —
 *   mix run -e 'alias AshAuthentication.Jwt; alias FluxVale.Identity.User;
 *     {:ok, token, _} = Jwt.token_for_user(User.get_by_email!("admin@fluxvale.com", authorize?: false)); IO.puts(token)'
 * Rows: mix run ../e2e/fv595_seed.exs first (idempotent).
 */
import { chromium } from "@playwright/test";
import { mkdirSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4111";
const TOKEN = process.env.FV_TOKEN_ADMIN;
const outdir = process.argv[2] ?? "/tmp/opencode/fv595-shots";
const part = process.argv[3] ?? "stills";

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
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

async function shot(page, name, mode, waitOn) {
  await page.waitForSelector(waitOn);
  await setTheme(page, mode);
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage: true });
  console.log(`captured ${name}.png`);
}

// The first flag row's View link href, read from the DOM.
async function firstFlagHref(page) {
  await page.goto(`${BASE}/admin/resources/ops/feature_flag`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-resource-index']");
  return page.evaluate(() => {
    const row = document.querySelector("[data-testid^='admin-resource-view-']");
    return row ? row.getAttribute("href") : null;
  });
}

// The sacrificial row's View link (the seed's write_path_demo).
async function demoFlagHref(page) {
  await page.goto(`${BASE}/admin/resources/ops/feature_flag`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-resource-index']");
  return page.evaluate(() => {
    const cell = [...document.querySelectorAll("span")].find((n) =>
      n.textContent.trim() === "write_path_demo",
    );
    if (!cell) return null;
    const row = cell.closest("tr");
    const link = row && row.querySelector("[data-testid^='admin-resource-view-']");
    return link ? link.getAttribute("href") : null;
  });
}

// The first wallet row's View link href (wallets exist by org
// provisioning — no wallet seeding needed).
async function firstWalletHref(page) {
  await page.goto(`${BASE}/admin/resources/billing/wallet`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-resource-index']");
  return page.evaluate(() => {
    const row = document.querySelector("[data-testid^='admin-resource-view-']");
    return row ? row.getAttribute("href") : null;
  });
}

if (part === "pricing") {
  // Slice 3's Pricing + Billing surfaces. Seeds first (sizes, a tax
  // rate): mix run ../e2e/fv595_seed.exs. Wallets and ledger rows ride
  // the canonical org provisioning.
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page);

  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}/admin/resources/pricing/size`, { waitUntil: "networkidle" });
    await shot(page, `pricing-size-index-${mode}`, mode, "[data-testid='admin-resource-index']");
    await page.goto(`${BASE}/admin/resources/pricing/tax_rate`, { waitUntil: "networkidle" });
    await shot(page, `pricing-tax-index-${mode}`, mode, "[data-testid='admin-resource-index']");
    await page.goto(`${BASE}/admin/resources/pricing/size/new`, { waitUntil: "networkidle" });
    await shot(page, `pricing-size-form-${mode}`, mode, "[data-testid='admin-resource-form']");
    await page.goto(`${BASE}/admin/resources/billing/wallet`, { waitUntil: "networkidle" });
    await shot(page, `billing-wallet-index-${mode}`, mode, "[data-testid='admin-resource-index']");
    await page.goto(`${BASE}/admin/resources/billing/ledger_entry`, {
      waitUntil: "networkidle",
    });
    await shot(
      page,
      `billing-ledger-index-${mode}`,
      mode,
      "[data-testid='admin-resource-index']",
    );
    await page.goto(`${BASE}/admin/resources/billing/ledger_entry/new`, {
      waitUntil: "networkidle",
    });
    await shot(
      page,
      `billing-goodwill-form-${mode}`,
      mode,
      "[data-testid='admin-resource-form']",
    );
  }

  // The waiver form on a wallet's edit mount: the registry-exposed
  // write surface, a lone checkbox over the record's own inputs.
  const walletHref = await firstWalletHref(page);
  if (!walletHref) {
    console.error("no wallet rows — the dev DB needs its canonical seeds");
    process.exit(1);
  }
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${walletHref}/edit?action=set_waiver`, {
      waitUntil: "networkidle",
    });
    await shot(page, `billing-waiver-form-${mode}`, mode, "[data-testid='admin-resource-form']");
  }

  await ctx.close();
}

if (part === "stills") {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page);

  for (const mode of ["light", "dark"]) {
    // Slice 1's read set.
    await page.goto(`${BASE}/admin/resources`, { waitUntil: "networkidle" });
    await shot(page, `resources-domains-${mode}`, mode, "[data-testid='admin-resources-domains']");
    await page.goto(`${BASE}/admin/resources/ops`, { waitUntil: "networkidle" });
    await shot(page, `resources-ops-domain-${mode}`, mode, "[data-testid='admin-resources-domain']");
    await page.goto(`${BASE}/admin/resources/ops/feature_flag`, { waitUntil: "networkidle" });
    await shot(page, `resources-flags-${mode}`, mode, "[data-testid='admin-resource-index']");
    await page.goto(`${BASE}/admin/resources/ops/access_rule`, { waitUntil: "networkidle" });
    await shot(page, `resources-rules-${mode}`, mode, "[data-testid='admin-resource-index']");

    // Slice 2's write surfaces.
    await page.goto(`${BASE}/admin/resources/ops/feature_flag/new`, {
      waitUntil: "networkidle",
    });
    await shot(page, `resources-create-form-${mode}`, mode, "[data-testid='admin-resource-form']");

    // The sidebar's open domain group on a resource index (D3 revised).
    await page.goto(`${BASE}/admin/resources/ops/feature_flag`, { waitUntil: "networkidle" });
    await shot(
      page,
      `resources-sidebar-group-${mode}`,
      mode,
      "[data-testid='admin-sidebar-domain-ops'][open]",
    );
  }

  // The edit form with an inline validation error: type 150 into the
  // rollout input, phx-change renders the constraint error inline.
  const href = await firstFlagHref(page);
  if (!href) {
    console.error("no flag rows — run mix run ../e2e/fv595_seed.exs first");
    process.exit(1);
  }
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${href}/edit`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-resource-input-rollout_percentage'] input");
    await page.fill("[data-testid='admin-resource-input-rollout_percentage'] input", "150");
    await page.waitForSelector("p:has-text('must be less than or equal to')");
    await setTheme(page, mode);
    await page.screenshot({ path: `${outdir}/resources-edit-error-${mode}.png`, fullPage: true });
    console.log(`captured resources-edit-error-${mode}.png`);
  }

  // The destroy confirm open on the show page (no confirm click — the
  // record survives the stills).
  for (const mode of ["light", "dark"]) {
    await page.goto(`${BASE}${href}`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-resource-show']");
    await page.click("[data-testid='admin-resource-destroy-destroy']");
    await shot(page, `resources-destroy-confirm-${mode}`, mode, "[data-testid='destructive-confirm']");
  }

  await ctx.close();
} else if (part === "gif-light" || part === "gif-dark") {
  // The confirm-then-destroy motion on the sacrificial row. Crop to
  // the content column right of the sidebar: the panel reveals there,
  // the flash and the index navigation land there. The sign-in rides a
  // separate plain context first and its cookies carry over via
  // storageState, so the recording starts on the record's own page —
  // a sign-in flash at the head of the GIF is capture noise.
  const mode = part === "gif-dark" ? "dark" : "light";
  const authCtx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const authPage = await authCtx.newPage();
  await signIn(authPage);
  const state = await authCtx.storageState();
  await authCtx.close();

  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: outdir, size: { width: 1440, height: 900 } },
    storageState: state,
  });
  const page = await ctx.newPage();
  await page.addInitScript(
    (m) => localStorage.setItem("phx:theme", m),
    mode,
  );

  const demoHref = await demoFlagHref(page);
  if (!demoHref) {
    console.error("no write_path_demo row — run mix run ../e2e/fv595_seed.exs first");
    process.exit(1);
  }

  await page.goto(`${BASE}${demoHref}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-resource-show']");

  const sidebar = await page
    .locator("[data-testid='admin-sidebar']")
    .evaluate((n) => Math.round(n.getBoundingClientRect().right));

  await page.click("[data-testid='admin-resource-destroy-destroy']");
  await page.waitForSelector("[data-testid='destructive-confirm']");
  await page.waitForTimeout(700);
  await page.click("[data-testid='admin-resource-destroy-confirm']");
  await page.waitForURL(/\/admin\/resources\/ops\/feature_flag$/, { timeout: 10_000 });
  await page.waitForSelector("[data-testid='admin-resource-index']");
  await page.waitForTimeout(900);

  const video = page.video();
  await ctx.close();
  const webm = await video.path();

  const x = Math.min(1439, sidebar + 16);
  const w = 1440 - x;
  // The crop runs AFTER scale=720, so the offset rides in the scaled
  // frame's coordinates: drop the sidebar, keep the content column.
  const cropX = Math.round((x * 720) / 1440);
  const cropW = Math.round((w * 720) / 1440);
  const out = `${outdir}/resources-destroy-motion-${mode}.gif`;
  execFileSync("ffmpeg", [
    "-y",
    "-i", webm,
    "-vf", `fps=12,scale=720:-1:flags=lanczos,crop=${cropW}:ih:${cropX}:0`,
    out,
  ]);
  unlinkSync(webm);
  console.log(`captured resources-destroy-motion-${mode}.gif`);
}

await browser.close();
console.log("done");
