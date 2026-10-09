// Runtime derivation (ADR-0024's runtimes, #99's gating): E2E_RUNTIME
// may narrow what runs, but the BASE_URL host sets the ceiling — a
// production host is ALWAYS production-class (read-only), so the
// natural `BASE_URL=https://fluxvale.com npx playwright test` can never
// run destructive tests, with or without the env var.
export type Runtime = "local" | "staging" | "production";

const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]"];
const STAGING_HOST = "staging.fluxvale.com";

export function runtimeFor(baseUrl: string | undefined): Runtime {
  const requested = process.env.E2E_RUNTIME;
  const hostname = new URL(baseUrl ?? "https://app.fluxvale.lvh.me").hostname;

  const hostRuntime = LOCAL_HOSTS.includes(hostname) || hostname.endsWith(".lvh.me")
    ? "local"
    : hostname === STAGING_HOST
      ? "staging"
      : "production";

  // The floor: production hosts cannot be talked down from read-only.
  if (hostRuntime === "production") return "production";
  if (requested === "local" || requested === "staging" || requested === "production") {
    return requested;
  }
  return hostRuntime;
}
