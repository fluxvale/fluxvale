// #532 contrast transcript: the confirm heading's actual rendered color
// against the confirm block's actual composited background, both color
// modes, plus the base --danger token's ratio for the before/after pair.
// WCAG 2.x sRGB relative-luminance math, computed in the browser.
//
// Usage: FV_BASE=http://127.0.0.1:4001 node fv532_contrast.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.FV_BASE ?? "http://127.0.0.1:4000";
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

for (const mode of ["light", "dark"]) {
  await page.goto(`${BASE}/storybook/components/confirm_block`, { waitUntil: "networkidle" });
  await page.waitForTimeout(400);

  if (mode === "dark") {
    await page.evaluate(() =>
      document.querySelector('#psb-colormode-dropdown a[phx-click*="dark"]').click(),
    );
    await page.waitForTimeout(700);
  }

  const result = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    const c = canvas.getContext("2d", { willReadFrequently: true });

    // Resolve any CSS color to unpremultiplied sRGB bytes.
    const rgba = (color) => {
      c.clearRect(0, 0, 1, 1);
      c.fillStyle = "#000";
      c.fillStyle = color;
      c.fillRect(0, 0, 1, 1);
      return [...c.getImageData(0, 0, 1, 1).data];
    };

    const luminance = ([r, g, b]) => {
      const lin = (v) => {
        const s = v / 255;
        return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    };

    const contrast = (a, b) => {
      const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
      return (hi + 0.05) / (lo + 0.05);
    };

    const block = document.querySelector("[data-testid=destructive-confirm]");
    const heading = document.querySelector("[data-testid=destructive-confirm] > p");
    const blockStyle = getComputedStyle(block);

    // The confirm renders inside a .card in the app; the storybook
    // canvas is not an app surface. Composite the block's tint over
    // the app's --panel token — the surface the heading actually sits
    // on in production.
    c.clearRect(0, 0, 1, 1);
    c.fillStyle = blockStyle.getPropertyValue("--panel").trim();
    c.fillRect(0, 0, 1, 1);
    c.fillStyle = getComputedStyle(block).backgroundColor;
    c.fillRect(0, 0, 1, 1);
    const surface = [...c.getImageData(0, 0, 1, 1).data].slice(0, 3);
    const after = rgba(getComputedStyle(heading).color);
    const before = rgba(blockStyle.getPropertyValue("--danger").trim());
    const deep = rgba(blockStyle.getPropertyValue("--danger-deep").trim());

    return {
      blockBg: getComputedStyle(block).backgroundColor,
      panelToken: blockStyle.getPropertyValue("--panel").trim(),
      surface: `rgb(${surface.join(", ")})`,
      headingColor: getComputedStyle(heading).color,
      dangerToken: blockStyle.getPropertyValue("--danger").trim(),
      deepToken: blockStyle.getPropertyValue("--danger-deep").trim(),
      before: contrast(before.slice(0, 3), surface).toFixed(2),
      after: contrast(after.slice(0, 3), surface).toFixed(2),
      deep: contrast(deep.slice(0, 3), surface).toFixed(2),
    };
  });

  console.log(`[${mode}]`);
  console.log(`  app card surface: --panel ${result.panelToken}`);
  console.log(`  block background: ${result.blockBg}`);
  console.log(`  composited surface: ${result.surface}`);
  console.log(`  heading color: ${result.headingColor}`);
  console.log(`  --danger token: ${result.dangerToken}`);
  console.log(`  --danger-deep token: ${result.deepToken}`);
  console.log(`  before (base --danger): ${result.before}:1`);
  console.log(`  after  (--danger-deep): ${result.after}:1`);
}

await browser.close();
