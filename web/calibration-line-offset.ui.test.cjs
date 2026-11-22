const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const { waitForDownloadSlot } = require("./browser-test-download.cjs");

test("shared reference line offsets keep five drafts, cancelled work and exact downloads", async (t) => {
  const directory = path.resolve(__dirname, "../_build/site");
  const fixture = JSON.parse(
    fs.readFileSync(
      path.resolve(__dirname, "../examples/calibration-line-offset.json"),
      "utf8",
    ),
  );
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    const file = path.resolve(
      directory,
      url.pathname === "/" ? "index.html" : url.pathname.slice(1),
    );
    if (
      !file.startsWith(directory + path.sep) ||
      !fs.existsSync(file) ||
      !fs.statSync(file).isFile()
    ) {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, {
      "Content-Type":
        {
          ".html": "text/html; charset=utf-8",
          ".mjs": "text/javascript",
          ".css": "text/css",
          ".json": "application/json",
        }[path.extname(file)] || "application/octet-stream",
    });
    fs.createReadStream(file).pipe(response);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({
      headless: true,
      channel: process.env.MOONGROUND_BROWSER_CHANNEL,
    });
    t.diagnostic(
      JSON.stringify({
        browser_version: browser.version(),
        channel: process.env.MOONGROUND_BROWSER_CHANNEL || "chromium",
      }),
    );
    for (const width of [1440, 390]) {
      const context = await browser.newContext({
        viewport: { width, height: 950 },
        acceptDownloads: true,
      });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      let releaseExample, exampleRequested;
      const gate = new Promise((resolve) => {
        releaseExample = resolve;
      });
      const requested = new Promise((resolve) => {
        exampleRequested = resolve;
      });
      await page.route("**/calibration-line-offset.json", async (route) => {
        exampleRequested();
        await gate;
        await route.fulfill({
          contentType: "application/json",
          body: JSON.stringify(fixture),
        });
      });
      await page.goto(`http://127.0.0.1:${server.address().port}/`, {
        waitUntil: "domcontentloaded",
      });
      await page.waitForFunction(() =>
        document
          .querySelector("#calibration-sensitivity-input")
          .value.includes('"probes"'),
      );
      await page.locator("#calibration-section").evaluate((e) => {
        e.open = true;
      });
      const section = page.locator("#calibration-sensitivity-section");
      await section.evaluate((e) => {
        e.open = true;
      });
      const mode = page.locator("#calibration-sensitivity-mode"),
        input = page.locator("#calibration-sensitivity-input");
      const compute = page.locator("#calibration-sensitivity-compute"),
        download = page.locator("#download-calibration-sensitivity");
      async function run(count) {
        await compute.click();
        await page.waitForFunction(
          (n) =>
            !document.querySelector("#calibration-sensitivity-compute")
              .disabled &&
            !document.querySelector("#download-calibration-sensitivity")
              .disabled &&
            document.querySelectorAll("#calibration-sensitivity-rows tr")
              .length === n,
          count,
        );
      }
      async function exported() {
        await waitForDownloadSlot(page);
        const event = page.waitForEvent("download");
        await download.click();
        const file = await event;
        assert.equal(
          file.suggestedFilename(),
          "moonground-calibration-line-offset.json",
        );
        return JSON.parse(fs.readFileSync(await file.path(), "utf8"));
      }
      await mode.selectOption("line_offset");
      await requested;
      const draft = structuredClone(fixture);
      draft.comparisons[0].probe_id = "参考线🌙 <img src=x onerror=alert(1)>";
      const text = JSON.stringify(draft);
      await input.fill(text);
      releaseExample();
      await page.waitForTimeout(50);
      assert.equal(await input.inputValue(), text);
      await run(2);
      const original = await exported();
      assert.equal(original.comparisons[0].difference_m, 5);
      assert.equal(original.comparisons[0].cross_contribution_m2, -0.09375);
      assert.match(
        await page.locator("#calibration-sensitivity-message").innerText(),
        /2 组参考线偏移/,
      );
      assert.equal(
        await page.locator("#calibration-sensitivity-rows img").count(),
        0,
      );
      assert.match(
        await page.locator("#calibration-sensitivity-scope").innerText(),
        /无限直线.*左侧为正/,
      );
      await page
        .locator("#calibration-sensitivity-rows details")
        .first()
        .evaluate((e) => {
          e.open = true;
        });
      assert.match(
        await page.locator("#calibration-sensitivity-rows").innerText(),
        /参考起点.*参考终点/s,
      );
      for (const selected of ["position", "distance", "angle", "area"]) {
        await mode.selectOption(selected);
        await input.fill(`independent ${selected} draft`);
      }
      await mode.selectOption("line_offset");
      assert.equal(await input.inputValue(), text);
      assert.deepEqual(await exported(), original);
      await page.evaluate(() => {
        const saved = window.setTimeout;
        window.setTimeout = (callback, delay, ...args) => {
          if (delay === 0) {
            window.setTimeout = saved;
            window.releaseOffset = () => callback(...args);
            return 0;
          }
          return saved(callback, delay, ...args);
        };
      });
      await compute.click();
      await page.waitForFunction(
        () => typeof window.releaseOffset === "function",
      );
      await mode.selectOption("area");
      await page.evaluate(() => window.releaseOffset());
      assert.equal(await input.inputValue(), "independent area draft");
      await mode.selectOption("line_offset");
      assert.deepEqual(await exported(), original);
      await page.evaluate(() => {
        window.savedOffsetParse = JSON.parse;
        JSON.parse = (text, ...args) => {
          if (
            String(text).includes('"kind":"calibration_line_offset_comparison"')
          )
            throw new Error("simulated line offset response failure");
          return window.savedOffsetParse(text, ...args);
        };
      });
      await compute.click();
      await page.waitForFunction(() =>
        document
          .querySelector("#calibration-sensitivity-message")
          .textContent.includes("simulated line offset"),
      );
      await page.evaluate(() => {
        JSON.parse = window.savedOffsetParse;
      });
      assert.deepEqual(await exported(), original);
      const maximum = structuredClone(fixture);
      maximum.modes = Array.from(
        { length: 32 },
        (_, i) => fixture.modes[i % 2],
      );
      maximum.comparisons = Array.from({ length: 256 }, (_, i) => ({
        ...fixture.comparisons[0],
        probe_id: `max-${i}`,
      }));
      await input.fill(JSON.stringify(maximum));
      await run(256);
      assert.equal((await exported()).comparisons.length, 256);
      await section.evaluate((e) => {
        e.open = false;
      });
      await page.waitForFunction(
        () =>
          document.querySelectorAll("#calibration-sensitivity-rows tr")
            .length === 0,
      );
      await section.evaluate((e) => {
        e.open = true;
      });
      await page.waitForFunction(
        () =>
          document.querySelectorAll("#calibration-sensitivity-rows tr")
            .length === 256,
      );
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > window.innerWidth,
        ),
        false,
      );
      assert.deepEqual(errors, []);
      await context.close();
    }
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
