import { execFile, execFileSync } from "node:child_process";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { expect, test, type Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor, type Runtime } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #190's E2E (ADR-0035): deploy Kavita (file access seeded on, #189)
// through the wizard, then rclone-put a file through the public WebDAV
// endpoint — the same chain a customer's `rclone copy` rides (edge →
// Traefik → dav Service → rclone sidecar → the app's data volume).
//
// The volume assertion differs by runtime (ADR-0024): local k3d has
// cluster access, so the file is cat'd straight off the PVC through
// the pod; staging has zero cluster credentials by design, so the proof
// is the read side of the same volume (rclone cat roundtrip + a 401
// without credentials — the credential actually gates).
//
// Kavita's PVC mounts at /kavita/config (#189) — the sidecar serves
// that mount path, and the upload lands under it.

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime: Runtime = runtimeFor(process.env.BASE_URL);
const isLocal = runtime === "local";

// #189's declared mount path for Kavita (catalog seed).
const KAVITA_MOUNT = "/kavita/config";

const run = promisify(execFile);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test.skip(
  runtime === "production",
  "instance lifecycle is destructive — production stays read-only (ADR-0024)",
);

test.skip(
  !rcloneOnPath(),
  "rclone not on PATH — mise install rclone (the client story IS rclone, #190)",
);

