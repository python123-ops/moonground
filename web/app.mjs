import {
  moonground_create,
  moonground_update,
  moonground_close,
  moonground_project,
  moonground_calibrate,
} from "./moonground.mjs";

const $ = (id) => document.getElementById(id);
const source = $("source");
const slider = $("frame");
const canvas = $("ground");
const context = canvas.getContext("2d");
let revision = 0;
let results = [];
let configuration = null;
let playing = null;
let loadedSource = "";
const states = {
  initializing: "初始化",
  ready: "可读取速度",
  rejected_innovation: "异常观测",
  numerical_failure: "数值不可用",
  rejected_projection: "区域外 / 不可测",
};

function message(text, error = false) {
  $("message").textContent = text;
  $("message").classList.toggle("error", error);
}

function stop() {
  if (playing !== null) clearInterval(playing);
  playing = null;
  $("play").textContent = "播放";
}

function invalidate() {
  revision++;
  stop();
  results = [];
  configuration = null;
  loadedSource = "";
  $("download").disabled = true;
  $("play").disabled = true;
  slider.disabled = true;
  $("counter").textContent = "0 / 0";
  $("time").textContent = "—";
  for (const id of ["ready", "speed", "segments"]) $(id).textContent = "—";
  $("tracks").replaceChildren();
  draw();
}

function unpack(text) {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value;
}

function draw() {
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#eef3e9";
  context.fillRect(0, 0, canvas.width, canvas.height);
  const index = Number(slider.value);
  const histories = new Map();
  const points = [];
  let roi = [];
  if (configuration?.mode !== "ground" && configuration?.calibration) {
    try {
      roi = unpack(
        moonground_project(
          JSON.stringify({
            calibration: configuration.calibration,
            points: configuration.calibration.roi.map((point) => ({ point })),
          }),
        ),
      ).points.map((point) => point.position_m);
      points.push(...roi);
    } catch {
      /* A failed configuration is shown by the replay action. */
    }
  }
  for (let frame = 0; frame <= index && frame < results.length; frame++) {
    for (const track of results[frame].tracks) {
      if (!track.position_m) continue;
      const key = `${track.track_id}:${track.segment_id}`;
      if (!histories.has(key)) histories.set(key, []);
      histories.get(key).push(track.position_m);
      points.push(track.position_m);
    }
  }
  if (points.length === 0) {
    context.fillStyle = "#8d9b8c";
    context.font = "22px system-ui";
    context.fillText("载入观测，查看米制地面轨迹", 295, 310);
    return;
  }
  if (
    points.some((point) =>
      point.some((value) => !Number.isFinite(value) || Math.abs(value) > 1e12),
    )
  ) {
    context.fillStyle = "#8d9b8c";
    context.font = "20px system-ui";
    context.fillText("坐标范围超出绘图精度，数值结果仍可导出。", 235, 310);
    return;
  }
  let minX = Infinity,
    maxX = -Infinity,
    minY = Infinity,
    maxY = -Infinity;
  for (const [x, y] of points) {
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);
  }
  const padding = Math.max(maxX - minX, maxY - minY, 1) * 0.12;
  minX -= padding;
  maxX += padding;
  minY -= padding;
  maxY += padding;
  const scale = Math.min(
    (canvas.width - 100) / (maxX - minX),
    (canvas.height - 100) / (maxY - minY),
  );
  const left = (canvas.width - (maxX - minX) * scale) / 2;
  const top = (canvas.height - (maxY - minY) * scale) / 2;
  const project = (p) => [
    left + (p[0] - minX) * scale,
    canvas.height - top - (p[1] - minY) * scale,
  ];
  const span = Math.max(maxX - minX, maxY - minY);
  const rough = span / 8,
    base = 10 ** Math.floor(Math.log10(rough));
  const step = ([1, 2, 5, 10].find((n) => n * base >= rough) ?? 10) * base;
  context.lineWidth = 1;
  context.strokeStyle = "#d9e2d2";
  context.font = "15px ui-monospace";
  context.fillStyle = "#7e8f7c";
  for (let x = Math.ceil(minX / step) * step; x <= maxX; x += step) {
    const [px] = project([x, 0]);
    context.beginPath();
    context.moveTo(px, top);
    context.lineTo(px, canvas.height - top);
    context.stroke();
    context.fillText(`${+x.toFixed(2)}`, px + 5, canvas.height - top + 22);
  }
  for (let y = Math.ceil(minY / step) * step; y <= maxY; y += step) {
    const [, py] = project([0, y]);
    context.beginPath();
    context.moveTo(left, py);
    context.lineTo(canvas.width - left, py);
    context.stroke();
    context.fillText(`${+y.toFixed(2)}`, left - 38, py + 5);
  }
  context.fillText("m", canvas.width - 35, canvas.height - 22);
  if (roi.length) {
    context.beginPath();
    roi.forEach((p, i) => {
      const [x, y] = project(p);
      i ? context.lineTo(x, y) : context.moveTo(x, y);
    });
    context.closePath();
    context.fillStyle = "#dbe8d250";
    context.fill();
    context.setLineDash([7, 7]);
    context.strokeStyle = "#9caf96";
    context.stroke();
    context.setLineDash([]);
  }
  for (const [key, path] of histories) {
    const hue = (Number(key.split(":")[0]) * 83 + 135) % 360;
    context.strokeStyle = `hsl(${hue} 38% 39%)`;
    context.lineWidth = 3;
    context.beginPath();
    path.forEach((p, i) => {
      const [x, y] = project(p);
      i ? context.lineTo(x, y) : context.moveTo(x, y);
    });
    context.stroke();
    const [x, y] = project(path.at(-1));
    context.fillStyle = context.strokeStyle;
    context.beginPath();
    context.arc(x, y, 6, 0, Math.PI * 2);
    context.fill();
    context.font = "bold 16px system-ui";
    context.fillText(`#${key}`, x + 12, y - 10);
  }
}

