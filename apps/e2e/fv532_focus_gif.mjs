// #532 focus GIF: keyboard focus enters the destructive confirm, the
// two buttons show their token ring, and Cancel returns focus to the
// trigger. Uses the admin moderation tag confirm (a real LiveView with
// no cluster dependency); the shell turns the webm into a GIF.
//
// Usage: FV_BASE=http://127.0.0.1:4001 FV_TOKEN=<admin jwt> \
//   node fv532_focus_gif.mjs <out.webm>
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const TOKEN = process.env.FV_TOKEN ?? "";
const TAG_ID = process.env.TAG_ID ?? "";
const out = process.argv[2] ?? "/tmp/opencode/fv532-focus.webm";

if (!TOKEN || !TAG_ID) {
  console.error("FV_TOKEN and TAG_ID required (an admin session token + a used tag id)");
  process.exit(1);
}

const browser = await chromium.launch();

// Establish the session in a throwaway context, then record a fresh
// context that starts on the interesting page.
const setup = await browser.newContext();
const setupPage = await setup.newPage();
await setupPage.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
const csrf = await setupPage.locator('meta[name="csrf-token"]').getAttribute("content");
await setupPage.request.post(`${BASE}/auth/session`, {
  form: { token: TOKEN },
  headers: { "x-csrf-token": csrf },
});
const state = "/tmp/opencode/fv532-state.json";
await setup.storageState({ path: state });
await setup.close();

const ctx = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  storageState: state,
  recordVideo: { dir: "/tmp/opencode/fv532-video", size: { width: 1280, height: 800 } },
});
await ctx.addInitScript(() => localStorage.setItem("phx:theme", "light"));
const page = await ctx.newPage();
const video = page.video();

await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
const trigger = page.locator(`[data-testid="admin-moderation-tag-delete-${TAG_ID}"]`);
await trigger.waitFor();
await trigger.scrollIntoViewIfNeeded();
await page.waitForTimeout(700);

// Open the confirm with the mouse, then drive it from the keyboard:
// focus lands on the block, Tab reaches the action then Cancel, and
// Enter on Cancel returns focus to the trigger.
await trigger.click();
await page.locator("[data-testid=destructive-confirm]").waitFor();
await page.waitForTimeout(900);
await page.keyboard.press("Tab");
await page.waitForTimeout(700);
await page.keyboard.press("Tab");
await page.waitForTimeout(700);
await page.keyboard.press("Enter");
await page.waitForTimeout(1200);

await video.saveAs(out);
await ctx.close();
await browser.close();
console.log("recorded", out);
