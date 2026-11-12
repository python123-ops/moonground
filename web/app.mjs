import {
  moonground_create,
  moonground_update,
  moonground_close,
  moonground_project,
  moonground_calibrate,
  moonground_checkpoint,
  moonground_restore,
  moonground_reframe,
  moonground_gates,
  moonground_analysis,
} from "./moonground.mjs";

const $ = (id) => document.getElementById(id);
const source = $("source");
const calibrationInput = $("calibration-input");
const gateInput = $("gate-input");
const slider = $("frame");
const canvas = $("ground");
const context = canvas.getContext("2d");
let revision = 0;
let results = [];
let configuration = null;
let playing = null;
let loadedSource = "";
let checkpointBusy = false;
let calibrationEdited = false;
let calibrationRevision = 0;
let calibrationResponse = null;
let fittedCalibrationInput = "";
let calibrationNeedsCoordinates = false;
let measurementLines = [];
let gateRevision = 0;
let gateEdited = false;
let gateReport = null;
let gateResponse = null;
let gateDefinitions = [];
let gatesBusy = false;
let analysisBusy = false;
let analysisCheckpointBusy = false;
let analysisResponse = null;
let analysisHeader = null;
let analysisGateInput = "";
const states = {
  initializing: "初始化",
  ready: "可读取速度",
  uncertain: "不确定性超限",
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
  measurementLines = [];
  clearGateResult();
  configuration = null;
  loadedSource = "";
  $("download").disabled = true;
  $("save-checkpoint").disabled = true;
  $("play").disabled = true;
  slider.disabled = true;
  $("counter").textContent = "0 / 0";
  $("time").textContent = "—";
  for (const id of ["ready", "speed", "segments"]) $(id).textContent = "—";
  $("tracks").replaceChildren();
  draw();
}

function gateMessage(text, error = false) {
  $("gate-message").textContent = text;
  $("gate-message").classList.toggle("error", error);
}

function clearGateResult() {
  gateRevision++;
  clearAnalysisResult();
  gateReport = null;
  gateResponse = null;
  gateDefinitions = [];
  $("download-gates").disabled = true;
  $("analyze-gates").disabled = !results.length || gatesBusy;
  $("gate-counts").replaceChildren();
  $("gate-events").replaceChildren();
  gateMessage(
    results.length
      ? "通道配置已修改，请重新统计。"
      : "先计算观测，再统计过线。",
  );
}

function analysisMessage(text, error = false) {
  $("analysis-message").textContent = text;
  $("analysis-message").classList.toggle("error", error);
}

function clearAnalysisResult() {
  analysisResponse = null;
  analysisHeader = null;
  analysisGateInput = "";
  $("download-analysis").disabled = true;
  $("save-analysis-checkpoint").disabled = true;
  analysisMessage("一次计算测量与过线，保存同一帧的完整检查点。");
}

function analysisIsCurrent() {
  return (
    analysisResponse !== null &&
    source.value === loadedSource &&
    gateInput.value === analysisGateInput
  );
}

function observationLines(input) {
  const lines = input.split("\n");
  if (lines.at(-1) === "") lines.pop();
  return lines;
}

function analysisRequest(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器联合输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("联合请求超过 16 Mi 字符上限，请使用原生命令。");
  return request;
}

