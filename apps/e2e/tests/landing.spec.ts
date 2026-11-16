import { expect, test } from "@playwright/test";

// Read-only surface checks — safe on every runtime including production
// (ADR-0024's read-only subset: no side effects, no credentials). Meta-tag
// assertions wait for the SEO slice; this file only asserts what the
// landing page itself renders.
test("landing page renders hero and CTAs", async ({ page }) => {
  await page.goto("/");
  // Landing-specific: the default layout title must not satisfy this.
  await expect(page).toHaveTitle(/deploy open source apps from the dashboard or an agent/);

  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toBeVisible();
  await expect(h1).toHaveText(/Open source apps, running in minutes\./);

  // The hero panel is an HTML dashboard preview, not a bitmap. It is
  // aria-hidden decoration; the sr-only line carries the honesty.
  const mock = page.getByTestId("hero-mock");
  await expect(mock).toBeVisible();
  await expect(mock).toContainText("Forgejo");
  await expect(mock).toContainText("Umami");
  await expect(mock).toContainText("Kavita");
  await expect(mock).toContainText("Sleeping");
  await expect(page.locator('img[src*="hero-app-page"]')).toHaveCount(0);

  // The primary CTA is the human sign-up path, not the agent guide.
  await expect(
    page.getByRole("link", { name: "Get started" }).first(),
  ).toHaveAttribute("href", "/sign-in");

  // The agent path is its own link, not the primary button.
  await expect(
    page.getByRole("link", { name: "Have an agent? Set it up" }).first(),
  ).toHaveAttribute("href", "/docs/agents");

  // The human catalog path stays one click away.
  await expect(
    page.getByRole("link", { name: "Browse the catalog" }).first(),
  ).toHaveAttribute("href", "/catalog");

  // The navbar's Agents label is the docs root, not the agent setup page.
  await expect(
    page
      .getByRole("navigation", { name: "Primary" })
      .getByRole("link", { name: "Agents", exact: true }),
  ).toHaveAttribute("href", "/docs");
});
