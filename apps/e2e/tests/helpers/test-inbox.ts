import type { APIRequestContext } from "@playwright/test";

// TestInbox client (ADR-0024 Am. 1): admin-PAT-gated JSON over Swoosh
// Local storage. 404 = nothing captured yet (poll); 401/403 = credential
// problem — fail fast instead of burning the timeout.
export class TestInbox {
  constructor(
    private readonly request: APIRequestContext,
    private readonly token: string,
  ) {}

  async latestCode(email: string, timeoutMs = 60_000): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    let lastState = "no attempt yet";

    while (Date.now() < deadline) {
      const resp = await this.request.get("/test-inbox/api/mails/latest", {
        params: { email },
        headers: { authorization: `Bearer ${this.token}` },
      });

      if (resp.ok()) {
        const mail = (await resp.json())?.mail;
        if (typeof mail?.code === "string" && /^\d{6}$/.test(mail.code)) {
          return mail.code;
        }
        lastState = `captured mail carries no 6-digit code: ${JSON.stringify(mail)}`;
      } else if (resp.status() === 404) {
        lastState = "no captured mail yet";
      } else {
        // 401 missing/invalid creds, 403 non-admin — both are a bad
        // E2E_TESTINBOX_TOKEN, retrying can't fix them
        throw new Error(
          `TestInbox ${resp.status()} — check E2E_TESTINBOX_TOKEN: ${await resp.text()}`,
        );
      }

      await new Promise((resolve) => setTimeout(resolve, 2_000));
    }

    throw new Error(
      `TestInbox: no sign-in code for ${email} within ${timeoutMs}ms (${lastState})`,
    );
  }
}
