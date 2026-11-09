import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { promisify } from "node:util";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

const run = promisify(execFile);

// Umami's full customer lifecycle through the real UI (#576; the
// bundled-backing-services row since #612 S4 — the OQ #3 takeover's
// proof consumer): sign in via TestInbox → catalog → deploy (ONE
// required input, APP_SECRET — DATABASE_URL never renders: the
// bundled PostgreSQL 18 owns it, the platform composes it at deploy)
// → running → instance URL serves Umami over HTTPS → /api/heartbeat
// answers 200 ok → the default admin (username admin, password umami,
// seeded by upstream's own first migration INTO THE BUNDLED POSTGRES)
// signs in through the public API → RESTART LEG: delete the pod, the
// app and its database re-boot together (native-sidecar init
// ordering), the admin still signs in — the bundled database's data
// survived on the instance volume → stop → storage-only interlude
// ($0.40/mo — the 10 GB the data now rides) → start → the admin still
// signs in → destroy. The two persistence legs are the #612 S4 gate:
// this is the entry where the bundled DATABASE stops being platform
// machinery and starts being customer data.

// Traces are off for this spec only (the pocket-id posture): the
// report artifact is public, and a trace records each fill's literal
// value — APP_SECRET is a live secret, dots in the DOM or not.
test.use({ trace: "off" });

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

// LOCAL-ONLY like backups.spec.ts: the restart leg drives the cluster
// itself (kubectl delete pod in the instance's namespace — the page
// renders the namespace to admins only, #179), and that reach exists
// only where the suite shares the machine with the k3d cluster (local
// + CI's ephemeral runner). Staging runs an adapted copy per the #497
// convention, never this file.
test.skip(
  runtime !== "local",
  "local only — the restart leg kubectl-deletes the app pod",
);

