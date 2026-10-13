import type { Page } from "@playwright/test";

// Wait out the connect race before interacting with a LiveView. A phx
// event pushed before the channel joins is silently dropped client-side
// (LiveView's pushWithReply short-circuits with "no connection" while
// canPush() is false); a phx link clicked in that window falls back to a
// full page load. On local k3d the join lands in a few ms so the race
// never shows; through a real edge it takes hundreds of ms and an event
// fired right after a page load loses it (#148) — the wait makes the
// interaction order deterministic on every runtime. phx-connected is
// the join signal: the client sets it on the view root in hideLoader(),
// and the server never renders it (phx-loading alone has a 1ms timer
// window where it isn't applied yet).
export async function waitForLiveViewJoin(page: Page, timeoutMs = 15_000) {
  await page.waitForFunction(
    () => document.querySelector("[data-phx-session].phx-connected") !== null,
    undefined,
    { timeout: timeoutMs },
  );
}