function render() {
  const index = Number(slider.value),
    frame = results[index];
  if (!frame) return;
  $("counter").textContent = `${index + 1} / ${results.length}`;
  const first = BigInt(results[0].timestamp_us),
    current = BigInt(frame.timestamp_us);
  $("time").textContent = `t + ${(Number(current - first) / 1e6).toFixed(3)} s`;
  const ready = frame.tracks.filter((t) => t.status === "ready");
  $("ready").textContent = String(ready.length);
  $("speed").textContent = ready.length
    ? `${Math.max(...ready.map((t) => t.speed_mps)).toFixed(2)} m/s`
    : "—";
  $("segments").textContent = String(
    new Set(frame.tracks.filter((t) => t.segment_id).map((t) => t.segment_id))
      .size,
  );
  const rows = frame.tracks.map((track) => {
    const tr = document.createElement("tr");
    const values = [
      `${track.track_id} / ${track.segment_id ?? "—"}`,
      states[track.status] ?? track.status,
      track.position_m
        ? track.position_m.map((n) => n.toFixed(2)).join(", ")
        : "—",
      track.speed_mps === null ? "—" : track.speed_mps.toFixed(2),
      track.observed_path_length_m === undefined
        ? "—"
        : track.observed_path_length_m.toFixed(2),
    ];
    for (const [i, value] of values.entries()) {
      const td = document.createElement("td");
      td.textContent = value;
      if (i === 1) {
        const span = document.createElement("span");
        span.className = "status";
        span.textContent = value;
        td.replaceChildren(span);
        if (track.reason) td.title = track.reason;
      }
      tr.append(td);
    }
    return tr;
  });
  if (!rows.length) {
    const tr = document.createElement("tr"),
      td = document.createElement("td");
    td.colSpan = 5;
    td.textContent = "本帧无可见观测。缺测期间不显示预测速度。";
    tr.append(td);
    rows.push(tr);
  }
  $("tracks").replaceChildren(...rows);
  draw();
}

