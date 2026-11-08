import { expect, test } from "@playwright/test";
import { runtimeFor } from "./helpers/runtime";
import { nativeSignIn, signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// The passwordless human flow through the real UI (the "Sign in" row
// of docs/observability.md's critical-flow table): request a code,
// read it from TestInbox, verify, and prove the session is real by
// loading an auth-gated page. Runs wherever TestInbox is reachable —
// local and staging (ADR-0024); never production (a login there sends
// a real email and provisions a user — not a read-only action).
const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  runtime === "production",
  "sign-in sends a real email and JIT-provisions a user — not a read-only action (ADR-0024)",
);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test("sign in with an emailed code and reach an auth-gated page", async ({
  page,
  request,
}) => {
  const email = `test+signin-${runId}@fluxvale.com`;
  await signIn(page, new TestInbox(request, testInboxToken!), email);

  // "/" is the starter page for everyone; /apps is the auth-gated app
  // surface — reaching its heading proves the session cookie works.
  await page.goto("/apps");
  await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
});

// #219: the resilience track. A network that blocks the WebSocket
// handshake still loads the HTML and app.js; LiveView never joins, so
// the sign-in forms submit through their native action/method
// fallbacks (assets/js/app.js lets a flagged form through while the
// socket is down).
test("sign in with the WebSocket handshake blocked", async ({
  page,
  request,
}) => {
  await page.routeWebSocket(/\/live\/websocket/, (ws) => ws.close());

  const email = `test+wsblocked-${runId}@fluxvale.com`;
  await nativeSignIn(page, new TestInbox(request, testInboxToken!), email, {
    waitForDisconnect: true,
  });

  await page.goto("/apps");
  await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
});

// #219: the same two native POSTs with no JavaScript at all.
test.describe("without JavaScript", () => {
  test.use({ javaScriptEnabled: false });

  test("sign in with JavaScript disabled", async ({ page, request }) => {
    const email = `test+nojs-${runId}@fluxvale.com`;
    await nativeSignIn(page, new TestInbox(request, testInboxToken!), email);

    await page.goto("/apps");
    await expect(page.getByRole("heading", { name: "Catalog" })).toBeVisible();
  });
});
