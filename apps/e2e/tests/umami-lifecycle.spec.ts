import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { promisify } from "node:util";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

const run = promisify(execFile);

// Umami's full customer lifecycle through the real UI (#576), mirroring
// memos-lifecycle and pocket-id-lifecycle: sign in via TestInbox →
// catalog → deploy (filling the two required inputs — DATABASE_URL and
// APP_SECRET, the Pocket ID ENCRYPTION_KEY shape) → running → instance
// URL serves Umami over HTTPS → /api/heartbeat answers 200 ok → the
// default admin (admin/umami, seeded by upstream's own first migration)
// signs in through the public API → stop → start → the same admin still
// signs in → destroy. The restart leg is the state gate: Umami keeps
// every row in the PostgreSQL database the deploy names, so the admin
// surviving the stop/start cycle proves the external-database posture
// end to end (there is no PVC — storage is 0 GB and the stopped rate is
// the honest $0.00).
//
// The database is the e2e stack's own CNPG cluster — the owner-supplied
// Postgres the catalog entry asks for, played by the one Postgres the
// ephemeral cluster already runs. CNPG disables superuser TCP access by
// default (enableSuperuserAccess false), so the spec creates a per-run
// login role + database owned by it through the primary pod's local
// socket (peer-mapped to the postgres superuser, the backups spec's
// kubectl pattern) and connects the instance over the in-cluster -rw
// service as that role; instance egress is open (NetworkPolicy denies
// ingress only), so the pod reaches fluxvale-dev like the backups Jobs
// reach MinIO.

// Traces are off for this spec only (the pocket-id posture): the report
// artifact is public, and a trace records each fill's literal value —
// the DATABASE_URL carries a live database password and APP_SECRET is
// a live secret, dots in the DOM or not.
test.use({ trace: "off" });

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// LOCAL-ONLY like backups.spec.ts: the spec provisions its database by
// kubectl exec into the local stack's CNPG primary, and the
// DATABASE_URL it fills names that cluster's -rw service — on any
// other runtime the deploy would point at a host it cannot resolve
// (staging's #497-convention proof run adapts a copy with the staging
// context and namespace, never this file).
test.skip(
  runtime !== "local",
  "local only, like backups.spec.ts — the database provisioning and DATABASE_URL name the local stack's CNPG",
);

const CNPG_POD = "fluxvale-cnpg-1";
const CNPG_HOST = "fluxvale-cnpg-rw.fluxvale-dev.svc.cluster.local:5432";
const PLATFORM_NAMESPACE = "fluxvale-dev";