async function run() {
  invalidate();
  const currentRevision = revision,
    input = source.value;
  let handle;
  try {
    if (new TextEncoder().encode(input).length > 8 * 1024 * 1024)
      throw new Error("浏览器输入上限为 8 MiB；更大的流请使用原生命令。");
    const lines = input.trimEnd().split(/\r?\n/);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入配置及 1—5000 帧观测。");
    const config = JSON.parse(lines[0]);
    handle = unpack(moonground_create(lines[0])).handle;
    const computed = [];
    for (let i = 1; i < lines.length; i++) {
      if (currentRevision !== revision) return;
      if (new TextEncoder().encode(lines[i]).length > 1048576)
        throw new Error(`第 ${i + 1} 行超过 1 MiB。`);
      try {
        computed.push(unpack(moonground_update(handle, lines[i])));
      } catch (error) {
        throw new Error(`第 ${i + 1} 行：${error.message}`);
      }
      if (i % 50 === 0) {
        message(`已计算 ${i} / ${lines.length - 1} 帧…`);
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
    }
    if (currentRevision !== revision) return;
    configuration = config;
    results = computed;
    loadedSource = input;
    slider.max = String(results.length - 1);
    slider.value = "0";
    slider.disabled = false;
    $("play").disabled = false;
    $("download").disabled = false;
    message(
      `已完成 ${results.length} 帧。有效区域以虚线显示；所有计算均在本地完成。`,
    );
    render();
  } catch (error) {
    if (currentRevision === revision) message(error.message, true);
  } finally {
    if (handle !== undefined) moonground_close(handle);
  }
}

source.addEventListener("input", () => {
  invalidate();
  message("输入已修改，请重新计算。");
});
$("run").addEventListener("click", run);
slider.addEventListener("input", () => {
  stop();
  render();
});
$("play").addEventListener("click", () => {
  if (playing !== null) {
    stop();
    return;
  }
  if (Number(slider.value) >= results.length - 1) slider.value = "0";
  $("play").textContent = "暂停";
  playing = setInterval(() => {
    const next = Number(slider.value) + 1;
    if (next >= results.length) {
      stop();
      return;
    }
    slider.value = String(next);
    render();
  }, 200);
});
$("file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  invalidate();
  const current = revision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器输入上限为 8 MiB。");
    const text = await file.text();
    if (current !== revision) return;
    source.value = text;
    await run();
  } catch (error) {
    if (current === revision) message(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("download").addEventListener("click", () => {
  if (!results.length || source.value !== loadedSource) return;
  const blob = new Blob(
    [
      JSON.stringify(
        { schema_version: "0.1.0", configuration, frames: results },
        null,
        2,
      ),
    ],
    { type: "application/json" },
  );
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = "moonground-results.json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
async function example() {
  invalidate();
  const current = revision;
  try {
    const response = await fetch("./warehouse.ndjson");
    if (!response.ok) throw new Error("示例读取失败");
    const text = await response.text();
    if (current !== revision) return;
    source.value = text;
    await run();
  } catch (error) {
    if (current === revision) message(error.message, true);
  }
}
$("example").addEventListener("click", example);
$("calibrate").addEventListener("click", () => {
  try {
    const fitted = unpack(moonground_calibrate($("calibration-input").value));
    const lines = source.value.trimEnd().split(/\r?\n/);
    const config = JSON.parse(lines[0]);
    config.mode = "pixel";
    config.calibration = fitted.calibration;
    lines[0] = JSON.stringify(config);
    source.value = lines.join("\n") + "\n";
    invalidate();
    message("标定已替换，请重新计算观测。");
    $("calibration-message").textContent =
      `拟合 ${fitted.report.fit_count} 点，核验 ${fitted.report.check_count} 点；核验最大残差 ${fitted.report.check_max_error_m.toExponential(2)} m。`;
  } catch (error) {
    $("calibration-message").textContent = error.message;
  }
});
fetch("./calibration.json")
  .then((response) => {
    if (!response.ok) throw new Error("无法读取标定示例");
    return response.text();
  })
  .then((text) => {
    $("calibration-input").value = text;
  })
  .catch((error) => {
    $("calibration-message").textContent = error.message;
  });
draw();
example();
