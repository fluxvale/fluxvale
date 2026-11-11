import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";
import { waitForStatus, destroyInstance } from "./helpers/instance-ui";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor, type Runtime } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// #679's regression, reproduced in-cluster: Kavita's scanner only
// ingests files inside SUBDIRECTORIES of a library folder — loose
// files at the root are skipped silently. The flagship file-access
// path (ADR-0035) had no e2e watching an uploaded book actually appear
// in the app, so a Kavita-side ingest break ships green. This spec
// rides the same chain file-access.spec.ts proves (edge → Traefik →
// dav Service → rclone sidecar → the PVC Kavita mounts at
// /kavita/config, #189): deploy Kavita, rclone-put a real EPUB into a
// series subfolder, create a Kavita library over that folder via the
// app's own API, and let Kavita's scan surface the series.
//
// The API quirks the architecture reproduction hit (rediscovering them
// costs an hour): `folders` is an ARRAY OF STRINGS of absolute
// in-container paths, `metadataProvider` must be 2 (0 is rejected),
// and creating a library triggers the first scan automatically —
// `lastScanned` reads "0001-01-01T00:00:00" until that scan finishes,
// which is how this spec knows the scan is done before asserting the
// series.

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime: Runtime = runtimeFor(process.env.BASE_URL);
const isLocal = runtime === "local";

// Kavita's volume mounts at /kavita/config (#189); the sidecar serves
// that root at /dav, so remote library/books/… = /kavita/config/library/books/….
const KAVITA_MOUNT = "/kavita/config";
const LIBRARY_FOLDER = `${KAVITA_MOUNT}/library/books`;
const LIBRARY_NAME = "E2E Books";
const SERIES_NAME = "Belphegor";
// A library that has never scanned reads the zero-date — matched by
// prefix so a Kind/format shift upstream can't silently pass the gate.
const NEVER_SCANNED_PREFIX = "0001-01-01";

// The architect-generated minimal valid EPUB3 (no third-party content).
// ESM suite (type: module) — no __dirname here.
const EPUB = fileURLToPath(new URL("fixtures/belphegor.epub", import.meta.url));

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

