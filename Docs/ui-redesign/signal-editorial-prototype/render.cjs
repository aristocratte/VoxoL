const { chromium } = require("playwright");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const prototypeDirectory = __dirname;
const outputDirectory = path.resolve(prototypeDirectory, "..", "renders");
const baseUrl = pathToFileURL(path.join(prototypeDirectory, "index.html")).href;

const captures = [
  { name: "01-brand-board", screen: "brand", width: 1248, height: 1008 },
  { name: "02-today", screen: "today", width: 1248, height: 828 },
  { name: "03-dictation", screen: "dictation", width: 1248, height: 828 },
  { name: "04-meetings", screen: "meetings", width: 1248, height: 828 },
  { name: "05-preflight", screen: "preflight", step: 0, width: 1248, height: 828 },
  { name: "06-today-minimum", screen: "today", width: 868, height: 648 },
  { name: "07-dictation-minimum", screen: "dictation", width: 868, height: 648 },
  { name: "08-insights", screen: "insights", width: 1248, height: 828 },
  { name: "09-insights-minimum", screen: "insights", width: 868, height: 648 },
  { name: "10-meetings-minimum", screen: "meetings", width: 868, height: 648 },
  { name: "11-library-minimum", screen: "library", width: 868, height: 648 },
  { name: "12-settings-minimum", screen: "settings", width: 868, height: 648 },
  { name: "13-preflight-access", screen: "preflight", step: 1, width: 1248, height: 828 },
  { name: "14-preflight-engines", screen: "preflight", step: 2, width: 1248, height: 828 },
  { name: "15-preflight-first-flight", screen: "preflight", step: 3, width: 1248, height: 828 },
  { name: "16-preflight-ready", screen: "preflight", step: 4, width: 1248, height: 828 },
  { name: "17-preflight-minimum", screen: "preflight", step: 0, width: 868, height: 648 },
  { name: "18-preflight-first-flight-minimum", screen: "preflight", step: 3, width: 868, height: 648 },
];

(async () => {
  const browser = await chromium.launch({ headless: true });

  try {
    for (const capture of captures) {
      const page = await browser.newPage({
        viewport: { width: capture.width, height: capture.height },
        deviceScaleFactor: 2,
        reducedMotion: "reduce",
      });
      const query = new URLSearchParams({
        capture: "1",
        screen: capture.screen,
      });
      if (capture.step !== undefined) query.set("step", String(capture.step));

      await page.goto(`${baseUrl}?${query.toString()}`);
      await page.waitForFunction(() => window.__prototypeReady === true);
      if (capture.screen === "brand") {
        const boardHeight = await page.locator(".brand-board").evaluate((board) => board.scrollHeight);
        await page.locator(".app-window").evaluate((windowElement, height) => {
          windowElement.style.height = `${height}px`;
        }, boardHeight);
        await page.locator(".brand-board").evaluate((board) => {
          board.style.overflow = "hidden";
        });
      }
      await page.locator(".app-window").screenshot({
        path: path.join(outputDirectory, `${capture.name}.png`),
        animations: "disabled",
      });
      await page.close();
    }
  } finally {
    await browser.close();
  }
})();
