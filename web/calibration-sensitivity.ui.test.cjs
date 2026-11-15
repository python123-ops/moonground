const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

test("explicit calibration sensitivity draft, cancellation, download and mobile layout", async (t) => {
  const directory = path.resolve(__dirname, "..", "_build", "site");
  const fixture = JSON.parse(
    fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "calibration-sensitivity.json"),
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
    await page.route("**/calibration-sensitivity.json", async (route) => {
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
    await request;
    await page.locator("#calibration-section").evaluate((element) => {
      element.open = true;
    });
    await page
      .locator("#calibration-sensitivity-section")
      .evaluate((element) => {
        element.open = true;
      });
    const input = page.locator("#calibration-sensitivity-input"),
      compute = page.locator("#calibration-sensitivity-compute");
    const download = page.locator("#download-calibration-sensitivity"),
      message = page.locator("#calibration-sensitivity-message");
    const draft = structuredClone(fixture);
    draft.probes[0].probe_id = "共享误差🌙 <img src=x onerror=alert(1)>";
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
      const waiting = page.waitForEvent("download");
      await download.click();
      const file = await waiting;
      assert.equal(
        file.suggestedFilename(),
        "moonground-calibration-sensitivity.json",
      );
      return JSON.parse(fs.readFileSync(await file.path(), "utf8"));
    }
    await run(2);
    const first = await exportResult();
    assert.equal(first.probes[0].probe_id, draft.probes[0].probe_id);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows img").count(),
      0,
    );
    assert.deepEqual(first.probes[1].displacement_contribution_m2, [0, 0, 0]);
    await page.locator("#source").fill("independent measurement draft");
    assert.deepEqual(
      await exportResult(),
      first,
      "unrelated measurement cleared explicit-baseline diagnostic",
    );
    // A same-input response parsing failure preserves the completed download.
    await page.evaluate(() => {
      window.sensitivityParse = JSON.parse;
      JSON.parse = (text, ...args) => {
        if (String(text).includes('"kind":"calibration_sensitivity"'))
          throw new Error("simulated response failure");
        return window.sensitivityParse(text, ...args);
      };
    });
    await compute.click();
    await page.waitForFunction(() =>
      document
        .querySelector("#calibration-sensitivity-message")
        .textContent.includes("simulated response failure"),
    );
    await page.evaluate(() => {
      JSON.parse = window.sensitivityParse;
    });
    assert.deepEqual(await exportResult(), first);
    // Suspend the actual browser yield, then edit the input while computation
    // is pending. Releasing that old continuation must not restore old data.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = (callback, delay, ...args) => {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseSensitivity = () => callback(...args);
          return 0;
        }
        return original(callback, delay, ...args);
      };
    });
    await compute.click();
    await page.waitForFunction(
      () => typeof window.releaseSensitivity === "function",
    );
    await input.fill(JSON.stringify(fixture));
    await page.evaluate(() => window.releaseSensitivity());
    await page.waitForTimeout(60);
    assert.equal(await download.isDisabled(), true);
    assert.equal(
      await page.locator("#calibration-sensitivity-rows tr").count(),
      0,
    );
    await run(2);
    const example = await exportResult();
    assert.deepEqual(
      example.probes[0].displacement_contribution_m2,
      [0.0036, 0.0023999999999999994, 0.0015999999999999994],
    );
    const invalid = structuredClone(fixture);
    invalid.probes[1].second_pixel = [101, 0];
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
    maximum.probes = Array.from({ length: 256 }, (_, i) => ({
      ...fixture.probes[0],
      probe_id: `pair-${i}`,
    }));
    await input.fill(JSON.stringify(maximum));
    await run(256);
    assert.equal(
      (await exportResult()).probes[255].first.mode_responses_m.length,
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
      /第一点.*第二点.*交叉块/s,
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
        path: path.join(
          directory,
          `calibration-sensitivity-${label}-preview.png`,
        ),
      });
    }
    assert.match(await message.textContent(), /2 对像素点、2 个共享模式/);
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
