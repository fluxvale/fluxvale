import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { promisify } from "node:util";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

const run = promisify(execFile);

// Docmost's full customer lifecycle through the real UI (#609),
// mirroring umami-lifecycle: sign in via TestInbox → catalog → deploy
// (filling the THREE required inputs — DATABASE_URL, REDIS_URL, and
// APP_SECRET, the BYO-interim shape until the bundled-services
// consumer slice takes the two connection strings over) → running →
// instance URL serves Docmost over HTTPS → /api/health answers 200
// with database and redis both up (the dependency-aware endpoint) →
// the setup page's first account becomes the workspace admin
// (POST /api/auth/setup 200, a second setup 403, the admin signs in)
// → the SPA login form renders in a real browser and the session
// uploads a file through the app's own multipart endpoint (the volume
// proof: UID 1000 writes the PVC through the pod's fsGroup grant,
// read back over the app's file route) → stop → start → the admin
// still signs in AND the uploaded file still reads (the external
// PostgreSQL held the rows, the instance volume held the bytes) →
// destroy. The restart leg is the state gate: with both services
// owner-run, everything that matters lives past the stop/start cycle.
//
// The owner-supplied services are played by the e2e stack's own
// cluster: the database by the stack's CNPG (a per-run role +
// database, exactly umami-lifecycle's pattern — CNPG disables
// superuser TCP access by default, so the role is the connection
// identity) and Redis by a per-run pod in a per-run namespace (no
// bundled consumer exists yet, so the spec brings its own — the
// ephemeral CI cluster and the local one both run plain k3s, where a
// namespace with no NetworkPolicy is reachable from instance
// namespaces because instance egress is open, the NetworkPolicy
// denies ingress only).
//
// Traces are off for this spec only (the pocket-id posture): the
// report artifact is public, and a trace records each fill's literal
// value — the DATABASE_URL carries a live database password and
// APP_SECRET is a live secret, dots in the DOM or not.
test.use({ trace: "off" });

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// LOCAL-ONLY like backups.spec.ts: the spec provisions its services by
// kubectl (CNPG role + database, a Redis namespace) and the
// connection strings it fills name that local cluster's services — on
// any other runtime the deploy would point at hosts it cannot resolve
// (staging's #497-convention proof run adapts a copy with the staging
// context and namespace, never this file).
test.skip(
  runtime !== "local",
  "local only, like backups.spec.ts — the service provisioning and connection strings name the local stack's cluster",
);

const CNPG_POD = "fluxvale-cnpg-1";
const CNPG_HOST = "fluxvale-cnpg-rw.fluxvale-dev.svc.cluster.local:5432";
const PLATFORM_NAMESPACE = "fluxvale-dev";

