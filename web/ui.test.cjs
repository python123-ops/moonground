const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

function closeMeasurement(actual, expected, label = "measurement") {
  if (typeof expected === "number") {
    assert.ok(
      Math.abs(actual - expected) <= 1e-8 * Math.max(1, Math.abs(expected)),
      `${label}: ${actual} != ${expected}`,
    );
  } else if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length, label);
    expected.forEach((value, index) =>
      closeMeasurement(actual[index], value, `${label}[${index}]`),
    );
  } else if (expected !== null && typeof expected === "object") {
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort());
    for (const [key, value] of Object.entries(expected))
      closeMeasurement(actual[key], value, `${label}.${key}`);
  } else {
    assert.equal(actual, expected, label);
  }
}

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
      ".json": "application/json; charset=utf-8",
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
    let releaseGates;
    const gatesGate = new Promise((resolve) => {
      releaseGates = resolve;
    });
    let gatesRequested;
    const pendingGates = new Promise((resolve) => {
      gatesRequested = resolve;
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
      await draftPage.route("**/gates.json", async (route) => {
        gatesRequested();
        await gatesGate;
        await route.fulfill({
          contentType: "application/json",
          body: fs.readFileSync(
            path.resolve(__dirname, "..", "examples", "gates.json"),
            "utf8",
          ),
        });
      });
      await draftPage.goto(
        `http://127.0.0.1:${server.address().port}/moonground/`,
        { waitUntil: "domcontentloaded" },
      );
      await pendingCalibration;
      await pendingGates;
      const gateDraft = '{"session_id":"user-gate-draft","gates":[]}';
      await draftPage.locator("#gate-input").fill(gateDraft);
      const gatesResponse = draftPage.waitForResponse((value) =>
        value.url().endsWith("/gates.json"),
      );
      releaseGates();
      await (await gatesResponse).finished();
      assert.equal(
        await draftPage.locator("#gate-input").inputValue(),
        gateDraft,
      );
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
      // An explicitly requested example must also yield to a later user edit.
      let releaseRobust;
      const robustGate = new Promise((resolve) => {
        releaseRobust = resolve;
      });
      let robustRequested;
      const pendingRobust = new Promise((resolve) => {
        robustRequested = resolve;
      });
      try {
        await draftPage.route("**/robust-calibration.json", async (route) => {
          robustRequested();
          await robustGate;
          await route.fulfill({
            contentType: "application/json",
            body: fs.readFileSync(
              path.resolve(
                __dirname,
                "..",
                "examples",
                "robust-calibration.json",
              ),
              "utf8",
            ),
          });
        });
        await draftPage.locator("#robust-calibration-example").click();
        await pendingRobust;
        const newerDraft = '{"control_pixels":[[33,44]],"user_draft":"newer"}';
        await draftPage.locator("#calibration-input").fill(newerDraft);
        const robustResponse = draftPage.waitForResponse((value) =>
          value.url().endsWith("/robust-calibration.json"),
        );
        releaseRobust();
        await (await robustResponse).finished();
        await draftPage.waitForLoadState("networkidle");
        assert.equal(
          await draftPage.locator("#calibration-input").inputValue(),
          newerDraft,
        );
        assert.equal(
          await draftPage.locator("#download-calibration").isDisabled(),
          true,
        );
      } finally {
        releaseRobust();
      }
    } finally {
      releaseCalibration();
      releaseGates();
      await draftPage.close();
    }
    const page = await browser.newPage({
      viewport: { width: 1440, height: 1050 },
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    let downloadsInBurst = 0;
    let downloadBurstStarted = 0;
    const exportJson = async (selector, filename) => {
      // Chromium silently drops the eleventh download within a one-second
      // burst, including trusted clicks. Pace all exports through this helper
      // so faster CI hosts exercise the same downloads without hitting it.
      if (downloadsInBurst === 10) {
        const remaining = 1050 - (performance.now() - downloadBurstStarted);
        if (remaining > 0)
          await new Promise((resolve) => setTimeout(resolve, remaining));
        downloadsInBurst = 0;
      }
      const pending = page.waitForEvent("download");
      await page.locator(selector).click();
      const download = await pending;
      if (downloadsInBurst === 0) downloadBurstStarted = performance.now();
      downloadsInBurst++;
      assert.equal(download.suggestedFilename(), filename);
      return JSON.parse(fs.readFileSync(await download.path(), "utf8"));
    };
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
    await page.waitForFunction(
      () => document.querySelector("#gate-input").value.length > 0,
    );
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#gate-message")
        .textContent.includes("已统计 10 帧、1 次过线"),
    );
    const warehouseGates = await exportJson(
      "#download-gates",
      "moonground-gate-results.json",
    );
    assert.equal(warehouseGates.frames.length, 10);
    assert.equal(warehouseGates.checkpoint.format, "moonground.gates");
    assert.deepEqual(warehouseGates.frames.at(-1).counts, [
      {
        gate_id: "aisle",
        negative_to_positive: "0",
        positive_to_negative: "1",
      },
    ]);
    await page.locator("#frame").evaluate((input) => {
      input.value = "3";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(
      await page.locator("#gate-events").textContent(),
      /正侧 → 负侧/,
    );
    assert.match(await page.locator("#gate-events").textContent(), /时间区间/);
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
    assert.equal(await page.locator("#download-gates").isDisabled(), true);
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
    await exportJson("#download", "moonground-results.json");
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
    // Compare the polluted request through strict and robust calibration, then
    // verify the displayed per-point decisions against the reusable response.
    await page.locator("details").evaluate((details) => {
      details.open = true;
    });
    const beforeRobust = await page.locator("#source").inputValue();
    const robustRequest = JSON.parse(
      fs.readFileSync(
        path.resolve(__dirname, "..", "examples", "robust-calibration.json"),
        "utf8",
      ),
    );
    await page.locator("#robust-calibration-example").click();
    await page.waitForFunction(() =>
      document.querySelector("#calibration-input").value.includes('"robust"'),
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#calibration-input").inputValue()),
      robustRequest,
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      beforeRobust,
      "loading controls replaced measurement calibration",
    );
    const strictRequest = structuredClone(robustRequest);
    delete strictRequest.robust;
    await page
      .locator("#calibration-input")
      .fill(JSON.stringify(strictRequest));
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /residual|fitting|核验|拟合失败/i,
    );
    assert.equal(await page.locator("#source").inputValue(), beforeRobust);
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#calibration-residuals li").count(), 0);
    await page.locator("#robust-calibration-example").click();
    await page.waitForFunction(() =>
      document.querySelector("#calibration-input").value.includes('"robust"'),
    );
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /保留 8 \/ 10 个控制点/,
    );
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /从 1 编号.*2、8/,
    );
    assert.equal(
      await page.locator("#calibration-diagnostics").isVisible(),
      true,
    );
    const fittedResponse = await exportJson(
      "#download-calibration",
      "moonground-calibration.json",
    );
    assert.equal(fittedResponse.report.fit_count, 8);
    assert.equal(fittedResponse.report.check_count, 3);
    assert.ok(
      fittedResponse.report.check_max_error_m <=
        robustRequest.max_check_error_m,
    );
    assert.deepEqual(fittedResponse.robust_report.outlier_indices, [1, 7]);
    assert.deepEqual(
      fittedResponse.robust_report.options,
      robustRequest.robust,
    );
    assert.deepEqual(fittedResponse.camera, robustRequest.camera);
    assert.equal(await page.locator("#calibration-residuals li").count(), 10);
    for (let index = 0; index < 10; index++) {
      const report = fittedResponse.robust_report;
      assert.equal(
        await page
          .locator("#calibration-residuals li")
          .nth(index)
          .textContent(),
        `第 ${index + 1} 控制点 · ${report.inlier_mask[index] ? "保留" : "排除"} · 误差 ${report.control_errors_m[index].toExponential(3)} m`,
      );
      assert.equal(report.inlier_mask[index], ![1, 7].includes(index));
    }
    const fittedSource = await page.locator("#source").inputValue();
    assert.deepEqual(
      JSON.parse(fittedSource.split("\n")[0]).calibration,
      fittedResponse.calibration,
    );
    assert.equal(
      fittedSource.slice(fittedSource.indexOf("\n")),
      beforeRobust.slice(beforeRobust.indexOf("\n")),
    );
    // A measurement edit does not invalidate a fit bound to unchanged controls.
    await page.locator("#source").fill(fittedSource + " ");
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      false,
    );
    assert.deepEqual(
      await exportJson("#download-calibration", "moonground-calibration.json"),
      fittedResponse,
    );
    await page.locator("#source").fill(fittedSource);
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.screenshot({
      path: path.join(directory, "robust-mobile-preview.png"),
      fullPage: true,
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.screenshot({
      path: path.join(directory, "robust-desktop-preview.png"),
      fullPage: true,
    });
    await page.setViewportSize({ width: 390, height: 844 });
    const badChecks = structuredClone(robustRequest);
    badChecks.check_world[0][0] += 5;
    await page.locator("#calibration-input").fill(JSON.stringify(badChecks));
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#calibration-residuals li").count(), 0);
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /hold.?out|check|核验/i,
    );
    assert.equal(await page.locator("#source").inputValue(), fittedSource);
    assert.equal(
      await page.locator("#calibration-diagnostics").isVisible(),
      false,
    );
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      true,
    );
    await page
      .locator("#calibration-input")
      .fill(JSON.stringify(robustRequest));
    await page.locator("#calibrate").click();
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      false,
    );
    await page
      .locator("#calibration-input")
      .fill(JSON.stringify(robustRequest) + " ");
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#calibration-residuals li").count(), 0);
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
    // Transform a raw-camera sequence containing both explicit correlated
    // covariance and the implicit two-pixel standard deviation.
    const reframeLines = activeSource.trimEnd().split(/\r?\n/).map(JSON.parse);
    delete reframeLines[1].observations[0].covariance;
    const reframeSource = reframeLines.map(JSON.stringify).join("\n") + "\n";
    await page.locator("#source").fill(reframeSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 15 帧"),
    );
    const reframeBaseline = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const reframeCheckpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    await page.locator("#scale-x").fill("0");
    assert.equal(await page.locator("#download").isDisabled(), false);
    assert.equal(await page.locator("#counter").textContent(), "3 / 15");
    await page.locator("#reframe").click();
    assert.match(await page.locator("#message").textContent(), /须大于 0/);
    assert.equal(await page.locator("#source").inputValue(), reframeSource);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      reframeBaseline,
    );
    await page.locator("#scale-x").fill("0.5");
    await page.locator("#scale-y").fill("0.75");
    await page.locator("#offset-x").fill("-40");
    await page.locator("#offset-y").fill("16");
    const oldControls = await page.locator("#calibration-input").inputValue();
    await page.locator("#reframe").click();
    assert.match(await page.locator("#message").textContent(), /已变换 15 帧/);
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#download").isDisabled(), true);
    const reframedSource = await page.locator("#source").inputValue();
    const reframedLines = reframedSource
      .trimEnd()
      .split(/\r?\n/)
      .map(JSON.parse);
    assert.deepEqual(reframedLines[1].observations[0].covariance, [1, 0, 2.25]);
    closeMeasurement(reframedLines[1].observations[0].point, [
      reframeLines[1].observations[0].point[0] * 0.5 - 40,
      reframeLines[1].observations[0].point[1] * 0.75 + 16,
    ]);
    assert.equal(reframedLines[0].camera.fx, reframeLines[0].camera.fx * 0.5);
    assert.equal(reframedLines[0].camera.fy, reframeLines[0].camera.fy * 0.75);
    assert.equal(
      await page.locator("#calibration-input").inputValue(),
      oldControls,
    );
    assert.equal(
      await page.locator("#download-calibration").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#calibration-residuals li").count(), 0);
    await page.locator("#calibrate").click();
    assert.match(
      await page.locator("#calibration-message").textContent(),
      /按新坐标编辑/,
    );
    assert.equal(await page.locator("#source").inputValue(), reframedSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 15 帧"),
    );
    closeMeasurement(
      (await exportJson("#download", "moonground-results.json")).frames,
      reframeBaseline.frames,
    );
    // A checkpoint header changes coordinates while its accepted metric state,
    // watermark, lifecycle counters and path remain byte-for-byte equivalent.
    const resumeReframeSource =
      JSON.stringify({ resume: reframeCheckpoint }) +
      "\n" +
      reframeLines.slice(4).map(JSON.stringify).join("\n") +
      "\n";
    await page.locator("#source").fill(resumeReframeSource);
    await page.locator("#reframe").click();
    assert.match(await page.locator("#message").textContent(), /已变换 12 帧/);
    const reframedResume = await page.locator("#source").inputValue();
    assert.deepEqual(
      JSON.parse(reframedResume.split("\n")[0]).resume.motion,
      reframeCheckpoint.motion,
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 12 帧"),
    );
    const reframedResumeResults = await exportJson(
      "#download",
      "moonground-results.json",
    );
    closeMeasurement(
      reframedResumeResults.frames,
      reframeBaseline.frames.slice(3),
    );
    // Finite but overflowing coordinates fail in the bridge before replacing
    // the source, valid displayed results or their download.
    await page.locator("#scale-x").fill("1e308");
    await page.locator("#reframe").click();
    assert.equal(await page.locator("#source").inputValue(), reframedResume);
    assert.equal(await page.locator("#download").isDisabled(), false);
    assert.equal(await page.locator("#message.error").count(), 1);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      reframedResumeResults,
    );
    await page.locator("#scale-x").fill("0.5");
    // A requested example that finishes after a parameter edit must yield to
    // that newer edit. It must also yield to a newer observation draft.
    for (const edit of ["parameter", "source"]) {
      let releaseExample;
      const gate = new Promise((resolve) => {
        releaseExample = resolve;
      });
      let requested;
      const pending = new Promise((resolve) => {
        requested = resolve;
      });
      await page.route("**/reframe.ndjson", async (route) => {
        requested();
        await gate;
        await route.fulfill({
          contentType: "application/x-ndjson",
          body: fs.readFileSync(
            path.resolve(__dirname, "..", "examples", "reframe.ndjson"),
            "utf8",
          ),
        });
      });
      try {
        await page.locator("#reframe-example").click();
        await pending;
        const newerSource = edit === "source" ? reframeSource : reframedResume;
        if (edit === "source") await page.locator("#source").fill(newerSource);
        else await page.locator("#offset-y").fill("17");
        const response = page.waitForResponse((value) =>
          value.url().endsWith("/reframe.ndjson"),
        );
        releaseExample();
        await (await response).finished();
        await page.waitForLoadState("networkidle");
        assert.equal(await page.locator("#source").inputValue(), newerSource);
      } finally {
        releaseExample();
        await page.unroute("**/reframe.ndjson");
      }
    }
    await page.locator("#reframe-example").click();
    const exampleFrames =
      fs
        .readFileSync(
          path.resolve(__dirname, "..", "examples", "reframe.ndjson"),
          "utf8",
        )
        .trimEnd()
        .split(/\r?\n/).length - 1;
    await page.waitForFunction(
      (count) =>
        document
          .querySelector("#message")
          .textContent.includes(`已完成 ${count} 帧`),
      exampleFrames,
    );
    assert.equal(await page.locator("#download").isDisabled(), false);
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.screenshot({
      path: path.join(directory, "reframe-mobile-preview.png"),
      fullPage: true,
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.screenshot({
      path: path.join(directory, "reframe-desktop-preview.png"),
      fullPage: true,
    });
    // Two-way crossings include initializing/uncertain accepted positions.
    // Positions inside the closed deadband retain the last outside anchor.
    const gateConfiguration = {
      session_id: "ui-gates",
      gates: [
        { gate_id: "door", start_m: [0, -2], end_m: [0, 2], deadband_m: 0.05 },
      ],
      max_gap_us: "500000",
      max_tracks: 10,
    };
    const gateObservation = (track_id, x) => ({
      track_id,
      point: [x, 0],
      covariance: [1e-6, 0, 1e-6],
    });
    const gateSource =
      [
        {
          session_id: "ui-gates",
          mode: "ground",
          motion: { q: 1e6, gate: 1e12, max_velocity_std_mps: 1e-6 },
        },
        {
          timestamp_us: "0",
          observations: [
            gateObservation(1, -1),
            gateObservation(2, 1),
            gateObservation(3, -1),
          ],
        },
        {
          timestamp_us: "100000",
          observations: [
            gateObservation(1, 1),
            gateObservation(2, -1),
            gateObservation(3, -0.02),
          ],
        },
        { timestamp_us: "200000", observations: [gateObservation(3, 0.02)] },
        { timestamp_us: "300000", observations: [gateObservation(3, 1)] },
      ]
        .map(JSON.stringify)
        .join("\n") + "\n";
    await page.locator("#source").fill(gateSource);
    assert.equal(await page.locator("#download-gates").isDisabled(), true);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 4 帧"),
    );
    const gateBase = await exportJson("#download", "moonground-results.json");
    await page.locator("#gate-input").fill(JSON.stringify(gateConfiguration));
    assert.equal(await page.locator("#download").isDisabled(), false);
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#gate-message")
        .textContent.includes("已统计 4 帧、3 次过线"),
    );
    const gateBundle = await exportJson(
      "#download-gates",
      "moonground-gate-results.json",
    );
    assert.deepEqual(
      gateBundle.frames.map((frame) => frame.crossings.length),
      [0, 2, 0, 1],
    );
    assert.deepEqual(gateBundle.frames.at(-1).counts, [
      { gate_id: "door", negative_to_positive: "1", positive_to_negative: "2" },
    ]);
    assert.equal(gateBundle.frames.at(-1).crossings[0].from_timestamp_us, "0");
    assert.equal(
      gateBundle.frames.at(-1).crossings[0].to_timestamp_us,
      "300000",
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "3";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(await page.locator("#gate-counts").textContent(), /door12/);
    assert.match(await page.locator("#gate-events").textContent(), /目标 3/);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.screenshot({
      path: path.join(directory, "gates-mobile-preview.png"),
      fullPage: true,
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.screenshot({
      path: path.join(directory, "gates-desktop-preview.png"),
      fullPage: true,
    });
    const gateMotionCheckpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    // Editing only the gates invalidates their result, while an invalid raw
    // numeric token fails in MoonBit and leaves base measurements exportable.
    const rawInvalidGate = JSON.stringify(gateConfiguration).replace(
      '"max_tracks":10',
      '"max_tracks":10.0000000000000001',
    );
    await page.locator("#gate-input").fill(rawInvalidGate);
    assert.equal(await page.locator("#download-gates").isDisabled(), true);
    assert.equal(await page.locator("#gate-counts tr").count(), 0);
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document.querySelector("#gate-message").classList.contains("error"),
    );
    assert.equal(
      await page.locator("#gate-input").inputValue(),
      rawInvalidGate,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      gateBase,
    );
    // Resume both consumers from matching checkpoints and process only the
    // later measurement frame. The cumulative counters continue exactly.
    const gateResumeSource =
      JSON.stringify({ resume: gateMotionCheckpoint }) +
      "\n" +
      JSON.stringify({
        timestamp_us: "400000",
        observations: [gateObservation(3, -1)],
      }) +
      "\n";
    await page.locator("#source").fill(gateResumeSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    await page
      .locator("#gate-input")
      .fill(JSON.stringify({ resume: gateBundle.checkpoint }));
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#gate-message")
        .textContent.includes("已统计 1 帧、1 次过线"),
    );
    const resumedGates = await exportJson(
      "#download-gates",
      "moonground-gate-results.json",
    );
    assert.deepEqual(resumedGates.frames[0].counts, [
      { gate_id: "door", negative_to_positive: "2", positive_to_negative: "2" },
    ]);
    assert.match(
      await page.locator("#gate-events").textContent(),
      /负侧 → 正侧/,
    );
    // Joint replay agrees with both existing consumers. Its selected-frame
    // checkpoint must not silently use the batch-final counting state.
    await page.locator("#source").fill(gateSource);
    await page.locator("#gate-input").fill(JSON.stringify(gateConfiguration));
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已测量并统计 4 帧"),
    );
    const analysis = await exportJson(
      "#download-analysis",
      "moonground-analysis-results.json",
    );
    assert.deepEqual(
      analysis.frames.map((f) => f.measurement),
      gateBase.frames,
    );
    assert.deepEqual(
      analysis.frames.map((f) => f.counting),
      gateBundle.frames,
    );
    assert.deepEqual(analysis.checkpoint.counting, gateBundle.checkpoint);
    assert.equal(analysis.checkpoint.format, "moonground.analysis");
    assert.equal(
      analysis.checkpoint.measurement.motion.last_timestamp_us,
      "300000",
    );
    assert.equal(
      analysis.checkpoint.counting.state.last_timestamp_us,
      "300000",
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "1";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const jointCheckpoint = await exportJson(
      "#save-analysis-checkpoint",
      "moonground-analysis-checkpoint.json",
    );
    assert.equal(
      jointCheckpoint.measurement.motion.last_timestamp_us,
      "100000",
    );
    assert.equal(jointCheckpoint.counting.state.last_timestamp_us, "100000");
    assert.equal(
      jointCheckpoint.measurement.motion.tracks[0].accepted_count,
      2,
    );
    assert.deepEqual(
      jointCheckpoint.counting.state.counts,
      gateBundle.frames[1].counts,
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "0";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const earlierJointCheckpoint = await exportJson(
      "#save-analysis-checkpoint",
      "moonground-analysis-checkpoint.json",
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "1";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.screenshot({
      path: path.join(directory, "analysis-mobile-preview.png"),
      fullPage: true,
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.screenshot({
      path: path.join(directory, "analysis-desktop-preview.png"),
      fullPage: true,
    });
    // Complete validation precedes either editor replacement, including a
    // mismatch that is individually valid as two independent checkpoints.
    const originalAnalysisSource = await page.locator("#source").inputValue();
    const originalAnalysisGates = await page
      .locator("#gate-input")
      .inputValue();
    for (const bad of [
      { ...jointCheckpoint, checkpoint_version: "999" },
      {
        ...jointCheckpoint,
        counting: {
          ...jointCheckpoint.counting,
          state: { ...jointCheckpoint.counting.state, last_timestamp_us: "0" },
        },
      },
    ]) {
      await page.locator("#analysis-checkpoint-file").setInputFiles({
        name: "invalid-analysis.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(bad)),
      });
      await page.waitForFunction(() =>
        document.querySelector("#analysis-message").classList.contains("error"),
      );
      assert.equal(
        await page.locator("#source").inputValue(),
        originalAnalysisSource,
      );
      assert.equal(
        await page.locator("#gate-input").inputValue(),
        originalAnalysisGates,
      );
      assert.deepEqual(
        await exportJson(
          "#download-analysis",
          "moonground-analysis-results.json",
        ),
        analysis,
      );
      assert.deepEqual(
        (await exportJson("#download", "moonground-results.json")).frames,
        gateBase.frames,
      );
    }
    await page.locator("#analysis-checkpoint-file").setInputFiles({
      name: "analysis.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(jointCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已载入完整分析检查点"),
    );
    assert.equal(await page.locator("#download-analysis").isDisabled(), true);
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    const laterGateFrames =
      gateSource.trimEnd().split(/\r?\n/).slice(3).join("\n") + "\n";
    await page
      .locator("#source")
      .fill((await page.locator("#source").inputValue()) + laterGateFrames);
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已测量并统计 2 帧"),
    );
    const resumedAnalysis = await exportJson(
      "#download-analysis",
      "moonground-analysis-results.json",
    );
    assert.deepEqual(resumedAnalysis.frames, analysis.frames.slice(2));
    assert.deepEqual(resumedAnalysis.checkpoint, analysis.checkpoint);
    // Independent consumers can run from different initial watermarks. The
    // joint entry rejects that pairing and preserves both displayed reports.
    await page
      .locator("#gate-input")
      .fill(JSON.stringify({ resume: earlierJointCheckpoint.counting }));
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#gate-message")
        .textContent.includes("已统计 2 帧"),
    );
    const independentBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const independentGates = await exportJson(
      "#download-gates",
      "moonground-gate-results.json",
    );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#analysis-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      independentBase,
    );
    assert.deepEqual(
      await exportJson("#download-gates", "moonground-gate-results.json"),
      independentGates,
    );
    // Both configuration and frame tokens remain raw until MoonBit sees them.
    const resumedBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const fractionalGate = JSON.stringify(gateConfiguration).replace(
      '"max_tracks":10',
      '"max_tracks":10.0000000000000001',
    );
    await page.locator("#gate-input").fill(fractionalGate);
    assert.equal(await page.locator("#download-analysis").isDisabled(), true);
    assert.equal(await page.locator("#download").isDisabled(), false);
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#analysis-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      resumedBase,
    );
    await page
      .locator("#source")
      .fill(
        gateSource.replace('"track_id":1', '"track_id":1.0000000000000001'),
      );
    await page.locator("#gate-input").fill(JSON.stringify(gateConfiguration));
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#analysis-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#download-analysis").isDisabled(), true);
    // Counter overflow fails the joint operation without replacing an already
    // successful measurement-only replay of exactly the same source.
    const overflowing = structuredClone(jointCheckpoint);
    overflowing.counting.state.counts[0].positive_to_negative =
      "9223372036854775807";
    const overflowSource =
      JSON.stringify({ resume: overflowing.measurement }) +
      "\n" +
      laterGateFrames;
    await page.locator("#source").fill(overflowSource);
    await page
      .locator("#gate-input")
      .fill(JSON.stringify({ resume: overflowing.counting }));
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 2 帧"),
    );
    const overflowBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#analysis-message").classList.contains("error"),
    );
    assert.match(
      await page.locator("#analysis-message").textContent(),
      /counter exhausted/,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      overflowBase,
    );
    assert.equal(await page.locator("#download-analysis").isDisabled(), true);
    const extremeSource =
      '{"session_id":"geometry-failure","mode":"ground"}\n{"timestamp_us":"0","observations":[{"track_id":1,"point":[-1e308,0],"covariance":[1,0,1]}]}\n';
    await page.locator("#source").fill(extremeSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    const extremeBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#gate-input").fill(
      JSON.stringify({
        session_id: "geometry-failure",
        gates: [
          {
            gate_id: "far",
            start_m: [1e308, 0],
            end_m: [1e308, 1],
            deadband_m: 0,
          },
        ],
      }),
    );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#analysis-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      extremeBase,
    );
    // Preparation yields to either editor, cancelling the old pending result.
    for (const edit of ["source", "gate"]) {
      await page.locator("#source").fill(gateSource);
      await page.locator("#gate-input").fill(JSON.stringify(gateConfiguration));
      await page.locator("#analyze").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#message")
          .textContent.includes("已测量并统计 4 帧"),
      );
      await page.evaluate(() => {
        const original = window.setTimeout;
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseAnalysisPreparation = () => callback(...args);
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
      await page.locator("#analyze").click();
      await page.waitForFunction(
        () => typeof window.releaseAnalysisPreparation === "function",
      );
      if (edit === "source")
        await page.locator("#source").fill(gateSource + " ");
      else
        await page
          .locator("#gate-input")
          .fill(JSON.stringify(gateConfiguration, null, 2));
      await page.evaluate(() => {
        window.releaseAnalysisPreparation();
        delete window.releaseAnalysisPreparation;
      });
      await page.waitForFunction(
        () => !document.querySelector("#analyze").disabled,
      );
      assert.equal(await page.locator("#download-analysis").isDisabled(), true);
      assert.equal(
        await page.locator("#save-analysis-checkpoint").isDisabled(),
        true,
      );
      assert.equal(
        await page.locator("#download").isDisabled(),
        edit === "source",
      );
    }
    await page.locator("#source").fill(activeSource);
    await page.locator("#gate-input").fill(
      JSON.stringify({
        ...gateConfiguration,
        session_id: JSON.parse(activeSource.split("\n")[0]).session_id,
      }),
    );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已测量并统计 15 帧"),
    );
    const pixelAnalysis = await exportJson(
      "#download-analysis",
      "moonground-analysis-results.json",
    );
    assert.deepEqual(
      pixelAnalysis.frames.map((f) => f.measurement),
      baseline.frames,
    );
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
    // Fixed-landmark checks have their own source, timeline and persistence.
    // They must not replace or invalidate the motion/gate replay above.
    const motionBeforeHealth = await page.locator("#source").inputValue();
    const gatesBeforeHealth = await page.locator("#gate-input").inputValue();
    const motionCounterBeforeHealth = await page
      .locator("#counter")
      .textContent();
    const motionResultBeforeHealth = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const healthSource = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "health.ndjson"),
      "utf8",
    );
    const healthLines = healthSource.trimEnd().split(/\r?\n/);
    await page.locator("#health-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#health-message")
        .textContent.includes("已检查 13 帧"),
    );
    const health = await exportJson(
      "#download-health",
      "moonground-health-results.json",
    );
    assert.equal(health.checkpoint.format, "moonground.health");
    assert.deepEqual(
      health.frames.map((f) => f.status),
      [
        "pending",
        "pending",
        "healthy",
        "pending",
        "pending",
        "drift",
        "insufficient",
        "pending",
        "pending",
        "healthy",
        "pending",
        "pending",
        "healthy",
      ],
    );
    assert.deepEqual(
      health.frames.map((f) => f.usable_count),
      [3, 3, 3, 3, 3, 3, 1, 3, 3, 3, 3, 3, 3],
    );
    assert.ok(health.frames[2].rms_error_m < 1e-7);
    assert.ok(health.frames[5].rms_error_m > 0.29);
    assert.equal(
      health.frames[5].scope,
      "observed_fixed_landmarks_under_fixed_calibration",
    );
    assert.equal(health.frames[12].streak_since_us, "1800000");
    const selectHealthFrame = async (index) =>
      page.locator("#health-frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await selectHealthFrame(5);
    assert.match(
      await page.locator("#health-status").textContent(),
      /持续残差超限/,
    );
    assert.match(
      await page.locator("#health-evidence").textContent(),
      /400000/,
    );
    assert.equal(await page.locator("#health-residuals tr").count(), 3);
    assert.match(await page.locator("#health-span").textContent(), /300000/);
    // The checkpoint download is explicitly batch-final, independent of the
    // selected report used to inspect the residual table.
    const healthCheckpoint = await exportJson(
      "#save-health-checkpoint",
      "moonground-health-checkpoint.json",
    );
    assert.equal(healthCheckpoint.state.last_timestamp_us, "2200000");
    await selectHealthFrame(6);
    assert.match(
      await page.locator("#health-status").textContent(),
      /地标不足/,
    );
    assert.equal(await page.locator("#health-residuals tr").count(), 3);
    assert.match(await page.locator("#health-usable").textContent(), /1 \/ 3/);
    await selectHealthFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator('section[aria-labelledby="health-heading"]').screenshot({
      path: path.join(directory, "health-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator('section[aria-labelledby="health-heading"]').screenshot({
      path: path.join(directory, "health-desktop-preview.png"),
    });
    for (const invalid of [
      { ...healthCheckpoint, checkpoint_version: "999" },
      {
        ...healthCheckpoint,
        state: { ...healthCheckpoint.state, last_timestamp_us: "0" },
      },
    ]) {
      await page.locator("#health-checkpoint-file").setInputFiles({
        name: "invalid-health.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(invalid)),
      });
      await page.waitForFunction(() =>
        document.querySelector("#health-message").classList.contains("error"),
      );
      assert.equal(
        await page.locator("#health-input").inputValue(),
        healthSource,
      );
      assert.deepEqual(
        await exportJson("#download-health", "moonground-health-results.json"),
        health,
      );
    }
    // A malformed imported stream fails before replacing the valid input and
    // leaves its current results available for download.
    await page.locator("#health-file").setInputFiles({
      name: "bad-health.ndjson",
      mimeType: "application/x-ndjson",
      buffer: Buffer.from(
        healthSource +
          '{"timestamp_us":"2300000","observations":[{"landmark_id":"unknown","point":[0,0]}]}\n',
      ),
    });
    await page.waitForFunction(() =>
      document.querySelector("#health-message").classList.contains("error"),
    );
    assert.equal(
      await page.locator("#health-input").inputValue(),
      healthSource,
    );
    assert.deepEqual(
      await exportJson("#download-health", "moonground-health-results.json"),
      health,
    );
    const nextHealthFrame = {
      ...JSON.parse(healthLines[1]),
      timestamp_us: "2350000",
    };
    await page
      .locator("#health-input")
      .fill(healthSource + JSON.stringify(nextHealthFrame) + "\n");
    assert.equal(await page.locator("#download-health").isDisabled(), true);
    assert.equal(await page.locator("#health-counter").textContent(), "0 / 0");
    await page.locator("#run-health").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#health-message")
        .textContent.includes("已检查 14 帧"),
    );
    const continuedHealth = await exportJson(
      "#download-health",
      "moonground-health-results.json",
    );
    await page.locator("#health-checkpoint-file").setInputFiles({
      name: "health.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(healthCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#health-message")
        .textContent.includes("已载入地标检查点"),
    );
    assert.equal(await page.locator("#download-health").isDisabled(), true);
    await page
      .locator("#health-input")
      .fill(
        (await page.locator("#health-input").inputValue()) +
          JSON.stringify(nextHealthFrame) +
          "\n",
      );
    await page.locator("#run-health").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#health-message")
        .textContent.includes("已检查 1 帧"),
    );
    const resumedHealth = await exportJson(
      "#download-health",
      "moonground-health-results.json",
    );
    assert.deepEqual(resumedHealth.frames[0], continuedHealth.frames.at(-1));
    assert.deepEqual(resumedHealth.checkpoint, continuedHealth.checkpoint);
    // Quality rejection keeps projection diagnostics while contributing no
    // residual to the usable subset; all configured landmarks remain listed.
    const qualityFrame = JSON.parse(healthLines[1]);
    qualityFrame.observations[1].covariance = [1e6, 0, 1e6];
    await page
      .locator("#health-input")
      .fill(healthLines[0] + "\n" + JSON.stringify(qualityFrame) + "\n");
    await page.locator("#run-health").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#health-message")
        .textContent.includes("已检查 1 帧"),
    );
    const qualityHealth = await exportJson(
      "#download-health",
      "moonground-health-results.json",
    );
    const qualityLandmark = qualityHealth.frames[0].landmarks[1];
    assert.equal(qualityHealth.frames[0].usable_count, 2);
    assert.equal(qualityHealth.frames[0].status, "insufficient");
    assert.equal(qualityLandmark.residual_m, null);
    assert.equal(qualityLandmark.error_m, null);
    assert.ok(qualityLandmark.projected_position_m !== null);
    assert.ok(qualityLandmark.projected_covariance !== null);
    assert.ok(qualityLandmark.position_std_m > 0.1);
    assert.ok(qualityLandmark.rejection_reason);
    await page.evaluate(() => {
      const original = File.prototype.text;
      window.restoreHealthRead = () => {
        File.prototype.text = original;
      };
      File.prototype.text = function () {
        if (this.name !== "delayed-health.json") return original.call(this);
        return new Promise((resolve, reject) => {
          window.releaseHealthRead = async () => {
            try {
              resolve(await original.call(this));
            } catch (error) {
              reject(error);
            }
          };
        });
      };
    });
    await page.locator("#health-checkpoint-file").setInputFiles({
      name: "delayed-health.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(healthCheckpoint)),
    });
    await page.locator("#health-input").fill(healthSource);
    await page.evaluate(() => {
      window.releaseHealthRead();
      window.restoreHealthRead();
    });
    assert.equal(
      await page.locator("#health-input").inputValue(),
      healthSource,
    );
    const rawHealth = healthSource.replace(
      '"min_observations":3',
      '"min_observations":3.0000000000000001',
    );
    await page.locator("#health-input").fill(rawHealth);
    await page.locator("#run-health").click();
    await page.waitForFunction(() =>
      document.querySelector("#health-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#health-input").inputValue(), rawHealth);
    assert.equal(await page.locator("#download-health").isDisabled(), true);
    // A late example read and a pending calculation both yield to a newer
    // health draft without touching either main-pipeline editor.
    let releaseHealth;
    const healthGate = new Promise((resolve) => {
      releaseHealth = resolve;
    });
    let healthRequested;
    const pendingHealth = new Promise((resolve) => {
      healthRequested = resolve;
    });
    await page.route("**/health.ndjson", async (route) => {
      healthRequested();
      await healthGate;
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: healthSource,
      });
    });
    try {
      await page.locator("#health-example").click();
      await pendingHealth;
      const draft = healthLines[0] + "\n";
      await page.locator("#health-input").fill(draft);
      const response = page.waitForResponse((value) =>
        value.url().endsWith("/health.ndjson"),
      );
      releaseHealth();
      await (await response).finished();
      await page.waitForLoadState("networkidle");
      assert.equal(await page.locator("#health-input").inputValue(), draft);
    } finally {
      releaseHealth();
      await page.unroute("**/health.ndjson");
    }
    await page.locator("#health-input").fill(healthSource);
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseHealthPreparation = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#run-health").click();
    await page.waitForFunction(
      () => typeof window.releaseHealthPreparation === "function",
    );
    await page.locator("#health-input").fill(healthLines[0] + "\n");
    await page.evaluate(() => {
      window.releaseHealthPreparation();
      delete window.releaseHealthPreparation;
    });
    await page.waitForFunction(
      () => !document.querySelector("#run-health").disabled,
    );
    assert.equal(await page.locator("#download-health").isDisabled(), true);
    assert.equal(await page.locator("#health-counter").textContent(), "0 / 0");
    // A newer valid file or example can finish reading while an older run is
    // still preparing. It must supersede that run instead of being dropped.
    for (const replacement of ["file", "example"]) {
      await page
        .locator("#health-input")
        .fill(healthSource.replace("warehouse-landmarks", "older-monitor"));
      await page.evaluate(() => {
        const original = window.setTimeout;
        window.healthPreparationQueue = [];
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.healthPreparationQueue.push(() => callback(...args));
            if (window.healthPreparationQueue.length === 2)
              window.setTimeout = original;
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
      await page.locator("#run-health").click();
      await page.waitForFunction(
        () => window.healthPreparationQueue.length === 1,
      );
      const replacementSource =
        replacement === "file"
          ? healthSource.replace("warehouse-landmarks", "replacement-monitor")
          : healthSource;
      if (replacement === "file") {
        await page.locator("#health-file").setInputFiles({
          name: "replacement-health.ndjson",
          mimeType: "application/x-ndjson",
          buffer: Buffer.from(replacementSource),
        });
      } else await page.locator("#health-example").click();
      await page.waitForFunction(
        () => window.healthPreparationQueue.length === 2,
      );
      await page.evaluate(() => window.healthPreparationQueue[0]());
      assert.equal(await page.locator("#run-health").isDisabled(), true);
      await page.evaluate(() => window.healthPreparationQueue[1]());
      await page.waitForFunction(() =>
        document
          .querySelector("#health-message")
          .textContent.includes("已检查 13 帧"),
      );
      assert.equal(
        await page.locator("#health-input").inputValue(),
        replacementSource,
      );
      assert.equal(
        await page.locator("#health-counter").textContent(),
        "13 / 13",
      );
      assert.equal(await page.locator("#run-health").isDisabled(), false);
      assert.equal(await page.locator("#download-health").isDisabled(), false);
    }
    assert.equal(
      await page.locator("#source").inputValue(),
      motionBeforeHealth,
    );
    assert.equal(
      await page.locator("#gate-input").inputValue(),
      gatesBeforeHealth,
    );
    assert.equal(
      await page.locator("#counter").textContent(),
      motionCounterBeforeHealth,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      motionResultBeforeHealth,
    );
    // Guarded analysis is a separate opt-in flow. Its pending/drift frames
    // terminate active metric segments while preserving cumulative gate counts.
    const healthBeforeGuarded = await page
      .locator("#health-input")
      .inputValue();
    const healthCounterBeforeGuarded = await page
      .locator("#health-counter")
      .textContent();
    const healthResultBeforeGuarded = await exportJson(
      "#download-health",
      "moonground-health-results.json",
    );
    const guardedSource = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "guarded.ndjson"),
      "utf8",
    );
    const guardedLines = guardedSource.trimEnd().split(/\r?\n/);
    await page.locator("#guarded-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 16 帧门控分析"),
    );
    const guarded = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    assert.equal(guarded.checkpoint.format, "moonground.guarded");
    assert.deepEqual(
      guarded.frames.map((f) => f.decision),
      [
        "blocked",
        "blocked",
        "allowed",
        "allowed",
        "blocked",
        "blocked",
        "blocked",
        "blocked",
        "blocked",
        "blocked",
        "allowed",
        "allowed",
        "blocked",
        "blocked",
        "allowed",
        "allowed",
      ],
    );
    assert.deepEqual(
      guarded.frames.map((f) => f.analysis.counting.crossings.length),
      [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1],
    );
    assert.deepEqual(guarded.frames[4].suppressed_track_ids, [1]);
    assert.deepEqual(guarded.frames[4].analysis.measurement.tracks, []);
    assert.deepEqual(
      guarded.frames[4].analysis.measurement.closed_segment_ids,
      ["1"],
    );
    assert.equal(
      guarded.frames[4].analysis.counting.counts[0].positive_to_negative,
      "1",
    );
    assert.equal(
      guarded.frames[10].analysis.measurement.tracks[0].segment_id,
      "2",
    );
    assert.equal(
      guarded.frames[10].analysis.measurement.tracks[0].status,
      "initializing",
    );
    assert.equal(
      guarded.frames[10].analysis.measurement.tracks[0].speed_mps,
      null,
    );
    assert.equal(
      guarded.frames[14].analysis.measurement.tracks[0].segment_id,
      "3",
    );
    assert.deepEqual(guarded.frames.at(-1).analysis.counting.counts, [
      {
        gate_id: "aisle",
        negative_to_positive: "0",
        positive_to_negative: "3",
      },
    ]);
    const selectGuardedFrame = async (index) =>
      page.locator("#guarded-frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await selectGuardedFrame(4);
    assert.equal(
      await page.locator("#guarded-decision").textContent(),
      "已阻断",
    );
    assert.match(
      await page.locator("#guarded-tracks").textContent(),
      /未生成目标测量/,
    );
    assert.match(
      await page.locator("#guarded-interruptions").textContent(),
      /关闭的测量片段：1/,
    );
    assert.match(
      await page.locator("#guarded-counts").textContent(),
      /aisle01/,
    );
    const guardedCheckpoint = await exportJson(
      "#save-guarded-checkpoint",
      "moonground-guarded-checkpoint.json",
    );
    assert.equal(guardedCheckpoint.health.state.last_timestamp_us, "2250000");
    assert.equal(
      guardedCheckpoint.analysis.measurement.motion.last_timestamp_us,
      "2250000",
    );
    assert.equal(
      guardedCheckpoint.analysis.counting.state.last_timestamp_us,
      "2250000",
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page
      .locator('section[aria-labelledby="guarded-heading"]')
      .screenshot({ path: path.join(directory, "guarded-mobile-preview.png") });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page
      .locator('section[aria-labelledby="guarded-heading"]')
      .screenshot({
        path: path.join(directory, "guarded-desktop-preview.png"),
      });
    const mismatchCamera = structuredClone(guardedCheckpoint);
    mismatchCamera.health.configuration.camera.fx += 1;
    for (const invalid of [
      { ...guardedCheckpoint, checkpoint_version: "999" },
      {
        ...guardedCheckpoint,
        health: {
          ...guardedCheckpoint.health,
          state: { ...guardedCheckpoint.health.state, last_timestamp_us: "0" },
        },
      },
      mismatchCamera,
    ]) {
      await page.locator("#guarded-checkpoint-file").setInputFiles({
        name: "invalid-guarded.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(invalid)),
      });
      await page.waitForFunction(
        () => document.querySelector("#guarded-checkpoint-file").value === "",
      );
      assert.equal(await page.locator("#guarded-message.error").count(), 1);
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        guardedSource,
      );
      assert.deepEqual(
        await exportJson(
          "#download-guarded",
          "moonground-guarded-results.json",
        ),
        guarded,
      );
    }
    const firstWrapper = JSON.parse(guardedLines[1]);
    const wrongTime = {
      ...firstWrapper,
      health: JSON.stringify({
        ...JSON.parse(firstWrapper.health),
        timestamp_us: "1",
      }),
    };
    const duplicateMeasurement = JSON.parse(
      JSON.parse(guardedLines[3]).measurement,
    );
    duplicateMeasurement.observations.push({
      ...duplicateMeasurement.observations[0],
    });
    const duplicateObjectWrapper = {
      ...JSON.parse(guardedLines[3]),
      measurement: JSON.stringify(duplicateMeasurement),
    };
    const unknownHealth = JSON.parse(firstWrapper.health);
    unknownHealth.observations[0].landmark_id = "unknown";
    const duplicateOuter =
      '{"measurement":' +
      JSON.stringify(firstWrapper.measurement) +
      ',"health":' +
      JSON.stringify(firstWrapper.health) +
      ',"health":' +
      JSON.stringify(firstWrapper.health) +
      "}";
    const badStreams = [
      [
        guardedLines[0],
        JSON.stringify({ ...firstWrapper, unknown: true }),
      ].join("\n") + "\n",
      [guardedLines[0], duplicateOuter].join("\n") + "\n",
      [guardedLines[0], JSON.stringify(wrongTime)].join("\n") + "\n",
      [
        guardedLines[0],
        ...guardedLines.slice(1, 3),
        JSON.stringify(duplicateObjectWrapper),
      ].join("\n") + "\n",
      [
        guardedLines[0],
        JSON.stringify({
          ...firstWrapper,
          health: JSON.stringify(unknownHealth),
        }),
      ].join("\n") + "\n",
    ];
    for (const input of badStreams) {
      await page.locator("#guarded-file").setInputFiles({
        name: "invalid-guarded.ndjson",
        mimeType: "application/x-ndjson",
        buffer: Buffer.from(input),
      });
      await page.waitForFunction(
        () => document.querySelector("#guarded-file").value === "",
      );
      assert.equal(await page.locator("#guarded-message.error").count(), 1);
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        guardedSource,
      );
      assert.deepEqual(
        await exportJson(
          "#download-guarded",
          "moonground-guarded-results.json",
        ),
        guarded,
      );
    }
    const lastWrapper = JSON.parse(guardedLines.at(-1));
    const nextGuardedFrame = {
      measurement: JSON.stringify({
        ...JSON.parse(lastWrapper.measurement),
        timestamp_us: "2400000",
      }),
      health: JSON.stringify({
        ...JSON.parse(lastWrapper.health),
        timestamp_us: "2400000",
      }),
    };
    await page
      .locator("#guarded-input")
      .fill(guardedSource + JSON.stringify(nextGuardedFrame) + "\n");
    assert.equal(await page.locator("#download-guarded").isDisabled(), true);
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 17 帧门控分析"),
    );
    const continuedGuarded = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    await page.locator("#guarded-checkpoint-file").setInputFiles({
      name: "guarded.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(guardedCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已载入完整门控检查点"),
    );
    assert.equal(await page.locator("#guarded-counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#download-guarded").isDisabled(), true);
    await page
      .locator("#guarded-input")
      .fill(
        (await page.locator("#guarded-input").inputValue()) +
          JSON.stringify(nextGuardedFrame) +
          "\n",
      );
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 1 帧门控分析"),
    );
    const resumedGuarded = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    assert.deepEqual(resumedGuarded.frames[0], continuedGuarded.frames.at(-1));
    assert.deepEqual(resumedGuarded.checkpoint, continuedGuarded.checkpoint);
    // Nested JSON remains raw: an ID which JS would round to 1 is invalid even
    // when the health decision would otherwise suppress the object's frame.
    const fractionalObject = {
      ...firstWrapper,
      measurement: firstWrapper.measurement.replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
    };
    await page
      .locator("#guarded-input")
      .fill(guardedLines[0] + "\n" + JSON.stringify(fractionalObject) + "\n");
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document.querySelector("#guarded-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#download-guarded").isDisabled(), true);
    const fractionalHeader = JSON.parse(guardedLines[0]),
      fractionalAnalysis = JSON.parse(fractionalHeader.analysis);
    fractionalAnalysis.counting = fractionalAnalysis.counting.replace(
      '"max_tracks":10',
      '"max_tracks":10.0000000000000001',
    );
    fractionalHeader.analysis = JSON.stringify(fractionalAnalysis);
    await page
      .locator("#guarded-input")
      .fill(JSON.stringify(fractionalHeader) + "\n" + guardedLines[1] + "\n");
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document.querySelector("#guarded-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#download-guarded").isDisabled(), true);
    // A newer draft cancels old preparation. A newer valid file or example is
    // allowed to supersede it and keeps the button busy until that run finishes.
    await page.locator("#guarded-input").fill(guardedSource);
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseGuardedPreparation = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#run-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseGuardedPreparation === "function",
    );
    await page.locator("#guarded-input").fill(guardedLines[0] + "\n");
    await page.evaluate(() => {
      window.releaseGuardedPreparation();
      delete window.releaseGuardedPreparation;
    });
    await page.waitForFunction(
      () => !document.querySelector("#run-guarded").disabled,
    );
    assert.equal(await page.locator("#guarded-counter").textContent(), "0 / 0");
    for (const replacement of ["file", "example"]) {
      await page
        .locator("#guarded-input")
        .fill(guardedSource.replace("warehouse-landmarks", "older-monitor"));
      await page.evaluate(() => {
        const original = window.setTimeout;
        window.guardedPreparationQueue = [];
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.guardedPreparationQueue.push(() => callback(...args));
            if (window.guardedPreparationQueue.length === 2)
              window.setTimeout = original;
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
      await page.locator("#run-guarded").click();
      await page.waitForFunction(
        () => window.guardedPreparationQueue.length === 1,
      );
      const replacementSource =
        replacement === "file"
          ? guardedSource.replace("warehouse-landmarks", "replacement-monitor")
          : guardedSource;
      if (replacement === "file")
        await page.locator("#guarded-file").setInputFiles({
          name: "replacement-guarded.ndjson",
          mimeType: "application/x-ndjson",
          buffer: Buffer.from(replacementSource),
        });
      else await page.locator("#guarded-example").click();
      await page.waitForFunction(
        () => window.guardedPreparationQueue.length === 2,
      );
      await page.evaluate(() => window.guardedPreparationQueue[0]());
      assert.equal(await page.locator("#run-guarded").isDisabled(), true);
      await page.evaluate(() => window.guardedPreparationQueue[1]());
      await page.waitForFunction(() =>
        document
          .querySelector("#guarded-message")
          .textContent.includes("已完成 16 帧门控分析"),
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        replacementSource,
      );
      assert.equal(await page.locator("#download-guarded").isDisabled(), false);
    }
    assert.equal(
      await page.locator("#source").inputValue(),
      motionBeforeHealth,
    );
    assert.equal(
      await page.locator("#gate-input").inputValue(),
      gatesBeforeHealth,
    );
    assert.equal(
      await page.locator("#health-input").inputValue(),
      healthBeforeGuarded,
    );
    assert.equal(
      await page.locator("#counter").textContent(),
      motionCounterBeforeHealth,
    );
    assert.equal(
      await page.locator("#health-counter").textContent(),
      healthCounterBeforeGuarded,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      motionResultBeforeHealth,
    );
    assert.deepEqual(
      await exportJson("#download-health", "moonground-health-results.json"),
      healthResultBeforeGuarded,
    );
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
