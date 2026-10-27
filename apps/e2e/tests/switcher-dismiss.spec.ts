import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #284: the org switcher closes on outside click and Escape — native
// <details> only toggles on a summary re-click, so the DetailsDismiss
// hook carries the GitHub-style dismissal. Signed-in chrome only, so
// the gates match the other sign-in specs: never production (sign-in
// JIT-provisions a user), and skipped wherever TestInbox is unreachable.
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

test("escape closes the open switcher", async ({ page, request }) => {
  const email = `test+esc-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);
  await page.goto("/");
  // The hook rides the LiveView mount — wait out the join so the
  // dismissal listeners are attached before the first interaction.
  await waitForLiveViewJoin(page);

  await page.getByTestId("org-switcher-button").click();
  await expect(page.locator("#org-switcher")).toHaveAttribute("open");

  await page.keyboard.press("Escape");
  await expect(page.locator("#org-switcher")).not.toHaveAttribute("open");
  await expect(page.getByTestId("org-switcher-panel")).toBeHidden();
});

test("a click outside closes the open switcher", async ({ page, request }) => {
  const email = `test+outside-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);
  await page.goto("/");
  await waitForLiveViewJoin(page);

  await page.getByTestId("org-switcher-button").click();
  await expect(page.locator("#org-switcher")).toHaveAttribute("open");

  // The page's own main content, in its padding — no link, no panel.
  await page.locator("main").click({ position: { x: 5, y: 5 } });
  await expect(page.locator("#org-switcher")).not.toHaveAttribute("open");
  await expect(page.getByTestId("org-switcher-panel")).toBeHidden();
});
