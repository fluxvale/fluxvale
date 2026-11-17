import type { Page } from "@playwright/test";
import { waitForLiveViewJoin } from "./live-view";
import { TestInbox } from "./test-inbox";

// Passwordless sign-in through the real UI (ADR-0024 §5 — deterministic
// login, zero test backdoors): request a code for a per-run test+
// address (JIT-provisions the user, dodges the 60s resend throttle),
// read it from TestInbox, verify. Success is the native POST to
// /auth/session.
//
// #831: the landing is two-shaped — a stamped account's POST lands "/",
// a fresh account's "/" is the gate's swap to /onboarding (the
// show-once flow). Wait on the DOM signal, not the URL: the gate's
// redirect chain passes through "/" mid-hop. The JS arm then walks the
// flow like a real user — skip stamps :finish_onboarding and lands the
// dashboard, so every sign-in run exercises the skip.
export async function signIn(page: Page, inbox: TestInbox, email: string) {
  await page.goto("/sign-in");
  // The join's render replaces the form, so a fill before it lands is
  // wiped — wait for the join (helpers/live-view.ts).
  await waitForLiveViewJoin(page);

  await page.getByTestId("sign-in-email").fill(email);
  await page.getByTestId("send-code").click();

  const code = await inbox.latestCode(email);
  await page.getByTestId("sign-in-code").fill(code);
  await page.getByTestId("verify-code").click();

  await page
    .locator(
      "[data-testid='dashboard-balance'], [data-testid='onboarding-step-username']",
    )
    .first()
    .waitFor();

  if ((await page.getByTestId("onboarding-step-username").count()) > 0) {
    // The skip is a phx-click: the join is its precondition (#148) —
    // wait out the connect race before touching the button.
    await waitForLiveViewJoin(page);
    await page.getByTestId("onboarding-skip").click();
    await page.waitForURL((url) => url.pathname === "/");
  }
}

// #219: the same round-trip over the native POST fallbacks — no
// waitForLiveViewJoin (a blocked WebSocket or JavaScript-off browser
// never joins; the forms submit as plain HTML forms). The two steps are
// the email form's POST → the code page, then the verify POST →
// SessionController's session write.
//
// #831: the landing is two-shaped (see signIn) and the native arms
// STOP at whichever page the gate served — a phx-click needs the
// socket, which these callers deliberately block or disable, so there
// is no native skip. Deep links stay ungated (D1): the callers prove
// the session through /apps, never the landing.
export async function nativeSignIn(
  page: Page,
  inbox: TestInbox,
  email: string,
  opts: { waitForDisconnect?: boolean } = {},
) {
  // The socket settles into its retry loop; a submit while a mock
  // reconnect is briefly open would be swallowed by LiveView instead of
  // falling back natively. The window is tiny — wait it out after every
  // navigation.
  const settle = async () => {
    if (!opts.waitForDisconnect) return;
    // Wait for app.js's socket object to exist *and* be down: an
    // undefined liveSocket would satisfy a bare !isConnected() while the
    // bundle is still loading, leaving the click to race the first
    // connect attempt.
    await page.waitForFunction(() => {
      const socket = (
        window as unknown as { liveSocket?: { isConnected(): boolean } }
      ).liveSocket;
      return socket !== undefined && !socket.isConnected();
    });
  };

  await page.goto("/sign-in");
  await settle();

  await page.getByTestId("sign-in-email").fill(email);
  await page.getByTestId("send-code").click();
  await page.waitForURL("**/sign-in/code");
  await settle();

  const code = await inbox.latestCode(email);
  await page.getByTestId("sign-in-code").fill(code);
  await page.getByTestId("verify-code").click();

  await page
    .locator(
      "[data-testid='dashboard-balance'], [data-testid='onboarding-step-username']",
    )
    .first()
    .waitFor();
}
