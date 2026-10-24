import { execFile, execFileSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #222's acceptance test (ADR-0037): the owner's whole backup round-trip
// through the real UI against the in-cluster MinIO stand-in for a BYO
// bucket — configure a destination on a running file-access app, seed a
// file through /dav, back up now, watch objects land in the bucket, break
// the data, restore from the panel's two-step confirm, and read the file
// back out of the volume.
//
// Local only: the bucket assertion is `kubectl exec` into the MinIO pod,
// and only the e2e bootstrap provisions that target (ADR-0024: staging
// carries no cluster credentials by design).
//
// A run's verdict lands through the backup sweep (every five minutes at
// :06/:11/…), not the trigger's return — the panel's run row flips when
// the watch pass reads the Job. Every wait here is therefore a poll with
// a sweep's-worth budget, never a fixed sleep.

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);
const isLocal = runtime === "local";

// The bootstrap writes these into apps/e2e/.e2e-env (mode 600, gitignored);
// the spec only reads them. Nothing here is a real credential — MinIO's
// are the manifest's plainly-fake local-dev values (12-minio.yaml).
const minioEndpoint = process.env.MINIO_ENDPOINT;
const minioBucket = process.env.MINIO_BUCKET;
const minioUser = process.env.MINIO_ROOT_USER;
const minioPassword = process.env.MINIO_ROOT_PASSWORD;

// Kavita's declared mount path (catalog seed, #189) — the volume root the
// /dav sidecar serves and the one a backup snapshots.
const KAVITA_MOUNT = "/kavita/config";

// The run's verdict arrives with the backup sweep's WATCH pass, not the
// trigger's return. The cron is `6-59/5` — :06, :11 … :56, then back to
// :06 — so the longest wait across the top of the hour is ten minutes.
// Eleven covers that with a margin; every wait below is bounded by it.
const SWEEP_BUDGET_MS = 11 * 60_000;

const run = promisify(execFile);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test.skip(
  !isLocal,
  "the round-trip reads the bucket and the volume from the cluster — local only (ADR-0024)",
);

test.skip(
  !(minioEndpoint && minioBucket && minioUser && minioPassword),
  "MINIO_* not set — the e2e bootstrap's S3 target is missing (scripts/e2e-bootstrap.sh)",
);

test.skip(
  !rcloneOnPath(),
  "rclone not on PATH — mise install rclone (the client story IS rclone, #190)",
);

