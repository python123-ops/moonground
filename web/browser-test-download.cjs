// Blink drops burst requests above ten downloads in one second. Keep automated
// exports below that limit while exercising the real button, blob and file.
// Source: third_party/blink/renderer/core/frame/local_frame.cc,
// LocalFrame::ShouldThrottleDownload in Chromium.
const lastDownload = new WeakMap();

async function waitForDownloadSlot(page) {
  const delay =
    150 - (performance.now() - (lastDownload.get(page) ?? -Infinity));
  if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
  lastDownload.set(page, performance.now());
}

module.exports = { waitForDownloadSlot };
