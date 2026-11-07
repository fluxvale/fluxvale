import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// Forgejo's full customer lifecycle through the real UI — the flow the
// build ladder demos at every milestone exit (ADR-0031): sign in via
// TestInbox → catalog → deploy Forgejo → running → instance URL opens
// → stop → destroy. It crosses the real cluster — `running` lands on
// the reconcile cron's next tick after pod readiness, and a cold node
// pulls the Forgejo image first — so the waits are generous
// (ADR-00024 §6).

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// Local + staging runtimes (#116: staging is instance-capable — Cluster
// row live, *.fluxvale.app wildcard at the edge). Production stays
// read-only (ADR-0024): the suite never mutates it.
test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test("forgejo: catalog → deploy → running → open → stop → destroy", async ({
  page,
  request,
}) => {
  test.setTimeout(15 * 60_000);

  // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
  // gets touched, and the instances list starts empty)
  const email = `test+e2e-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // Catalog → Forgejo (`/` after sign-in is the Phoenix starter page —
  // the app nav lives on the app's own pages, so go there directly).
  // Each page's first phx interaction waits for the join (#148 —
  // helpers/live-view.ts); later pages ride the same socket.
  // The catalog's price badge carries B′ (#206): Forgejo recommends
  // `small`, $3.35/mo — stated as a monthly-equivalent, billed hourly.
  await page.goto("/apps");
  await waitForLiveViewJoin(page);
  await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
  await page.getByTestId("app-forgejo").click();
  await expect(page.getByRole("heading", { name: "Forgejo", exact: true })).toBeVisible();
  await waitForLiveViewJoin(page);
  await expect(page.locator("[data-testid^='price-']").first()).toContainText(
    "$3.35/mo · billed hourly",
  );

  // Deploy stepper: version → configuration (seed defaults carry) →
  // resources → name. The resources step exercises #186's formula
  // pricing with a custom allocation: cpu 1 over Forgejo's `small`
  // recommendation (0.5/512/10), the live estimate repricing to the
  // v5 B′ curve's $3.91/mo before continuing (#206 — the label also
  // states billed-hourly). The allocation is selected (#195 —
  // sliders + quick picks, no text field) and rungs-only (#221): the
  // range input addresses the ladder by index, so `fill("2")` sets
  // cpu to its third rung (1 core); `fill` sets a range input's
  // value directly (Playwright's supported path for range, including
  // its actionability checks).
  await page.locator("[data-testid^='deploy-']").first().click();
  await waitForLiveViewJoin(page);
  await page.getByTestId("version-option").first().check();
  await page.getByTestId("continue-version").click();
  await page.getByTestId("continue-env").click();
  await page.getByTestId("resource-cpu").fill("2");
  await expect(page.getByTestId("resources-price")).toContainText("$3.91/mo · billed hourly");
  await page.getByTestId("continue-resources").click();
  await expect(page.getByTestId("price-summary")).toContainText("$3.91/mo · billed hourly");
  const name = `e2e-forgejo-${runId}`;
  await page.getByTestId("instance-name").fill(name);
  await page.getByTestId("deploy-submit").click();

  // Status page: Provisioning → Starting → Running (live badge; no
  // polling in-page — PubSub re-renders, this loop just reads). The
  // join wait covers stop/delete below — their clicks must not race
  // either.
  await page.waitForURL(/\/instances\//);
  await waitForLiveViewJoin(page);
  await waitForStatus(page, "Running", 12 * 60_000);

  // The instance page shows the version's recommended-size rate
  // (small, $3.35 at B′) — pre-#206 shape: this custom-allocation
  // instance actually bills its $3.91 snapshot (#186); repricing that
  // surface is flagged as a follow-up in the closing PR's body, not
  // #206's scope. Framing is the same
  // monthly-equivalent/billed-hourly as every surface.
  await expect(page.getByTestId("instance-price")).toContainText(
    "$3.35/mo · billed hourly",
  );

  // The instance URL opens through Traefik (self-signed — ignored at
  // the config level) and actually serves Forgejo, not a placeholder
  // that merely answers 200
  const url = (await page.getByTestId("instance-url").textContent())?.trim();
  expect(url).toMatch(/^https:\/\//);
  const opened = await request.get(url!);
  expect(opened.status()).toBeLessThan(400);
  expect(await opened.text()).toMatch(/Forgejo/i);

  // #181's done-when: usable within one click of opening — registration
  // is open, so the owner can sign up (the first registrant becomes the
  // admin). A closed instance still renders /user/sign_up (200) with a
  // "Registration is disabled" notice instead of the form — assert the
  // form itself, and the notice's absence.
  const signUp = await request.get(new URL("user/sign_up", url!).toString());
  expect(signUp.url()).toMatch(/\/user\/sign_up$/);
  expect(signUp.status()).toBeLessThan(400);
  const body = await signUp.text();
  expect(body).not.toMatch(/registration is disabled/i);
  expect(body).toMatch(/name="password"/);

  // Stop → Stopped (scale-to-zero under the hood, quick); the price
  // line swaps to the storage-only fee — small stopped, $0.40 at B′.
  await page.getByTestId("stop-button").click();
  await waitForStatus(page, "Stopped", 60_000);
  await expect(page.getByTestId("instance-price")).toContainText(
    "$0.40/mo while stopped · billed hourly",
  );

  // Destroy: native confirm() dialog, teardown (async Oban) exits the
  // view to /instances where the fresh user's list is empty again
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await expect(page.getByTestId("instance-row")).toHaveCount(0);
});

// Poll the live badge until `want` shows; "Failed" fails fast with the
// status message — waiting out a dead deploy proves nothing. The badge
// reads #179's user-facing vocabulary (Running/Stopped/Failed…), never
// the internal state-machine atom.
async function waitForStatus(page: Page, want: string, timeoutMs: number) {
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
