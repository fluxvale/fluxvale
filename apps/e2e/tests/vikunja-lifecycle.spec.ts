import { randomBytes } from "node:crypto";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// Vikunja's full customer lifecycle through the real UI (#610),
// mirroring memos-lifecycle (the SQLite single-volume sibling): sign
// in via TestInbox → catalog → deploy (filling the one optional input
// — the session secret that keeps sign-ins alive across restarts; the
// Pocket ID provider inputs ride their defaults — the display name
// arrives pre-filled, everything else empty, inert while the toggle
// stays off) → running → instance URL serves Vikunja over HTTPS →
// /health answers 200 OK → /api/v1/info reports v2.8.0, registration
// open, and concurrent_writes false (the SQLite honesty fact pinned
// in the listing's caveats) → register (the first registrant is NOT
// admin — the JWT carries is_admin false, the no-contract posture) →
// stop → start → the token issued before the stop still works (the
// session secret held + the SQLite user row survived on the PVC) →
// destroy. It crosses the real cluster — `running` lands on the
// reconcile cron's next tick after pod readiness, and a cold node
// pulls the Vikunja image first — so the waits are generous
// (ADR-00024 §6).

// Traces are off for this spec only (the pocket-id posture): CI
// uploads the playwright report as a public artifact, and the session
// secret and the account password would land in it on a red→green
// retry. The spec carries its own budgets and fail-fast error states.
test.use({ trace: "off" });

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// Local + staging runtimes (#116: staging is instance-capable). Production
// stays read-only (ADR-0024): the suite never mutates it.
test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test(
  "vikunja: catalog → deploy → running → open → register → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min: the budgets below (12 + 1 + 5) plus sign-in, catalog,
    // deploy, and destroy interactions must fit under the cap.
    test.setTimeout(20 * 60_000);

    // The one optional deploy input: keeps sessions signed in across
    // restarts (upstream mints a fresh random secret per boot when
    // unset). The restart leg below proves it works.
    const sessionSecret = randomBytes(24).toString("base64");
    const password = `e2e-${randomBytes(16).toString("hex")}`;

    // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
    // gets touched, and the instances list starts empty)
    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Catalog → Vikunja. `micro` at B′ — the honest recommendation
    // (#610: a single Go binary over SQLite, verified booting and
    // idling tiny on a fresh cluster) plus its own 5 GB storage
    // default — $2.83/mo, stated as a monthly-equivalent, billed
    // hourly.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
    await page.getByTestId("app-vikunja").click();
    await expect(
      page.getByRole("heading", { name: "Vikunja", exact: true }),
    ).toBeVisible();
    await waitForLiveViewJoin(page);
    await expect(page.locator("[data-testid^='price-']").first()).toContainText(
      "$2.83/mo · billed hourly",
    );

    // Deploy stepper: version → configuration (the session secret is
    // filled; the Pocket ID provider inputs ride their defaults — the
    // display name arrives pre-filled with "Pocket ID", everything
    // else empty, inert while VIKUNJA_AUTH_OPENID_ENABLED is false) →
    // resources at the recommendation → name.
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await page.locator("#env-form").waitFor({ state: "visible" });
    await page.locator("#env-VIKUNJA_SERVICE_SECRET").fill(sessionSecret);
    await page.getByTestId("continue-env").click();
    await expect(page.getByTestId("resources-price")).toContainText(
      "$2.83/mo · billed hourly",
    );
    await page.getByTestId("continue-resources").click();
    await expect(page.getByTestId("price-summary")).toContainText(
      "$2.83/mo · billed hourly",
    );
    const name = `e2e-vikunja-${runId}`;
    await page.getByTestId("instance-name").fill(name);
    await page.getByTestId("deploy-submit").click();

    // Status page: Provisioning → Starting → Running (live badge; no
    // polling in-page — PubSub re-renders, this loop just reads).
    await page.waitForURL(/\/instances\//);
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    await expect(page.getByTestId("instance-price")).toContainText(
      "$2.83/mo · billed hourly",
    );

    // The instance URL opens through Traefik (self-signed — ignored
    // at the config level) and serves the actual Vikunja app.
    // Vikunja's frontend is a client-rendered Vue SPA: the served
    // HTML is an empty shell, so the identity proof is upstream's own
    // public /api/v1/info and the render proof is a hydrated heading
    // in a real browser (the raw shell matches nothing).
    const url = (await page.getByTestId("instance-url").textContent())?.trim();
    expect(url).toMatch(/^https:\/\//);
    const opened = await request.get(url!);
    expect(opened.status()).toBeLessThan(400);

    // The public info endpoint carries the deployed version (the
    // pinned upstream release), the first-run posture (registration
    // open — no env lever ships to close it, the Vaultwarden
    // SIGNUPS_ALLOWED lockout stance), the SQLite honesty fact the
    // listing's caveats disclose (batch writes serialize), and the
    // untouched OIDC surface (the provider inputs stayed empty).
    const info = await request.get(new URL("api/v1/info", url!).toString());
    expect(info.status()).toBe(200);
    const instanceInfo = (await info.json()) as {
      version: string;
      concurrent_writes: boolean;
      auth: {
        local: { registration_enabled: boolean };
        openid_connect: { enabled: boolean };
      };
    };
    expect(instanceInfo.version).toBe("v2.8.0");
    expect(instanceInfo.auth.local.registration_enabled).toBe(true);
    expect(instanceInfo.concurrent_writes).toBe(false);
    expect(instanceInfo.auth.openid_connect.enabled).toBe(false);

    const ui = await page.context().newPage();
    await ui.goto(url!, { waitUntil: "networkidle", timeout: 60_000 });
    await expect(ui.locator("h1").first()).toBeVisible({ timeout: 30_000 });
    await ui.close();

    // Upstream's own liveness endpoint — an unauthenticated 200 whose
    // body is "OK" (verified from the running 2.8.0 image).
    const health = await request.get(new URL("health", url!).toString());
    expect(health.status()).toBe(200);
    expect(await health.text()).toBe("OK");

    // Register now, before the restart leg: the account row lives in
    // Vikunja's SQLite on the PVC, so after the stop / start cycle
    // the same credentials must still sign in — and the first
    // registrant is NOT admin (the runtime half of the no-contract
    // posture: the JWT payload carries is_admin false; every
    // admin-grant path is Pro-gated upstream). The instance (and its
    // volume) is destroyed at the end, so the account costs nothing.
    const registered = await request.post(
      new URL("api/v1/register", url!).toString(),
      {
        data: {
          username: `e2e-user-${runId}`,
          email: `e2e-user-${runId}@example.com`,
          password,
        },
      },
    );
    expect(registered.status()).toBeLessThan(400);

    const token = await login(request, url!, password);
    expect(isAdminClaim(token)).toBe(false);

    // Stop → Stopped (storage-only fee: micro stopped, $0.24 at B′).
    await page.getByTestId("stop-button").click();
    await waitForStatus(page, "Stopped", 60_000);
    await expect(page.getByTestId("instance-price")).toContainText(
      "$0.24/mo while stopped · billed hourly",
    );

    // … and back up: a clean restart serves the same instance (#610).
    // The restart is warm — image cached on the node, PVC in place,
    // one reconcile tick — so a much shorter budget than the cold
    // first start; a stuck restart should fail fast with its status
    // message.
    await page.getByTestId("start-button").click();
    await waitForStatus(page, "Running", 5 * 60_000);

    // The state-survival half, both facts at once: the token issued
    // before the stop still authenticates (the session secret set at
    // deploy held across the restart — without it, every boot mints a
    // fresh one and signs everyone out), and the account row itself
    // survived on the restored volume (the credentials still sign
    // in). An authenticated read proves the first; a fresh login
    // proves the second.
    const revivedUser = await request.get(
      new URL("api/v1/user", url!).toString(),
      { headers: { authorization: `Bearer ${token}` } },
    );
    expect(revivedUser.status()).toBe(200);

    const revivedToken = await login(request, url!, password);
    expect(revivedToken).toBeTruthy();

    // Destroy: native confirm() dialog, teardown (async Oban) exits
    // the view to /instances where the fresh user's list is empty
    // again.
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByTestId("delete-button").click();
    await page.waitForURL(/\/instances$/);
    await expect(page.getByTestId("instance-row")).toHaveCount(0);
  },
);

// Signs in through the public API and returns the session token.
// Vikunja's /api/v1/login answers {"token": "<jwt>"}.
async function login(
  request: import("@playwright/test").APIRequestContext,
  url: string,
  password: string,
): Promise<string> {
  const response = await request.post(new URL("api/v1/login", url).toString(), {
    data: { username: `e2e-user-${runId}`, password },
  });
  expect(response.status()).toBeLessThan(400);

  const body = (await response.json()) as { token: string };
  return body.token;
}

// Decodes the JWT's is_admin claim (the not-admin gate — Vikunja
// signs HS256 JWTs whose payload is plain base64url JSON).
function isAdminClaim(token: string): boolean {
  const payload = JSON.parse(
    Buffer.from(token.split(".")[1]!, "base64url").toString("utf8"),
  ) as { is_admin: boolean };

  return payload.is_admin;
}

// Poll the live badge until `want` shows; "Failed" fails fast with the
// status message — waiting out a dead deploy proves nothing. The badge
// reads #179's user-facing vocabulary (Running/Stopped/Failed…), never
// the internal state-machine atom.
async function waitForStatus(page: Page, want: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const status = await page
      .getByTestId("status-badge")
      .innerText({ timeout: 10_000 })
      .catch(() => null);

    if (status?.trim() === want) return;
    if (status?.trim() === "Failed") {
      const message = await page
        .getByTestId("status-message")
        .textContent()
        .catch(() => "");
      throw new Error(`instance hit error state: ${message?.trim()}`);
    }

    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  throw new Error(`status never reached "${want}" within ${timeoutMs}ms`);
}