test(
  "kavita ingest: deploy Kavita → rclone-put an EPUB into a series subfolder through /dav → Kavita's scan surfaces the series",
  async ({ page, request }) => {
    test.setTimeout(18 * 60_000);

    // Sign in as a fresh per-run user, then deploy Kavita through the
    // wizard (the file-access flow's deploy walk).
    const email = `test+e2e-kavita-ingest-${runId}@fluxvale.com`;
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
    const name = `e2e-kavita-ingest-${runId}`;
    await page.getByTestId("instance-name").fill(name);
    await page.getByTestId("deploy-submit").click();

    await page.waitForURL(/\/instances\//);
    await waitForLiveViewJoin(page);
    await waitForStatus(page, "Running", 12 * 60_000);

    // The panel is the client doc: address, username, revealable
    // password (the #194 clipboard round-trip is file-access.spec's
    // job — this spec only needs the credential to work). A missing
    // panel must say so here, not time out on a bare locator below.
    await expect(page.getByTestId("file-access-panel")).toBeVisible();
    const davUrl = (await page.getByTestId("dav-url").textContent())?.trim();
    const davUser = (await page.getByTestId("dav-username").textContent())?.trim();
    await page.getByTestId("reveal-credentials").click();
    await expect(page.getByTestId("dav-password")).toBeVisible();
    const davPass = (await page.getByTestId("dav-password").textContent())?.trim();
    expect(davUrl).toMatch(/^https:\/\//);
    expect(davUser).toBeTruthy();
    expect(davPass).toBeTruthy();

    const obscured = (await run("rclone", ["obscure", davPass!])).stdout.trim();
    const env = {
      ...process.env,
      RCLONE_CONFIG_FV_TYPE: "webdav",
      RCLONE_CONFIG_FV_URL: davUrl!,
      RCLONE_CONFIG_FV_VENDOR: "rclone",
      RCLONE_CONFIG_FV_USER: davUser!,
      RCLONE_CONFIG_FV_PASS: obscured,
      // Local k3d rides Traefik's self-signed default cert (ADR-0020) —
      // rclone's skip-verify is the global flag's env form, not per-remote.
      ...(isLocal ? { RCLONE_NO_CHECK_CERTIFICATE: "true" } : {}),
    };

    // The upload that matters: INTO a series subfolder. The #679 class
    // is a loose file at the library root being silently skipped — the
    // subdirectory is what the scanner accepts.
    await test.step("rclone-put the EPUB into library/books/Belphegor/", async () => {
      await run(
        "rclone",
        ["copyto", EPUB, `fv:library/books/${SERIES_NAME}/belphegor.epub`],
        { env },
      );
      const listing = (
        await run("rclone", ["lsf", `fv:library/books/${SERIES_NAME}/`], { env })
      ).stdout;
      expect(listing).toContain("belphegor.epub");
    });

    // Drive Kavita's own API (the context-scoped request rides the
    // same ignoreHTTPSErrors the browser context has — Traefik's
    // self-signed cert on local). First registrant becomes the admin.
    const baseUrl = (await page.getByTestId("instance-url").textContent())?.trim();
    expect(baseUrl).toMatch(/^https:\/\//);

    const api = await test.step("register + create the library over Kavita's API", async () => {
      const kavitaUser = `e2e${runId.replace(/[^a-zA-Z0-9]/g, "").slice(0, 24)}`;
      const kavitaPass = `Kavita!${runId.replace(/[^a-zA-Z0-9]/g, "")}A1`;

      const register = await request.post(`${baseUrl}/api/account/register`, {
        data: { username: kavitaUser, email, password: kavitaPass },
      });
      // Read the body once; the assert carries it so Kavita's error
      // JSON surfaces instead of a bare 4xx (the rediscovery-cost rule
      // from the header).
      const registerBody = await register.text();
      expect(register.status(), registerBody).toBe(200);
      const token = (JSON.parse(registerBody) as { token: string }).token;
      expect(token).toBeTruthy();
      const headers = { authorization: `Bearer ${token}` };

      // metadataProvider 2 is REQUIRED (0 is invalid); fileGroupTypes
      // [1,2,3] = archive + epub + pdf.
      const create = await request.post(`${baseUrl}/api/library/create`, {
        headers,
        data: {
          name: LIBRARY_NAME,
          type: 2,
          folders: [LIBRARY_FOLDER],
          folderWatching: true,
          includeInDashboard: true,
          includeInSearch: true,
          manageCollections: true,
          manageReadingLists: true,
          allowScrobbling: true,
          allowMetadataMatching: true,
          enableMetadata: true,
          removePrefixForSortName: false,
          inheritWebLinksFromFirstChapter: false,
          defaultLanguage: "",
          metadataProvider: 2,
          fileGroupTypes: [1, 2, 3],
          excludePatterns: [],
        },
      });
      expect(create.status(), await create.text()).toBe(200);

      return { headers };
    });

    const ourLibrary = await test.step("wait out the first scan, scan-fallback behind it", async () => {
      // Lenient read: a transient non-200 (or non-JSON body) reads as
      // null — pollUntil keeps polling, it must not abort the loop.
      const libraries = async () => {
        const res = await request.get(`${baseUrl}/api/library/libraries`, {
          headers: api.headers,
        });
        if (!res.ok()) return null;
        return (await res.json()) as {
          id: number;
          name: string;
          lastScanned: string;
        }[];
      };

      const find = () =>
        libraries().then((libs) => libs?.find((l) => l.name === LIBRARY_NAME));

      // Creating a library auto-scans; lastScanned flips off the
      // zero-date (prefix-matched) when that scan finishes.
      let library = await pollUntil(find, NEVER_SCANNED_PREFIX, 120_000);
      expect(library, `${LIBRARY_NAME} in /api/library/libraries`).toBeTruthy();

      if (library!.lastScanned.startsWith(NEVER_SCANNED_PREFIX)) {
        // The auto-scan never landed — trigger one explicitly and
        // keep polling.
        const scan = await request.post(
          `${baseUrl}/api/library/scan?libraryId=${library!.id}`,
          { headers: api.headers },
        );
        expect(scan.status(), await scan.text()).toBe(200);
        library = await pollUntil(find, NEVER_SCANNED_PREFIX, 120_000);
      }

      // Explicit guards — a bare `library!` would TypeError instead of
      // saying what never settled.
      expect(
        library,
        `${LIBRARY_NAME} never appeared in /api/library/libraries`,
      ).toBeTruthy();
      expect(
        library!.lastScanned.startsWith(NEVER_SCANNED_PREFIX),
        `the first scan never finished — lastScanned still reads ${library!.lastScanned}`,
      ).toBe(false);

      return library!;
    });

    // The point of the whole ride: Kavita's scanner INGESTED the
    // subfolder EPUB — the series exists in this library. all-v2 is a
    // FILTER, not a scoper: SeriesFilterV2Dto never reads libraryId,
    // so the body field would be inert and the query ranges over every
    // library; the scoping happens here, client-side.
    const series = await request.post(
      `${baseUrl}/api/series/all-v2?pageNumber=1&pageSize=10`,
      { headers: api.headers, data: { name: "", statements: [] } },
    );
    const seriesBody = await series.text();
    expect(series.status(), seriesBody).toBe(200);
    const list = JSON.parse(seriesBody) as {
      name: string;
      libraryId: number;
    }[];
    const matches = list.filter(
      (s) => s.name === SERIES_NAME && s.libraryId === ourLibrary.id,
    );
    expect(matches.length, JSON.stringify(list)).toBeGreaterThan(0);

    await destroyInstance(page);
  },
);

// Poll every 5s until `find` yields a library whose lastScanned has
// left the zero-date prefix; `timeoutMs` bounds the wait. A failed or
// unsettled read is "not yet" — swallowed, and the loop keeps polling
// until the deadline. Returns the last find, settled or not — the
// caller decides whether that's a failure.
async function pollUntil(
  find: () => Promise<{ id: number; lastScanned: string } | undefined>,
  neverPrefix: string,
  timeoutMs: number,
) {
  const deadline = Date.now() + timeoutMs;
  let library = await find().catch(() => undefined);

  while (
    Date.now() < deadline &&
    (!library || library.lastScanned.startsWith(neverPrefix))
  ) {
    await new Promise((resolve) => setTimeout(resolve, 5_000));
    library = await find().catch(() => undefined);
  }

  return library;
}

function rcloneOnPath(): boolean {
  try {
    execFileSync("rclone", ["version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}
