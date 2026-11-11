import { expect, test } from "@playwright/test";
import { destroyInstance, waitForStatus } from "./helpers/instance-ui";
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
  await expect(page.getByRole("heading", { name: "Forgejo hosting", exact: true })).toBeVisible();
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

  // The guided stop→resize start (#493's headline behavior): the
  // button stops the instance, and the panel opens on the stopped
  // landing — no separate stop-button click.
  await page.getByTestId("stop-to-resize").click();
  await waitForStatus(page, "Stopped", 60_000);
  const panel = page.getByTestId("resize-panel");
  await expect(panel).toBeVisible();

  // The live price line (#206's label discipline): the From → To
  // figures state billed hourly, and the candidate's while-stopped
  // fee rides beneath. At the recommendation From and To are the same
  // size-row cents.
  const price = page.getByTestId("resize-price");
  await expect(price).toContainText(/From \$[\d.]+\/mo to \$[\d.]+\/mo · billed hourly/);
  await expect(price).toContainText(/\$[\d.]+\/mo while stopped/);

  // Storage lock: the LOCAL dev stack's default class is local-path
  // (allowVolumeExpansion absent — the probe reads it live). Other
  // runtimes may run an expandable class, so the storage-lock
  // assertions are local-only; the probe decides there.
  if (runtime === "local") {
    await expect(page.getByTestId("resource-storage")).toBeDisabled();
    await expect(page.getByTestId("slider-locked-note")).toContainText(
      "Storage can't be expanded on this cluster yet.",
    );
  }

  // The unlocked dimensions stay live.
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

  // #532: focus lands in the confirm; Cancel returns it to Continue.
  await expect(confirm).toBeFocused();
  await page.getByTestId("resize-cancel").click();
  await expect(page.getByTestId("resize-continue")).toBeFocused();
  await page.getByTestId("resize-continue").click();
  await expect(confirm).toContainText("Resize instance");

  await page.getByTestId("resize-submit").click();
  await expect(
    page.getByText("Resized. Start your instance to run at the new size."),
  ).toBeVisible();
  await expect(panel).toBeHidden();

  // The row carries the new allocation; Start is the flow's end.
  await expect(page.getByTestId("instance-resources")).toContainText("1 CPU · 512 MB · 10 GB");
  await page.getByTestId("start-button").click();
  await waitForStatus(page, "Running", 6 * 60_000);

  // Destroy like every lifecycle sibling — the leg's stack is shared
  // by the whole suite, and a leaked runner-scoped instance doubles
  // on retry (every other spec cleans up; this one was the holdout).
  await destroyInstance(page);
});
