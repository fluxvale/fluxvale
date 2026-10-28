import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #276: the org home at /organizations/:slug — the org switcher rows'
// target. A signed-in visit asserts the org renders; the header-geometry
// guard rides the same page. The personal org's name IS the signup
// email's derived username (#296), so long local parts make the
// long-name fixture.
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
// and verify fails with "That code didn't match"). The local part stays
// long enough to stress the header (the name is the derived username)
// but short enough that the per-run runId survives DeriveUsername's
// 39-char window — so the slug below is exact by construction: no
// truncation edge, no -2/-3 collision suffix across runs.
const emailFor = (tag: string) => `test+orghome+${tag}+${runId}@fluxvale.com`;

// Post-#286 the switcher hides its org rows for a single-org actor, so
// a fresh user's panel has no /organizations/ link to read the path
// from — derive it instead, mirroring DeriveUsername's base rule
// (downcase, non-[a-z0-9] runs -> "-", trim; the org takes the username
// verbatim as name and slug). The asserts keep the mirror honest: if an
// edit ever pushes the local part past the 39-char window, truncation
// semantics fork and this fails loudly instead of 404ing opaquely.
const slugForEmail = (email: string) => {
  const slug = email
    .split("@")[0]!
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  expect(slug.length).toBeGreaterThan(2);
  expect(slug.length).toBeLessThanOrEqual(39);
  return slug;
};

const ownOrgPath = (email: string) => `/organizations/${slugForEmail(email)}`;

test("org-home: signed-in visit renders the org home", async ({ page, request }) => {
  const email = emailFor("orgpage");
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  const path = ownOrgPath(email);
  await page.goto(path);
  await waitForLiveViewJoin(page);

  await expect(page.getByTestId("org-name")).toBeVisible();
  await expect(page.getByTestId("org-slug")).toHaveText(/\S/);
  // A fresh account: exactly the JIT-provisioned owner.
  await expect(page.getByTestId("member-count")).toContainText("1 member");
  await expect(page.getByTestId("wallet-balance")).toBeVisible();
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
    const email = emailFor(`w${width}`);
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    const path = ownOrgPath(email);
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
