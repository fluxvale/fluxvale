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