test(
  "umami: catalog → deploy → running → open → default admin → pod restart → stop → start → destroy",
  async ({ page, request }) => {
    // 30 min: the budgets below (12 + 6 + 1 + 6) plus sign-in, catalog,
    // deploy, the database provisioning, and destroy must fit the cap.
    test.setTimeout(30 * 60_000);

    // APP_SECRET is the one input the platform cannot provide (the
    // Pocket ID ENCRYPTION_KEY shape).
    const appSecret = randomBytes(24).toString("base64");

    // Sign in as a fresh per-run user (JIT-provisioned; nobody's data
    // gets touched, and the instances list starts empty)
    const email = `test+e2e-${runId}@fluxvale.com`;
    await signIn(page, new TestInbox(request, testInboxToken!), email);

    // Catalog → Umami. `medium` + 10 GB — the bundled row's honest
    // recommendation (the app idles ~123 MiB measured; the bundled
    // PostgreSQL carves 0.10 CPU / 256 MB of the envelope) — $4.09/mo,
    // stated as a monthly-equivalent, billed hourly.
    await page.goto("/apps");
    await waitForLiveViewJoin(page);
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
    await page.getByTestId("app-umami").click();
    await expect(
      page.getByRole("heading", { name: "Umami hosting", exact: true }),
    ).toBeVisible();
    await waitForLiveViewJoin(page);
    await expect(page.locator("[data-testid^='price-']").first()).toContainText(
      "$4.09/mo · billed hourly",
    );

    // Deploy stepper: version (the bundled row sorts first —
    // "3.4.1-bundled" > "3.4.1" as a string) → configuration (the
    // bundled note INSTEAD of the two platform-owned inputs; APP_SECRET
    // the one fill; the optional 2FA key stays empty) → resources at
    // the floored recommendation → name.
    await page.locator("[data-testid^='deploy-']").first().click();
    await waitForLiveViewJoin(page);
    await page.getByTestId("version-option").first().check();
    // The version text rides the wrapping <label> — an input carries
    // no text, so toContainText on the radio itself can only read ""
    // (found the hard way: this spec's first CI run was its first
    // execution anywhere; every locator here is now markup-verified).
    await expect(
      page.locator("label:has(> input[data-testid='version-option'])").first(),
    ).toContainText("3.4.1-bundled");
    await page.getByTestId("continue-version").click();
    await page.locator("#bundled-env-note").waitFor();
    await expect(page.getByTestId("bundled-env-note")).toContainText(
      "PostgreSQL 18",
    );
    await page.locator("#env-APP_SECRET").fill(appSecret);
    // The platform-owned key never renders (D6) — a hidden input would
    // be a takeover trap the create refuses.
    await expect(page.locator("#env-DATABASE_URL")).toHaveCount(0);
    await page.getByTestId("continue-env").click();

    // Resources: the honest-share disclosure, sliders floored at the
    // version's defaults (storage starts at 10 GB — no 0 or 5 rung;
    // the bundled row has data to keep).
    await page.getByTestId("bundled-services-note").waitFor();
    await page.locator("#resource-storage-gb-ticks [data-value='10']").waitFor();
    await expect(
      page.locator("#resource-storage-gb-ticks [data-value='0']"),
    ).toHaveCount(0);
    await expect(page.getByTestId("resources-price")).toContainText(
      "$4.09/mo · billed hourly",
    );
    await page.getByTestId("continue-resources").click();
    await expect(page.getByTestId("price-summary")).toContainText(
      "$4.09/mo · billed hourly",
    );
    const name = `e2e-umami-${runId}`;
    await page.getByTestId("instance-name").fill(name);
    await page.getByTestId("deploy-submit").click();

    // Status page: Provisioning → Starting → Running (live badge; no
    // polling in-page — PubSub re-renders, this loop just reads). The
    // cold start runs prisma's migrations against the bundled
    // PostgreSQL after the sidecar's startup probe passes, so the
    // budget matches the other cold pulls (ADR-00024 §6).
    await page.waitForURL(/\/instances\//);
    // The platform's own deterministic mapping (namespace.ex): one
    // fluxvale-app-<id> per instance. Deriving it from the instance's
    // URL can't be poisoned by a sibling spec's concurrent deploy —
    // a before/after namespace diff can (workers run specs in
    // parallel; the diff saw a neighbour's namespace land mid-test).
    const instanceId = page.url().match(/instances\/([0-9a-f-]{36})/)![1]!;
    const namespace = `fluxvale-app-${instanceId}`;
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    await expect(page.getByTestId("instance-price")).toContainText(
      "$4.09/mo · billed hourly",
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
    // boot migrations ran against the BUNDLED database. The issued
    // token then reads the (empty) website list: the whole auth path
    // works.
    const token = await loginAdmin(request, url!);
    const websites = await request.get(new URL("api/websites", url!).toString(), {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(websites.status()).toBe(200);

    // The persistence witness is WRITTEN state, not the default admin:
    // upstream's first migration re-seeds admin/umami on an empty
    // database, so a sign-in passes even if the PVC data were lost
    // (initdb re-runs, migrate re-seeds). A website created through
    // the public API exists only in data that survives the legs.
    const marker = `persist-${Date.now()}`;
    const created = await request.post(new URL("api/websites", url!).toString(), {
      headers: { authorization: `Bearer ${token}` },
      data: { name: marker, domain: `${marker}.example` },
    });
    expect(created.status()).toBe(200);

    // --- RESTART LEG (#612 S4): destroy the pod → data persists ------
    // App and bundled database die together; the Deployment
    // reschedules; native-sidecar init ordering re-runs (the app
    // cannot start until pg_isready passes); the witness website must
    // still answer — the database rode the PVC under backing/.
    await assertOurWorkload(namespace);
    await kubectl(["-n", namespace, "delete", "pod", "-l", "app.kubernetes.io/name=app"]);
    // The delete returns when the pod OBJECT is gone; readyReplicas
    // can still read 1 for the dead pod on an immediate poll — wait
    // out the 0 before waiting for the replacement, or waitPodReady
    // can return against the stale status.
    await waitReadyReplicas(namespace, "0", 60_000);
    await waitPodReady(namespace, 6 * 60_000);
    const revivedHeartbeat = await request.get(
      new URL("api/heartbeat", url!).toString(),
    );
    expect(revivedHeartbeat.status()).toBe(200);
    await expectWebsitePresent(request, await loginAdmin(request, url!), url!, marker);

    // --- STOP/START LEG (#612 S4): storage-only interlude → data
    // persists. Scale 0 kills the whole namespace's workloads; the PVC
    // (and the billing) is all that remains — $0.40/mo while stopped,
    // the 10 GB storage axis alone (the BYO row's honest $0.00 is a
    // different row now).
    await page.getByTestId("stop-button").click();
    await waitForStatus(page, "Stopped", 60_000);
    await expect(page.getByTestId("instance-price")).toContainText(
      "$0.40/mo while stopped · billed hourly",
    );

    // … and back up: init ordering re-runs from a cold pair, and the
    // witness website still answers across the interlude — the data
    // survived a stopped-instance stretch in the bundled database.
    await page.getByTestId("start-button").click();
    await waitForStatus(page, "Running", 6 * 60_000);
    await expectWebsitePresent(request, await loginAdmin(request, url!), url!, marker);

    // Destroy: native confirm() dialog, teardown (async Oban) exits
    // the view to /instances where the fresh user's list is empty
    // again — the namespace (and the bundled database with it) goes.
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByTestId("delete-button").click();
    await page.waitForURL(/\/instances$/);
    await expect(page.getByTestId("instance-row")).toHaveCount(0);
  },
);

// The first-run witness: upstream's default admin (the first-run
// contract, ADR-0034 Am. 2) signs in through the public API — it
// proves the auth path and the bundled DB booted, NOT data survival
// (the first migration re-seeds this row on an empty database; the
// legs' persistence witness is the run-unique website). Returns the
// issued token for callers that read further.
async function loginAdmin(
  request: import("@playwright/test").APIRequestContext,
  baseUrl: string,
) {
  const login = await request.post(new URL("api/auth/login", baseUrl).toString(), {
    data: { username: "admin", password: "umami" },
  });
  expect(login.status()).toBeLessThan(400);
  const session = (await login.json()) as { token: string; user: { role: string } };
  expect(session.user.role).toBe("admin");
  return session.token;
}

// True persistence witness: the run-unique website created before the
// legs. Its row only exists in data that rode the PVC — the default
// admin cannot witness this (re-seeded by the first migration on a
// wiped volume). Shape-agnostic on purpose: the list endpoint's
// paging wrapper differs across API minors, and the marker string can
// only come from survived data.
async function expectWebsitePresent(
  request: import("@playwright/test").APIRequestContext,
  token: string,
  baseUrl: string,
  marker: string,
) {
  const list = await request.get(new URL("api/websites", baseUrl).toString(), {
    headers: { authorization: `Bearer ${token}` },
  });
  expect(list.status()).toBe(200);
  expect(JSON.stringify(await list.json())).toContain(marker);
}

// The derived namespace's shape double-check: its Deployment runs the
// Umami image and its init container runs PostgreSQL — the bundled
// pod this spec is about, not a neighbour's namespace (the page
// renders the namespace to admins only, #179, so the URL-derived name
// plus this check is the ground truth).
async function assertOurWorkload(namespace: string) {
  const images = await kubectl([
    "-n",
    namespace,
    "get",
    "deploy",
    "app",
    "-o",
    "jsonpath={.spec.template.spec.containers[0].image} {.spec.template.spec.initContainers[*].image}",
  ]);
  expect(images).toContain("umami-software/umami");
  expect(images).toContain("postgres");
}

// Poll the Deployment's readyReplicas until it reads `want`. After a
// pod delete the old pod's status can linger briefly — waitReadyReplicas
// (namespace, "0") closes the window where waitPodReady would return
// against the dead pod's stale "1". `want === "0"` also matches the
// EMPTY read: readyReplicas is a *int32 the API omits when zero, so
// zero arrives as "" from jsonpath, never as "0".
async function waitReadyReplicas(namespace: string, want: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  const isZero = (v: string) => v === "" || v === "0";

  while (Date.now() < deadline) {
    const ready = await kubectl(
      [
        "-n",
        namespace,
        "get",
        "deploy",
        "app",
        "-o",
        "jsonpath={.status.readyReplicas}",
      ],
      { bestEffort: true },
    );

    const value = ready.trim();
    if ((want === "0" && isZero(value)) || value === want) return;
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  throw new Error(`readyReplicas never read "${want}" in ${namespace} within ${timeoutMs}ms`);
}

// The pod is Ready again (post-delete reschedule). The page badge
// alone can't witness recovery (it reads Running throughout), so this
// reads pod readiness directly — the same signal the reconciler
// consumes.
async function waitPodReady(namespace: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const ready = await kubectl(
      [
        "-n",
        namespace,
        "get",
        "deploy",
        "app",
        "-o",
        "jsonpath={.status.readyReplicas}",
      ],
      { bestEffort: true },
    );

    if (ready.trim() === "1") return;
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  throw new Error(`pod never became ready in ${namespace} within ${timeoutMs}ms`);
}

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

// The strict path rethrows redacted (execFile's rejection message
// carries the full command line; the report artifact is public, the
// trace-off posture above); best-effort callers swallow failures here.
async function kubectl(
  args: string[],
  options: { bestEffort?: boolean } = {},
): Promise<string> {
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
