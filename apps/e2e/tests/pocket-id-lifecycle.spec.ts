import { expect, test, type Page } from "@playwright/test";
import { randomBytes } from "node:crypto";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// Pocket ID's full customer lifecycle through the real UI (#492),
// mirroring vaultwarden-lifecycle and forgejo-lifecycle: sign in via
// TestInbox → catalog → deploy (filling the one required input,
// ENCRYPTION_KEY) → running → instance URL serves the Pocket ID UI →
// healthz 204 → first-run claim open → stop → start → destroy. The
// restart leg is the #492 gate: Pocket ID's SQLite state on the PVC
// must survive a stop / start cycle cleanly. It crosses the real
// cluster — `running` lands on the reconcile cron's next tick after
// pod readiness, and a cold node pulls the Pocket ID image first — so
// the waits are generous (ADR-00024 §6).

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
  "pocket-id: catalog → deploy → running → open → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min: the budgets below (12 + 5) plus sign-in, catalog, deploy
    // and destroy interactions must fit under the cap.
    test.setTimeout(20 * 60_000);

    // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
    // gets touched, and the instances list starts empty)
    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Catalog → Pocket ID. `micro` at B′ — the honest recommendation
    // (#492: a single static Go binary with embedded SQLite) —
    // $2.83/mo, stated as a monthly-equivalent, billed hourly.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
    await page.getByTestId("app-pocket-id").click();
    await expect(
      page.getByRole("heading", { name: "Pocket ID", exact: true }),
    ).toBeVisible();
    await waitForLiveViewJoin(page);
    await expect(page.locator("[data-testid^='price-']").first()).toContainText(
      "$2.83/mo · billed hourly",
    );

    // Deploy stepper: version → configuration (ONE required input —
    // Pocket ID refuses to boot without its encryption key, so the
    // deploy MUST fill it; a random per-run value, rendered as dots by
    // the password input and never logged) → resources at the
    // recommendation → name. Everything else stays default: the
    // shipped recommendation must be right on its own (#492).
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await page.locator("#env-form").waitFor({ state: "visible" });
    await page.locator("#env-ENCRYPTION_KEY").fill(
      randomBytes(24).toString("base64"),
    );
    await page.getByTestId("continue-env").click();
    await expect(page.getByTestId("resources-price")).toContainText(
      "$2.83/mo · billed hourly",
    );
    await page.getByTestId("continue-resources").click();
    await expect(page.getByTestId("price-summary")).toContainText(
      "$2.83/mo · billed hourly",
    );
    const name = `e2e-pocket-id-${runId}`;
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

    // The instance URL opens through Traefik (self-signed — ignored at
    // the config level) and serves the actual Pocket ID UI, not a
    // placeholder that merely answers 200.
    const url = (await page.getByTestId("instance-url").textContent())?.trim();
    expect(url).toMatch(/^https:\/\//);
    const opened = await request.get(url!);
    expect(opened.status()).toBeLessThan(400);
    expect(await opened.text()).toMatch(/Pocket ID/i);

    // Upstream's own liveness endpoint — an unauthenticated 204 (the
    // image HEALTHCHECK probes the same route).
    const healthz = await request.get(new URL("healthz", url!).toString());
    expect(healthz.status()).toBe(204);

    // The first-run contract's runtime half (#492, ADR-0034): the
    // initial-admin setup is still claimable — upstream's public
    // probe (the SPA calls it on /setup) answers while no account
    // exists, and 404s once it is done.
    const setup = await request.get(
      new URL("api/signup/setup", url!).toString(),
    );
    expect(setup.status()).toBeLessThan(400);

    // Stop → Stopped (storage-only fee: micro stopped, $0.24 at B′).
    await page.getByTestId("stop-button").click();
    await waitForStatus(page, "Stopped", 60_000);
    await expect(page.getByTestId("instance-price")).toContainText(
      "$0.24/mo while stopped · billed hourly",
    );

    // … and back up: a clean restart serves the same instance (#492).
    // The restart is warm — image cached on the node, PVC in place, one
    // reconcile tick — so a much shorter budget than the cold first
    // start; a stuck restart should fail fast with its status message.
    await page.getByTestId("start-button").click();
    await waitForStatus(page, "Running", 5 * 60_000);
    const revived = await request.get(new URL("healthz", url!).toString());
    expect(revived.status()).toBe(204);

    // Destroy: native confirm() dialog, teardown (async Oban) exits the
    // view to /instances where the fresh user's list is empty again.
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByTestId("delete-button").click();
    await page.waitForURL(/\/instances$/);
    await expect(page.getByTestId("instance-row")).toHaveCount(0);
  },
);

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
