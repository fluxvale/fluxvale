import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";
import { waitForStatus, destroyInstance } from "./helpers/instance-ui";

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
  await expect(page.getByRole("heading", { name: "Forgejo hosting", exact: true })).toBeVisible();
  await waitForLiveViewJoin(page);
  await expect(page.locator("[data-testid^='price-']").first()).toContainText(
    "$3.35/mo · billed hourly",
  );

  // Deploy stepper: version → configuration (seed defaults carry) →
  // resources → name. The resources step exercises #186's formula
  // pricing with a custom allocation: cpu 1 over Forgejo's `small`
  // recommendation (0.5/512/10), the live estimate repricing to the
  // v5 B′ curve's $3.90/mo before continuing (#206 — the label also
  // states billed-hourly; #558 rounds the compute and storage axes
  // independently, so the 1 CPU/512 MB compute plus 10 GB storage
  // reads 390¢ where the round-the-sum figure was 391¢). The allocation is selected (#195 —
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
  await expect(page.getByTestId("resources-price")).toContainText("$3.90/mo · billed hourly");
  await page.getByTestId("continue-resources").click();
  await expect(page.getByTestId("price-summary")).toContainText("$3.90/mo · billed hourly");
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

  // The instance page shows the row's OWN settlement rate (#493 closed
  // the #206-era gap): this custom-allocation instance bills its $3.90
  // formula snapshot (#186), and the Details row now says so — the
  // same resolver the accrual prices through. Framing is the same
  // monthly-equivalent/billed-hourly as every surface.
  await expect(page.getByTestId("instance-price")).toContainText(
    "$3.90/mo · billed hourly",
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

  await destroyInstance(page);
});
