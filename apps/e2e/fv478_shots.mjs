/* fv478 captures: the invitation gate's user-visible surface — the
 * sign-in email step (the honest early-access hint) and the honest-copy
 * wall an uninvited external address hits at verify. Light AND dark,
 * labelled before/after via FV_LABEL (before = clean main's sign-in).
 *
 * Requires the branch server (FV_BASE_AFTER) with TEST_INBOX_ENABLED
 * and the capture credential from fv478_seed.exs
 * (FV_TESTINBOX_TOKEN). The before label needs no credentials.
 *
 * Usage: FV_BASE_AFTER=http://127.0.0.1:4000 FV_BASE_BEFORE=http://127.0.0.1:4001 \
 *   FV_LABEL=after [FV_TESTINBOX_TOKEN=pat] node fv478_shots.mjs <outdir>
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const AFTER = process.env.FV_BASE_AFTER ?? "http://127.0.0.1:4000";
const BEFORE = process.env.FV_BASE_BEFORE ?? "";
const label = process.env.FV_LABEL ?? "after";
const inboxToken = process.env.FV_TESTINBOX_TOKEN ?? "";
const outdir = process.argv[2] ?? `/tmp/opencode/fv478-${label}`;
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch();

async function themedPage(mode, base) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    reducedMotion: "reduce",
  });
  await ctx.addInitScript((t) => localStorage.setItem("phx:theme", t), mode);
  const page = await ctx.newPage();
  return { ctx, page };
}

async function still(name, mode, drive) {
  const { ctx, page } = await themedPage(mode);
  await drive(page, ctx);
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${outdir}/${name}-${mode}.png`, fullPage: true });
  await ctx.close();
  console.log(`captured ${name}-${mode}`);
}

// The plain email step: before has no hint, after carries the honest one.
const emailStep = (base) => async (page) => {
  await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
};

// The wall: request a code for an uninvited external address, read the
// login code from the TestInbox, verify — the honest copy is the
// refusal. A fresh address per call: the refused verify burns the login
// code, and a same-address retry would land in the resend throttle.
const wall = (base) => async (page, ctx) => {
  const address = `fv478-wall-${Date.now()}-${Math.floor(Math.random() * 1000)}@partner.example`;
  await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
  await page.fill("input[name='email']", address);
  await page.click("[data-testid='send-code']");
  await page.waitForSelector("#code-form");

  const resp = await ctx.request.get(`${base}/test-inbox/api/mails/latest`, {
    params: { email: address },
    headers: { authorization: `Bearer ${inboxToken}` },
  });
  if (!resp.ok()) throw new Error(`TestInbox ${resp.status()}: ${await resp.text()}`);
  const { mail } = await resp.json();
  if (!/^\d{6}$/.test(mail?.code ?? "")) throw new Error(`no code in mail: ${JSON.stringify(mail)}`);

  await page.fill("input[name='code']", mail.code);
  await page.click("[data-testid='verify-code']");
  await page.waitForSelector("text=invitation-only early access");
};

if (label === "before") {
  if (!BEFORE) throw new Error("before label needs FV_BASE_BEFORE");
  await still("before-email", "light", emailStep(BEFORE));
  await still("before-email", "dark", emailStep(BEFORE));
} else {
  await still("after-email", "light", emailStep(AFTER));
  await still("after-email", "dark", emailStep(AFTER));

  if (!inboxToken) throw new Error("after label needs FV_TESTINBOX_TOKEN for the wall stills");
  await still("after-wall", "light", wall(AFTER));
  await still("after-wall", "dark", wall(AFTER));
}

await browser.close();
