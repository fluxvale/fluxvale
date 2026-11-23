import { expect, test } from "@playwright/test";
import { destroyInstance, waitForStatus } from "./helpers/instance-ui";
import { runtimeFor } from "./helpers/runtime";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { TestInbox } from "./helpers/test-inbox";

// #831: the show-once onboarding flow at the e2e level — a fresh JIT
// user's "/" is the gate's swap to /onboarding, the username step
// offers the DERIVED handle (the seeded admin-2 class of account: no
// step ever let them choose), skip stamps and lands the dashboard, and
// the flow never re-shows. Runs wherever TestInbox is reachable —
// local and staging (ADR-0024); never production (sign-in sends a real
// email and JIT-provisions a user — not a read-only action).
const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

// #887 failure-safe instance cleanup: armed once the spec's deploy is
// Running, cleared by a successful in-body destroy. A failed routing
// assertion reaches afterEach with it live — the delete rides the
// machine API with the very PAT the spec minted (the custom-hostname
// shape), so cleanup never depends on the page's state, and every
// step swallows itself: a failed test keeps its original error (the
// docmost finally posture — a green run never reports red at teardown
// either, its cleanup already asserted in the body).
let liveInstance: { id: string; token: string } | null = null;

test.afterEach(async ({ request }) => {
  const target = liveInstance;
  liveInstance = null;

  if (!target) return;

  await request
    .delete(`/api/v1/instances/${target.id}`, {
      headers: { authorization: `Bearer ${target.token}` },
    })
    .catch(() => null);
});

test.skip(
  runtime === "production",
  "sign-in sends a real email and JIT-provisions a user — not a read-only action (ADR-0024)",
);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// DeriveUsername's rule set, mirrored for the pre-fill assertion: the
// suggestion is the account's current handle, so the expectation is the
// sanitizer verbatim (lowercase local part, non-alphanumerics to
// hyphens, trimmed, 39-char cap, the neutral fallback).
const derivedHandle = (email: string) =>
  email
    .split("@")[0]!
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 39)
    .replace(/-+$/, "") || "user";

test("a fresh user's / is the flow: derived handle, skip stamps, shown once", async ({
  page,
  request,
}) => {
  const email = `test+onboard-${runId}-r${test.info().retry}@fluxvale.com`;

  // The real sign-in mechanics WITHOUT the helper's gate-walk — this
  // spec is the walk.
  await page.goto("/sign-in");
  await waitForLiveViewJoin(page);

  await page.getByTestId("sign-in-email").fill(email);
  await page.getByTestId("send-code").click();

  const code = await new TestInbox(request, testInboxToken!).latestCode(email);
  await page.getByTestId("sign-in-code").fill(code);
  await page.getByTestId("verify-code").click();

  // The gate: the fresh account lands the flow, not the dashboard.
  const step = page.getByTestId("onboarding-step-username");
  await step.waitFor();

  // The username step pre-fills the derived handle as the suggestion.
  await expect(page.getByTestId("onboarding-username-input")).toHaveValue(
    derivedHandle(email),
  );

  // Skip: everything after the current step is forgone; the stamp
  // lands the dashboard.
  await page.getByTestId("onboarding-skip").click();
  await page.waitForURL((url) => url.pathname === "/");
  await expect(
    page.getByRole("heading", { name: "Dashboard", level: 1 }),
  ).toBeVisible();

  // Show-once: the second visit to / is the dashboard, never the flow.
  await page.goto("/");
  await expect(page.getByTestId("onboarding-step-username")).toHaveCount(0);
  await expect(
    page.getByRole("heading", { name: "Dashboard", level: 1 }),
  ).toBeVisible();
});

// #887: the agent-first run completes onboarding with no click. The
// signals — a live machine credential and a first instance — converge
// the stamp server-side, so the gate renders the dashboard and the
// flow itself bounces. The credential here is a minted PAT (the
// agent's OAuth pair lands in the same table, and the predicate reads
// rows, not kinds); the instance is the lifecycle spec's own Memos
// stepper, run to Running because clean teardown needs a settled row.
test(
  "the agent-first run completes onboarding with no click (#887)",
  async ({ page, request }) => {
    // 15 min: the deploy-to-Running wait (12) dominates; sign-in,
    // mint, stepper and assertions are seconds.
    test.setTimeout(15 * 60_000);

    const email = `test+onboard-agent-${runId}-r${test.info().retry}@fluxvale.com`;

    // Real sign-in mechanics (this spec is the walk): the fresh
    // account lands the flow — and STAYS there: no skip, no finish.
    await page.goto("/sign-in");
    await waitForLiveViewJoin(page);
    await page.getByTestId("sign-in-email").fill(email);
    await page.getByTestId("send-code").click();
    const code = await new TestInbox(request, testInboxToken!).latestCode(email);
    await page.getByTestId("sign-in-code").fill(code);
    await page.getByTestId("verify-code").click();
    await page.getByTestId("onboarding-step-username").waitFor();

    // Signal 1 — machine auth: deep links stay ungated (#831 D1), so
    // the account mints a PAT mid-flow. The instances:write box is
    // checked on purpose: that scope is what the afterEach cleanup
    // deletes the deployed instance with (any live credential row
    // satisfies the predicate — scope breadth is cleanup's need, not
    // the signal's). The raw value is read from the one-time reveal
    // before Done dismisses it, exactly like an agent copying its
    // credential.
    await page.goto("/settings/developer#api-tokens");
    await waitForLiveViewJoin(page);
    await page.getByTestId("api-token-name-input").fill("agent-first-run");
    await page
      .locator("[data-testid='api-token-scope'][value='instances:write']")
      .check();
    await page.getByTestId("api-token-create").click();
    const patToken =
      (await page.getByTestId("api-token-reveal-value").textContent()) ?? "";
    await page.getByTestId("api-token-reveal-done").click();

    // Signal 2 — the first instance: the lifecycle spec's Memos
    // stepper (zero-config), this spec's own per-run user and name.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await page.getByTestId("app-memos").click();
    await waitForLiveViewJoin(page);
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await page.getByTestId("continue-env").click();
    await page.getByTestId("continue-resources").click();
    await page.getByTestId("instance-name").fill(`e2e-onboard-${runId}-r${test.info().retry}`);
    await page.getByTestId("deploy-submit").click();
    await page.waitForURL(/\/instances\//);
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    // Arm the failure-safe cleanup now that the row is Running: the
    // id rides the instance page's URL, the token was read at the
    // reveal. A successful in-body destroy clears it below.
    const instanceId = page.url().match(/\/instances\/([0-9a-f-]{36})/)?.[1];
    if (instanceId) liveInstance = { id: instanceId, token: patToken.trim() };

    // The contract: `/` renders the dashboard — never step one again —
    // with the agent's instance right there.
    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: "Dashboard", level: 1 }),
    ).toBeVisible();
    await expect(page.getByTestId("onboarding-step-username")).toHaveCount(0);
    await expect(page.getByTestId("instance-row")).toHaveCount(1);

    // And the flow itself bounces: mount converges the stamp and
    // lands the dashboard (the show-once guarantee, signal-earned).
    await page.goto("/onboarding");
    await page.waitForURL((url) => url.pathname === "/");
    await expect(
      page.getByRole("heading", { name: "Dashboard", level: 1 }),
    ).toBeVisible();

    // Teardown — this spec's instance is its alone to destroy.
    await page.goto("/instances");
    await waitForLiveViewJoin(page);
    await page.getByTestId("instance-row").click();
    await waitForLiveViewJoin(page);
    await destroyInstance(page);
    liveInstance = null;
  },
);
