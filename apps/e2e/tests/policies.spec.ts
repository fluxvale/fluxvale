import { expect, test } from "@playwright/test";

// Read-only surface checks — safe on every runtime including production
// (ADR-0024's read-only subset): the legal pages (#365) must render
// anonymously, and the one public footer (#881 — the same link-columns
// definition on every unauthenticated surface, so one page proves both
// former lineages) must link them.
test("the Terms of Service renders anonymously", async ({ page }) => {
  await page.goto("/policies/terms");
  await expect(page).toHaveTitle(/Terms of Service · FluxVale/);
  await expect(page.getByTestId("terms-of-service")).toBeVisible();
});

test("the Acceptable Use Policy renders anonymously", async ({ page }) => {
  await page.goto("/policies/acceptable-use");
  await expect(page).toHaveTitle(/Acceptable Use Policy · FluxVale/);
  await expect(page.getByTestId("acceptable-use-policy")).toBeVisible();
});

test("both footers link the legal pages", async ({ page }) => {
  // The public chrome's footer, via a public page that uses it.
  await page.goto("/catalog");
  await expect(page.getByTestId("footer-terms")).toBeVisible();
  await expect(page.getByTestId("footer-acceptable-use")).toBeVisible();

  // The landing renders the same one definition (#881).
  await page.goto("/");
  await expect(page.getByTestId("footer-terms")).toBeVisible();
  await expect(page.getByTestId("footer-acceptable-use")).toBeVisible();
});
