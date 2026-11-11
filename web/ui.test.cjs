const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

test("desktop, mobile, local import and stale-result prevention", async (t) => {
  const directory = path.resolve(__dirname, "..", "_build", "site");
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204);
      response.end();
      return;
    }
    const name = url.pathname.replace(/^\/moonground\//, "") || "index.html";
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
    const environment = {
      browser_version: browser.version(),
      channel: process.env.MOONGROUND_BROWSER_CHANNEL || "bundled-chromium",
      platform: process.platform,
    };
    t.diagnostic(JSON.stringify(environment));
    fs.writeFileSync(
      path.join(directory, "browser-environment.json"),
      JSON.stringify(environment, null, 2) + "\n",
    );
    // Keep the default calibration request pending while a user edits the
    // controls. A late example response must not replace that draft.
    const draftPage = await browser.newPage();
    let releaseCalibration;
    const calibrationGate = new Promise((resolve) => {
      releaseCalibration = resolve;
    });
    let calibrationRequested;
    const pendingCalibration = new Promise((resolve) => {
      calibrationRequested = resolve;
    });
    try {
      await draftPage.route("**/calibration.json", async (route) => {
        calibrationRequested();
        await calibrationGate;
        await route.fulfill({
          contentType: "application/json",
          body: fs.readFileSync(
            path.resolve(__dirname, "..", "examples", "calibration.json"),
            "utf8",
          ),
        });
      });
      await draftPage.goto(
        `http://127.0.0.1:${server.address().port}/moonground/`,
        { waitUntil: "domcontentloaded" },
      );
      await pendingCalibration;
      await draftPage.locator("details").evaluate((details) => {
        details.open = true;
      });
      const draft = '{"control_pixels":[[11,22]],"user_draft":"preserve"}';
      await draftPage.locator("#calibration-input").fill(draft);
      const response = draftPage.waitForResponse((value) =>
        value.url().endsWith("/calibration.json"),
      );
      releaseCalibration();
      await (await response).finished();
      await draftPage.waitForLoadState("networkidle");
      assert.equal(
        await draftPage.locator("#calibration-input").inputValue(),
        draft,
      );
    } finally {
      releaseCalibration();
      await draftPage.close();
    }
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1050 },
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/moonground/`);
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    assert.equal(await page.locator("#counter").textContent(), "1 / 10");
    assert.equal(await page.locator("#speed").textContent(), "—");
    await page.locator("#frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.equal(await page.locator("#ready").textContent(), "1");
    assert.match(await page.locator("#speed").textContent(), /m\/s/);
    await page.locator("details").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelector("#calibration-input").value.length > 0,
    );
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /拟合 6 点，核验 2 点/,
    );
    assert.equal(await page.locator("#download").isDisabled(), true);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await page.locator("details").evaluate((details) => {
      details.open = false;
    });
    await page.screenshot({
      path: path.join(directory, "desktop-preview.png"),
      fullPage: true,
    });
    await page.locator("#source").fill('{"session_id":"bad"}\n{}');
    assert.equal(await page.locator("#download").isDisabled(), true);
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").classList.contains("error"),
    );
    const fixture = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "warehouse.ndjson"),
    );
    await page.locator("#file").setInputFiles({
      name: "仓储轨迹.ndjson",
      mimeType: "application/x-ndjson",
      buffer: fixture,
    });
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    const downloaded = page.waitForEvent("download");
    await page.locator("#download").click();
    assert.equal(
      (await downloaded).suggestedFilename(),
      "moonground-results.json",
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.screenshot({
      path: path.join(directory, "mobile-preview.png"),
      fullPage: true,
    });
    await page.locator("#camera-example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 15 帧"),
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(await page.locator("#tracks").textContent(), /不确定性超限/);
    assert.equal(await page.locator("#speed").textContent(), "—");
    assert.equal(await page.locator("#tracks td").count(), 7);
    await page.locator("#frame").evaluate((input) => {
      input.value = "14";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.equal(await page.locator("#ready").textContent(), "1");
    assert.match(await page.locator("#speed").textContent(), /m\/s/);
    await page.locator("details").evaluate((details) => {
      details.open = true;
    });
    await page
      .locator("#calibration-input")
      .fill(
        fs.readFileSync(
          path.resolve(
            __dirname,
            "..",
            "examples",
            "distorted-calibration.json",
          ),
          "utf8",
        ),
      );
    await page.locator("#calibrate").click();
    assert.ok(
      await page
        .locator("#source")
        .evaluate((input) => JSON.parse(input.value.split("\n")[0]).camera),
    );
    assert.equal(await page.locator("#download").isDisabled(), true);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 15 帧"),
    );
    await page
      .locator("#calibration-input")
      .fill(
        fs.readFileSync(
          path.resolve(__dirname, "..", "examples", "calibration.json"),
          "utf8",
        ),
      );
    await page.locator("#calibrate").click();
    assert.equal(
      await page
        .locator("#source")
        .evaluate(
          (input) => "camera" in JSON.parse(input.value.split("\n")[0]),
        ),
      true,
    );
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /拟合请求需提供 camera/,
    );
    // Save the selected prefix, then restore in a fresh handle and continue.
    const activeSource = await page.locator("#source").inputValue();
    const [, ...activeFrames] = activeSource.trimEnd().split(/\r?\n/);
    const exportJson = async (selector, filename) => {
      const pending = page.waitForEvent("download");
      await page.locator(selector).click();
      const download = await pending;
      assert.equal(download.suggestedFilename(), filename);
      return JSON.parse(fs.readFileSync(await download.path(), "utf8"));
    };
    const baseline = await exportJson("#download", "moonground-results.json");
    await page.locator("#frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const checkpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    assert.equal(checkpoint.checkpoint_version, "1");
    assert.equal(
      checkpoint.motion.last_timestamp_us,
      JSON.parse(activeFrames[2]).timestamp_us,
    );
    assert.equal(checkpoint.motion.tracks[0].accepted_count, 3);
    assert.deepEqual(
      checkpoint.configuration.camera,
      JSON.parse(activeSource.split("\n")[0]).camera,
    );
    // Finish an earlier slow read after a newer failed selection. The newer
    // selection must keep the currently displayed valid source and results.
    await page.evaluate(() => {
      const original = File.prototype.text;
      window.restoreCheckpointRead = () => {
        File.prototype.text = original;
      };
      File.prototype.text = function () {
        if (this.name !== "delayed-checkpoint.json") return original.call(this);
        return new Promise((resolve, reject) => {
          window.releaseCheckpointRead = async () => {
            try {
              resolve(await original.call(this));
            } catch (error) {
              reject(error);
            }
          };
        });
      };
    });
    await page.locator("#checkpoint-file").setInputFiles({
      name: "delayed-checkpoint.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(checkpoint)),
    });
    await page.locator("#checkpoint-file").setInputFiles({
      name: "damaged.json",
      mimeType: "application/json",
      buffer: Buffer.from(
        '{"format":"moonground.session","checkpoint_version":"999"}',
      ),
    });
    await page.waitForFunction(() =>
      document.querySelector("#message").classList.contains("error"),
    );
    await page.evaluate(() => window.releaseCheckpointRead());
    await page.evaluate(() => window.restoreCheckpointRead());
    assert.equal(await page.locator("#source").inputValue(), activeSource);
    assert.equal(await page.locator("#counter").textContent(), "3 / 15");
    assert.equal(await page.locator("#download").isDisabled(), false);
    await page.locator("#checkpoint-file").setInputFiles({
      name: "saved.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(checkpoint)),
    });
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已载入检查点"),
    );
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#save-checkpoint").isDisabled(), true);
    const resumeInput = await page.locator("#source").inputValue();
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /检查点绑定原标定/,
    );
    assert.equal(await page.locator("#source").inputValue(), resumeInput);
    await page
      .locator("#source")
      .fill(resumeInput + activeFrames.slice(3).join("\n") + "\n");
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 12 帧"),
    );
    const resumed = await exportJson("#download", "moonground-results.json");
    assert.deepEqual(resumed.frames, baseline.frames.slice(3));
    const continued = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    assert.equal(continued.motion.tracks[0].accepted_count, 4);
    await page
      .locator("#source")
      .fill(
        '{"session_id":"large-coordinate","mode":"ground"}\n{"timestamp_us":"0","observations":[{"track_id":1,"point":[1e300,1e300]}]}',
      );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    assert.equal(await page.locator("#download").isDisabled(), false);
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
