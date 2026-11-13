import { expect, test } from "@playwright/test";
import {
  allowedOriginsFromEnv,
  watchRequestOrigins,
} from "./helpers/request-origins";
import { runtimeFor } from "./helpers/runtime";

// Read-only surface checks — safe on every runtime including
// production (ADR-0024's read-only subset: no side effects, no
// credentials). The authenticated pages get their coverage from
// sign-in.spec.ts and forgejo-lifecycle.spec.ts.
test("home page renders", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/FluxVale/);
});

test("sign-in page renders the email form", async ({ page }) => {
  await page.goto("/sign-in");
  await expect(page.getByTestId("sign-in-email")).toBeVisible();
  await expect(page.getByTestId("send-code")).toBeVisible();
});

// #164: the public catalog + sitemap — the programmatic-SEO surface.
// Still read-only (ADR-0024's read-only subset): no sign-in, no deploy,
// only GETs. The deploy-route check rides the anonymous 302, which is
// the auth boundary working, not a bypass.

test("the public catalog renders app cards", async ({ page }) => {
  await page.goto("/catalog");
  await expect(page.locator("[data-testid^='app-']").first()).toBeVisible();
});

test("clicking a catalog card opens the public app detail", async ({ page }) => {
  await page.goto("/catalog");
  await page.locator("[data-testid^='app-']").first().click();
  // URL + a catalog-specific element — the title alone would also match
  // the sign-in page if the route ever regressed to auth-gated.
  await expect(page).toHaveURL(/\/catalog\//);
  await expect(page.locator("h1")).toBeVisible();
  await expect(page.locator("[data-testid^='deploy-']").first()).toBeVisible();
});

// #716: catalog icons ship vendored and load same-origin. A hotlinked
// third-party icon whose host hangs never errors — it silently holds
// the page's load event hostage (the Nov 11 fleet-wide pages-leg
// outage: one hanging icon host timed every /catalog navigation out).
// The request listener covers every subresource, not just img src.
test("catalog pages make no cross-origin subresource requests during load", async ({
  page,
  baseURL,
}) => {
  const guard = watchRequestOrigins(page, new URL(baseURL!).origin);
  // Origins, not strings: currentSrc is the browser-resolved URL, so
  // protocol-relative and malformed srcs cannot slip a string sniff.
  const foreignImgSrcs = () =>
    page.locator("img").evaluateAll((imgs) =>
      imgs
        .map((img) => img.currentSrc)
        .filter((src) => {
          if (src === "") return false;
          try {
            return new URL(src).origin !== window.location.origin;
          } catch {
            return true;
          }
        }),
    );
  // Icon tiles only, never the whole page: the detail page's
  // screenshots are loading="lazy", so below the fold they sit
  // undecoded by design — polling them would mint a flake. An icon
  // tile that fails to decode is exactly the silent break this guard
  // exists for (a vendored file 404s quietly under Plug.Static).
  const iconImgs = () => page.locator("[data-testid='app-icon'] img, [data-testid^='app-'] img");
  const undecodedIconSrcs = () =>
    iconImgs().evaluateAll((imgs) =>
      imgs
        .filter((img) => !(img.complete && img.naturalWidth > 0))
        .map((img) => img.getAttribute("src") ?? "(no src)"),
    );

  await page.goto("/catalog");
  await expect(page.locator("[data-testid^='app-']").first()).toBeVisible();
  expect(await foreignImgSrcs()).toEqual([]);
  expect(await iconImgs().count()).toBeGreaterThan(0);
  await expect.poll(undecodedIconSrcs).toEqual([]);
  expect(
    guard.violations(),
    "cross-origin subresource requests during /catalog navigation",
  ).toEqual([]);

  await page.locator("[data-testid^='app-']").first().click();
  await expect(page).toHaveURL(/\/catalog\//);
  expect(await foreignImgSrcs()).toEqual([]);
  expect(await iconImgs().count()).toBeGreaterThan(0);
  await expect.poll(undecodedIconSrcs).toEqual([]);
  expect(
    guard.violations(),
    "cross-origin subresource requests during /catalog navigation",
  ).toEqual([]);
});

// The guard's own proof: planted subresources — not just img src — are
// flagged, and the allow-list control is not.
test("the origin guard flags a planted cross-origin subresource", async ({ page, baseURL }) => {
  // Path-bearing entry: normalization must reduce it to its origin, or
  // the allowed control below would register as a violation.
  const guard = watchRequestOrigins(page, new URL(baseURL!).origin, ["https://allowed.example/"]);

  await page.route("https://planted.example/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/plain", body: "" }),
  );
  await page.route("https://allowed.example/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/plain", body: "" }),
  );

  await page.goto("/catalog");

  const allowedSeen = page.waitForRequest("https://allowed.example/ok.png");

  await page.evaluate(() => {
    const img = document.createElement("img");
    img.src = "https://planted.example/pixel.png";
    document.body.append(img);

    const srcset = document.createElement("img");
    srcset.srcset = "https://planted.example/srcset.png 1x";
    document.body.append(srcset);

    const picture = document.createElement("picture");
    const source = document.createElement("source");
    source.srcset = "https://planted.example/source.png";
    picture.append(source);
    const fallback = document.createElement("img");
    fallback.src = "https://planted.example/fallback.png";
    picture.append(fallback);
    document.body.append(picture);

    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    stylesheet.href = "https://planted.example/style.css";
    document.head.append(stylesheet);

    const frame = document.createElement("iframe");
    frame.src = "https://planted.example/frame";
    document.body.append(frame);

    const background = document.createElement("div");
    background.style.width = "1px";
    background.style.height = "1px";
    background.style.backgroundImage = "url(https://planted.example/background.png)";
    document.body.append(background);

    const allowed = document.createElement("img");
    allowed.src = "https://allowed.example/ok.png";
    document.body.append(allowed);
  });

  await allowedSeen;

  await expect
    .poll(() => guard.violations())
    .toEqual(
      expect.arrayContaining([
        "https://planted.example/pixel.png",
        "https://planted.example/srcset.png",
        "https://planted.example/source.png",
        "https://planted.example/style.css",
        "https://planted.example/frame",
        "https://planted.example/background.png",
      ]),
    );
  // The <picture> fallback is not asserted: the browser may never request it.
  expect(guard.violations()).not.toContain("https://allowed.example/ok.png");
});

