/* Admin feedback moderation captures (#501): the populated state set in
 * both themes, plus the destroy-confirm reveal GIF (the reveal is
 * motion). Local dev target only (127.0.0.1:4000), driven by a minted
 * admin session token via FV_TOKEN_ADMIN (see admin_shell_screenshot.mjs
 * for the mint one-liner).
 *
 * Two phases, matching the seed contract in
 * moderation_capture_seed.exs:
 *
 *   node admin_moderation_screenshot.mjs <outdir> empty
 *     — against a dev DB with no feedback posts: the honest empty board.
 *
 *   node admin_moderation_screenshot.mjs <outdir> full
 *     — against the seeded data (demo posts + the moderation capture
 *       set): the list, a post expansion (sanitized body, votes,
 *       comments, tags), every confirm reveal, the referenced-original
 *       guard note, the search empty state, and the sidebar live.
 *
 * Also prints the width probe: the content band's scrollWidth vs
 * clientWidth at 1024/1280/1440 (the lane's width discipline).
 */
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const outdir = process.argv[2] ?? "/tmp/opencode/fv501-g-shots";
const phase = process.argv[3] ?? "full";
mkdirSync(outdir, { recursive: true });
const videoDir = `${outdir}/video`;
mkdirSync(videoDir, { recursive: true });

const token = process.env.FV_TOKEN_ADMIN ?? "";
if (!token) {
  console.error("FV_TOKEN_ADMIN required (see the header comment)");
  process.exit(1);
}

async function setTheme(page, mode) {
  await page.evaluate((m) => {
    localStorage.setItem("phx:theme", m);
    document.documentElement.setAttribute("data-theme", m);
    document.documentElement.setAttribute("data-theme-source", "user");
  }, mode);
  await page.waitForTimeout(300);
}

const browser = await chromium.launch();

