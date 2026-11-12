import http from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "_build",
  "site",
);
const port = Number(process.argv[2] ?? 8765);
if (!Number.isInteger(port) || port < 1 || port > 65535)
  throw new Error("Port must be an integer in [1,65535].");
if (!existsSync(path.join(root, "index.html")))
  throw new Error("Run node web/build.mjs before starting the preview.");
const assets = new Map([
  ["index.html", "text/html; charset=utf-8"],
  ["app.mjs", "text/javascript; charset=utf-8"],
  ["moonground.mjs", "text/javascript; charset=utf-8"],
  ["style.css", "text/css; charset=utf-8"],
  ["warehouse.ndjson", "application/x-ndjson; charset=utf-8"],
  ["distorted-camera.ndjson", "application/x-ndjson; charset=utf-8"],
  ["resume.ndjson", "application/x-ndjson; charset=utf-8"],
  ["reframe.ndjson", "application/x-ndjson; charset=utf-8"],
  ["calibration.json", "application/json; charset=utf-8"],
  ["gates.json", "application/json; charset=utf-8"],
  ["robust-calibration.json", "application/json; charset=utf-8"],
]);
const server = http.createServer((request, response) => {
  if (!["GET", "HEAD"].includes(request.method)) {
    response.writeHead(405);
    response.end();
    return;
  }
  let pathname;
  try {
    pathname = decodeURIComponent(
      new URL(request.url, "http://127.0.0.1").pathname,
    );
  } catch {
    response.writeHead(400);
    response.end();
    return;
  }
  if (pathname === "/favicon.ico") {
    response.writeHead(204);
    response.end();
    return;
  }
  const name = pathname === "/" ? "index.html" : pathname.slice(1);
  if (!assets.has(name)) {
    response.writeHead(404);
    response.end();
    return;
  }
  const target = path.join(root, name);
  if (!existsSync(target)) {
    response.writeHead(503);
    response.end("Rebuild the preview with node web/build.mjs.");
    return;
  }
  response.writeHead(200, {
    "Content-Type": assets.get(name),
    "Content-Length": statSync(target).size,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  if (request.method === "HEAD") {
    response.end();
    return;
  }
  createReadStream(target)
    .on("error", () => response.destroy())
    .pipe(response);
});
server.on("error", (error) => {
  console.error(error.message);
  process.exitCode = 1;
});
server.listen(port, "127.0.0.1", () =>
  console.log(`MoonGround preview: http://127.0.0.1:${port}/`),
);
