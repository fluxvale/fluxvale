import { expect, test } from "@playwright/test";

// Read-only surface checks — safe on every runtime including production
// (ADR-0024's read-only subset: no side effects, no credentials). Meta-tag
// assertions wait for the SEO slice; this file only asserts what the
// landing page itself renders.
test("landing page renders hero and CTAs", async ({ page }) => {
  await page.goto("/");
  // Landing-specific: the default layout title must not satisfy this.
  await expect(page).toHaveTitle(/your agent deploys open source apps/);

  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toBeVisible();
  await expect(h1).toHaveText(/Your agent deploys\. FluxVale runs it\./);

  // The primary CTA is the agent path. Anonymous visitors land on the
  // public agent guide; the signed-in landing points at /settings/agents.
  await expect(
    page.getByRole("link", { name: "Set up your agent" }).first(),
  ).toHaveAttribute("href", "/docs/agents");

  // The human fallback stays one click away, but it is not the primary.
  await expect(
    page.getByRole("link", { name: "Browse the catalog" }).first(),
  ).toHaveAttribute("href", "/catalog");
});
