import { expect, test } from "@playwright/test";

// Read-only surface checks — safe on every runtime including production
// (ADR-0024's read-only subset): the legal pages (#365) must render
// anonymously, and both footers must link them. The chrome footer rides
// every public page; the landing carries its own self-contained footer.
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
  // The chrome footer, via a public page that uses it.
  await page.goto("/catalog");
  await expect(page.getByTestId("footer-terms")).toBeVisible();
  await expect(page.getByTestId("footer-acceptable-use")).toBeVisible();

  // The landing's own footer.
  await page.goto("/");
  await expect(page.getByTestId("footer-terms")).toBeVisible();
  await expect(page.getByTestId("footer-acceptable-use")).toBeVisible();
});
