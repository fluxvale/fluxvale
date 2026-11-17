import { expect, test } from "@playwright/test";
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
  const email = `test+onboard-${runId}@fluxvale.com`;

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
