import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #276: the org home at /organizations/:slug — the org switcher rows'
// target. A signed-in visit asserts the org renders; the header-geometry
// guard rides the same page. The personal org's name IS the signup
// email's local part, so long addresses make the long-name fixture.
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

// One address per test (the suite's convention — the 60s resend throttle
// makes a shared address' second sign-in read the already-consumed code,
// and verify fails with "That code didn't match"). Each stays long: the
// name is the local part, and the geometry guard wants a name that would
// overflow the header if it could.
const emailFor = (tag: string) =>
  `test+orghome-${tag}-long-organization-name-${runId}@fluxvale.com`;

// The signed-in actor's own org, discovered through the switcher panel —
// its org rows ARE the /organizations/:slug links (no API seam needed).
// The sign-in flash rides the dashboard and, fixed to the top-right, it
// overlays the switcher at narrow widths — dismiss it if present.
async function ownOrgPath(page: Page): Promise<string> {
  const flashClose = page.getByRole("button", { name: "close" });
  if (await flashClose.first().isVisible().catch(() => false)) {
    await flashClose.first().click();
  }
  await page.getByTestId("org-switcher-button").click();
  const href = await page
    .locator('[data-testid="org-switcher-panel"] a[href^="/organizations/"]')
    .first()
    .getAttribute("href");
  expect(href).toBeTruthy();
  await page.getByTestId("org-switcher-button").click();
  return href!;
}

test("org-home: signed-in visit renders the org home", async ({ page, request }) => {
  await signIn(page, new TestInbox(request, testInboxToken!), emailFor("org-page"));

  const path = await ownOrgPath(page);
  await page.goto(path);
  await waitForLiveViewJoin(page);

  await expect(page.getByTestId("org-name")).toBeVisible();
  await expect(page.getByTestId("org-slug")).toHaveText(/\S/);
  // A fresh account: exactly the JIT-provisioned owner.
  await expect(page.getByTestId("member-count")).toContainText("1 member");
  await expect(page.getByTestId("org-wallet-balance")).toBeVisible();
  // Nothing deployed yet — the empty state points at the catalog.
  await expect(page.getByTestId("instances-empty")).toBeVisible();
});

for (const width of [375, 640]) {
  test(`org-home-geometry at ${width}px: no horizontal overflow, first nav link clickable`, async ({
    page,
    request,
  }) => {
    test.setTimeout(60_000); // sign-in plus two navigations

    await page.setViewportSize({ width, height: 800 });
    await signIn(page, new TestInbox(request, testInboxToken!), emailFor(`${width}px`));

    const path = await ownOrgPath(page);
    await page.goto(path);
    // The org-name assertion passes on the static render, but header
    // interactions inside the join window race the connected re-render
    // (it resets uncontrolled <details> state — the user menu closes
    // under the click). Join first, then touch the chrome.
    await waitForLiveViewJoin(page);

    await expect(page.getByTestId("org-name")).toBeVisible();

    // (a) The long org name must never push the page into horizontal
    // scroll — the header cluster shrinks instead (#276 review).
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);

    // (b) A Playwright click uses hit-testing: a successful navigation
    // proves nothing sits on the first nav entry. Below sm (375) the
    // header nav hides into the user menu (#255) — the Catalog row
    // lives there; at 640 the header link is the real target.
    if (width < 640) {
      await page.getByTestId("user-menu-button").click();
      await page
        .getByTestId("user-menu-panel")
        .getByRole("link", { name: "Catalog" })
        .click();
    } else {
      await page.getByRole("banner").getByRole("link", { name: "Catalog" }).click();
    }
    await expect(page).toHaveURL(/\/apps$/);
  });
}
