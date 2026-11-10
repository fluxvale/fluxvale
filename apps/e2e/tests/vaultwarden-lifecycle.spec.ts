import { expect, test } from "@playwright/test";
import { waitForStatus, destroyInstance } from "./helpers/instance-ui";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// Vaultwarden's full customer lifecycle through the real UI (#492),
// mirroring forgejo-lifecycle: sign in via TestInbox → catalog → deploy
// → running → instance URL serves the web vault → admin panel denied →
// stop → start → destroy. The restart leg is the #492 gate, not
// flourish: Vaultwarden's SQLite state on the PVC must survive a stop /
// start cycle cleanly. It crosses the real cluster — `running` lands on
// the reconcile cron's next tick after pod readiness, and a cold node
// pulls the Vaultwarden image first — so the waits are generous
// (ADR-00024 §6).

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
  "vaultwarden: catalog → deploy → running → open → admin denied → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min: the budgets below (12 + 1 + 5) plus sign-in, catalog,
    // deploy and destroy interactions must fit under the cap.
    test.setTimeout(20 * 60_000);

    // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
    // gets touched, and the instances list starts empty)
    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Catalog → Vaultwarden. `micro` at B′ — the honest recommendation
    // (#492: a single Rust binary with SQLite, no server-side vault
    // crypto) — $2.83/mo, stated as a monthly-equivalent, billed hourly.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
    await page.getByTestId("app-vaultwarden").click();
    await expect(
      page.getByRole("heading", { name: "Vaultwarden hosting", exact: true }),
    ).toBeVisible();
    await waitForLiveViewJoin(page);
    await expect(page.locator("[data-testid^='price-']").first()).toContainText(
      "$2.83/mo · billed hourly",
    );

    // Deploy stepper: version → configuration (one optional input — the
    // sign-ups whitelist, default open — nothing to fill) → resources at
    // the recommendation → name. Keeping the defaults is the point: the
    // shipped recommendation must be right on its own (#492).
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    await page.getByTestId("continue-version").click();
    await page.getByTestId("continue-env").click();
    await expect(page.getByTestId("resources-price")).toContainText(
      "$2.83/mo · billed hourly",
    );
    await page.getByTestId("continue-resources").click();
    await expect(page.getByTestId("price-summary")).toContainText(
      "$2.83/mo · billed hourly",
    );
    const name = `e2e-vaultwarden-${runId}`;
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
    // the config level) and serves the actual web vault, not a
    // placeholder that merely answers 200.
    const url = (await page.getByTestId("instance-url").textContent())?.trim();
    expect(url).toMatch(/^https:\/\//);
    const opened = await request.get(url!);
    expect(opened.status()).toBeLessThan(400);
    expect(await opened.text()).toMatch(/Vaultwarden|Bitwarden/i);

    // Upstream's own health endpoint — an unauthenticated 200 (the image
    // HEALTHCHECK probes the same path).
    const alive = await request.get(new URL("alive", url!).toString());
    expect(alive.status()).toBe(200);

    // #492 gate, at runtime: the admin panel is disabled in packaging.
    // With no ADMIN_TOKEN configured, Vaultwarden mounts /admin as a
    // static notice — HTTP 200, "The admin panel is disabled, please
    // configure the 'ADMIN_TOKEN' variable to enable it". That
    // responder exists only while no token is set, so the notice IS the
    // absence proof; the panel's login UI must never render.
    const admin = await request.get(new URL("admin", url!).toString());
    expect(admin.status()).toBe(200);
    expect(await admin.text()).toMatch(/admin panel is disabled/i);

    // Stop → Stopped (storage-only fee: micro stopped, $0.24 at B′).
    await page.getByTestId("stop-button").click();
    await waitForStatus(page, "Stopped", 60_000);
    await expect(page.getByTestId("instance-price")).toContainText(
      "$0.24/mo while stopped · billed hourly",
    );

    // … and back up: a clean restart serves the same vault (#492). The
    // restart is warm — image cached on the node, PVC in place, one
    // reconcile tick — so a much shorter budget than the cold first
    // start; a stuck restart should fail fast with its status message.
    await page.getByTestId("start-button").click();
    await waitForStatus(page, "Running", 5 * 60_000);
    const revived = await request.get(new URL("alive", url!).toString());
    expect(revived.status()).toBe(200);

    await destroyInstance(page);
  },
);
