const { chromium } = require("playwright");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const prototypeDirectory = __dirname;
const outputDirectory = path.resolve(prototypeDirectory, "..", "renders");
const outputPath = path.join(outputDirectory, "preflight-motion-demo.mp4");
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "voxol-preflight-"));
const baseUrl = pathToFileURL(path.join(prototypeDirectory, "index.html")).href;

async function pause(page, duration) {
  await page.waitForTimeout(duration);
}

async function waitForMorph(page) {
  await page.waitForFunction(() => !document.documentElement.hasAttribute("data-preflight-direction"));
}

(async () => {
  fs.mkdirSync(outputDirectory, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1248, height: 828 },
    deviceScaleFactor: 1,
    reducedMotion: "no-preference",
    recordVideo: {
      dir: temporaryDirectory,
      size: { width: 1248, height: 828 },
    },
  });
  const page = await context.newPage();
  const video = page.video();

  try {
    await page.goto(`${baseUrl}?capture=1&motion=1&screen=preflight&step=0`);
    await page.waitForFunction(() => window.__prototypeReady === true);
    await pause(page, 1100);

    await page.locator('[data-demo-index="1"]').click();
    await pause(page, 700);
    await page.locator('[data-demo-index="2"]').click();
    await pause(page, 800);

    await page.locator(".preflight-next").click();
    await waitForMorph(page);
    await pause(page, 300);
    while ((await page.locator("[data-grant]").count()) > 0) {
      await page.locator("[data-grant]").first().click();
      await pause(page, 480);
    }

    await pause(page, 500);
    await page.locator(".preflight-next").click();
    await waitForMorph(page);
    await pause(page, 500);
    await page.locator(".preflight-next").click();
    await waitForMorph(page);
    await pause(page, 400);

    const trigger = page.locator(".flight-hold");
    await trigger.dispatchEvent("pointerdown", { pointerId: 1 });
    await pause(page, 1300);
    await trigger.dispatchEvent("pointerup", { pointerId: 1 });
    await page.waitForFunction(() => document.querySelector(".flight-scene")?.dataset.flightState === "complete");
    await pause(page, 1000);

    await page.locator(".preflight-next").click();
    await waitForMorph(page);
    await pause(page, 1800);
  } finally {
    await page.close();
    await context.close();
    await browser.close();
  }

  const webmPath = await video.path();
  const result = spawnSync("/opt/homebrew/bin/ffmpeg", [
    "-y",
    "-i", webmPath,
    "-ss", "2.0",
    "-c:v", "libx264",
    "-preset", "medium",
    "-crf", "20",
    "-pix_fmt", "yuv420p",
    "-movflags", "+faststart",
    "-an",
    outputPath,
  ], { stdio: "inherit" });

  if (result.status !== 0) {
    throw new Error(`ffmpeg exited with status ${result.status}`);
  }

  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  process.stdout.write(`${outputPath}\n`);
})();
