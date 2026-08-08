const { chromium } = require("playwright");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const baseUrl = pathToFileURL(path.join(__dirname, "index.html")).href;
const desktopScreens = ["brand", "today", "dictation", "insights", "meetings", "library", "settings", "preflight"];
const viewports = [
  { name: "desktop", width: 1248, height: 828, screens: desktopScreens },
  { name: "minimum", width: 868, height: 648, screens: ["today", "dictation", "insights", "meetings", "library", "settings", "preflight"] },
];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function assertPreflightSceneFits(page, label) {
  const state = await page.evaluate(() => {
    const main = document.querySelector(".preflight-main");
    const card = document.querySelector(".preflight-card");
    const scene = document.querySelector(".preflight-scene");
    const smallTargets = [...document.querySelectorAll(".screen--preflight button:not([disabled])")]
      .filter((element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
      })
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          label: element.getAttribute("aria-label") || element.textContent.trim().replace(/\s+/g, " ").slice(0, 48),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        };
      })
      .filter((target) => target.width < 40 || target.height < 40);

    return {
      mainHorizontalOverflow: main.scrollWidth - main.clientWidth,
      mainVerticalOverflow: main.scrollHeight - main.clientHeight,
      cardHorizontalOverflow: card.scrollWidth - card.clientWidth,
      cardVerticalOverflow: card.scrollHeight - card.clientHeight,
      sceneHorizontalOverflow: scene.scrollWidth - scene.clientWidth,
      sceneVerticalOverflow: scene.scrollHeight - scene.clientHeight,
      smallTargets,
    };
  });

  assert(state.mainHorizontalOverflow <= 1, `${label}: preflight main overflows horizontally by ${state.mainHorizontalOverflow}px`);
  assert(state.mainVerticalOverflow <= 1, `${label}: preflight main overflows vertically by ${state.mainVerticalOverflow}px`);
  assert(state.cardHorizontalOverflow <= 1, `${label}: preflight card overflows horizontally by ${state.cardHorizontalOverflow}px`);
  assert(state.cardVerticalOverflow <= 1, `${label}: preflight card overflows vertically by ${state.cardVerticalOverflow}px`);
  assert(state.sceneHorizontalOverflow <= 1, `${label}: preflight scene overflows horizontally by ${state.sceneHorizontalOverflow}px`);
  assert(state.sceneVerticalOverflow <= 1, `${label}: preflight scene overflows vertically by ${state.sceneVerticalOverflow}px`);
  assert(state.smallTargets.length === 0, `${label}: small preflight targets ${JSON.stringify(state.smallTargets)}`);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const failures = [];

  try {
    for (const viewport of viewports) {
      for (const screen of viewport.screens) {
        const page = await browser.newPage({
          viewport: { width: viewport.width, height: viewport.height },
          reducedMotion: "reduce",
        });
        const errors = [];
        page.on("pageerror", (error) => errors.push(error.message));
        page.on("console", (message) => {
          if (message.type() === "error") errors.push(message.text());
        });

        try {
          const preflightStep = screen === "preflight" ? 0 : 1;
          await page.goto(`${baseUrl}?capture=1&screen=${screen}&step=${preflightStep}`);
          await page.waitForFunction(() => window.__prototypeReady === true);

          const state = await page.evaluate(() => {
            const activeScreen = document.querySelector(".screen.is-active");
            const appWindow = document.querySelector(".app-window");
            const activeScroller = activeScreen?.querySelector(".screen-scroll");
            const visibleTargets = [...document.querySelectorAll("button:not([disabled]), a[href], input, select")]
              .filter((element) => !element.closest(".prototype-toolbar"))
              .filter((element) => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
              })
              .map((element) => {
                const rect = element.getBoundingClientRect();
                return {
                  label: element.getAttribute("aria-label") || element.textContent.trim().replace(/\s+/g, " ").slice(0, 48),
                  width: Math.round(rect.width),
                  height: Math.round(rect.height),
                };
              });

            return {
              activeScreen: activeScreen?.dataset.screen,
              fontFamily: getComputedStyle(appWindow).fontFamily,
              documentWidth: document.documentElement.scrollWidth,
              viewportWidth: window.innerWidth,
              appScrollWidth: appWindow.scrollWidth,
              appClientWidth: appWindow.clientWidth,
              activeScrollHeight: activeScroller?.scrollHeight ?? null,
              activeClientHeight: activeScroller?.clientHeight ?? null,
              smallTargets: visibleTargets.filter((target) => target.width < 40 || target.height < 40),
            };
          });

          assert(errors.length === 0, `${screen}: console errors: ${errors.join(" | ")}`);
          assert(state.activeScreen === screen, `${screen}: active screen is ${state.activeScreen}`);
          assert(state.fontFamily.includes("Outfit"), `${screen}: Outfit is not active (${state.fontFamily})`);
          assert(state.documentWidth <= state.viewportWidth, `${screen}: document overflows ${state.documentWidth}px > ${state.viewportWidth}px`);
          assert(state.appScrollWidth <= state.appClientWidth, `${screen}: app overflows ${state.appScrollWidth}px > ${state.appClientWidth}px`);
          if (state.activeScrollHeight !== null) {
            assert(state.activeScrollHeight <= state.activeClientHeight + 1, `${screen}: first viewport requires vertical scroll ${state.activeScrollHeight}px > ${state.activeClientHeight}px`);
          }
          assert(state.smallTargets.length === 0, `${screen}: small targets ${JSON.stringify(state.smallTargets)}`);

          if (screen === "today") {
            await page.locator(".voice-trigger").click();
            assert(await page.locator(".voice-trigger").getAttribute("aria-pressed") === "true", "today: voice state did not activate");
          }

          if (screen === "meetings") {
            await page.locator('[data-meeting-tab="actions"]').click();
            assert(await page.locator('[data-meeting-panel="actions"]').isVisible(), "meetings: actions panel did not open");
          }

          if (screen === "insights") {
            const periodButtons = page.locator(".insights-period button");
            await periodButtons.nth(1).click();
            assert(await periodButtons.nth(1).evaluate((button) => button.classList.contains("is-selected")), "insights: period did not update");
          }

          if (screen === "preflight") {
            const before = await page.locator(".preflight-eyebrow").textContent();
            await assertPreflightSceneFits(page, `${viewport.name}/preflight-intro`);
            await page.locator(".preflight-next").click();
            const after = await page.locator(".preflight-eyebrow").textContent();
            assert(before !== after, "preflight: next step did not advance");
            await assertPreflightSceneFits(page, `${viewport.name}/preflight-access`);
            while ((await page.locator("[data-grant]").count()) > 0) {
              await page.locator("[data-grant]").first().click();
            }
            assert((await page.locator(".permission-list .is-allowed").count()) === 3, "preflight: permission grants did not update");

            await page.locator(".preflight-next").click();
            assert(await page.locator(".engines-scene").isVisible(), "preflight: engines scene did not open");
            await assertPreflightSceneFits(page, `${viewport.name}/preflight-engines`);

            await page.locator(".preflight-next").click();
            assert(await page.locator(".flight-scene").isVisible(), "preflight: first-flight scene did not open");
            assert(await page.locator(".preflight-next").isDisabled(), "preflight: first-flight gate should start disabled");
            await assertPreflightSceneFits(page, `${viewport.name}/preflight-first-flight`);
            await page.locator(".flight-hold").dispatchEvent("pointerdown", { pointerId: 1 });
            await page.locator(".flight-hold").dispatchEvent("pointerup", { pointerId: 1 });
            await page.waitForFunction(() => document.querySelector(".flight-scene")?.dataset.flightState === "complete");
            assert(!(await page.locator(".preflight-next").isDisabled()), "preflight: guided interaction did not unlock the next step");

            await page.locator(".preflight-next").click();
            assert(await page.locator(".ready-scene").isVisible(), "preflight: ready scene did not open");
            await assertPreflightSceneFits(page, `${viewport.name}/preflight-ready`);

            await page.locator(".preflight-back").click();
            assert(await page.locator(".flight-scene").isVisible(), "preflight: back did not return to the guided interaction");
          }

          process.stdout.write(`✓ ${viewport.name}/${screen}\n`);
        } catch (error) {
          const failure = `${viewport.name}/${screen}: ${error.message}`;
          failures.push(failure);
          process.stderr.write(`✗ ${failure}\n`);
        } finally {
          await page.close();
        }
      }
    }

    const motionPage = await browser.newPage({
      viewport: { width: 1248, height: 828 },
      reducedMotion: "no-preference",
    });
    const motionErrors = [];
    motionPage.on("pageerror", (error) => motionErrors.push(error.message));
    motionPage.on("console", (message) => {
      if (message.type() === "error") motionErrors.push(message.text());
    });

    try {
      await motionPage.goto(`${baseUrl}?capture=1&motion=1&screen=preflight&step=0`);
      await motionPage.waitForFunction(() => window.__prototypeReady === true);
      assert(await motionPage.evaluate(() => typeof document.startViewTransition === "function"), "motion/preflight: View Transitions API is unavailable");

      const cursorStart = await motionPage.locator(".preflight-progress__cursor").boundingBox();
      await motionPage.locator(".preflight-next").click();
      assert(await motionPage.locator(".preflight-main").evaluate((element) => element.classList.contains("is-morphing")), "motion/preflight: morph state did not start");
      assert(await motionPage.evaluate(() => document.getAnimations().length > 0), "motion/preflight: no shared-element animations are running");
      await motionPage.waitForFunction(() => !document.documentElement.hasAttribute("data-preflight-direction"));
      const cursorEnd = await motionPage.locator(".preflight-progress__cursor").boundingBox();
      assert(cursorStart && cursorEnd && cursorEnd.x > cursorStart.x + 20, "motion/preflight: liquid progress cursor did not move");

      await motionPage.locator(".preflight-next").click();
      await motionPage.waitForTimeout(100);
      await motionPage.locator(".preflight-back").evaluate((button) => button.click());
      await motionPage.waitForFunction(() => !document.documentElement.hasAttribute("data-preflight-direction"));
      assert(await motionPage.locator(".permissions-scene").isVisible(), "motion/preflight: interrupted reverse morph did not settle on permissions");
      assert(motionErrors.length === 0, `motion/preflight: console errors: ${motionErrors.join(" | ")}`);
      process.stdout.write("✓ motion/preflight-morph\n");
    } catch (error) {
      const failure = `motion/preflight: ${error.message}`;
      failures.push(failure);
      process.stderr.write(`✗ ${failure}\n`);
    } finally {
      await motionPage.close();
    }
  } finally {
    await browser.close();
  }

  if (failures.length > 0) {
    process.stderr.write(`${failures.join("\n")}\n`);
    process.exitCode = 1;
  }
})();
