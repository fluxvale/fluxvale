import type { Page } from "@playwright/test";

// #716's outage class: any subresource from a foreign origin can hang the
// browser's `load` event — srcset, <source>, CSS url(), <iframe>, and
// scripts all count, not just img src. The one sanctioned external
// script is SiteAnalytics (#576, Umami): it renders wherever
// UMAMI_SCRIPT_URL points, so a deployment that configures it
// allow-lists that origin via E2E_ALLOWED_ORIGINS.
export function allowedOriginsFromEnv(raw = process.env.E2E_ALLOWED_ORIGINS): string[] {
  if (raw === undefined || raw.trim() === "") return [];

  return raw
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "")
    .map((entry) => {
      try {
        return new URL(entry).origin;
      } catch {
        throw new Error(`E2E_ALLOWED_ORIGINS entry is not a URL: ${entry}`);
      }
    });
}

// Register before page.goto: a request that starts during the load is
// only seen by a listener already in place.
export function watchRequestOrigins(
  page: Page,
  pageOrigin: string,
  allowedOrigins: string[] = allowedOriginsFromEnv(),
): { violations: () => string[] } {
  const seen = new Set<string>();

  page.on("request", (request) => {
    const url = new URL(request.url());
    // data:, blob:, about: never touch a host and cannot hang load.
    if (url.protocol !== "http:" && url.protocol !== "https:") return;
    if (url.origin === pageOrigin || allowedOrigins.includes(url.origin)) return;
    seen.add(request.url());
  });

  // A Set keeps first-seen order and drops duplicates.
  return { violations: () => [...seen] };
}
