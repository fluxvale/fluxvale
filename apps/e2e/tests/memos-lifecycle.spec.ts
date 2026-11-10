import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";
import { waitForStatus, destroyInstance } from "./helpers/instance-ui";

// Memos' full customer lifecycle through the real UI (#492), mirroring
// pocket-id-lifecycle and vaultwarden-lifecycle: sign in via TestInbox
// → catalog → deploy (no configuration inputs at all — SQLite and the
// upstream defaults are the whole story) → running → instance URL
// serves Memos over HTTPS → public instance profile reports 26.11.0 and
// needs_setup → claim the host account → stop → start → the claim
// survives → destroy. The restart leg is the #492 gate: Memos' SQLite
// state on the PVC must survive a stop / start cycle, and claiming the
// host before the stop makes that observable (needs_setup flips false
// and stays flipped). It crosses the real cluster — `running` lands on
// the reconcile cron's next tick after pod readiness, and a cold node
// pulls the Memos image first — so the waits are generous (ADR-00024
// §6).

// Traces are off for this spec only (the pocket-id posture): CI uploads
// the playwright report as an artifact on every run, and the host
// account's password would land in a public artifact on a red→green
// retry. The spec carries its own budgets and fail-fast error states.
test.use({ trace: "off" });

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// Local + staging runtimes (#116: staging is instance-capable). Production
// stays read-only (ADR-0024): the suite never mutates it.
test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test(
  "memos: catalog → deploy → running → open → claim host → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min: the budgets below (12 + 1 + 5) plus sign-in, catalog,
    // deploy and destroy interactions must fit under the cap.
    test.setTimeout(20 * 60_000);

    // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
    // gets touched, and the instances list starts empty)
    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Catalog → Memos. `micro` at B′ — the honest recommendation (#492:
    // a static Go binary over SQLite, upstream's whole pitch is
    // featherweight) — $2.83/mo, stated as a monthly-equivalent,
    // billed hourly.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
    await page.getByTestId("app-memos").click();
    await expect(
      page.getByRole("heading", { name: "Memos hosting", exact: true }),
    ).toBeVisible();
    await waitForLiveViewJoin(page);
    await expect(page.locator("[data-testid^='price-']").first()).toContainText(
      "$2.83/mo · billed hourly",
    );

    // Deploy stepper: version → configuration (NOTHING to configure —
    // Memos boots on upstream defaults alone, so the shipped
    // recommendation must be right on its own; the step renders its
    // empty-schema "Continue" and on we go) → resources at the
    // recommendation → name.
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await expect(
      page.getByText("Nothing to configure for this app."),
    ).toBeVisible();
    await page.getByTestId("continue-env").click();
    await expect(page.getByTestId("resources-price")).toContainText(
      "$2.83/mo · billed hourly",
    );
    await page.getByTestId("continue-resources").click();
    await expect(page.getByTestId("price-summary")).toContainText(
      "$2.83/mo · billed hourly",
    );
    const name = `e2e-memos-${runId}`;
    await page.getByTestId("instance-name").fill(name);
    await page.getByTestId("deploy-submit").click();

    // Status page: Provisioning → Starting → Running (live badge; no
    // polling in-page — PubSub re-renders, this loop just reads).
    await page.waitForURL(/\/instances\//);
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    await expect(page.getByTestId("instance-price")).toContainText(
      "$2.83/mo · billed hourly",
    );

    // The instance URL opens through Traefik (self-signed — ignored at
    // the config level) and serves the actual Memos app. Memos v26's
    // frontend is a client-rendered React SPA: the served HTML is an
    // empty shell, so the identity proof is upstream's own public
    // instance profile and the render proof is a hydrated heading in a
    // real browser (the raw shell matches nothing).
    const url = (await page.getByTestId("instance-url").textContent())?.trim();
    expect(url).toMatch(/^https:\/\//);
    const opened = await request.get(url!);
    expect(opened.status()).toBeLessThan(400);

    // The public profile carries the deployed version (the pinned
    // upstream release) and the first-run posture: needs_setup is true
    // while no account exists — the contract's runtime half (#492,
    // ADR-0034).
    const profile = await request.get(
      new URL("api/instance/profile", url!).toString(),
    );
    expect(profile.status()).toBe(200);
    const instanceProfile = (await profile.json()) as {
      version: string;
      needsSetup: boolean;
    };
    expect(instanceProfile.version).toBe("26.11.0");
    expect(instanceProfile.needsSetup).toBe(true);

    const ui = await page.context().newPage();
    await ui.goto(url!, { waitUntil: "networkidle", timeout: 60_000 });
    await expect(ui.locator("h1").first()).toBeVisible({ timeout: 30_000 });
    await ui.close();

    // Upstream's ready endpoint — a 200 whose body names the database
    // dependency explicitly ("Service ready." only while the SQLite
    // ping answers; 503 "Database unavailable." otherwise).
    const healthz = await request.get(new URL("healthz", url!).toString());
    expect(healthz.status()).toBe(200);

    // Claim the host now, before the restart leg: the claim lives in
    // Memos' SQLite on the PVC, so after the stop / start cycle
    // needs_setup must stay false — the observable half of the state-
    // survival gate. Registration is open on first boot (upstream's
    // own tests pin it) and the first account becomes the host. The
    // instance (and its volume) is destroyed at the end, so the claim
    // costs nothing.
    const password = `e2e-${randomHex(16)}`;
    const claimed = await request.post(new URL("api/users", url!).toString(), {
      data: {
        username: `e2e-admin-${runId}`,
        email: `e2e-admin-${runId}@example.com`,
        password,
      },
    });
    expect(claimed.status()).toBeLessThan(400);

    const claimedProfile = await request.get(
      new URL("api/instance/profile", url!).toString(),
    );
    expect(
      ((await claimedProfile.json()) as { needsSetup: boolean }).needsSetup,
    ).toBe(false);

    // Stop → Stopped (storage-only fee: micro stopped, $0.24 at B′).
    await page.getByTestId("stop-button").click();
    await waitForStatus(page, "Stopped", 60_000);
    await expect(page.getByTestId("instance-price")).toContainText(
      "$0.24/mo while stopped · billed hourly",
    );

    // … and back up: a clean restart serves the same instance (#492).
    // The restart is warm — image cached on the node, PVC in place, one
    // reconcile tick — so a much shorter budget than the cold first
    // start; a stuck restart should fail fast with its status message.
    await page.getByTestId("start-button").click();
    await waitForStatus(page, "Running", 5 * 60_000);

    // The state-survival half: the host claimed before the stop still
    // exists, so needs_setup stays false across the restart, and the
    // claimed credentials still sign in — the restored volume held the
    // user row, not just an empty schema.
    const revivedProfile = await request.get(
      new URL("api/instance/profile", url!).toString(),
    );
    expect(
      ((await revivedProfile.json()) as { needsSetup: boolean }).needsSetup,
    ).toBe(false);

    const signedIn = await request.post(
      new URL("api/auth/signin", url!).toString(),
      {
        data: {
          passwordCredentials: {
            username: `e2e-admin-${runId}`,
            password,
          },
        },
      },
    );
    expect(signedIn.status()).toBeLessThan(400);

    await destroyInstance(page);
  },
);

function randomHex(bytes: number) {
  const array = new Uint8Array(bytes);
  crypto.getRandomValues(array);
  return Array.from(array, (b) => b.toString(16).padStart(2, "0")).join("");
}
