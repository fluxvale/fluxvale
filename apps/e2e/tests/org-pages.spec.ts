import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// S5: the personal org never presents as an org — the org-scoped URL a
// fresh user would derive redirects to the dashboard (their instances
// and balance already live there), and no org chrome renders. A real
// org's home needs a team membership, which no flow creates yet, so the
// e2e suite pins the personal posture and hosts the header-geometry
// guard on the dashboard.
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
// long enough to stress the header (the username derives from it — the
// switcher's Personal row label) but short enough that the per-run runId
// survives DeriveUsername's 39-char window — so the slug below is exact
// by construction: no truncation edge, no -2/-3 collision suffix across
// runs.
const emailFor = (tag: string) => `test+orghome+${tag}+${runId}@fluxvale.com`;

// Mirrors DeriveUsername's base rule (downcase, non-[a-z0-9] runs -> "-",
// trim): the personal org's slug is the derived username verbatim, so
// the redirect probe addresses a slug that provably exists. The asserts
// keep the mirror honest: if an edit ever pushes the local part past the
// 39-char window, truncation semantics fork and this fails loudly
// instead of redirecting for the wrong reason.
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

test("personal-org path: a fresh user's org URL lands on the dashboard, org-less", async ({
  page,
  request,
}) => {
  const email = emailFor("orgpage");
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  await page.goto(ownOrgPath(email));
  await waitForLiveViewJoin(page);

  // The redirect landed on the dashboard — no org identity, no org
  // chrome (S5: the personal org is the account, not an org page).
  await expect(page).not.toHaveURL(/\/organizations\//);
  await expect(page.getByTestId("org-name")).toHaveCount(0);
  await expect(page.getByTestId("member-count")).toHaveCount(0);
});

for (const width of [375, 640]) {
  test(`dashboard-geometry at ${width}px: no horizontal overflow, first nav link clickable`, async ({
    page,
    request,
  }) => {
    test.setTimeout(60_000); // sign-in plus two navigations

    await page.setViewportSize({ width, height: 800 });
    const email = emailFor(`w${width}`);
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    await page.goto("/");
    // Header interactions inside the join window race the connected
    // re-render (it resets uncontrolled <details> state — the user menu
    // closes under the click). Join first, then touch the chrome.
    await waitForLiveViewJoin(page);

    // (a) The long derived username (the user menu's name line, the
    // switcher label at 640+) must never push the page into horizontal
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