test(
  "docmost: catalog → deploy → running → setup admin → upload → stop → start → destroy",
  async ({ page, request }) => {
    // 20 min, umami-lifecycle's bound: the leg ceiling math (ci.yml's
    // comment) assumes a retry of this spec fits twice inside the 60m
    // job — 17.1m leg worst + 2 × 20m = 57.1m. The budgets below
    // (10 + 1 + 4) plus sign-in, catalog, deploy, the service
    // provisioning, the upload proof, and destroy fit the same 20m.
    test.setTimeout(20 * 60_000);

    const suffix = runId.replace(/[^a-z0-9]/g, "").slice(-12);
    const database = `docmost_e2e_${suffix}`;
    const dbRole = `docmost_e2e_${suffix}`;
    const redisNamespace = `fv609-e2e-${suffix}`;
    const redisHost = `redis.${redisNamespace}.svc.cluster.local:6379`;
    // base64url keeps the password URL-safe for the connection string.
    const dbPassword = randomBytes(18).toString("base64url");

    const databaseUrl = `postgresql://${dbRole}:${dbPassword}@${CNPG_HOST}/${database}`;
    const redisUrl = `redis://${redisHost}`;
    const appSecret = randomBytes(24).toString("base64");

    try {
      // The owner-supplied PostgreSQL: a per-run database in the
      // stack's CNPG cluster, owned by a per-run login role. Inside
      // the try on purpose: if CREATE DATABASE dies after CREATE ROLE
      // lands, the finally still drops the role — the persistent
      // local cluster keeps nothing of a failed run.
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

      // The owner-supplied Redis: a per-run namespace with one pod and
      // service, mirroring the pin the platform's own registry chose
      // for redis 8 (#612's config — the same image Docmost's compose
      // ships). Delete-and-apply keeps a re-run of the same suffix
      // convergent.
      await kubectl(["delete", "namespace", redisNamespace, "--ignore-not-found=true"]);
      await kubectl(["create", "namespace", redisNamespace]);
      await kubectl([
        "create",
        "deployment",
        "--namespace",
        redisNamespace,
        "redis",
        "--image=docker.io/library/redis:8.10.3-alpine3.23",
      ]);
      await kubectl([
        "expose",
        "deployment",
        "--namespace",
        redisNamespace,
        "redis",
        "--port=6379",
        "--target-port=6379",
      ]);
      await kubectl([
        "--namespace",
        redisNamespace,
        "rollout",
        "status",
        "deployment/redis",
        "--timeout=300s",
      ]);

      // Sign in as a fresh per-run user (JIT-provisioned; nobody's
      // data gets touched, and the instances list starts empty)
      const email = `test+e2e-${runId}@fluxvale.com`;
      await signIn(page, new TestInbox(request, testInboxToken!), email);

      // Catalog → Docmost. `medium` at B′ — the honest recommendation
      // (#609: the app alone idles around 150 MB anonymous but its
      // working set sits near 445 Mi with zero content, and a real
      // team's wiki grows past the 512 MB classes) — $3.93/mo with
      // the 5 GB upload volume on its own axis, stated as a
      // monthly-equivalent, billed hourly.
      await page.goto("/apps");
      await waitForLiveViewJoin(page);
      await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
      await page.getByTestId("app-docmost").click();
      await expect(
        page.getByRole("heading", { name: "Docmost", exact: true }),
      ).toBeVisible();
      await waitForLiveViewJoin(page);
      await expect(page.locator("[data-testid^='price-']").first()).toContainText(
        "$3.93/mo · billed hourly",
      );

      // Deploy stepper: version → configuration (THREE required inputs
      // — the two connection strings and the app secret, all rendered
      // as password fields) → resources at the recommendation → name.
      await page.locator("[data-testid^='deploy-']").first().click();
      await waitForLiveViewJoin(page);
      await page.getByTestId("version-option").first().check();
      await page.getByTestId("continue-version").click();
      await page.locator("#env-form").waitFor({ state: "visible" });
      await page.locator("#env-DATABASE_URL").fill(databaseUrl);
      await page.locator("#env-REDIS_URL").fill(redisUrl);
      await page.locator("#env-APP_SECRET").fill(appSecret);
      await page.getByTestId("continue-env").click();
      await expect(page.getByTestId("resources-price")).toContainText(
        "$3.93/mo · billed hourly",
      );
      await page.getByTestId("continue-resources").click();
      await expect(page.getByTestId("price-summary")).toContainText(
        "$3.93/mo · billed hourly",
      );
      const name = `e2e-docmost-${runId}`;
      await page.getByTestId("instance-name").fill(name);
      await page.getByTestId("deploy-submit").click();

      // Status page: Provisioning → Starting → Running (live badge; no
      // polling in-page — PubSub re-renders, this loop just reads).
      // The cold start runs the boot migrations before the server
      // answers (measured ~26s to a green /api/health at this
      // allocation on a warm image), so the budget mostly covers the
      // CI image pull.
      await page.waitForURL(/\/instances\//);
      await waitForLiveViewJoin(page);
      await waitForStatus(page, "Running", 10 * 60_000);

      await expect(page.getByTestId("instance-price")).toContainText(
        "$3.93/mo · billed hourly",
      );

      // The instance URL opens through Traefik (self-signed — ignored
      // at the config level) and serves the actual Docmost app: the
      // SPA shell answers, and upstream's dependency-aware health
      // endpoint reports both owner-run services up — an unauthenticated
      // 200 whose body says database and redis are both "up".
      const url = (await page.getByTestId("instance-url").textContent())?.trim();
      expect(url).toMatch(/^https:\/\//);
      const opened = await request.get(url!);
      expect(opened.status()).toBeLessThan(400);

      const health = await request.get(new URL("api/health", url!).toString());
      expect(health.status()).toBe(200);
      const healthBody = (await health.json()) as {
        status: string;
        info: Record<string, { status: string }>;
      };
      expect(healthBody.status).toBe("ok");
      expect(healthBody.info.database.status).toBe("up");
      expect(healthBody.info.redis.status).toBe("up");

      // The first-run contract's runtime half (ADR-0034): the setup
      // page creates the workspace and the first account in one step
      // and then closes. The created admin signs in through the public
      // API — this also proves the boot migrations ran against the
      // owner-supplied database, since the account row lives there.
      const adminEmail = `docmost-admin-${suffix}@fluxvale.test`;
      const adminPassword = randomBytes(12).toString("base64url");

      const setup = await request.post(new URL("api/auth/setup", url!).toString(), {
        data: {
          workspaceName: `E2E ${suffix}`,
          name: "E2E Owner",
          email: adminEmail,
          password: adminPassword,
        },
      });
      expect(setup.status()).toBeLessThan(400);
      const setupWorkspace = (await setup.json()) as {
        data: { defaultSpaceId: string };
      };

      const setupAgain = await request.post(
        new URL("api/auth/setup", url!).toString(),
        {
          data: {
            workspaceName: "Impostor",
            name: "Nope",
            email: `impostor-${suffix}@fluxvale.test`,
            password: "not-going-to-work",
          },
        },
      );
      expect(setupAgain.status()).toBe(403);

      const login = await request.post(new URL("api/auth/login", url!).toString(), {
        data: { email: adminEmail, password: adminPassword },
      });
      expect(login.status()).toBeLessThan(400);

      // The browser-render proof (the umami-lifecycle shape): the SPA
      // login form renders in a real browser, the admin signs in
      // through it, and the same authenticated session then drives the
      // upload below — the cookie path is the one real users ride.
      const ui = await page.context().newPage();
      await ui.goto(new URL("login", url!).toString(), {
        waitUntil: "networkidle",
        timeout: 60_000,
      });
      await expect(ui.getByLabel("Email", { exact: true })).toBeVisible({
        timeout: 30_000,
      });
      await ui.getByLabel("Email", { exact: true }).fill(adminEmail);
      await ui.getByLabel("Password", { exact: true }).fill(adminPassword);
      await ui.getByRole("button", { name: "Sign in" }).click();
      await ui.waitForURL(/home/, { timeout: 30_000 });

      // The volume proof — the claim the $0.24 stopped price rests on:
      // a page in the setup-created default space, a file uploaded
      // through the app's own multipart endpoint (written by UID 1000
      // onto the PVC through the pod's fsGroup grant), read back over
      // the app's own file route, all from the authenticated session.
      // The upload handler answers bare (@Res bypasses the response
      // transform); the page create is wrapped ({data}). The marker
      // rides the file's bytes so the read-back can't pass on a
      // different file.
      const marker = `fv609-upload-proof-${suffix}`;
      const upload = await ui.evaluate(
        async ({ spaceId, marker, fileBase }) => {
          const pageRes = await fetch("/api/pages", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ spaceId, title: "E2E upload proof" }),
            credentials: "include",
          });
          if (!pageRes.ok) throw new Error(`page create failed: ${pageRes.status}`);

          const created = (await pageRes.json()) as { data: { id: string } };
          const form = new FormData();
          form.append("pageId", created.data.id);
          form.append("file", new File([`${marker}\n`], "upload-proof.txt", {
            type: "text/plain",
          }));

          const upRes = await fetch("/api/files/upload", {
            method: "POST",
            body: form,
            credentials: "include",
          });
          if (!upRes.ok) throw new Error(`upload failed: ${upRes.status}`);

          const up = (await upRes.json()) as { url?: string; data?: { url?: string } };
          const fileUrl = new URL(up.url ?? up.data?.url ?? "", fileBase);
          const path = `${fileUrl.pathname}${fileUrl.search}`;
          const fileRes = await fetch(path, { credentials: "include" });

          return { status: fileRes.status, text: await fileRes.text(), path };
        },
        { spaceId: setupWorkspace.defaultSpaceId, marker, fileBase: url! },
      );
      expect(upload.status).toBe(200);
      expect(upload.text).toContain(marker);

      // Stop → Stopped (storage-only fee: the 5 GB upload volume at
      // the storage axis rate — the honest stopped rate is $0.24, not
      // Umami's $0.00, because this app keeps a volume).
      await page.getByTestId("stop-button").click();
      await waitForStatus(page, "Stopped", 60_000);
      await expect(page.getByTestId("instance-price")).toContainText(
        "$0.24/mo while stopped · billed hourly",
      );

      // … and back up: a clean restart serves the same instance. The
      // app container is stateless over its two owner-run services, so
      // this leg is about the named database and Redis still being
      // there — asserted below by the health body and a second sign-in
      // after the restart.
      await page.getByTestId("start-button").click();
      await waitForStatus(page, "Running", 4 * 60_000);
      const revivedHealth = await request.get(
        new URL("api/health", url!).toString(),
      );
      expect(revivedHealth.status()).toBe(200);

      // The state-survival half: the admin created before the stop
      // still signs in — the user row lived in the external Postgres
      // across the whole stop / start cycle.
      const revivedLogin = await request.post(
        new URL("api/auth/login", url!).toString(),
        { data: { email: adminEmail, password: adminPassword } },
      );
      expect(revivedLogin.status()).toBeLessThan(400);

      // The volume's state-survival half: the uploaded file still
      // reads back after the stop / start cycle — the bytes lived on
      // the instance volume the whole time (the fsGroup grant is what
      // let UID 1000 write them, #609's deployer fix).
      const revivedUpload = await ui.evaluate(
        async ({ path, marker }) => {
          const fileRes = await fetch(path, { credentials: "include" });
          return { status: fileRes.status, text: await fileRes.text(), marker };
        },
        { path: upload.path, marker },
      );
      expect(revivedUpload.status).toBe(200);
      expect(revivedUpload.text).toContain(marker);
      await ui.close();

      // Destroy: native confirm() dialog, teardown (async Oban) exits
      // the view to /instances where the fresh user's list is empty
      // again.
      page.once("dialog", (dialog) => dialog.accept());
      await page.getByTestId("delete-button").click();
      await page.waitForURL(/\/instances$/);
      await expect(page.getByTestId("instance-row")).toHaveCount(0);
    } finally {
      // Local re-runs share a persistent cluster; CI's is ephemeral.
      // Either way the per-run services go away with the spec —
      // best-effort (a green lifecycle must never report red at
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
      await kubectl(
        ["delete", "namespace", redisNamespace, "--ignore-not-found=true"],
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
  // library never reads. The strict path rethrows REDACTED: execFile's
  // rejection message leads with "Command failed:" plus the full
  // command line, and the CREATE ROLE line carries the database
  // password — the report artifact is public (the trace-off posture,
  // above), so only the exit code and stderr may reach it.
  const result = run("kubectl", ["--context", "k3d-fluxvale", ...args]);

  if (options.bestEffort) {
    return result.then(
      ({ stdout }) => stdout,
      () => "",
    );
  }

  try {
    return (await result).stdout;
  } catch (error) {
    const exit = (error as { code?: number }).code;
    const stderr = String((error as { stderr?: string }).stderr ?? "").trim();

    throw new Error(
      `kubectl failed (exit ${exit ?? "unknown"}): ${stderr.slice(0, 200) || "no stderr; see the run log"}`,
    );
  }
}
