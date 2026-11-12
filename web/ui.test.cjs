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
    const exportJson = async (selector, filename) => {
      const pending = page.waitForEvent("download");
      await page.locator(selector).click();
      const download = await pending;
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
