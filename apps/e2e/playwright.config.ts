import { defineConfig } from "@playwright/test";

// Four runtimes share this suite (ADR-0024): local, review env, staging,
// prod (read-only subset). The environment is chosen via BASE_URL — the
// suite never starts a server itself. Default: the local k3d/Tilt stack
// (ADR-0020), reached through Traefik.
const baseURL = process.env.BASE_URL ?? "https://app.fluxvale.lvh.me";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false, // one app under test per run; lifecycle tests are serial by nature
  retries: process.env.CI ? 1 : 0,
  reporter: [
    ["list"],
    // HTML report for post-run debugging (npx playwright show-report);
    // never auto-opens — scripts and CI must stay quiet
    ["html", { open: "never" }],
  ],
  use: {
    baseURL,
    // Self-signed TLS on the local stack (ADR-0020); every runtime today
    // is either self-signed or internal. Revisit when cert-backed prod
    // joins (M4).
    ignoreHTTPSErrors: true,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  outputDir: "./test-results",
});
