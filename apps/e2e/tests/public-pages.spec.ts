import { expect, test } from "@playwright/test";

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
