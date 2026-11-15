const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

test("circular calibration angles, three independent drafts and cancelled work on mobile and desktop", async (t) => {
  const directory = path.resolve(__dirname, "..", "_build", "site");
  const fixture = JSON.parse(
    fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "calibration-angle.json"),
      "utf8",
    ),
  );
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    const target = path.resolve(
      directory,
      url.pathname === "/" ? "index.html" : url.pathname.slice(1),
    );
    if (
      !target.startsWith(directory + path.sep) ||
      !fs.existsSync(target) ||
      !fs.statSync(target).isFile()
    ) {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, {
      "Content-Type":
        {
          ".html": "text/html; charset=utf-8",
          ".mjs": "text/javascript; charset=utf-8",
          ".css": "text/css; charset=utf-8",
          ".json": "application/json",
          ".ndjson": "application/x-ndjson",
        }[path.extname(target)] || "application/octet-stream",
    });
    fs.createReadStream(target).pipe(response);
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
        channel: process.env.MOONGROUND_BROWSER_CHANNEL || "bundled-chromium",
      }),
    );
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    let releaseExample, requestedExample;
    const exampleGate = new Promise((resolve) => {
      releaseExample = resolve;
    });
    const exampleRequested = new Promise((resolve) => {
      requestedExample = resolve;
    });
    await page.route("**/calibration-angle.json", async (route) => {
      requestedExample();
      await exampleGate;
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
    await page.locator("#calibration-section").evaluate((element) => {
      element.open = true;
    });
    const section = page.locator("#calibration-sensitivity-section");
    await section.evaluate((element) => {
      element.open = true;
    });
    const input = page.locator("#calibration-sensitivity-input"),
      mode = page.locator("#calibration-sensitivity-mode");
    const compute = page.locator("#calibration-sensitivity-compute"),
      download = page.locator("#download-calibration-sensitivity");
    const drafts = {},
      results = {};
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
      const selected = await mode.inputValue();
      const event = page.waitForEvent("download");
      await download.click();
      const file = await event;
      assert.equal(
        file.suggestedFilename(),
        `moonground-calibration-${selected === "position" ? "sensitivity" : selected}.json`,
      );
      return JSON.parse(fs.readFileSync(await file.path(), "utf8"));
    }
    async function pause() {
      await page.evaluate(() => {
        delete window.releaseAngle;
        const original = window.setTimeout;
        window.setTimeout = (callback, delay, ...args) => {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseAngle = () => callback(...args);
            return 0;
          }
          return original(callback, delay, ...args);
        };
      });
      await compute.click();
      await page.waitForFunction(
        () => typeof window.releaseAngle === "function",
      );
    }
    drafts.position = await input.inputValue();
    await run(2);
    results.position = await exported();
    await mode.selectOption("distance");
    await page.waitForFunction(() =>
      document
        .querySelector("#calibration-sensitivity-input")
        .value.includes('"common-scale"'),
    );
    drafts.distance = await input.inputValue();
    await run(2);
    results.distance = await exported();
    await mode.selectOption("angle");
    await exampleRequested;
    const draft = structuredClone(fixture);
    draft.comparisons[0].probe_id = "道路夹角🌙 <img src=x onerror=alert(1)>";
    drafts.angle = JSON.stringify(draft);
    await input.fill(drafts.angle);
    releaseExample();
    await page.waitForTimeout(60);
    assert.equal(
      await input.inputValue(),
      drafts.angle,
      "late example replaced edited angle draft",
    );
    await run(3);
    results.angle = await exported();
    const pair = results.angle.comparisons[0];
    assert.equal(pair.first.std_rad, 0.125);
    assert.equal(pair.cross_contribution_rad2, 0.015625);
    assert.equal(pair.std_rad, 0);
    assert.equal(results.angle.comparisons[1].angle_rad, Math.PI);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows img").count(),
      0,
    );
    assert.match(
      await page.locator("#calibration-sensitivity-scope").innerText(),
      /地面.*第二段.*圆周/,
    );
    for (const selected of ["position", "distance", "angle"]) {
      await mode.selectOption(selected);
      assert.equal(await input.inputValue(), drafts[selected]);
      assert.deepEqual(await exported(), results[selected]);
    }
    await page
      .locator("#source")
      .fill("independent ordinary measurement draft");
    assert.deepEqual(await exported(), results.angle);
    await pause();
    await mode.selectOption("distance");
    await page.evaluate(() => window.releaseAngle());
    await page.waitForTimeout(60);
    assert.deepEqual(await exported(), results.distance);
    await mode.selectOption("angle");
    assert.deepEqual(await exported(), results.angle);
    await pause();
    await input.fill(JSON.stringify(fixture));
    await page.evaluate(() => window.releaseAngle());
    await page.waitForTimeout(60);
    assert.equal(await download.isDisabled(), true);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows tr").count(),
      0,
    );
    await run(3);
    const original = await exported();
    await page.evaluate(() => {
      window.angleParse = JSON.parse;
      JSON.parse = (text, ...args) => {
        if (String(text).includes('"kind":"calibration_angle_comparison"'))
          throw new Error("simulated angle response failure");
        return window.angleParse(text, ...args);
      };
    });
    await compute.click();
    await page.waitForFunction(() =>
      document
        .querySelector("#calibration-sensitivity-message")
        .textContent.includes("simulated angle response failure"),
    );
    await page.evaluate(() => {
      JSON.parse = window.angleParse;
    });
    assert.deepEqual(await exported(), original);
    await page.unroute("**/calibration-angle.json");
    let releaseLate, requestedLate;
    const lateGate = new Promise((resolve) => {
      releaseLate = resolve;
    });
    const lateRequest = new Promise((resolve) => {
      requestedLate = resolve;
    });
    await page.route("**/calibration-angle.json", async (route) => {
      requestedLate();
      await lateGate;
      await route.fulfill({
        contentType: "application/json",
        body: JSON.stringify(fixture),
      });
    });
    await page.locator("#calibration-sensitivity-example").click();
    await lateRequest;
    await mode.selectOption("position");
    releaseLate();
    await page.waitForTimeout(60);
    assert.equal(await input.inputValue(), drafts.position);
    assert.deepEqual(await exported(), results.position);
    await mode.selectOption("angle");
    assert.equal(await download.isDisabled(), true);
    await run(3);
    const invalid = structuredClone(fixture);
    invalid.comparisons[2].second_segment = [
      [0, 0],
      [0, 0],
    ];
    await input.fill(JSON.stringify(invalid));
    await compute.click();
    await page.waitForFunction(() =>
      document
        .querySelector("#calibration-sensitivity-message")
        .classList.contains("error"),
    );
    assert.equal(await download.isDisabled(), true);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows tr").count(),
      0,
    );
    const maximum = structuredClone(fixture);
    maximum.modes = Array.from({ length: 32 }, () => fixture.modes[0]);
    maximum.comparisons = Array.from({ length: 256 }, (_, i) => ({
      ...fixture.comparisons[0],
      probe_id: `angle-${i}`,
    }));
    await input.fill(JSON.stringify(maximum));
    await run(256);
    assert.equal(
      (await exported()).comparisons[255].mode_responses_rad.length,
      32,
    );
    await section.evaluate((element) => {
      element.open = false;
    });
    await page.waitForFunction(
      () =>
        document.querySelectorAll("#calibration-sensitivity-rows tr").length ===
        0,
    );
    assert.equal(await download.isDisabled(), false);
    await section.evaluate((element) => {
      element.open = true;
    });
    await page.waitForFunction(
      () =>
        document.querySelectorAll("#calibration-sensitivity-rows tr").length ===
        256,
    );
    await input.fill(JSON.stringify(fixture, null, 2));
    await run(3);
    await page
      .locator("#calibration-sensitivity-rows tr")
      .first()
      .locator("summary")
      .click();
    assert.match(
      await page
        .locator("#calibration-sensitivity-rows tr")
        .first()
        .innerText(),
      /第一段方向.*第二段方向.*交叉贡献.*rad²/s,
    );
    for (const [name, width, height] of [
      ["mobile", 390, 844],
      ["desktop", 1440, 1000],
    ]) {
      await page.setViewportSize({ width, height });
      await input.evaluate((element) => {
        element.scrollTop = 0;
      });
      await section.scrollIntoViewIfNeeded();
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= window.innerWidth,
        ),
        true,
      );
      await section.screenshot({
        path: path.join(directory, `calibration-angle-${name}-preview.png`),
      });
    }
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
