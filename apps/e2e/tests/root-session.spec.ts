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
  await expect(page).toHaveTitle(/managed cloud platform for open source applications/);
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed cloud platform for open source applications/);
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
  await expect(page).toHaveTitle(/managed cloud platform/);
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed cloud platform for open source applications/);
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

  // Desktop: Billing left the header row for the account menu (#467) —
  // the closed header carries no Billing or Pricing link, and Feedback
  // takes Pricing's seat in the nav row.
  await expect(
    page.getByRole("banner").getByRole("link", { name: "Billing" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("banner").getByRole("link", { name: "Pricing" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("banner").getByRole("link", { name: "Feedback" }),
  ).toHaveAttribute("href", "/feedback");

  await page.getByTestId("user-menu-button").click();
  await expect(page.getByTestId("user-menu-panel")).toContainText(email);

  // The menu lists Billing beside the account entries at every width
  // (#467) — no header copy to fold below sm anymore.
  await expect(
    page.getByTestId("user-menu-panel").getByRole("link", { name: "Billing" }),
  ).toHaveAttribute("href", "/billing");

  // Below sm the header links fold into the menu (#255) — drop to a
  // mobile viewport with the menu still open: the folded Catalog row
  // lives there, and Billing's menu row holds at this width too.
  await page.setViewportSize({ width: 375, height: 812 });
  await expect(
    page.getByTestId("user-menu-panel").getByRole("link", { name: "Billing" }),
  ).toHaveAttribute("href", "/billing");
  await expect(
    page.getByTestId("user-menu-panel").getByRole("link", { name: "Catalog" }),
  ).toHaveAttribute("href", "/apps");

  // Sign out ends the session — and / is the landing again (#473: the
  // sign-out redirect itself lands here now).
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL("/");
  await page.goto("/");
  await expect(
    page.getByRole("heading", { level: 1 }),
  ).toHaveText(/Managed cloud platform for open source applications/);
});
