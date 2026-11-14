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
    let releaseInitialEvidenceTransit;
    let initialEvidenceTransitRequested;
    const initialEvidenceTransitGate = new Promise((resolve) => {
      releaseInitialEvidenceTransit = resolve;
    });
    const initialEvidenceTransitRequest = new Promise((resolve) => {
      initialEvidenceTransitRequested = resolve;
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
      await draftPage.route(
        "**/evidence-transit-source.json",
        async (route) => {
          initialEvidenceTransitRequested();
          await initialEvidenceTransitGate;
          await route.fulfill({
            contentType: "application/json",
            body: fs.readFileSync(
              path.resolve(
                __dirname,
                "..",
                "examples",
                "evidence-transit-source.json",
              ),
              "utf8",
            ),
          });
        },
      );
      await draftPage.goto(
        `http://127.0.0.1:${server.address().port}/moonground/`,
        { waitUntil: "domcontentloaded" },
      );
      await pendingCalibration;
      await pendingGates;
      await initialEvidenceTransitRequest;
      await draftPage
        .locator("#evidence-transit-section")
        .evaluate((details) => {
          details.open = true;
        });
      const initialEvidenceTransitDraft =
        '{"counting":"user-evidence-transit-draft"}';
      await draftPage
        .locator("#evidence-transit-input")
        .fill(initialEvidenceTransitDraft);
      const initialEvidenceTransitResponse = draftPage.waitForResponse(
        (response) => response.url().endsWith("/evidence-transit-source.json"),
      );
      releaseInitialEvidenceTransit();
      await (await initialEvidenceTransitResponse).finished();
      assert.equal(
        await draftPage.locator("#evidence-transit-input").inputValue(),
        initialEvidenceTransitDraft,
      );
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
      await draftPage.locator("#calibration-section").evaluate((details) => {
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
      releaseInitialEvidenceTransit();
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
      assert.equal(await page.locator(selector).isEnabled(), true, selector);
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
    await page.locator("#calibration-section").evaluate((details) => {
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
    await page.locator("#calibration-section").evaluate((details) => {
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
    await page.locator("#calibration-section").evaluate((details) => {
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
    await page.locator("#calibration-section").evaluate((details) => {
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
    // Transit consumes already validated measurements, with an explicit source
    // choice and the corresponding upstream replay cursor.
    await page.locator("#transit-section").evaluate((details) => {
      details.open = true;
    });
    const transitConfiguration = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "transit.json"),
      "utf8",
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    const transit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    // A different valid upstream session fails inside the bridge and keeps the
    // currently displayed ordinary transit result intact.
    await page.locator("#transit-guarded").click();
    await page.waitForFunction(() =>
      document.querySelector("#transit-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      transit,
    );
    // A newer explicit source choice supersedes older preparation, even while
    // the earlier zero-delay callback has not been released.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseTransitSourceChoice = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#transit-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseTransitSourceChoice === "function",
    );
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    await page.evaluate(() => {
      window.releaseTransitSourceChoice();
      delete window.releaseTransitSourceChoice;
    });
    assert.equal(await page.locator("#transit-message.error").count(), 0);
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      transit,
    );
    assert.equal(transit.checkpoint.format, "moonground.transit");
    assert.deepEqual(transit.frames.at(-1).counts, [
      { section_id: "aisle", completed: "1" },
    ]);
    const passageIndex = transit.frames.findIndex(
      (frame) => frame.passages.length > 0,
    );
    assert.ok(passageIndex >= 0);
    const passage = transit.frames[passageIndex].passages[0];
    assert.ok(
      BigInt(passage.elapsed_upper_us) >= BigInt(passage.elapsed_lower_us),
    );
    assert.ok(passage.estimated_elapsed_us >= Number(passage.elapsed_lower_us));
    assert.ok(passage.estimated_elapsed_us <= Number(passage.elapsed_upper_us));
    assert.equal(Object.hasOwn(passage, "speed_mps"), false);
    await page.locator("#frame").evaluate((input, value) => {
      input.value = String(value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    }, passageIndex);
    assert.match(
      await page.locator("#transit-source").textContent(),
      /普通测量/,
    );
    assert.match(
      await page.locator("#transit-passages").textContent(),
      /aisle/,
    );
    assert.match(await page.locator("#transit-counts").textContent(), /aisle1/);
    const transitCheckpoint = await exportJson(
      "#save-transit-checkpoint",
      "moonground-transit-checkpoint.json",
    );
    assert.equal(transitCheckpoint.counting.state.last_timestamp_us, "1800000");
    await page.locator("#transit-input").evaluate((input) => {
      input.scrollTop = 0;
    });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page
      .locator("#transit-section")
      .screenshot({ path: path.join(directory, "transit-mobile-preview.png") });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#transit-section").screenshot({
      path: path.join(directory, "transit-desktop-preview.png"),
    });
    const ordinaryAtTransit = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page
      .locator("#gate-input")
      .fill((await page.locator("#gate-input").inputValue()) + " ");
    assert.equal(await page.locator("#download-transit").isDisabled(), false);
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      transit,
    );
    for (const invalid of [
      { ...transitCheckpoint, checkpoint_version: "999" },
      {
        ...transitCheckpoint,
        counts: [{ section_id: "aisle", completed: "-1" }],
      },
    ]) {
      await page.locator("#transit-checkpoint-file").setInputFiles({
        name: "invalid-transit.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(invalid)),
      });
      await page.waitForFunction(
        () => document.querySelector("#transit-checkpoint-file").value === "",
      );
      assert.equal(await page.locator("#transit-message.error").count(), 1);
      assert.equal(
        await page.locator("#transit-input").inputValue(),
        transitConfiguration,
      );
      assert.deepEqual(
        await exportJson(
          "#download-transit",
          "moonground-transit-results.json",
        ),
        transit,
      );
    }
    // Save the matching upstream final watermark before restoring the separate
    // downstream checkpoint and supplying only a later measurement frame.
    await page.locator("#frame").evaluate((input) => {
      input.value = input.max;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const transitMotionCheckpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    const warehouseInput = await page.locator("#source").inputValue();
    const nextTransitObservation = {
      timestamp_us: "2000000",
      observations: [{ track_id: 1, point: [270, 240] }],
    };
    await page
      .locator("#source")
      .fill(warehouseInput + JSON.stringify(nextTransitObservation) + "\n");
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 11 帧"),
    );
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 11 帧"),
    );
    const extendedTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    await page
      .locator("#source")
      .fill(
        JSON.stringify({ resume: transitMotionCheckpoint }) +
          "\n" +
          JSON.stringify(nextTransitObservation) +
          "\n",
      );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    await page.locator("#transit-checkpoint-file").setInputFiles({
      name: "transit.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(transitCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已载入区间检查点"),
    );
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 1 帧"),
    );
    const resumedTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    assert.deepEqual(resumedTransit.frames[0], extendedTransit.frames.at(-1));
    assert.deepEqual(resumedTransit.checkpoint, extendedTransit.checkpoint);
    const rawTransit = JSON.parse(transitConfiguration);
    rawTransit.counting = rawTransit.counting.replace(
      '"max_tracks":1000',
      '"max_tracks":1000.0000000000000001',
    );
    await page.locator("#transit-input").fill(JSON.stringify(rawTransit));
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document.querySelector("#transit-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#download").isDisabled(), false);
    // Healthy blocking propagates as empty measurement frames, cancelling
    // pending entries. It cannot complete a passage across a blocked interval.
    const guardedTransitConfiguration = JSON.parse(transitConfiguration);
    const guardedTransitGates = JSON.parse(
      guardedTransitConfiguration.counting,
    );
    guardedTransitGates.session_id = "guarded-warehouse";
    guardedTransitGates.gates[0].start_m[0] = 5.8;
    guardedTransitGates.gates[0].end_m[0] = 5.8;
    guardedTransitGates.gates[1].start_m[0] = 6.6;
    guardedTransitGates.gates[1].end_m[0] = 6.6;
    guardedTransitConfiguration.counting = JSON.stringify(guardedTransitGates);
    await page
      .locator("#transit-input")
      .fill(JSON.stringify(guardedTransitConfiguration));
    await page.locator("#transit-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 16 帧"),
    );
    const guardedTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    assert.deepEqual(guardedTransit.frames.at(-1).counts, [
      { section_id: "aisle", completed: "0" },
    ]);
    assert.equal(guardedTransit.frames[3].pending_count, 1);
    assert.equal(guardedTransit.frames[4].pending_count, 0);
    assert.equal(
      guardedTransit.frames[4].cancellations[0].reason,
      "discontinuity",
    );
    await page.locator("#guarded-frame").evaluate((input) => {
      input.value = "4";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(
      await page.locator("#transit-source").textContent(),
      /健康门控测量.*5 \/ 16/,
    );
    assert.match(
      await page.locator("#transit-cancellations").textContent(),
      /观测中断/,
    );
    await page
      .locator("#source")
      .fill((await page.locator("#source").inputValue()) + " ");
    assert.equal(await page.locator("#download-transit").isDisabled(), false);
    await page
      .locator("#guarded-input")
      .fill((await page.locator("#guarded-input").inputValue()) + " ");
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    // A configuration edit cancels in-flight preparation without changing the
    // upstream results.
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseTransitPreparation = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseTransitPreparation === "function",
    );
    await page.locator("#transit-input").fill(transitConfiguration + " ");
    await page.evaluate(() => {
      window.releaseTransitPreparation();
      delete window.releaseTransitPreparation;
    });
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      ordinaryAtTransit,
    );
    // Changing the selected upstream draft while preparing also prevents a
    // stale transit result from becoming available.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseTransitUpstream = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseTransitUpstream === "function",
    );
    await page.locator("#source").fill(warehouseInput + " ");
    await page.evaluate(() => {
      window.releaseTransitUpstream();
      delete window.releaseTransitUpstream;
    });
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    assert.equal(await page.locator("#transit-ordinary").isDisabled(), true);
    // Projection replacement stays inside the existing guarded stream. A
    // separate ordinary transit result survives until its own source changes.
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    const ordinaryBeforeProjection = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    const projectionSource = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "projection-replace.ndjson"),
      "utf8",
    );
    const projectionLines = projectionSource.trimEnd().split("\n");
    await page.locator("#guarded-projection-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("含 1 次标定切换"),
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      projectionSource,
    );
    const projection = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    assert.equal(projection.frames.length, 16);
    const barrierIndex = projection.frames.findIndex(
      (frame) => frame.kind === "guarded_projection_replaced",
    );
    assert.equal(barrierIndex, 9);
    const barrier = projection.frames[barrierIndex];
    const replacement = JSON.parse(
      JSON.parse(projectionLines[barrierIndex + 1]).replace_projection,
    );
    assert.equal(projection.frames[8].health.status, "drift");
    assert.equal(barrier.decision, "blocked");
    assert.equal(barrier.health.timestamp_us, "950000");
    assert.equal(barrier.health.status, "insufficient");
    assert.equal(barrier.health.streak_since_us, null);
    assert.deepEqual(barrier.analysis.measurement.tracks, []);
    assert.deepEqual(barrier.suppressed_track_ids, []);
    assert.equal(barrier.analysis.counting.counts[0].positive_to_negative, "1");
    assert.equal(projection.frames[12].health.status, "healthy");
    assert.equal(
      projection.frames[12].analysis.measurement.tracks[0].segment_id,
      "2",
    );
    assert.equal(
      projection.frames[12].analysis.measurement.tracks[0].status,
      "initializing",
    );
    assert.equal(
      projection.frames[12].analysis.measurement.tracks[0].speed_mps,
      null,
    );
    assert.equal(
      projection.frames.at(-1).analysis.measurement.tracks[0].status,
      "ready",
    );
    assert.equal(
      projection.frames.at(-1).analysis.counting.counts[0].positive_to_negative,
      "2",
    );
    assert.deepEqual(
      projection.checkpoint.analysis.measurement.configuration.calibration
        .matrix,
      replacement.calibration.matrix,
    );
    assert.deepEqual(
      projection.checkpoint.health.configuration.camera,
      projection.checkpoint.analysis.measurement.configuration.camera,
    );
    assert.deepEqual(
      projection.checkpoint.health.configuration.calibration.roi,
      replacement.calibration.roi,
    );
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      ordinaryBeforeProjection,
    );
    await page.locator("#source").fill(warehouseInput + " ");
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    assert.equal(await page.locator("#download-guarded").isDisabled(), false);
    await page.locator("#guarded-frame").evaluate((input, value) => {
      input.value = String(value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    }, barrierIndex);
    assert.equal(
      await page.locator("#guarded-decision").textContent(),
      "切换标定",
    );
    assert.match(
      await page.locator("#guarded-evidence").textContent(),
      /从下一帧重新确认/,
    );
    assert.match(
      await page.locator("#guarded-projection").textContent(),
      /发生 1 次/,
    );
    assert.deepEqual(
      await page.locator("#guarded-timeline").evaluate((canvas, index) => {
        const x = Math.floor(((index + 0.5) * canvas.width) / 16);
        return Array.from(
          canvas.getContext("2d").getImageData(x, 15, 1, 1).data,
        );
      }, barrierIndex),
      [114, 80, 156, 255],
    );
    const projectionCheckpoint = await exportJson(
      "#save-guarded-checkpoint",
      "moonground-guarded-checkpoint.json",
    );
    assert.equal(
      projectionCheckpoint.health.state.last_timestamp_us,
      "1550000",
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator('[aria-labelledby="guarded-heading"]').screenshot({
      path: path.join(directory, "projection-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator('[aria-labelledby="guarded-heading"]').screenshot({
      path: path.join(directory, "projection-desktop-preview.png"),
    });
    const operation = JSON.parse(projectionLines[barrierIndex + 1]);
    const missingCamera = { ...replacement };
    delete missingCamera.camera;
    const unknownCamera = {
      ...replacement,
      camera: { ...replacement.camera, unknown: true },
    };
    const badProjectionOperations = [
      JSON.stringify({ replace_projection: JSON.stringify(unknownCamera) }),
      JSON.stringify({ replace_projection: JSON.stringify(missingCamera) }),
      JSON.stringify({
        replace_projection: JSON.stringify({ ...replacement, unknown: true }),
      }),
      JSON.stringify({
        replace_projection: operation.replace_projection.replace(
          '"camera":',
          '"camera":null,"camera":',
        ),
      }),
      '{"replace_projection":' +
        JSON.stringify(operation.replace_projection) +
        ',"replace_projection":' +
        JSON.stringify(operation.replace_projection) +
        "}",
      JSON.stringify({
        replace_projection: JSON.stringify({
          ...replacement,
          timestamp_us: "900000",
        }),
      }),
      JSON.stringify({
        replace_projection: operation.replace_projection,
        measurement: JSON.parse(projectionLines[1]).measurement,
      }),
      JSON.stringify({ replace_projection: replacement }),
    ];
    for (const badOperation of badProjectionOperations) {
      await page.locator("#guarded-file").setInputFiles({
        name: "invalid-projection.ndjson",
        mimeType: "application/x-ndjson",
        buffer: Buffer.from(
          projectionLines.slice(0, barrierIndex + 1).join("\n") +
            "\n" +
            badOperation +
            "\n",
        ),
      });
      await page.waitForFunction(
        () => document.querySelector("#guarded-file").value === "",
      );
      assert.equal(await page.locator("#guarded-message.error").count(), 1);
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        projectionSource,
      );
      assert.deepEqual(
        await exportJson(
          "#download-guarded",
          "moonground-guarded-results.json",
        ),
        projection,
      );
    }
    // The final checkpoint is bound to the replacement projection, and a
    // resumed next frame exactly matches replaying the full source.
    const afterReplacement = JSON.parse(projectionLines.at(-1));
    for (const field of ["measurement", "health"]) {
      const payload = JSON.parse(afterReplacement[field]);
      payload.timestamp_us = "1700000";
      afterReplacement[field] = JSON.stringify(payload);
    }
    await page
      .locator("#guarded-input")
      .fill(projectionSource + JSON.stringify(afterReplacement) + "\n");
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 17 帧门控分析"),
    );
    const extendedProjection = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    await page.locator("#guarded-checkpoint-file").setInputFiles({
      name: "projection-checkpoint.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(projectionCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已载入完整门控检查点"),
    );
    await page
      .locator("#guarded-input")
      .fill(
        (await page.locator("#guarded-input").inputValue()) +
          JSON.stringify(afterReplacement) +
          "\n",
      );
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 1 帧门控分析"),
    );
    const resumedProjection = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    assert.deepEqual(
      resumedProjection.frames[0],
      extendedProjection.frames.at(-1),
    );
    assert.deepEqual(
      resumedProjection.checkpoint,
      extendedProjection.checkpoint,
    );
    // A second barrier while healthy closes an active segment. The transit
    // consumer receives that exact empty frame and cancels its pending entry.
    const secondReplacement = {
      timestamp_us: "1600000",
      calibration: {
        ...replacement.calibration,
        matrix: [0.025, 0, -0.75, 0, 0.025, -1, 0, 0, 1],
      },
      camera: null,
    };
    const twiceProjectionSource =
      projectionSource +
      JSON.stringify({
        replace_projection: JSON.stringify(secondReplacement),
      }) +
      "\n";
    await page.locator("#guarded-input").fill(twiceProjectionSource);
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("含 2 次标定切换"),
    );
    const twiceProjection = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    assert.deepEqual(
      twiceProjection.frames.at(-1).analysis.measurement.closed_segment_ids,
      ["2"],
    );
    assert.equal(twiceProjection.frames.at(-1).health.status, "insufficient");
    assert.equal(
      twiceProjection.frames.at(-1).analysis.counting.counts[0]
        .positive_to_negative,
      "2",
    );
    assert.equal(
      twiceProjection.checkpoint.health.state.last_timestamp_us,
      "1600000",
    );
    assert.equal(twiceProjection.checkpoint.health.state.streak, null);
    assert.equal(
      twiceProjection.checkpoint.analysis.measurement.configuration.camera ??
        null,
      null,
    );
    assert.equal(
      twiceProjection.checkpoint.health.configuration.camera ?? null,
      null,
    );
    assert.match(
      await page.locator("#guarded-projection").textContent(),
      /发生 2 次/,
    );
    const projectionTransitConfig = JSON.parse(transitConfiguration);
    const projectionTransitGates = JSON.parse(projectionTransitConfig.counting);
    projectionTransitGates.session_id = "projection-replace-warehouse";
    for (const [index, x] of [6.2, 6.9].entries()) {
      projectionTransitGates.gates[index].start_m[0] = x;
      projectionTransitGates.gates[index].end_m[0] = x;
    }
    projectionTransitConfig.counting = JSON.stringify(projectionTransitGates);
    await page
      .locator("#transit-input")
      .fill(JSON.stringify(projectionTransitConfig));
    await page.locator("#transit-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 17 帧"),
    );
    const projectionTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    assert.equal(projectionTransit.frames[15].pending_count, 1);
    assert.equal(projectionTransit.frames[16].pending_count, 0);
    assert.equal(
      projectionTransit.frames[16].cancellations[0].reason,
      "discontinuity",
    );
    assert.equal(projectionTransit.frames[16].cancellations[0].segment_id, "2");
    assert.equal(projectionTransit.frames.at(-1).counts[0].completed, "1");
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    assert.equal(await page.locator("#download-transit").isDisabled(), false);
    await page.locator("#guarded-projection-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("含 1 次标定切换"),
    );
    assert.equal(await page.locator("#download-transit").isDisabled(), true);
    // The new example uses the same superseding-run rules as the original
    // example: releasing an older preparation cannot replace the newer run.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.projectionPreparationQueue = [];
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.projectionPreparationQueue.push(() => callback(...args));
          if (window.projectionPreparationQueue.length === 2)
            window.setTimeout = original;
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#run-guarded").click();
    await page.waitForFunction(
      () => window.projectionPreparationQueue.length === 1,
    );
    await page.locator("#guarded-projection-example").click();
    await page.waitForFunction(
      () => window.projectionPreparationQueue.length === 2,
    );
    await page.evaluate(() => window.projectionPreparationQueue[0]());
    assert.equal(await page.locator("#run-guarded").isDisabled(), true);
    await page.evaluate(() => window.projectionPreparationQueue[1]());
    await page.waitForFunction(
      () => !document.querySelector("#run-guarded").disabled,
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      projectionSource,
    );
    assert.deepEqual(
      await exportJson("#download-guarded", "moonground-guarded-results.json"),
      projection,
    );
    // The independent evidence source is raw text, including a late default
    // configuration read which must not replace a user's draft.
    const evidenceConfiguration = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "gate-evidence.json"),
      "utf8",
    );
    const evidenceDraft = await browser.newPage();
    let releaseEvidenceDefault;
    const heldEvidenceDefault = new Promise((resolve) => {
      releaseEvidenceDefault = resolve;
    });
    let evidenceDefaultRequested;
    const evidenceDefaultRequest = new Promise((resolve) => {
      evidenceDefaultRequested = resolve;
    });
    await evidenceDraft.route("**/gate-evidence.json", async (route) => {
      evidenceDefaultRequested();
      await heldEvidenceDefault;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: evidenceConfiguration,
      });
    });
    await evidenceDraft.goto(page.url());
    await evidenceDefaultRequest;
    await evidenceDraft
      .locator("#gate-evidence-section")
      .evaluate((details) => {
        details.open = true;
      });
    await evidenceDraft
      .locator("#evidence-input")
      .fill(evidenceConfiguration + " ");
    const evidenceDefaultResponse = evidenceDraft.waitForResponse((response) =>
      response.url().endsWith("/gate-evidence.json"),
    );
    releaseEvidenceDefault();
    await evidenceDefaultResponse;
    await evidenceDraft.evaluate(
      () => new Promise((resolve) => setTimeout(resolve, 0)),
    );
    assert.equal(
      await evidenceDraft.locator("#evidence-input").inputValue(),
      evidenceConfiguration + " ",
    );
    await evidenceDraft.close();
    assert.equal(
      await page
        .locator("#gate-evidence-section")
        .evaluate((details) => details.open),
      false,
    );
    await page.locator("#gate-evidence-section").evaluate((details) => {
      details.open = true;
    });
    await page
      .locator("#gate-input")
      .fill(
        fs.readFileSync(
          path.resolve(__dirname, "..", "examples", "gates.json"),
          "utf8",
        ),
      );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已测量并统计 10 帧"),
    );
    const legacyBeforeEvidence = await exportJson(
      "#download-analysis",
      "moonground-analysis-results.json",
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    const transitBeforeEvidence = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    await page.locator("#evidence-input").fill(evidenceConfiguration);
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 10 帧"),
    );
    const warehouseEvidence = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    assert.equal(
      warehouseEvidence.checkpoint.format,
      "moonground.gate-evidence",
    );
    assert.equal(warehouseEvidence.frames[0].kind, "gate_evidence_frame");
    assert.equal(
      warehouseEvidence.frames[0].evidence_scope,
      "normal_band_on_filtered_mean_chord",
    );
    assert.ok(warehouseEvidence.frames[0].evidence.length > 0);
    assert.deepEqual(
      await exportJson(
        "#download-analysis",
        "moonground-analysis-results.json",
      ),
      legacyBeforeEvidence,
    );
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      transitBeforeEvidence,
    );
    await page
      .locator("#gate-input")
      .fill((await page.locator("#gate-input").inputValue()) + " ");
    assert.equal(await page.locator("#download-evidence").isDisabled(), false);
    assert.equal(await page.locator("#download-transit").isDisabled(), false);
    // Equal means and equal worst-axis sigma, but different normal variances.
    // The whole path is measured by the existing ground session, not fabricated
    // as measurement JSON in the browser test.
    const directionalGates = {
      session_id: "evidence-direction",
      max_gap_us: "500000",
      max_tracks: 10,
      gates: [
        {
          gate_id: "vertical",
          start_m: [0, -2],
          end_m: [0, 2],
          deadband_m: 0.05,
        },
        {
          gate_id: "horizontal",
          start_m: [-2, 0],
          end_m: [2, 0],
          deadband_m: 0.05,
        },
      ],
    };
    const directionalConfiguration = {
      counting: JSON.stringify(directionalGates),
      sigma_multiplier: 2,
    };
    const directionalFrame = (timestamp, x) => ({
      timestamp_us: timestamp,
      observations: [
        { track_id: 1, point: [x, x], covariance: [0.0001, 0, 1] },
        { track_id: 2, point: [x, x], covariance: [1, 0, 0.0001] },
      ],
    });
    const directionalFrames = [
      directionalFrame("0", 0.3),
      directionalFrame("200000", 0.01),
      directionalFrame("400000", -0.3),
    ];
    const directionalHeader = {
      session_id: "evidence-direction",
      mode: "ground",
      motion: { q: 0.01, gate: 1e12 },
    };
    const directionalSource =
      [directionalHeader, ...directionalFrames].map(JSON.stringify).join("\n") +
      "\n";
    await page.locator("#source").fill(directionalSource);
    assert.equal(await page.locator("#download-evidence").isDisabled(), true);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 3 帧"),
    );
    const directionalMeasurement = await exportJson(
      "#download",
      "moonground-results.json",
    );
    assert.equal(
      directionalMeasurement.frames[0].tracks[0].position_std_m,
      directionalMeasurement.frames[0].tracks[1].position_std_m,
    );
    await page.locator("#gate-input").fill(JSON.stringify(directionalGates));
    await page.locator("#analyze-gates").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#gate-message")
        .textContent.includes("已统计 3 帧"),
    );
    const directionalLegacy = await exportJson(
      "#download-gates",
      "moonground-gate-results.json",
    );
    assert.equal(directionalLegacy.checkpoint.checkpoint_version, "1");
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration));
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 3 帧"),
    );
    const directional = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    const initialEvidence = (id, gate) =>
      directional.frames[0].evidence.find(
        (item) => item.track_id === id && item.gate_id === gate,
      );
    assert.equal(initialEvidence(1, "vertical").normal_std_m, 0.01);
    assert.equal(initialEvidence(1, "vertical").side, "negative");
    assert.equal(initialEvidence(1, "horizontal").normal_std_m, 1);
    assert.equal(initialEvidence(1, "horizontal").side, "unconfirmed");
    assert.equal(initialEvidence(2, "vertical").normal_std_m, 1);
    assert.equal(initialEvidence(2, "vertical").side, "unconfirmed");
    assert.equal(initialEvidence(2, "horizontal").normal_std_m, 0.01);
    assert.equal(initialEvidence(2, "horizontal").side, "positive");
    assert.equal(directional.frames.at(-1).counting.crossings.length, 2);
    assert.equal(directionalLegacy.frames.at(-1).crossings.length, 4);
    assert.deepEqual(
      await exportJson("#download-gates", "moonground-gate-results.json"),
      directionalLegacy,
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "0";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(
      await page.locator("#evidence-summary").textContent(),
      /4 项，2 项侧别未确认/,
    );
    assert.match(
      await page.locator("#evidence-rows").textContent(),
      /0\.0100000/,
    );
    assert.equal(await page.locator("#evidence-rows tr").count(), 4);
    await page.locator("#gate-evidence-section").evaluate((details) => {
      details.open = false;
    });
    await page.locator("#frame").evaluate((input) => {
      input.value = "1";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.equal(await page.locator("#evidence-rows tr").count(), 0);
    await page.locator("#gate-evidence-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#evidence-rows tr").length === 4,
    );
    assert.match(
      await page.locator("#evidence-rows").textContent(),
      /侧别未确认/,
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = "0";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const evidenceCheckpoint = await exportJson(
      "#save-evidence-checkpoint",
      "moonground-gate-evidence-checkpoint.json",
    );
    assert.equal(evidenceCheckpoint.state.last_timestamp_us, "400000");
    assert.ok(
      evidenceCheckpoint.state.tracks.some((track) =>
        track.anchors.some((anchor) => anchor?.covariance),
      ),
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#gate-evidence-section").screenshot({
      path: path.join(directory, "gate-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#gate-evidence-section").screenshot({
      path: path.join(directory, "gate-evidence-desktop-preview.png"),
    });
    const badEvidenceCovariance = JSON.parse(
      JSON.stringify(evidenceCheckpoint),
    );
    badEvidenceCovariance.state.tracks[0].anchors.find(Boolean).covariance = [
      1, 2, 1,
    ];
    for (const invalid of [
      { ...evidenceCheckpoint, checkpoint_version: "2" },
      badEvidenceCovariance,
      directionalLegacy.checkpoint,
    ]) {
      await page.locator("#evidence-checkpoint-file").setInputFiles({
        name: "invalid-evidence.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(invalid)),
      });
      await page.waitForFunction(
        () => document.querySelector("#evidence-checkpoint-file").value === "",
      );
      assert.equal(await page.locator("#evidence-message.error").count(), 1);
      assert.equal(
        await page.locator("#evidence-input").inputValue(),
        JSON.stringify(directionalConfiguration),
      );
      assert.deepEqual(
        await exportJson(
          "#download-evidence",
          "moonground-gate-evidence-results.json",
        ),
        directional,
      );
    }
    // A wrong explicit source fails without replacing the currently valid result.
    await page.locator("#evidence-guarded").click();
    await page.waitForFunction(() =>
      document.querySelector("#evidence-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson(
        "#download-evidence",
        "moonground-gate-evidence-results.json",
      ),
      directional,
    );
    await page.locator("#frame").evaluate((input) => {
      input.value = input.max;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const evidenceMotionCheckpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    const nextEvidenceObservation = directionalFrame("600000", -0.5);
    await page
      .locator("#source")
      .fill(directionalSource + JSON.stringify(nextEvidenceObservation) + "\n");
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 4 帧"),
    );
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 4 帧"),
    );
    const extendedEvidence = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    await page
      .locator("#source")
      .fill(
        JSON.stringify({ resume: evidenceMotionCheckpoint }) +
          "\n" +
          JSON.stringify(nextEvidenceObservation) +
          "\n",
      );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    await page.locator("#evidence-checkpoint-file").setInputFiles({
      name: "evidence.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已载入独立法向证据检查点"),
    );
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 1 帧"),
    );
    const resumedEvidence = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    assert.deepEqual(resumedEvidence.frames[0], extendedEvidence.frames.at(-1));
    assert.deepEqual(resumedEvidence.checkpoint, extendedEvidence.checkpoint);
    // k=0 still reports the actual normal sigma, and never substitutes the
    // scalar worst-axis sigma for the directional covariance.
    await page
      .locator("#evidence-input")
      .fill(
        JSON.stringify({ ...directionalConfiguration, sigma_multiplier: 0 }),
      );
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 1 帧"),
    );
    const zeroBand = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    assert.ok(
      zeroBand.frames[0].evidence.every((item) => item.normal_std_m > 0),
    );
    assert.ok(
      zeroBand.frames[0].evidence.every(
        (item) => item.lower_m === item.upper_m,
      ),
    );
    const rawEvidenceSources = [
      JSON.stringify({
        ...directionalConfiguration,
        counting: directionalConfiguration.counting.replace(
          '"max_tracks":10',
          '"max_tracks":10.0000000000000001',
        ),
      }),
      '{"counting":' +
        JSON.stringify(directionalConfiguration.counting) +
        ',"sigma_multiplier":2,"sigma_multiplier":0}',
      JSON.stringify({
        ...directionalConfiguration,
        counting: JSON.stringify({ resume: directionalLegacy.checkpoint }),
      }),
    ];
    for (const rawConfiguration of rawEvidenceSources) {
      await page.locator("#evidence-input").fill(rawConfiguration);
      await page.locator("#evidence-ordinary").click();
      await page.waitForFunction(() =>
        document.querySelector("#evidence-message").classList.contains("error"),
      );
      assert.equal(await page.locator("#download-evidence").isDisabled(), true);
      assert.equal(await page.locator("#download").isDisabled(), false);
    }
    // Empty guarded frames, including projection barriers, clear confidence
    // anchors without changing the previous cumulative counts.
    await page.locator("#guarded-input").fill(twiceProjectionSource);
    await page.locator("#run-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("含 2 次标定切换"),
    );
    const evidenceGuardedGates = JSON.parse(
      JSON.parse(JSON.parse(projectionLines[0]).analysis).counting,
    );
    await page.locator("#evidence-input").fill(
      JSON.stringify({
        counting: JSON.stringify(evidenceGuardedGates),
        sigma_multiplier: 2,
      }),
    );
    await page.locator("#evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 17 帧"),
    );
    const guardedEvidence = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    assert.equal(guardedEvidence.frames[6].evidence.length, 0);
    assert.equal(guardedEvidence.frames[9].evidence.length, 0);
    assert.equal(guardedEvidence.frames[16].evidence.length, 0);
    assert.equal(
      guardedEvidence.frames.at(-1).counting.counts[0].positive_to_negative,
      "2",
    );
    assert.deepEqual(guardedEvidence.checkpoint.state.tracks, []);
    await page.locator("#guarded-frame").evaluate((input) => {
      input.value = "15";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(await page.locator("#evidence-rows").textContent(), /aisle/);
    await page.locator("#guarded-frame").evaluate((input) => {
      input.value = "16";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.match(
      await page.locator("#evidence-rows").textContent(),
      /本帧无可用/,
    );
    await page
      .locator("#source")
      .fill((await page.locator("#source").inputValue()) + " ");
    assert.equal(await page.locator("#download-evidence").isDisabled(), false);
    // New source choice supersedes an older preparation without a busy lock.
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseEvidencePreparation = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidencePreparation === "function",
    );
    await page.locator("#evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 17 帧"),
    );
    await page.evaluate(() => {
      window.releaseEvidencePreparation();
      delete window.releaseEvidencePreparation;
    });
    assert.equal(await page.locator("#evidence-message.error").count(), 0);
    assert.deepEqual(
      await exportJson(
        "#download-evidence",
        "moonground-gate-evidence-results.json",
      ),
      guardedEvidence,
    );
    await page.locator("#guarded-input").fill(twiceProjectionSource + " ");
    assert.equal(await page.locator("#download-evidence").isDisabled(), true);
    await page.locator("#evidence-input").fill(evidenceConfiguration);
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseEvidenceEdit = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceEdit === "function",
    );
    await page.locator("#evidence-input").fill(evidenceConfiguration + " ");
    await page.evaluate(() => {
      window.releaseEvidenceEdit();
      delete window.releaseEvidenceEdit;
    });
    assert.equal(await page.locator("#download-evidence").isDisabled(), true);
    assert.equal(await page.locator("#download").isDisabled(), false);
    // Joint evidence analysis owns a separate replay. It never replaces an
    // already displayed ordinary measurement, legacy analysis or transit run.
    await page
      .locator("#gate-input")
      .fill(
        fs.readFileSync(
          path.resolve(__dirname, "..", "examples", "gates.json"),
          "utf8",
        ),
      );
    await page.locator("#analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#message")
        .textContent.includes("已测量并统计 10 帧"),
    );
    const jointBase = await exportJson("#download", "moonground-results.json");
    const jointLegacy = await exportJson(
      "#download-analysis",
      "moonground-analysis-results.json",
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    const jointTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    await page.locator("#evidence-input").fill(evidenceConfiguration);
    await page.locator("#evidence-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已处理 10 帧"),
    );
    const independentBeforeJoint = await exportJson(
      "#download-evidence",
      "moonground-gate-evidence-results.json",
    );
    const ordinaryCounterBeforeJoint = await page
      .locator("#counter")
      .textContent();
    const jointInput = await page.locator("#source").inputValue();
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已联合计算 10 帧"),
    );
    const evidenceJoint = await exportJson(
      "#download-evidence-analysis",
      "moonground-evidence-analysis-results.json",
    );
    assert.equal(
      evidenceJoint.checkpoint.format,
      "moonground.evidence-analysis",
    );
    assert.ok(
      evidenceJoint.frames.every(
        (frame) => frame.kind === "evidence_analysis_frame",
      ),
    );
    assert.deepEqual(
      evidenceJoint.frames.map((frame) => frame.measurement),
      jointBase.frames,
    );
    assert.deepEqual(
      evidenceJoint.frames.map((frame) => frame.counting),
      independentBeforeJoint.frames,
    );
    assert.deepEqual(
      evidenceJoint.checkpoint.counting,
      independentBeforeJoint.checkpoint,
    );
    assert.equal(await page.locator("#download-evidence").isDisabled(), true);
    assert.equal(
      await page.locator("#save-evidence-checkpoint").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#counter").textContent(),
      ordinaryCounterBeforeJoint,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      jointBase,
    );
    assert.deepEqual(
      await exportJson(
        "#download-analysis",
        "moonground-analysis-results.json",
      ),
      jointLegacy,
    );
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      jointTransit,
    );
    await page.locator("#evidence-joint-frame").evaluate((input) => {
      input.value = "2";
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    assert.equal(
      await page.locator("#evidence-joint-counter").textContent(),
      "3 / 10",
    );
    assert.equal(
      await page.locator("#counter").textContent(),
      ordinaryCounterBeforeJoint,
    );
    assert.match(
      await page.locator("#evidence-joint-tracks").textContent(),
      /1 \/ 1/,
    );
    const evidenceJointCheckpoint = await exportJson(
      "#save-evidence-analysis-checkpoint",
      "moonground-evidence-analysis-checkpoint.json",
    );
    assert.equal(
      evidenceJointCheckpoint.measurement.motion.last_timestamp_us,
      "400000",
    );
    assert.equal(
      evidenceJointCheckpoint.counting.state.last_timestamp_us,
      "400000",
    );
    assert.equal(
      evidenceJoint.checkpoint.counting.state.last_timestamp_us,
      "1800000",
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#gate-evidence-section").screenshot({
      path: path.join(directory, "evidence-analysis-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#gate-evidence-section").screenshot({
      path: path.join(directory, "evidence-analysis-desktop-preview.png"),
    });
    const mismatchedEvidenceJoint = JSON.parse(
      JSON.stringify(evidenceJointCheckpoint),
    );
    mismatchedEvidenceJoint.counting.state.last_timestamp_us = "500000";
    const fractionalEvidenceJoint = JSON.stringify(
      evidenceJointCheckpoint,
    ).replace('"track_id":1', '"track_id":1.0000000000000001');
    for (const invalid of [
      JSON.stringify({ ...evidenceJointCheckpoint, checkpoint_version: "999" }),
      JSON.stringify(mismatchedEvidenceJoint),
      fractionalEvidenceJoint,
      JSON.stringify(independentBeforeJoint.checkpoint),
    ]) {
      await page.locator("#evidence-analysis-checkpoint-file").setInputFiles({
        name: "invalid-joint-evidence.json",
        mimeType: "application/json",
        buffer: Buffer.from(invalid),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-analysis-checkpoint-file").value ===
          "",
      );
      assert.equal(await page.locator("#evidence-message.error").count(), 1);
      assert.equal(await page.locator("#source").inputValue(), jointInput);
      assert.equal(
        await page.locator("#evidence-input").inputValue(),
        evidenceConfiguration,
      );
      assert.deepEqual(
        await exportJson(
          "#download-evidence-analysis",
          "moonground-evidence-analysis-results.json",
        ),
        evidenceJoint,
      );
    }
    // One full checkpoint restores both watermarks; only later observations
    // are needed, without a separate measurement/checkpoint pairing step.
    await page.locator("#evidence-analysis-checkpoint-file").setInputFiles({
      name: "joint-evidence.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceJointCheckpoint)),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已载入完整联合证据检查点"),
    );
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );
    const jointTail =
      jointInput.trimEnd().split("\n").slice(4).join("\n") + "\n";
    await page
      .locator("#source")
      .fill((await page.locator("#source").inputValue()) + jointTail);
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已联合计算 7 帧"),
    );
    const resumedEvidenceJoint = await exportJson(
      "#download-evidence-analysis",
      "moonground-evidence-analysis-results.json",
    );
    assert.deepEqual(
      resumedEvidenceJoint.frames,
      evidenceJoint.frames.slice(3),
    );
    assert.deepEqual(resumedEvidenceJoint.checkpoint, evidenceJoint.checkpoint);
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#download").isDisabled(), true);
    // Ground mode uses the same independent joint view and directional
    // covariance evidence, even before ordinary measurements are calculated.
    await page.locator("#source").fill(directionalSource);
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration));
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已联合计算 3 帧"),
    );
    const groundEvidenceJoint = await exportJson(
      "#download-evidence-analysis",
      "moonground-evidence-analysis-results.json",
    );
    assert.deepEqual(
      groundEvidenceJoint.frames.map((frame) => frame.measurement),
      directionalMeasurement.frames,
    );
    assert.deepEqual(
      groundEvidenceJoint.frames.map((frame) => frame.counting),
      directional.frames,
    );
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    assert.equal(await page.locator("#download").isDisabled(), true);
    // Both numeric source layers reach core unchanged. Neither nested capacity
    // tokens nor frame identity tokens are rounded through JavaScript parsing.
    await page.locator("#evidence-input").fill(rawEvidenceSources[0]);
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#evidence-message").classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration));
    await page
      .locator("#source")
      .fill(
        directionalSource.replace(
          '"track_id":1',
          '"track_id":1.0000000000000001',
        ),
      );
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#evidence-message").classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );
    // Evidence geometry can fail after the first measurement is valid. The
    // failed joint batch preserves the already displayed ordinary result.
    const jointGeometrySource =
      '{"session_id":"joint-evidence-geometry","mode":"ground"}\n{"timestamp_us":"0","observations":[{"track_id":1,"point":[-1e308,0],"covariance":[1,0,1]}]}\n';
    await page.locator("#source").fill(jointGeometrySource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    const beforeJointGeometryFailure = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#evidence-input").fill(
      JSON.stringify({
        counting: JSON.stringify({
          session_id: "joint-evidence-geometry",
          gates: [
            {
              gate_id: "extreme",
              start_m: [1e308, 0],
              end_m: [1e308, 1],
              deadband_m: 0,
            },
          ],
        }),
        sigma_multiplier: 2,
      }),
    );
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document.querySelector("#evidence-message").classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      beforeJointGeometryFailure,
    );
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );
    // New independent choice cancels old joint preparation, and the reverse
    // choice is equally explicit. Neither older callback may overwrite it.
    await page.locator("#source").fill(directionalSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 3 帧"),
    );
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration));
    for (const older of ["joint", "independent"]) {
      await page.evaluate(() => {
        const original = window.setTimeout;
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseJointEvidenceRun = () => callback(...args);
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
      await page
        .locator(older === "joint" ? "#evidence-analyze" : "#evidence-ordinary")
        .click();
      await page.waitForFunction(
        () => typeof window.releaseJointEvidenceRun === "function",
      );
      await page
        .locator(older === "joint" ? "#evidence-ordinary" : "#evidence-analyze")
        .click();
      await page.waitForFunction(
        (joint) =>
          document
            .querySelector("#evidence-message")
            .textContent.includes(joint ? "已联合计算 3 帧" : "已处理 3 帧"),
        older !== "joint",
      );
      await page.evaluate(() => {
        window.releaseJointEvidenceRun();
        delete window.releaseJointEvidenceRun;
      });
      assert.equal(await page.locator("#evidence-message.error").count(), 0);
      assert.equal(
        await page.locator("#download-evidence-analysis").isDisabled(),
        older === "joint",
      );
      assert.equal(
        await page.locator("#download-evidence").isDisabled(),
        older !== "joint",
      );
    }
    assert.deepEqual(
      await exportJson(
        "#download-evidence-analysis",
        "moonground-evidence-analysis-results.json",
      ),
      groundEvidenceJoint,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      directionalMeasurement,
    );
    // A later source edit cancels an asynchronous full checkpoint import.
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "joint-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseJointEvidenceRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page.locator("#evidence-analysis-checkpoint-file").setInputFiles({
      name: "joint-late.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceJointCheckpoint)),
    });
    await page.waitForFunction(
      () => typeof window.releaseJointEvidenceRead === "function",
    );
    await page.locator("#source").fill(directionalSource + " ");
    await page.evaluate(() => {
      window.releaseJointEvidenceRead();
      delete window.releaseJointEvidenceRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-analysis-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      directionalSource + " ",
    );
    assert.equal(
      await page.locator("#evidence-input").inputValue(),
      JSON.stringify(directionalConfiguration),
    );
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );
    // Configuration edits also cancel a prepared raw joint request.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseJointEvidenceEdit = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseJointEvidenceEdit === "function",
    );
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration) + " ");
    await page.evaluate(() => {
      window.releaseJointEvidenceEdit();
      delete window.releaseJointEvidenceEdit;
    });
    assert.equal(
      await page.locator("#download-evidence-analysis").isDisabled(),
      true,
    );

    // Three-party evidence uses the shared raw input with its own protocol,
    // result, playback and checkpoint. It never selects another result slot.
    await page.locator("#source").fill(directionalSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 3 帧"),
    );
    await page
      .locator("#evidence-input")
      .fill(JSON.stringify(directionalConfiguration));
    await page.locator("#evidence-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-message")
        .textContent.includes("已联合计算 3 帧"),
    );
    await page.locator("#guarded-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-message")
        .textContent.includes("已完成 16 帧"),
    );
    const beforeThreePartyLegacy = await exportJson(
      "#download-guarded",
      "moonground-guarded-results.json",
    );
    const beforeThreePartyLegacyInput = await page
      .locator("#guarded-input")
      .inputValue();
    await page.locator("#evidence-guarded-section").evaluate((details) => {
      details.open = true;
    });
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      beforeThreePartyLegacyInput,
    );
    assert.deepEqual(
      await exportJson("#download-guarded", "moonground-guarded-results.json"),
      beforeThreePartyLegacy,
    );
    const threePartySource = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "evidence-guarded.ndjson"),
      "utf8",
    );
    const threePartyLines = threePartySource.trimEnd().split("\n");
    await page.locator("#evidence-guarded-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 16 帧三方证据分析"),
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      threePartySource,
    );
    const threeParty = await exportJson(
      "#download-evidence-guarded",
      "moonground-evidence-guarded-results.json",
    );
    assert.equal(threeParty.checkpoint.format, "moonground.evidence-guarded");
    assert.equal(threeParty.frames.length, 16);
    threeParty.frames.forEach((frame, index) => {
      assert.equal(
        frame.kind,
        index === 9
          ? "evidence_guarded_projection_replaced"
          : "evidence_guarded_frame",
      );
      assert.equal(frame.decision, projection.frames[index].decision);
      assert.deepEqual(frame.health, projection.frames[index].health);
      assert.deepEqual(
        frame.analysis.measurement,
        projection.frames[index].analysis.measurement,
      );
      assert.equal(frame.analysis.counting.sigma_multiplier, 2);
      if (frame.decision === "blocked") {
        assert.deepEqual(frame.analysis.counting.evidence, []);
        assert.deepEqual(frame.analysis.measurement.tracks, []);
      }
    });
    assert.deepEqual(
      threeParty.frames[6].analysis.measurement.closed_segment_ids,
      ["1"],
    );
    assert.equal(threeParty.frames[9].health.status, "insufficient");
    assert.equal(
      threeParty.frames[12].analysis.measurement.tracks[0].segment_id,
      "2",
    );
    assert.equal(
      threeParty.frames[12].analysis.measurement.tracks[0].speed_mps,
      null,
    );
    assert.equal(
      threeParty.frames[15].analysis.counting.counting.counts[0]
        .positive_to_negative,
      "2",
    );
    assert.equal(
      threeParty.checkpoint.analysis.measurement.motion.last_timestamp_us,
      "1550000",
    );
    assert.deepEqual(
      threeParty.checkpoint.analysis.measurement.configuration.calibration,
      threeParty.checkpoint.health.configuration.calibration,
    );
    assert.deepEqual(
      threeParty.checkpoint.analysis.measurement.configuration.camera,
      threeParty.checkpoint.health.configuration.camera,
    );
    assert.equal(await page.locator("#download-guarded").isDisabled(), true);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      directionalMeasurement,
    );
    assert.deepEqual(
      await exportJson(
        "#download-evidence-analysis",
        "moonground-evidence-analysis-results.json",
      ),
      groundEvidenceJoint,
    );
    const threePartySetFrame = async (index) => {
      await page.locator("#evidence-guarded-frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    };
    await threePartySetFrame(9);
    assert.match(
      await page.locator("#evidence-guarded-status").textContent(),
      /950000.*切换标定/,
    );
    assert.match(
      await page.locator("#evidence-guarded-policy").textContent(),
      /关闭旧片段.*重新确认/,
    );
    const threePartyCheckpoint = await exportJson(
      "#save-evidence-guarded-checkpoint",
      "moonground-evidence-guarded-checkpoint.json",
    );
    assert.equal(threePartyCheckpoint.health.state.last_timestamp_us, "950000");
    assert.equal(
      threePartyCheckpoint.analysis.measurement.motion.last_timestamp_us,
      "950000",
    );
    assert.equal(
      threePartyCheckpoint.analysis.counting.state.last_timestamp_us,
      "950000",
    );
    assert.deepEqual(threePartyCheckpoint.analysis.counting.state.tracks, []);
    assert.equal(threePartyCheckpoint.health.state.streak, null);
    assert.equal(await page.locator("#evidence-joint-frame").inputValue(), "2");
    assert.equal(await page.locator("#counter").textContent(), "1 / 3");
    await page.locator("#evidence-guarded-section").evaluate((details) => {
      details.open = false;
    });
    await threePartySetFrame(12);
    assert.equal(await page.locator("#evidence-guarded-rows tr").count(), 0);
    await page.locator("#evidence-guarded-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-guarded-rows").children.length > 0,
    );
    assert.equal(await page.locator("#evidence-guarded-rows tr").count(), 1);
    // A selection change while the prefix replay is preparing cancels that
    // download; the saved file must always match the visible selected frame.
    await page.evaluate(() => {
      const original = window.setTimeout;
      window.setTimeout = function (callback, delay, ...args) {
        if (delay === 0) {
          window.setTimeout = original;
          window.releaseThreePartySave = () => callback(...args);
          return -1;
        }
        return original.call(window, callback, delay, ...args);
      };
    });
    let cancelledThreePartyDownloads = 0;
    const countCancelledThreePartyDownload = () => {
      cancelledThreePartyDownloads++;
    };
    page.on("download", countCancelledThreePartyDownload);
    await page.locator("#save-evidence-guarded-checkpoint").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartySave === "function",
    );
    await threePartySetFrame(14);
    await page.evaluate(() => {
      window.releaseThreePartySave();
      delete window.releaseThreePartySave;
    });
    await page.waitForFunction(
      () =>
        !document.querySelector("#save-evidence-guarded-checkpoint").disabled,
    );
    page.off("download", countCancelledThreePartyDownload);
    assert.equal(cancelledThreePartyDownloads, 0);
    await threePartySetFrame(13);
    assert.equal(await page.locator("#evidence-guarded-events li").count(), 1);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#evidence-guarded-section").screenshot({
      path: path.join(directory, "evidence-guarded-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#evidence-guarded-section").screenshot({
      path: path.join(directory, "evidence-guarded-desktop-preview.png"),
    });
    // Complete raw checkpoints are validated before changing any input. Every
    // owner and confidence anchor is checked, including exact integer tokens.
    const invalidThreePartyCheckpoints = [];
    const threePartyClone = () =>
      JSON.parse(JSON.stringify(threeParty.checkpoint));
    const threePartyBadVersion = threePartyClone();
    threePartyBadVersion.checkpoint_version = "999";
    invalidThreePartyCheckpoints.push(JSON.stringify(threePartyBadVersion));
    const threePartyBadTime = threePartyClone();
    threePartyBadTime.health.state.last_timestamp_us = "1550001";
    invalidThreePartyCheckpoints.push(JSON.stringify(threePartyBadTime));
    const threePartyBadCovariance = threePartyClone();
    threePartyBadCovariance.analysis.counting.state.tracks[0].anchors[0].covariance =
      [1, 2, 1];
    invalidThreePartyCheckpoints.push(JSON.stringify(threePartyBadCovariance));
    const threePartyBadProjection = threePartyClone();
    threePartyBadProjection.health.configuration.calibration.matrix[2] += 1;
    invalidThreePartyCheckpoints.push(JSON.stringify(threePartyBadProjection));
    invalidThreePartyCheckpoints.push(
      JSON.stringify(threeParty.checkpoint).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
    );
    invalidThreePartyCheckpoints.push(
      JSON.stringify(beforeThreePartyLegacy.checkpoint),
    );
    for (const rawCheckpoint of invalidThreePartyCheckpoints) {
      await page.locator("#evidence-guarded-checkpoint-file").setInputFiles({
        name: "invalid-three-party.json",
        mimeType: "application/json",
        buffer: Buffer.from(rawCheckpoint),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-guarded-checkpoint-file").value ===
          "",
      );
      assert.equal(
        await page.locator("#evidence-guarded-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        threePartySource,
      );
      assert.deepEqual(
        await exportJson(
          "#download-evidence-guarded",
          "moonground-evidence-guarded-results.json",
        ),
        threeParty,
      );
    }
    const threePartyFirst = JSON.parse(threePartyLines[1]);
    const threePartyBadTimeFrame = {
      ...threePartyFirst,
      health: threePartyFirst.health.replace(
        '"timestamp_us":"0"',
        '"timestamp_us":"1"',
      ),
    };
    const threePartyBadIdentity = {
      ...threePartyFirst,
      measurement: threePartyFirst.measurement.replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
    };
    const threePartyDuplicate = {
      ...threePartyFirst,
      measurement: threePartyFirst.measurement.replace(
        '"track_id":1',
        '"track_id":1,"track_id":1',
      ),
    };
    const threePartyRawHeader = JSON.parse(threePartyLines[0]);
    const threePartyRawAnalysis = JSON.parse(threePartyRawHeader.analysis);
    const threePartyFractionalConfiguration = JSON.stringify({
      ...threePartyRawHeader,
      analysis: JSON.stringify({
        ...threePartyRawAnalysis,
        measurement: threePartyRawAnalysis.measurement.replace(
          '"max_tracks":10',
          '"max_tracks":10.0000000000000001',
        ),
      }),
    });
    const invalidThreePartyInputs = [
      threePartyFractionalConfiguration + "\n" + threePartyLines[1] + "\n",
      threePartyLines[0] +
        "\n" +
        JSON.stringify({ ...threePartyFirst, unknown: true }) +
        "\n",
      threePartyLines[0] + "\n" + JSON.stringify(threePartyBadTimeFrame) + "\n",
      threePartyLines[0] + "\n" + JSON.stringify(threePartyBadIdentity) + "\n",
      threePartyLines[0] + "\n" + JSON.stringify(threePartyDuplicate) + "\n",
      ...badProjectionOperations.map(
        (operation) =>
          threePartyLines.slice(0, 10).join("\n") + "\n" + operation + "\n",
      ),
    ];
    for (const rawInput of invalidThreePartyInputs) {
      await page.locator("#evidence-guarded-file").setInputFiles({
        name: "invalid-three-party.ndjson",
        mimeType: "application/x-ndjson",
        buffer: Buffer.from(rawInput),
      });
      await page.waitForFunction(
        () => document.querySelector("#evidence-guarded-file").value === "",
      );
      assert.equal(
        await page.locator("#evidence-guarded-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        threePartySource,
      );
    }
    assert.deepEqual(
      await exportJson(
        "#download-evidence-guarded",
        "moonground-evidence-guarded-results.json",
      ),
      threeParty,
    );
    // Resume exactly at the selected replacement barrier, not the batch end.
    await page.locator("#evidence-guarded-checkpoint-file").setInputFiles({
      name: "three-party.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(threePartyCheckpoint)),
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-guarded-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#evidence-guarded-message.error").count(),
      0,
    );
    const threePartyResume = await page.locator("#guarded-input").inputValue();
    assert.deepEqual(JSON.parse(threePartyResume).resume, threePartyCheckpoint);
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#evidence-input").inputValue(),
      JSON.stringify(directionalConfiguration),
    );
    await page
      .locator("#guarded-input")
      .fill(threePartyResume + threePartyLines.slice(11).join("\n") + "\n");
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 6 帧三方证据分析"),
    );
    const threePartyResumed = await exportJson(
      "#download-evidence-guarded",
      "moonground-evidence-guarded-results.json",
    );
    assert.deepEqual(threePartyResumed.frames, threeParty.frames.slice(10));
    assert.deepEqual(threePartyResumed.checkpoint, threeParty.checkpoint);
    const threePartyFinalCheckpoint = await exportJson(
      "#save-evidence-guarded-checkpoint",
      "moonground-evidence-guarded-checkpoint.json",
    );
    assert.deepEqual(threePartyFinalCheckpoint, threeParty.checkpoint);
    // Independent config and ordinary source edits are unrelated to this
    // complete three-party header; editing the shared raw source invalidates it.
    await page
      .locator("#evidence-input")
      .fill("three-party does not use this configuration");
    await page.locator("#source").fill("unrelated ordinary draft");
    assert.deepEqual(
      await exportJson(
        "#download-evidence-guarded",
        "moonground-evidence-guarded-results.json",
      ),
      threePartyResumed,
    );
    await page.locator("#guarded-input").fill(threePartySource);
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    // Preparation is intentionally yielded once. A valid new file must replace
    // the pending run rather than being silently ignored by a busy flag.
    const holdThreePartyPreparation = async () =>
      page.evaluate(() => {
        const original = window.setTimeout;
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseThreePartyRun = () => callback(...args);
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
    const releaseThreePartyPreparation = async () =>
      page.evaluate(() => {
        window.releaseThreePartyRun();
        delete window.releaseThreePartyRun;
      });
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    const replacementThreePartySource = threePartySource.replaceAll(
      "warehouse-landmarks",
      "replacement-evidence-monitor",
    );
    await page.locator("#evidence-guarded-file").setInputFiles({
      name: "replacement-three-party.ndjson",
      mimeType: "application/x-ndjson",
      buffer: Buffer.from(replacementThreePartySource),
    });
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 16 帧三方证据分析"),
    );
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      replacementThreePartySource,
    );
    const replacementThreeParty = await exportJson(
      "#download-evidence-guarded",
      "moonground-evidence-guarded-results.json",
    );
    assert.equal(
      replacementThreeParty.frames[0].health.monitor_id,
      "replacement-evidence-monitor",
    );
    assert.equal(
      await page.locator("#run-evidence-guarded").isDisabled(),
      false,
    );
    // Old and new shared-input operations cancel each other's pending work.
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await page.locator("#guarded-example").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#guarded-input")
        .value.includes("guarded-warehouse"),
    );
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      beforeThreePartyLegacyInput,
    );
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    await holdThreePartyPreparation();
    await page.locator("#run-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await page.locator("#evidence-guarded-example").click();
    await page.waitForFunction(
      (expected) => document.querySelector("#guarded-input").value === expected,
      threePartySource,
    );
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 16 帧三方证据分析"),
    );
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      threePartySource,
    );
    assert.deepEqual(
      await exportJson(
        "#download-evidence-guarded",
        "moonground-evidence-guarded-results.json",
      ),
      threeParty,
    );
    // Late sample fetch and checkpoint file reads cannot overwrite a draft.
    let releaseThreePartySample;
    let threePartySampleRequested;
    const threePartySampleGate = new Promise((resolve) => {
      releaseThreePartySample = resolve;
    });
    const threePartySampleRequest = new Promise((resolve) => {
      threePartySampleRequested = resolve;
    });
    await page.route("**/evidence-guarded.ndjson", async (route) => {
      threePartySampleRequested();
      await threePartySampleGate;
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: threePartySource,
      });
    });
    try {
      await page.locator("#evidence-guarded-example").click();
      await threePartySampleRequest;
      await page.locator("#guarded-input").fill("newer three-party draft");
      const sampleResponse = page.waitForResponse((response) =>
        response.url().endsWith("/evidence-guarded.ndjson"),
      );
      releaseThreePartySample();
      await (await sampleResponse).finished();
      await page.waitForLoadState("networkidle");
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        "newer three-party draft",
      );
      assert.equal(
        await page.locator("#download-evidence-guarded").isDisabled(),
        true,
      );
    } finally {
      releaseThreePartySample();
      await page.unroute("**/evidence-guarded.ndjson");
    }
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "three-party-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseThreePartyRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page.locator("#evidence-guarded-checkpoint-file").setInputFiles({
      name: "three-party-late.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(threeParty.checkpoint)),
    });
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRead === "function",
    );
    await page.locator("#guarded-input").fill("newer checkpoint draft");
    await page.evaluate(() => {
      window.releaseThreePartyRead();
      delete window.releaseThreePartyRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-guarded-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      "newer checkpoint draft",
    );
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );

    // Evidence transit is a detached downstream owner. Both its gate policy
    // and its selected measurement source are explicit and independent.
    await page.locator("#evidence-transit-section").evaluate((details) => {
      details.open = true;
    });
    const evidenceTransitConfig = fs.readFileSync(
      path.resolve(__dirname, "..", "examples", "evidence-transit-source.json"),
      "utf8",
    );
    const evidenceTransitFresh = JSON.parse(evidenceTransitConfig);
    const evidenceTransitPolicy = JSON.parse(evidenceTransitFresh.counting);
    await page.locator("#evidence-transit-example").click();
    await page.waitForFunction(
      (expected) =>
        document.querySelector("#evidence-transit-input").value === expected,
      evidenceTransitConfig,
    );
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    const evidenceTransitBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#transit-input").fill(transitConfiguration);
    await page.locator("#transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-message")
        .textContent.includes("已处理 10 帧"),
    );
    const legacyBeforeEvidenceTransit = await exportJson(
      "#download-transit",
      "moonground-transit-results.json",
    );
    const waitEvidenceTransit = async (frames) =>
      page.waitForFunction(
        (count) =>
          document
            .querySelector("#evidence-transit-message")
            .textContent.includes(`已处理 ${count} 帧`),
        frames,
      );
    const exportEvidenceTransit = () =>
      exportJson(
        "#download-evidence-transit",
        "moonground-evidence-transit-results.json",
      );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    const evidenceTransit = await exportEvidenceTransit();
    assert.equal(
      evidenceTransit.checkpoint.format,
      "moonground.evidence-transit",
    );
    assert.equal(
      evidenceTransit.checkpoint.counting.format,
      "moonground.gate-evidence",
    );
    assert.equal(evidenceTransit.frames.length, 10);
    evidenceTransit.frames.forEach((frame) => {
      assert.equal(frame.kind, "evidence_transit_frame");
      assert.equal(frame.counting.sigma_multiplier, 2);
    });
    assert.equal(
      evidenceTransit.frames[1].counting.evidence.find(
        (value) => value.gate_id === "entry",
      ).side,
      "unconfirmed",
    );
    assert.equal(evidenceTransit.frames[2].pending_count, 1);
    assert.deepEqual(evidenceTransit.frames.at(-1).counts, [
      { section_id: "aisle", completed: "1" },
    ]);
    const evidenceTransitPassageIndex = evidenceTransit.frames.findIndex(
      (frame) => frame.passages.length,
    );
    assert.equal(evidenceTransitPassageIndex, 4);
    const evidenceTransitPassage = evidenceTransit.frames[4].passages[0];
    assert.equal(evidenceTransitPassage.entry.from_timestamp_us, "0");
    assert.equal(evidenceTransitPassage.entry.to_timestamp_us, "400000");
    assert.equal(evidenceTransitPassage.exit.from_timestamp_us, "400000");
    assert.equal(evidenceTransitPassage.exit.to_timestamp_us, "800000");
    assert.equal(evidenceTransitPassage.elapsed_lower_us, "0");
    assert.equal(evidenceTransitPassage.elapsed_upper_us, "800000");
    assert.equal(Object.hasOwn(evidenceTransitPassage, "speed_mps"), false);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      evidenceTransitBase,
    );
    assert.deepEqual(
      await exportJson("#download-transit", "moonground-transit-results.json"),
      legacyBeforeEvidenceTransit,
    );
    const setEvidenceTransitOrdinaryFrame = async (index) =>
      page.locator("#frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await setEvidenceTransitOrdinaryFrame(1);
    assert.match(
      await page.locator("#evidence-transit-rows").textContent(),
      /侧别未确认/,
    );
    await setEvidenceTransitOrdinaryFrame(4);
    assert.match(
      await page.locator("#evidence-transit-source").textContent(),
      /普通测量.*5 \/ 10.*800000/,
    );
    assert.match(
      await page.locator("#evidence-transit-policy").textContent(),
      /k = 2/,
    );
    assert.match(
      await page.locator("#evidence-transit-passages").textContent(),
      /\[0, 800000\]/,
    );
    const evidenceTransitCheckpoint = await exportJson(
      "#save-evidence-transit-checkpoint",
      "moonground-evidence-transit-checkpoint.json",
    );
    assert.equal(
      evidenceTransitCheckpoint.counting.state.last_timestamp_us,
      "1800000",
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#evidence-transit-section").screenshot({
      path: path.join(directory, "evidence-transit-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#evidence-transit-section").screenshot({
      path: path.join(directory, "evidence-transit-desktop-preview.png"),
    });
    // Core applies k=2 when omitted; the browser never supplies or recomputes it.
    const evidenceTransitDefault = {
      ...evidenceTransitFresh,
      counting: JSON.stringify({ counting: evidenceTransitPolicy.counting }),
    };
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(evidenceTransitDefault));
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    // A mismatched but otherwise valid source is a failed new request. It
    // preserves the successful existing result and its original source binding.
    await page.locator("#evidence-guarded-example").click();
    await page.waitForFunction(
      (expected) => document.querySelector("#guarded-input").value === expected,
      threePartySource,
    );
    await page.locator("#evidence-transit-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-transit-message")
        .classList.contains("error"),
    );
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    const invalidEvidenceTransitSaved = JSON.parse(
      JSON.stringify(evidenceTransitCheckpoint),
    );
    invalidEvidenceTransitSaved.checkpoint_version = "999";
    const invalidEvidenceTransitAnchor = JSON.parse(
      JSON.stringify(evidenceTransitCheckpoint),
    );
    invalidEvidenceTransitAnchor.counting.state.tracks[0].anchors[0].covariance =
      [1, 2, 1];
    for (const checkpoint of [
      invalidEvidenceTransitSaved,
      invalidEvidenceTransitAnchor,
      legacyBeforeEvidenceTransit.checkpoint,
    ]) {
      await page.locator("#evidence-transit-checkpoint-file").setInputFiles({
        name: "invalid-evidence-transit.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(checkpoint)),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-transit-checkpoint-file").value ===
          "",
      );
      assert.equal(
        await page.locator("#evidence-transit-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        JSON.stringify(evidenceTransitDefault),
      );
      assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    }
    // Exact nested numeric tokens remain raw until core validation.
    const evidenceTransitFractional = {
      ...evidenceTransitFresh,
      counting: JSON.stringify({
        ...evidenceTransitPolicy,
        counting: evidenceTransitPolicy.counting.replace(
          '"max_tracks":1000',
          '"max_tracks":1000.0000000000000001',
        ),
      }),
    };
    const evidenceTransitDuplicate = {
      ...evidenceTransitFresh,
      counting:
        '{"counting":' +
        JSON.stringify(evidenceTransitPolicy.counting) +
        ',"sigma_multiplier":2,"sigma_multiplier":0}',
    };
    for (const configuration of [
      evidenceTransitFractional,
      evidenceTransitDuplicate,
      JSON.parse(transitConfiguration),
    ]) {
      await page
        .locator("#evidence-transit-input")
        .fill(JSON.stringify(configuration));
      await page.locator("#evidence-transit-ordinary").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#evidence-transit-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#download-evidence-transit").isDisabled(),
        true,
      );
      assert.equal(await page.locator("#download").isDisabled(), false);
      assert.equal(await page.locator("#download-transit").isDisabled(), false);
    }
    // Save a confirmed entry and both endpoint covariances before the exit.
    const evidenceTransitWarehouseLines = warehouseInput.trimEnd().split("\n");
    await page
      .locator("#source")
      .fill(evidenceTransitWarehouseLines.slice(0, 4).join("\n") + "\n");
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 3 帧"),
    );
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(3);
    const evidenceTransitPrefix = await exportEvidenceTransit();
    assert.equal(evidenceTransitPrefix.frames.at(-1).pending_count, 1);
    const evidenceTransitPendingCheckpoint = await exportJson(
      "#save-evidence-transit-checkpoint",
      "moonground-evidence-transit-checkpoint.json",
    );
    assert.equal(
      evidenceTransitPendingCheckpoint.counting.state.last_timestamp_us,
      "400000",
    );
    assert.equal(evidenceTransitPendingCheckpoint.pending.length, 1);
    assert.deepEqual(
      evidenceTransitPendingCheckpoint.pending[0].from_covariance,
      evidenceTransitBase.frames[0].tracks[0].position_covariance,
    );
    assert.deepEqual(
      evidenceTransitPendingCheckpoint.pending[0].to_covariance,
      evidenceTransitBase.frames[2].tracks[0].position_covariance,
    );
    await setEvidenceTransitOrdinaryFrame(2);
    const evidenceTransitMotionCheckpoint = await exportJson(
      "#save-checkpoint",
      "moonground-checkpoint.json",
    );
    assert.equal(
      evidenceTransitMotionCheckpoint.motion.last_timestamp_us,
      "400000",
    );
    const invalidEvidenceTransitPending = [];
    const evidenceTransitMissingCovariance = JSON.parse(
      JSON.stringify(evidenceTransitPendingCheckpoint),
    );
    delete evidenceTransitMissingCovariance.pending[0].from_covariance;
    invalidEvidenceTransitPending.push(evidenceTransitMissingCovariance);
    const evidenceTransitIndefiniteCovariance = JSON.parse(
      JSON.stringify(evidenceTransitPendingCheckpoint),
    );
    evidenceTransitIndefiniteCovariance.pending[0].to_covariance = [1, 2, 1];
    invalidEvidenceTransitPending.push(evidenceTransitIndefiniteCovariance);
    const evidenceTransitUnconfirmedCovariance = JSON.parse(
      JSON.stringify(evidenceTransitPendingCheckpoint),
    );
    evidenceTransitUnconfirmedCovariance.pending[0].from_covariance = [
      1000000, 0, 1000000,
    ];
    invalidEvidenceTransitPending.push(evidenceTransitUnconfirmedCovariance);
    for (const checkpoint of invalidEvidenceTransitPending) {
      await page.locator("#evidence-transit-checkpoint-file").setInputFiles({
        name: "invalid-pending-evidence-transit.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(checkpoint)),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-transit-checkpoint-file").value ===
          "",
      );
      assert.equal(
        await page.locator("#evidence-transit-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        evidenceTransitConfig,
      );
      assert.deepEqual(await exportEvidenceTransit(), evidenceTransitPrefix);
    }
    const evidenceTransitSourceBeforeImport = await page
      .locator("#source")
      .inputValue();
    const evidenceTransitGuardedBeforeImport = await page
      .locator("#guarded-input")
      .inputValue();
    await page.locator("#evidence-transit-checkpoint-file").setInputFiles({
      name: "pending-evidence-transit.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceTransitPendingCheckpoint)),
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#evidence-transit-message.error").count(),
      0,
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      evidenceTransitSourceBeforeImport,
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      evidenceTransitGuardedBeforeImport,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#evidence-transit-input").inputValue())
        .resume,
      evidenceTransitPendingCheckpoint,
    );
    // The selected upstream still contains old frames. Core must reject it;
    // silently filtering to the imported watermark would hide an invalid flow.
    await page.locator("#evidence-transit-ordinary").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-transit-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    await page
      .locator("#source")
      .fill(
        JSON.stringify({ resume: evidenceTransitMotionCheckpoint }) +
          "\n" +
          evidenceTransitWarehouseLines.slice(4).join("\n") +
          "\n",
      );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(7);
    const evidenceTransitResumed = await exportEvidenceTransit();
    assert.deepEqual(
      evidenceTransitResumed.frames,
      evidenceTransit.frames.slice(3),
    );
    assert.deepEqual(
      evidenceTransitResumed.checkpoint,
      evidenceTransit.checkpoint,
    );
    // Health and replacement barriers cancel confirmed entries without joining
    // two segments or inventing a passage through the blocked interval.
    const evidenceTransitGuardedGates = JSON.parse(
      evidenceTransitPolicy.counting,
    );
    evidenceTransitGuardedGates.session_id = "projection-replace-warehouse";
    evidenceTransitGuardedGates.gates.forEach((gate, index) => {
      gate.start_m[0] = [6.2, 6.9][index];
      gate.end_m[0] = [6.2, 6.9][index];
    });
    const evidenceTransitGuardedConfig = {
      ...evidenceTransitFresh,
      counting: JSON.stringify({
        counting: JSON.stringify(evidenceTransitGuardedGates),
        sigma_multiplier: 2,
      }),
    };
    const evidenceTransitGuardedSource =
      threePartySource +
      JSON.stringify({
        replace_projection: JSON.stringify(secondReplacement),
      }) +
      "\n";
    await page.locator("#guarded-input").fill(evidenceTransitGuardedSource);
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 17 帧三方证据分析"),
    );
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(evidenceTransitGuardedConfig));
    await page.locator("#evidence-transit-guarded").click();
    await waitEvidenceTransit(17);
    const evidenceTransitGuarded = await exportEvidenceTransit();
    assert.equal(evidenceTransitGuarded.frames[3].pending_count, 1);
    assert.equal(evidenceTransitGuarded.frames[6].pending_count, 0);
    assert.equal(
      evidenceTransitGuarded.frames[6].cancellations[0].reason,
      "discontinuity",
    );
    assert.equal(
      evidenceTransitGuarded.frames[9].counting.counting.timestamp_us,
      "950000",
    );
    assert.deepEqual(evidenceTransitGuarded.frames[9].counting.evidence, []);
    assert.equal(evidenceTransitGuarded.frames[13].pending_count, 1);
    assert.equal(
      evidenceTransitGuarded.frames[16].cancellations[0].reason,
      "discontinuity",
    );
    assert.equal(
      evidenceTransitGuarded.frames[16].cancellations[0].segment_id,
      "2",
    );
    assert.deepEqual(evidenceTransitGuarded.frames.at(-1).counts, [
      { section_id: "aisle", completed: "0" },
    ]);
    assert.deepEqual(evidenceTransitGuarded.checkpoint.pending, []);
    await threePartySetFrame(6);
    assert.match(
      await page.locator("#evidence-transit-source").textContent(),
      /三方证据门控.*7 \/ 17/,
    );
    assert.match(
      await page.locator("#evidence-transit-cancellations").textContent(),
      /观测中断/,
    );
    const evidenceTransitGuardedCheckpoint = await exportJson(
      "#save-evidence-transit-checkpoint",
      "moonground-evidence-transit-checkpoint.json",
    );
    assert.equal(
      evidenceTransitGuardedCheckpoint.counting.state.last_timestamp_us,
      "1600000",
    );
    await page.locator("#evidence-input").fill("independent evidence draft");
    await page.locator("#transit-input").fill("independent old transit draft");
    await page.locator("#source").fill("unrelated ordinary draft");
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransitGuarded);
    await page
      .locator("#guarded-input")
      .fill(evidenceTransitGuardedSource + " ");
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    // New source choices supersede older work, and invalidation is scoped to
    // each captured source, including when an older display belongs elsewhere.
    const holdEvidenceTransitPreparation = async () =>
      page.evaluate(() => {
        const original = window.setTimeout;
        window.setTimeout = function (callback, delay, ...args) {
          if (delay === 0) {
            window.setTimeout = original;
            window.releaseEvidenceTransitRun = () => callback(...args);
            return -1;
          }
          return original.call(window, callback, delay, ...args);
        };
      });
    const releaseEvidenceTransitPreparation = async () =>
      page.evaluate(() => {
        window.releaseEvidenceTransitRun();
        delete window.releaseEvidenceTransitRun;
      });
    await page.locator("#example").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    const evidenceTransitSameSessionSource = threePartySource.replaceAll(
      "projection-replace-warehouse",
      "warehouse-example",
    );
    await page.locator("#guarded-input").fill(evidenceTransitSameSessionSource);
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 16 帧三方证据分析"),
    );
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    // Clearing the older ordinary display must not cancel the newer valid
    // three-party request waiting to commit.
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#source").fill(warehouseInput + " ");
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    await releaseEvidenceTransitPreparation();
    await waitEvidenceTransit(16);
    const evidenceTransitOtherOrigin = await exportEvidenceTransit();
    assert.equal(evidenceTransitOtherOrigin.frames.length, 16);
    assert.equal(
      await page.locator("#evidence-transit-message.error").count(),
      0,
    );
    // A pending ordinary request likewise survives clearing the older guarded
    // display, while invalidating its own source cancels it.
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#guarded-input")
      .fill(evidenceTransitSameSessionSource + " ");
    await releaseEvidenceTransitPreparation();
    await waitEvidenceTransit(10);
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    await page.locator("#guarded-input").fill(evidenceTransitSameSessionSource);
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-message")
        .textContent.includes("已完成 16 帧三方证据分析"),
    );
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#guarded-input")
      .fill(evidenceTransitSameSessionSource + "  ");
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#evidence-transit-input")
      .fill(evidenceTransitConfig + " ");
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#download").isDisabled(), false);
    // A valid imported checkpoint supersedes a pending computation immediately.
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-ordinary").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#evidence-transit-checkpoint-file").setInputFiles({
      name: "replacement-evidence-transit.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceTransitPendingCheckpoint)),
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#evidence-transit-message.error").count(),
      0,
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(
      JSON.parse(await page.locator("#evidence-transit-input").inputValue())
        .resume,
      evidenceTransitPendingCheckpoint,
    );
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    // A late complete checkpoint read and an example response both yield to a
    // newer raw configuration draft rather than replacing it after validation.
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "evidence-transit-late.json")
          return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseEvidenceTransitRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page.locator("#evidence-transit-checkpoint-file").setInputFiles({
      name: "evidence-transit-late.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(evidenceTransitCheckpoint)),
    });
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRead === "function",
    );
    await page
      .locator("#evidence-transit-input")
      .fill("newer evidence transit draft");
    await page.evaluate(() => {
      window.releaseEvidenceTransitRead();
      delete window.releaseEvidenceTransitRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-checkpoint-file").value ===
        "",
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      "newer evidence transit draft",
    );
    let releaseEvidenceTransitExample;
    let evidenceTransitExampleRequested;
    const evidenceTransitExampleGate = new Promise((resolve) => {
      releaseEvidenceTransitExample = resolve;
    });
    const evidenceTransitExampleRequest = new Promise((resolve) => {
      evidenceTransitExampleRequested = resolve;
    });
    await page.route("**/evidence-transit-source.json", async (route) => {
      evidenceTransitExampleRequested();
      await evidenceTransitExampleGate;
      await route.fulfill({
        contentType: "application/json",
        body: evidenceTransitConfig,
      });
    });
    try {
      await page.locator("#evidence-transit-example").click();
      await evidenceTransitExampleRequest;
      await page
        .locator("#evidence-transit-input")
        .fill("newer example configuration draft");
      const exampleResponse = page.waitForResponse((response) =>
        response.url().endsWith("/evidence-transit-source.json"),
      );
      releaseEvidenceTransitExample();
      await (await exampleResponse).finished();
      await page.waitForLoadState("networkidle");
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        "newer example configuration draft",
      );
    } finally {
      releaseEvidenceTransitExample();
      await page.unroute("**/evidence-transit-source.json");
    }

    // Atomic raw-observation transit has its own result slot and cursor; the
    // independent consumer remains available through the explicit mode switch.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    const beforeTransitJointIndependent = await exportEvidenceTransit();
    const beforeTransitJointBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const waitTransitJoint = async (count) =>
      page.waitForFunction(
        (frames) =>
          document
            .querySelector("#evidence-transit-joint-message")
            .textContent.includes("已联合计算 " + frames + " 帧"),
        count,
      );
    const exportTransitJoint = () =>
      exportJson(
        "#download-evidence-transit-analysis",
        "moonground-evidence-transit-analysis-results.json",
      );
    const selectTransitJointFrame = async (index) =>
      page.locator("#evidence-transit-joint-frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    const transitJoint = await exportTransitJoint();
    assert.equal(
      transitJoint.checkpoint.format,
      "moonground.evidence-transit-analysis",
    );
    assert.equal(transitJoint.frames.length, 10);
    transitJoint.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "evidence_transit_analysis_frame");
      assert.deepEqual(frame.measurement, beforeTransitJointBase.frames[index]);
      assert.deepEqual(frame.transit, evidenceTransit.frames[index]);
    });
    assert.deepEqual(
      transitJoint.checkpoint.transit,
      evidenceTransit.checkpoint,
    );
    assert.equal(
      transitJoint.checkpoint.measurement.motion.last_timestamp_us,
      "1800000",
    );
    assert.equal(
      await page.locator("#evidence-transit-mode").inputValue(),
      "joint",
    );
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#save-evidence-transit-checkpoint").isDisabled(),
      true,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      beforeTransitJointBase,
    );
    await page.locator("#evidence-transit-mode").selectOption("independent");
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );
    assert.deepEqual(
      await exportEvidenceTransit(),
      beforeTransitJointIndependent,
    );
    await page.locator("#evidence-transit-mode").selectOption("joint");
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    await selectTransitJointFrame(2);
    assert.match(
      await page.locator("#evidence-transit-source").textContent(),
      /原观测联合.*3 \/ 10.*400000/,
    );
    assert.equal(await page.locator("#counter").textContent(), "1 / 10");
    const transitJointCheckpoint = await exportJson(
      "#save-evidence-transit-analysis-checkpoint",
      "moonground-evidence-transit-analysis-checkpoint.json",
    );
    assert.equal(
      transitJointCheckpoint.measurement.motion.last_timestamp_us,
      "400000",
    );
    assert.equal(
      transitJointCheckpoint.transit.counting.state.last_timestamp_us,
      "400000",
    );
    assert.equal(transitJointCheckpoint.transit.pending.length, 1);
    assert.deepEqual(
      transitJointCheckpoint.transit,
      evidenceTransitPendingCheckpoint,
    );
    await holdEvidenceTransitPreparation();
    let cancelledTransitJointDownloads = 0;
    const countCancelledTransitJoint = () => {
      cancelledTransitJointDownloads++;
    };
    page.on("download", countCancelledTransitJoint);
    await page.locator("#save-evidence-transit-analysis-checkpoint").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await selectTransitJointFrame(4);
    await releaseEvidenceTransitPreparation();
    await page.waitForFunction(
      () =>
        !document.querySelector("#save-evidence-transit-analysis-checkpoint")
          .disabled,
    );
    page.off("download", countCancelledTransitJoint);
    assert.equal(cancelledTransitJointDownloads, 0);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#evidence-transit-section").screenshot({
      path: path.join(
        directory,
        "evidence-transit-analysis-mobile-preview.png",
      ),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#evidence-transit-section").screenshot({
      path: path.join(
        directory,
        "evidence-transit-analysis-desktop-preview.png",
      ),
    });
    // A whole checkpoint must validate before either source input is touched.
    const cloneTransitJoint = () =>
      JSON.parse(JSON.stringify(transitJointCheckpoint));
    const badTransitJointVersion = cloneTransitJoint();
    badTransitJointVersion.checkpoint_version = "999";
    const badTransitJointTime = cloneTransitJoint();
    badTransitJointTime.transit.counting.state.last_timestamp_us = "400001";
    const badTransitJointCovariance = cloneTransitJoint();
    badTransitJointCovariance.transit.pending[0].from_covariance = [
      1000000, 0, 1000000,
    ];
    const badTransitJointAnchor = cloneTransitJoint();
    badTransitJointAnchor.transit.counting.state.tracks[0].anchors[0].covariance =
      [1, 2, 1];
    const invalidTransitJointCheckpoints = [
      JSON.stringify(badTransitJointVersion),
      JSON.stringify(badTransitJointTime),
      JSON.stringify(badTransitJointCovariance),
      JSON.stringify(badTransitJointAnchor),
      JSON.stringify(transitJointCheckpoint).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
      JSON.stringify(evidenceTransitPendingCheckpoint),
    ];
    for (const rawCheckpoint of invalidTransitJointCheckpoints) {
      await page
        .locator("#evidence-transit-analysis-checkpoint-file")
        .setInputFiles({
          name: "bad-transit-joint.json",
          mimeType: "application/json",
          buffer: Buffer.from(rawCheckpoint),
        });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-transit-analysis-checkpoint-file")
            .value === "",
      );
      assert.equal(
        await page.locator("#evidence-transit-joint-message.error").count(),
        1,
      );
      assert.equal(await page.locator("#source").inputValue(), warehouseInput);
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        evidenceTransitConfig,
      );
      assert.deepEqual(await exportTransitJoint(), transitJoint);
    }
    // Recomputing ordinary output invalidates its detached consumer but leaves
    // the raw-input-bound joint slot and its cursor intact.
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    assert.equal(
      await page.locator("#evidence-transit-mode").inputValue(),
      "joint",
    );
    assert.equal(
      await page.locator("#evidence-transit-joint-frame").inputValue(),
      "4",
    );
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    await page.locator("#evidence-transit-mode").selectOption("independent");
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    await page.locator("#evidence-transit-mode").selectOption("joint");
    // Valid complete import restores both original inputs, with no manual
    // watermark pairing and no dependence on ordinary computed results.
    await page
      .locator("#evidence-transit-analysis-checkpoint-file")
      .setInputFiles({
        name: "transit-joint.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(transitJointCheckpoint)),
      });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-analysis-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#evidence-transit-joint-message.error").count(),
      0,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#source").inputValue()).resume,
      transitJointCheckpoint.measurement,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#evidence-transit-input").inputValue())
        .resume,
      transitJointCheckpoint.transit,
    );
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );
    assert.equal(await page.locator("#download").isDisabled(), true);
    const transitJointResume = await page.locator("#source").inputValue();
    await page
      .locator("#source")
      .fill(
        transitJointResume +
          evidenceTransitWarehouseLines.slice(4).join("\n") +
          "\n",
      );
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(7);
    const transitJointResumed = await exportTransitJoint();
    assert.deepEqual(transitJointResumed.frames, transitJoint.frames.slice(3));
    assert.deepEqual(transitJointResumed.checkpoint, transitJoint.checkpoint);
    assert.equal(await page.locator("#counter").textContent(), "0 / 0");
    // Ground measurements retain anisotropic covariance. Only the small-normal
    // variance identity obtains confirmed crossings through these two gates.
    const groundTransitJointHeader = {
      session_id: "joint-transit-ground",
      mode: "ground",
      motion: { q: 1000000, gate: 1e12, max_tracks: 10 },
    };
    const groundTransitJointSource =
      JSON.stringify(groundTransitJointHeader) +
      "\n" +
      [-0.6, -0.2, 0.2, 0.6]
        .map((x, index) =>
          JSON.stringify({
            timestamp_us: String(index * 200000),
            observations: [
              { track_id: 1, point: [x, 0], covariance: [0.0001, 0, 1] },
              { track_id: 2, point: [x, 0], covariance: [1, 0, 0.0001] },
            ],
          }),
        )
        .join("\n") +
      "\n";
    const groundTransitJointGates = {
      session_id: "joint-transit-ground",
      max_gap_us: "500000",
      max_tracks: 10,
      gates: [-0.3, 0.3].map((x, index) => ({
        gate_id: index ? "exit" : "entry",
        start_m: [x, -2],
        end_m: [x, 2],
        deadband_m: 0.01,
      })),
    };
    const groundTransitJointConfig = {
      ...evidenceTransitFresh,
      counting: JSON.stringify({
        counting: JSON.stringify(groundTransitJointGates),
        sigma_multiplier: 2,
      }),
    };
    await page.locator("#source").fill(groundTransitJointSource);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(groundTransitJointConfig));
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 4 帧"),
    );
    const groundTransitJointBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(4);
    const groundTransitIndependent = await exportEvidenceTransit();
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(4);
    const groundTransitJoint = await exportTransitJoint();
    assert.deepEqual(
      groundTransitJoint.frames.map((frame) => frame.measurement),
      groundTransitJointBase.frames,
    );
    assert.deepEqual(
      groundTransitJoint.frames.map((frame) => frame.transit),
      groundTransitIndependent.frames,
    );
    assert.deepEqual(groundTransitJoint.frames.at(-1).transit.counts, [
      { section_id: "aisle", completed: "1" },
    ]);
    assert.deepEqual(
      groundTransitJoint.frames.flatMap((frame) =>
        frame.transit.passages.map((passage) => passage.track_id),
      ),
      [1],
    );
    assert.equal(
      groundTransitJoint.frames[0].transit.counting.evidence
        .filter((value) => value.track_id === 2)
        .every((value) => value.side === "unconfirmed"),
      true,
    );
    // Raw nested capacities and object identities must not be rounded before
    // validation, and a downstream arithmetic error must preserve base output.
    const fractionalTransitJointConfig = {
      ...groundTransitJointConfig,
      counting: JSON.stringify({
        counting: JSON.stringify(groundTransitJointGates).replace(
          '"max_tracks":10',
          '"max_tracks":10.0000000000000001',
        ),
        sigma_multiplier: 2,
      }),
    };
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(fractionalTransitJointConfig));
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-transit-joint-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(groundTransitJointConfig));
    await page
      .locator("#source")
      .fill(
        groundTransitJointSource.replace(
          '"track_id":1',
          '"track_id":1.0000000000000001',
        ),
      );
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-transit-joint-message")
        .classList.contains("error"),
    );
    const transitJointExtremeSource =
      '{"session_id":"transit-joint-extreme","mode":"ground"}\n{"timestamp_us":"0","observations":[{"track_id":1,"point":[-1e308,0],"covariance":[1,0,1]}]}\n';
    await page.locator("#source").fill(transitJointExtremeSource);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 1 帧"),
    );
    const transitJointExtremeBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#evidence-transit-input").fill(
      JSON.stringify({
        ...evidenceTransitFresh,
        counting: JSON.stringify({
          counting: JSON.stringify({
            session_id: "transit-joint-extreme",
            gates: [
              {
                gate_id: "entry",
                start_m: [1e308, 0],
                end_m: [1e308, 1],
                deadband_m: 0,
              },
              {
                gate_id: "exit",
                start_m: [0, 0],
                end_m: [0, 1],
                deadband_m: 0,
              },
            ],
          }),
          sigma_multiplier: 2,
        }),
      }),
    );
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-transit-joint-message")
        .classList.contains("error"),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      transitJointExtremeBase,
    );
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );
    // Two explicit run choices supersede each other without losing the inactive
    // valid slot or allowing an older callback to switch the visible mode.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    for (const older of ["joint", "independent"]) {
      await holdEvidenceTransitPreparation();
      await page
        .locator(
          older === "joint"
            ? "#evidence-transit-analyze"
            : "#evidence-transit-ordinary",
        )
        .click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      await page
        .locator(
          older === "joint"
            ? "#evidence-transit-ordinary"
            : "#evidence-transit-analyze",
        )
        .click();
      if (older === "joint") await waitEvidenceTransit(10);
      else await waitTransitJoint(10);
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#evidence-transit-mode").inputValue(),
        older === "joint" ? "independent" : "joint",
      );
    }
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    await page.locator("#evidence-transit-mode").selectOption("independent");
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    await page.locator("#evidence-transit-mode").selectOption("joint");
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await releaseEvidenceTransitPreparation();
    await waitTransitJoint(10);
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#evidence-transit-mode").selectOption("independent");
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#evidence-transit-mode").inputValue(),
      "independent",
    );
    assert.deepEqual(await exportEvidenceTransit(), evidenceTransit);
    await page.locator("#evidence-transit-mode").selectOption("joint");
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    // Shared configuration edits clear both slots, whereas raw source edits
    // cancel the pending joint and cannot be overwritten by a late import.
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#evidence-transit-input")
      .fill(evidenceTransitConfig + " ");
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#download-evidence-transit").isDisabled(),
      true,
    );
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "transit-joint-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseTransitJointRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page
      .locator("#evidence-transit-analysis-checkpoint-file")
      .setInputFiles({
        name: "transit-joint-late.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(transitJointCheckpoint)),
      });
    await page.waitForFunction(
      () => typeof window.releaseTransitJointRead === "function",
    );
    await page.locator("#source").fill("newer joint transit draft");
    await page.evaluate(() => {
      window.releaseTransitJointRead();
      delete window.releaseTransitJointRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-analysis-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      "newer joint transit draft",
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      evidenceTransitConfig,
    );
    // A valid whole import also supersedes the run's zero-delay preparation.
    await page.locator("#source").fill(warehouseInput);
    await holdEvidenceTransitPreparation();
    await page.locator("#evidence-transit-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#evidence-transit-analysis-checkpoint-file")
      .setInputFiles({
        name: "replacement-transit-joint.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(transitJointCheckpoint)),
      });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-transit-analysis-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#evidence-transit-joint-message.error").count(),
      0,
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(
      JSON.parse(await page.locator("#source").inputValue()).resume,
      transitJointCheckpoint.measurement,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#evidence-transit-input").inputValue())
        .resume,
      transitJointCheckpoint.transit,
    );
    assert.equal(
      await page.locator("#download-evidence-transit-analysis").isDisabled(),
      true,
    );

    // Health-gated evidence transit owns its complete raw protocol and state.
    // Its display shares the evidence area, without changing the v16 panel.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    const healthTransitOrdinarySource = await page
      .locator("#source")
      .inputValue();
    const healthTransitOtherPanelConfiguration = await page
      .locator("#evidence-transit-input")
      .inputValue();
    await page.locator("#evidence-guarded-section").evaluate((details) => {
      details.open = true;
    });
    await page.locator("#evidence-guarded-example").click();
    await page.waitForFunction(
      (input) =>
        document.querySelector("#guarded-input").value === input &&
        !document.querySelector("#run-evidence-guarded").disabled,
      threePartySource,
    );
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#evidence-guarded-transit-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#evidence-guarded-mode").inputValue(),
      "gates",
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      threePartySource,
    );
    assert.deepEqual(
      await exportJson(
        "#download-evidence-guarded",
        "moonground-evidence-guarded-results.json",
      ),
      threeParty,
    );

    const healthTransitSource = fs.readFileSync(
      path.resolve(
        __dirname,
        "..",
        "examples",
        "evidence-guarded-transit.ndjson",
      ),
      "utf8",
    );
    const healthTransitLines = healthTransitSource.trimEnd().split("\n");
    const importGuardedTransit = async (input) => {
      await page.locator("#evidence-guarded-transit-file").setInputFiles({
        name: "guarded-transit.ndjson",
        mimeType: "application/x-ndjson",
        buffer: Buffer.from(input),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-guarded-transit-file").value === "",
      );
    };
    const exportGuardedTransit = () =>
      exportJson(
        "#download-evidence-guarded-transit",
        "moonground-evidence-guarded-transit-results.json",
      );
    const healthTransitSetFrame = async (index) =>
      page
        .locator("#evidence-guarded-transit-frame")
        .evaluate((input, value) => {
          input.value = String(value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }, index);
    await page.locator("#evidence-guarded-transit-example").click();
    await page.waitForFunction(
      (input) =>
        document.querySelector("#guarded-input").value === input &&
        !document.querySelector("#run-evidence-guarded-transit").disabled,
      healthTransitSource,
    );
    const healthTransit = await exportGuardedTransit();
    assert.equal(healthTransit.frames.length, 17);
    assert.equal(
      healthTransit.checkpoint.format,
      "moonground.evidence-guarded-transit",
    );
    assert.equal(
      healthTransit.checkpoint.analysis.format,
      "moonground.evidence-transit-analysis",
    );
    assert.equal(
      healthTransit.checkpoint.analysis.transit.format,
      "moonground.evidence-transit",
    );
    healthTransit.frames.forEach((frame, index) => {
      assert.equal(
        frame.kind,
        [9, 16].includes(index)
          ? "evidence_guarded_transit_projection_replaced"
          : "evidence_guarded_transit_frame",
      );
      assert.equal(
        frame.decision,
        frame.health.status === "healthy" ? "allowed" : "blocked",
      );
      assert.equal(frame.analysis.transit.counting.sigma_multiplier, 2);
      if (index < 16) {
        assert.deepEqual(frame.health, threeParty.frames[index].health);
        assert.deepEqual(
          frame.analysis.measurement,
          threeParty.frames[index].analysis.measurement,
        );
      }
      if (frame.decision === "blocked") {
        assert.deepEqual(frame.analysis.measurement.tracks, []);
        assert.deepEqual(frame.analysis.transit.counting.evidence, []);
        assert.equal(frame.analysis.transit.pending_count, 0);
      }
    });
    assert.equal(healthTransit.frames[3].analysis.transit.pending_count, 2);
    assert.deepEqual(
      healthTransit.frames[4].analysis.transit.passages.map(
        (p) => p.section_id,
      ),
      ["short-aisle"],
    );
    assert.deepEqual(
      healthTransit.frames[6].analysis.transit.cancellations.map((c) => [
        c.section_id,
        c.reason,
      ]),
      [["long-aisle", "discontinuity"]],
    );
    assert.equal(
      healthTransit.frames[13].analysis.measurement.tracks[0].segment_id,
      "2",
    );
    assert.deepEqual(
      healthTransit.frames[16].analysis.transit.cancellations.map((c) => [
        c.section_id,
        c.reason,
      ]),
      [
        ["short-aisle", "discontinuity"],
        ["long-aisle", "discontinuity"],
      ],
    );
    assert.deepEqual(healthTransit.frames[16].analysis.transit.counts, [
      { section_id: "short-aisle", completed: "1" },
      { section_id: "long-aisle", completed: "0" },
    ]);
    assert.equal(
      healthTransit.checkpoint.health.state.last_timestamp_us,
      "1600000",
    );
    assert.equal(
      healthTransit.checkpoint.analysis.measurement.motion.last_timestamp_us,
      "1600000",
    );
    assert.equal(
      healthTransit.checkpoint.analysis.transit.counting.state
        .last_timestamp_us,
      "1600000",
    );
    assert.deepEqual(
      healthTransit.checkpoint.analysis.measurement.configuration.calibration,
      healthTransit.checkpoint.health.configuration.calibration,
    );
    assert.deepEqual(
      healthTransit.checkpoint.analysis.measurement.configuration.camera,
      healthTransit.checkpoint.health.configuration.camera,
    );
    assert.equal(
      healthTransit.checkpoint.health.configuration.camera ?? null,
      null,
    );
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#save-evidence-guarded-checkpoint").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#evidence-transit-guarded").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      healthTransitOrdinarySource,
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      healthTransitOtherPanelConfiguration,
    );
    assert.deepEqual(await exportTransitJoint(), transitJoint);

    await healthTransitSetFrame(4);
    assert.match(
      await page.locator("#evidence-guarded-status").textContent(),
      /450000.*证据通行.*已放行/,
    );
    assert.match(
      await page.locator("#evidence-guarded-transit-passages").textContent(),
      /short-aisle/,
    );
    assert.equal(await page.locator("#evidence-guarded-rows tr").count(), 3);
    await page.locator("#evidence-guarded-mode").selectOption("gates");
    assert.equal(
      await page.locator("#download-evidence-guarded-transit").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#evidence-guarded-frame").isVisible(),
      true,
    );
    await page.locator("#evidence-guarded-mode").selectOption("transit");
    assert.equal(
      await page.locator("#evidence-guarded-transit-frame").inputValue(),
      "4",
    );
    assert.equal(
      await page.locator("#download-evidence-guarded-transit").isDisabled(),
      false,
    );
    // Wrong-entry runs reject the new header without discarding its report.
    for (const selector of ["#run-guarded", "#run-evidence-guarded"]) {
      await page.locator(selector).click();
      await page.waitForFunction(
        (selector) => !document.querySelector(selector).disabled,
        selector,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        healthTransitSource,
      );
      assert.equal(
        await page.locator("#evidence-guarded-mode").inputValue(),
        "transit",
      );
    }
    assert.deepEqual(await exportGuardedTransit(), healthTransit);

    // Selected checkpoints include all three equal watermarks and pending proof.
    await healthTransitSetFrame(3);
    const healthTransitPendingCheckpoint = await exportJson(
      "#save-evidence-guarded-transit-checkpoint",
      "moonground-evidence-guarded-transit-checkpoint.json",
    );
    assert.equal(
      healthTransitPendingCheckpoint.health.state.last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthTransitPendingCheckpoint.analysis.measurement.motion
        .last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthTransitPendingCheckpoint.analysis.transit.counting.state
        .last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthTransitPendingCheckpoint.analysis.transit.pending.length,
      2,
    );
    for (const pending of healthTransitPendingCheckpoint.analysis.transit
      .pending) {
      assert.equal(pending.from_covariance.length, 3);
      assert.equal(pending.to_covariance.length, 3);
    }
    await healthTransitSetFrame(15);
    const healthTransitWarmCheckpoint = await exportJson(
      "#save-evidence-guarded-transit-checkpoint",
      "moonground-evidence-guarded-transit-checkpoint.json",
    );
    assert.equal(
      healthTransitWarmCheckpoint.health.state.last_timestamp_us,
      "1550000",
    );
    assert.equal(
      healthTransitWarmCheckpoint.analysis.transit.pending.length,
      2,
    );
    assert.deepEqual(
      healthTransitWarmCheckpoint.analysis.measurement.configuration
        .calibration,
      threeParty.checkpoint.analysis.measurement.configuration.calibration,
    );

    const invalidGuardedTransitCheckpoints = [];
    const healthTransitClone = () =>
      JSON.parse(JSON.stringify(healthTransitPendingCheckpoint));
    const healthTransitBadTime = healthTransitClone();
    healthTransitBadTime.health.state.last_timestamp_us = "350001";
    invalidGuardedTransitCheckpoints.push(JSON.stringify(healthTransitBadTime));
    const healthTransitBadCountingTime = healthTransitClone();
    healthTransitBadCountingTime.analysis.transit.counting.state.last_timestamp_us =
      "350001";
    invalidGuardedTransitCheckpoints.push(
      JSON.stringify(healthTransitBadCountingTime),
    );
    const healthTransitBadCovariance = healthTransitClone();
    healthTransitBadCovariance.analysis.transit.pending[0].from_covariance = [
      1, 2, 1,
    ];
    invalidGuardedTransitCheckpoints.push(
      JSON.stringify(healthTransitBadCovariance),
    );
    const healthTransitBadProjection = healthTransitClone();
    healthTransitBadProjection.health.configuration.calibration.matrix[2] += 1;
    invalidGuardedTransitCheckpoints.push(
      JSON.stringify(healthTransitBadProjection),
    );
    invalidGuardedTransitCheckpoints.push(
      JSON.stringify(healthTransitPendingCheckpoint).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
      JSON.stringify(threeParty.checkpoint),
      JSON.stringify(transitJoint.checkpoint),
    );
    const importGuardedTransitCheckpoint = async (
      checkpoint,
      name = "guarded-transit.json",
    ) => {
      await page
        .locator("#evidence-guarded-transit-checkpoint-file")
        .setInputFiles({
          name,
          mimeType: "application/json",
          buffer: Buffer.from(
            typeof checkpoint === "string"
              ? checkpoint
              : JSON.stringify(checkpoint),
          ),
        });
      await page.waitForFunction(
        () =>
          document.querySelector("#evidence-guarded-transit-checkpoint-file")
            .value === "",
      );
    };
    for (const rawCheckpoint of invalidGuardedTransitCheckpoints) {
      await importGuardedTransitCheckpoint(rawCheckpoint);
      assert.equal(
        await page.locator("#evidence-guarded-transit-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        healthTransitSource,
      );
      assert.equal(
        await page.locator("#evidence-guarded-transit-counter").textContent(),
        "16 / 17",
      );
    }
    assert.deepEqual(await exportGuardedTransit(), healthTransit);
    const healthTransitFirst = JSON.parse(healthTransitLines[1]);
    const healthTransitHeader = JSON.parse(healthTransitLines[0]);
    const healthTransitRawAnalysis = JSON.parse(healthTransitHeader.analysis);
    const fractionalGuardedTransitHeader = JSON.stringify({
      ...healthTransitHeader,
      analysis: JSON.stringify({
        ...healthTransitRawAnalysis,
        measurement: healthTransitRawAnalysis.measurement.replace(
          '"max_tracks":10',
          '"max_tracks":10.0000000000000001',
        ),
      }),
    });
    const invalidGuardedTransitInputs = [
      fractionalGuardedTransitHeader + "\n" + healthTransitLines[1] + "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({ ...healthTransitFirst, unknown: true }) +
        "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({
          ...healthTransitFirst,
          health: healthTransitFirst.health.replace(
            '"timestamp_us":"0"',
            '"timestamp_us":"1"',
          ),
        }) +
        "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({
          ...healthTransitFirst,
          measurement: healthTransitFirst.measurement.replace(
            '"track_id":1',
            '"track_id":1.0000000000000001',
          ),
        }) +
        "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({
          ...healthTransitFirst,
          measurement: healthTransitFirst.measurement.replace(
            '"track_id":1',
            '"track_id":1,"track_id":1',
          ),
        }) +
        "\n",
      ...badProjectionOperations.map(
        (operation) =>
          healthTransitLines.slice(0, 10).join("\n") + "\n" + operation + "\n",
      ),
    ];
    for (const rawInput of invalidGuardedTransitInputs) {
      await importGuardedTransit(rawInput);
      assert.equal(
        await page.locator("#evidence-guarded-transit-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        healthTransitSource,
      );
    }
    assert.deepEqual(await exportGuardedTransit(), healthTransit);
    await importGuardedTransitCheckpoint(healthTransitPendingCheckpoint);
    assert.equal(
      await page.locator("#evidence-guarded-transit-message.error").count(),
      0,
    );
    const healthTransitResume = await page
      .locator("#guarded-input")
      .inputValue();
    assert.deepEqual(
      JSON.parse(healthTransitResume).resume,
      healthTransitPendingCheckpoint,
    );
    assert.equal(
      await page.locator("#download-evidence-guarded-transit").isDisabled(),
      true,
    );
    await importGuardedTransit(
      healthTransitResume + healthTransitLines.slice(5).join("\n") + "\n",
    );
    const healthTransitResumed = await exportGuardedTransit();
    assert.deepEqual(
      healthTransitResumed.frames,
      healthTransit.frames.slice(4),
    );
    assert.deepEqual(healthTransitResumed.checkpoint, healthTransit.checkpoint);
    // Importing the final replacement retains its new projection and empty state.
    await importGuardedTransitCheckpoint(healthTransit.checkpoint);
    const healthTransitEndResume = await page
      .locator("#guarded-input")
      .inputValue();
    assert.deepEqual(
      JSON.parse(healthTransitEndResume).resume,
      healthTransit.checkpoint,
    );
    await importGuardedTransit(healthTransitSource);

    // A changing selection or mode cancels a pending prefix-save download.
    let cancelledGuardedTransitDownloads = 0;
    const countCancelledGuardedTransitDownload = () => {
      cancelledGuardedTransitDownloads++;
    };
    page.on("download", countCancelledGuardedTransitDownload);
    for (const change of ["frame", "mode"]) {
      await holdThreePartyPreparation();
      await page.locator("#save-evidence-guarded-transit-checkpoint").click();
      await page.waitForFunction(
        () => typeof window.releaseThreePartyRun === "function",
      );
      if (change === "frame") await healthTransitSetFrame(4);
      else await page.locator("#evidence-guarded-mode").selectOption("gates");
      await releaseThreePartyPreparation();
      await page.waitForFunction(
        () =>
          !document.querySelector("#save-evidence-guarded-transit-checkpoint")
            .disabled ||
          document.querySelector("#evidence-guarded-mode").value !== "transit",
      );
    }
    page.off("download", countCancelledGuardedTransitDownload);
    assert.equal(cancelledGuardedTransitDownloads, 0);
    await page.locator("#evidence-guarded-mode").selectOption("transit");

    // The three shared-input owners cancel each other's late preparations.
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await page.locator("#evidence-guarded-example").click();
    await page.waitForFunction(
      (input) => document.querySelector("#guarded-input").value === input,
      threePartySource,
    );
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#evidence-guarded-mode").inputValue(),
      "gates",
    );
    assert.deepEqual(
      await exportJson(
        "#download-evidence-guarded",
        "moonground-evidence-guarded-results.json",
      ),
      threeParty,
    );
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await importGuardedTransit(healthTransitSource);
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#evidence-guarded-mode").inputValue(),
      "transit",
    );
    assert.deepEqual(await exportGuardedTransit(), healthTransit);
    await page.locator("#guarded-example").click();
    await page.waitForFunction(
      (input) => document.querySelector("#guarded-input").value === input,
      beforeThreePartyLegacyInput,
    );
    await holdThreePartyPreparation();
    await page.locator("#run-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await importGuardedTransit(healthTransitSource);
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      healthTransitSource,
    );
    assert.doesNotMatch(
      await page.locator("#evidence-guarded-message").textContent(),
      /正在/,
    );
    assert.doesNotMatch(
      await page.locator("#guarded-message").textContent(),
      /正在/,
    );
    // A valid new file and a complete import can supersede a busy new run.
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    const renamedGuardedTransit = healthTransitSource.replaceAll(
      "warehouse-landmarks",
      "new-transit-monitor",
    );
    await importGuardedTransit(renamedGuardedTransit);
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#run-evidence-guarded-transit").isDisabled(),
      false,
    );
    assert.equal(
      (await exportGuardedTransit()).frames[0].health.monitor_id,
      "new-transit-monitor",
    );
    await holdThreePartyPreparation();
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => typeof window.releaseThreePartyRun === "function",
    );
    await importGuardedTransitCheckpoint(healthTransitPendingCheckpoint);
    await releaseThreePartyPreparation();
    assert.equal(
      await page.locator("#run-evidence-guarded-transit").isDisabled(),
      false,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#guarded-input").inputValue()).resume,
      healthTransitPendingCheckpoint,
    );

    // Neither late raw checkpoint reads nor sample responses replace new input.
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "guarded-transit-late.json")
          return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseGuardedTransitRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page
      .locator("#evidence-guarded-transit-checkpoint-file")
      .setInputFiles({
        name: "guarded-transit-late.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(healthTransitPendingCheckpoint)),
      });
    await page.waitForFunction(
      () => typeof window.releaseGuardedTransitRead === "function",
    );
    await page.locator("#guarded-input").fill("newer health transit draft");
    await page.evaluate(() => {
      window.releaseGuardedTransitRead();
      delete window.releaseGuardedTransitRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#evidence-guarded-transit-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      "newer health transit draft",
    );
    assert.equal(
      await page.locator("#download-evidence-guarded-transit").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#download-evidence-guarded").isDisabled(),
      true,
    );
    assert.deepEqual(await exportTransitJoint(), transitJoint);

    let releaseGuardedTransitSample, healthTransitSampleRequested;
    const healthTransitSampleGate = new Promise((resolve) => {
      releaseGuardedTransitSample = resolve;
    });
    const healthTransitSampleRequest = new Promise((resolve) => {
      healthTransitSampleRequested = resolve;
    });
    await page.route("**/evidence-guarded-transit.ndjson", async (route) => {
      healthTransitSampleRequested();
      await healthTransitSampleGate;
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: healthTransitSource,
      });
    });
    try {
      await page.locator("#evidence-guarded-transit-example").click();
      await healthTransitSampleRequest;
      await page.locator("#guarded-input").fill("newest health transit draft");
      const sampleResponse = page.waitForResponse((response) =>
        response.url().endsWith("/evidence-guarded-transit.ndjson"),
      );
      releaseGuardedTransitSample();
      await (await sampleResponse).finished();
      await page.waitForLoadState("networkidle");
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        "newest health transit draft",
      );
    } finally {
      releaseGuardedTransitSample();
      await page.unroute("**/evidence-guarded-transit.ndjson");
    }
    await importGuardedTransit(healthTransitSource);
    await healthTransitSetFrame(4);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#evidence-guarded-section").screenshot({
      path: path.join(directory, "evidence-guarded-transit-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#evidence-guarded-section").screenshot({
      path: path.join(
        directory,
        "evidence-guarded-transit-desktop-preview.png",
      ),
    });
    await healthTransitSetFrame(16);
    assert.match(
      await page.locator("#evidence-guarded-policy").textContent(),
      /2 次标定切换/,
    );
    assert.equal(
      await page.locator("#evidence-guarded-transit-cancellations li").count(),
      2,
    );
    assert.deepEqual(await exportGuardedTransit(), healthTransit);

    // Confirmation windows are an independent downstream of all three transit
    // reports. Every empty, blocked and replacement frame remains in the stream.
    await page.locator("#evidence-transit-section").evaluate((d) => {
      d.open = true;
    });
    await page.locator("#transit-windows-section").evaluate((d) => {
      d.open = true;
    });
    const windowConfiguration =
      '{"window_us":"500000","duration_limits_us":["0","100000","300000","9223372036854775807"]}';
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    const runWindows = async (origin, count) => {
      await page.locator("#transit-windows-" + origin).click();
      await page.waitForFunction(() => {
        const message = document.querySelector("#transit-windows-message");
        return (
          message.textContent.startsWith("已统计") ||
          message.classList.contains("error")
        );
      });
      assert.equal(
        await page.locator("#transit-windows-message.error").count(),
        0,
      );
      assert.match(
        await page.locator("#transit-windows-message").textContent(),
        new RegExp("已统计 " + count + " 个确认帧"),
      );
    };
    const exportWindows = () =>
      exportJson(
        "#download-transit-windows",
        "moonground-transit-windows-results.json",
      );
    const checkWindowClassification = (report, inputs) => {
      report.frames.forEach((frame, index) => {
        assert.equal(
          frame.classification_scope,
          "observed_chord_elapsed_bounds",
        );
        assert.equal(
          frame.timestamp_us,
          inputs[index].counting.counting.timestamp_us,
        );
        for (const window of [frame.current_window, frame.closed_window]) {
          if (window === null) continue;
          const observed = inputs.slice(0, index + 1).filter((input) => {
            const t = BigInt(input.counting.counting.timestamp_us);
            return (
              t >= BigInt(window.start_us) &&
              (window.end_exclusive_us === null ||
                t < BigInt(window.end_exclusive_us))
            );
          });
          assert.equal(window.input_frames, String(observed.length));
          for (const section of window.sections) {
            const passages = observed
              .flatMap((input) => input.passages)
              .filter((p) => p.section_id === section.section_id);
            assert.equal(section.completed, String(passages.length));
            for (const limit of section.duration_limits) {
              const within = passages.filter(
                (p) => BigInt(p.elapsed_upper_us) <= BigInt(limit.limit_us),
              ).length;
              const exceeded = passages.filter(
                (p) => BigInt(p.elapsed_lower_us) > BigInt(limit.limit_us),
              ).length;
              assert.deepEqual(
                [limit.within, limit.exceeded, limit.indeterminate],
                [
                  String(within),
                  String(exceeded),
                  String(passages.length - within - exceeded),
                ],
              );
            }
            for (const cancellation of section.cancellations) {
              const count = observed
                .flatMap((input) => input.cancellations)
                .filter(
                  (c) =>
                    c.section_id === section.section_id &&
                    c.reason === cancellation.reason,
                ).length;
              assert.equal(cancellation.count, String(count));
            }
          }
        }
      });
    };
    await runWindows("independent", 10);
    const independentWindows = await exportWindows();
    assert.equal(
      independentWindows.checkpoint.format,
      "moonground.evidence-transit-windows",
    );
    assert.equal(independentWindows.checkpoint.baseline_timestamp_us, null);
    checkWindowClassification(independentWindows, evidenceTransit.frames);
    await runWindows("joint", 10);
    assert.deepEqual(await exportWindows(), independentWindows);
    await selectTransitJointFrame(2);
    assert.match(
      await page.locator("#transit-windows-source").textContent(),
      /原观测联合区间.*3 \/ 10.*400000/,
    );
    await page.locator("#evidence-transit-mode").selectOption("independent");
    assert.deepEqual(await exportWindows(), independentWindows);
    assert.match(
      await page.locator("#transit-windows-source").textContent(),
      /原观测联合区间/,
    );

    await runWindows("guarded", 17);
    const guardedWindows = await exportWindows();
    checkWindowClassification(
      guardedWindows,
      healthTransit.frames.map((f) => f.analysis.transit),
    );
    assert.equal(guardedWindows.frames[0].current_window.input_frames, "1");
    assert.equal(guardedWindows.frames[6].current_window.input_frames, "2");
    assert.equal(guardedWindows.frames[16].current_window.input_frames, "2");
    assert.equal(
      guardedWindows.frames[16].current_window.sections[0].cancellations[0]
        .count,
      "1",
    );
    assert.equal(
      guardedWindows.frames[16].current_window.sections[1].cancellations[0]
        .count,
      "1",
    );
    await healthTransitSetFrame(5);
    assert.match(
      await page.locator("#transit-windows-source").textContent(),
      /健康证据通行.*6 \/ 17.*550000/,
    );
    assert.match(
      await page.locator("#transit-windows-closed-summary").textContent(),
      /\[0, 500000\).*输入 5 帧/,
    );
    assert.equal(
      await page.locator("#transit-windows-closed-limits tr").count(),
      8,
    );
    const finalWindowsCheckpoint = await exportJson(
      "#save-transit-windows-checkpoint",
      "moonground-transit-windows-checkpoint.json",
    );
    assert.deepEqual(finalWindowsCheckpoint, guardedWindows.checkpoint);
    assert.equal(finalWindowsCheckpoint.last_timestamp_us, "1600000");
    // Lazy rendering retains only the selected window's small tables.
    await page.locator("#transit-windows-section").evaluate((d) => {
      d.open = false;
    });
    await healthTransitSetFrame(16);
    assert.equal(
      await page.locator("#transit-windows-current-limits tr").count(),
      0,
    );
    await page.locator("#transit-windows-section").evaluate((d) => {
      d.open = true;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#transit-windows-current-limits").children
          .length === 8,
    );
    await healthTransitSetFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(directory, "transit-windows-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(directory, "transit-windows-desktop-preview.png"),
    });

    const importWindowsCheckpoint = async (
      checkpoint,
      name = "transit-windows.json",
    ) => {
      await page.locator("#transit-windows-checkpoint-file").setInputFiles({
        name,
        mimeType: "application/json",
        buffer: Buffer.from(
          typeof checkpoint === "string"
            ? checkpoint
            : JSON.stringify(checkpoint),
        ),
      });
      await page.waitForFunction(
        () =>
          document.querySelector("#transit-windows-checkpoint-file").value ===
          "",
      );
    };
    const badWindowVersion = JSON.parse(JSON.stringify(finalWindowsCheckpoint));
    badWindowVersion.checkpoint_version = "99";
    const badWindowPartition = JSON.parse(
      JSON.stringify(finalWindowsCheckpoint),
    );
    badWindowPartition.current_window.sections[0].duration_limits[0].within =
      "1";
    const badWindowTime = JSON.parse(JSON.stringify(finalWindowsCheckpoint));
    badWindowTime.last_timestamp_us = "1600001";
    for (const invalid of [
      badWindowVersion,
      badWindowPartition,
      badWindowTime,
      healthTransit.checkpoint,
    ]) {
      await importWindowsCheckpoint(invalid);
      assert.equal(
        await page.locator("#transit-windows-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        windowConfiguration,
      );
      assert.deepEqual(await exportWindows(), guardedWindows);
    }
    // A downstream resume is validated whole and cannot silently filter old
    // frames when the user selects an upstream batch preceding its watermark.
    await importWindowsCheckpoint(finalWindowsCheckpoint);
    assert.equal(
      await page.locator("#transit-windows-message.error").count(),
      0,
    );
    const finalWindowResume = await page
      .locator("#transit-windows-input")
      .inputValue();
    assert.deepEqual(
      JSON.parse(finalWindowResume).resume,
      finalWindowsCheckpoint,
    );
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      healthTransitSource,
    );
    assert.equal(
      await page.locator("#transit-windows-input").inputValue(),
      finalWindowResume,
    );
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );

    // Source seed comes from the beginning of a replay, including a started
    // pending-entry checkpoint; its end checkpoint must never seed earlier rows.
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await importGuardedTransit(
      healthTransitLines.slice(0, 5).join("\n") + "\n",
    );
    await runWindows("guarded", 4);
    const prefixWindows = await exportWindows();
    const prefixWindowsCheckpoint = await exportJson(
      "#save-transit-windows-checkpoint",
      "moonground-transit-windows-checkpoint.json",
    );
    assert.equal(prefixWindowsCheckpoint.last_timestamp_us, "350000");
    assert.equal(prefixWindowsCheckpoint.current_window.input_frames, "4");
    await importGuardedTransitCheckpoint(healthTransitPendingCheckpoint);
    const resumedGuardedWindowSource = await page
      .locator("#guarded-input")
      .inputValue();
    await importGuardedTransit(
      resumedGuardedWindowSource +
        healthTransitLines.slice(5).join("\n") +
        "\n",
    );
    await runWindows("guarded", 13);
    const newlyStartedWindows = await exportWindows();
    assert.equal(
      newlyStartedWindows.checkpoint.baseline_timestamp_us,
      "350000",
    );
    assert.equal(
      newlyStartedWindows.frames[0].current_window.first_timestamp_us,
      "450000",
    );
    assert.equal(
      newlyStartedWindows.frames[0].current_window.input_frames,
      "1",
    );
    assert.equal(
      newlyStartedWindows.frames[0].current_window.sections[0].completed,
      "1",
    );
    await importWindowsCheckpoint(prefixWindowsCheckpoint);
    await runWindows("guarded", 13);
    const resumedWindows = await exportWindows();
    assert.deepEqual(resumedWindows.frames, guardedWindows.frames.slice(4));
    assert.deepEqual(resumedWindows.checkpoint, guardedWindows.checkpoint);
    assert.deepEqual(prefixWindows.frames, guardedWindows.frames.slice(0, 4));

    // Raw configuration reaches the strict reader without numeric conversion,
    // property deduplication or accepting an inner upstream-source override.
    for (const raw of [
      '{"window_us":500000.0000000000000001,"duration_limits_us":["100000"]}',
      '{"window_us":"0500000","duration_limits_us":["100000"]}',
      '{"window_us":"500000","window_us":"600000","duration_limits_us":["100000"]}',
      '{"window_us":"500000","duration_limits_us":["100000.0000000000000001"]}',
      '{"window_us":"500000","duration_limits_us":["300000","100000"]}',
      '{"window_us":"500000","duration_limits_us":["100000"],"unknown":true}',
      '{"window_us":"500000","duration_limits_us":["100000"],"transit":"override"}',
    ]) {
      await page.locator("#transit-windows-input").fill(raw);
      await page.locator("#transit-windows-guarded").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#transit-windows-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        raw,
      );
      assert.equal(
        await page.locator("#download-transit-windows").isDisabled(),
        true,
      );
    }
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await importGuardedTransit(healthTransitSource);
    await runWindows("guarded", 17);
    // Invalidating either warehouse slot leaves a health-bound window result.
    await page.locator("#source").fill(warehouseInput + " ");
    assert.deepEqual(await exportWindows(), guardedWindows);
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    assert.deepEqual(await exportWindows(), guardedWindows);
    await runWindows("independent", 10);
    await page.locator("#guarded-input").fill(healthTransitSource + " ");
    assert.deepEqual(await exportWindows(), independentWindows);
    await importGuardedTransit(healthTransitSource);

    // A source disappearing cancels its pending computation. A different,
    // newer source choice survives disappearance of the older displayed one.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#source").fill(warehouseInput + " ");
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );
    await releaseEvidenceTransitPreparation();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-message")
        .textContent.startsWith("已统计 17"),
    );
    assert.deepEqual(await exportWindows(), guardedWindows);
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-independent").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#source").fill(warehouseInput + " ");
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportWindows(), guardedWindows);
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-joint").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runWindows("guarded", 17);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportWindows(), guardedWindows);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#transit-windows-input")
      .fill(windowConfiguration + " ");
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );
    // Whole imports supersede pending work, and late reads yield to new drafts.
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await importWindowsCheckpoint(prefixWindowsCheckpoint);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(
      JSON.parse(await page.locator("#transit-windows-input").inputValue())
        .resume,
      prefixWindowsCheckpoint,
    );
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "windows-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseWindowRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page.locator("#transit-windows-checkpoint-file").setInputFiles({
      name: "windows-late.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(prefixWindowsCheckpoint)),
    });
    await page.waitForFunction(
      () => typeof window.releaseWindowRead === "function",
    );
    await page
      .locator("#transit-windows-input")
      .fill("newer confirmation window draft");
    await page.evaluate(() => {
      window.releaseWindowRead();
      delete window.releaseWindowRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#transit-windows-checkpoint-file").value === "",
    );
    assert.equal(
      await page.locator("#transit-windows-input").inputValue(),
      "newer confirmation window draft",
    );
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runWindows("joint", 10);
    await page
      .locator("#evidence-transit-input")
      .fill(evidenceTransitConfig + " ");
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );

    // Exact string clocks survive the UI adapter above 2^53 and at Int64 MAX.
    // Empty upstream frames cross a huge gap without enumerating zero buckets.
    const windowClockTimes = ["0", "9007199254740993", "9223372036854775807"];
    const windowClockSource =
      JSON.stringify({ session_id: "window-clock", mode: "ground" }) +
      "\n" +
      windowClockTimes
        .map((timestamp_us) =>
          JSON.stringify({ timestamp_us, observations: [] }),
        )
        .join("\n") +
      "\n";
    const windowClockTransit = {
      counting: JSON.stringify({
        counting: JSON.stringify({
          session_id: "window-clock",
          gates: [
            { gate_id: "entry", start_m: [0, -1], end_m: [0, 1] },
            { gate_id: "exit", start_m: [1, -1], end_m: [1, 1] },
          ],
        }),
        sigma_multiplier: 2,
      }),
      sections: [
        {
          section_id: "clock-section",
          entry_gate_id: "entry",
          entry_direction: "positive_to_negative",
          exit_gate_id: "exit",
          exit_direction: "positive_to_negative",
        },
      ],
    };
    await page.locator("#source").fill(windowClockSource);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(windowClockTransit));
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(3);
    await page
      .locator("#transit-windows-input")
      .fill(
        '{"window_us":"1","duration_limits_us":["0","9223372036854775807"]}',
      );
    await runWindows("joint", 3);
    const clockWindows = await exportWindows();
    assert.equal(clockWindows.frames.length, 3);
    assert.equal(
      clockWindows.frames[1].current_window.start_us,
      "9007199254740993",
    );
    assert.equal(clockWindows.frames[1].unobserved_windows, "9007199254740992");
    assert.equal(clockWindows.frames[2].current_window.end_exclusive_us, null);
    assert.equal(clockWindows.frames[2].current_window.input_frames, "1");
    assert.equal(
      clockWindows.frames[2].unobserved_windows,
      (9223372036854775807n - 9007199254740993n - 1n).toString(),
    );
    assert.match(
      await page.locator("#transit-windows-current-summary").textContent(),
      /9223372036854775807.*Int64 时钟上限/,
    );
    await selectTransitJointFrame(1);
    assert.match(
      await page.locator("#transit-windows-current-summary").textContent(),
      /9007199254740993, 9007199254740994/,
    );
    assert.match(
      await page.locator("#transit-windows-gap").textContent(),
      /9007199254740992/,
    );
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runWindows("guarded", 17);
    await healthTransitSetFrame(5);

    // Raw measurement, evidence transit and windows commit as one independent
    // slot; the original three-source downstream remains available.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    await runWindows("joint", 10);
    const waitWindowJoint = async (count) => {
      await page.waitForFunction(() => {
        const message = document.querySelector(
          "#transit-windows-joint-message",
        );
        return (
          message.textContent.includes("已联合处理") ||
          message.classList.contains("error")
        );
      });
      assert.equal(
        await page.locator("#transit-windows-joint-message.error").count(),
        0,
      );
      assert.match(
        await page.locator("#transit-windows-joint-message").textContent(),
        new RegExp("已联合处理 " + count + " 帧"),
      );
    };
    const runWindowJoint = async (count) => {
      await page.locator("#transit-windows-analyze").click();
      await waitWindowJoint(count);
    };
    const exportWindowJoint = () =>
      exportJson(
        "#download-transit-windows-analysis",
        "moonground-transit-windows-analysis-results.json",
      );
    const selectWindowJointFrame = (index) =>
      page.locator("#transit-windows-joint-frame").evaluate((input, index) => {
        input.value = String(index);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await runWindowJoint(10);
    const windowJoint = await exportWindowJoint();
    assert.equal(
      windowJoint.checkpoint.format,
      "moonground.evidence-transit-window-analysis",
    );
    assert.deepEqual(windowJoint.checkpoint.analysis, transitJoint.checkpoint);
    assert.deepEqual(
      windowJoint.checkpoint.windows,
      independentWindows.checkpoint,
    );
    windowJoint.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "evidence_transit_window_analysis_frame");
      assert.deepEqual(frame.analysis, transitJoint.frames[index]);
      assert.deepEqual(frame.windows, independentWindows.frames[index]);
    });
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "joint",
    );
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#save-transit-windows-checkpoint").isDisabled(),
      true,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      beforeTransitJointBase,
    );
    assert.deepEqual(await exportTransitJoint(), transitJoint);
    await page.locator("#transit-windows-mode").selectOption("independent");
    assert.equal(
      await page.locator("#download-transit-windows-analysis").isDisabled(),
      true,
    );
    assert.deepEqual(await exportWindows(), independentWindows);
    await page.locator("#transit-windows-mode").selectOption("joint");
    await selectWindowJointFrame(2);
    assert.match(
      await page.locator("#transit-windows-source").textContent(),
      /原观测联合分窗.*3 \/ 10.*400000/,
    );
    assert.match(
      await page.locator("#transit-windows-joint-summary").textContent(),
      /待出口 1/,
    );
    assert.equal(
      await page.locator("#transit-windows-joint-tracks tr").count(),
      windowJoint.frames[2].analysis.measurement.tracks.length,
    );
    const windowJointCheckpoint = await exportJson(
      "#save-transit-windows-analysis-checkpoint",
      "moonground-transit-windows-analysis-checkpoint.json",
    );
    assert.equal(
      windowJointCheckpoint.analysis.measurement.motion.last_timestamp_us,
      "400000",
    );
    assert.equal(
      windowJointCheckpoint.analysis.transit.counting.state.last_timestamp_us,
      "400000",
    );
    assert.equal(windowJointCheckpoint.windows.last_timestamp_us, "400000");
    assert.equal(windowJointCheckpoint.analysis.transit.pending.length, 1);
    assert.equal(
      windowJointCheckpoint.windows.current_window.input_frames,
      "3",
    );
    // Saving replays the selected prefix and cancels on selection/mode changes.
    let cancelledWindowJointDownloads = 0;
    const countCancelledWindowJoint = () => {
      cancelledWindowJointDownloads++;
    };
    page.on("download", countCancelledWindowJoint);
    for (const change of ["selection", "mode"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#save-transit-windows-analysis-checkpoint").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      if (change === "selection") await selectWindowJointFrame(4);
      else
        await page.locator("#transit-windows-mode").selectOption("independent");
      await releaseEvidenceTransitPreparation();
      await page.waitForFunction(
        () =>
          !document.querySelector("#save-transit-windows-analysis-checkpoint")
            .disabled ||
          document.querySelector("#transit-windows-mode").value !== "joint",
      );
    }
    page.off("download", countCancelledWindowJoint);
    assert.equal(cancelledWindowJointDownloads, 0);
    await page.locator("#transit-windows-mode").selectOption("joint");
    await selectWindowJointFrame(3);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(directory, "transit-windows-analysis-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(
        directory,
        "transit-windows-analysis-desktop-preview.png",
      ),
    });

    const importWindowJointCheckpoint = async (
      checkpoint,
      name = "window-joint.json",
    ) => {
      await page
        .locator("#transit-windows-analysis-checkpoint-file")
        .setInputFiles({
          name,
          mimeType: "application/json",
          buffer: Buffer.from(
            typeof checkpoint === "string"
              ? checkpoint
              : JSON.stringify(checkpoint),
          ),
        });
      await page.waitForFunction(
        () =>
          document.querySelector("#transit-windows-analysis-checkpoint-file")
            .value === "",
      );
    };
    const badWindowJointVersion = JSON.parse(
      JSON.stringify(windowJoint.checkpoint),
    );
    badWindowJointVersion.checkpoint_version = "99";
    const badWindowJointTime = JSON.parse(
      JSON.stringify(windowJointCheckpoint),
    );
    badWindowJointTime.windows.last_timestamp_us = "400001";
    const badWindowJointDefinitions = JSON.parse(
      JSON.stringify(windowJointCheckpoint),
    );
    badWindowJointDefinitions.windows.gates[0].end_m[0] += 0.1;
    const badWindowJointCapacity = JSON.parse(
      JSON.stringify(windowJointCheckpoint),
    );
    badWindowJointCapacity.windows.config.max_tracks += 1;
    const badWindowJointCounts = JSON.parse(
      JSON.stringify(windowJointCheckpoint),
    );
    badWindowJointCounts.windows.counts[0].completed = "1";
    for (const checkpoint of [
      badWindowJointVersion,
      badWindowJointTime,
      badWindowJointDefinitions,
      badWindowJointCapacity,
      badWindowJointCounts,
      transitJoint.checkpoint,
      independentWindows.checkpoint,
    ]) {
      await importWindowJointCheckpoint(checkpoint);
      assert.equal(
        await page.locator("#transit-windows-joint-message.error").count(),
        1,
      );
      assert.equal(await page.locator("#source").inputValue(), warehouseInput);
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        evidenceTransitConfig,
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        windowConfiguration,
      );
      assert.deepEqual(await exportWindowJoint(), windowJoint);
    }
    await importWindowJointCheckpoint(windowJointCheckpoint);
    assert.equal(
      await page.locator("#transit-windows-joint-message.error").count(),
      0,
    );
    const windowJointResumeSource = await page.locator("#source").inputValue();
    assert.deepEqual(
      JSON.parse(windowJointResumeSource).resume,
      windowJointCheckpoint.analysis.measurement,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#evidence-transit-input").inputValue())
        .resume,
      windowJointCheckpoint.analysis.transit,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#transit-windows-input").inputValue())
        .resume,
      windowJointCheckpoint.windows,
    );
    assert.equal(
      await page.locator("#download-transit-windows-analysis").isDisabled(),
      true,
    );
    await page
      .locator("#source")
      .fill(
        windowJointResumeSource +
          evidenceTransitWarehouseLines.slice(4).join("\n") +
          "\n",
      );
    await runWindowJoint(7);
    const resumedWindowJoint = await exportWindowJoint();
    assert.deepEqual(resumedWindowJoint.frames, windowJoint.frames.slice(3));
    assert.deepEqual(resumedWindowJoint.checkpoint, windowJoint.checkpoint);
    // A fresh statistics baseline at an already-started analysis preserves its
    // pending entry and counts only later input frames.
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runWindowJoint(7);
    const freshStartedWindowJoint = await exportWindowJoint();
    assert.equal(
      freshStartedWindowJoint.checkpoint.windows.baseline_timestamp_us,
      "400000",
    );
    assert.equal(
      freshStartedWindowJoint.frames[0].windows.current_window.input_frames,
      "1",
    );
    assert.deepEqual(
      freshStartedWindowJoint.frames.map((f) => f.analysis),
      windowJoint.frames.slice(3).map((f) => f.analysis),
    );
    // Ground mode retains anisotropic covariance and matches the old host chain.
    await page.locator("#source").fill(groundTransitJointSource);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(groundTransitJointConfig));
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(4);
    await runWindows("joint", 4);
    const groundWindowIndependent = await exportWindows();
    await runWindowJoint(4);
    const groundWindowJoint = await exportWindowJoint();
    assert.deepEqual(
      groundWindowJoint.frames.map((f) => f.analysis),
      groundTransitJoint.frames,
    );
    assert.deepEqual(
      groundWindowJoint.frames.map((f) => f.windows),
      groundWindowIndependent.frames,
    );

    await importWindowJointCheckpoint(groundWindowJoint.checkpoint);
    assert.equal(
      await page.locator("#transit-windows-joint-message.error").count(),
      0,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#source").inputValue()).resume,
      groundWindowJoint.checkpoint.analysis.measurement,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#transit-windows-input").inputValue())
        .resume,
      groundWindowJoint.checkpoint.windows,
    );
    await page.locator("#source").fill(groundTransitJointSource);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(groundTransitJointConfig));
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(4);
    await runWindowJoint(4);
    assert.deepEqual(await exportWindowJoint(), groundWindowJoint);
    // A real origin failure occurs after the upstream candidate update. The
    // browser exposes no partial joint batch and leaves the existing v16 report.
    await page
      .locator("#transit-windows-input")
      .fill(
        '{"window_us":"500000","duration_limits_us":["100000"],"origin_us":"1"}',
      );
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-joint-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-transit-windows-analysis").isDisabled(),
      true,
    );
    assert.deepEqual(await exportTransitJoint(), groundTransitJoint);
    for (const raw of [
      '{"window_us":500000.0000000000000001,"duration_limits_us":["100000"]}',
      '{"window_us":"500000","window_us":"500001","duration_limits_us":["100000"]}',
      '{"window_us":"500000","duration_limits_us":["100000"],"transit":"unexpected"}',
    ]) {
      await page.locator("#transit-windows-input").fill(raw);
      await page.locator("#transit-windows-analyze").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#transit-windows-joint-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        raw,
      );
    }
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(fractionalTransitJointConfig));
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-joint-message")
        .classList.contains("error"),
    );
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(groundTransitJointConfig));
    await page
      .locator("#source")
      .fill(
        groundTransitJointSource.replace(
          '"track_id":1',
          '"track_id":1.0000000000000001',
        ),
      );
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-joint-message")
        .classList.contains("error"),
    );
    await page
      .locator("#source")
      .fill(
        groundTransitJointSource.replace(
          '"track_id":1',
          '"track_id":1,"track_id":1',
        ),
      );
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-joint-message")
        .classList.contains("error"),
    );
    // Joint results bind raw inputs rather than other report objects.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await runWindowJoint(10);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await page.locator("#evidence-transit-analyze").click();
    await waitTransitJoint(10);
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    await page.locator("#evidence-transit-ordinary").click();
    await waitEvidenceTransit(10);
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    for (const origin of ["independent", "joint", "guarded"]) {
      await runWindows(origin, origin === "guarded" ? 17 : 10);
      await page.locator("#transit-windows-mode").selectOption("joint");
      assert.deepEqual(await exportWindowJoint(), windowJoint);
    }
    // Upstream report invalidation must not cancel an unrelated raw-joint run.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 10 帧"),
    );
    await releaseEvidenceTransitPreparation();
    await waitWindowJoint(10);
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    // Explicit joint/downstream run choices and mode changes supersede old work.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runWindows("guarded", 17);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "independent",
    );
    assert.deepEqual(await exportWindows(), guardedWindows);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runWindowJoint(10);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "joint",
    );
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    for (const selector of [
      "#source",
      "#evidence-transit-input",
      "#transit-windows-input",
    ]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#transit-windows-analyze").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-transit-windows-analysis").isDisabled(),
        true,
      );
      assert.equal(await page.locator(selector).inputValue(), previous + " ");
      await page.locator(selector).fill(previous);
      await runWindowJoint(10);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#transit-windows-mode").selectOption("independent");
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "independent",
    );
    await page.locator("#transit-windows-mode").selectOption("joint");
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    // A valid whole import supersedes a busy preparation. A late file read
    // cannot replace a later raw edit in any of the three shared inputs.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await importWindowJointCheckpoint(windowJointCheckpoint);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-analyze").isDisabled(),
      false,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#transit-windows-input").inputValue())
        .resume,
      windowJointCheckpoint.windows,
    );
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "window-joint-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseWindowJointRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page
      .locator("#transit-windows-analysis-checkpoint-file")
      .setInputFiles({
        name: "window-joint-late.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(windowJointCheckpoint)),
      });
    await page.waitForFunction(
      () => typeof window.releaseWindowJointRead === "function",
    );
    const untouchedWindowTransit = await page
      .locator("#evidence-transit-input")
      .inputValue();
    const untouchedWindowConfig = await page
      .locator("#transit-windows-input")
      .inputValue();
    await page.locator("#source").fill("newer raw joint-window draft");
    await page.evaluate(() => {
      window.releaseWindowJointRead();
      delete window.releaseWindowJointRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#transit-windows-analysis-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      "newer raw joint-window draft",
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      untouchedWindowTransit,
    );
    assert.equal(
      await page.locator("#transit-windows-input").inputValue(),
      untouchedWindowConfig,
    );
    // Int64 boundary formatting and bounded huge-gap output also survive joint mode.
    await page.locator("#source").fill(windowClockSource);
    await page
      .locator("#evidence-transit-input")
      .fill(JSON.stringify(windowClockTransit));
    await page
      .locator("#transit-windows-input")
      .fill(
        '{"window_us":"1","duration_limits_us":["0","9223372036854775807"]}',
      );
    await runWindowJoint(3);
    const clockWindowJoint = await exportWindowJoint();
    assert.deepEqual(
      clockWindowJoint.frames.map((f) => f.windows),
      clockWindows.frames,
    );
    assert.match(
      await page.locator("#transit-windows-current-summary").textContent(),
      /9223372036854775807.*Int64 时钟上限/,
    );
    // Leave the complete joint warehouse preview available for inspection.
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runWindowJoint(10);
    await selectWindowJointFrame(3);

    // Health, raw evidence transit and windows use the original v17 paired
    // source/control text; ordinary measurement/transit inputs stay unrelated.
    await importGuardedTransit(healthTransitSource);
    const healthWindowOrdinaryInput = await page
      .locator("#source")
      .inputValue();
    const healthWindowTransitInput = await page
      .locator("#evidence-transit-input")
      .inputValue();
    const runHealthWindows = async (count) => {
      await page.locator("#transit-windows-guarded-analyze").click();
      await page.waitForFunction(() => {
        const message = document.querySelector(
          "#transit-windows-guarded-message",
        );
        return (
          message.textContent.includes("已联合处理") ||
          message.classList.contains("error")
        );
      });
      assert.equal(
        await page.locator("#transit-windows-guarded-message.error").count(),
        0,
      );
      assert.match(
        await page.locator("#transit-windows-guarded-message").textContent(),
        new RegExp("已联合处理 " + count + " 帧"),
      );
    };
    const exportHealthWindows = () =>
      exportJson(
        "#download-transit-windows-guarded",
        "moonground-guarded-transit-windows-results.json",
      );
    const selectHealthWindowFrame = (index) =>
      page
        .locator("#transit-windows-guarded-frame")
        .evaluate((input, value) => {
          input.value = String(value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }, index);
    await runHealthWindows(17);
    const healthWindowJoint = await exportHealthWindows();
    assert.equal(
      healthWindowJoint.checkpoint.format,
      "moonground.evidence-guarded-transit-windows",
    );
    assert.deepEqual(
      healthWindowJoint.checkpoint.guarded,
      healthTransit.checkpoint,
    );
    assert.deepEqual(
      healthWindowJoint.checkpoint.windows,
      guardedWindows.checkpoint,
    );
    healthWindowJoint.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "evidence_guarded_transit_window_frame");
      assert.deepEqual(frame.guarded, healthTransit.frames[index]);
      assert.deepEqual(frame.windows, guardedWindows.frames[index]);
    });
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "guarded",
    );
    assert.equal(
      await page.locator("#download-transit-windows").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#download-transit-windows-analysis").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      healthWindowOrdinaryInput,
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      healthWindowTransitInput,
    );
    await page.locator("#transit-windows-mode").selectOption("joint");
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    assert.equal(
      await page.locator("#download-transit-windows-guarded").isDisabled(),
      true,
    );
    await page.locator("#transit-windows-mode").selectOption("guarded");
    await selectHealthWindowFrame(6);
    assert.match(
      await page.locator("#transit-windows-guarded-status").textContent(),
      /已阻断.*被抑制目标：1/,
    );
    assert.match(
      await page.locator("#transit-windows-joint-summary").textContent(),
      /取消 1.*关闭测量片段：1/,
    );
    assert.equal(
      await page.locator("#transit-windows-joint-tracks tr").count(),
      1,
    );
    assert.equal(
      await page.locator("#transit-windows-joint-tracks").textContent(),
      "本帧无目标测量。",
    );
    assert.match(
      await page.locator("#transit-windows-current-summary").textContent(),
      /输入 2 帧/,
    );
    await selectHealthWindowFrame(16);
    assert.match(
      await page.locator("#transit-windows-guarded-status").textContent(),
      /切换标定.*已阻断.*2 次标定切换/,
    );
    assert.match(
      await page.locator("#transit-windows-joint-summary").textContent(),
      /取消 2/,
    );

    await selectHealthWindowFrame(3);
    const healthWindowPendingCP = await exportJson(
      "#save-transit-windows-guarded-checkpoint",
      "moonground-guarded-transit-windows-checkpoint.json",
    );
    assert.deepEqual(
      healthWindowPendingCP.guarded,
      healthTransitPendingCheckpoint,
    );
    assert.equal(healthWindowPendingCP.windows.last_timestamp_us, "350000");
    assert.equal(
      healthWindowPendingCP.guarded.health.state.last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthWindowPendingCP.guarded.analysis.measurement.motion
        .last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthWindowPendingCP.guarded.analysis.transit.counting.state
        .last_timestamp_us,
      "350000",
    );
    assert.equal(
      healthWindowPendingCP.guarded.analysis.transit.pending.length,
      2,
    );
    await selectHealthWindowFrame(9);
    const healthWindowBarrierCP = await exportJson(
      "#save-transit-windows-guarded-checkpoint",
      "moonground-guarded-transit-windows-checkpoint.json",
    );
    assert.equal(healthWindowBarrierCP.windows.last_timestamp_us, "950000");
    assert.equal(healthWindowBarrierCP.guarded.health.state.streak, null);
    assert.deepEqual(
      healthWindowBarrierCP.guarded.analysis.transit.pending,
      [],
    );
    assert.deepEqual(
      healthWindowBarrierCP.guarded.analysis.measurement.configuration
        .calibration,
      healthWindowBarrierCP.guarded.health.configuration.calibration,
    );
    assert.equal(
      healthWindowBarrierCP.windows.current_window.input_frames,
      "5",
    );
    await selectHealthWindowFrame(15);
    const healthWindowWarmCP = await exportJson(
      "#save-transit-windows-guarded-checkpoint",
      "moonground-guarded-transit-windows-checkpoint.json",
    );
    assert.deepEqual(healthWindowWarmCP.guarded, healthTransitWarmCheckpoint);
    assert.equal(healthWindowWarmCP.windows.last_timestamp_us, "1550000");

    const importHealthWindowCP = async (
      checkpoint,
      name = "health-windows.json",
    ) => {
      await page
        .locator("#transit-windows-guarded-checkpoint-file")
        .setInputFiles({
          name,
          mimeType: "application/json",
          buffer: Buffer.from(
            typeof checkpoint === "string"
              ? checkpoint
              : JSON.stringify(checkpoint),
          ),
        });
      await page.waitForFunction(
        () =>
          document.querySelector("#transit-windows-guarded-checkpoint-file")
            .value === "",
      );
    };
    const healthWindowBadVersion = JSON.parse(
      JSON.stringify(healthWindowPendingCP),
    );
    healthWindowBadVersion.checkpoint_version = "99";
    const healthWindowBadTime = JSON.parse(
      JSON.stringify(healthWindowPendingCP),
    );
    healthWindowBadTime.guarded.health.state.last_timestamp_us = "350001";
    const healthWindowBadFirst = JSON.parse(
      JSON.stringify(healthWindowPendingCP),
    );
    healthWindowBadFirst.windows.current_window.first_timestamp_us = "1";
    const healthWindowBadDefinitions = JSON.parse(
      JSON.stringify(healthWindowPendingCP),
    );
    healthWindowBadDefinitions.windows.gates[0].end_m[0] += 0.1;
    const healthWindowBadProjection = JSON.parse(
      JSON.stringify(healthWindowPendingCP),
    );
    healthWindowBadProjection.guarded.health.configuration.calibration.matrix[2] += 1;
    for (const checkpoint of [
      healthWindowBadVersion,
      healthWindowBadTime,
      healthWindowBadFirst,
      healthWindowBadDefinitions,
      healthWindowBadProjection,
      JSON.stringify(healthWindowPendingCP).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
      healthTransit.checkpoint,
      windowJoint.checkpoint,
      guardedWindows.checkpoint,
    ]) {
      await importHealthWindowCP(checkpoint);
      assert.equal(
        await page.locator("#transit-windows-guarded-message.error").count(),
        1,
      );
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        healthTransitSource,
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        windowConfiguration,
      );
      assert.equal(
        await page.locator("#source").inputValue(),
        healthWindowOrdinaryInput,
      );
      assert.equal(
        await page.locator("#evidence-transit-input").inputValue(),
        healthWindowTransitInput,
      );
      assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    }
    await importHealthWindowCP(healthWindowPendingCP);
    assert.equal(
      await page.locator("#transit-windows-guarded-message.error").count(),
      0,
    );
    const healthWindowResumeInput = await page
      .locator("#guarded-input")
      .inputValue();
    assert.deepEqual(
      JSON.parse(healthWindowResumeInput).resume,
      healthWindowPendingCP.guarded,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#transit-windows-input").inputValue())
        .resume,
      healthWindowPendingCP.windows,
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      healthWindowOrdinaryInput,
    );
    assert.equal(
      await page.locator("#evidence-transit-input").inputValue(),
      healthWindowTransitInput,
    );
    assert.equal(
      await page.locator("#download-transit-windows-guarded").isDisabled(),
      true,
    );
    await page
      .locator("#guarded-input")
      .fill(
        healthWindowResumeInput + healthTransitLines.slice(5).join("\n") + "\n",
      );
    await runHealthWindows(13);
    const healthWindowResumed = await exportHealthWindows();
    assert.deepEqual(
      healthWindowResumed.frames,
      healthWindowJoint.frames.slice(4),
    );
    assert.deepEqual(
      healthWindowResumed.checkpoint,
      healthWindowJoint.checkpoint,
    );
    // Selected replacement prefixes preserve cold health and the updated Brown
    // projection; later original paired/control rows resume without rewriting.
    await importHealthWindowCP(healthWindowBarrierCP);
    const healthWindowBarrierResume = await page
      .locator("#guarded-input")
      .inputValue();
    await page
      .locator("#guarded-input")
      .fill(
        healthWindowBarrierResume +
          healthTransitLines.slice(11).join("\n") +
          "\n",
      );
    await runHealthWindows(7);
    const healthWindowBarrierResumed = await exportHealthWindows();
    assert.deepEqual(
      healthWindowBarrierResumed.frames,
      healthWindowJoint.frames.slice(10),
    );
    assert.deepEqual(
      healthWindowBarrierResumed.checkpoint,
      healthWindowJoint.checkpoint,
    );
    // A fresh statistics strategy starts at an old pending-entry checkpoint.
    await importGuardedTransitCheckpoint(healthTransitPendingCheckpoint);
    const healthWindowStartedSource = await page
      .locator("#guarded-input")
      .inputValue();
    await page
      .locator("#guarded-input")
      .fill(
        healthWindowStartedSource +
          healthTransitLines.slice(5).join("\n") +
          "\n",
      );
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runHealthWindows(13);
    const healthWindowStarted = await exportHealthWindows();
    assert.equal(
      healthWindowStarted.checkpoint.windows.baseline_timestamp_us,
      "350000",
    );
    assert.equal(
      healthWindowStarted.frames[0].windows.current_window.input_frames,
      "1",
    );
    assert.equal(
      healthWindowStarted.frames[0].windows.current_window.first_timestamp_us,
      "450000",
    );
    assert.deepEqual(
      healthWindowStarted.frames.map((f) => f.guarded),
      healthTransit.frames.slice(4),
    );

    await importGuardedTransit(healthTransitSource);
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    await runHealthWindows(17);
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => !document.querySelector("#run-evidence-guarded-transit").disabled,
    );
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    // The first blocked candidate can advance old health before origin failure;
    // no partial new batch is exposed and the independent v17 report stays valid.
    await page
      .locator("#transit-windows-input")
      .fill(
        '{"window_us":"500000","duration_limits_us":["100000"],"origin_us":"1"}',
      );
    await page.locator("#transit-windows-guarded-analyze").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#transit-windows-guarded-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-transit-windows-guarded").isDisabled(),
      true,
    );
    assert.deepEqual(await exportGuardedTransit(), healthTransit);
    for (const raw of [
      '{"window_us":500000.0000000000000001,"duration_limits_us":["100000"]}',
      '{"window_us":"500000","window_us":"500001","duration_limits_us":["100000"]}',
      '{"window_us":"500000","duration_limits_us":["100000"],"unknown":true}',
    ]) {
      await page.locator("#transit-windows-input").fill(raw);
      await page.locator("#transit-windows-guarded-analyze").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#transit-windows-guarded-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#transit-windows-input").inputValue(),
        raw,
      );
    }
    await page.locator("#transit-windows-input").fill(windowConfiguration);
    for (const raw of [
      fractionalGuardedTransitHeader + "\n" + healthTransitLines[1] + "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({
          ...JSON.parse(healthTransitLines[1]),
          measurement: JSON.parse(healthTransitLines[1]).measurement.replace(
            '"track_id":1',
            '"track_id":1.0000000000000001',
          ),
        }) +
        "\n",
      healthTransitLines[0] +
        "\n" +
        JSON.stringify({
          ...JSON.parse(healthTransitLines[1]),
          measurement: JSON.parse(healthTransitLines[1]).measurement.replace(
            '"track_id":1',
            '"track_id":1,"track_id":1',
          ),
        }) +
        "\n",
      ...badProjectionOperations.map(
        (operation) =>
          healthTransitLines.slice(0, 10).join("\n") + "\n" + operation + "\n",
      ),
    ]) {
      await page.locator("#guarded-input").fill(raw);
      await page.locator("#transit-windows-guarded-analyze").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#transit-windows-guarded-message")
          .classList.contains("error"),
      );
      assert.equal(await page.locator("#guarded-input").inputValue(), raw);
    }
    await importGuardedTransit(healthTransitSource);
    await runHealthWindows(17);
    // Ordinary raw inputs are unrelated to this slot. Identical v17 reruns
    // replace its old report object without invalidating the new raw-bound one.
    await page.locator("#source").fill(warehouseInput + " ");
    await page
      .locator("#evidence-transit-input")
      .fill(evidenceTransitConfig + " ");
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    await page.locator("#source").fill(warehouseInput);
    await page.locator("#evidence-transit-input").fill(evidenceTransitConfig);
    await runWindowJoint(10);
    await page.locator("#transit-windows-mode").selectOption("guarded");
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    await runWindows("guarded", 17);
    await page.locator("#transit-windows-mode").selectOption("guarded");
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    // Prefix downloads must match the visible selected frame and active mode.
    let cancelledHealthWindowDownloads = 0;
    const countCancelledHealthWindow = () => {
      cancelledHealthWindowDownloads++;
    };
    page.on("download", countCancelledHealthWindow);
    for (const change of ["selection", "mode"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#save-transit-windows-guarded-checkpoint").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      if (change === "selection") await selectHealthWindowFrame(9);
      else await page.locator("#transit-windows-mode").selectOption("joint");
      await releaseEvidenceTransitPreparation();
      await page.waitForFunction(
        () =>
          !document.querySelector("#save-transit-windows-guarded-checkpoint")
            .disabled ||
          document.querySelector("#transit-windows-mode").value !== "guarded",
      );
    }
    page.off("download", countCancelledHealthWindow);
    assert.equal(cancelledHealthWindowDownloads, 0);
    await page.locator("#transit-windows-mode").selectOption("guarded");
    // Three window modes cancel old preparations, keeping inactive reports.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runWindowJoint(10);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "joint",
    );
    assert.deepEqual(await exportWindowJoint(), windowJoint);
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runHealthWindows(17);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-mode").inputValue(),
      "guarded",
    );
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runHealthWindows(17);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    // Shared guarded owners also cancel late operations, without clearing a
    // valid health-window report merely because the same raw v17 input reruns.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => !document.querySelector("#run-evidence-guarded-transit").disabled,
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    await holdEvidenceTransitPreparation();
    await page.locator("#run-evidence-guarded-transit").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runHealthWindows(17);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
    for (const selector of ["#guarded-input", "#transit-windows-input"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#transit-windows-guarded-analyze").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-transit-windows-guarded").isDisabled(),
        true,
      );
      assert.equal(await page.locator(selector).inputValue(), previous + " ");
      await page.locator(selector).fill(previous);
      await runHealthWindows(17);
    }
    // Whole imports supersede a busy run and a late read yields to new input.
    await holdEvidenceTransitPreparation();
    await page.locator("#transit-windows-guarded-analyze").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await importHealthWindowCP(healthWindowPendingCP);
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#transit-windows-guarded-analyze").isDisabled(),
      false,
    );
    assert.deepEqual(
      JSON.parse(await page.locator("#guarded-input").inputValue()).resume,
      healthWindowPendingCP.guarded,
    );
    await page.evaluate(() => {
      const original = File.prototype.text;
      File.prototype.text = function () {
        if (this.name !== "health-window-late.json") return original.call(this);
        File.prototype.text = original;
        const file = this;
        return new Promise((resolve) => {
          window.releaseHealthWindowRead = async () =>
            resolve(await original.call(file));
        });
      };
    });
    await page
      .locator("#transit-windows-guarded-checkpoint-file")
      .setInputFiles({
        name: "health-window-late.json",
        mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify(healthWindowPendingCP)),
      });
    await page.waitForFunction(
      () => typeof window.releaseHealthWindowRead === "function",
    );
    const healthWindowUntouchedConfig = await page
      .locator("#transit-windows-input")
      .inputValue();
    await page.locator("#guarded-input").fill("newer health-window draft");
    await page.evaluate(() => {
      window.releaseHealthWindowRead();
      delete window.releaseHealthWindowRead;
    });
    await page.waitForFunction(
      () =>
        document.querySelector("#transit-windows-guarded-checkpoint-file")
          .value === "",
    );
    assert.equal(
      await page.locator("#guarded-input").inputValue(),
      "newer health-window draft",
    );
    assert.equal(
      await page.locator("#transit-windows-input").inputValue(),
      healthWindowUntouchedConfig,
    );
    // A late old example fetch cannot replace the new health-window draft.
    let releaseHealthWindowExample, healthWindowExampleRequested;
    const healthWindowExampleGate = new Promise((resolve) => {
      releaseHealthWindowExample = resolve;
    });
    const healthWindowExampleRequest = new Promise((resolve) => {
      healthWindowExampleRequested = resolve;
    });
    await page.route("**/evidence-guarded-transit.ndjson", async (route) => {
      healthWindowExampleRequested();
      await healthWindowExampleGate;
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: healthTransitSource,
      });
    });
    try {
      await page.locator("#evidence-guarded-transit-example").click();
      await healthWindowExampleRequest;
      await page.locator("#guarded-input").fill(healthTransitSource);
      await page.locator("#transit-windows-input").fill(windowConfiguration);
      await runHealthWindows(17);
      const sampleResponse = page.waitForResponse((response) =>
        response.url().endsWith("/evidence-guarded-transit.ndjson"),
      );
      releaseHealthWindowExample();
      await (await sampleResponse).finished();
      await page.waitForLoadState("networkidle");
      assert.deepEqual(await exportHealthWindows(), healthWindowJoint);
      assert.equal(
        await page.locator("#guarded-input").inputValue(),
        healthTransitSource,
      );
    } finally {
      releaseHealthWindowExample();
      await page.unroute("**/evidence-guarded-transit.ndjson");
    }
    await selectHealthWindowFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(directory, "guarded-transit-windows-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#transit-windows-section").screenshot({
      path: path.join(directory, "guarded-transit-windows-desktop-preview.png"),
    });
    // Direction evidence consumes ordinary measurements only. Two identities
    // have equal motion and swapped anisotropic covariance, never radial sigma.
    const velocityHeader = {
      session_id: "velocity-ui",
      mode: "ground",
      motion: {
        q: 0.01,
        gate: 1e12,
        initial_velocity_std: 2,
        min_observations: 2,
        min_span_us: "0",
        max_gap_us: "500000",
      },
    };
    const velocityObservations = Array.from({ length: 6 }, (_, index) => ({
      timestamp_us: String(index * 200000),
      observations: [
        { track_id: 2, point: [index * 0.4, 0], covariance: [1, 0, 0.0001] },
        { track_id: 1, point: [index * 0.4, 0], covariance: [0.0001, 0, 1] },
      ],
    })).concat({ timestamp_us: "1200000", observations: [] });
    const velocitySource =
      [velocityHeader, ...velocityObservations]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    const velocityConfiguration = JSON.stringify({
      session_id: "velocity-ui",
      probes: [
        { probe_id: "forward", direction: [1, 0], threshold_mps: 0.5 },
        { probe_id: "reverse", direction: [-1, 0], threshold_mps: 0 },
        { probe_id: "across", direction: [0, 1], threshold_mps: 0 },
        {
          probe_id: "equality",
          direction: [0, 1],
          threshold_mps: 0,
          sigma_multiplier: 0,
        },
        { probe_id: "rescaled", direction: [1e300, 0], threshold_mps: 0.5 },
      ],
    });
    const runVelocityBase = async (input, count) => {
      await page.locator("#source").fill(input);
      await page.locator("#run").click();
      await page.waitForFunction(
        (frames) =>
          document
            .querySelector("#message")
            .textContent.includes("已完成 " + frames + " 帧"),
        count,
      );
      assert.equal(await page.locator("#message.error").count(), 0);
    };
    const runVelocity = async (count) => {
      await page.locator("#velocity-compute").click();
      await page.waitForFunction(() => {
        const message = document.querySelector("#velocity-message");
        return (
          message.textContent.includes("已计算") ||
          message.classList.contains("error")
        );
      });
      const text = await page.locator("#velocity-message").textContent();
      assert.equal(
        await page.locator("#velocity-message.error").count(),
        0,
        text,
      );
      assert.match(text, new RegExp("已计算 " + count + " 帧方向速度证据"));
    };
    const exportVelocity = () =>
      exportJson("#download-velocity", "moonground-velocity-evidence.json");
    const selectVelocityFrame = (index) =>
      page.locator("#frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await page.locator("#velocity-section").evaluate((details) => {
      details.open = true;
    });
    await runVelocityBase(velocitySource, 7);
    const velocityBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    await page.locator("#velocity-input").fill(velocityConfiguration);
    assert.equal(await page.locator("#download-velocity").isDisabled(), true);
    await runVelocity(7);
    const velocityEvidence = await exportVelocity();
    assert.deepEqual(Object.keys(velocityEvidence), ["frames"]);
    velocityEvidence.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "velocity_evidence_frame");
      assert.equal(frame.evidence_scope, "model_velocity_component_band");
      assert.equal(frame.session_id, "velocity-ui");
      assert.equal(frame.timestamp_us, velocityBase.frames[index].timestamp_us);
    });
    assert.deepEqual(velocityEvidence.frames[0].evidence, []);
    assert.deepEqual(velocityEvidence.frames[0].unavailable, [
      { track_id: 1, segment_id: "1", reason: "initializing" },
      { track_id: 2, segment_id: "2", reason: "initializing" },
    ]);
    await selectVelocityFrame(0);
    assert.match(
      await page.locator("#velocity-unavailable").textContent(),
      /初始化/,
    );
    assert.match(
      await page.locator("#velocity-evidence").textContent(),
      /没有可判定/,
    );
    await selectVelocityFrame(5);
    const velocityLast = velocityEvidence.frames[5];
    assert.deepEqual(
      velocityLast.evidence.map((row) => row.track_id),
      [1, 1, 1, 1, 1, 2, 2, 2, 2, 2],
    );
    const firstAxis = velocityLast.evidence.filter((row) => row.track_id === 1);
    const secondAxis = velocityLast.evidence.filter(
      (row) => row.track_id === 2,
    );
    assert.deepEqual(
      firstAxis.map((row) => row.probe_id),
      ["forward", "reverse", "across", "equality", "rescaled"],
    );
    assert.ok(firstAxis[0].axis_std_mps < firstAxis[2].axis_std_mps);
    assert.ok(secondAxis[0].axis_std_mps > secondAxis[2].axis_std_mps);
    assert.equal(firstAxis[0].decision, "above");
    assert.equal(firstAxis[1].decision, "at_or_below");
    assert.equal(firstAxis[2].decision, "indeterminate");
    assert.equal(firstAxis[3].decision, "at_or_below");
    assert.equal(firstAxis[3].component_mps, 0);
    assert.equal(firstAxis[3].lower_mps, 0);
    assert.equal(firstAxis[3].upper_mps, 0);
    assert.ok(firstAxis[3].axis_std_mps > 0);
    assert.equal(firstAxis[0].sigma_multiplier, 2);
    for (const key of [
      "component_mps",
      "axis_std_mps",
      "lower_mps",
      "upper_mps",
      "decision",
    ])
      assert.equal(firstAxis[0][key], firstAxis[4][key]);
    for (const row of velocityLast.evidence) {
      const original = velocityBase.frames[5].tracks.find(
        (track) => track.track_id === row.track_id,
      );
      const expected =
        row.probe_id === "reverse"
          ? -original.velocity_mps[0]
          : row.probe_id === "across" || row.probe_id === "equality"
            ? original.velocity_mps[1]
            : original.velocity_mps[0];
      assert.equal(row.component_mps, expected);
    }
    assert.equal(await page.locator("#velocity-evidence tr").count(), 10);
    assert.match(
      await page.locator("#velocity-evidence").textContent(),
      /确定高于阈值.*确定不高于阈值.*阈值关系未确认/,
    );
    assert.deepEqual(
      JSON.parse(
        await page
          .locator("#velocity-evidence tr")
          .first()
          .getAttribute("title"),
      ),
      velocityLast.evidence[0],
    );
    await selectVelocityFrame(6);
    assert.deepEqual(velocityEvidence.frames[6].evidence, []);
    assert.deepEqual(velocityEvidence.frames[6].unavailable, []);
    assert.match(
      await page.locator("#velocity-frame").textContent(),
      /7 \/ 7.*方向证据 0 行/,
    );
    assert.match(
      await page.locator("#velocity-evidence").textContent(),
      /没有可判定/,
    );

    // Recomputing unchanged original measurements retains the same stateless
    // evidence. Independent gate/guarded configuration edits do not own it.
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    assert.deepEqual(await exportVelocity(), velocityEvidence);
    const velocityGateInput = await page.locator("#gate-input").inputValue();
    await page.locator("#gate-input").fill(velocityGateInput + " ");
    assert.deepEqual(await exportVelocity(), velocityEvidence);
    await page.locator("#gate-input").fill(velocityGateInput);
    const velocityGuardedInput = await page
      .locator("#guarded-input")
      .inputValue();
    await page.locator("#guarded-input").fill(velocityGuardedInput + " ");
    assert.deepEqual(await exportVelocity(), velocityEvidence);
    await page.locator("#guarded-input").fill(velocityGuardedInput);

    // Config is forwarded as raw text. Numeric token fractions, duplicate keys
    // and unsupported small radii fail without damaging ordinary measurements.
    for (const raw of [
      velocityConfiguration.replace('"velocity-ui"', '"wrong-session"'),
      velocityConfiguration.replace('"probes":', '"unknown":true,"probes":'),
      velocityConfiguration.replace(
        '"session_id":"velocity-ui"',
        '"session_id":"velocity-ui","session_id":"velocity-ui"',
      ),
      velocityConfiguration.replace('"reverse"', '"forward"'),
      velocityConfiguration.replace("[1,0]", "[0,0]"),
      velocityConfiguration.replace(
        '"probes":',
        '"max_tracks":10.0000000000000001,"probes":',
      ),
      velocityConfiguration.replace(
        '"probe_id":"forward"',
        '"probe_id":"forward","sigma_multiplier":5e-324',
      ),
      '{"resume":{}}',
      velocityConfiguration + " ".repeat(1048577),
    ]) {
      await page.locator("#velocity-input").fill(raw);
      await page.locator("#velocity-compute").click();
      await page.waitForFunction(() =>
        document.querySelector("#velocity-message").classList.contains("error"),
      );
      assert.equal(await page.locator("#velocity-input").inputValue(), raw);
      assert.equal(await page.locator("#download-velocity").isDisabled(), true);
      assert.deepEqual(
        await exportJson("#download", "moonground-results.json"),
        velocityBase,
      );
    }
    await page.locator("#velocity-input").fill(velocityConfiguration);
    await runVelocity(7);

    // Uncertain retains vectors/covariance upstream but cannot create evidence.
    const velocityUncertainInput =
      [
        {
          ...velocityHeader,
          motion: { ...velocityHeader.motion, max_velocity_std_mps: 1e-12 },
        },
        ...velocityObservations,
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(velocityUncertainInput, 7);
    assert.equal(await page.locator("#download-velocity").isDisabled(), true);
    await runVelocity(7);
    const velocityUncertain = await exportVelocity();
    assert.deepEqual(velocityUncertain.frames[5].evidence, []);
    assert.equal(velocityUncertain.frames[5].unavailable.length, 2);
    assert.ok(
      velocityUncertain.frames[5].unavailable.every(
        (row) => row.reason === "uncertain",
      ),
    );
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#velocity-unavailable").textContent(),
      /不确定性超限/,
    );
    const velocityRejectedInput =
      [
        { ...velocityHeader, motion: { ...velocityHeader.motion, gate: 1e-9 } },
        ...velocityObservations,
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(velocityRejectedInput, 7);
    await runVelocity(7);
    const velocityRejected = await exportVelocity();
    assert.deepEqual(velocityRejected.frames[5].evidence, []);
    assert.ok(
      velocityRejected.frames[5].unavailable.every(
        (row) => row.reason === "rejected_innovation",
      ),
    );
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#velocity-unavailable").textContent(),
      /异常观测/,
    );
    const velocityPixelInput =
      warehouseInput.replace('"warehouse-example"', '"velocity-ui"') +
      JSON.stringify({
        timestamp_us: "2000000",
        observations: [{ track_id: 1, point: [-10, 100] }],
      }) +
      "\n";
    await runVelocityBase(velocityPixelInput, 11);
    await runVelocity(11);
    const velocityPixel = await exportVelocity();
    assert.deepEqual(velocityPixel.frames[10].evidence, []);
    assert.deepEqual(velocityPixel.frames[10].unavailable, [
      { track_id: 1, segment_id: null, reason: "rejected_projection" },
    ]);
    await selectVelocityFrame(10);
    assert.match(
      await page.locator("#velocity-unavailable").textContent(),
      /区域外 \/ 不可测/,
    );

    // Late prepares cannot replace edited config/source or a newer synchronous
    // sample and explicit compute. No new file/fetch or checkpoint owner exists.
    await runVelocityBase(velocitySource, 7);
    await runVelocity(7);
    for (const selector of ["#velocity-input", "#source"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#velocity-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(await page.locator("#download-velocity").isDisabled(), true);
      assert.equal(await page.locator(selector).inputValue(), previous + " ");
      await page.locator(selector).fill(previous);
      if (selector === "#source") {
        await page.locator("#run").click();
        await page.waitForFunction(() =>
          document
            .querySelector("#message")
            .textContent.includes("已完成 7 帧"),
        );
      }
      await runVelocity(7);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#velocity-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#velocity-example").click();
    const velocitySampleConfig = await page
      .locator("#velocity-input")
      .inputValue();
    assert.equal(JSON.parse(velocitySampleConfig).session_id, "velocity-ui");
    assert.equal(await page.locator("#download-velocity").isDisabled(), true);
    await runVelocity(7);
    const velocitySampleResult = await exportVelocity();
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#velocity-input").inputValue(),
      velocitySampleConfig,
    );
    assert.deepEqual(await exportVelocity(), velocitySampleResult);

    await holdEvidenceTransitPreparation();
    await page.locator("#velocity-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportVelocity(), velocitySampleResult);
    await selectVelocityFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#velocity-section").screenshot({
      path: path.join(directory, "velocity-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#velocity-section").screenshot({
      path: path.join(directory, "velocity-evidence-desktop-preview.png"),
    });
    // Current metric zones reuse ordinary positions/covariance. There is no
    // inferred occupancy or exact ellipse/polygon intersection claim.
    const zoneWide = [
      [-10, -10],
      [10, -10],
      [10, 10],
      [-10, 10],
    ];
    const zoneFresh = {
      session_id: "velocity-ui",
      zones: [
        { zone_id: "wide", vertices_m: zoneWide },
        {
          zone_id: "far",
          vertices_m: [
            [5, 5],
            [6, 5],
            [6, 6],
            [5, 6],
          ],
        },
        {
          zone_id: "strip",
          vertices_m: [
            [-10, -0.25],
            [10, -0.25],
            [10, 0.25],
            [-10, 0.25],
          ],
        },
        {
          zone_id: "boundary",
          vertices_m: [
            [0, 0],
            [3, 0],
            [3, 1],
            [0, 1],
          ],
          sigma_multiplier: 0,
        },
        { zone_id: "wide-cw", vertices_m: [...zoneWide].reverse() },
      ],
    };
    const zoneConfiguration = JSON.stringify(zoneFresh);
    const runZones = async (count) => {
      await page.locator("#zone-compute").click();
      await page.waitForFunction(() => {
        const message = document.querySelector("#zone-message");
        return (
          message.textContent.includes("已计算") ||
          message.classList.contains("error")
        );
      });
      const text = await page.locator("#zone-message").textContent();
      assert.equal(await page.locator("#zone-message.error").count(), 0, text);
      assert.match(text, new RegExp("已计算 " + count + " 帧凸区域位置证据"));
    };
    const exportZones = () =>
      exportJson("#download-zones", "moonground-zone-evidence.json");
    await page.locator("#zone-section").evaluate((details) => {
      details.open = true;
    });
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    const zoneEvidence = await exportZones();
    assert.deepEqual(Object.keys(zoneEvidence), ["frames"]);
    zoneEvidence.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "zone_evidence_frame");
      assert.equal(frame.evidence_scope, "model_position_halfplane_bands");
      assert.equal(frame.session_id, "velocity-ui");
      assert.equal(frame.timestamp_us, velocityBase.frames[index].timestamp_us);
    });
    assert.deepEqual(zoneEvidence.frames[0].evidence, []);
    assert.deepEqual(zoneEvidence.frames[0].unavailable, [
      { track_id: 1, segment_id: "1", reason: "initializing" },
      { track_id: 2, segment_id: "2", reason: "initializing" },
    ]);
    const zoneLast = zoneEvidence.frames[5];
    assert.deepEqual(
      zoneLast.evidence.map((row) => row.track_id),
      [1, 1, 1, 1, 1, 2, 2, 2, 2, 2],
    );
    assert.deepEqual(
      zoneLast.evidence.slice(0, 5).map((row) => row.zone_id),
      ["wide", "far", "strip", "boundary", "wide-cw"],
    );
    assert.deepEqual(
      zoneLast.evidence.slice(0, 5).map((row) => row.decision),
      ["inside", "outside", "indeterminate", "inside", "inside"],
    );
    assert.equal(zoneLast.evidence[7].decision, "inside");
    zoneLast.evidence.forEach((row) => {
      assert.equal(row.faces.length, 4);
      assert.deepEqual(
        row.faces.map((face) => face.edge_index),
        [0, 1, 2, 3],
      );
      const first = row.faces.findIndex((face) => face.lower_m > 0);
      assert.equal(
        row.separating_edge_index,
        row.decision === "outside" ? first : null,
      );
    });
    assert.equal(zoneLast.evidence[1].separating_edge_index, 0);
    closeMeasurement(zoneLast.evidence[0].faces[0].outward_normal, [0, -1]);
    closeMeasurement(zoneLast.evidence[4].faces[0].outward_normal, [0, 1]);
    const zoneBottom1 = zoneLast.evidence[2].faces[0];
    const zoneBottom2 = zoneLast.evidence[7].faces[0];
    assert.ok(zoneBottom1.normal_std_m > zoneBottom2.normal_std_m);
    assert.equal(zoneLast.evidence[3].faces[0].upper_m, 0);
    assert.equal(zoneLast.evidence[3].faces[0].lower_m, 0);
    assert.ok(zoneLast.evidence[3].faces[0].normal_std_m > 0);
    await selectVelocityFrame(0);
    assert.match(
      await page.locator("#zone-unavailable").textContent(),
      /初始化/,
    );
    assert.match(
      await page.locator("#zone-evidence").textContent(),
      /没有可判定/,
    );
    await selectVelocityFrame(5);
    assert.equal(await page.locator("#zone-evidence tr").count(), 10);
    assert.match(
      await page.locator("#zone-evidence").textContent(),
      /确认在区域内.*确认在区域外.*区域关系未确认/,
    );
    await page.locator("#zone-face-selection").selectOption("1");
    assert.equal(await page.locator("#zone-faces tr").count(), 4);
    assert.deepEqual(
      JSON.parse(
        await page.locator("#zone-faces tr").first().getAttribute("title"),
      ),
      zoneLast.evidence[1].faces[0],
    );
    await page.locator("#zone-face-selection").selectOption("7");
    await selectVelocityFrame(4);
    assert.equal(await page.locator("#zone-face-selection").inputValue(), "7");
    await selectVelocityFrame(6);
    assert.deepEqual(zoneEvidence.frames[6].evidence, []);
    assert.deepEqual(zoneEvidence.frames[6].unavailable, []);
    assert.equal(await page.locator("#zone-face-selection").isDisabled(), true);
    assert.equal(await page.locator("#zone-faces tr").count(), 0);
    assert.match(
      await page.locator("#zone-frame").textContent(),
      /7 \/ 7.*区域证据 0 行/,
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    assert.deepEqual(await exportZones(), zoneEvidence);
    assert.deepEqual(await exportVelocity(), velocitySampleResult);

    // Config dependencies are independent of velocity, gates and guarded input.
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportZones(), zoneEvidence);
      await page.locator(selector).fill(previous);
    }
    await runVelocity(7);
    const zoneVelocityReference = await exportVelocity();
    await page.locator("#zone-input").fill(zoneConfiguration + " ");
    assert.equal(await page.locator("#download-zones").isDisabled(), true);
    assert.deepEqual(await exportVelocity(), zoneVelocityReference);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);

    // Strict geometry, raw integer tokens and pre-frame facet capacity limits.
    const zoneInvalidGeometries = [
      [
        [0, 0],
        [1, 0],
        [1, 0],
        [0, 1],
      ],
      [
        [0, 0],
        [1, 0],
        [2, 0],
        [2, 1],
        [0, 1],
      ],
      [
        [0, 0],
        [2, 0],
        [1, 1],
        [2, 2],
        [0, 2],
      ],
      [
        [0, 0],
        [2, 3],
        [4, 0],
        [0, 2],
        [4, 2],
      ],
      [
        [0, 0],
        [1, 0],
      ],
    ];
    const zoneBadInputs = [
      ...zoneInvalidGeometries.map((vertices_m) =>
        JSON.stringify({
          session_id: "velocity-ui",
          zones: [{ zone_id: "bad", vertices_m }],
        }),
      ),
      zoneConfiguration.replace('"velocity-ui"', '"wrong-session"'),
      zoneConfiguration.replace('"zones":', '"unknown":true,"zones":'),
      zoneConfiguration.replace(
        '"session_id":"velocity-ui"',
        '"session_id":"velocity-ui","session_id":"velocity-ui"',
      ),
      zoneConfiguration.replace('"far"', '"wide"'),
      zoneConfiguration.replace(
        '"zones":',
        '"max_tracks":1000.0000000000000001,"zones":',
      ),
      zoneConfiguration.replace(
        '"zone_id":"wide"',
        '"zone_id":"wide","sigma_multiplier":5e-324',
      ),
      JSON.stringify({ ...zoneFresh, max_tracks: 1 }),
      JSON.stringify({ ...zoneFresh, max_tracks: 3277 }),
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [{ zone_id: "x".repeat(129), vertices_m: zoneWide }],
      }),
      '{"resume":{}}',
      zoneConfiguration + " ".repeat(1048577),
    ];
    for (const raw of zoneBadInputs) {
      await page.locator("#zone-input").fill(raw);
      await page.locator("#zone-compute").click();
      await page.waitForFunction(() =>
        document.querySelector("#zone-message").classList.contains("error"),
      );
      assert.equal(await page.locator("#zone-input").inputValue(), raw);
      assert.equal(await page.locator("#download-zones").isDisabled(), true);
      assert.deepEqual(
        await exportJson("#download", "moonground-results.json"),
        velocityBase,
      );
      assert.deepEqual(await exportVelocity(), zoneVelocityReference);
    }
    const zoneCapacityBoundary = {
      session_id: "velocity-ui",
      max_tracks: 8192,
      zones: [
        { zone_id: "one", vertices_m: zoneWide },
        { zone_id: "two", vertices_m: zoneWide },
      ],
    };
    await page
      .locator("#zone-input")
      .fill(JSON.stringify(zoneCapacityBoundary));
    await runZones(7); // 8192 × 8 faces = 65536.
    await page
      .locator("#zone-input")
      .fill(JSON.stringify({ ...zoneCapacityBoundary, max_tracks: 8193 }));
    await page.locator("#zone-compute").click();
    await page.waitForFunction(() =>
      document.querySelector("#zone-message").classList.contains("error"),
    );
    assert.equal(await page.locator("#download-zones").isDisabled(), true);

    // The known disjoint corner example remains Indeterminate under the
    // sufficient per-face rule; the UI must not label that as an intersection.
    const zoneCornerHeader = { ...velocityHeader, session_id: "zones-corner" };
    const zoneCornerInput =
      [
        zoneCornerHeader,
        ...[0, 200000].map((timestamp) => ({
          timestamp_us: String(timestamp),
          observations: [
            { track_id: 1, point: [1.2, 1.2], covariance: [0.0625, 0, 0.0625] },
          ],
        })),
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    const zoneUnitSquare = {
      session_id: "zones-corner",
      zones: [
        {
          zone_id: "unit-square",
          vertices_m: [
            [0, 0],
            [1, 0],
            [1, 1],
            [0, 1],
          ],
          sigma_multiplier: 1,
        },
      ],
    };
    await runVelocityBase(zoneCornerInput, 2);
    await page.locator("#zone-input").fill(JSON.stringify(zoneUnitSquare));
    await runZones(2);
    const zoneCornerBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const zoneCornerEvidence = await exportZones();
    const zoneCorner = zoneCornerEvidence.frames[1].evidence[0];
    assert.equal(zoneCorner.decision, "indeterminate");
    assert.equal(zoneCorner.separating_edge_index, null);
    assert.ok(zoneCorner.faces.every((face) => face.lower_m <= 0));
    const cornerTrack = zoneCornerBase.frames[1].tracks[0];
    assert.ok(
      Math.hypot(cornerTrack.position_m[0] - 1, cornerTrack.position_m[1] - 1) >
        cornerTrack.position_std_m,
    );
    await selectVelocityFrame(1);
    assert.match(
      await page.locator("#zone-evidence").textContent(),
      /区域关系未确认/,
    );

    // A rounded unit normal cannot move the exact sloped vertex outside the
    // original closed triangle. k0 retains the core's compensated edge test.
    const zoneSlopedInput =
      [
        { ...velocityHeader, session_id: "zones-sloped" },
        ...[0, 200000].map((timestamp) => ({
          timestamp_us: String(timestamp),
          observations: [{ track_id: 1, point: [3, 4], covariance: [1, 0, 1] }],
        })),
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(zoneSlopedInput, 2);
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "zones-sloped",
        zones: [
          {
            zone_id: "triangle",
            vertices_m: [
              [0, 0],
              [3, 4],
              [0, 5],
            ],
            sigma_multiplier: 0,
          },
        ],
      }),
    );
    await runZones(2);
    const zoneSloped = await exportZones();
    const zoneSlopedBand = zoneSloped.frames[1].evidence[0];
    assert.equal(zoneSlopedBand.decision, "inside");
    assert.equal(zoneSlopedBand.separating_edge_index, null);
    assert.ok(
      zoneSlopedBand.faces.slice(0, 2).every((face) => face.distance_m === 0),
    );
    assert.ok(zoneSlopedBand.faces.every((face) => face.upper_m <= 0));
    await selectVelocityFrame(1);
    assert.match(
      await page.locator("#zone-evidence").textContent(),
      /确认在区域内/,
    );

    // Only Ready positions are usable, despite retained accepted uncertainty.
    await runVelocityBase(velocityUncertainInput, 7);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    const zoneUncertain = await exportZones();
    assert.deepEqual(zoneUncertain.frames[5].evidence, []);
    assert.ok(
      zoneUncertain.frames[5].unavailable.every(
        (row) => row.reason === "uncertain",
      ),
    );
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#zone-unavailable").textContent(),
      /不确定性超限/,
    );
    await runVelocityBase(velocityRejectedInput, 7);
    await runZones(7);
    const zoneRejected = await exportZones();
    assert.deepEqual(zoneRejected.frames[5].evidence, []);
    assert.ok(
      zoneRejected.frames[5].unavailable.every(
        (row) => row.reason === "rejected_innovation",
      ),
    );
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#zone-unavailable").textContent(),
      /异常观测/,
    );
    await runVelocityBase(velocityPixelInput, 11);
    await runZones(11);
    const zonePixel = await exportZones();
    assert.deepEqual(zonePixel.frames[10].evidence, []);
    assert.deepEqual(zonePixel.frames[10].unavailable, [
      { track_id: 1, segment_id: null, reason: "rejected_projection" },
    ]);
    await selectVelocityFrame(10);
    assert.match(
      await page.locator("#zone-unavailable").textContent(),
      /区域外 \/ 不可测/,
    );

    // Concurrent stateless tools share only the upstream payload. They do not
    // cancel each other; edited own dependencies and new runs supersede old ones.
    await runVelocityBase(velocitySource, 7);
    await runZones(7);
    await runVelocity(7);
    await holdEvidenceTransitPreparation();
    await page.locator("#zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runVelocity(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportZones(), zoneEvidence);
    await holdEvidenceTransitPreparation();
    await page.locator("#velocity-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runZones(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportVelocity(), zoneVelocityReference);

    for (const selector of ["#zone-input", "#source"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#zone-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(await page.locator("#download-zones").isDisabled(), true);
      assert.equal(await page.locator(selector).inputValue(), previous + " ");
      await page.locator(selector).fill(previous);
      if (selector === "#source") {
        await page.locator("#run").click();
        await page.waitForFunction(() =>
          document
            .querySelector("#message")
            .textContent.includes("已完成 7 帧"),
        );
      }
      await runZones(7);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#zone-example").click();
    const zoneSampleConfig = await page.locator("#zone-input").inputValue();
    assert.equal(JSON.parse(zoneSampleConfig).session_id, "velocity-ui");
    await runZones(7);
    const zoneSampleResult = await exportZones();
    await releaseEvidenceTransitPreparation();
    assert.equal(
      await page.locator("#zone-input").inputValue(),
      zoneSampleConfig,
    );
    assert.deepEqual(await exportZones(), zoneSampleResult);
    await holdEvidenceTransitPreparation();
    await page.locator("#zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportZones(), zoneSampleResult);

    // A valid maximum-length ID must not push the small selection control
    // outside the 390px viewport. Tables retain their own horizontal scrolling.
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [{ zone_id: "z".repeat(128), vertices_m: zoneWide }],
      }),
    );
    await runZones(7);
    await selectVelocityFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    await page.locator("#zone-face-selection").selectOption("2");
    await page.locator("#zone-section").screenshot({
      path: path.join(directory, "zone-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    await page.locator("#zone-section").screenshot({
      path: path.join(directory, "zone-evidence-desktop-preview.png"),
    });
    // Explicit disk support uses the existing raw position configuration and
    // original ordinary frames, with an independent result and no checkpoint.
    await runVelocity(7);
    const diskVelocityReference = await exportVelocity();
    const diskConfiguration = '{"radius_m":0.25}';
    const runDiskZones = async (count) => {
      await page.locator("#disk-zone-compute").click();
      await page.waitForFunction((expected) => {
        const message = document.querySelector("#disk-zone-message");
        return (
          message.classList.contains("error") ||
          message.textContent.includes("已计算 " + expected + " 帧")
        );
      }, count);
      const text = await page.locator("#disk-zone-message").textContent();
      assert.equal(
        await page.locator("#disk-zone-message.error").count(),
        0,
        text,
      );
    };
    const exportDiskZones = () =>
      exportJson("#download-disk-zones", "moonground-disk-zone-evidence.json");
    await page.locator("#disk-zone-input").fill('{"radius_m":0}');
    await runDiskZones(7);
    const diskZero = await exportDiskZones();
    assert.deepEqual(Object.keys(diskZero), ["frames"]);
    diskZero.frames.forEach((frame, index) => {
      const point = zoneEvidence.frames[index];
      assert.equal(frame.kind, "disk_zone_evidence_frame");
      assert.equal(
        frame.evidence_scope,
        "model_position_halfplane_bands_plus_explicit_disk",
      );
      assert.equal(frame.session_id, point.session_id);
      assert.equal(frame.timestamp_us, point.timestamp_us);
      assert.deepEqual(frame.unavailable, point.unavailable);
      assert.equal(frame.evidence.length, point.evidence.length);
      frame.evidence.forEach((row, rowIndex) => {
        const original = point.evidence[rowIndex];
        assert.equal(row.radius_m, 0);
        assert.equal(row.track_id, original.track_id);
        assert.equal(row.segment_id, original.segment_id);
        assert.equal(row.zone_id, original.zone_id);
        assert.equal(row.decision, original.decision);
        assert.equal(row.separating_edge_index, original.separating_edge_index);
        assert.equal(row.sigma_multiplier, original.sigma_multiplier);
        row.faces.forEach((face, faceIndex) => {
          const oldFace = original.faces[faceIndex];
          const { position_lower_m, position_upper_m, ...baseFace } = face;
          assert.deepEqual(baseFace, oldFace);
          assert.equal(position_lower_m, oldFace.lower_m);
          assert.equal(position_upper_m, oldFace.upper_m);
        });
      });
    });
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    assert.deepEqual(await exportZones(), zoneEvidence);
    await runDiskZones(7);
    const diskEvidence = await exportDiskZones();
    diskEvidence.frames.forEach((frame, index) => {
      assert.deepEqual(
        frame.unavailable,
        zoneEvidence.frames[index].unavailable,
      );
      frame.evidence.forEach((row, rowIndex) => {
        const point = zoneEvidence.frames[index].evidence[rowIndex];
        assert.equal(row.radius_m, 0.25);
        row.faces.forEach((face, faceIndex) => {
          const original = point.faces[faceIndex];
          assert.equal(face.distance_m, original.distance_m);
          assert.equal(face.normal_std_m, original.normal_std_m);
          assert.deepEqual(face.outward_normal, original.outward_normal);
          assert.equal(face.position_lower_m, original.lower_m);
          assert.equal(face.position_upper_m, original.upper_m);
          assert.ok(face.lower_m < original.lower_m);
          assert.ok(face.upper_m > original.upper_m);
        });
      });
    });
    // The point lies on a closed boundary at k=0, but the nonzero body
    // straddles it. The original statistical sigma is still reported.
    const diskBoundary = diskEvidence.frames[5].evidence[3];
    assert.equal(zoneLast.evidence[3].decision, "inside");
    assert.equal(diskBoundary.decision, "indeterminate");
    assert.equal(diskBoundary.faces[0].position_lower_m, 0);
    assert.equal(diskBoundary.faces[0].position_upper_m, 0);
    assert.equal(diskBoundary.faces[0].lower_m, -0.25);
    assert.equal(diskBoundary.faces[0].upper_m, 0.25);
    assert.ok(diskBoundary.faces[0].normal_std_m > 0);
    await selectVelocityFrame(5);
    assert.equal(await page.locator("#disk-zone-evidence tr").count(), 10);
    await page.locator("#disk-zone-face-selection").selectOption("3");
    assert.deepEqual(
      JSON.parse(
        await page.locator("#disk-zone-faces tr").first().getAttribute("title"),
      ),
      diskBoundary.faces[0],
    );
    assert.equal(
      await page.locator("#disk-zone-faces tr").first().locator("td").count(),
      6,
    );
    await selectVelocityFrame(4);
    assert.equal(
      await page.locator("#disk-zone-face-selection").inputValue(),
      "3",
    );
    await selectVelocityFrame(0);
    assert.match(
      await page.locator("#disk-zone-unavailable").textContent(),
      /初始化/,
    );
    await selectVelocityFrame(6);
    assert.equal(await page.locator("#disk-zone-faces tr").count(), 0);
    assert.equal(
      await page.locator("#disk-zone-face-selection").isDisabled(),
      true,
    );
    await selectVelocityFrame(5);
    // Raw original numeric tokens and duplicate keys reach MoonBit unchanged.
    // Failures leave the ordinary/point/velocity products independently usable.
    const diskBadInputs = [
      "{}",
      '{"radius_m":-0.25}',
      '{"radius_m":"0.25"}',
      '{"radius_m":0.25,"unknown":true}',
      '{"radius_m":0.25,"radius_m":0}',
      '{"radius_m":1e309}',
      '{"radius_m":5e-324}',
      '{"radius_m":1e308}',
      '{"resume":{}}',
      diskConfiguration + " ".repeat(1048577),
    ];
    for (const raw of diskBadInputs) {
      await page.locator("#disk-zone-input").fill(raw);
      await page.locator("#disk-zone-compute").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#disk-zone-message")
          .classList.contains("error"),
      );
      assert.equal(await page.locator("#disk-zone-input").inputValue(), raw);
      assert.equal(
        await page.locator("#download-disk-zones").isDisabled(),
        true,
      );
      assert.deepEqual(await exportZones(), zoneEvidence);
      assert.deepEqual(await exportVelocity(), diskVelocityReference);
    }
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    await runDiskZones(7);
    await page
      .locator("#zone-input")
      .fill(
        zoneConfiguration.replace(
          '"zones":',
          '"max_tracks":1000.0000000000000001,"zones":',
        ),
      );
    assert.equal(await page.locator("#download-zones").isDisabled(), true);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    await page.locator("#disk-zone-compute").click();
    await page.waitForFunction(() =>
      document.querySelector("#disk-zone-message").classList.contains("error"),
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    await runDiskZones(7);
    // A failed preparation under unchanged inputs retains the displayed result.
    await page.evaluate(() => {
      window.diskOriginalTextEncoder = window.TextEncoder;
      window.TextEncoder = class {
        encode() {
          throw new Error("disk UI preparation failed");
        }
      };
    });
    await page.locator("#disk-zone-compute").click();
    await page.waitForFunction(() =>
      document.querySelector("#disk-zone-message").classList.contains("error"),
    );
    await page.evaluate(() => {
      window.TextEncoder = window.diskOriginalTextEncoder;
      delete window.diskOriginalTextEncoder;
    });
    assert.deepEqual(await exportDiskZones(), diskEvidence);
    assert.deepEqual(await exportZones(), zoneEvidence);
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    assert.deepEqual(await exportDiskZones(), diskEvidence);
    // Unrelated directions, gates and health inputs do not own disk evidence.
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportDiskZones(), diskEvidence);
      await page.locator(selector).fill(previous);
    }
    await runVelocity(7);

    // Closed inner tangency is inside. Outer tangency is unconfirmed, since
    // a single-face lower bound of zero is not sufficient separation.
    const diskTangencyConfig = JSON.stringify({
      ...zoneUnitSquare,
      session_id: "disk-tangency",
      zones: zoneUnitSquare.zones.map((zone) => ({
        ...zone,
        sigma_multiplier: 0,
      })),
    });
    for (const [x, expected] of [
      [0.25, "inside"],
      [-0.25, "indeterminate"],
    ]) {
      const input =
        [
          { ...velocityHeader, session_id: "disk-tangency" },
          ...[0, 200000].map((time) => ({
            timestamp_us: String(time),
            observations: [
              { track_id: 1, point: [x, 0.5], covariance: [0.0001, 0, 0.0001] },
            ],
          })),
        ]
          .map(JSON.stringify)
          .join("\n") + "\n";
      await runVelocityBase(input, 2);
      await page.locator("#zone-input").fill(diskTangencyConfig);
      await runDiskZones(2);
      const tangency = (await exportDiskZones()).frames[1].evidence[0];
      assert.equal(tangency.decision, expected);
      assert.equal(tangency.separating_edge_index, null);
      assert.ok(
        tangency.faces.some((face) =>
          expected === "inside" ? face.upper_m === 0 : face.lower_m === 0,
        ),
      );
    }
    for (const [input, count, reason] of [
      [velocityUncertainInput, 7, "uncertain"],
      [velocityRejectedInput, 7, "rejected_innovation"],
      [velocityPixelInput, 11, "rejected_projection"],
    ]) {
      await runVelocityBase(input, count);
      await page.locator("#zone-input").fill(zoneConfiguration);
      await runDiskZones(count);
      const frame = (await exportDiskZones()).frames[count === 11 ? 10 : 5];
      assert.deepEqual(frame.evidence, []);
      assert.ok(frame.unavailable.length > 0);
      assert.ok(frame.unavailable.every((row) => row.reason === reason));
    }
    await runVelocityBase(velocitySource, 7);
    await runZones(7);
    await runVelocity(7);
    await runDiskZones(7);
    // Preparing either point or disk evidence does not supersede the other.
    for (const [held, concurrent] of [
      ["#disk-zone-compute", () => runZones(7)],
      ["#zone-compute", () => runDiskZones(7)],
      ["#disk-zone-compute", () => runVelocity(7)],
    ]) {
      await holdEvidenceTransitPreparation();
      await page.locator(held).click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      await concurrent();
      await releaseEvidenceTransitPreparation();
      assert.deepEqual(await exportDiskZones(), diskEvidence);
      assert.deepEqual(await exportZones(), zoneEvidence);
    }
    for (const selector of ["#disk-zone-input", "#zone-input", "#source"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#disk-zone-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-disk-zones").isDisabled(),
        true,
      );
      assert.equal(await page.locator(selector).inputValue(), previous + " ");
      if (selector === "#disk-zone-input")
        assert.deepEqual(await exportZones(), zoneEvidence);
      else
        assert.equal(await page.locator("#download-zones").isDisabled(), true);
      await page.locator(selector).fill(previous);
      if (selector === "#source") await runVelocityBase(previous, 7);
      await runZones(7);
      await runDiskZones(7);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#disk-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#disk-zone-example").click();
    assert.deepEqual(await exportZones(), zoneEvidence);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    await runDiskZones(7);
    const diskSampleResult = await exportDiskZones();
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportDiskZones(), diskSampleResult);
    await holdEvidenceTransitPreparation();
    await page.locator("#disk-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#run").click();
    await page.waitForFunction(() =>
      document.querySelector("#message").textContent.includes("已完成 7 帧"),
    );
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportDiskZones(), diskSampleResult);
    await page.locator("#zone-example").click();
    assert.equal(await page.locator("#download-zones").isDisabled(), true);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    // Only the selected row's faces are rendered; folded details keep exports.
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [{ zone_id: "z".repeat(128), vertices_m: zoneWide }],
      }),
    );
    await runDiskZones(7);
    await selectVelocityFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    await runDiskZones(7);
    await page.locator("#disk-zone-face-selection").selectOption("3");
    await page.locator("#zone-section").evaluate((details) => {
      details.open = false;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#disk-zone-faces tr").length === 0,
    );
    assert.equal(
      await page.locator("#download-disk-zones").isDisabled(),
      false,
    );
    await page.locator("#zone-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#disk-zone-faces tr").length === 4,
    );
    await page.locator("#disk-zone-results").screenshot({
      path: path.join(directory, "disk-zone-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#disk-zone-results").screenshot({
      path: path.join(directory, "disk-zone-evidence-desktop-preview.png"),
    });
    // Fixed ground-axis offsets have independent options and reports. Rebuild
    // every baseline explicitly after the previous source/cancellation cases.
    await runVelocityBase(velocitySource, 7);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    await runVelocity(7);
    const footprintVelocityBaseline = await exportVelocity();
    await runZones(7);
    const footprintPointBaseline = await exportZones();
    await runDiskZones(7);
    const footprintDiskBaseline = await exportDiskZones();
    const footprintVertices = [
      [-0.25, -0.25],
      [1, -0.25],
      [1, 0.25],
      [-0.25, 0.25],
    ];
    const footprintConfiguration = JSON.stringify({
      vertices_offset_m: footprintVertices,
    });
    const physicalMode = (mode) =>
      page.locator("#physical-zone-mode").selectOption(mode);
    const runFootprintZones = async (count) => {
      await physicalMode("convex");
      await page.locator("#footprint-zone-compute").click();
      await page.waitForFunction((expected) => {
        const message = document.querySelector("#footprint-zone-message");
        return (
          message.classList.contains("error") ||
          message.textContent.includes("已计算 " + expected + " 帧")
        );
      }, count);
      const text = await page.locator("#footprint-zone-message").textContent();
      assert.equal(
        await page.locator("#footprint-zone-message.error").count(),
        0,
        text,
      );
    };
    const exportFootprintZones = () =>
      exportJson(
        "#download-footprint-zones",
        "moonground-footprint-zone-evidence.json",
      );
    await physicalMode("convex");
    assert.equal(await page.locator("#disk-zone-results").isHidden(), true);
    assert.equal(
      await page.locator("#footprint-zone-results").isVisible(),
      true,
    );
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runFootprintZones(7);
    const footprintEvidence = await exportFootprintZones();
    assert.deepEqual(Object.keys(footprintEvidence), ["frames"]);
    footprintEvidence.frames.forEach((frame, index) => {
      const point = footprintPointBaseline.frames[index];
      assert.equal(frame.kind, "footprint_zone_evidence_frame");
      assert.equal(
        frame.evidence_scope,
        "model_position_halfplane_bands_plus_explicit_convex_footprint",
      );
      assert.equal(frame.session_id, point.session_id);
      assert.equal(frame.timestamp_us, point.timestamp_us);
      assert.deepEqual(frame.unavailable, point.unavailable);
      frame.evidence.forEach((row, rowIndex) => {
        const original = point.evidence[rowIndex];
        assert.deepEqual(row.vertices_offset_m, footprintVertices);
        assert.equal("radius_m" in row, false);
        assert.equal(row.track_id, original.track_id);
        assert.equal(row.segment_id, original.segment_id);
        row.faces.forEach((face, faceIndex) => {
          const oldFace = original.faces[faceIndex];
          assert.equal(face.distance_m, oldFace.distance_m);
          assert.equal(face.normal_std_m, oldFace.normal_std_m);
          assert.deepEqual(face.outward_normal, oldFace.outward_normal);
          assert.equal(face.position_lower_m, oldFace.lower_m);
          assert.equal(face.position_upper_m, oldFace.upper_m);
          assert.ok(face.footprint_lower_m <= 0);
          assert.ok(face.footprint_upper_m >= 0);
          assert.ok(face.lower_m <= oldFace.lower_m);
          assert.ok(face.upper_m >= oldFace.upper_m);
        });
      });
    });
    const footprintLast = footprintEvidence.frames[5].evidence;
    assert.deepEqual(
      footprintLast[0].faces.map((face) => [
        face.footprint_lower_m,
        face.footprint_upper_m,
      ]),
      [
        [-0.25, 0.25],
        [-0.25, 1],
        [-0.25, 0.25],
        [-1, 0.25],
      ],
    );
    assert.equal(
      footprintPointBaseline.frames[5].evidence[3].decision,
      "inside",
    );
    assert.equal(footprintLast[3].decision, "indeterminate");
    await selectVelocityFrame(5);
    await page.locator("#footprint-zone-face-selection").selectOption("3");
    assert.equal(await page.locator("#footprint-zone-faces tr").count(), 4);
    assert.equal(
      await page
        .locator("#footprint-zone-faces tr")
        .first()
        .locator("td")
        .count(),
      7,
    );
    assert.deepEqual(
      JSON.parse(
        await page
          .locator("#footprint-zone-faces tr")
          .first()
          .getAttribute("title"),
      ),
      footprintLast[3].faces[0],
    );
    await selectVelocityFrame(4);
    assert.equal(
      await page.locator("#footprint-zone-face-selection").inputValue(),
      "3",
    );
    await selectVelocityFrame(6);
    assert.equal(await page.locator("#footprint-zone-faces tr").count(), 0);
    await selectVelocityFrame(0);
    assert.match(
      await page.locator("#footprint-zone-unavailable").textContent(),
      /初始化/,
    );
    await selectVelocityFrame(5);

    // Display changes are neither a computation nor an invalidation.
    await physicalMode("disk");
    assert.deepEqual(await exportDiskZones(), footprintDiskBaseline);
    assert.equal(await page.locator("#footprint-zone-faces tr").count(), 0);
    assert.deepEqual(await exportZones(), footprintPointBaseline);
    assert.deepEqual(await exportVelocity(), footprintVelocityBaseline);
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), footprintEvidence);
    // Changing one options document preserves the other physical model.
    await page
      .locator("#footprint-zone-input")
      .fill(footprintConfiguration + " ");
    assert.equal(
      await page.locator("#download-footprint-zones").isDisabled(),
      true,
    );
    await physicalMode("disk");
    assert.deepEqual(await exportDiskZones(), footprintDiskBaseline);
    await physicalMode("convex");
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runFootprintZones(7);
    await physicalMode("disk");
    await page.locator("#disk-zone-input").fill(diskConfiguration + " ");
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), footprintEvidence);
    await physicalMode("disk");
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    await runDiskZones(7);

    // A square has exactly the same axis-aligned face supports as a disk of
    // this radius, while an asymmetric shape retains its separate two sides.
    await physicalMode("convex");
    await page.locator("#footprint-zone-input").fill(
      JSON.stringify({
        vertices_offset_m: [
          [-0.25, -0.25],
          [0.25, -0.25],
          [0.25, 0.25],
          [-0.25, 0.25],
        ],
      }),
    );
    await runFootprintZones(7);
    (await exportFootprintZones()).frames.forEach((frame, index) => {
      frame.evidence.forEach((row, rowIndex) => {
        const disk = footprintDiskBaseline.frames[index].evidence[rowIndex];
        assert.equal(row.decision, disk.decision);
        assert.equal(row.separating_edge_index, disk.separating_edge_index);
        row.faces.forEach((face, faceIndex) => {
          const { footprint_lower_m, footprint_upper_m, ...sameFace } = face;
          assert.deepEqual(sameFace, disk.faces[faceIndex]);
          assert.equal(footprint_lower_m, -0.25);
          assert.equal(footprint_upper_m, 0.25);
        });
      });
    });
    await page.locator("#footprint-zone-input").fill(
      JSON.stringify({
        vertices_offset_m: [...footprintVertices].reverse(),
      }),
    );
    await runFootprintZones(7);
    const footprintClockwise = await exportFootprintZones();
    footprintClockwise.frames.forEach((frame, index) =>
      frame.evidence.forEach((row, rowIndex) => {
        const { vertices_offset_m, ...sameRow } = row;
        const { vertices_offset_m: originalVertices, ...originalRow } =
          footprintEvidence.frames[index].evidence[rowIndex];
        assert.deepEqual(vertices_offset_m, [...originalVertices].reverse());
        assert.deepEqual(sameRow, originalRow);
      }),
    );
    const footprintBadGeometries = [
      [
        [0, 0],
        [1, 0],
      ],
      [
        [0, 0],
        [0, 0],
        [1, 1],
      ],
      [
        [-1, 0],
        [0, 0],
        [1, 0],
      ],
      [
        [1, 1],
        [2, 1],
        [1, 2],
      ],
      [
        [-1, -1],
        [1, -1],
        [0, 0],
        [1, 1],
        [-1, 1],
      ],
    ];
    const footprintBadInputs = [
      ...footprintBadGeometries.map((vertices_offset_m) =>
        JSON.stringify({ vertices_offset_m }),
      ),
      "{}",
      '{"radius_m":0.25}',
      '{"resume":{}}',
      footprintConfiguration.replace(
        '"vertices_offset_m":',
        '"unknown":true,"vertices_offset_m":',
      ),
      '{"vertices_offset_m":[[-1,-1],[1,-1],[1,1],[-1,1]],"vertices_offset_m":[]}',
      '{"vertices_offset_m":[[-1,-1],[1e309,-1],[1,1],[-1,1]]}',
      footprintConfiguration + " ".repeat(1048577),
    ];
    for (const raw of footprintBadInputs) {
      await page.locator("#footprint-zone-input").fill(raw);
      await page.locator("#footprint-zone-compute").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#footprint-zone-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#footprint-zone-input").inputValue(),
        raw,
      );
      assert.equal(
        await page.locator("#download-footprint-zones").isDisabled(),
        true,
      );
      assert.deepEqual(await exportZones(), footprintPointBaseline);
      assert.deepEqual(await exportVelocity(), footprintVelocityBaseline);
    }
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runFootprintZones(7);
    await page
      .locator("#zone-input")
      .fill(
        zoneConfiguration.replace(
          '"zones":',
          '"max_tracks":1000.0000000000000001,"zones":',
        ),
      );
    assert.equal(await page.locator("#download-zones").isDisabled(), true);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    assert.equal(
      await page.locator("#download-footprint-zones").isDisabled(),
      true,
    );
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-zone-message")
        .classList.contains("error"),
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    await runFootprintZones(7);
    await physicalMode("disk");
    await runDiskZones(7);
    await physicalMode("convex");
    // A preparation error with unchanged dependencies retains the old report.
    await page.evaluate(() => {
      window.footprintOriginalTextEncoder = window.TextEncoder;
      window.TextEncoder = class {
        encode() {
          throw new Error("footprint UI preparation failed");
        }
      };
    });
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-zone-message")
        .classList.contains("error"),
    );
    await page.evaluate(() => {
      window.TextEncoder = window.footprintOriginalTextEncoder;
      delete window.footprintOriginalTextEncoder;
    });
    assert.deepEqual(await exportFootprintZones(), footprintEvidence);
    await runVelocityBase(velocitySource, 7);
    assert.deepEqual(await exportFootprintZones(), footprintEvidence);
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportFootprintZones(), footprintEvidence);
      await page.locator(selector).fill(previous);
    }
    await runVelocity(7);

    // An anchor on a footprint vertex is legal. Zero physical support on a
    // side must copy the original endpoint, even with nonzero covariance.
    const footprintCornerInput =
      [
        { ...velocityHeader, session_id: "footprint-corner" },
        ...[0, 200000].map((time) => ({
          timestamp_us: String(time),
          observations: [
            { track_id: 1, point: [0, 0], covariance: [0.0001, 0, 0.0001] },
          ],
        })),
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(footprintCornerInput, 2);
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "footprint-corner",
        zones: [{ ...zoneUnitSquare.zones[0], sigma_multiplier: 0 }],
      }),
    );
    await page.locator("#footprint-zone-input").fill(
      JSON.stringify({
        vertices_offset_m: [
          [0, 0],
          [1, 0],
          [1, 0.25],
          [0, 0.25],
        ],
      }),
    );
    await runFootprintZones(2);
    const footprintCorner = (await exportFootprintZones()).frames[1]
      .evidence[0];
    assert.equal(footprintCorner.decision, "inside");
    assert.equal(footprintCorner.separating_edge_index, null);
    assert.equal(footprintCorner.faces[0].footprint_upper_m, 0);
    assert.equal(
      footprintCorner.faces[0].upper_m,
      footprintCorner.faces[0].position_upper_m,
    );
    assert.ok(footprintCorner.faces[0].normal_std_m > 0);
    assert.equal(footprintCorner.faces[1].upper_m, 0);
    for (const [input, count, reason] of [
      [velocityUncertainInput, 7, "uncertain"],
      [velocityRejectedInput, 7, "rejected_innovation"],
      [velocityPixelInput, 11, "rejected_projection"],
    ]) {
      await runVelocityBase(input, count);
      await page.locator("#zone-input").fill(zoneConfiguration);
      await page.locator("#footprint-zone-input").fill(footprintConfiguration);
      await runFootprintZones(count);
      const frame = (await exportFootprintZones()).frames[
        count === 11 ? 10 : 5
      ];
      assert.deepEqual(frame.evidence, []);
      assert.ok(frame.unavailable.length > 0);
      assert.ok(frame.unavailable.every((row) => row.reason === reason));
    }
    await runVelocityBase(velocitySource, 7);
    await runVelocity(7);
    await runZones(7);
    await runFootprintZones(7);
    await physicalMode("disk");
    await runDiskZones(7);
    await physicalMode("convex");
    // Switching display while preparing is allowed. Neither physical model
    // cancels the other's run or lets an old finally clear a newer own task.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await physicalMode("disk");
    await runDiskZones(7);
    await releaseEvidenceTransitPreparation();
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), footprintEvidence);
    await physicalMode("disk");
    await holdEvidenceTransitPreparation();
    await page.locator("#disk-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runFootprintZones(7);
    await releaseEvidenceTransitPreparation();
    await physicalMode("disk");
    assert.deepEqual(await exportDiskZones(), footprintDiskBaseline);
    await physicalMode("convex");
    for (const selector of [
      "#footprint-zone-input",
      "#zone-input",
      "#source",
    ]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#footprint-zone-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-footprint-zones").isDisabled(),
        true,
      );
      if (selector === "#footprint-zone-input")
        assert.deepEqual(await exportZones(), footprintPointBaseline);
      else {
        assert.equal(await page.locator("#download-zones").isDisabled(), true);
        assert.equal(
          await page.locator("#download-disk-zones").isDisabled(),
          true,
        );
      }
      await page.locator(selector).fill(previous);
      if (selector === "#source") await runVelocityBase(previous, 7);
      await runZones(7);
      await runFootprintZones(7);
      await physicalMode("disk");
      await runDiskZones(7);
      await physicalMode("convex");
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#footprint-zone-example").click();
    await runFootprintZones(7);
    const footprintSampleResult = await exportFootprintZones();
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintZones(), footprintSampleResult);
    assert.equal(
      await page.locator("#footprint-zone-input").inputValue(),
      footprintConfiguration,
    );
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runVelocityBase(velocitySource, 7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintZones(), footprintSampleResult);
    await page.locator("#zone-example").click();
    assert.equal(await page.locator("#download-zones").isDisabled(), true);
    assert.equal(await page.locator("#download-disk-zones").isDisabled(), true);
    assert.equal(
      await page.locator("#download-footprint-zones").isDisabled(),
      true,
    );
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [{ zone_id: "z".repeat(128), vertices_m: zoneWide }],
      }),
    );
    await runFootprintZones(7);
    await selectVelocityFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runZones(7);
    await runFootprintZones(7);
    await page.locator("#footprint-zone-face-selection").selectOption("3");
    await page.locator("#zone-section").evaluate((details) => {
      details.open = false;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-zone-faces tr").length === 0,
    );
    assert.equal(
      await page.locator("#download-footprint-zones").isDisabled(),
      false,
    );
    await page.locator("#zone-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-zone-faces tr").length === 4,
    );
    await page.locator("#physical-zone-results").screenshot({
      path: path.join(directory, "footprint-zone-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#physical-zone-results").screenshot({
      path: path.join(directory, "footprint-zone-evidence-desktop-preview.png"),
    });
    // Mixed target shapes use an exact current-frame value bundle, not a
    // persistent ID map. Set up all comparison products explicitly.
    await runVelocityBase(velocitySource, 7);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await physicalMode("disk");
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    await physicalMode("convex");
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runVelocity(7);
    const assignedVelocityBaseline = await exportVelocity();
    await runZones(7);
    const assignedPointBaseline = await exportZones();
    await physicalMode("disk");
    await runDiskZones(7);
    const assignedDiskBaseline = await exportDiskZones();
    await runFootprintZones(7);
    const assignedConvexBaseline = await exportFootprintZones();
    const assignedBase = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const assignmentDocs = (base) =>
      base.frames.map((frame) => ({
        timestamp_us: frame.timestamp_us,
        footprints: frame.tracks.map((track, index) => ({
          track_id: track.track_id,
          segment_id: track.segment_id,
          shape:
            index % 2 === 0
              ? { kind: "disk", radius_m: 0.25 }
              : { kind: "convex", vertices_offset_m: footprintVertices },
        })),
      }));
    const assignmentText = (documents) =>
      documents
        .map((doc) => (typeof doc === "string" ? doc : JSON.stringify(doc)))
        .join("\n") + "\n";
    const assignedDocuments = assignmentDocs(assignedBase);
    const assignedConfiguration = assignmentText(assignedDocuments);
    const runAssignedZones = async (count) => {
      await physicalMode("assigned");
      await page.locator("#assigned-zone-compute").click();
      await page.waitForFunction((expected) => {
        const message = document.querySelector("#assigned-zone-message");
        return (
          message.classList.contains("error") ||
          message.textContent.includes("已计算 " + expected + " 帧")
        );
      }, count);
      const text = await page.locator("#assigned-zone-message").textContent();
      assert.equal(
        await page.locator("#assigned-zone-message.error").count(),
        0,
        text,
      );
    };
    const exportAssignedZones = () =>
      exportJson(
        "#download-assigned-zones",
        "moonground-assigned-zone-evidence.json",
      );
    await physicalMode("assigned");
    assert.equal(
      await page.locator("#footprint-zone-controls").isHidden(),
      true,
    );
    assert.equal(
      await page.locator("#assigned-zone-controls").isVisible(),
      true,
    );
    await page.locator("#assigned-zone-example").click();
    assert.equal(
      await page.locator("#assigned-zone-input").inputValue(),
      assignedConfiguration,
    );
    await runAssignedZones(7);
    const assignedEvidence = await exportAssignedZones();
    assert.deepEqual(Object.keys(assignedEvidence), ["frames"]);
    assignedEvidence.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "assigned_zone_evidence_frame");
      assert.equal(
        frame.evidence_scope,
        "model_position_halfplane_bands_plus_current_target_footprints",
      );
      assert.equal(frame.timestamp_us, assignedBase.frames[index].timestamp_us);
      assert.deepEqual(
        frame.unavailable,
        assignedPointBaseline.frames[index].unavailable,
      );
      frame.evidence.forEach((row) => {
        const { shape_kind, ...band } = row;
        const baseline = (
          shape_kind === "disk" ? assignedDiskBaseline : assignedConvexBaseline
        ).frames[index].evidence.find(
          (item) =>
            item.track_id === row.track_id && item.zone_id === row.zone_id,
        );
        if (shape_kind === "disk") {
          const faces = band.faces.map((face) => {
            const { footprint_lower_m, footprint_upper_m, ...original } = face;
            assert.equal(footprint_lower_m, -0.25);
            assert.equal(footprint_upper_m, 0.25);
            return original;
          });
          assert.deepEqual({ ...band, faces }, baseline);
          assert.equal("vertices_offset_m" in band, false);
        } else {
          assert.equal(shape_kind, "convex");
          assert.deepEqual(band, baseline);
          assert.equal("radius_m" in band, false);
        }
      });
    });
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#footprint-zone-evidence").textContent(),
      /圆盘/,
    );
    assert.match(
      await page.locator("#footprint-zone-evidence").textContent(),
      /凸形/,
    );
    await page.locator("#footprint-zone-face-selection").selectOption("3");
    assert.deepEqual(
      JSON.parse(
        await page
          .locator("#footprint-zone-faces tr")
          .first()
          .getAttribute("title"),
      ),
      assignedEvidence.frames[5].evidence[3].faces[0],
    );
    await selectVelocityFrame(4);
    assert.equal(
      await page.locator("#footprint-zone-face-selection").inputValue(),
      "3",
    );

    // A current Ready object with no shape is unavailable once, not per zone.
    const missingDocuments = JSON.parse(JSON.stringify(assignedDocuments));
    missingDocuments[0].footprints = [];
    missingDocuments[5].footprints.pop();
    await page
      .locator("#assigned-zone-input")
      .fill(assignmentText(missingDocuments));
    await runAssignedZones(7);
    const assignedMissing = await exportAssignedZones();
    assert.deepEqual(
      assignedMissing.frames[0].unavailable,
      assignedEvidence.frames[0].unavailable,
    );
    assert.equal(assignedMissing.frames[5].evidence.length, 5);
    assert.deepEqual(assignedMissing.frames[5].unavailable, [
      { track_id: 2, segment_id: "2", reason: "missing_footprint" },
    ]);
    await selectVelocityFrame(5);
    assert.match(
      await page.locator("#footprint-zone-unavailable").textContent(),
      /足迹未分配/,
    );
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), assignedConvexBaseline);
    await physicalMode("disk");
    assert.deepEqual(await exportDiskZones(), assignedDiskBaseline);
    await physicalMode("assigned");
    assert.deepEqual(await exportAssignedZones(), assignedMissing);

    // No browser parsing can round an invalid ID token into a valid mapping.
    const assignedBadInputs = [];
    for (const edit of [
      (doc) => {
        doc.timestamp_us = "1000001";
      },
      (doc) => {
        doc.footprints[0].segment_id = "999";
      },
      (doc) => {
        doc.footprints[0].segment_id = "01";
      },
      (doc) => {
        doc.footprints.push(doc.footprints[0]);
      },
      (doc) => {
        doc.footprints[0].track_id = 99;
      },
      (doc) => {
        doc.footprints[0].shape.kind = "unknown";
      },
    ]) {
      const docs = JSON.parse(JSON.stringify(assignedDocuments));
      edit(docs[5]);
      assignedBadInputs.push(assignmentText(docs));
    }
    for (const raw of [
      JSON.stringify(assignedDocuments[5]).replace(
        '"track_id":1',
        '"track_id":1.0000000000000001',
      ),
      JSON.stringify(assignedDocuments[5]).replace(
        '"footprints":',
        '"unknown":true,"footprints":',
      ),
      JSON.stringify(assignedDocuments[5]).replace(
        '"timestamp_us":',
        '"timestamp_us":"0","timestamp_us":',
      ),
      JSON.stringify(assignedDocuments[5]).replace(
        '"radius_m":0.25',
        '"radius_m":0.25,"radius_m":0',
      ),
      JSON.stringify(assignedDocuments[5]) + " ".repeat(1048577),
    ]) {
      const docs = [...assignedDocuments];
      docs[5] = raw;
      assignedBadInputs.push(assignmentText(docs));
    }
    assignedBadInputs.push(assignmentText(assignedDocuments.slice(1)));
    assignedBadInputs.push(assignedConfiguration + "\n");
    for (const raw of assignedBadInputs) {
      await page.locator("#assigned-zone-input").fill(raw);
      await page.locator("#assigned-zone-compute").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#assigned-zone-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#assigned-zone-input").inputValue(),
        raw,
      );
      assert.equal(
        await page.locator("#download-assigned-zones").isDisabled(),
        true,
      );
      assert.deepEqual(await exportZones(), assignedPointBaseline);
      assert.deepEqual(await exportVelocity(), assignedVelocityBaseline);
      assert.equal(
        await page.locator("#download-footprint-zones").isDisabled(),
        false,
      );
      assert.equal(
        await page.locator("#download-disk-zones").isDisabled(),
        false,
      );
    }
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    await page.evaluate(() => {
      window.assignedOriginalTextEncoder = window.TextEncoder;
      window.TextEncoder = class {
        encode() {
          throw new Error("assigned preparation failed");
        }
      };
    });
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#assigned-zone-message")
        .classList.contains("error"),
    );
    await page.evaluate(() => {
      window.TextEncoder = window.assignedOriginalTextEncoder;
      delete window.assignedOriginalTextEncoder;
    });
    assert.deepEqual(await exportAssignedZones(), assignedEvidence);
    await runVelocityBase(velocitySource, 7);
    assert.deepEqual(await exportAssignedZones(), assignedEvidence);
    // An unchanged identity pair in another frame still needs its exact clock.
    await page
      .locator("#assigned-zone-input")
      .fill(
        assignmentText(
          assignedDocuments.map((doc, index) =>
            index === 5 ? assignedDocuments[4] : doc,
          ),
        ),
      );
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#assigned-zone-message")
        .classList.contains("error"),
    );

    // Sample docs preserve >2^53 timestamps and a newly reported segment;
    // neither clocks nor segment identity can be recovered from an old map.
    const assignedLargeInput =
      [
        { ...velocityHeader, session_id: "velocity-ui" },
        {
          timestamp_us: "9007199254740993",
          observations: [
            { track_id: 1, point: [0, 0], covariance: [0.01, 0, 0.01] },
          ],
        },
        {
          timestamp_us: "9007199254940993",
          observations: [
            { track_id: 1, point: [0.1, 0], covariance: [0.01, 0, 0.01] },
          ],
        },
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(assignedLargeInput, 2);
    await page.locator("#assigned-zone-example").click();
    const largeAssignments = await page
      .locator("#assigned-zone-input")
      .inputValue();
    assert.match(largeAssignments, /9007199254740993/);
    await runAssignedZones(2);
    assert.equal(
      (await exportAssignedZones()).frames[1].timestamp_us,
      "9007199254940993",
    );
    const assignedRestartInput =
      [
        velocityHeader,
        ...[0, 200000, 400000, 800000, 1000000].map((time, index) => ({
          timestamp_us: String(time),
          observations:
            index === 2
              ? []
              : [{ track_id: 1, point: [0, 0], covariance: [0.01, 0, 0.01] }],
        })),
      ]
        .map((line) => JSON.stringify(line))
        .join("\n") + "\n";
    await runVelocityBase(assignedRestartInput, 5);
    await page.locator("#assigned-zone-example").click();
    await runAssignedZones(5);
    const restartedAssignments = (
      await page.locator("#assigned-zone-input").inputValue()
    )
      .trimEnd()
      .split("\n")
      .map(JSON.parse);
    assert.notEqual(
      restartedAssignments[0].footprints[0].segment_id,
      restartedAssignments[4].footprints[0].segment_id,
    );
    restartedAssignments[4].footprints[0].segment_id =
      restartedAssignments[0].footprints[0].segment_id;
    await page
      .locator("#assigned-zone-input")
      .fill(assignmentText(restartedAssignments));
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#assigned-zone-message")
        .classList.contains("error"),
    );

    for (const [input, count, reason] of [
      [velocityUncertainInput, 7, "uncertain"],
      [velocityRejectedInput, 7, "rejected_innovation"],
      [velocityPixelInput, 11, "rejected_projection"],
    ]) {
      await runVelocityBase(input, count);
      await page.locator("#assigned-zone-example").click();
      if (count === 11) {
        const sample = (await page.locator("#assigned-zone-input").inputValue())
          .trimEnd()
          .split("\n")
          .map(JSON.parse);
        assert.deepEqual(sample[10].footprints, []);
      }
      await runAssignedZones(count);
      const report = await exportAssignedZones();
      const index = count === 11 ? 10 : 5;
      assert.deepEqual(report.frames[index].evidence, []);
      assert.ok(report.frames[index].unavailable.length > 0);
      assert.ok(
        report.frames[index].unavailable.every((row) => row.reason === reason),
      );
      const docs = (await page.locator("#assigned-zone-input").inputValue())
        .trimEnd()
        .split("\n")
        .map(JSON.parse);
      docs[index].footprints = [];
      await page.locator("#assigned-zone-input").fill(assignmentText(docs));
      await runAssignedZones(count);
      assert.deepEqual(
        (await exportAssignedZones()).frames[index].unavailable,
        report.frames[index].unavailable,
      );
      if (count === 11) {
        docs[index].footprints = [
          {
            track_id: 1,
            segment_id: "1",
            shape: { kind: "disk", radius_m: 0.25 },
          },
        ];
        await page.locator("#assigned-zone-input").fill(assignmentText(docs));
        await page.locator("#assigned-zone-compute").click();
        await page.waitForFunction(() =>
          document
            .querySelector("#assigned-zone-message")
            .classList.contains("error"),
        );
      }
    }
    await runVelocityBase(velocitySource, 7);
    await runZones(7);
    await runVelocity(7);
    await runFootprintZones(7);
    await physicalMode("disk");
    await runDiskZones(7);
    await physicalMode("assigned");
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportAssignedZones(), assignedEvidence);
      await page.locator(selector).fill(previous);
    }
    await runVelocity(7);
    // Display-only switches must not erase or cancel another strategy's task.
    await page
      .locator("#assigned-zone-input")
      .fill(assignedConfiguration.replace(/\n$/, " \n"));
    await holdEvidenceTransitPreparation();
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runFootprintZones(7);
    await releaseEvidenceTransitPreparation();
    await physicalMode("assigned");
    assert.deepEqual(await exportAssignedZones(), assignedEvidence);
    await physicalMode("convex");
    await page
      .locator("#footprint-zone-input")
      .fill(footprintConfiguration + " ");
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runAssignedZones(7);
    await releaseEvidenceTransitPreparation();
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), assignedConvexBaseline);
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runFootprintZones(7);
    await physicalMode("assigned");
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    for (const selector of ["#assigned-zone-input", "#zone-input", "#source"]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#assigned-zone-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-assigned-zones").isDisabled(),
        true,
      );
      if (selector === "#assigned-zone-input") {
        assert.deepEqual(await exportZones(), assignedPointBaseline);
        assert.equal(
          await page.locator("#download-footprint-zones").isDisabled(),
          false,
        );
      } else {
        assert.equal(await page.locator("#download-zones").isDisabled(), true);
        assert.equal(
          await page.locator("#download-disk-zones").isDisabled(),
          true,
        );
        assert.equal(
          await page.locator("#download-footprint-zones").isDisabled(),
          true,
        );
      }
      await page.locator(selector).fill(previous);
      if (selector === "#source") await runVelocityBase(previous, 7);
      await runZones(7);
      await runFootprintZones(7);
      await physicalMode("disk");
      await runDiskZones(7);
      await runAssignedZones(7);
    }
    await page
      .locator("#assigned-zone-input")
      .fill(assignmentText(missingDocuments));
    await holdEvidenceTransitPreparation();
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#assigned-zone-example").click();
    await runAssignedZones(7);
    const assignedSample = await exportAssignedZones();
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportAssignedZones(), assignedSample);
    assert.equal(
      await page.locator("#assigned-zone-input").inputValue(),
      assignedConfiguration,
    );
    await holdEvidenceTransitPreparation();
    await page.locator("#assigned-zone-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runVelocityBase(velocitySource, 7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportAssignedZones(), assignedSample);
    await page.locator("#zone-example").click();
    assert.equal(
      await page.locator("#download-assigned-zones").isDisabled(),
      true,
    );
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [{ zone_id: "z".repeat(128), vertices_m: zoneWide }],
      }),
    );
    await runAssignedZones(7);
    await selectVelocityFrame(5);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#zone-input").fill(zoneConfiguration);
    await runAssignedZones(7);
    await page.locator("#footprint-zone-face-selection").selectOption("8");
    await page.locator("#zone-section").evaluate((details) => {
      details.open = false;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-zone-faces tr").length === 0,
    );
    assert.equal(
      await page.locator("#download-assigned-zones").isDisabled(),
      false,
    );
    await page.locator("#zone-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-zone-faces tr").length === 4,
    );
    await page.locator("#physical-zone-results").screenshot({
      path: path.join(directory, "assigned-zone-evidence-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#physical-zone-results").screenshot({
      path: path.join(directory, "assigned-zone-evidence-desktop-preview.png"),
    });
    // Confirmation sequences consume the original mixed-shape inputs directly.
    // Establish every comparison product rather than inheriting a display mode.
    await runVelocityBase(velocitySource, 7);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await physicalMode("disk");
    await page.locator("#disk-zone-input").fill(diskConfiguration);
    await runDiskZones(7);
    const runDiskBaseline = await exportDiskZones();
    await physicalMode("convex");
    await page.locator("#footprint-zone-input").fill(footprintConfiguration);
    await runFootprintZones(7);
    const runConvexBaseline = await exportFootprintZones();
    await runZones(7);
    const runPointBaseline = await exportZones();
    await runVelocity(7);
    const runVelocityBaseline = await exportVelocity();
    await physicalMode("assigned");
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    const runAssignedBaseline = await exportAssignedZones();
    await page.locator("#footprint-run-section").evaluate((details) => {
      details.open = true;
    });
    const defaultRunOptions =
      '{"max_gap_us":"500000","confirmation_us":"1000000","min_samples":"2"}';
    const runOptions =
      '{"max_gap_us":"500000","confirmation_us":"400000","min_samples":"3"}';
    const runFootprintRuns = async (count) => {
      await physicalMode("assigned");
      await page.locator("#footprint-run-section").evaluate((details) => {
        details.open = true;
      });
      await page.locator("#footprint-run-compute").click();
      await page.waitForFunction((expected) => {
        const message = document.querySelector("#footprint-run-message");
        return (
          message.classList.contains("error") ||
          message.textContent.includes("已计算 " + expected + " 帧")
        );
      }, count);
      assert.equal(
        await page.locator("#footprint-run-message.error").count(),
        0,
        await page.locator("#footprint-run-message").textContent(),
      );
    };
    const exportFootprintRuns = () =>
      exportJson("#download-footprint-runs", "moonground-footprint-runs.json");
    await page.locator("#footprint-run-input").fill(defaultRunOptions);
    await runFootprintRuns(7);
    const defaultRuns = await exportFootprintRuns();
    assert.ok(
      defaultRuns.frames.every((frame) => frame.confirmed.length === 0),
    );
    assert.deepEqual(Object.keys(defaultRuns).sort(), ["checkpoint", "frames"]);
    assert.equal(defaultRuns.checkpoint.kind, "footprint_run_checkpoint");
    assert.equal(defaultRuns.checkpoint.last_timestamp_us, "1200000");
    assert.deepEqual(defaultRuns.checkpoint.states, []);
    assert.deepEqual(
      await page.evaluate(async (checkpoint) => {
        const bridge = await import("./moonground.mjs");
        return JSON.parse(
          bridge.moonground_footprint_runs(
            JSON.stringify({
              source: JSON.stringify({ resume: checkpoint }),
              frames: "",
            }),
          ),
        );
      }, defaultRuns.checkpoint),
      { frames: [], checkpoint: defaultRuns.checkpoint },
    );
    await page.locator("#footprint-run-input").fill(runOptions);
    await runFootprintRuns(7);
    const footprintRuns = await exportFootprintRuns();
    footprintRuns.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "footprint_run_frame");
      assert.equal(
        frame.evidence_scope,
        "current_target_footprint_confirmed_sample_runs",
      );
      assert.deepEqual(frame.evidence, runAssignedBaseline.frames[index]);
      for (const run of frame.active) {
        assert.equal(typeof run.sample_count, "string");
        assert.equal(typeof run.sample_span_us, "string");
        assert.equal(
          BigInt(run.sample_span_us),
          BigInt(run.last_timestamp_us) - BigInt(run.first_timestamp_us),
        );
      }
    });
    const runFor = (frame, key, track = 1, zone = "wide") =>
      frame[key].find((run) => run.track_id === track && run.zone_id === zone);
    assert.equal(runFor(footprintRuns.frames[2], "active").confirmed, false);
    assert.equal(
      runFor(footprintRuns.frames[3], "confirmed").sample_count,
      "3",
    );
    assert.equal(
      runFor(footprintRuns.frames[3], "confirmed").sample_span_us,
      "400000",
    );
    assert.equal(runFor(footprintRuns.frames[4], "confirmed"), undefined);
    assert.equal(runFor(footprintRuns.frames[5], "active").sample_count, "5");
    assert.equal(footprintRuns.frames[6].active.length, 0);
    assert.ok(footprintRuns.frames[6].closed.length > 0);
    assert.ok(
      footprintRuns.frames[6].closed.every(
        (record) => record.reason === "missing_target",
      ),
    );
    await selectVelocityFrame(3);
    assert.equal(
      await page.locator("#footprint-run-rows tr").count(),
      footprintRuns.frames[3].active.length +
        footprintRuns.frames[3].closed.length,
    );
    assert.match(
      await page.locator("#footprint-run-rows").textContent(),
      /本帧首次确认/,
    );
    assert.deepEqual(
      JSON.parse(
        await page
          .locator("#footprint-run-rows tr")
          .first()
          .getAttribute("title"),
      ),
      footprintRuns.frames[3].active[0],
    );
    await selectVelocityFrame(6);
    assert.match(
      await page.locator("#footprint-run-rows").textContent(),
      /本帧缺少目标/,
    );
    assert.deepEqual(
      JSON.parse(
        await page
          .locator("#footprint-run-rows tr")
          .first()
          .getAttribute("title"),
      ),
      footprintRuns.frames[6].closed[0],
    );
    // Each threshold is necessary; sample time is never rounded in the browser.
    for (const options of [
      { max_gap_us: "500000", confirmation_us: "600000", min_samples: "2" },
      { max_gap_us: "500000", confirmation_us: "200000", min_samples: "4" },
    ]) {
      await page.locator("#footprint-run-input").fill(JSON.stringify(options));
      await runFootprintRuns(7);
      const report = await exportFootprintRuns();
      assert.equal(runFor(report.frames[2], "active").confirmed, false);
      assert.equal(runFor(report.frames[4], "confirmed").sample_count, "4");
    }
    await page
      .locator("#footprint-run-input")
      .fill('{"max_gap_us":"500000","confirmation_us":"0","min_samples":"1"}');
    await runFootprintRuns(7);
    const instantRuns = await exportFootprintRuns();
    assert.equal(runFor(instantRuns.frames[1], "confirmed").sample_count, "1");
    assert.equal(
      runFor(instantRuns.frames[1], "confirmed").sample_span_us,
      "0",
    );
    assert.equal(runFor(instantRuns.frames[2], "confirmed"), undefined);
    await page
      .locator("#footprint-run-input")
      .fill('{"max_gap_us":"200000","confirmation_us":"0","min_samples":"1"}');
    await runFootprintRuns(7);
    const gapRuns = await exportFootprintRuns();
    assert.ok(
      gapRuns.frames[2].closed.every(
        (record) => record.reason === "gap_exceeded",
      ),
    );
    assert.equal(runFor(gapRuns.frames[2], "active").sample_count, "1");
    await page.locator("#footprint-run-input").fill(runOptions);
    for (const change of [
      (docs) => {
        docs[4].footprints[0].shape.radius_m = 0.5;
      },
      (docs) => {
        docs[4].footprints[1].shape.vertices_offset_m.reverse();
      },
    ]) {
      const docs = JSON.parse(JSON.stringify(assignedDocuments));
      change(docs);
      await page.locator("#assigned-zone-input").fill(assignmentText(docs));
      await runFootprintRuns(7);
      const report = await exportFootprintRuns();
      assert.ok(
        report.frames[4].closed.some(
          (record) => record.reason === "shape_changed",
        ),
      );
      const track = docs[4].footprints[0].shape.radius_m === 0.5 ? 1 : 2;
      assert.equal(runFor(report.frames[4], "active", track).sample_count, "1");
      assert.equal(
        runFor(report.frames[4], "active", track).first_timestamp_us,
        "800000",
      );
    }
    const unavailableDocs = JSON.parse(JSON.stringify(assignedDocuments));
    unavailableDocs[3].footprints.pop();
    await page
      .locator("#assigned-zone-input")
      .fill(assignmentText(unavailableDocs));
    await runFootprintRuns(7);
    const missingRuns = await exportFootprintRuns();
    assert.ok(
      missingRuns.frames[3].closed.some(
        (record) =>
          record.run.track_id === 2 && record.reason === "unavailable_evidence",
      ),
    );
    assert.equal(
      missingRuns.frames[3].evidence.unavailable[0].reason,
      "missing_footprint",
    );
    assert.equal(runFor(missingRuns.frames[4], "active", 2).sample_count, "1");
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await page.locator("#zone-input").fill(
      JSON.stringify({
        session_id: "velocity-ui",
        zones: [
          {
            zone_id: "edge",
            vertices_m: [
              [-10, -10],
              [1, -10],
              [1, 10],
              [-10, 10],
            ],
          },
        ],
      }),
    );
    await runFootprintRuns(7);
    const unknownRuns = await exportFootprintRuns();
    assert.ok(
      unknownRuns.frames[2].closed.some(
        (record) =>
          record.run.track_id === 1 &&
          record.reason === "indeterminate_evidence",
      ),
    );
    assert.equal(runFor(unknownRuns.frames[2], "active", 1, "edge"), undefined);
    assert.equal(
      runFor(unknownRuns.frames[4], "active", 1, "edge").decision,
      "outside",
    );
    assert.equal(
      runFor(unknownRuns.frames[4], "active", 1, "edge").sample_count,
      "1",
    );
    // Projection rows retain their reason, without a fabricated current segment.
    await runVelocityBase(velocityPixelInput, 11);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await page.locator("#assigned-zone-example").click();
    await runFootprintRuns(11);
    const projectionRuns = await exportFootprintRuns();
    assert.deepEqual(projectionRuns.frames[10].evidence.unavailable, [
      { track_id: 1, segment_id: null, reason: "rejected_projection" },
    ]);
    assert.ok(
      projectionRuns.frames[10].closed.some(
        (record) => record.reason === "missing_target",
      ),
    );
    await runVelocityBase(assignedLargeInput, 2);
    await page.locator("#assigned-zone-example").click();
    await page
      .locator("#footprint-run-input")
      .fill('{"max_gap_us":"500000","confirmation_us":"0","min_samples":"1"}');
    await runFootprintRuns(2);
    const largeRuns = await exportFootprintRuns();
    assert.equal(largeRuns.checkpoint.last_timestamp_us, "9007199254940993");
    assert.equal(
      largeRuns.frames[1].active[0].first_timestamp_us,
      "9007199254940993",
    );
    assert.equal(largeRuns.frames[1].active[0].sample_span_us, "0");
    // Restore independent slots explicitly before exercising editing boundaries.
    await runVelocityBase(velocitySource, 7);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    await runZones(7);
    await runVelocity(7);
    await physicalMode("disk");
    await runDiskZones(7);
    await runFootprintZones(7);
    await physicalMode("assigned");
    await page.locator("#footprint-run-input").fill(runOptions);
    await runFootprintRuns(7);
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    for (const raw of [
      '{"max_gap_us":"0"}',
      '{"confirmation_us":"01"}',
      '{"min_samples":2}',
      '{"min_samples":1.0000000000000001}',
      '{"min_samples":"2","min_samples":"3"}',
      '{"min_samples":"2","unknown":true}',
    ]) {
      await page.locator("#footprint-run-input").fill(raw);
      await page.locator("#footprint-run-compute").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#footprint-run-message")
          .classList.contains("error"),
      );
      assert.equal(
        await page.locator("#footprint-run-input").inputValue(),
        raw,
      );
      assert.equal(
        await page.locator("#download-footprint-runs").isDisabled(),
        true,
      );
      assert.deepEqual(await exportAssignedZones(), runAssignedBaseline);
      assert.deepEqual(await exportZones(), runPointBaseline);
    }
    await page.locator("#footprint-run-input").fill(runOptions);
    await runFootprintRuns(7);
    await page.evaluate(() => {
      window.runOriginalTextEncoder = window.TextEncoder;
      window.TextEncoder = class {
        encode() {
          throw new Error("run preparation failed");
        }
      };
    });
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-message")
        .classList.contains("error"),
    );
    await page.evaluate(() => {
      window.TextEncoder = window.runOriginalTextEncoder;
      delete window.runOriginalTextEncoder;
    });
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    await page
      .locator("#assigned-zone-input")
      .fill(
        assignedConfiguration.replace(
          '"track_id":1',
          '"track_id":1.0000000000000001',
        ),
      );
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-footprint-runs").isDisabled(),
      true,
    );
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAssignedZones(7);
    await runFootprintRuns(7);
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportFootprintRuns(), footprintRuns);
      await page.locator(selector).fill(previous);
    }
    await runVelocity(7);
    // Other physical modes have no ownership over a run's task or result.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await physicalMode("convex");
    await page
      .locator("#footprint-zone-input")
      .fill(footprintConfiguration + " ");
    await runFootprintZones(7);
    await releaseEvidenceTransitPreparation();
    await physicalMode("assigned");
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    await physicalMode("convex");
    assert.deepEqual(await exportFootprintZones(), runConvexBaseline);
    await physicalMode("disk");
    await page.locator("#disk-zone-input").fill(diskConfiguration + " ");
    await runDiskZones(7);
    assert.deepEqual(await exportDiskZones(), runDiskBaseline);
    await physicalMode("assigned");
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    // Recomputing the independent assigned product does not cancel run preparation.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runAssignedZones(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    for (const selector of [
      "#footprint-run-input",
      "#assigned-zone-input",
      "#zone-input",
      "#source",
    ]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#footprint-run-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-footprint-runs").isDisabled(),
        true,
      );
      if (selector === "#footprint-run-input") {
        assert.deepEqual(await exportAssignedZones(), runAssignedBaseline);
        assert.deepEqual(await exportZones(), runPointBaseline);
        assert.deepEqual(await exportVelocity(), runVelocityBaseline);
      }
      await page.locator(selector).fill(previous);
      if (selector === "#source") await runVelocityBase(previous, 7);
      await runAssignedZones(7);
      await runZones(7);
      await runFootprintRuns(7);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#footprint-run-input")
      .fill('{"max_gap_us":"500000","confirmation_us":"0","min_samples":"1"}');
    await runFootprintRuns(7);
    const supersedingRuns = await exportFootprintRuns();
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintRuns(), supersedingRuns);
    await page.locator("#footprint-run-input").fill(runOptions);
    await runFootprintRuns(7);
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page.locator("#assigned-zone-example").click();
    await runFootprintRuns(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runVelocityBase(velocitySource, 7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    await runVelocityBase(velocitySource, 7);
    assert.deepEqual(await exportFootprintRuns(), footprintRuns);
    await selectVelocityFrame(3);
    await page.locator("#footprint-run-section").evaluate((details) => {
      details.open = false;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-run-rows tr").length === 0,
    );
    assert.equal(
      await page.locator("#download-footprint-runs").isDisabled(),
      false,
    );
    await page.locator("#footprint-run-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-run-rows tr").length > 1,
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#footprint-run-section").screenshot({
      path: path.join(directory, "footprint-runs-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#footprint-run-section").screenshot({
      path: path.join(directory, "footprint-runs-desktop-preview.png"),
    });
    // Atomic raw replay has its own result and clock; ordinary output is only
    // an optional identity preview, never the input of this joint calculation.
    const atomicOrdinaryBaseline = await exportJson(
      "#download",
      "moonground-results.json",
    );
    const atomicRunBaseline = await exportFootprintRuns();
    const atomicIdentity = (frame) => ({
      session_id: frame.session_id,
      timestamp_us: frame.timestamp_us,
      tracks: frame.tracks.map(({ track_id, segment_id, status }) => ({
        track_id,
        segment_id,
        status,
      })),
    });
    const atomicMode = (mode) =>
      page.locator("#footprint-run-mode").selectOption(mode);
    const showAtomic = async () => {
      await physicalMode("assigned");
      await page.locator("#zone-section").evaluate((details) => {
        details.open = true;
      });
      await page.locator("#footprint-run-section").evaluate((details) => {
        details.open = true;
      });
      await atomicMode("joint");
    };
    const runAtomicFootprints = async (count) => {
      await showAtomic();
      await page.locator("#footprint-run-joint-compute").click();
      await page.waitForFunction((expected) => {
        const node = document.querySelector("#footprint-run-joint-message");
        return (
          node.classList.contains("error") ||
          node.textContent.includes("已联合计算 " + expected + " 帧")
        );
      }, count);
      assert.equal(
        await page.locator("#footprint-run-joint-message.error").count(),
        0,
        await page.locator("#footprint-run-joint-message").textContent(),
      );
    };
    const previewAtomicFootprints = async () => {
      await showAtomic();
      await page.locator("#footprint-run-preview").click();
      await page.waitForFunction(() => {
        const node = document.querySelector("#footprint-run-preview-message");
        return (
          node.classList.contains("error") ||
          node.textContent.includes("已预览首帧候选")
        );
      });
      assert.equal(
        await page.locator("#footprint-run-preview-message.error").count(),
        0,
        await page.locator("#footprint-run-preview-message").textContent(),
      );
      return JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      );
    };
    const exportAtomicFootprints = () =>
      exportJson(
        "#download-footprint-run-analysis",
        "moonground-footprint-run-analysis.json",
      );
    const selectAtomicFrame = (index) =>
      page.locator("#footprint-run-joint-frame").evaluate((input, value) => {
        input.value = String(value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, index);
    await showAtomic();
    assert.equal(
      await page.locator("#footprint-run-independent").isHidden(),
      true,
    );
    assert.equal(await page.locator("#footprint-run-joint").isVisible(), true);
    const atomicAssignmentsBeforePreview = await page
      .locator("#assigned-zone-input")
      .inputValue();
    assert.deepEqual(
      await previewAtomicFootprints(),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    assert.equal(
      await page.locator("#assigned-zone-input").inputValue(),
      atomicAssignmentsBeforePreview,
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      atomicOrdinaryBaseline,
    );
    // Even a same-text input event invalidates the ordinary output, but not a
    // raw joint owner. The new path must work with no ordinary result loaded.
    await page.locator("#source").fill(velocitySource);
    assert.equal(await page.locator("#download").isDisabled(), true);
    assert.equal(
      await page.locator("#footprint-run-compute").isDisabled(),
      true,
    );
    assert.deepEqual(
      await previewAtomicFootprints(),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    await runAtomicFootprints(7);
    const atomicFootprints = await exportAtomicFootprints();
    atomicFootprints.frames.forEach((frame, index) => {
      assert.equal(frame.kind, "footprint_run_analysis_frame");
      assert.deepEqual(frame.measurement, atomicOrdinaryBaseline.frames[index]);
      assert.deepEqual(frame.runs, atomicRunBaseline.frames[index]);
    });
    assert.equal(
      atomicFootprints.checkpoint.format,
      "moonground.footprint-run-analysis",
    );
    assert.equal(atomicFootprints.checkpoint.checkpoint_version, "1");
    assert.equal(atomicFootprints.checkpoint.runs.last_timestamp_us, "1200000");
    assert.ok(atomicFootprints.checkpoint.measurement);
    assert.deepEqual(
      await page.evaluate(async (checkpoint) => {
        const bridge = await import("./moonground.mjs");
        return JSON.parse(
          bridge.moonground_footprint_run_analysis(
            JSON.stringify({
              source: JSON.stringify({ resume: checkpoint }),
              frames: "",
            }),
          ),
        );
      }, atomicFootprints.checkpoint),
      { frames: [], checkpoint: atomicFootprints.checkpoint },
    );
    assert.equal(await page.locator("#download").isDisabled(), true);
    await runVelocityBase(velocitySource, 7);
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      atomicOrdinaryBaseline,
    );
    await selectAtomicFrame(3);
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-joint-measurement").textContent(),
      ),
      atomicIdentity(atomicOrdinaryBaseline.frames[3]),
    );
    assert.equal(
      await page.locator("#footprint-run-rows tr").count(),
      atomicFootprints.frames[3].runs.active.length +
        atomicFootprints.frames[3].runs.closed.length,
    );
    await selectVelocityFrame(1);
    assert.match(
      await page.locator("#footprint-run-joint-counter").textContent(),
      /600000/,
    );
    assert.equal(
      await page.locator("#footprint-run-joint-frame").inputValue(),
      "3",
    );
    await atomicMode("independent");
    assert.deepEqual(await exportFootprintRuns(), atomicRunBaseline);
    assert.equal(
      await page.locator("#download-footprint-run-analysis").isHidden(),
      true,
    );
    await atomicMode("joint");
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    assert.equal(
      await page.locator("#footprint-run-joint-frame").inputValue(),
      "3",
    );
    assert.equal(
      await page.locator("#download-footprint-runs").isHidden(),
      true,
    );
    // Displayed previews cannot be substituted for the actual candidate.
    await page.locator("#footprint-run-preview-json").evaluate((node) => {
      node.textContent =
        '{"timestamp_us":"999","tracks":[{"track_id":1,"segment_id":"999"}]}';
    });
    await runAtomicFootprints(7);
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      ),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    const badAtomicDocuments = JSON.parse(JSON.stringify(assignedDocuments));
    badAtomicDocuments[4].footprints[0].segment_id = "999";
    await page
      .locator("#assigned-zone-input")
      .fill(assignmentText(badAtomicDocuments));
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      ),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-joint-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-footprint-run-analysis").isDisabled(),
      true,
    );
    assert.equal(
      await page.locator("#assigned-zone-input").inputValue(),
      assignmentText(badAtomicDocuments),
    );
    assert.deepEqual(
      await exportJson("#download", "moonground-results.json"),
      atomicOrdinaryBaseline,
    );
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAtomicFootprints(7);
    // Failures at unchanged dependencies preserve the prior complete result.
    await page.evaluate(() => {
      window.atomicOriginalTextEncoder = window.TextEncoder;
      window.TextEncoder = class {
        encode() {
          throw new Error("atomic preparation failed");
        }
      };
    });
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-joint-message")
        .classList.contains("error"),
    );
    await page.locator("#footprint-run-preview").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-preview-message")
        .classList.contains("error"),
    );
    await page.evaluate(() => {
      window.TextEncoder = window.atomicOriginalTextEncoder;
      delete window.atomicOriginalTextEncoder;
    });
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      ),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    // Raw fractional IDs and duplicate fields cannot be rounded or normalized.
    for (const input of [
      velocitySource.replace('"track_id":2', '"track_id":2.0000000000000001'),
      velocitySource.replace(
        '"session_id":"velocity-ui"',
        '"session_id":"velocity-ui","session_id":"velocity-ui"',
      ),
    ]) {
      await page.locator("#source").fill(input);
      await page.locator("#footprint-run-preview").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#footprint-run-preview-message")
          .classList.contains("error"),
      );
      await page.locator("#footprint-run-joint-compute").click();
      await page.waitForFunction(() =>
        document
          .querySelector("#footprint-run-joint-message")
          .classList.contains("error"),
      );
      assert.equal(await page.locator("#source").inputValue(), input);
      assert.equal(
        await page.locator("#download-footprint-run-analysis").isDisabled(),
        true,
      );
    }
    const laterBadAtomicLines = velocitySource.trimEnd().split("\n");
    laterBadAtomicLines[7] =
      '{"timestamp_us":"1200000","observations":[{"track_id":1.0000000000000001,"point":[0,0]}]}';
    await page.locator("#source").fill(laterBadAtomicLines.join("\n") + "\n");
    assert.deepEqual(
      await previewAtomicFootprints(),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-joint-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#download-footprint-run-analysis").isDisabled(),
      true,
    );
    // A started measurement checkpoint cannot be paired with a new monitor.
    const mismatchedAtomicSource =
      [
        JSON.stringify({ resume: atomicFootprints.checkpoint.measurement }),
        '{"timestamp_us":"1400000","observations":[]}',
      ].join("\n") + "\n";
    await page.locator("#source").fill(mismatchedAtomicSource);
    await page
      .locator("#assigned-zone-input")
      .fill('{"timestamp_us":"1400000","footprints":[]}\n');
    await page.locator("#footprint-run-preview").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-preview-message")
        .classList.contains("error"),
    );
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(() =>
      document
        .querySelector("#footprint-run-joint-message")
        .classList.contains("error"),
    );
    assert.equal(
      await page.locator("#source").inputValue(),
      mismatchedAtomicSource,
    );
    // Exact large clocks and projection reasons use the same raw producer.
    await page.locator("#source").fill(assignedLargeInput);
    await page.locator("#assigned-zone-input").fill(largeAssignments);
    assert.equal(
      (await previewAtomicFootprints()).timestamp_us,
      "9007199254740993",
    );
    await runAtomicFootprints(2);
    const largeAtomic = await exportAtomicFootprints();
    assert.equal(
      largeAtomic.frames[1].measurement.timestamp_us,
      "9007199254940993",
    );
    assert.equal(
      largeAtomic.checkpoint.runs.last_timestamp_us,
      "9007199254940993",
    );
    await runVelocityBase(velocityPixelInput, 11);
    await page.locator("#assigned-zone-example").click();
    await runAtomicFootprints(11);
    const projectedAtomic = await exportAtomicFootprints();
    assert.deepEqual(
      projectedAtomic.frames[10].runs.evidence.unavailable,
      projectionRuns.frames[10].evidence.unavailable,
    );
    assert.deepEqual(
      (await exportJson("#download", "moonground-results.json")).frames,
      projectedAtomic.frames.map((frame) => frame.measurement),
    );
    await runVelocityBase(velocitySource, 7);
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAtomicFootprints(7);
    await atomicMode("independent");
    await runFootprintRuns(7);
    await atomicMode("joint");
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    // Same-raw ordinary recalculation is unrelated to a raw joint preparation.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runVelocityBase(velocitySource, 7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    // Each display strategy preserves the other's task and complete result.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await atomicMode("independent");
    await runFootprintRuns(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportFootprintRuns(), atomicRunBaseline);
    await atomicMode("joint");
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    await atomicMode("independent");
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runAtomicFootprints(7);
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    await atomicMode("independent");
    assert.deepEqual(await exportFootprintRuns(), atomicRunBaseline);
    await atomicMode("joint");
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-preview").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await runAtomicFootprints(7);
    await releaseEvidenceTransitPreparation();
    assert.match(
      await page.locator("#footprint-run-joint-message").textContent(),
      /已联合计算 7 帧/,
    );
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    // Assignment changes do not cancel an unrelated candidate preview.
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-preview").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#assigned-zone-input")
      .fill(assignedConfiguration.replace(/\n$/, " \n"));
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      ),
      atomicIdentity(atomicOrdinaryBaseline.frames[0]),
    );
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await runAtomicFootprints(7);
    for (const selector of [
      "#source",
      "#zone-input",
      "#assigned-zone-input",
      "#footprint-run-input",
    ]) {
      await holdEvidenceTransitPreparation();
      await page.locator("#footprint-run-joint-compute").click();
      await page.waitForFunction(
        () => typeof window.releaseEvidenceTransitRun === "function",
      );
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      await releaseEvidenceTransitPreparation();
      assert.equal(
        await page.locator("#download-footprint-run-analysis").isDisabled(),
        true,
      );
      await page.locator(selector).fill(previous);
      await runAtomicFootprints(7);
    }
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-joint-compute").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#footprint-run-input")
      .fill('{"max_gap_us":"500000","confirmation_us":"0","min_samples":"1"}');
    await runAtomicFootprints(7);
    const supersedingAtomic = await exportAtomicFootprints();
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(await exportAtomicFootprints(), supersedingAtomic);
    await page.locator("#footprint-run-input").fill(runOptions);
    await runAtomicFootprints(7);
    await holdEvidenceTransitPreparation();
    await page.locator("#footprint-run-preview").click();
    await page.waitForFunction(
      () => typeof window.releaseEvidenceTransitRun === "function",
    );
    await page
      .locator("#source")
      .fill(velocitySource.replace("velocity-ui", "velocity-preview-new"));
    await page
      .locator("#zone-input")
      .fill(zoneConfiguration.replace("velocity-ui", "velocity-preview-new"));
    const newAtomicPreview = await previewAtomicFootprints();
    assert.equal(newAtomicPreview.session_id, "velocity-preview-new");
    await releaseEvidenceTransitPreparation();
    assert.deepEqual(
      JSON.parse(
        await page.locator("#footprint-run-preview-json").textContent(),
      ),
      newAtomicPreview,
    );
    await page.locator("#source").fill(velocitySource);
    await page.locator("#zone-input").fill(zoneConfiguration);
    await page.locator("#assigned-zone-input").fill(assignedConfiguration);
    await previewAtomicFootprints();
    await runAtomicFootprints(7);
    for (const selector of [
      "#velocity-input",
      "#gate-input",
      "#guarded-input",
    ]) {
      const previous = await page.locator(selector).inputValue();
      await page.locator(selector).fill(previous + " ");
      assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
      await page.locator(selector).fill(previous);
    }
    await physicalMode("convex");
    const atomicOtherFootprint = await page
      .locator("#footprint-zone-input")
      .inputValue();
    await page
      .locator("#footprint-zone-input")
      .fill(atomicOtherFootprint + " ");
    await physicalMode("assigned");
    assert.deepEqual(await exportAtomicFootprints(), atomicFootprints);
    await selectAtomicFrame(3);
    await page.locator("#footprint-run-section").evaluate((details) => {
      details.open = false;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-run-rows tr").length === 0,
    );
    assert.equal(
      await page.locator("#download-footprint-run-analysis").isDisabled(),
      false,
    );
    await page.locator("#footprint-run-section").evaluate((details) => {
      details.open = true;
    });
    await page.waitForFunction(
      () => document.querySelectorAll("#footprint-run-rows tr").length > 1,
    );
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#footprint-run-section").screenshot({
      path: path.join(directory, "footprint-run-analysis-mobile-preview.png"),
    });
    await page.setViewportSize({ width: 1440, height: 1050 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
      true,
    );
    await page.locator("#footprint-run-section").screenshot({
      path: path.join(directory, "footprint-run-analysis-desktop-preview.png"),
    });
    assert.deepEqual(errors, []);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
});