test("E2E_ALLOWED_ORIGINS normalizes origins and rejects malformed entries", () => {
  // The undefined case must mean "no config": an ambient allow-list (the
  // staging/Umami workflow sets it) would otherwise leak into the
  // default-parameter path and make this assertion environment-dependent.
  const ambient = process.env.E2E_ALLOWED_ORIGINS;
  delete process.env.E2E_ALLOWED_ORIGINS;

  try {
    expect(
      allowedOriginsFromEnv("https://analytics.example.com/script.js, https://b.example:8443"),
    ).toEqual(["https://analytics.example.com", "https://b.example:8443"]);
    expect(allowedOriginsFromEnv("")).toEqual([]);
    expect(allowedOriginsFromEnv(undefined)).toEqual([]);
    expect(() => allowedOriginsFromEnv("analytics.example.com")).toThrow(/not a URL/);
  } finally {
    if (ambient !== undefined) process.env.E2E_ALLOWED_ORIGINS = ambient;
  }
});

test("an anonymous deploy CTA lands on /sign-in — the auth boundary", async ({ page }) => {
  await page.goto("/catalog");
  const cardHref = await page.locator("[data-testid^='app-']").first().getAttribute("href");
  const slug = cardHref?.split("/").pop();
  expect(slug, "catalog card links carry a slug").toBeTruthy();

  await page.goto(`/apps/${slug}/deploy`);
  await expect(page).toHaveURL(/\/sign-in/);
});

test("the sitemap is served and mentions the catalog", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(response.status()).toBe(200);
  expect(await response.text()).toContain("/catalog");
});

// #412: the public feedback board — same read-only subset: GETs only,
// the board shell, one post page, and the sitemap rows.
//
// Demo rows come from the promotable seed, which is gated OFF for prod
// (the #412 ruling: fabricated votes are invented social proof; prod
// launches honestly empty). Content assertions run on the seeding
// runtimes — local, review, and staging (the runtime helper classifies
// review.fluxvale.app hosts staging-class); the prod leg asserts the
// shell: the page renders, the chrome's link exists, the sitemap lists
// the board.
const runtime = runtimeFor(process.env.BASE_URL);
const seedsDemoContent = runtime !== "production";

test("the feedback board renders the shell (header, footer link)", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByRole("heading", { name: "Feedback" })).toBeVisible();
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the feedback board renders post rows", async ({ page }) => {
  test.skip(!seedsDemoContent, "prod launches unseeded: no fabricated rows to assert");
  await page.goto("/feedback");
  await expect(page.locator("[data-testid^='feedback-post-']").first()).toBeVisible();
});

test("clicking a board row opens the public post page", async ({ page }) => {
  test.skip(!seedsDemoContent, "prod launches unseeded: no rows to click through");
  await page.goto("/feedback");
  await page.locator("[data-testid^='feedback-post-']").first().click();
  // URL + a board-specific element — the h1 alone would also match the
  // sign-in page if the route ever regressed to auth-gated.
  await expect(page).toHaveURL(/\/feedback\//);
  await expect(page.locator("h1")).toBeVisible();
  await expect(page.getByTestId("feedback-status")).toBeVisible();
});

test("the footer carries the feedback link on a public page", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the sitemap mentions the feedback board", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(await response.text()).toContain("/feedback");
});

// #412 T9: the roadmap — a shell check that runs on every runtime: the
// page renders honestly empty (three columns, the chrome) wherever no
// post is planned, started, or completed yet.
test("the roadmap renders the shell (heading, columns, footer link)", async ({ page }) => {
  await page.goto("/roadmap");
  await expect(page.getByRole("heading", { name: "Roadmap" })).toBeVisible();
  await expect(page.getByTestId("roadmap-column-planned")).toBeVisible();
  await expect(page.getByTestId("roadmap-column-started")).toBeVisible();
  await expect(page.getByTestId("roadmap-column-completed")).toBeVisible();
  await expect(page.getByTestId("footer-feedback")).toBeVisible();
});

test("the board header links to the roadmap", async ({ page }) => {
  await page.goto("/feedback");
  await expect(page.getByTestId("roadmap-link")).toBeVisible();
});

test("the sitemap mentions the roadmap", async ({ page }) => {
  const response = await page.request.get("/sitemap.xml");
  expect(await response.text()).toContain("/roadmap");
});
