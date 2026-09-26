import { defineConfig } from "@playwright/test";

// Four runtimes share this suite (ADR-0024): local, review env, staging,
// prod (read-only subset). The environment is chosen via BASE_URL — the
// suite never starts a server itself. Default: the local k3d/Tilt stack
// (ADR-0020), reached through Traefik.
const baseURL = process.env.BASE_URL ?? "https://app.fluxvale.lvh.me";
const target = new URL(baseURL);

// Local targets: loopback or the lvh.me dev wildcard (ADR-0020). Only
// these may skip TLS validation (self-signed) or ride plain http — the
// TestInbox PAT must never travel cleartext to a real deployment.
const isLocal =
  ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname) ||
  target.hostname.endsWith(".lvh.me");

if (target.protocol !== "https:" && !isLocal) {
  throw new Error(
    `BASE_URL must be https for non-local targets (got ${baseURL})`,
  );
}

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
    ignoreHTTPSErrors: isLocal,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  outputDir: "./test-results",
});
