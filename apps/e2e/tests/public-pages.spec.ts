import { expect, test } from "@playwright/test";
import { runtimeFor } from "./helpers/runtime";

// Read-only surface checks — safe on every runtime including
// production (ADR-0024's read-only subset: no side effects, no
// credentials). The authenticated pages get their coverage from
// sign-in.spec.ts and forgejo-lifecycle.spec.ts.
test("home page renders", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/FluxVale/);
});

test("sign-in page renders the email form", async ({ page }) => {
  await page.goto("/sign-in");
  await expect(page.getByTestId("sign-in-email")).toBeVisible();
  await expect(page.getByTestId("send-code")).toBeVisible();
});

// #164: the public catalog + sitemap — the programmatic-SEO surface.
// Still read-only (ADR-0024's read-only subset): no sign-in, no deploy,
// only GETs. The deploy-route check rides the anonymous 302, which is
// the auth boundary working, not a bypass.

test("the public catalog renders app cards", async ({ page }) => {
  await page.goto("/catalog");
  await expect(page.locator("[data-testid^='app-']").first()).toBeVisible();
});

test("clicking a catalog card opens the public app detail", async ({ page }) => {
  await page.goto("/catalog");
  await page.locator("[data-testid^='app-']").first().click();
  // URL + a catalog-specific element — the title alone would also match
  // the sign-in page if the route ever regressed to auth-gated.
  await expect(page).toHaveURL(/\/catalog\//);
  await expect(page.locator("h1")).toBeVisible();
  await expect(page.locator("[data-testid^='deploy-']").first()).toBeVisible();
});

// #716: catalog icons ship vendored and load same-origin. A hotlinked
// third-party icon whose host hangs never errors — it silently holds
// the page's load event hostage (the Nov 11 fleet-wide pages-leg
// outage: one hanging icon host timed every /catalog navigation out).
test("catalog pages carry no third-party image sources", async ({ page }) => {
  const absoluteSrcs = () =>
    page.locator("img").evaluateAll((imgs) =>
      imgs
        .map((img) => img.getAttribute("src") ?? "")
        .filter((src) => /^https?:\/\//i.test(src)),
    );

  await page.goto("/catalog");
  await expect(page.locator("[data-testid^='app-']").first()).toBeVisible();
  expect(await absoluteSrcs()).toEqual([]);

  await page.locator("[data-testid^='app-']").first().click();
  await expect(page).toHaveURL(/\/catalog\//);
  expect(await absoluteSrcs()).toEqual([]);
});

test("an anonymous deploy CTA lands on /sign-in — the auth boundary", async ({ page }) => {
  await page.goto("/catalog");
  const cardHref = await page.locator("[data-testid^='app-']").first().getAttribute("href");
  const slug = cardHref?.split("/").pop();
  expect(slug, "catalog card links carry a slug").toBeTruthy();

  await page.goto(`/apps/${slug}/deploy`);
  await expect(page).toHaveURL(/\/sign-in/);
});

test("the sitemap is served and mentions the catalog", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(response.status()).toBe(200);
  expect(await response.text()).toContain("/catalog");
});

// #412: the public feedback board — same read-only subset: GETs only,
// the board shell, one post page, and the sitemap rows.
//
// Demo rows come from the promotable seed, which is gated OFF for prod
// (the #412 ruling: fabricated votes are invented social proof; prod
// launches honestly empty). Content assertions run on the seeding
// runtimes — local, review, and staging (the runtime helper classifies
// review.fluxvale.app hosts staging-class); the prod leg asserts the
// shell: the page renders, the chrome's link exists, the sitemap lists
// the board.
const runtime = runtimeFor(process.env.BASE_URL);
const seedsDemoContent = runtime !== "production";

test("the feedback board renders the shell (header, footer link)", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByRole("heading", { name: "Feedback" })).toBeVisible();
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the feedback board renders post rows", async ({ page }) => {
  test.skip(!seedsDemoContent, "prod launches unseeded: no fabricated rows to assert");
  await page.goto("/feedback");
  await expect(page.locator("[data-testid^='feedback-post-']").first()).toBeVisible();
});

test("clicking a board row opens the public post page", async ({ page }) => {
  test.skip(!seedsDemoContent, "prod launches unseeded: no rows to click through");
  await page.goto("/feedback");
  await page.locator("[data-testid^='feedback-post-']").first().click();
  // URL + a board-specific element — the h1 alone would also match the
  // sign-in page if the route ever regressed to auth-gated.
  await expect(page).toHaveURL(/\/feedback\//);
  await expect(page.locator("h1")).toBeVisible();
  await expect(page.getByTestId("feedback-status")).toBeVisible();
});

test("the footer carries the feedback link on a public page", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the sitemap mentions the feedback board", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(await response.text()).toContain("/feedback");
});

// #412 T9: the roadmap — a shell check that runs on every runtime: the
// page renders honestly empty (three columns, the chrome) wherever no
// post is planned, started, or completed yet.
test("the roadmap renders the shell (heading, columns, footer link)", async ({ page }) => {
  await page.goto("/roadmap");
  await expect(page.getByRole("heading", { name: "Roadmap" })).toBeVisible();
  await expect(page.getByTestId("roadmap-column-planned")).toBeVisible();
  await expect(page.getByTestId("roadmap-column-started")).toBeVisible();
  await expect(page.getByTestId("roadmap-column-completed")).toBeVisible();
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the board header links to the roadmap", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByTestId("roadmap-link")).toBeVisible();
});

test("the sitemap mentions the roadmap", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(await response.text()).toContain("/roadmap");
});