const newSession = async ({ width = 1440, height = 900, video = false } = {}) => {
  const ctx = await browser.newContext({
    viewport: { width, height },
    ...(video ? { recordVideo: { dir: videoDir, size: { width, height } } } : {}),
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  return { ctx, page };
};

// goto + the page-mounted assertion (a 500 or a bounce must never
// masquerade as a capture) + theme, then the still. The sticky header
// is neutralized for the shot: a fullPage stitch scrolls the page and
// the fixed header ghosts into every viewport band (the re-shoot
// finding) — the still shows the document at scroll 0 with the header
// in document flow.
async function shot(page, name, mode, { fullPage = true, path = "/admin/moderation" } = {}) {
  await page.goto(`${BASE}${path}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  await setTheme(page, mode);
  await page.addStyleTag({ content: "header.sticky { position: static !important; }" });
  await page.screenshot({ path: `${outdir}/${name}.png`, fullPage });
  console.log(`captured ${name}.png`);
}

// The width probe: the content band beside the sidebar must not
// scroll horizontally at the lane's three widths.
async function widthProbe() {
  for (const width of [1024, 1280, 1440]) {
    const { ctx, page } = await newSession({ width, height: 900 });
    await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-moderation-content']");
    const numbers = await page.evaluate(() => {
      const band = document.querySelector("[data-testid='admin-moderation-content']");
      return {
        scrollWidth: band.scrollWidth,
        clientWidth: band.clientWidth,
        documentScrollWidth: document.documentElement.scrollWidth,
        viewport: window.innerWidth,
      };
    });
    console.log(
      `width probe @${width}: band scrollWidth=${numbers.scrollWidth} clientWidth=${numbers.clientWidth} document scrollWidth=${numbers.documentScrollWidth}`,
    );
    await ctx.close();
  }
}

if (phase === "empty") {
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await shot(page, `admin-moderation-empty-${mode}`, mode);
    await ctx.close();
  }
}

if (phase === "full") {
  // The list and the shell, both themes.
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await shot(page, `admin-moderation-list-${mode}`, mode);
    await page.waitForSelector("[data-testid^='admin-moderation-title-']");
    await ctx.close();
  }

  // The expansion: sanitized body, tags, votes, comments. The CSV
  // export post carries all of it (the duplicate banner state lives on
  // the duplicate's own row).
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-sidebar']");
    await setTheme(page, mode);
    await page.addStyleTag({ content: "header.sticky { position: static !important; }" });

    const row = page
      .locator("#admin-moderation-posts > div", {
        hasText: "Moderation capture export usage as CSV",
      })
      .first();
    await row.waitFor();
    await row.locator("[data-testid^='admin-moderation-expand-']").first().click();
    await page.waitForSelector("[data-testid='admin-moderation-post-body']");
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${outdir}/admin-moderation-expanded-${mode}.png`, fullPage: true });
    console.log(`captured admin-moderation-expanded-${mode}.png`);
    await ctx.close();
  }

  // The referenced-original guard: the duplicate points at the CSV
  // export post, so its expansion shows the honest note and its delete
  // button renders disabled WITH the reason (no click needed, no dead
  // lever offered).
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-sidebar']");
    await setTheme(page, mode);
    await page.addStyleTag({ content: "header.sticky { position: static !important; }" });

    const rowContainer = page.locator("#admin-moderation-posts > div", {
      hasText: "Moderation capture export usage as CSV",
    });
    await rowContainer.locator("[data-testid^='admin-moderation-expand-']").first().click();
    await page.waitForSelector("[data-testid='admin-moderation-referenced-note']");
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-moderation-referenced-note-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-referenced-note-${mode}.png`);
    await ctx.close();
  }

  // The confirm reveals on the keyboard-shortcuts post (unreferenced):
  // post destroy. Vote and comment confirms ride the same post's
  // expansion (it has one vote, no comments — the comment confirm uses
  // the CSV export post's comment instead).
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-sidebar']");
    await setTheme(page, mode);
    await page.addStyleTag({ content: "header.sticky { position: static !important; }" });

    const rowContainer = page.locator("#admin-moderation-posts > div", {
      hasText: "Moderation capture keyboard shortcuts everywhere",
    });
    await rowContainer.locator("[data-testid^='admin-moderation-expand-']").first().click();
    await page.waitForSelector("[data-testid='admin-moderation-danger-zone']");
    await rowContainer
      .locator("[data-testid='admin-moderation-destroy-post']")
      .first()
      .click();
    await page.waitForSelector("[data-testid='admin-moderation-destroy-confirm']");
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-moderation-destroy-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-destroy-confirm-${mode}.png`);

    // The vote retract confirm, same post (one admin-org vote).
    await page.locator("[data-testid='admin-moderation-destroy-cancel']").click();
    await page.waitForSelector("[data-testid='admin-moderation-destroy-confirm']", {
      state: "detached",
    });
    await rowContainer.locator("[data-testid^='admin-moderation-retract-']").first().click();
    await page.waitForSelector("[data-testid='admin-moderation-retract-confirm']");
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-moderation-retract-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-retract-confirm-${mode}.png`);
    await page.locator("[data-testid='admin-moderation-retract-cancel']").click();

    await ctx.close();
  }

  // The comment delete confirm + the used-tag delete confirm + the
  // search empty state, on the CSV export post.
  for (const mode of ["light", "dark"]) {
    const { ctx, page } = await newSession();
    await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-testid='admin-sidebar']");
    await setTheme(page, mode);
    await page.addStyleTag({ content: "header.sticky { position: static !important; }" });

    const rowContainer = page.locator("#admin-moderation-posts > div", {
      hasText: "Moderation capture export usage as CSV",
    });
    await rowContainer.locator("[data-testid^='admin-moderation-expand-']").first().click();
    await page.waitForSelector("[data-testid^='admin-moderation-comment-delete-']");
    await rowContainer
      .locator("[data-testid^='admin-moderation-comment-delete-']")
      .first()
      .click();
    await page.waitForSelector("[data-testid='admin-moderation-comment-delete-confirm']");
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-moderation-comment-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-comment-confirm-${mode}.png`);
    await page.locator("[data-testid='admin-moderation-comment-delete-cancel']").click();

    // The used-tag confirm (Capture platform carries the export post).
    const tagRow = page.locator("#admin-moderation-tags-list > div", {
      hasText: "Capture platform",
    });
    await tagRow.locator("[data-testid^='admin-moderation-tag-delete-']").first().click();
    await page.waitForSelector("[data-testid='admin-moderation-tag-delete-confirm']");
    await page.waitForTimeout(300);
    await page.screenshot({
      path: `${outdir}/admin-moderation-tag-confirm-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-tag-confirm-${mode}.png`);
    await page.locator("[data-testid='admin-moderation-tag-delete-cancel']").click();
    await page.waitForSelector("[data-testid='admin-moderation-tag-delete-confirm']", {
      state: "detached",
    });

    // The search empty state.
    const searchBox = page.locator("[data-testid='admin-moderation-search-input']");
    await searchBox.fill("zzz-no-such-post");
    await page.waitForTimeout(600);
    await page.screenshot({
      path: `${outdir}/admin-moderation-search-empty-${mode}.png`,
      fullPage: true,
    });
    console.log(`captured admin-moderation-search-empty-${mode}.png`);

    await ctx.close();
  }

  // The band widths (the shell capture's contract): the populated list
  // beside the nav at the md floor and mid-band.
  for (const width of [768, 900]) {
    const { ctx, page } = await newSession({ width, height: 900 });
    await shot(page, `admin-moderation-band-${width}-light`, "light");
    await ctx.close();
  }

  // The sidebar itself, cropped: the section live (a real link, no
  // Coming badge) with the deep debugging group.
  const { ctx: sideCtx, page: sidePage } = await newSession();
  await sidePage.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
  await sidePage.waitForSelector("[data-testid='admin-sidebar']");
  await setTheme(sidePage, "light");
  await sidePage.locator("[data-testid='admin-sidebar']").screenshot({
    path: `${outdir}/admin-sidebar-feedback-live.png`,
  });
  console.log("captured admin-sidebar-feedback-live.png");
  await sideCtx.close();

  await widthProbe();
}

