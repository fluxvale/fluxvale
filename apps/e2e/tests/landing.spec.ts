import { expect, test } from "@playwright/test";

// Read-only surface checks — safe on every runtime including production
// (ADR-0024's read-only subset: no side effects, no credentials). Meta-tag
// assertions wait for the SEO slice; this file only asserts what the
// landing page itself renders.
test("landing page renders hero and CTAs", async ({ page }) => {
  await page.goto("/");
  // Landing-specific: the default layout title must not satisfy this.
  await expect(page).toHaveTitle(/Managed hosting for open source applications/);

  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toBeVisible();
  await expect(h1).toHaveText(/Managed hosting for open source applications/);

  // The landing carries three "Browse apps" links (hero CTA, the steps'
  // catalog-preview foot, the catalog band CTA) — the hero one is first
  // in DOM order and is the assertion target.
  await expect(
    page.getByRole("link", { name: "Browse apps" }).first(),
  ).toHaveAttribute("href", "/catalog");
});
