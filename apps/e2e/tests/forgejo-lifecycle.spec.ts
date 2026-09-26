import { expect, test, type Page } from "@playwright/test";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// Forgejo's full customer lifecycle through the real UI — the flow the
// build ladder demos at every milestone exit (ADR-0031): sign in via
// TestInbox → catalog → deploy Forgejo → running → instance URL opens
// → stop → destroy. It crosses the real cluster — `running` lands on
// the reconcile cron's next tick after pod readiness, and a cold node
// pulls the Forgejo image first — so the waits are generous
// (ADR-00024 §6).

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test("forgejo: catalog → deploy → running → open → stop → destroy", async ({
  page,
  request,
}) => {
  test.setTimeout(15 * 60_000);

  // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
  // gets touched, and the instances list starts empty)
  const email = `test+e2e-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // Catalog → Forgejo (`/` after sign-in is the Phoenix starter page —
  // the app nav lives on the app's own pages, so go there directly)
  await page.goto("/apps");
  await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
  await page.getByTestId("app-forgejo").click();
  await expect(page.getByRole("heading", { name: "Forgejo", exact: true })).toBeVisible();

  // Deploy stepper: version → configuration (seed defaults carry) → name
  await page.locator("[data-testid^='deploy-']").first().click();
  await page.getByTestId("version-option").first().check();
  await page.getByTestId("continue-version").click();
  await page.getByTestId("continue-env").click();
  const name = `e2e-forgejo-${runId}`;
  await page.getByTestId("instance-name").fill(name);
  await page.getByTestId("deploy-submit").click();

  // Status page: deploying → starting → running (live badge; no polling
  // in-page — PubSub re-renders, this loop just reads)
  await page.waitForURL(/\/instances\//);
  await waitForStatus(page, "running", 12 * 60_000);

  // The instance URL opens through Traefik (self-signed — ignored at
  // the config level) and actually serves Forgejo, not a placeholder
  // that merely answers 200
  const url = (await page.getByTestId("instance-url").textContent())?.trim();
  expect(url).toMatch(/^https:\/\//);
  const opened = await request.get(url!);
  expect(opened.status()).toBeLessThan(400);
  expect(await opened.text()).toMatch(/Forgejo/i);

  // Stop → stopped (K8s scale-to-0, quick)
  await page.getByTestId("stop-button").click();
  await waitForStatus(page, "stopped", 60_000);

  // Destroy: native confirm() dialog, teardown (async Oban) exits the
  // view to /instances where the fresh user's list is empty again
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await expect(page.getByTestId("instance-row")).toHaveCount(0);
});

// Poll the live badge until `want` shows; `error` fails fast with the
// status message — waiting out a dead deploy proves nothing.
async function waitForStatus(page: Page, want: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const status = await page
      .getByTestId("status-badge")
      .innerText({ timeout: 10_000 })
      .catch(() => null);

    if (status?.trim() === want) return;
    if (status?.trim() === "error") {
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