function analysisReport(request) {
  const response = moonground_analysis(request);
  const report = unpack(response);
  if (new TextEncoder().encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器联合结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

function renderGates(index) {
  const frame = gateReport?.frames[index];
  $("gate-counts").replaceChildren();
  $("gate-events").replaceChildren();
  if (!frame) return;
  for (const count of frame.counts) {
    const row = document.createElement("tr");
    for (const value of [
      count.gate_id,
      count.negative_to_positive,
      count.positive_to_negative,
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    $("gate-counts").append(row);
  }
  for (const crossing of frame.crossings) {
    const item = document.createElement("li");
    const direction =
      crossing.direction === "negative_to_positive"
        ? "负侧 → 正侧"
        : "正侧 → 负侧";
    item.textContent = `${crossing.gate_id} · 目标 ${crossing.track_id} / 片段 ${crossing.segment_id} · ${direction} · 交点 (${crossing.position_m.map((n) => n.toFixed(3)).join(", ")}) m；时间区间 [${crossing.from_timestamp_us}, ${crossing.to_timestamp_us}] μs，区间比例 ${crossing.crossing_fraction.toFixed(6)}`;
    $("gate-events").append(item);
  }
  if (!frame.crossings.length) {
    const item = document.createElement("li");
    item.textContent = "本帧无过线事件。";
    $("gate-events").append(item);
  }
}

function unpack(text) {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value;
}

function clearCalibrationResult() {
  calibrationResponse = null;
  fittedCalibrationInput = "";
  $("download-calibration").disabled = true;
  $("calibration-message").textContent = "";
  $("calibration-diagnostics").hidden = true;
  $("calibration-residuals").replaceChildren();
}

function calibrationDiagnostics(fitted) {
  const maximum = fitted.report.check_max_error_m.toExponential(2);
  const rows = document.createDocumentFragment();
  const report = fitted.robust_report;
  if (!report) {
    return {
      message: `拟合 ${fitted.report.fit_count} 点，核验 ${fitted.report.check_count} 点；核验最大残差 ${maximum} m。`,
      rows,
      robust: false,
    };
  }
  if (
    report.control_count > 256 ||
    report.inlier_mask.length !== report.control_count ||
    report.control_errors_m.length !== report.control_count
  ) {
    throw new Error("稳健标定响应中的控制点诊断不完整。");
  }
  for (let index = 0; index < report.control_count; index++) {
    const row = document.createElement("li");
    row.textContent = `第 ${index + 1} 控制点 · ${report.inlier_mask[index] ? "保留" : "排除"} · 误差 ${report.control_errors_m[index].toExponential(3)} m`;
    rows.append(row);
  }
  const excluded = report.outlier_indices.length
    ? `排除控制点（从 1 编号）：${report.outlier_indices.map((index) => index + 1).join("、")}。`
    : "未排除控制点。";
  return {
    message: `稳健拟合保留 ${report.inlier_count} / ${report.control_count} 个控制点，核验 ${fitted.report.check_count} 点；核验最大残差 ${maximum} m。${excluded}`,
    rows,
    robust: true,
  };
}

function openSession(line) {
  const handle = unpack(moonground_create(line)).handle;
  try {
    const bootstrap = JSON.parse(line);
    return {
      handle,
      resumed: Object.hasOwn(bootstrap, "resume"),
      configuration: Object.hasOwn(bootstrap, "resume")
        ? bootstrap.resume.configuration
        : bootstrap,
    };
  } catch (error) {
    moonground_close(handle);
    throw error;
  }
}

function saveFile(text, name) {
  const url = URL.createObjectURL(
    new Blob([text], { type: "application/json" }),
  );
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function selectedCheckpoint(currentRevision) {
  const lines = loadedSource.trimEnd().split(/\r?\n/);
  const last = Number(slider.value) + 1;
  let handle;
  try {
    handle = openSession(lines[0]).handle;
    for (let i = 1; i <= last; i++) {
      if (revision !== currentRevision) return null;
      unpack(moonground_update(handle, lines[i]));
      if (i % 50 === 0) await new Promise((resolve) => setTimeout(resolve, 0));
    }
    if (revision !== currentRevision) return null;
    const checkpoint = moonground_checkpoint(handle);
    unpack(checkpoint);
    if (new TextEncoder().encode(checkpoint).length > 8 * 1024 * 1024)
      throw new Error("检查点超过浏览器 8 MiB 文件上限，请使用原生命令。");
    return checkpoint;
  } finally {
    if (handle !== undefined) moonground_close(handle);
  }
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
  for (const gate of gateDefinitions) points.push(gate.start_m, gate.end_m);
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
  for (const gate of gateDefinitions) {
    const [ax, ay] = project(gate.start_m);
    const [bx, by] = project(gate.end_m);
    context.strokeStyle = "#b26025";
    context.lineWidth = 3;
    context.setLineDash([10, 5]);
    context.beginPath();
    context.moveTo(ax, ay);
    context.lineTo(bx, by);
    context.stroke();
    context.setLineDash([]);
    context.font = "bold 15px system-ui";
    context.fillStyle = "#8d451b";
    context.fillText(`${gate.gate_id} · A→B`, ax + 9, ay - 10);
    const length = Math.hypot(bx - ax, by - ay);
    if (length > 0) {
      const ux = (bx - ax) / length,
        uy = (by - ay) / length;
      context.beginPath();
      context.moveTo(bx - 11 * ux + 5 * uy, by - 11 * uy - 5 * ux);
      context.lineTo(bx, by);
      context.lineTo(bx - 11 * ux - 5 * uy, by - 11 * uy + 5 * ux);
      context.stroke();
    }
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
  for (const crossing of gateReport?.frames[index]?.crossings ?? []) {
    const [x, y] = project(crossing.position_m);
    context.fillStyle = "#d67c29";
    context.strokeStyle = "#ffffff";
    context.lineWidth = 3;
    context.beginPath();
    context.arc(x, y, 8, 0, Math.PI * 2);
    context.fill();
    context.stroke();
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
      track.position_std_m == null ? "—" : track.position_std_m.toFixed(3),
      track.velocity_std_mps == null ? "—" : track.velocity_std_mps.toFixed(3),
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
    td.colSpan = 7;
    td.textContent = "本帧无可见观测。缺测期间不显示预测速度。";
    tr.append(td);
    rows.push(tr);
  }
  $("tracks").replaceChildren(...rows);
  renderGates(index);
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
    const opened = openSession(lines[0]);
    const config = opened.configuration;
    handle = opened.handle;
    const computed = [];
    const rawMeasurements = [];
    for (let i = 1; i < lines.length; i++) {
      if (currentRevision !== revision) return;
      if (new TextEncoder().encode(lines[i]).length > 1048576)
        throw new Error(`第 ${i + 1} 行超过 1 MiB。`);
      try {
        const raw = moonground_update(handle, lines[i]);
        computed.push(unpack(raw));
        rawMeasurements.push(raw);
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
    measurementLines = rawMeasurements;
    $("analyze-gates").disabled = gatesBusy;
    loadedSource = input;
    slider.max = String(results.length - 1);
    slider.value = "0";
    slider.disabled = false;
    $("play").disabled = false;
    $("download").disabled = false;
    $("save-checkpoint").disabled = checkpointBusy;
    message(
      `已完成 ${results.length} 帧${opened.resumed ? "（从检查点续接，仅显示后续轨迹）" : ""}。有效区域以虚线显示；所有计算均在本地完成。`,
    );
    render();
  } catch (error) {
    if (currentRevision === revision) message(error.message, true);
  } finally {
    if (handle !== undefined) moonground_close(handle);
  }
}

gateInput.addEventListener("input", () => {
  gateEdited = true;
  clearGateResult();
  draw();
});
$("analyze").addEventListener("click", async () => {
  if (analysisBusy) return;
  const current = ++revision,
    currentGate = ++gateRevision,
    input = source.value,
    gates = gateInput.value;
  analysisBusy = true;
  $("analyze").disabled = true;
  analysisMessage("正在测量并统计过线…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入配置及 1—5000 帧观测。");
    // Both source documents remain strings until MoonBit validates their raw
    // numeric tokens, duplicate keys and checkpoint relationship.
    const header = JSON.stringify({ measurement: lines[0], counting: gates });
    const request = analysisRequest(header, lines.slice(1).join("\n") + "\n");
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== revision || currentGate !== gateRevision) return;
    const { response, report } = analysisReport(request);
    if (current !== revision || currentGate !== gateRevision) return;
    stop();
    configuration = report.checkpoint.measurement.configuration;
    results = report.frames.map((frame) => frame.measurement);
    measurementLines = results.map((frame) => JSON.stringify(frame));
    gateReport = {
      frames: report.frames.map((frame) => frame.counting),
      checkpoint: report.checkpoint.counting,
    };
    gateDefinitions = report.checkpoint.counting.configuration.gates;
    gateResponse = JSON.stringify(gateReport);
    loadedSource = input;
    analysisHeader = header;
    analysisGateInput = gates;
    analysisResponse = response;
    slider.max = String(results.length - 1);
    slider.value = "0";
    slider.disabled = false;
    $("play").disabled = false;
    $("download").disabled = false;
    $("save-checkpoint").disabled = checkpointBusy;
    $("analyze-gates").disabled = gatesBusy;
    $("download-gates").disabled = false;
    $("download-analysis").disabled = false;
    $("save-analysis-checkpoint").disabled = analysisCheckpointBusy;
    const events = gateReport.frames.reduce(
      (total, frame) => total + frame.crossings.length,
      0,
    );
    message(`已测量并统计 ${results.length} 帧。测量与过线在同一帧提交。`);
    gateMessage(`已统计 ${results.length} 帧、${events} 次过线。`);
    analysisMessage(
      `联合状态已同步至 ${report.checkpoint.measurement.motion.last_timestamp_us} μs。完整结果含末帧检查点；当前帧检查点随回放选择保存。`,
    );
    render();
  } catch (error) {
    if (current === revision && currentGate === gateRevision)
      analysisMessage(error.message, true);
  } finally {
    analysisBusy = false;
    $("analyze").disabled = false;
  }
});
$("download-analysis").addEventListener("click", () => {
  if (!analysisIsCurrent()) return;
  saveFile(analysisResponse + "\n", "moonground-analysis-results.json");
});
$("save-analysis-checkpoint").addEventListener("click", async () => {
  if (analysisCheckpointBusy || !analysisIsCurrent()) return;
  const current = revision,
    currentGate = gateRevision,
    selected = slider.value;
  analysisCheckpointBusy = true;
  $("save-analysis-checkpoint").disabled = true;
  stop();
  try {
    const lines = observationLines(loadedSource);
    const observations = lines.slice(1, Number(selected) + 2).join("\n") + "\n";
    const request = analysisRequest(analysisHeader, observations);
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== revision || currentGate !== gateRevision) return;
    const { report } = analysisReport(request);
    if (
      current !== revision ||
      currentGate !== gateRevision ||
      slider.value !== selected
    )
      return;
    saveFile(
      JSON.stringify(report.checkpoint) + "\n",
      "moonground-analysis-checkpoint.json",
    );
    analysisMessage(
      `已保存第 ${Number(selected) + 1} 帧的完整检查点，测量与过线时间均为 ${report.checkpoint.measurement.motion.last_timestamp_us} μs。`,
    );
  } catch (error) {
    if (current === revision && currentGate === gateRevision)
      analysisMessage(error.message, true);
  } finally {
    analysisCheckpointBusy = false;
    $("save-analysis-checkpoint").disabled = !analysisIsCurrent();
  }
});
$("analysis-checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const current = ++revision,
    currentGate = ++gateRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器完整检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== revision || currentGate !== gateRevision) return;
    // Validate the complete raw checkpoint before deriving either old-format
    // resume input. No partial import can replace the displayed state.
    const { report } = analysisReport(
      analysisRequest('{"resume":' + text + "}", ""),
    );
    const checkpoint = report.checkpoint;
    const nextInput = JSON.stringify({ resume: checkpoint.measurement }) + "\n";
    const nextGates = JSON.stringify({ resume: checkpoint.counting }, null, 2);
    analysisRequest(
      JSON.stringify({
        measurement: nextInput.slice(0, -1),
        counting: nextGates,
      }),
      "",
    );
    if (current !== revision || currentGate !== gateRevision) return;
    invalidate();
    source.value = nextInput;
    gateInput.value = nextGates;
    gateEdited = true;
    configuration = checkpoint.measurement.configuration;
    gateDefinitions = checkpoint.counting.configuration.gates;
    draw();
    const last = checkpoint.measurement.motion.last_timestamp_us;
    message(
      `已载入完整分析检查点。在下一行添加晚于 ${last ?? "起点"} μs 的观测。`,
    );
    analysisMessage(
      `测量与过线已共同恢复至 ${last ?? "尚无观测"} μs；点击“测量并统计”继续。`,
    );
  } catch (error) {
    if (current === revision && currentGate === gateRevision)
      analysisMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("analyze-gates").addEventListener("click", async () => {
  if (gatesBusy || !results.length || source.value !== loadedSource) return;
  const current = revision,
    currentGate = gateRevision;
  gatesBusy = true;
  $("analyze-gates").disabled = true;
  gateMessage("正在统计过线…");
  try {
    const measurements = measurementLines.join("\n") + "\n";
    const encoder = new TextEncoder();
    if (
      encoder.encode(gateInput.value).length > 8 * 1024 * 1024 ||
      encoder.encode(measurements).length > 8 * 1024 * 1024
    )
      throw new Error(
        "浏览器过线输入上限为 8 MiB；更长的测量流请使用原生命令。",
      );
    const request = JSON.stringify({ source: gateInput.value, measurements });
    if (request.length > 16 * 1024 * 1024)
      throw new Error("过线请求超过 16 Mi 字符上限，请使用原生命令。");
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== revision || currentGate !== gateRevision) return;
    const response = moonground_gates(request);
    const report = unpack(response);
    if (encoder.encode(response).length > 8 * 1024 * 1024)
      throw new Error("浏览器过线结果超过 8 MiB；请使用原生命令保存。");
    if (current !== revision || currentGate !== gateRevision) return;
    gateDefinitions = report.checkpoint.configuration.gates;
    gateReport = report;
    gateResponse = response;
    $("download-gates").disabled = false;
    const events = report.frames.reduce(
      (total, frame) => total + frame.crossings.length,
      0,
    );
    gateMessage(
      `已统计 ${report.frames.length} 帧、${events} 次过线。下方显示所选帧的累计计数；下载含最终检查点。`,
    );
    render();
  } catch (error) {
    if (current === revision && currentGate === gateRevision)
      gateMessage(error.message, true);
  } finally {
    gatesBusy = false;
    $("analyze-gates").disabled =
      !results.length || source.value !== loadedSource;
  }
});
$("download-gates").addEventListener("click", () => {
  if (gateResponse === null || source.value !== loadedSource) return;
  saveFile(gateResponse + "\n", "moonground-gate-results.json");
});

source.addEventListener("input", () => {
  invalidate();
  message("输入已修改，请重新计算。");
});
calibrationInput.addEventListener("input", () => {
  calibrationEdited = true;
  calibrationNeedsCoordinates = false;
  calibrationRevision++;
  clearCalibrationResult();
  $("calibration-message").textContent = "标定输入已修改，请重新拟合。";
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
  saveFile(
    JSON.stringify(
      { schema_version: "0.2.0", configuration, frames: results },
      null,
      2,
    ),
    "moonground-results.json",
  );
});

$("save-checkpoint").addEventListener("click", async () => {
  if (checkpointBusy || !results.length || source.value !== loadedSource)
    return;
  const current = revision;
  checkpointBusy = true;
  $("save-checkpoint").disabled = true;
  stop();
  try {
    const checkpoint = await selectedCheckpoint(current);
    if (checkpoint !== null) {
      saveFile(checkpoint + "\n", "moonground-checkpoint.json");
      message("已保存所选帧的检查点。继续处理时，观测时间须严格晚于该帧。");
    }
  } catch (error) {
    if (revision === current) message(error.message, true);
  } finally {
    checkpointBusy = false;
    $("save-checkpoint").disabled =
      !results.length || source.value !== loadedSource;
  }
});

$("checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  // Cancel older asynchronous work while preserving the valid displayed state
  // until this newly selected checkpoint has passed validation.
  const current = ++revision;
  let handle;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (revision !== current) return;
    handle = unpack(moonground_restore(text)).handle;
    const checkpoint = JSON.parse(text);
    const nextInput = JSON.stringify({ resume: checkpoint }) + "\n";
    if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
      throw new Error("恢复起点超过浏览器 8 MiB 输入上限，请使用原生命令。");
    if (revision !== current) return;
    invalidate();
    source.value = nextInput;
    configuration = checkpoint.configuration;
    draw();
    const last = checkpoint.motion.last_timestamp_us;
    message(
      `已载入检查点（最后帧 ${last ?? "尚无观测"} 微秒）。在下一行添加后续观测后计算。`,
    );
  } catch (error) {
    if (revision === current) message(error.message, true);
  } finally {
    if (handle !== undefined) moonground_close(handle);
    event.target.value = "";
  }
});
async function example(name = "warehouse.ndjson") {
  invalidate();
  const current = revision;
  try {
    const response = await fetch(`./${name}`);
    if (!response.ok) throw new Error("示例读取失败");
    const text = await response.text();
    if (current !== revision) return;
    source.value = text;
    await run();
  } catch (error) {
    if (current === revision) message(error.message, true);
  }
}
$("example").addEventListener("click", () => example());
$("camera-example").addEventListener("click", () =>
  example("distorted-camera.ndjson"),
);
$("resume-example").addEventListener("click", () => example("resume.ndjson"));
$("reframe-example").addEventListener("click", () => example("reframe.ndjson"));
const transformFields = ["scale-x", "scale-y", "offset-x", "offset-y"];
for (const id of transformFields) {
  $(id).addEventListener("input", () => {
    // Parameter edits do not change the loaded observations or their results.
    // They do cancel older reads that could otherwise replace this draft.
    revision++;
  });
}
$("reframe").addEventListener("click", () => {
  const current = ++revision;
  try {
    const values = transformFields.map((id) => $(id).valueAsNumber);
    if (values.some((value) => !Number.isFinite(value)))
      throw new Error("请填写有限的缩放倍率与偏移像素数。");
    if (values[0] <= 0 || values[1] <= 0)
      throw new Error("水平和垂直缩放倍率须大于 0。");
    if (new TextEncoder().encode(source.value).length > 8 * 1024 * 1024)
      throw new Error("浏览器输入上限为 8 MiB；更大的流请使用原生命令。");
    const transformed = unpack(
      moonground_reframe(
        JSON.stringify({
          ndjson: source.value,
          transform: {
            scale_x: values[0],
            scale_y: values[1],
            offset_x: values[2],
            offset_y: values[3],
          },
        }),
      ),
    );
    if (new TextEncoder().encode(transformed.ndjson).length > 8 * 1024 * 1024)
      throw new Error(
        "变换后的观测超过浏览器 8 MiB 输入上限，请使用原生命令。",
      );
    if (current !== revision) return;
    invalidate();
    source.value = transformed.ndjson;
    calibrationEdited = true;
    calibrationRevision++;
    calibrationNeedsCoordinates = true;
    clearCalibrationResult();
    $("calibration-message").textContent =
      "观测坐标已变换。原控制点保留为草稿；请先按新坐标编辑控制点与核验点，再拟合。";
    message(
      `已变换 ${transformed.frame_count} 帧观测及其相机、标定与像素协方差；请重新计算。地面测量状态与检查点历史保持。`,
    );
  } catch (error) {
    if (current === revision) message(error.message, true);
  }
});
$("robust-calibration-example").addEventListener("click", async () => {
  calibrationEdited = true;
  const current = ++calibrationRevision;
  clearCalibrationResult();
  $("calibration-message").textContent = "正在载入稳健标定示例…";
  try {
    const response = await fetch("./robust-calibration.json");
    if (!response.ok) throw new Error("无法读取稳健标定示例");
    const text = await response.text();
    if (current !== calibrationRevision) return;
    calibrationInput.value = text;
    calibrationNeedsCoordinates = false;
    $("calibration-message").textContent =
      "已载入含误标控制点的合成示例；点击拟合后才替换当前标定。";
  } catch (error) {
    if (current === calibrationRevision)
      $("calibration-message").textContent = error.message;
  }
});
$("calibrate").addEventListener("click", () => {
  calibrationEdited = true;
  calibrationRevision++;
  clearCalibrationResult();
  try {
    if (calibrationNeedsCoordinates)
      throw new Error(
        "观测坐标已变换；请先按新坐标编辑控制点与核验点，再拟合。",
      );
    const request = calibrationInput.value;
    const lines = source.value.trimEnd().split(/\r?\n/);
    const config = JSON.parse(lines[0]);
    if (Object.hasOwn(config, "resume"))
      throw new Error("检查点绑定原标定；修改标定时请新建会话配置。");
    const response = moonground_calibrate(request);
    const fitted = unpack(response);
    if (config.camera && !fitted.camera)
      throw new Error(
        "当前观测使用原始像素；拟合请求需提供 camera，或先改用已校正观测及配置。",
      );
    const diagnostics = calibrationDiagnostics(fitted);
    config.mode = "pixel";
    config.calibration = fitted.calibration;
    if (fitted.camera) config.camera = fitted.camera;
    lines[0] = JSON.stringify(config);
    source.value = lines.join("\n") + "\n";
    invalidate();
    message(
      `标定已替换，观测须使用${fitted.camera ? "原始" : "已校正"}像素；请重新计算。`,
    );
    $("calibration-message").textContent = diagnostics.message;
    $("calibration-residuals").replaceChildren(diagnostics.rows);
    $("calibration-diagnostics").hidden = !diagnostics.robust;
    calibrationResponse = response;
    fittedCalibrationInput = request;
    $("download-calibration").disabled = false;
  } catch (error) {
    clearCalibrationResult();
    $("calibration-message").textContent = error.message;
  }
});
$("download-calibration").addEventListener("click", () => {
  if (
    calibrationResponse === null ||
    calibrationInput.value !== fittedCalibrationInput
  ) {
    clearCalibrationResult();
    return;
  }
  saveFile(calibrationResponse + "\n", "moonground-calibration.json");
});
const initialCalibrationRevision = calibrationRevision;
fetch("./calibration.json")
  .then((response) => {
    if (!response.ok) throw new Error("无法读取标定示例");
    return response.text();
  })
  .then((text) => {
    if (
      calibrationRevision === initialCalibrationRevision &&
      !calibrationEdited &&
      calibrationInput.value === ""
    )
      calibrationInput.value = text;
  })
  .catch((error) => {
    if (
      calibrationRevision === initialCalibrationRevision &&
      !calibrationEdited
    )
      $("calibration-message").textContent = error.message;
  });
const initialGateRevision = gateRevision;
fetch("./gates.json")
  .then((response) => {
    if (!response.ok) throw new Error("无法读取通道示例");
    return response.text();
  })
  .then((text) => {
    if (!gateEdited && gateInput.value === "") gateInput.value = text;
  })
  .catch((error) => {
    if (gateRevision === initialGateRevision && !gateEdited)
      gateMessage(error.message, true);
  });
draw();
example();
