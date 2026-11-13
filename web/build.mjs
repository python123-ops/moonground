import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const built = spawnSync(
  process.env.MOON ?? "moon",
  ["build", "web_bridge", "--target", "js", "--release", "--deny-warn"],
  { cwd: root, stdio: "inherit" },
);
if (built.status !== 0) process.exit(built.status ?? 1);
const output = path.join(root, "_build", "site");
mkdirSync(output, { recursive: true });
copyFileSync(
  path.join(root, "examples", "evidence-guarded-transit.ndjson"),
  path.join(output, "evidence-guarded-transit.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "evidence-transit-source.json"),
  path.join(output, "evidence-transit-source.json"),
);
copyFileSync(
  path.join(root, "examples", "evidence-guarded.ndjson"),
  path.join(output, "evidence-guarded.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "gate-evidence.json"),
  path.join(output, "gate-evidence.json"),
);
copyFileSync(
  path.join(root, "examples", "transit.json"),
  path.join(output, "transit.json"),
);
copyFileSync(
  path.join(root, "examples", "projection-replace.ndjson"),
  path.join(output, "projection-replace.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "guarded.ndjson"),
  path.join(output, "guarded.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "health.ndjson"),
  path.join(output, "health.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "gates.json"),
  path.join(output, "gates.json"),
);
for (const file of ["index.html", "app.mjs", "style.css"])
  copyFileSync(path.join(root, "web", file), path.join(output, file));
copyFileSync(
  path.join(root, "examples", "resume.ndjson"),
  path.join(output, "resume.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "reframe.ndjson"),
  path.join(output, "reframe.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "distorted-camera.ndjson"),
  path.join(output, "distorted-camera.ndjson"),
);
copyFileSync(
  path.join(
    root,
    "_build",
    "js",
    "release",
    "build",
    "web_bridge",
    "web_bridge.js",
  ),
  path.join(output, "moonground.mjs"),
);
copyFileSync(
  path.join(root, "examples", "warehouse.ndjson"),
  path.join(output, "warehouse.ndjson"),
);
copyFileSync(
  path.join(root, "examples", "calibration.json"),
  path.join(output, "calibration.json"),
);
copyFileSync(
  path.join(root, "examples", "robust-calibration.json"),
  path.join(output, "robust-calibration.json"),
);
console.log(`Built ${output}`);
