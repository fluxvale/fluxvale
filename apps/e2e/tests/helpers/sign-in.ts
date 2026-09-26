import type { Page } from "@playwright/test";
import { TestInbox } from "./test-inbox";

// Passwordless sign-in through the real UI (ADR-0024 §5 — deterministic
// login, zero test backdoors): request a code for a per-run test+
// address (JIT-provisions the user, dodges the 60s resend throttle),
// read it from TestInbox, verify. Success is the native POST to
// /auth/session landing on /.
export async function signIn(page: Page, inbox: TestInbox, email: string) {
  await page.goto("/sign-in");
  // Wait out the connect race: the socket's first patch re-renders the
  // form and would wipe a value filled before it (phx-loading leaves
  // with the join).
  await page.waitForFunction(
    () =>
      document.querySelector("[data-phx-session]") !== null &&
      document.querySelector(".phx-loading") === null,
    undefined,
    { timeout: 15_000 },
  );

  await page.getByTestId("sign-in-email").fill(email);
  await page.getByTestId("send-code").click();

  const code = await inbox.latestCode(email);
  await page.getByTestId("sign-in-code").fill(code);
  await page.getByTestId("verify-code").click();
  await page.waitForURL((url) => url.pathname === "/");
}
