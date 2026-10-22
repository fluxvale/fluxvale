import { expect, test } from "@playwright/test";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #205: `/` is session-aware, GitHub-style — anonymous visitors get the
// marketing landing, signed-in sessions get the dashboard, and the
// signed-in chrome carries the user menu instead of "Sign in". Runs
// wherever TestInbox is reachable — local and staging (ADR-0024);
// never production (sign-in sends a real email and JIT-provisions a
// user — not a read-only action).
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

test("anon-landing: signed-out / shows the marketing landing", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/Managed hosting for open source applications/);
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed hosting for open source applications/);
  await expect(
    page.getByRole("banner").getByRole("link", { name: /Sign in/ }),
  ).toBeVisible();
  await expect(page.getByTestId("user-menu")).toHaveCount(0);
});

test("authed-dashboard: signed-in / shows the dashboard", async ({
  page,
  request,
}) => {
  const email = `test+dash-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // signIn lands on "/" — for a session that's the dashboard now.
  await expect(
    page.getByRole("heading", { name: "Dashboard", level: 1 }),
  ).toBeVisible();
  await expect(page.getByTestId("dashboard-balance")).toBeVisible();
  await expect(page.getByTestId("dashboard-runway")).toBeVisible();

  // Fresh account: the instances overview shows its empty state.
  await expect(page.getByText("No instances yet")).toBeVisible();

  // The landing is still reachable for the session (its permalink).
  await page.goto("/about");
  await expect(page).toHaveTitle(/Managed hosting/);
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed hosting for open source applications/);
});

test("user-menu: signed-in nav shows the user menu, not Sign in", async ({
  page,
  request,
}) => {
  const email = `test+menu-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);
  await page.goto("/");

  await expect(page.getByTestId("user-menu")).toBeVisible();
  await expect(
    page.getByRole("banner").getByRole("link", { name: /^Sign in/ }),
  ).toHaveCount(0);

  await page.getByTestId("user-menu-button").click();
  await expect(page.getByTestId("user-menu-panel")).toContainText(email);
  await expect(
    page.getByTestId("user-menu-panel").getByRole("link", { name: "Billing" }),
  ).toHaveAttribute("href", "/billing");

  // Sign out ends the session — and / is the landing again.
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL(/\/sign-in$/);
  await page.goto("/");
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed hosting for open source applications/);
});
