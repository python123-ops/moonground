const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

test("desktop, mobile, local import and stale-result prevention", async () => {
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
    browser = await chromium.launch({ headless: true });
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
    await page
      .locator("#file")
      .setInputFiles({
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