// The reveal GIF: cause and effect on the post destroy confirm — the
// cursor presses Delete post, the panel reveals under it and is HELD,
// then Cancel closes it. Cropped 1:1 to the expanded panel's bounding
// box (+40px margin) so the full panel stays framed (the #554
// discipline); fps 12, scaled to 720 wide to stay under 300KB.
if (phase === "gif") {
  const { execFileSync } = await import("node:child_process");
  const { unlinkSync } = await import("node:fs");

  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } },
  });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/sign-in`, { waitUntil: "networkidle" });
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  await page.request.post(`${BASE}/auth/session`, {
    form: { token },
    headers: { "x-csrf-token": csrf },
  });
  await page.goto(`${BASE}/admin/moderation`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-testid='admin-sidebar']");
  await setTheme(page, "light");

  const rowContainer = page.locator("#admin-moderation-posts > div", {
    hasText: "Moderation capture keyboard shortcuts everywhere",
  });
  await rowContainer.locator("[data-testid^='admin-moderation-expand-']").first().click();
  await page.waitForSelector("[data-testid='admin-moderation-danger-zone']");

  const panel = page.locator("[data-testid^='admin-moderation-detail-']");
  await panel.waitFor();
  const preRow = await rowContainer.boundingBox();
  console.log(`row bbox pre-reveal: ${JSON.stringify(preRow)}`);

  // Park the row's TITLE at a fixed height so the whole row (title
  // through the grown panel) stays inside the video crop.
  await page.mouse.wheel(0, preRow.y - 120);
  await page.waitForTimeout(300);

  const destroy = rowContainer.locator("[data-testid='admin-moderation-destroy-post']");
  const dbox = await destroy.boundingBox();
  await destroy.hover();
  await page.waitForTimeout(400);
  await page.mouse.move(dbox.x + dbox.width / 2, dbox.y + dbox.height / 2, { steps: 8 });
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.up();
  await page.locator("[data-testid='admin-moderation-destroy-confirm']").waitFor();
  // The reveal HELD for half the loop.
  await page.waitForTimeout(2800);

  // The crop is measured AFTER the reveal and frames the WHOLE row:
  // the title on top, the panel below, nothing else.
  const revealed = await rowContainer.boundingBox();
  const box = {
    x: Math.round(revealed.x),
    y: Math.round(revealed.y),
    w: Math.round(revealed.width),
    h: Math.round(revealed.height),
  };
  console.log(`row bbox post-reveal: ${JSON.stringify(box)}`);

  const cancel = page.locator("[data-testid='admin-moderation-destroy-cancel']");
  const cbox = await cancel.boundingBox();
  await page.mouse.move(cbox.x + cbox.width / 2, cbox.y + cbox.height / 2, { steps: 8 });
  await cancel.click();
  await page.locator("[data-testid='admin-moderation-destroy-confirm']").waitFor({
    state: "detached",
  });
  await page.waitForTimeout(400);

  const video = await page.video().path();
  await ctx.close();
  console.log(`recorded ${video}`);

  const m = 20; // margin around the framed row
  const x = Math.max(0, box.x - m);
  const y = Math.max(0, box.y - m);
  const w = Math.min(1440 - x, box.w + 2 * m);
  const h = Math.min(900 - y, box.h + 2 * m);
  const out = `${outdir}/admin-moderation-destroy-confirm-reveal.gif`;
  execFileSync("ffmpeg", [
    "-y",
    "-i",
    video,
    // Output-side seek: frame-accurate (the webm's variable frame rate
    // makes keyframe input seeks land wherever they like).
    "-ss",
    "2.2",
    "-vf",
    `fps=4,crop=${w}:${h}:${x}:${y},scale=380:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=96[p];[s1][p]paletteuse=dither=none`,
    "-loop",
    "0",
    out,
  ]);
  unlinkSync(video);
  console.log(`captured admin-moderation-destroy-confirm-reveal.gif (crop=${w}:${h}:${x}:${y})`);
}

await browser.close();
console.log("done");
