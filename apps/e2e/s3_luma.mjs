/* Luminance proof for the re-captured dav-tab light files: mean
 * relative luminance of each PNG (decoded through a canvas), broken
 * (dark pixels under light names) vs re-captured. A light page reads
 * ~0.85+; a dark page ~0.10.
 */

import { chromium } from "@playwright/test";
import { readFileSync } from "node:fs";

const files = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage();

for (const file of files) {
  const b64 = readFileSync(file).toString("base64");
  const luma = await page.evaluate(async (dataUrl) => {
    const img = new Image();
    img.src = dataUrl;
    await new Promise((res, rej) => {
      img.onload = res;
      img.onerror = rej;
    });
    const canvas = document.createElement("canvas");
    // sample: scale down for speed, luminance is a mean
    const scale = Math.min(1, 800 / img.width);
    canvas.width = Math.round(img.width * scale);
    canvas.height = Math.round(img.height * scale);
    const ctx = canvas.getContext("2d");
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
    let sum = 0;
    for (let i = 0; i < data.length; i += 4) {
      // relative luminance approximation (sRGB coefficients)
      sum +=
        (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255;
    }
    return { mean: sum / (data.length / 4), w: img.width, h: img.height };
  }, `data:image/png;base64,${b64}`);

  console.log(`${file}: mean luma=${luma.mean.toFixed(3)} (${luma.w}x${luma.h})`);
}

await browser.close();
