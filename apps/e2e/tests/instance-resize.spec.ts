import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #493: the guided stop→resize→start through the real UI — sign in via
// TestInbox → deploy Forgejo at its small recommendation → running →
// stop → resize (storage locked: local-path can't expand; CPU reprices
// live through the formula) → confirm → start again at the new size.
// It crosses the real cluster like forgejo-lifecycle (`running` lands
// on the reconcile cron's tick after pod readiness), so the waits are
// generous (ADR-00024 §6).

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// Local + staging runtimes (#116): the resize mutates instance state —
// production stays read-only (ADR-0024).
test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test("resize: stop → panel reprices → confirm → resized → running again", async ({
  page,
  request,
}) => {
  test.setTimeout(15 * 60_000);

  // Fresh per-run user (JIT-provisioned; nobody's data gets touched).
  const email = `test+e2e-${runId}-resize@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // Deploy Forgejo at its small recommendation (0.5 CPU · 512 MB ·
  // 10 GB — every default sits on the sliders' ladders, so the resize
  // panel opens priced at the size row).
  await page.goto("/apps");
  await waitForLiveViewJoin(page);
  await page.getByTestId("app-forgejo").click();
  await expect(page.getByRole("heading", { name: "Forgejo", exact: true })).toBeVisible();
  await waitForLiveViewJoin(page);
  await page.locator("[data-testid^='deploy-']").first().click();
  await waitForLiveViewJoin(page);
  await page.getByTestId("version-option").first().check();
  await page.getByTestId("continue-version").click();
  await page.getByTestId("continue-env").click();
  // No slider move — the recommendation carries.
  await page.getByTestId("continue-resources").click();
  await page.getByTestId("instance-name").fill(`e2e-resize-${runId}`);
  await page.getByTestId("deploy-submit").click();

  await page.waitForURL(/\/instances\//);
  await waitForLiveViewJoin(page);
  await waitForStatus(page, "Running", 12 * 60_000);

  // Stop → Stopped (scale-to-zero, quick), then open the resize panel.
  await page.getByTestId("stop-button").click();
  await waitForStatus(page, "Stopped", 60_000);

  await page.getByTestId("resize-button").click();
  const panel = page.getByTestId("resize-panel");
  await expect(panel).toBeVisible();

  // The live price line — "From X/mo to Y/mo · Z/mo while stopped"; at
  // the recommendation X and Y are the same size-row cents.
  const price = page.getByTestId("resize-price");
  await expect(price).toContainText(
    /From \$[\d.]+\/mo to \$[\d.]+\/mo · \$[\d.]+\/mo while stopped/,
  );

  // local-path can't expand a PVC — storage is locked at its rung and
  // the panel says so; CPU and memory stay live.
  await expect(page.getByTestId("resource-storage")).toBeDisabled();
  await expect(page.getByTestId("slider-locked-note")).toContainText(
    "Storage can't be expanded on this cluster yet.",
  );
  await expect(page.getByTestId("resource-cpu")).toBeEnabled();

  // Move CPU up a rung (0.5 → 1 core): the candidate leaves the
  // recommendation and reprices through the formula, live.
  const priceBefore = (await price.innerText()).trim();
  await page.getByTestId("resource-cpu").fill("2");
  await expect(price).toContainText(/to \$[\d.]+\/mo/);
  expect((await price.innerText()).trim()).not.toBe(priceBefore);

  // Continue → the confirm states the consequence before the submit
  // exists (the backups panel's two-step shape, in-page).
  await page.getByTestId("resize-continue").click();
  const confirm = page.getByTestId("resize-confirm");
  await expect(confirm).toContainText("Resize instance");
  await expect(confirm).toContainText("1 CPU · 512 MB · 10 GB");
  await expect(confirm).toContainText("The instance stays stopped.");
  await expect(confirm).toContainText("while stopped");

  await page.getByTestId("resize-submit").click();
  await expect(page.getByText("Resized. Start your instance to run at the new size.")).toBeVisible();
  await expect(panel).toBeHidden();

  // The row carries the new allocation; Start is the flow's end.
  await expect(page.getByTestId("instance-resources")).toContainText("1 CPU · 512 MB · 10 GB");
  await page.getByTestId("start-button").click();
  await waitForStatus(page, "Running", 6 * 60_000);
});

// Poll the live badge until `want` shows; "Failed" fails fast with the
// status message — waiting out a dead deploy proves nothing. The badge
// reads #179's user-facing vocabulary, never the state-machine atom.
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