test("file access: deploy Kavita → rclone put through /dav → file lands in the instance volume", async ({
  page,
  request,
  context,
}) => {
  test.setTimeout(15 * 60_000);

  // Sign in as a fresh per-run user, then deploy Kavita through the
  // wizard — the seeded entry carries file_access: true (#189 + #190).
  const email = `test+e2e-files-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

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
  const name = `e2e-files-${runId}`;
  await page.getByTestId("instance-name").fill(name);
  await page.getByTestId("deploy-submit").click();

  await page.waitForURL(/\/instances\//);
  await waitForLiveViewJoin(page);
  await waitForStatus(page, "Running", 12 * 60_000);

  // The panel is the client doc: address, username, revealable password.
  await expect(page.getByTestId("file-access-panel")).toBeVisible();
  const davUrl = (await page.getByTestId("dav-url").textContent())?.trim();
  const username = (
    await page.getByTestId("dav-username").textContent()
  )?.trim();
  await page.getByTestId("reveal-credentials").click();
  await expect(page.getByTestId("dav-password")).toBeVisible();
  const password = (
    await page.getByTestId("dav-password").textContent()
  )?.trim();
  expect(davUrl).toMatch(/^https:\/\//);
  expect(username).toBeTruthy();
  expect(password).toBeTruthy();

  // #194: the HUMAN path — what the copy buttons actually hand the
  // clipboard, not what a test can scrape out of the DOM. The 43-char
  // password used to render as wrapped body text, so a triple-click
  // (or a drag) caught the "Password" label and a trailing newline and
  // the paste 401'd. Click each button and read the real clipboard.
  await test.step("panel reveal hands over the exact credential", async () => {
    const copyValue = (testid: string) =>
      page.getByTestId(testid).getAttribute("data-copy-value");

    const copiedUrl = await copyValue("copy-dav-url");
    const copiedUser = await copyValue("copy-dav-username");
    const copiedPass = await copyValue("copy-dav-password");

    expect(copiedUrl).toBe(davUrl);
    expect(copiedUser).toBe(username);
    expect(copiedPass).toBe(password);
    // The failure shape: anything that isn't the bare password is a 401
    // in the owner's client. No label, no newline, no wrapping artifact.
    expect(copiedPass).not.toContain("Password");
    expect(copiedPass).not.toMatch(/\s/);
    expect(copiedPass).toHaveLength(43);
  });

  await test.step("the copy button writes it to the real clipboard", async () => {
    // The assertion the old suite could not make: there was no button.
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.getByTestId("copy-dav-password").click();
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe(password);
  });

  await test.step("the password renders no-wrap", async () => {
    // A wrapped line is what made hand-selection lossy in the first place.
    const passwordWhiteSpace = await page
      .getByTestId("dav-password")
      .evaluate((el) => getComputedStyle(el).whiteSpace);
    expect(passwordWhiteSpace).toBe("nowrap");
  });

  // The credential actually gates: no auth → 401 through the real edge.
  const unauth = await request.get(davUrl!);
  expect(unauth.status()).toBe(401);

  // rclone put through the endpoint (the documented client path).
  const obscured = (await run("rclone", ["obscure", password!])).stdout.trim();
  const content = `fluxvale file-access e2e ${runId} — if you can read this, the volume got it`;
  const dir = await mkdtemp(path.join(tmpdir(), "fv-dav-"));
  const localFile = path.join(dir, "e2e-upload.txt");
  await writeFile(localFile, content, "utf8");

  const env = {
    ...process.env,
    RCLONE_CONFIG_FV_TYPE: "webdav",
    RCLONE_CONFIG_FV_URL: davUrl!,
    RCLONE_CONFIG_FV_VENDOR: "rclone",
    RCLONE_CONFIG_FV_USER: username!,
    RCLONE_CONFIG_FV_PASS: obscured,
    // Local k3d rides Traefik's self-signed default cert (ADR-0020) —
    // rclone's skip-verify is the global flag's env form, not per-remote.
    ...(isLocal ? { RCLONE_NO_CHECK_CERTIFICATE: "true" } : {}),
  };

  await run(
    "rclone",
    ["copyto", localFile, "fv:library/e2e-upload.txt", "--verbose"],
    { env },
  );
  const listing = (await run("rclone", ["lsf", "fv:library/"], { env })).stdout;
  expect(listing).toContain("e2e-upload.txt");

  // #194's second cause, asserted against the real endpoint: the
  // snippet's OWN config line must authenticate. rclone guesses whether
  // a `pass` value is already obscured and misreads the generated
  // 43-char base64url password ~99% of the time, so the literal form
  // 401s — `--obscure` is what makes the copied snippet work. Execute
  // the text the panel actually carries (read straight off the copy
  // button) so a drift in the rendered snippet can't pass by virtue of
  // this test retyping the flags correctly.
  const snippet = await page
    .getByTestId("copy-dav-snippet")
    .getAttribute("data-copy-value");
  expect(snippet).toBeTruthy();

  const configEnd = snippet!.indexOf("\nrclone copy");
  expect(configEnd).toBeGreaterThan(0);
  const snippetConfigCommand = snippet!.slice(0, configEnd);
  const snippetRemote = snippetConfigCommand.match(
    /rclone config create (\S+)/,
  )?.[1];
  expect(snippetRemote).toBeTruthy();

  const snippetConfig = path.join(dir, "rclone.conf");
  const snippetEnv = { ...env, RCLONE_CONFIG: snippetConfig };

  await test.step("the panel's own rclone snippet authenticates", async () => {
    await run("sh", ["-c", snippetConfigCommand], { env: snippetEnv });

    const snippetListing = (
      await run("rclone", ["lsf", `${snippetRemote!}:library/`], {
        env: snippetEnv,
      })
    ).stdout;
    expect(snippetListing).toContain("e2e-upload.txt");

    // And the config file must not carry the password in the clear —
    // --obscure is what both fixes auth and keeps the secret off disk.
    const writtenConfig = await readFile(snippetConfig, "utf8");
    expect(writtenConfig).not.toContain(password);
  });

  // Volume ground truth. Local: cat the file through the pod — from
  // the sidecar container (alpine guarantees coreutils; the app's
  // container sees the same PVC, one volume, two mounts). Staging: the
  // read side of the same volume is the strongest credential-free proof.
  if (isLocal) {
    const instanceId = page.url().match(/\/instances\/([0-9a-f-]+)$/)?.[1];
    const kubectl = await run("kubectl", [
      "--context",
      "k3d-fluxvale",
      "-n",
      `fluxvale-app-${instanceId}`,
      "exec",
      "deploy/app",
      "-c",
      "file-access",
      "--",
      "cat",
      `${KAVITA_MOUNT}/library/e2e-upload.txt`,
    ]);
    expect(kubectl.stdout.trim()).toBe(content);
  } else {
    const roundtrip = (
      await run("rclone", ["cat", "fv:library/e2e-upload.txt"], { env })
    ).stdout;
    expect(roundtrip.trim()).toBe(content);
  }

  // Clean up the instance; the temp dir rides the runner's lifecycle.
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByTestId("delete-button").click();
  await page.waitForURL(/\/instances$/);
  await rm(dir, { recursive: true, force: true });
});

// Poll the live badge until `want` shows — the lifecycle spec's helper
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