test(
  "umami: catalog → deploy → running → open → default admin → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min: the budgets below (12 + 1 + 5) plus sign-in, catalog,
    // deploy, the database provisioning, and destroy must fit the cap.
    test.setTimeout(20 * 60_000);

    // The owner-supplied Postgres: a per-run database in the stack's
    // CNPG cluster, owned by a per-run login role (superuser TCP access
    // is off by default, so the role is the connection identity).
    const suffix = runId.replace(/[^a-z0-9]/g, "");
    const database = `umami_e2e_${suffix}`;
    const dbRole = `umami_e2e_${suffix}`;
    // base64url keeps the password URL-safe for the connection string.
    const dbPassword = randomBytes(18).toString("base64url");
    await kubectl([
      "-n",
      PLATFORM_NAMESPACE,
      "exec",
      CNPG_POD,
      "--",
      "psql",
      "-U",
      "postgres",
      "-c",
      `CREATE ROLE ${dbRole} LOGIN PASSWORD '${dbPassword}'`,
    ]);
    await kubectl([
      "-n",
      PLATFORM_NAMESPACE,
      "exec",
      CNPG_POD,
      "--",
      "psql",
      "-U",
      "postgres",
      "-c",
      `CREATE DATABASE ${database} OWNER ${dbRole}`,
    ]);

    const databaseUrl = `postgresql://${dbRole}:${dbPassword}@${CNPG_HOST}/${database}`;
    const appSecret = randomBytes(24).toString("base64");

    try {
      // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
      // gets touched, and the instances list starts empty)
      const email = `test+e2e-${runId}@fluxvale.com`;
      await signIn(page, new TestInbox(request, testInboxToken!), email);

      // Catalog → Umami. `micro` at B′ — the honest recommendation
      // (#576: a single Node process idling around 200 MB) — $2.59/mo
      // with zero storage on its own axis, stated as a
      // monthly-equivalent, billed hourly.
      await page.goto("/apps");
      await waitForLiveViewJoin(page);
      await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
      await page.getByTestId("app-umami").click();
      await expect(
        page.getByRole("heading", { name: "Umami", exact: true }),
      ).toBeVisible();
      await waitForLiveViewJoin(page);
      await expect(page.locator("[data-testid^='price-']").first()).toContainText(
        "$2.59/mo · billed hourly",
      );

      // Deploy stepper: version → configuration (TWO required inputs —
      // the connection string and the app secret, both rendered as
      // password fields; the optional 2FA key stays empty) → resources
      // at the recommendation → name.
      await page.locator("[data-testid^='deploy-']").first().click();
      await waitForLiveViewJoin(page);
      await page.getByTestId("version-option").first().check();
      await page.getByTestId("continue-version").click();
      await page.locator("#env-form").waitFor({ state: "visible" });
      await page.locator("#env-DATABASE_URL").fill(databaseUrl);
      await page.locator("#env-APP_SECRET").fill(appSecret);
      await page.getByTestId("continue-env").click();
      await expect(page.getByTestId("resources-price")).toContainText(
        "$2.59/mo · billed hourly",
      );
      await page.getByTestId("continue-resources").click();
      await expect(page.getByTestId("price-summary")).toContainText(
        "$2.59/mo · billed hourly",
      );
      const name = `e2e-umami-${runId}`;
      await page.getByTestId("instance-name").fill(name);
      await page.getByTestId("deploy-submit").click();

      // Status page: Provisioning → Starting → Running (live badge; no
      // polling in-page — PubSub re-renders, this loop just reads). The
      // cold start runs prisma's migrations before the server answers,
      // so the budget matches the other cold pulls (ADR-00024 §6).
      await page.waitForURL(/\/instances\//);
      await waitForLiveViewJoin(page);
      await waitForStatus(page, "Running", 12 * 60_000);

      await expect(page.getByTestId("instance-price")).toContainText(
        "$2.59/mo · billed hourly",
      );

      // The instance URL opens through Traefik (self-signed — ignored
      // at the config level) and serves the actual Umami app. Umami is
      // a Next.js app: the shell SSRs the login form, so the render
      // proof is the real login fields in a real browser.
      const url = (await page.getByTestId("instance-url").textContent())?.trim();
      expect(url).toMatch(/^https:\/\//);
      const opened = await request.get(url!);
      expect(opened.status()).toBeLessThan(400);

      const ui = await page.context().newPage();
      await ui.goto(new URL("login", url!).toString(), {
        waitUntil: "networkidle",
        timeout: 60_000,
      });
      await expect(ui.locator("input[name='username']")).toBeVisible({
        timeout: 30_000,
      });
      await ui.close();

      // Upstream's own liveness endpoint — the path the image's
      // HEALTHCHECK probes; an unauthenticated 200 with ok in the body.
      const heartbeat = await request.get(new URL("api/heartbeat", url!).toString());
      expect(heartbeat.status()).toBe(200);
      expect(((await heartbeat.json()) as { ok: boolean }).ok).toBe(true);

      // The first-run contract's runtime half (ADR-0034 Am. 2): the
      // default admin exists and signs in through the public API —
      // upstream's first migration seeded it, so this also proves the
      // boot migrations ran against the owner-supplied database. The
      // issued token then reads the (empty) website list: the whole
      // auth path works.
      const login = await request.post(new URL("api/auth/login", url!).toString(), {
        data: { username: "admin", password: "umami" },
      });
      expect(login.status()).toBeLessThan(400);
      const session = (await login.json()) as { token: string; user: { role: string } };
      expect(session.user.role).toBe("admin");

      const websites = await request.get(new URL("api/websites", url!).toString(), {
        headers: { authorization: `Bearer ${session.token}` },
      });
      expect(websites.status()).toBe(200);

      // Stop → Stopped (storage-only fee: zero storage, so the honest
      // stopped rate is $0.00 — the compute class is all there is).
      await page.getByTestId("stop-button").click();
      await waitForStatus(page, "Stopped", 60_000);
      await expect(page.getByTestId("instance-price")).toContainText(
        "$0.00/mo while stopped · billed hourly",
      );

      // … and back up: a clean restart serves the same instance. The
      // app container is stateless, so this leg is really about the
      // named database still being there — asserted below by signing
      // in again after the restart.
      await page.getByTestId("start-button").click();
      await waitForStatus(page, "Running", 5 * 60_000);
      const revivedHeartbeat = await request.get(
        new URL("api/heartbeat", url!).toString(),
      );
      expect(revivedHeartbeat.status()).toBe(200);

      // The state-survival half: the admin seeded before the stop still
      // signs in — the user row lived in the external Postgres across
      // the whole stop / start cycle.
      const revivedLogin = await request.post(
        new URL("api/auth/login", url!).toString(),
        { data: { username: "admin", password: "umami" } },
      );
      expect(revivedLogin.status()).toBeLessThan(400);

      // Destroy: native confirm() dialog, teardown (async Oban) exits
      // the view to /instances where the fresh user's list is empty
      // again.
      page.once("dialog", (dialog) => dialog.accept());
      await page.getByTestId("delete-button").click();
      await page.waitForURL(/\/instances$/);
      await expect(page.getByTestId("instance-row")).toHaveCount(0);
    } finally {
      // Local re-runs share a persistent cluster; CI's is ephemeral.
      // Either way the per-run database and role go away with the spec
      // — best-effort (a green lifecycle must never report red at
      // teardown, and a failed one must keep its original error).
      // WITH (FORCE) terminates the connections the just-destroyed
      // instance's async Oban teardown may still hold; the role drop
      // follows only once the database is gone (a role that owns
      // anything refuses the drop).
      await kubectl(
        [
          "-n",
          PLATFORM_NAMESPACE,
          "exec",
          CNPG_POD,
          "--",
          "psql",
          "-U",
          "postgres",
          "-c",
          `DROP DATABASE ${database} WITH (FORCE)`,
        ],
        { bestEffort: true },
      );
      await kubectl(
        [
          "-n",
          PLATFORM_NAMESPACE,
          "exec",
          CNPG_POD,
          "--",
          "psql",
          "-U",
          "postgres",
          "-c",
          `DROP ROLE ${dbRole}`,
        ],
        { bestEffort: true },
      );
    }
  },
);

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

async function kubectl(
  args: string[],
  options: { bestEffort?: boolean } = {},
): Promise<string> {
  // promisify(execFile) has no reject:false — an unknown option is
  // silently ignored and a non-zero exit still rejects, so best-effort
  // callers (the teardown) swallow failures HERE, not in an option the
  // library never reads.
  const result = run("kubectl", ["--context", "k3d-fluxvale", ...args]);

  if (options.bestEffort) {
    return result.then(
      ({ stdout }) => stdout,
      () => "",
    );
  }

  return (await result).stdout;
}