test("backups: configure → back up now → objects in MinIO → restore → data back", async ({
  page,
  request,
}) => {
  // The measured round-trip is ~9-11 min warm. The ceiling is bounded on
  // purpose: CI's e2e job has 45 minutes and spends ~15 of them on the
  // bootstrap, so a spec that runs away must fail with its own evidence
  // rather than take the job's whole budget with it.
  test.setTimeout(25 * 60_000);

  const email = `test+e2e-backups-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // --- deploy Kavita (the file-access app: a volume worth backing up) -----
  await page.goto("/apps");
  await waitForLiveViewJoin(page);
  await page.getByTestId("app-kavita").click();
  await waitForLiveViewJoin(page);
  await page.locator("[data-testid^='deploy-']").first().click();
  await waitForLiveViewJoin(page);
  await page.getByTestId("version-option").first().check();
  await page.getByTestId("continue-version").click();
  await page.getByTestId("continue-env").click();
  await page.getByTestId("continue-resources").click();

  const name = `e2e-backups-${runId}`;
  await page.getByTestId("instance-name").fill(name);
  await page.getByTestId("deploy-submit").click();

  await page.waitForURL(/\/instances\//);
  await waitForLiveViewJoin(page);
  const instanceId = page.url().match(/\/instances\/([0-9a-f-]+)$/)?.[1];
  expect(instanceId).toBeTruthy();
  await waitForStatus(page, "Running", 12 * 60_000);

  // Stay awake for the whole round-trip: the e2e stack's idle threshold is
  // 180s (#210 part 3) and this spec spends minutes waiting on the backup
  // sweep — an app asleep mid-test would turn the restore's return to
  // Running into a coin toss (and the restore's own sleeping arm is an
  // ExUnit case, not this one's).
  await page.getByTestId("always-on-toggle").click();
  await expect(page.getByTestId("availability-mode")).toHaveText("Always on");

  // --- seed a known file through /dav (the customer's own client path) ----
  await expect(page.getByTestId("file-access-panel")).toBeVisible();
  const davUrl = (await page.getByTestId("dav-url").textContent())?.trim();
  const davUser = (await page.getByTestId("dav-username").textContent())?.trim();
  await page.getByTestId("reveal-credentials").click();
  await expect(page.getByTestId("dav-password")).toBeVisible();
  const davPassword = (await page.getByTestId("dav-password").textContent())?.trim();
  expect(davUrl).toMatch(/^https:\/\//);
  expect(davUser).toBeTruthy();
  expect(davPassword).toBeTruthy();

  const obscured = (await run("rclone", ["obscure", davPassword!])).stdout.trim();
  const dir = await mkdtemp(path.join(tmpdir(), "fv-backups-"));
  const fileName = `roundtrip-${runId}.txt`;
  const remoteFile = `fv:evidence/${fileName}`;
  const volumeFile = `${KAVITA_MOUNT}/evidence/${fileName}`;
  const content = `fluxvale backups e2e ${runId} — this file took the round trip through MinIO`;
  const localFile = path.join(dir, fileName);
  await writeFile(localFile, content, "utf8");

  const env = {
    ...process.env,
    RCLONE_CONFIG_FV_TYPE: "webdav",
    RCLONE_CONFIG_FV_URL: davUrl!,
    RCLONE_CONFIG_FV_VENDOR: "rclone",
    RCLONE_CONFIG_FV_USER: davUser!,
    RCLONE_CONFIG_FV_PASS: obscured,
    // Local k3d rides Traefik's self-signed default cert (ADR-0020) —
    // rclone's skip-verify is the global flag's env form.
    RCLONE_NO_CHECK_CERTIFICATE: "true",
  };

  await run("rclone", ["copyto", localFile, remoteFile, "--verbose"], { env });
  expect((await run("rclone", ["lsf", "fv:evidence/"], { env })).stdout).toContain(fileName);

  // Ground truth on the volume before any backup exists.
  expect(await readVolumeFile(instanceId!, volumeFile)).toBe(content);

  // --- configure the destination through the panel -----------------------
  const prefix = `e2e/${runId}`;

  await test.step("the panel takes a BYO-bucket destination", async () => {
    await expect(page.getByTestId("backups-unconfigured")).toBeVisible();
    await page.getByTestId("backups-setup").click();

    // Field names are the resource's own (`backup[endpoint]` …), the
    // contract the panel's ExUnit suite already pins.
    await page.locator("input[name='backup[endpoint]']").fill(minioEndpoint!);
    await page.locator("input[name='backup[bucket]']").fill(minioBucket!);
    await page.locator("input[name='backup[prefix]']").fill(prefix);
    await page.locator("input[name='backup[access_key_id]']").fill(minioUser!);
    await page.locator("input[name='backup[secret_access_key]']").fill(minioPassword!);
    await page.locator("input[name='backup[retention_keep]']").fill("3");
    await page.getByTestId("backups-save").click();

    // The configured summary: the coordinates, the masked key (last four
    // characters only — the credential itself never renders), the folder
    // hint, and the schedule line naming the retention just chosen.
    await expect(page.getByTestId("backup-endpoint")).toHaveText(minioEndpoint!);
    await expect(page.getByTestId("backup-bucket")).toHaveText(minioBucket!);
    await expect(page.getByTestId("backup-bucket-hint")).toHaveText(`Folder: ${prefix}`);
    await expect(page.getByTestId("backup-access-key")).toHaveText(
      `••••${minioUser!.slice(-4)}`,
    );
    await expect(page.getByTestId("backup-retention")).toHaveText(
      "Daily · keep the last 3 snapshots",
    );
    await expect(page.getByTestId("backups-notice")).toContainText("Backup settings saved.");
    await expect(page.locator("#backup-settings-form")).toHaveCount(0);
  });

  // --- back up now -------------------------------------------------------
  await test.step("Back up now runs, and the panel reports the size", async () => {
    const runRow = page
      .locator("[data-testid=backup-run][data-run-kind=manual]")
      .first();

    // Configuring once the daily window has opened lets the sweep's DUE
    // pass take the run slot on its next tick. A scheduled run satisfies
    // the window for the rest of the day, so a lost attempt only costs one
    // wait — retry until a MANUAL row exists rather than asserting on
    // scheduling luck.
    await clickWhenFree(page, "back-up-now", "[data-testid=backup-run][data-run-kind=manual]");
    await expect(runRow).toBeVisible();

    // The Job applies in seconds; the sweep's watch pass is what flips the
    // row. Poll for a terminal verdict so a failure fails fast with its own
    // reason rather than timing out.
    await expect
      .poll(() => runRow.getAttribute("data-run-status").catch(() => null), {
        timeout: SWEEP_BUDGET_MS,
        intervals: [2_000],
      })
      .toMatch(/^(succeeded|failed)$/);

    expect(await runRow.getAttribute("data-run-status")).toBe("succeeded");
    await expect(page.getByTestId("backups-health")).toHaveText("Healthy");

    // The last-success line carries the size the run added.
    const lastSuccess = page.getByTestId("last-success");
    await expect(lastSuccess).toContainText(/Last successful backup: .+ · \d/);
    const sizeText = (await lastSuccess.textContent()) ?? "";
    const match = sizeText.match(/·\s+(\d+(?:\.\d+)?)\s+(B|KB|MB|GB)/);
    expect(match, `no size on the last-success line: ${sizeText}`).not.toBeNull();
    expect(Number(match![1])).toBeGreaterThan(0);
  });

  // --- the objects are really in the bucket ------------------------------
  await test.step("the restic repo exists in the MinIO bucket", async () => {
    const repoPath = `/data/${minioBucket}/${prefix}`;

    // Single-node fs mode: the bucket's keys are directories on the PV (an
    // object is `<key>/xl.meta`), so restic's repo shape is directly
    // observable — `config` plus the four directories it creates on init.
    const entries = (
      await kubectl(["-n", "fluxvale-dev", "exec", "deploy/minio", "--", "ls", "-a", repoPath])
    )
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);

    for (const entry of ["config", "data", "index", "keys", "snapshots"]) {
      expect(entries, `restic repo is missing ${entry}: ${entries.join(", ")}`).toContain(entry);
    }

    // snapshots/ carries one manifest directory per snapshot: an empty
    // snapshots/ is not a backup.
    const snapshots = (
      await kubectl([
        "-n",
        "fluxvale-dev",
        "exec",
        "deploy/minio",
        "--",
        "ls",
        "-a",
        `${repoPath}/snapshots`,
      ])
    )
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line && line !== "." && line !== "..");

    expect(snapshots.length, "no snapshot manifest in the repository").toBeGreaterThan(0);
  });

  // --- break the data ----------------------------------------------------
  await test.step("the seeded file is deleted from the volume", async () => {
    await run("rclone", ["deletefile", remoteFile, "--verbose"], { env });
    expect((await run("rclone", ["lsf", "fv:evidence/"], { env })).stdout).not.toContain(fileName);
    expect(await volumeFileExists(instanceId!, volumeFile)).toBe(false);
  });

  // --- restore through the panel's two-step confirm ----------------------
  await test.step("restore asks first, naming the backup it will apply", async () => {
    await clickWhenFree(page, "restore-latest", "[data-testid=destructive-confirm]");

    const confirm = page.getByTestId("destructive-confirm");
    await expect(confirm).toBeVisible();
    // The consequence copy is load-bearing: it names the snapshot (age and
    // size), rather than "the last backup" on trust.
    await expect(confirm).toContainText(
      /This replaces the app's current data with the backup from .+ \(\d+(?:\.\d+)? (?:B|KB|MB|GB)\)\. This cannot be undone\./,
    );
    await expect(page.getByTestId("restore-confirm")).toBeVisible();
  });

  await test.step("the restore holds the instance, then it comes back", async () => {
    await page.getByTestId("restore-confirm").click();

    // The instance is taken off service for the restore: the panel says so
    // in words while the volume is rewritten.
    await expect(page.getByTestId("backups-restoring")).toBeVisible({ timeout: 2 * 60_000 });

    const restoreRow = page
      .locator("[data-testid=backup-run][data-run-kind=restore]")
      .first();

    await expect
      .poll(() => restoreRow.getAttribute("data-run-status"), {
        timeout: SWEEP_BUDGET_MS,
        intervals: [2_000],
      })
      .toMatch(/^(succeeded|failed)$/);

    expect(await restoreRow.getAttribute("data-run-status")).toBe("succeeded");

    // Released by the sweep as :starting (it was running before); the
    // reconciler re-confirms readiness and stays the only writer of
    // :running.
    await waitForStatus(page, "Running", 6 * 60_000);
  });

  // --- the data is back --------------------------------------------------
  await test.step("the file is back on the volume, byte for byte", async () => {
    expect(await readVolumeFile(instanceId!, volumeFile)).toBe(content);

    // The read side of the same volume, through the customer's own path.
    expect((await run("rclone", ["cat", remoteFile], { env })).stdout.trim()).toBe(content);
  });

  // --- clean up ----------------------------------------------------------
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await rm(dir, { recursive: true, force: true });
});

// A click the panel refuses while any run is pending/running (the
// one-active-run invariant, mirrored in the buttons' disabled state). The
// platform's own sweep can take the slot a tick before the click — retry
// until the click actually lands (its own consequence is visible), rather
// than asserting on scheduling luck.
async function clickWhenFree(page: Page, testid: string, landed: string) {
  const activeRun = page.locator(
    "[data-testid=backup-run][data-run-status=pending], [data-testid=backup-run][data-run-status=running]",
  );
  const deadline = Date.now() + SWEEP_BUDGET_MS;
  let refusal = "";

  while (Date.now() < deadline) {
    // A previous iteration's click may have landed while its own
    // consequence was still rendering.
    if ((await page.locator(landed).count()) > 0) return;

    // The loss the one-active-run index gates: the platform's own sweep
    // took the slot a tick before the click. Transient by construction —
    // the next window (or the sweep's own finalize) frees it again.
    if ((await activeRun.count()) > 0) {
      await page.waitForTimeout(2_000);
      continue;
    }

    const button = page.getByTestId(testid);
    if (!(await button.isVisible().catch(() => false))) {
      await page.waitForTimeout(2_000);
      continue;
    }
    if (await button.isDisabled().catch(() => true)) {
      await page.waitForTimeout(2_000);
      continue;
    }

    await button.click({ timeout: 5_000 }).catch(() => {});
    await page
      .locator(landed)
      .first()
      .waitFor({ state: "visible", timeout: 10_000 })
      .catch(() => {});

    if ((await page.locator(landed).count()) > 0) return;

    // Nothing landed: keep the panel's words for the timeout message — and
    // fail now unless they name the one transient loss (the sweep taking
    // the slot between our check and the click). Any other refusal is a
    // real one, and retrying it for eleven minutes just hides it.
    refusal =
      (await page
        .getByTestId("backups-error")
        .textContent()
        .catch(() => "")) ?? refusal;

    if (refusal.trim() && !isRunInFlight(refusal)) {
      throw new Error(`"${testid}" was refused: ${refusal.trim()}`);
    }

    await page.waitForTimeout(2_000);
  }

  throw new Error(
    `"${testid}" never took effect within ${SWEEP_BUDGET_MS}ms` +
      (refusal.trim() ? ` — the panel said: ${refusal.trim()}` : ""),
  );
}

// `copy_for(:run_in_flight)` — the one refusal that resolves on its own
// (a sweep-started run finishing and being watched). Everything else the
// panel can say here is a real failure.
function isRunInFlight(copy: string): boolean {
  return copy.includes("already running");
}

// The volume assertion, read straight off the PVC through the WebDAV
// sidecar's container (alpine guarantees coreutils; the app's container
// sees the same PVC — one volume, two mounts).
async function readVolumeFile(instanceId: string, path: string): Promise<string> {
  const stdout = await kubectl([
    "-n",
    `fluxvale-app-${instanceId}`,
    "exec",
    "deploy/app",
    "-c",
    "file-access",
    "--",
    "cat",
    path,
  ]);

  return stdout.trim();
}

async function volumeFileExists(instanceId: string, path: string): Promise<boolean> {
  // `test -f` answers present/gone in its own output — a missing file is
  // the answer, not an error to report.
  const { stdout } = await run(
    "kubectl",
    [
      "--context",
      "k3d-fluxvale",
      "-n",
      `fluxvale-app-${instanceId}`,
      "exec",
      "deploy/app",
      "-c",
      "file-access",
      "--",
      "sh",
      "-c",
      `test -f ${path} && echo present || echo gone`,
    ],
    { reject: false },
  );

  return stdout.trim() === "present";
}

async function kubectl(args: string[]): Promise<string> {
  const { stdout } = await run("kubectl", ["--context", "k3d-fluxvale", ...args]);

  return stdout;
}

// Poll the live badge until `want` shows — the lifecycle specs' helper
// (failure fails fast with the status message).
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

function rcloneOnPath(): boolean {
  try {
    execFileSync("rclone", ["version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}
