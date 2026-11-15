const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

test("shared length comparison modes, isolated drafts, cancellation and mobile layout", async (t) => {
  const directory = path.resolve(__dirname, "..", "_build", "site");
  const fixture = JSON.parse(
    fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "calibration-distance.json"),
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
    const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const target = path.resolve(directory, name);
    if (
      !target.startsWith(directory + path.sep) ||
      !fs.existsSync(target) ||
      !fs.statSync(target).isFile()
    ) {
      response.writeHead(404);
      response.end();
      return;
    }
    const types = {
      ".html": "text/html; charset=utf-8",
      ".mjs": "text/javascript; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".json": "application/json",
      ".ndjson": "application/x-ndjson",
    };
    response.writeHead(200, {
      "Content-Type": types[path.extname(target)] || "application/octet-stream",
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
    let release, requested;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const request = new Promise((resolve) => {
      requested = resolve;
    });
    await page.route("**/calibration-distance.json", async (route) => {
      requested();
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
    await page.locator("#calibration-section").evaluate((element) => {
      element.open = true;
    });
    await page
      .locator("#calibration-sensitivity-section")
      .evaluate((element) => {
        element.open = true;
      });
    const positionDraft = await page
      .locator("#calibration-sensitivity-input")
      .inputValue();
    await page
      .locator("#calibration-sensitivity-mode")
      .selectOption("distance");
    await request;
    const input = page.locator("#calibration-sensitivity-input"),
      compute = page.locator("#calibration-sensitivity-compute");
    const download = page.locator("#download-calibration-sensitivity"),
      message = page.locator("#calibration-sensitivity-message");
    const mode = page.locator("#calibration-sensitivity-mode");
    const draft = structuredClone(fixture);
    draft.comparisons[0].probe_id = "长度比较🌙 <img src=x onerror=alert(1)>";
    await input.fill(JSON.stringify(draft));
    release();
    await page.waitForTimeout(60);
    assert.deepEqual(
      JSON.parse(await input.inputValue()),
      draft,
      "late example replaced draft",
    );
    async function run(count) {
      await compute.click();
      await page.waitForFunction(
        () =>
          !document.querySelector("#calibration-sensitivity-compute")
            .disabled &&
          !document.querySelector("#download-calibration-sensitivity").disabled,
      );
      await page.waitForFunction(
        (n) =>
          document.querySelectorAll("#calibration-sensitivity-rows tr")
            .length === n,
        count,
      );
    }
    async function exportResult() {
      const selected = await mode.inputValue();
      const waiting = page.waitForEvent("download");
      await download.click();
      const file = await waiting;
      assert.equal(
        file.suggestedFilename(),
        selected === "distance"
          ? "moonground-calibration-distance.json"
          : "moonground-calibration-sensitivity.json",
      );
      return JSON.parse(fs.readFileSync(await file.path(), "utf8"));
    }
    async function pauseComputation() {
      await page.evaluate(() => {
        delete window.releaseDistance;
        const original = window.setTimeout;
        window.setTimeout = (callback, delay, ...args) => {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseDistance = () => callback(...args);
            return 0;
          }
          return original(callback, delay, ...args);
        };
      });
      await compute.click();
      await page.waitForFunction(
        () => typeof window.releaseDistance === "function",
      );
    }
    await run(2);
    const first = await exportResult();
    assert.equal(first.comparisons[0].probe_id, draft.comparisons[0].probe_id);
    assert.equal(first.comparisons[0].ratio, 0.5);
    assert.equal(first.comparisons[0].ratio_std, 0);
    assert.equal(first.comparisons[0].difference_std_m, 0.625);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows img").count(),
      0,
    );
    await page.locator("#source").fill("independent measurement draft");
    assert.deepEqual(await exportResult(), first);
    // Point and distance modes retain their own drafts and successful results.
    await mode.selectOption("position");
    assert.equal(await input.inputValue(), positionDraft);
    assert.equal(await download.isDisabled(), true);
    await run(2);
    const positionResult = await exportResult();
    await input.fill("{}");
    await mode.selectOption("distance");
    assert.deepEqual(await exportResult(), first);
    await mode.selectOption("position");
    assert.equal(await input.inputValue(), "{}");
    assert.equal(await download.isDisabled(), true);
    await input.fill(positionDraft);
    await run(2);
    assert.deepEqual(await exportResult(), positionResult);
    await mode.selectOption("distance");
    // A cancelled old mode continuation cannot write the other mode's result.
    await pauseComputation();
    await mode.selectOption("position");
    await page.evaluate(() => window.releaseDistance());
    await page.waitForTimeout(60);
    assert.deepEqual(await exportResult(), positionResult);
    await mode.selectOption("distance");
    assert.deepEqual(await exportResult(), first);
    await pauseComputation();
    await input.fill(JSON.stringify(fixture));
    await page.evaluate(() => window.releaseDistance());
    await page.waitForTimeout(60);
    assert.equal(await download.isDisabled(), true);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows tr").count(),
      0,
    );
    await run(2);
    const example = await exportResult();
    assert.equal(example.comparisons[0].difference_contribution_m2, 0.390625);
    assert.equal(example.comparisons[0].ratio_contribution, 0);
    // Same-input response failures preserve the completed, bound download.
    await page.evaluate(() => {
      window.distanceParse = JSON.parse;
      JSON.parse = (text, ...args) => {
        if (String(text).includes('"kind":"calibration_distance_comparison"'))
          throw new Error("simulated distance response failure");
        return window.distanceParse(text, ...args);
      };
    });
    await compute.click();
    await page.waitForFunction(() =>
      document
        .querySelector("#calibration-sensitivity-message")
        .textContent.includes("simulated distance response failure"),
    );
    await page.evaluate(() => {
      JSON.parse = window.distanceParse;
    });
    assert.deepEqual(await exportResult(), example);
    // A delayed example from the old mode must not replace the new mode draft.
    await page.unroute("**/calibration-distance.json");
    let lateRelease, lateRequested;
    const lateGate = new Promise((resolve) => {
      lateRelease = resolve;
    });
    const lateRequest = new Promise((resolve) => {
      lateRequested = resolve;
    });
    await page.route("**/calibration-distance.json", async (route) => {
      lateRequested();
      await lateGate;
      await route.fulfill({
        contentType: "application/json",
        body: JSON.stringify(fixture),
      });
    });
    await page.locator("#calibration-sensitivity-example").click();
    await lateRequest;
    await mode.selectOption("position");
    lateRelease();
    await page.waitForTimeout(60);
    assert.equal(await input.inputValue(), positionDraft);
    assert.deepEqual(await exportResult(), positionResult);
    await mode.selectOption("distance");
    assert.equal(await download.isDisabled(), true);
    await run(2);
    const invalid = structuredClone(fixture);
    invalid.comparisons[1].second_segment = [
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
    maximum.modes = Array.from({ length: 32 }, () => fixture.modes[1]);
    maximum.comparisons = Array.from({ length: 256 }, (_, i) => ({
      ...fixture.comparisons[0],
      probe_id: `pair-${i}`,
    }));
    await input.fill(JSON.stringify(maximum));
    await run(256);
    assert.equal(
      (await exportResult()).comparisons[255].ratio_mode_responses.length,
      32,
    );
    await page
      .locator("#calibration-sensitivity-section")
      .evaluate((element) => {
        element.open = false;
      });
    await page.waitForFunction(
      () =>
        document.querySelectorAll("#calibration-sensitivity-rows tr").length ===
        0,
    );
    assert.equal(await download.isDisabled(), false);
    await page
      .locator("#calibration-sensitivity-section")
      .evaluate((element) => {
        element.open = true;
      });
    await page.waitForFunction(
      () =>
        document.querySelectorAll("#calibration-sensitivity-rows tr").length ===
        256,
    );
    await input.fill(JSON.stringify(fixture, null, 2));
    await run(2);
    await input.evaluate((element) => {
      element.scrollTop = 0;
    });
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
      /第一段.*第二段.*交叉贡献/s,
    );
    for (const [width, height, label] of [
      [390, 844, "mobile"],
      [1440, 1050, "desktop"],
    ]) {
      await page.setViewportSize({ width, height });
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= window.innerWidth,
        ),
        true,
      );
      await page.locator("#calibration-sensitivity-section").screenshot({
        path: path.join(directory, `calibration-distance-${label}-preview.png`),
      });
    }
    assert.match(await message.textContent(), /2 组长度比较、2 个共享模式/);
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
