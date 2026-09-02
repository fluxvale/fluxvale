import { defineConfig } from "@playwright/test";

// Four runtimes share this suite (ADR-0024): local, review env, staging,
// prod (read-only subset). The environment is chosen via BASE_URL — the
// suite never starts a server itself.
const baseURL = process.env.BASE_URL ?? "http://localhost:4000";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false, // one app under test per run, lifecycle tests come in M3
  retries: process.env.CI ? 1 : 0,
  reporter: [
    ["list"],
    // HTML report for post-run debugging (npx playwright show-report);
    // never auto-opens — scripts and CI must stay quiet
    ["html", { open: "never" }],
  ],
  use: {
    baseURL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  outputDir: "./test-results",
});
