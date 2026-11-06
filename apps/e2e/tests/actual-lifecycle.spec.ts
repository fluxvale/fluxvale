import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// ActualBudget's customer lifecycle through the real UI (#492): sign
// in via TestInbox → catalog → deploy ActualBudget → running →
// instance URL serves the sync server → the first open claims it
// (bootstrap sets the shared server password, ADR-0034 Am. 1) → stop →
// start → running again → destroy. The stop/start round-trip is the
// restart-cleanliness proof the catalog wave's bar asks for. It
// crosses the real cluster — `running` lands on the reconcile cron's
// next tick after pod readiness, and a cold node pulls the
// ~120 MB image first — so the waits stay generous (ADR-00024 §6).

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// Local + staging runtimes (#116). Production stays read-only
// (ADR-0024): the suite never mutates it.
test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test("actualbudget: catalog → deploy → running → claim → stop → start → destroy", async ({
  page,
  request,
}) => {
  test.setTimeout(18 * 60_000);

  // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
  // gets touched, and the instances list starts empty)
  const email = `test+e2e-actual-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // Catalog → ActualBudget. The entry recommends `small` (0.5 / 512 MB
  // / 10 GB), so the card's price badge carries B′'s $3.35/mo, stated
  // as a monthly-equivalent, billed hourly (#206).
  await page.goto("/apps");
  await waitForLiveViewJoin(page);
  await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
  await page.getByTestId("app-actualbudget").click();
  await expect(
    page.getByRole("heading", { name: "ActualBudget", exact: true }),
  ).toBeVisible();
  await waitForLiveViewJoin(page);
  await expect(page.locator("[data-testid^='price-']").first()).toContainText(
    "$3.35/mo · billed hourly",
  );

  // Deploy stepper: version → configuration (no configurable env — the
  // seed defaults carry) → resources (the recommendation is the
  // default; this app's honest size IS the shipped unit) → name.
  await page.locator("[data-testid^='deploy-']").first().click();
  await waitForLiveViewJoin(page);
  await page.getByTestId("version-option").first().check();
  await page.getByTestId("continue-version").click();
  await page.getByTestId("continue-env").click();
  await page.getByTestId("continue-resources").click();
  await expect(page.getByTestId("price-summary")).toContainText(
    "$3.35/mo · billed hourly",
  );
  const name = `e2e-actual-${runId}`;
  await page.getByTestId("instance-name").fill(name);
  await page.getByTestId("deploy-submit").click();

  // Status page: Provisioning → Starting → Running (live badge).
  await page.waitForURL(/\/instances\//);
  await waitForLiveViewJoin(page);
  await waitForStatus(page, "Running", 12 * 60_000);
  await expect(page.getByTestId("instance-price")).toContainText(
    "$3.35/mo · billed hourly",
  );

  // The instance URL opens through Traefik (self-signed — ignored at
  // the config level) and actually serves the sync server, not a
  // placeholder that merely answers 200: the SPA shell, the
  // dependency-free health endpoint, and an unclaimed instance.
  const url = (await page.getByTestId("instance-url").textContent())?.trim();
  expect(url).toMatch(/^https:\/\//);
  const opened = await request.get(url!);
  expect(opened.status()).toBeLessThan(400);
  expect(await opened.text()).toMatch(/Actual/i);
  const health = await request.get(new URL("health", url!).toString());
  expect(health.ok()).toBeTruthy();
  expect(await health.json()).toEqual({ status: "UP" });

  // #181's done-when, Actual's shape (ADR-0034 Am. 1): a fresh server
  // ships unclaimed and the first open sets the server password. Prove
  // the whole claim path over the wire — needs-bootstrap false, the
  // one-time bootstrap mints a token, the password then logs in, a
  // wrong password is refused.
  const needsBootstrap = await request.get(
    new URL("account/needs-bootstrap", url!).toString(),
  );
  expect((await needsBootstrap.json()).data.bootstrapped).toBe(false);
  const password = `e2e-${runId}-passphrase`;
  const bootstrap = await request.post(
    new URL("account/bootstrap", url!).toString(),
    { data: { password } },
  );
  expect(bootstrap.ok()).toBeTruthy();
  expect((await bootstrap.json()).data.token).toBeTruthy();
  const login = await request.post(new URL("account/login", url!).toString(), {
    data: { password },
  });
  expect((await login.json()).data.token).toBeTruthy();
  const badLogin = await request.post(
    new URL("account/login", url!).toString(),
    { data: { password: "not-the-password" } },
  );
  expect((await badLogin.json()).status).toBe("error");

  // Stop → Stopped (scale-to-zero under the hood, quick); the price
  // line swaps to the storage-only fee — small stopped, $0.40 at B′.
  await page.getByTestId("stop-button").click();
  await waitForStatus(page, "Stopped", 60_000);
  await expect(page.getByTestId("instance-price")).toContainText(
    "$0.40/mo while stopped · billed hourly",
  );

  // Start → Running again: the restart-cleanliness half of the wave's
  // bar. The server reattaches to its PVC (the bootstrap from above
  // lives on), and the health endpoint comes back UP.
  await page.getByTestId("start-button").click();
  await waitForStatus(page, "Running", 8 * 60_000);
  const healthAfterRestart = await request.get(
    new URL("health", url!).toString(),
  );
  expect(healthAfterRestart.ok()).toBeTruthy();
  expect(await healthAfterRestart.json()).toEqual({ status: "UP" });
  const stillBootstrapped = await request.get(
    new URL("account/needs-bootstrap", url!).toString(),
  );
  expect((await stillBootstrapped.json()).data.bootstrapped).toBe(true);

  // Destroy: native confirm() dialog, teardown (async Oban) exits the
  // view to /instances where the fresh user's list is empty again
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await expect(page.getByTestId("instance-row")).toHaveCount(0);
});

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
