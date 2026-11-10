import { expect, type Page } from "@playwright/test";

// The instance-page assertions every lifecycle spec shares. Extracted
// from twelve per-spec copies of one body (eleven byte-identical plus
// one brace-formatting variant; four comment variants) — #510 batch 3.
// A new lifecycle spec copies the destroy block at birth (vikunja #610
// and docmost #609 both did), so the shared shape lives here now.

// Poll the live badge until `want` shows; "Failed" fails fast with the
// status message — waiting out a dead deploy proves nothing. The badge
// reads #179's user-facing vocabulary (Running/Stopped/Failed…), never
// the internal state-machine atom.
export async function waitForStatus(page: Page, want: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const status = await page
      .getByTestId("status-badge")
      .innerText({ timeout: 10_000 })
      .catch(() => null);

    if (status?.trim() === want) return;
    if (status?.trim() === "Failed") {
      const message = await page
        .getByTestId("status-message")
        .textContent()
        .catch(() => "");
      throw new Error(`instance hit error state: ${message?.trim()}`);
    }

    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  throw new Error(`status never reached "${want}" within ${timeoutMs}ms`);
}

// Destroy: native confirm() dialog, teardown (async Oban) exits the
// view to /instances where the fresh user's list is empty again.
export async function destroyInstance(page: Page) {
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await expect(page.getByTestId("instance-row")).toHaveCount(0);
}
