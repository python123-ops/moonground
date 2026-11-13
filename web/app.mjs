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
  moonground_health,
  moonground_guarded,
  moonground_transit,
  moonground_gate_evidence,
  moonground_evidence_analysis,
  moonground_evidence_guarded,
  moonground_evidence_guarded_transit,
  moonground_evidence_transit,
  moonground_evidence_transit_analysis,
  moonground_transit_windows,
} from "./moonground.mjs";

const $ = (id) => document.getElementById(id);
const source = $("source");
const calibrationInput = $("calibration-input");
const gateInput = $("gate-input");
const healthInput = $("health-input");
const guardedInput = $("guarded-input");
const transitInput = $("transit-input");
const evidenceInput = $("evidence-input");
const evidenceTransitInput = $("evidence-transit-input");
const transitWindowsInput = $("transit-windows-input");
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
let healthRevision = 0;
let healthReport = null;
let healthResponse = null;
let healthLoadedSource = "";
let healthRunToken = 0;
let guardedRevision = 0;
let guardedRunToken = 0;
let guardedReport = null;
let guardedResponse = null;
let guardedLoadedSource = "";
let transitRevision = 0;
let transitRunToken = 0;
let transitEdited = false;
let transitReport = null;
let transitResponse = null;
let transitOrigin = null;
let transitPendingOrigin = null;
let transitSourceReference = null;
let transitLoadedConfiguration = "";
let evidenceRevision = 0;
let evidenceRunToken = 0;
let evidenceEdited = false;
let evidenceReport = null;
let evidenceResponse = null;
let evidenceOrigin = null;
let evidencePendingOrigin = null;
let evidenceSourceReference = null;
let evidenceLoadedConfiguration = "";
let evidenceJointReport = null;
let evidenceJointResponse = null;
let evidenceJointHeader = null;
let evidenceJointSource = "";
let evidenceJointConfiguration = "";
let evidenceJointCheckpointBusy = false;
let evidenceGuardedRevision = 0;
let evidenceGuardedRunToken = 0;
let evidenceGuardedReport = null;
let evidenceGuardedResponse = null;
let evidenceGuardedLoadedSource = "";
let evidenceGuardedCheckpointBusy = false;
let evidenceGuardedMode = "gates";
let evidenceGuardedTransitRevision = 0;
let evidenceGuardedTransitRunToken = 0;
let evidenceGuardedTransitReport = null;
let evidenceGuardedTransitResponse = null;
let evidenceGuardedTransitLoadedSource = "";
let evidenceGuardedTransitCheckpointBusy = false;
let evidenceTransitRevision = 0;
let evidenceTransitRunToken = 0;
let evidenceTransitEdited = false;
let evidenceTransitReport = null;
let evidenceTransitResponse = null;
let evidenceTransitOrigin = null;
let evidenceTransitPendingOrigin = null;
let evidenceTransitReference = null;
let evidenceTransitConfiguration = "";
let evidenceTransitMode = "independent";
let evidenceTransitJointRevision = 0;
let evidenceTransitJointRunToken = 0;
let evidenceTransitJointReport = null;
let evidenceTransitJointResponse = null;
let evidenceTransitJointHeader = null;
let evidenceTransitJointSource = "";
let evidenceTransitJointConfiguration = "";
let evidenceTransitJointPendingSource = null;
let evidenceTransitJointCheckpointBusy = false;
let transitWindowsRevision = 0;
let transitWindowsRunToken = 0;
let transitWindowsPendingOrigin = null;
let transitWindowsReport = null;
let transitWindowsResponse = null;
let transitWindowsOrigin = null;
let transitWindowsReference = null;
let transitWindowsConfiguration = "";
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
  invalidateEvidenceTransitJointSource();
  stop();
  results = [];
  measurementLines = [];
  invalidateTransitSource("ordinary");
  invalidateEvidenceTransitSource("ordinary");
  invalidateEvidenceSource("ordinary");
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
  renderTransit("ordinary");
  renderEvidenceTransit("ordinary");
  renderEvidence("ordinary");
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
    refreshTransitSources();
    refreshEvidenceSources();
    refreshEvidenceTransitSources();
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
    invalidateTransitSource("ordinary");
    invalidateEvidenceTransitSource("ordinary");
    invalidateEvidenceSource("ordinary");
    gateReport = {
      frames: report.frames.map((frame) => frame.counting),
      checkpoint: report.checkpoint.counting,
    };
    gateDefinitions = report.checkpoint.counting.configuration.gates;
    gateResponse = JSON.stringify(gateReport);
    loadedSource = input;
    refreshTransitSources();
    refreshEvidenceSources();
    refreshEvidenceTransitSources();
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
const healthStates = {
  insufficient: "地标不足",
  pending: "等待持续证据",
  healthy: "残差符合阈值",
  drift: "持续残差超限",
};
const healthEvidence = {
  within_tolerance: "本帧符合阈值",
  beyond_tolerance: "本帧残差超限",
  insufficient: "本帧可用地标不足",
};
const healthColors = {
  insufficient: "#b5c0b3",
  pending: "#dcba72",
  healthy: "#498867",
  drift: "#bb6554",
};

function healthMessage(text, error = false) {
  $("health-message").textContent = text;
  $("health-message").classList.toggle("error", error);
}

function clearHealthResult() {
  healthRevision++;
  healthReport = null;
  healthResponse = null;
  healthLoadedSource = "";
  $("download-health").disabled = true;
  $("save-health-checkpoint").disabled = true;
  $("health-frame").disabled = true;
  $("health-counter").textContent = "0 / 0";
  $("health-time").textContent = "—";
  for (const id of [
    "health-status",
    "health-usable",
    "health-rms",
    "health-max",
    "health-span",
    "health-observations",
  ])
    $(id).textContent = "—";
  $("health-evidence").textContent = "尚无地标检查结果。";
  $("health-residuals").replaceChildren();
  drawHealthTimeline();
}

function drawHealthTimeline() {
  const timeline = $("health-timeline"),
    drawing = timeline.getContext("2d");
  drawing.fillStyle = "#eef3e9";
  drawing.fillRect(0, 0, timeline.width, timeline.height);
  if (!healthReport?.frames.length) return;
  const width = timeline.width / healthReport.frames.length;
  healthReport.frames.forEach((frame, index) => {
    drawing.fillStyle = healthColors[frame.status];
    drawing.fillRect(index * width, 0, Math.max(width, 1), timeline.height);
  });
  const selected = Number($("health-frame").value);
  drawing.strokeStyle = "#20342f";
  drawing.lineWidth = 3;
  drawing.strokeRect(
    selected * width + 1.5,
    1.5,
    Math.max(width - 3, 1),
    timeline.height - 3,
  );
}

function renderHealth() {
  const index = Number($("health-frame").value),
    frame = healthReport?.frames[index];
  if (!frame) return;
  $("health-counter").textContent =
    `${index + 1} / ${healthReport.frames.length}`;
  $("health-time").textContent = `${frame.timestamp_us} μs`;
  $("health-status").textContent = healthStates[frame.status];
  $("health-usable").textContent =
    `${frame.usable_count} / ${frame.landmarks.length}`;
  const metric = (value) =>
    value == null ? "—" : `${value.toExponential(3)} m`;
  $("health-rms").textContent = metric(frame.rms_error_m);
  $("health-max").textContent = metric(frame.max_error_m);
  $("health-span").textContent =
    frame.streak_since_us === null
      ? "—"
      : `${BigInt(frame.timestamp_us) - BigInt(frame.streak_since_us)} μs`;
  $("health-observations").textContent = String(frame.streak_observations);
  $("health-evidence").textContent =
    `${healthEvidence[frame.evidence]}${frame.streak_since_us === null ? "" : `；当前同类证据始于 ${frame.streak_since_us} μs`}。`;
  const rows = frame.landmarks.map((landmark) => {
    const row = document.createElement("tr");
    const vector = (value) =>
      value == null ? "—" : value.map((n) => n.toFixed(4)).join(", ");
    for (const value of [
      landmark.landmark_id,
      vector(landmark.projected_position_m),
      vector(landmark.residual_m),
      metric(landmark.error_m),
      metric(landmark.position_std_m),
      landmark.rejection_reason ?? "可用",
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    return row;
  });
  $("health-residuals").replaceChildren(...rows);
  drawHealthTimeline();
}

function requestHealth(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器地标检查输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("地标检查请求超过 16 Mi 字符上限，请使用原生命令。");
  const response = moonground_health(request);
  const report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器地标检查结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

async function runHealth(
  input = healthInput.value,
  current = ++healthRevision,
) {
  const runToken = ++healthRunToken;
  $("run-health").disabled = true;
  healthMessage("正在检查固定地标…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入地标配置及 1—5000 帧观测。");
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== healthRevision) return;
    // Preserve raw configuration, covariance and timestamp tokens for MoonBit.
    const { response, report } = requestHealth(
      lines[0],
      lines.slice(1).join("\n") + "\n",
    );
    if (current !== healthRevision) return;
    healthInput.value = input;
    healthLoadedSource = input;
    healthReport = report;
    healthResponse = response;
    $("health-frame").max = String(report.frames.length - 1);
    $("health-frame").value = String(report.frames.length - 1);
    $("health-frame").disabled = false;
    $("download-health").disabled = false;
    $("save-health-checkpoint").disabled = false;
    healthMessage(
      `已检查 ${report.frames.length} 帧固定地标。状态仅描述这些地标在原标定下的残差；测量与标定均未修改。`,
    );
    renderHealth();
  } catch (error) {
    if (current === healthRevision) healthMessage(error.message, true);
  } finally {
    if (runToken === healthRunToken) $("run-health").disabled = false;
  }
}

healthInput.addEventListener("input", () => {
  clearHealthResult();
  healthMessage("地标输入已修改，请重新检查。");
});
$("run-health").addEventListener("click", () => runHealth());
$("health-frame").addEventListener("input", renderHealth);
$("download-health").addEventListener("click", () => {
  if (healthResponse === null || healthInput.value !== healthLoadedSource)
    return;
  saveFile(healthResponse + "\n", "moonground-health-results.json");
});
$("save-health-checkpoint").addEventListener("click", () => {
  if (!healthReport || healthInput.value !== healthLoadedSource) return;
  saveFile(
    JSON.stringify(healthReport.checkpoint) + "\n",
    "moonground-health-checkpoint.json",
  );
  healthMessage(
    `已保存整批末帧 ${healthReport.checkpoint.state.last_timestamp_us} μs 的地标检查点。`,
  );
});
$("health-example").addEventListener("click", async () => {
  const current = ++healthRevision;
  try {
    const response = await fetch("./health.ndjson");
    if (!response.ok) throw new Error("地标示例读取失败。");
    const text = await response.text();
    if (current !== healthRevision) return;
    await runHealth(text, current);
  } catch (error) {
    if (current === healthRevision) healthMessage(error.message, true);
  }
});
$("health-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const current = ++healthRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器地标输入文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== healthRevision) return;
    await runHealth(text, current);
  } catch (error) {
    if (current === healthRevision) healthMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("health-checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const current = ++healthRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器地标检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== healthRevision) return;
    const { report } = requestHealth('{"resume":' + text + "}", "");
    const nextInput = JSON.stringify({ resume: report.checkpoint }) + "\n";
    if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
      throw new Error("恢复起点超过浏览器 8 MiB 输入上限，请使用原生命令。");
    if (current !== healthRevision) return;
    clearHealthResult();
    healthInput.value = nextInput;
    healthMessage(
      `已载入地标检查点（末帧 ${report.checkpoint.state.last_timestamp_us ?? "尚无观测"} μs）。添加更晚的地标观测后继续检查。`,
    );
  } catch (error) {
    if (current === healthRevision) healthMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});

function guardedMessage(text, error = false) {
  $("guarded-message").textContent = text;
  $("guarded-message").classList.toggle("error", error);
}

function clearGuardedResult() {
  clearEvidenceGuardedResult();
  clearEvidenceGuardedTransitResult();
  guardedRevision++;
  guardedReport = null;
  guardedResponse = null;
  guardedLoadedSource = "";
  invalidateTransitSource("guarded");
  invalidateEvidenceSource("guarded");
  $("download-guarded").disabled = true;
  $("save-guarded-checkpoint").disabled = true;
  $("guarded-frame").disabled = true;
  $("guarded-counter").textContent = "0 / 0";
  $("guarded-time").textContent = "—";
  for (const id of [
    "guarded-decision",
    "guarded-health",
    "guarded-usable",
    "guarded-rms",
    "guarded-observed",
    "guarded-crossings",
  ])
    $(id).textContent = "—";
  $("guarded-evidence").textContent = "尚无门控分析结果。";
  $("guarded-projection").textContent = "";
  $("guarded-interruptions").textContent = "";
  $("guarded-tracks").replaceChildren();
  $("guarded-counts").replaceChildren();
  $("guarded-events").replaceChildren();
  drawGuardedTimeline();
}

function drawGuardedTimeline() {
  const timeline = $("guarded-timeline"),
    drawing = timeline.getContext("2d");
  drawing.fillStyle = "#eef3e9";
  drawing.fillRect(0, 0, timeline.width, timeline.height);
  if (!guardedReport?.frames.length) return;
  const width = timeline.width / guardedReport.frames.length;
  guardedReport.frames.forEach((frame, index) => {
    drawing.fillStyle = healthColors[frame.health.status];
    drawing.fillRect(index * width, 0, Math.max(width, 1), 36);
    drawing.fillStyle = frame.decision === "allowed" ? "#24674d" : "#a56c61";
    drawing.fillRect(index * width, 40, Math.max(width, 1), 16);
    if (frame.kind === "guarded_projection_replaced") {
      drawing.fillStyle = "#72509c";
      drawing.fillRect((index + 0.5) * width - 1.5, 0, 3, timeline.height);
    }
  });
  drawing.strokeStyle = "#20342f";
  drawing.lineWidth = 3;
  drawing.strokeRect(
    Number($("guarded-frame").value) * width + 1.5,
    1.5,
    Math.max(width - 3, 1),
    timeline.height - 3,
  );
}

function renderGuarded() {
  const index = Number($("guarded-frame").value),
    frame = guardedReport?.frames[index];
  if (!frame) return;
  const health = frame.health,
    measurement = frame.analysis.measurement,
    counting = frame.analysis.counting,
    replaced = frame.kind === "guarded_projection_replaced",
    replacements = guardedReport.frames
      .slice(0, index + 1)
      .filter((entry) => entry.kind === "guarded_projection_replaced").length;
  $("guarded-counter").textContent =
    `${index + 1} / ${guardedReport.frames.length}`;
  $("guarded-time").textContent = `${health.timestamp_us} μs`;
  $("guarded-decision").textContent = replaced
    ? "切换标定"
    : frame.decision === "allowed"
      ? "已放行"
      : "已阻断";
  $("guarded-health").textContent = healthStates[health.status];
  $("guarded-usable").textContent =
    `${health.usable_count} / ${health.landmarks.length}`;
  $("guarded-rms").textContent =
    health.rms_error_m == null
      ? "—"
      : `${health.rms_error_m.toExponential(3)} m`;
  $("guarded-observed").textContent = String(measurement.tracks.length);
  $("guarded-crossings").textContent = String(counting.crossings.length);
  $("guarded-evidence").textContent = replaced
    ? "已切换标定与相机，本帧不处理观测。旧测量片段与过线参考点已关闭；地标健康从下一帧重新确认。"
    : `${healthEvidence[health.evidence]}；${frame.decision === "allowed" ? "当前健康已确认，处理本帧目标。" : "当前帧未满足健康放行条件，未处理本帧目标；已有测量片段与过线参考点已中断。"}`;
  $("guarded-projection").textContent =
    `本次回放至此发生 ${replacements} 次标定切换。${replaced ? "地标米制位置、通道及累计次数保持，后续目标从新片段预热。" : ""}`;
  $("guarded-interruptions").textContent =
    `本帧被抑制的目标：${frame.suppressed_track_ids.join("、") || "无"}；关闭的测量片段：${measurement.closed_segment_ids.join("、") || "无"}。`;
  const rows = measurement.tracks.map((track) => {
    const row = document.createElement("tr");
    for (const value of [
      `${track.track_id} / ${track.segment_id ?? "—"}`,
      states[track.status] ?? track.status,
      track.position_m?.map((n) => n.toFixed(3)).join(", ") ?? "—",
      track.speed_mps == null ? "—" : track.speed_mps.toFixed(3),
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    return row;
  });
  if (!rows.length) {
    const row = document.createElement("tr"),
      cell = document.createElement("td");
    cell.colSpan = 4;
    cell.textContent = replaced
      ? "标定切换帧，未生成目标测量。"
      : frame.decision === "blocked"
        ? "本帧被健康状态阻断，未生成目标测量。"
        : "本帧无目标观测。";
    row.append(cell);
    rows.push(row);
  }
  $("guarded-tracks").replaceChildren(...rows);
  $("guarded-counts").replaceChildren(
    ...counting.counts.map((count) => {
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
      return row;
    }),
  );
  $("guarded-events").replaceChildren(
    ...counting.crossings.map((crossing) => {
      const item = document.createElement("li");
      item.textContent = `${crossing.gate_id} · 目标 ${crossing.track_id} / 片段 ${crossing.segment_id} · ${crossing.direction === "negative_to_positive" ? "负侧 → 正侧" : "正侧 → 负侧"} · 时间区间 [${crossing.from_timestamp_us}, ${crossing.to_timestamp_us}] μs`;
      return item;
    }),
  );
  drawGuardedTimeline();
  renderTransit("guarded");
  renderEvidence("guarded");
}

function requestGuarded(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器门控分析输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("门控分析请求超过 16 Mi 字符上限，请使用原生命令。");
  const response = moonground_guarded(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器门控分析结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

async function runGuarded(
  input = guardedInput.value,
  current = ++guardedRevision,
) {
  cancelOtherGuardedPreparations("legacy");
  const runToken = ++guardedRunToken;
  $("run-guarded").disabled = true;
  guardedMessage("正在按地标健康状态分析…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入门控分析配置及 1—5000 行联合观测或标定切换操作。");
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== guardedRevision) return;
    const { response, report } = requestGuarded(
      lines[0],
      lines.slice(1).join("\n") + "\n",
    );
    if (current !== guardedRevision) return;
    if (guardedInput.value !== input) {
      clearEvidenceGuardedResult();
      clearEvidenceGuardedTransitResult();
    }
    guardedInput.value = input;
    invalidateTransitSource("guarded");
    invalidateEvidenceSource("guarded");
    guardedLoadedSource = input;
    guardedReport = report;
    guardedResponse = response;
    refreshTransitSources();
    refreshEvidenceSources();
    $("guarded-frame").max = String(report.frames.length - 1);
    $("guarded-frame").value = String(report.frames.length - 1);
    $("guarded-frame").disabled = false;
    $("download-guarded").disabled = false;
    $("save-guarded-checkpoint").disabled = false;
    const blocked = report.frames.filter(
      (frame) => frame.decision === "blocked",
    ).length;
    const replacements = report.frames.filter(
      (frame) => frame.kind === "guarded_projection_replaced",
    ).length;
    guardedMessage(
      `已完成 ${report.frames.length} 帧门控分析，阻断 ${blocked} 帧${replacements ? `，含 ${replacements} 次标定切换` : ""}。下载包含全部帧及同一末帧的完整检查点。`,
    );
    renderGuarded();
  } catch (error) {
    if (current === guardedRevision) guardedMessage(error.message, true);
  } finally {
    if (runToken === guardedRunToken) $("run-guarded").disabled = false;
  }
}

guardedInput.addEventListener("input", () => {
  clearGuardedResult();
  guardedMessage("门控分析输入已修改，请重新计算。");
});
$("run-guarded").addEventListener("click", () => runGuarded());
$("guarded-frame").addEventListener("input", renderGuarded);
$("download-guarded").addEventListener("click", () => {
  if (guardedResponse === null || guardedInput.value !== guardedLoadedSource)
    return;
  saveFile(guardedResponse + "\n", "moonground-guarded-results.json");
});
$("save-guarded-checkpoint").addEventListener("click", () => {
  if (!guardedReport || guardedInput.value !== guardedLoadedSource) return;
  saveFile(
    JSON.stringify(guardedReport.checkpoint) + "\n",
    "moonground-guarded-checkpoint.json",
  );
  guardedMessage(
    `已保存整批末帧 ${guardedReport.checkpoint.health.state.last_timestamp_us} μs 的完整门控检查点。`,
  );
});
async function guardedExample(name = "guarded.ndjson") {
  cancelOtherGuardedPreparations("legacy");
  const current = ++guardedRevision;
  try {
    const response = await fetch(`./${name}`);
    if (!response.ok) throw new Error("门控分析示例读取失败。");
    const text = await response.text();
    if (current !== guardedRevision) return;
    await runGuarded(text, current);
  } catch (error) {
    if (current === guardedRevision) guardedMessage(error.message, true);
  }
}
$("guarded-example").addEventListener("click", () => guardedExample());
$("guarded-projection-example").addEventListener("click", () =>
  guardedExample("projection-replace.ndjson"),
);
$("guarded-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  cancelOtherGuardedPreparations("legacy");
  const current = ++guardedRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器门控分析输入文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== guardedRevision) return;
    await runGuarded(text, current);
  } catch (error) {
    if (current === guardedRevision) guardedMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("guarded-checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  cancelOtherGuardedPreparations("legacy");
  const current = ++guardedRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器门控分析检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== guardedRevision) return;
    const { report } = requestGuarded('{"resume":' + text + "}", "");
    const nextInput = JSON.stringify({ resume: report.checkpoint }) + "\n";
    if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
      throw new Error("恢复起点超过浏览器 8 MiB 输入上限，请使用原生命令。");
    if (current !== guardedRevision) return;
    clearGuardedResult();
    guardedInput.value = nextInput;
    guardedMessage(
      `已载入完整门控检查点（末帧 ${report.checkpoint.health.state.last_timestamp_us ?? "尚无观测"} μs）。添加更晚的联合观测或标定切换操作后继续。`,
    );
  } catch (error) {
    if (current === guardedRevision) guardedMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});

function transitMessage(text, error = false) {
  $("transit-message").textContent = text;
  $("transit-message").classList.toggle("error", error);
}

function refreshTransitSources() {
  $("transit-ordinary").disabled =
    !results.length || source.value !== loadedSource;
  $("transit-guarded").disabled =
    !guardedReport?.frames.length || guardedInput.value !== guardedLoadedSource;
}

function clearTransitResult() {
  transitRevision++;
  transitReport = null;
  transitResponse = null;
  transitOrigin = null;
  transitSourceReference = null;
  transitLoadedConfiguration = "";
  $("download-transit").disabled = true;
  $("save-transit-checkpoint").disabled = true;
  $("transit-source").textContent = "尚未选择测量来源";
  $("transit-counts").replaceChildren();
  $("transit-passages").replaceChildren();
  $("transit-cancellations").replaceChildren();
  $("transit-pending").textContent = "—";
}

function invalidateTransitSource(origin) {
  if (transitOrigin === origin) {
    clearTransitResult();
    transitMessage("所选来源的测量结果已更新，请重新统计区间通行。");
  } else if (transitPendingOrigin === origin) transitRevision++;
  refreshTransitSources();
  refreshEvidenceSources();
}

function measurementReference(origin) {
  return origin === "ordinary" ? measurementLines : guardedReport;
}

function measurementSourceCurrent(origin, reference) {
  return (
    measurementReference(origin) === reference &&
    (origin === "ordinary"
      ? results.length > 0 && source.value === loadedSource
      : !!guardedReport?.frames.length &&
        guardedInput.value === guardedLoadedSource)
  );
}

function renderTransit(changedOrigin = transitOrigin) {
  if (!transitReport || changedOrigin !== transitOrigin) return;
  if (!measurementSourceCurrent(transitOrigin, transitSourceReference)) {
    clearTransitResult();
    return;
  }
  const index = Number(
    $(transitOrigin === "ordinary" ? "frame" : "guarded-frame").value,
  );
  const frame = transitReport.frames[index];
  if (!frame) return;
  const label = transitOrigin === "ordinary" ? "普通测量" : "健康门控测量";
  $("transit-source").textContent =
    `${label} · ${index + 1} / ${transitReport.frames.length} · ${frame.counting.timestamp_us} μs`;
  renderTransitRows(frame, "transit");
}

function renderTransitRows(frame, prefix) {
  $(`${prefix}-pending`).textContent = String(frame.pending_count);
  $(`${prefix}-counts`).replaceChildren(
    ...frame.counts.map((count) => {
      const row = document.createElement("tr");
      for (const value of [count.section_id, count.completed]) {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.append(cell);
      }
      return row;
    }),
  );
  const bracket = (event) =>
    `[${event.from_timestamp_us}, ${event.to_timestamp_us}]`;
  const rows = frame.passages.map((passage) => {
    const row = document.createElement("tr");
    for (const value of [
      passage.section_id,
      `${passage.track_id} / ${passage.segment_id}`,
      bracket(passage.entry),
      bracket(passage.exit),
      `[${passage.elapsed_lower_us}, ${passage.elapsed_upper_us}]`,
      passage.estimated_elapsed_us.toFixed(3),
    ]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    return row;
  });
  if (!rows.length) {
    const row = document.createElement("tr"),
      cell = document.createElement("td");
    cell.colSpan = 6;
    cell.textContent = "本帧无完成通行。";
    row.append(cell);
    rows.push(row);
  }
  $(`${prefix}-passages`).replaceChildren(...rows);
  const reasons = {
    discontinuity: "观测中断或片段变化",
    expired: "入口确认期限到达",
    reentered: "重复入口",
    reversed: "反向通过",
    ambiguous_order: "过线先后不明确",
  };
  $(`${prefix}-cancellations`).replaceChildren(
    ...frame.cancellations.map((cancellation) => {
      const item = document.createElement("li");
      item.textContent = `${cancellation.section_id} · 目标 ${cancellation.track_id} / 片段 ${cancellation.segment_id} · ${reasons[cancellation.reason] ?? cancellation.reason}`;
      return item;
    }),
  );
}

function requestTransit(configuration, measurements) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(configuration).length + encoder.encode(measurements).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器区间统计输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: configuration, measurements });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("区间统计请求超过 16 Mi 字符上限。");
  const response = moonground_transit(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器区间统计结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

async function runTransit(origin) {
  const reference = measurementReference(origin);
  if (!measurementSourceCurrent(origin, reference)) return;
  const current = ++transitRevision,
    runToken = ++transitRunToken,
    configuration = transitInput.value;
  transitPendingOrigin = origin;
  transitMessage("正在配对同目标、同片段的入口与出口…");
  try {
    // Upstream outputs have already passed MoonBit validation; exact timestamps
    // and segment IDs are strings. The user-provided configuration stays raw.
    const lines =
      origin === "ordinary"
        ? reference
        : reference.frames.map((frame) =>
            JSON.stringify(frame.analysis.measurement),
          );
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== transitRevision ||
      !measurementSourceCurrent(origin, reference)
    )
      return;
    const { response, report } = requestTransit(
      configuration,
      lines.join("\n") + "\n",
    );
    if (
      current !== transitRevision ||
      !measurementSourceCurrent(origin, reference)
    )
      return;
    transitReport = report;
    transitResponse = response;
    transitOrigin = origin;
    transitSourceReference = reference;
    transitLoadedConfiguration = configuration;
    $("download-transit").disabled = false;
    $("save-transit-checkpoint").disabled = false;
    const completed = report.frames.reduce(
      (total, frame) => total + frame.passages.length,
      0,
    );
    transitMessage(
      `已处理 ${report.frames.length} 帧，完成 ${completed} 次区间通行。下方随所选来源的回放滑块显示本帧结果。`,
    );
    renderTransit();
  } catch (error) {
    if (current === transitRevision) transitMessage(error.message, true);
  } finally {
    if (runToken === transitRunToken) transitPendingOrigin = null;
  }
}

transitInput.addEventListener("input", () => {
  transitEdited = true;
  clearTransitResult();
  transitMessage("区间配置已修改，请选择测量来源重新统计。");
});
$("transit-ordinary").addEventListener("click", () => runTransit("ordinary"));
$("transit-guarded").addEventListener("click", () => runTransit("guarded"));
$("download-transit").addEventListener("click", () => {
  if (
    !transitReport ||
    transitInput.value !== transitLoadedConfiguration ||
    !measurementSourceCurrent(transitOrigin, transitSourceReference)
  )
    return;
  saveFile(transitResponse + "\n", "moonground-transit-results.json");
});
$("save-transit-checkpoint").addEventListener("click", () => {
  if (
    !transitReport ||
    transitInput.value !== transitLoadedConfiguration ||
    !measurementSourceCurrent(transitOrigin, transitSourceReference)
  )
    return;
  saveFile(
    JSON.stringify(transitReport.checkpoint) + "\n",
    "moonground-transit-checkpoint.json",
  );
  transitMessage(
    `已保存整批末帧 ${transitReport.checkpoint.counting.state.last_timestamp_us} μs 的区间统计检查点。它不包含上游测量状态。`,
  );
});
$("transit-checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const current = ++transitRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器区间检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== transitRevision) return;
    const { report } = requestTransit('{"resume":' + text + "}", "");
    const nextInput = JSON.stringify({ resume: report.checkpoint });
    if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
      throw new Error("区间恢复起点超过浏览器 8 MiB 输入上限。");
    if (current !== transitRevision) return;
    clearTransitResult();
    transitEdited = true;
    transitInput.value = nextInput;
    transitMessage(
      `已载入区间检查点（末帧 ${report.checkpoint.counting.state.last_timestamp_us ?? "尚无观测"} μs）。先将上游恢复至同一水位，再选择更晚的测量结果。`,
    );
  } catch (error) {
    if (current === transitRevision) transitMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
const initialTransitRevision = transitRevision;
fetch("./transit.json")
  .then((response) => {
    if (!response.ok) throw new Error("区间示例读取失败。");
    return response.text();
  })
  .then((text) => {
    if (
      !transitEdited &&
      transitRevision === initialTransitRevision &&
      transitInput.value === ""
    )
      transitInput.value = text;
  })
  .catch((error) => {
    if (!transitEdited && transitRevision === initialTransitRevision)
      transitMessage(error.message, true);
  });

function reportRow(values) {
  const row = document.createElement("tr");
  for (const value of values) {
    const cell = document.createElement("td");
    cell.textContent = value;
    row.append(cell);
  }
  return row;
}
function reportNumber(value) {
  return value === 0 ? "0" : value.toPrecision(6);
}
function evidenceRows(items) {
  const sides = {
    positive: "正侧已确认",
    negative: "负侧已确认",
    unconfirmed: "侧别未确认",
  };
  const rows = items.map((item) =>
    reportRow([
      item.gate_id,
      `${item.track_id} / ${item.segment_id}`,
      reportNumber(item.distance_m),
      reportNumber(item.normal_std_m),
      `[${reportNumber(item.lower_m)}, ${reportNumber(item.upper_m)}]`,
      sides[item.side],
    ]),
  );
  if (!rows.length) {
    const empty = reportRow(["本帧无可用的法向侧别证据。"]);
    empty.firstChild.colSpan = 6;
    rows.push(empty);
  }
  return rows;
}
function measurementRows(measurement) {
  const rows = measurement.tracks.map((track) =>
    reportRow([
      `${track.track_id} / ${track.segment_id ?? "—"}`,
      states[track.status] ?? track.status,
      track.position_m?.map(reportNumber).join(", ") ?? "—",
      track.speed_mps == null ? "—" : reportNumber(track.speed_mps),
    ]),
  );
  if (!rows.length) {
    const empty = reportRow(["本帧无目标测量。"]);
    empty.firstChild.colSpan = 4;
    rows.push(empty);
  }
  return rows;
}

function evidenceMessage(text, error = false) {
  $("evidence-message").textContent = text;
  $("evidence-message").classList.toggle("error", error);
}

function refreshEvidenceSources() {
  $("evidence-ordinary").disabled =
    !results.length || source.value !== loadedSource;
  $("evidence-guarded").disabled =
    !guardedReport?.frames.length || guardedInput.value !== guardedLoadedSource;
}

function clearEvidenceJoint() {
  evidenceJointReport = null;
  evidenceJointResponse = null;
  evidenceJointHeader = null;
  evidenceJointSource = "";
  evidenceJointConfiguration = "";
  $("evidence-joint-playback").hidden = true;
  $("evidence-joint-measurement").hidden = true;
  $("evidence-joint-tracks").replaceChildren();
  $("evidence-joint-closed").textContent = "";
  $("download-evidence-analysis").disabled = true;
  $("save-evidence-analysis-checkpoint").disabled = true;
}

function evidenceJointIsCurrent() {
  return (
    evidenceOrigin === "joint" &&
    evidenceJointReport !== null &&
    source.value === evidenceJointSource &&
    evidenceInput.value === evidenceJointConfiguration
  );
}

function clearEvidenceResult() {
  clearEvidenceJoint();
  evidenceRevision++;
  evidenceReport = null;
  evidenceResponse = null;
  evidenceOrigin = null;
  evidenceSourceReference = null;
  evidenceLoadedConfiguration = "";
  $("download-evidence").disabled = true;
  $("save-evidence-checkpoint").disabled = true;
  $("evidence-source").textContent = "尚未选择测量来源";
  $("evidence-policy").textContent = "";
  $("evidence-rows").replaceChildren();
  $("evidence-counts").replaceChildren();
  $("evidence-events").replaceChildren();
  $("evidence-summary").textContent = "法向协方差证据";
}

function invalidateEvidenceSource(origin) {
  if (
    evidenceOrigin === origin ||
    (origin === "ordinary" && evidenceOrigin === "joint")
  ) {
    clearEvidenceResult();
    evidenceMessage("所选来源的测量结果已更新，请重新按法向证据统计。");
  } else if (
    evidencePendingOrigin === origin ||
    (origin === "ordinary" && evidencePendingOrigin === "joint")
  )
    evidenceRevision++;
  refreshEvidenceSources();
}

function renderEvidence(changedOrigin = evidenceOrigin) {
  if (!evidenceReport || changedOrigin !== evidenceOrigin) return;
  if (
    evidenceOrigin === "joint"
      ? !evidenceJointIsCurrent()
      : !measurementSourceCurrent(evidenceOrigin, evidenceSourceReference)
  ) {
    clearEvidenceResult();
    return;
  }
  const index = Number(
    $(
      evidenceOrigin === "joint"
        ? "evidence-joint-frame"
        : evidenceOrigin === "ordinary"
          ? "frame"
          : "guarded-frame",
    ).value,
  );
  const frame = evidenceReport.frames[index];
  if (!frame) return;
  const unconfirmed = frame.evidence.filter(
    (item) => item.side === "unconfirmed",
  ).length;
  $("evidence-summary").textContent =
    `法向协方差证据 · 本帧 ${frame.evidence.length} 项，${unconfirmed} 项侧别未确认`;
  $("evidence-source").textContent =
    `${evidenceOrigin === "joint" ? "原始观测联合计算" : evidenceOrigin === "ordinary" ? "普通测量" : "健康门控测量"} · ${index + 1} / ${evidenceReport.frames.length} · ${frame.counting.timestamp_us} μs`;
  if (evidenceOrigin === "joint")
    $("evidence-joint-counter").textContent =
      `${index + 1} / ${evidenceReport.frames.length}`;
  $("evidence-policy").textContent =
    `k = ${frame.sigma_multiplier}；按法向带判断侧别，有限通道交点仍取滤波均值连线。`;
  $("evidence-rows").replaceChildren();
  $("evidence-counts").replaceChildren();
  $("evidence-events").replaceChildren();
  $("evidence-joint-tracks").replaceChildren();
  // Avoid building a potentially large hidden table while another source's
  // playback advances. Only the current selected frame is rendered on open.
  if (!$("gate-evidence-section").open) return;
  const row = reportRow;
  if (evidenceOrigin === "joint") {
    const measurement = evidenceJointReport.frames[index].measurement;
    $("evidence-joint-closed").textContent =
      `关闭的测量片段：${measurement.closed_segment_ids.join("、") || "无"}。`;
    $("evidence-joint-tracks").replaceChildren(...measurementRows(measurement));
  }
  $("evidence-rows").replaceChildren(...evidenceRows(frame.evidence));
  $("evidence-counts").replaceChildren(
    ...frame.counting.counts.map((count) =>
      row([
        count.gate_id,
        count.negative_to_positive,
        count.positive_to_negative,
      ]),
    ),
  );
  $("evidence-events").replaceChildren(
    ...frame.counting.crossings.map((event) => {
      const item = document.createElement("li");
      item.textContent = `${event.gate_id} · 目标 ${event.track_id} / 片段 ${event.segment_id} · ${event.direction === "negative_to_positive" ? "负侧 → 正侧" : "正侧 → 负侧"} · 观测区间 [${event.from_timestamp_us}, ${event.to_timestamp_us}] μs`;
      return item;
    }),
  );
}

function requestEvidence(configuration, measurements) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(configuration).length + encoder.encode(measurements).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器法向证据输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: configuration, measurements });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("法向证据请求超过 16 Mi 字符上限。");
  const response = moonground_gate_evidence(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器法向证据结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

async function runEvidence(origin) {
  const reference = measurementReference(origin);
  if (!measurementSourceCurrent(origin, reference)) return;
  const current = ++evidenceRevision,
    runToken = ++evidenceRunToken,
    configuration = evidenceInput.value;
  evidencePendingOrigin = origin;
  evidenceMessage("正在按位置协方差的法向证据统计…");
  try {
    const lines =
      origin === "ordinary"
        ? reference
        : reference.frames.map((frame) =>
            JSON.stringify(frame.analysis.measurement),
          );
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== evidenceRevision ||
      !measurementSourceCurrent(origin, reference)
    )
      return;
    const { response, report } = requestEvidence(
      configuration,
      lines.join("\n") + "\n",
    );
    if (
      current !== evidenceRevision ||
      !measurementSourceCurrent(origin, reference)
    )
      return;
    clearEvidenceJoint();
    evidenceReport = report;
    evidenceResponse = response;
    evidenceOrigin = origin;
    evidenceSourceReference = reference;
    evidenceLoadedConfiguration = configuration;
    $("download-evidence").disabled = false;
    $("save-evidence-checkpoint").disabled = false;
    const crossings = report.frames.reduce(
      (total, frame) => total + frame.counting.crossings.length,
      0,
    );
    evidenceMessage(
      `已处理 ${report.frames.length} 帧，确认 ${crossings} 次过线。下表随所选来源的回放滑块显示；结果和状态独立保存。`,
    );
    renderEvidence();
  } catch (error) {
    if (current === evidenceRevision) evidenceMessage(error.message, true);
  } finally {
    if (runToken === evidenceRunToken) evidencePendingOrigin = null;
  }
}

evidenceInput.addEventListener("input", () => {
  evidenceEdited = true;
  clearEvidenceResult();
  evidenceMessage("法向证据配置已修改，请选择测量来源重新统计。");
});
$("gate-evidence-section").addEventListener("toggle", () => renderEvidence());
$("evidence-ordinary").addEventListener("click", () => runEvidence("ordinary"));
$("evidence-guarded").addEventListener("click", () => runEvidence("guarded"));
$("download-evidence").addEventListener("click", () => {
  if (
    !evidenceReport ||
    evidenceOrigin === "joint" ||
    evidenceInput.value !== evidenceLoadedConfiguration ||
    !measurementSourceCurrent(evidenceOrigin, evidenceSourceReference)
  )
    return;
  saveFile(evidenceResponse + "\n", "moonground-gate-evidence-results.json");
});
$("save-evidence-checkpoint").addEventListener("click", () => {
  if (
    !evidenceReport ||
    evidenceOrigin === "joint" ||
    evidenceInput.value !== evidenceLoadedConfiguration ||
    !measurementSourceCurrent(evidenceOrigin, evidenceSourceReference)
  )
    return;
  saveFile(
    JSON.stringify(evidenceReport.checkpoint) + "\n",
    "moonground-gate-evidence-checkpoint.json",
  );
  evidenceMessage(
    `已保存整批末帧 ${evidenceReport.checkpoint.state.last_timestamp_us} μs 的独立法向证据检查点。它不包含上游测量状态。`,
  );
});
$("evidence-checkpoint-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const current = ++evidenceRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器法向证据检查点文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== evidenceRevision) return;
    const { report } = requestEvidence('{"resume":' + text + "}", "");
    const nextInput = JSON.stringify({ resume: report.checkpoint });
    if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
      throw new Error("法向证据恢复起点超过浏览器 8 MiB 输入上限。");
    if (current !== evidenceRevision) return;
    clearEvidenceResult();
    evidenceEdited = true;
    evidenceInput.value = nextInput;
    evidenceMessage(
      `已载入独立法向证据检查点（末帧 ${report.checkpoint.state.last_timestamp_us ?? "尚无观测"} μs）。先将上游恢复至同一水位，再选择更晚的测量结果。`,
    );
  } catch (error) {
    if (current === evidenceRevision) evidenceMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});

function requestEvidenceAnalysis(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器联合证据输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("联合证据请求超过 16 Mi 字符上限。");
  const response = moonground_evidence_analysis(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器联合证据结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}

$("evidence-analyze").addEventListener("click", async () => {
  const current = ++evidenceRevision,
    runToken = ++evidenceRunToken,
    input = source.value,
    configuration = evidenceInput.value;
  evidencePendingOrigin = "joint";
  evidenceMessage("正在联合计算原始测量与法向证据…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入测量配置及 1—5000 帧观测。");
    // Preserve both complete raw source documents, including integer tokens.
    const header = JSON.stringify({
      measurement: lines[0],
      counting: configuration,
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== evidenceRevision ||
      input !== source.value ||
      configuration !== evidenceInput.value
    )
      return;
    const { response, report } = requestEvidenceAnalysis(
      header,
      lines.slice(1).join("\n") + "\n",
    );
    if (
      current !== evidenceRevision ||
      input !== source.value ||
      configuration !== evidenceInput.value
    )
      return;
    evidenceJointReport = report;
    evidenceJointResponse = response;
    evidenceJointHeader = header;
    evidenceJointSource = input;
    evidenceJointConfiguration = configuration;
    evidenceReport = { frames: report.frames.map((frame) => frame.counting) };
    evidenceResponse = null;
    evidenceOrigin = "joint";
    evidenceSourceReference = report;
    evidenceLoadedConfiguration = configuration;
    $("evidence-joint-frame").max = String(report.frames.length - 1);
    $("evidence-joint-frame").value = String(report.frames.length - 1);
    $("evidence-joint-playback").hidden = false;
    $("evidence-joint-measurement").hidden = false;
    $("download-evidence").disabled = true;
    $("save-evidence-checkpoint").disabled = true;
    $("download-evidence-analysis").disabled = false;
    $("save-evidence-analysis-checkpoint").disabled =
      evidenceJointCheckpointBusy;
    evidenceMessage(
      `已联合计算 ${report.frames.length} 帧。测量与法向证据在同一帧提交；上方普通测量与其他统计结果保持。`,
    );
    renderEvidence();
  } catch (error) {
    if (current === evidenceRevision) evidenceMessage(error.message, true);
  } finally {
    if (runToken === evidenceRunToken) evidencePendingOrigin = null;
  }
});
$("evidence-joint-frame").addEventListener("input", () => renderEvidence());
$("download-evidence-analysis").addEventListener("click", () => {
  if (!evidenceJointIsCurrent()) return;
  saveFile(
    evidenceJointResponse + "\n",
    "moonground-evidence-analysis-results.json",
  );
});
$("save-evidence-analysis-checkpoint").addEventListener("click", async () => {
  if (evidenceJointCheckpointBusy || !evidenceJointIsCurrent()) return;
  const current = evidenceRevision,
    selected = $("evidence-joint-frame").value;
  const header = evidenceJointHeader,
    input = evidenceJointSource;
  evidenceJointCheckpointBusy = true;
  $("save-evidence-analysis-checkpoint").disabled = true;
  try {
    const prefix =
      observationLines(input)
        .slice(1, Number(selected) + 2)
        .join("\n") + "\n";
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== evidenceRevision || !evidenceJointIsCurrent()) return;
    const { report } = requestEvidenceAnalysis(header, prefix);
    if (
      current !== evidenceRevision ||
      !evidenceJointIsCurrent() ||
      selected !== $("evidence-joint-frame").value
    )
      return;
    saveFile(
      JSON.stringify(report.checkpoint) + "\n",
      "moonground-evidence-analysis-checkpoint.json",
    );
    evidenceMessage(
      `已保存所选第 ${Number(selected) + 1} 帧的完整联合证据检查点，测量与证据时间均为 ${report.checkpoint.counting.state.last_timestamp_us} μs。`,
    );
  } catch (error) {
    if (current === evidenceRevision) evidenceMessage(error.message, true);
  } finally {
    evidenceJointCheckpointBusy = false;
    $("save-evidence-analysis-checkpoint").disabled = !evidenceJointIsCurrent();
  }
});
$("evidence-analysis-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    const current = ++evidenceRevision,
      runToken = ++evidenceRunToken;
    evidencePendingOrigin = "joint";
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器完整联合证据检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== evidenceRevision) return;
      const { report } = requestEvidenceAnalysis('{"resume":' + text + "}", "");
      const checkpoint = report.checkpoint;
      const measurement = JSON.stringify({ resume: checkpoint.measurement });
      const counting = JSON.stringify({ resume: checkpoint.counting }, null, 2);
      // Only canonical components returned after complete core validation may be
      // placed in the two existing source inputs. Recheck the bounded envelope.
      requestEvidenceAnalysis(JSON.stringify({ measurement, counting }), "");
      if (current !== evidenceRevision) return;
      invalidate();
      clearEvidenceResult();
      source.value = measurement + "\n";
      evidenceInput.value = counting;
      evidenceEdited = true;
      configuration = checkpoint.measurement.configuration;
      draw();
      evidenceMessage(
        `已载入完整联合证据检查点，两侧共同恢复至 ${checkpoint.counting.state.last_timestamp_us ?? "尚无观测"} μs。添加更晚观测后点击“测量并按法向证据统计”继续。`,
      );
    } catch (error) {
      if (current === evidenceRevision) evidenceMessage(error.message, true);
    } finally {
      if (runToken === evidenceRunToken) evidencePendingOrigin = null;
      event.target.value = "";
    }
  },
);

const initialEvidenceRevision = evidenceRevision;
fetch("./gate-evidence.json")
  .then((response) => {
    if (!response.ok) throw new Error("法向证据示例读取失败。");
    return response.text();
  })
  .then((text) => {
    if (
      !evidenceEdited &&
      evidenceRevision === initialEvidenceRevision &&
      evidenceInput.value === ""
    )
      evidenceInput.value = text;
  })
  .catch((error) => {
    if (!evidenceEdited && evidenceRevision === initialEvidenceRevision)
      evidenceMessage(error.message, true);
  });

function evidenceGuardedMessage(text, error = false) {
  $("evidence-guarded-message").textContent = text;
  $("evidence-guarded-message").classList.toggle("error", error);
}
function evidenceGuardedIsCurrent() {
  return (
    evidenceGuardedReport !== null &&
    guardedInput.value === evidenceGuardedLoadedSource
  );
}
function clearEvidenceGuardedResult() {
  evidenceGuardedRevision++;
  evidenceGuardedReport = null;
  evidenceGuardedResponse = null;
  evidenceGuardedLoadedSource = "";
  invalidateEvidenceTransitSource("evidence-guarded");
  $("evidence-guarded-frame").disabled = true;
  $("evidence-guarded-counter").textContent = "0 / 0";
  evidenceGuardedMessage("共享输入已更新，请使用证据过线入口重新运行。");
  renderEvidenceGuarded();
}
function evidenceGuardedProjectionReplaced(frame) {
  return (
    frame.kind === "evidence_guarded_projection_replaced" ||
    frame.kind === "evidence_guarded_transit_projection_replaced"
  );
}
function evidenceGuardedView() {
  const transit = evidenceGuardedMode === "transit";
  return {
    transit,
    report: transit ? evidenceGuardedTransitReport : evidenceGuardedReport,
    current: transit
      ? evidenceGuardedTransitIsCurrent()
      : evidenceGuardedIsCurrent(),
    slider: $(
      transit ? "evidence-guarded-transit-frame" : "evidence-guarded-frame",
    ),
    counter: $(
      transit ? "evidence-guarded-transit-counter" : "evidence-guarded-counter",
    ),
  };
}
function refreshEvidenceGuardedExports() {
  const gates = evidenceGuardedMode === "gates" && evidenceGuardedIsCurrent();
  const transit =
    evidenceGuardedMode === "transit" && evidenceGuardedTransitIsCurrent();
  $("download-evidence-guarded").disabled = !gates;
  $("save-evidence-guarded-checkpoint").disabled =
    !gates || evidenceGuardedCheckpointBusy;
  $("download-evidence-guarded-transit").disabled = !transit;
  $("save-evidence-guarded-transit-checkpoint").disabled =
    !transit || evidenceGuardedTransitCheckpointBusy;
}
function drawEvidenceGuardedTimeline() {
  const canvas = $("evidence-guarded-timeline"),
    drawing = canvas.getContext("2d"),
    view = evidenceGuardedView();
  drawing.fillStyle = "#eef3e9";
  drawing.fillRect(0, 0, canvas.width, canvas.height);
  if (!view.current || !view.report?.frames.length) return;
  const width = canvas.width / view.report.frames.length;
  view.report.frames.forEach((frame, index) => {
    drawing.fillStyle = healthColors[frame.health.status];
    drawing.fillRect(index * width, 0, Math.max(width, 1), 36);
    drawing.fillStyle = frame.decision === "allowed" ? "#24674d" : "#a56c61";
    drawing.fillRect(index * width, 40, Math.max(width, 1), 16);
    if (evidenceGuardedProjectionReplaced(frame)) {
      drawing.fillStyle = "#72509c";
      drawing.fillRect((index + 0.5) * width - 1.5, 0, 3, canvas.height);
    }
  });
  drawing.strokeStyle = "#20342f";
  drawing.lineWidth = 3;
  drawing.strokeRect(
    Number(view.slider.value) * width + 1.5,
    1.5,
    Math.max(width - 3, 1),
    canvas.height - 3,
  );
}
function renderEvidenceGuarded() {
  refreshTransitWindowsSources();
  renderTransitWindows();
  refreshEvidenceGuardedExports();
  const view = evidenceGuardedView();
  $("evidence-guarded-mode").value = evidenceGuardedMode;
  $("evidence-guarded-gate-playback").hidden = view.transit;
  $("evidence-guarded-transit-playback").hidden = !view.transit;
  $("evidence-guarded-transit-results").hidden = !view.transit;
  for (const id of [
    "evidence-guarded-tracks",
    "evidence-guarded-counts",
    "evidence-guarded-rows",
    "evidence-guarded-events",
    "evidence-guarded-transit-counts",
    "evidence-guarded-transit-passages",
    "evidence-guarded-transit-cancellations",
  ])
    $(id).replaceChildren();
  drawEvidenceGuardedTimeline();
  if (!view.current || !view.report?.frames.length) {
    for (const id of [
      "evidence-guarded-status",
      "evidence-guarded-policy",
      "evidence-guarded-closed",
    ])
      $(id).textContent = "";
    view.counter.textContent = "0 / 0";
    $("evidence-guarded-transit-pending").textContent = "—";
    return;
  }
  const index = Number(view.slider.value),
    frame = view.report.frames[index];
  if (!frame) return;
  const transit = view.transit ? frame.analysis.transit : null,
    evidence = transit ? transit.counting : frame.analysis.counting,
    measurement = frame.analysis.measurement,
    replaced = evidenceGuardedProjectionReplaced(frame);
  const replacements = view.report.frames
    .slice(0, index + 1)
    .filter(evidenceGuardedProjectionReplaced).length;
  view.counter.textContent =
    String(index + 1) + " / " + view.report.frames.length;
  $("evidence-guarded-status").textContent =
    frame.health.timestamp_us +
    " μs · " +
    (view.transit ? "证据通行" : "证据过线") +
    " · " +
    (replaced
      ? "切换标定"
      : frame.decision === "allowed"
        ? "已放行"
        : "已阻断") +
    " · " +
    healthStates[frame.health.status] +
    " · 可用地标 " +
    frame.health.usable_count +
    "/" +
    frame.health.landmarks.length +
    " · RMS " +
    (frame.health.rms_error_m == null
      ? "—"
      : reportNumber(frame.health.rms_error_m) + " m");
  $("evidence-guarded-policy").textContent =
    "k = " +
    evidence.sigma_multiplier +
    "；本次回放至此 " +
    replacements +
    " 次标定切换。" +
    (replaced
      ? "本帧关闭旧片段与证据参考点；后续地标重新确认，目标从新片段预热。"
      : frame.decision === "blocked"
        ? "本帧未处理目标，证据参考点已中断，累计计数保留。"
        : "地标健康已确认，测量与法向证据共同提交。") +
    (view.transit ? "待入口在观测中断时取消；通行时长保留原始观测区间。" : "");
  $("evidence-guarded-closed").textContent =
    "被抑制目标：" +
    (frame.suppressed_track_ids.join("、") || "无") +
    "；关闭的测量片段：" +
    (measurement.closed_segment_ids.join("、") || "无") +
    "。";
  if (transit)
    $("evidence-guarded-transit-pending").textContent = String(
      transit.pending_count,
    );
  if (!view.transit) renderEvidenceTransit("evidence-guarded");
  if (!$("evidence-guarded-section").open) return;
  $("evidence-guarded-tracks").replaceChildren(...measurementRows(measurement));
  $("evidence-guarded-rows").replaceChildren(
    ...evidenceRows(evidence.evidence),
  );
  $("evidence-guarded-counts").replaceChildren(
    ...evidence.counting.counts.map((count) =>
      reportRow([
        count.gate_id,
        count.negative_to_positive,
        count.positive_to_negative,
      ]),
    ),
  );
  $("evidence-guarded-events").replaceChildren(
    ...evidence.counting.crossings.map((event) => {
      const item = document.createElement("li");
      item.textContent =
        event.gate_id +
        " · 目标 " +
        event.track_id +
        " / 片段 " +
        event.segment_id +
        " · " +
        (event.direction === "negative_to_positive"
          ? "负侧 → 正侧"
          : "正侧 → 负侧") +
        " · 观测区间 [" +
        event.from_timestamp_us +
        ", " +
        event.to_timestamp_us +
        "] μs";
      return item;
    }),
  );
  if (transit) renderTransitRows(transit, "evidence-guarded-transit");
}

function requestEvidenceGuarded(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器三方证据输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("三方证据请求超过 16 Mi 字符上限。");
  const response = moonground_evidence_guarded(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器三方证据结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}
async function runEvidenceGuarded(
  input = guardedInput.value,
  current = ++evidenceGuardedRevision,
) {
  if (current !== evidenceGuardedRevision) return;
  cancelOtherGuardedPreparations("gates");
  const runToken = ++evidenceGuardedRunToken;
  $("run-evidence-guarded").disabled = true;
  evidenceGuardedMessage("正在联合检查健康、测量目标与统计法向证据…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入三方证据配置及 1—5000 行配对观测或标定切换操作。");
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== evidenceGuardedRevision) return;
    const { response, report } = requestEvidenceGuarded(
      lines[0],
      lines.slice(1).join("\n") + "\n",
    );
    if (current !== evidenceGuardedRevision) return;
    if (guardedInput.value !== input) clearGuardedResult();
    guardedInput.value = input;
    invalidateEvidenceTransitSource("evidence-guarded");
    evidenceGuardedLoadedSource = input;
    evidenceGuardedReport = report;
    evidenceGuardedResponse = response;
    refreshEvidenceTransitSources();
    $("evidence-guarded-frame").max = String(report.frames.length - 1);
    $("evidence-guarded-frame").value = String(report.frames.length - 1);
    $("evidence-guarded-frame").disabled = false;
    evidenceGuardedMode = "gates";
    evidenceGuardedMessage(
      `已完成 ${report.frames.length} 帧三方证据分析。使用本区独立回放与完整检查点；其他结果槽保持。`,
    );
    renderEvidenceGuarded();
  } catch (error) {
    if (current === evidenceGuardedRevision)
      evidenceGuardedMessage(error.message, true);
  } finally {
    if (runToken === evidenceGuardedRunToken)
      $("run-evidence-guarded").disabled = false;
  }
}
$("run-evidence-guarded").addEventListener("click", () => runEvidenceGuarded());
$("evidence-guarded-frame").addEventListener("input", renderEvidenceGuarded);
$("evidence-guarded-section").addEventListener("toggle", renderEvidenceGuarded);
$("evidence-guarded-example").addEventListener("click", async () => {
  cancelOtherGuardedPreparations("gates");
  const current = ++evidenceGuardedRevision;
  try {
    const response = await fetch("./evidence-guarded.ndjson");
    if (!response.ok) throw new Error("三方证据示例读取失败。");
    const text = await response.text();
    if (current !== evidenceGuardedRevision) return;
    await runEvidenceGuarded(text, current);
  } catch (error) {
    if (current === evidenceGuardedRevision)
      evidenceGuardedMessage(error.message, true);
  }
});
$("evidence-guarded-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  cancelOtherGuardedPreparations("gates");
  const current = ++evidenceGuardedRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器三方证据 NDJSON 文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== evidenceGuardedRevision) return;
    await runEvidenceGuarded(text, current);
  } catch (error) {
    if (current === evidenceGuardedRevision)
      evidenceGuardedMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("download-evidence-guarded").addEventListener("click", () => {
  if (evidenceGuardedMode === "gates" && evidenceGuardedIsCurrent())
    saveFile(
      evidenceGuardedResponse + "\n",
      "moonground-evidence-guarded-results.json",
    );
});
$("save-evidence-guarded-checkpoint").addEventListener("click", async () => {
  if (
    evidenceGuardedCheckpointBusy ||
    evidenceGuardedMode !== "gates" ||
    !evidenceGuardedIsCurrent()
  )
    return;
  const current = evidenceGuardedRevision,
    selected = $("evidence-guarded-frame").value,
    input = evidenceGuardedLoadedSource;
  evidenceGuardedCheckpointBusy = true;
  $("save-evidence-guarded-checkpoint").disabled = true;
  try {
    const lines = observationLines(input);
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== evidenceGuardedRevision || !evidenceGuardedIsCurrent())
      return;
    const { report } = requestEvidenceGuarded(
      lines[0],
      lines.slice(1, Number(selected) + 2).join("\n") + "\n",
    );
    if (
      current !== evidenceGuardedRevision ||
      !evidenceGuardedIsCurrent() ||
      selected !== $("evidence-guarded-frame").value
    )
      return;
    saveFile(
      JSON.stringify(report.checkpoint) + "\n",
      "moonground-evidence-guarded-checkpoint.json",
    );
    evidenceGuardedMessage(
      `已保存所选第 ${Number(selected) + 1} 帧的完整三方证据检查点，三侧水位均为 ${report.checkpoint.health.state.last_timestamp_us} μs。`,
    );
  } catch (error) {
    if (current === evidenceGuardedRevision)
      evidenceGuardedMessage(error.message, true);
  } finally {
    evidenceGuardedCheckpointBusy = false;
    refreshEvidenceGuardedExports();
  }
});
$("evidence-guarded-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    cancelOtherGuardedPreparations("gates");
    const current = ++evidenceGuardedRevision;
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器三方证据检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== evidenceGuardedRevision) return;
      const { report } = requestEvidenceGuarded('{"resume":' + text + "}", "");
      const nextInput = JSON.stringify({ resume: report.checkpoint }) + "\n";
      if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
        throw new Error("三方证据恢复起点超过浏览器 8 MiB 输入上限。");
      if (current !== evidenceGuardedRevision) return;
      clearGuardedResult();
      guardedInput.value = nextInput;
      evidenceGuardedMessage(
        `已载入完整三方证据检查点（${report.checkpoint.health.state.last_timestamp_us ?? "尚无观测"} μs）。在共享输入中添加更晚配对观测，使用本区三方入口继续。`,
      );
    } catch (error) {
      if (current === evidenceGuardedRevision)
        evidenceGuardedMessage(error.message, true);
    } finally {
      event.target.value = "";
    }
  },
);

function cancelOtherGuardedPreparations(owner) {
  if (owner !== "legacy") {
    guardedRevision++;
    if ($("run-guarded").disabled) guardedMessage("上一次门控分析准备已取消。");
  }
  if (owner !== "gates") {
    evidenceGuardedRevision++;
    if ($("run-evidence-guarded").disabled)
      evidenceGuardedMessage("上一次证据过线准备已取消。");
  }
  if (owner !== "transit") {
    evidenceGuardedTransitRevision++;
    if ($("run-evidence-guarded-transit").disabled)
      evidenceGuardedTransitMessage("上一次证据通行准备已取消。");
  }
}
function evidenceGuardedTransitMessage(text, error = false) {
  $("evidence-guarded-transit-message").textContent = text;
  $("evidence-guarded-transit-message").classList.toggle("error", error);
}
function evidenceGuardedTransitIsCurrent() {
  return (
    evidenceGuardedTransitReport !== null &&
    guardedInput.value === evidenceGuardedTransitLoadedSource
  );
}
function clearEvidenceGuardedTransitResult() {
  invalidateTransitWindowsSource("guarded");
  evidenceGuardedTransitRevision++;
  evidenceGuardedTransitReport = null;
  evidenceGuardedTransitResponse = null;
  evidenceGuardedTransitLoadedSource = "";
  $("evidence-guarded-transit-frame").disabled = true;
  $("evidence-guarded-transit-counter").textContent = "0 / 0";
  evidenceGuardedTransitMessage("共享输入已更新，请使用证据通行入口重新运行。");
  renderEvidenceGuarded();
}
function requestEvidenceGuardedTransit(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error(
      "浏览器健康证据通行输入上限为 8 MiB；更大的流请使用原生命令。",
    );
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("健康证据通行请求超过 16 Mi 字符上限。");
  const response = moonground_evidence_guarded_transit(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器健康证据通行结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}
async function runEvidenceGuardedTransit(
  input = guardedInput.value,
  current = ++evidenceGuardedTransitRevision,
) {
  if (current !== evidenceGuardedTransitRevision) return;
  cancelOtherGuardedPreparations("transit");
  const runToken = ++evidenceGuardedTransitRunToken;
  $("run-evidence-guarded-transit").disabled = true;
  evidenceGuardedTransitMessage(
    "正在联合检查地标健康、测量目标并统计证据区间通行…",
  );
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error(
        "请输入健康证据通行配置及 1—5000 行配对观测或标定切换操作。",
      );
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (current !== evidenceGuardedTransitRevision) return;
    const { response, report } = requestEvidenceGuardedTransit(
      lines[0],
      lines.slice(1).join("\n") + "\n",
    );
    if (current !== evidenceGuardedTransitRevision) return;
    if (guardedInput.value !== input) clearGuardedResult();
    guardedInput.value = input;
    invalidateTransitWindowsSource("guarded");
    evidenceGuardedTransitLoadedSource = input;
    evidenceGuardedTransitReport = report;
    evidenceGuardedTransitResponse = response;
    evidenceGuardedMode = "transit";
    $("evidence-guarded-transit-frame").max = String(report.frames.length - 1);
    $("evidence-guarded-transit-frame").value = String(
      report.frames.length - 1,
    );
    $("evidence-guarded-transit-frame").disabled = false;
    evidenceGuardedTransitMessage(
      "已完成 " +
        report.frames.length +
        " 帧健康证据通行。完整结果和所选帧检查点包含健康、测量与证据区间状态。",
    );
    renderEvidenceGuarded();
  } catch (error) {
    if (current === evidenceGuardedTransitRevision)
      evidenceGuardedTransitMessage(error.message, true);
  } finally {
    if (runToken === evidenceGuardedTransitRunToken)
      $("run-evidence-guarded-transit").disabled = false;
  }
}
$("evidence-guarded-mode").addEventListener("change", (event) => {
  cancelOtherGuardedPreparations(null);
  evidenceGuardedMode = event.target.value;
  renderEvidenceGuarded();
});
$("run-evidence-guarded-transit").addEventListener("click", () =>
  runEvidenceGuardedTransit(),
);
$("evidence-guarded-transit-frame").addEventListener(
  "input",
  renderEvidenceGuarded,
);
$("evidence-guarded-transit-example").addEventListener("click", async () => {
  cancelOtherGuardedPreparations("transit");
  const current = ++evidenceGuardedTransitRevision;
  try {
    const response = await fetch("./evidence-guarded-transit.ndjson");
    if (!response.ok) throw new Error("健康证据通行示例读取失败。");
    const text = await response.text();
    if (current !== evidenceGuardedTransitRevision) return;
    await runEvidenceGuardedTransit(text, current);
  } catch (error) {
    if (current === evidenceGuardedTransitRevision)
      evidenceGuardedTransitMessage(error.message, true);
  }
});
$("evidence-guarded-transit-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  cancelOtherGuardedPreparations("transit");
  const current = ++evidenceGuardedTransitRevision;
  try {
    if (file.size > 8 * 1024 * 1024)
      throw new Error("浏览器健康证据通行 NDJSON 文件上限为 8 MiB。");
    const text = await file.text();
    if (current !== evidenceGuardedTransitRevision) return;
    await runEvidenceGuardedTransit(text, current);
  } catch (error) {
    if (current === evidenceGuardedTransitRevision)
      evidenceGuardedTransitMessage(error.message, true);
  } finally {
    event.target.value = "";
  }
});
$("download-evidence-guarded-transit").addEventListener("click", () => {
  if (evidenceGuardedMode === "transit" && evidenceGuardedTransitIsCurrent())
    saveFile(
      evidenceGuardedTransitResponse + "\n",
      "moonground-evidence-guarded-transit-results.json",
    );
});
$("save-evidence-guarded-transit-checkpoint").addEventListener(
  "click",
  async () => {
    if (
      evidenceGuardedTransitCheckpointBusy ||
      evidenceGuardedMode !== "transit" ||
      !evidenceGuardedTransitIsCurrent()
    )
      return;
    const current = evidenceGuardedTransitRevision,
      selected = $("evidence-guarded-transit-frame").value,
      input = evidenceGuardedTransitLoadedSource;
    evidenceGuardedTransitCheckpointBusy = true;
    refreshEvidenceGuardedExports();
    try {
      const lines = observationLines(input);
      await new Promise((resolve) => setTimeout(resolve, 0));
      if (
        current !== evidenceGuardedTransitRevision ||
        !evidenceGuardedTransitIsCurrent()
      )
        return;
      const { report } = requestEvidenceGuardedTransit(
        lines[0],
        lines.slice(1, Number(selected) + 2).join("\n") + "\n",
      );
      if (
        current !== evidenceGuardedTransitRevision ||
        evidenceGuardedMode !== "transit" ||
        !evidenceGuardedTransitIsCurrent() ||
        selected !== $("evidence-guarded-transit-frame").value
      )
        return;
      saveFile(
        JSON.stringify(report.checkpoint) + "\n",
        "moonground-evidence-guarded-transit-checkpoint.json",
      );
      evidenceGuardedTransitMessage(
        "已保存所选第 " +
          (Number(selected) + 1) +
          " 帧的完整健康证据通行检查点，共同水位 " +
          report.checkpoint.health.state.last_timestamp_us +
          " μs。",
      );
    } catch (error) {
      if (current === evidenceGuardedTransitRevision)
        evidenceGuardedTransitMessage(error.message, true);
    } finally {
      evidenceGuardedTransitCheckpointBusy = false;
      refreshEvidenceGuardedExports();
    }
  },
);
$("evidence-guarded-transit-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    cancelOtherGuardedPreparations("transit");
    const current = ++evidenceGuardedTransitRevision,
      runToken = ++evidenceGuardedTransitRunToken;
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器完整健康证据通行检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== evidenceGuardedTransitRevision) return;
      const { report } = requestEvidenceGuardedTransit(
        '{"resume":' + text + "}",
        "",
      );
      const nextInput = JSON.stringify({ resume: report.checkpoint }) + "\n";
      if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
        throw new Error("健康证据通行恢复起点超过浏览器 8 MiB 输入上限。");
      if (current !== evidenceGuardedTransitRevision) return;
      clearGuardedResult();
      guardedInput.value = nextInput;
      evidenceGuardedTransitMessage(
        "已载入完整健康证据通行检查点（" +
          (report.checkpoint.health.state.last_timestamp_us ?? "尚无观测") +
          " μs）。添加更晚配对观测后使用证据通行入口继续。",
      );
    } catch (error) {
      if (current === evidenceGuardedTransitRevision)
        evidenceGuardedTransitMessage(error.message, true);
    } finally {
      if (runToken === evidenceGuardedTransitRunToken)
        $("run-evidence-guarded-transit").disabled = false;
      event.target.value = "";
    }
  },
);

function evidenceTransitMessage(text, error = false) {
  $("evidence-transit-message").textContent = "独立下游：" + text;
  $("evidence-transit-message").classList.toggle("error", error);
}
function evidenceTransitSource(origin) {
  switch (origin) {
    case "ordinary":
      return measurementLines;
    case "evidence-guarded":
      return evidenceGuardedReport;
    default:
      return null;
  }
}
function evidenceTransitSourceCurrent(origin, reference) {
  if (reference === null || evidenceTransitSource(origin) !== reference)
    return false;
  switch (origin) {
    case "ordinary":
      return results.length > 0 && source.value === loadedSource;
    case "evidence-guarded":
      return evidenceGuardedIsCurrent() && reference.frames.length > 0;
    default:
      return false;
  }
}
function refreshEvidenceTransitSources() {
  $("evidence-transit-ordinary").disabled = !evidenceTransitSourceCurrent(
    "ordinary",
    measurementLines,
  );
  $("evidence-transit-guarded").disabled = !evidenceTransitSourceCurrent(
    "evidence-guarded",
    evidenceGuardedReport,
  );
}
function clearEvidenceTransitResult(cancelPending = true) {
  invalidateTransitWindowsSource("independent");
  if (cancelPending) {
    evidenceTransitRevision++;
    evidenceTransitPendingOrigin = null;
  }
  evidenceTransitReport = null;
  evidenceTransitResponse = null;
  evidenceTransitOrigin = null;
  evidenceTransitReference = null;
  evidenceTransitConfiguration = "";
  renderEvidenceTransit();
}
function invalidateEvidenceTransitSource(origin) {
  if (evidenceTransitOrigin === origin) {
    // An older displayed source can disappear while the user is preparing a
    // different source. Clear that display without cancelling the newer choice.
    clearEvidenceTransitResult(
      evidenceTransitPendingOrigin === null ||
        evidenceTransitPendingOrigin === origin,
    );
    evidenceTransitMessage(
      "所选来源的测量结果已更新，请重新统计证据区间通行。",
    );
  } else if (evidenceTransitPendingOrigin === origin) {
    evidenceTransitRevision++;
    evidenceTransitPendingOrigin = null;
    evidenceTransitMessage("待处理来源已修改，本次证据区间统计已取消。");
  }
  refreshEvidenceTransitSources();
}
function evidenceTransitIsCurrent() {
  return (
    evidenceTransitReport !== null &&
    evidenceTransitInput.value === evidenceTransitConfiguration &&
    evidenceTransitSourceCurrent(
      evidenceTransitOrigin,
      evidenceTransitReference,
    )
  );
}
function refreshEvidenceTransitExports() {
  const independent =
    evidenceTransitMode === "independent" && evidenceTransitIsCurrent();
  const joint =
    evidenceTransitMode === "joint" && evidenceTransitJointIsCurrent();
  $("download-evidence-transit").disabled = !independent;
  $("save-evidence-transit-checkpoint").disabled = !independent;
  $("download-evidence-transit-analysis").disabled = !joint;
  $("save-evidence-transit-analysis-checkpoint").disabled =
    !joint || evidenceTransitJointCheckpointBusy;
}
function renderEvidenceTransit(changedOrigin = evidenceTransitOrigin) {
  refreshTransitWindowsSources();
  renderTransitWindows();
  refreshEvidenceTransitExports();
  const joint = evidenceTransitMode === "joint";
  $("evidence-transit-mode").value = evidenceTransitMode;
  $("evidence-transit-joint-playback").hidden = !joint;
  $("evidence-transit-joint-measurement").hidden = !joint;
  const valid = joint
    ? evidenceTransitJointIsCurrent()
    : evidenceTransitIsCurrent();
  if (!valid) {
    $("evidence-transit-source").textContent = joint
      ? "原观测联合 · 尚无有效结果"
      : "尚未选择测量来源";
    $("evidence-transit-policy").textContent = "";
    $("evidence-transit-pending").textContent = "—";
    $("evidence-transit-joint-counter").textContent = "0 / 0";
    $("evidence-transit-joint-closed").textContent = "";
    for (const suffix of [
      "counts",
      "passages",
      "cancellations",
      "rows",
      "joint-tracks",
    ])
      $("evidence-transit-" + suffix).replaceChildren();
    return;
  }
  if (
    !joint &&
    changedOrigin !== null &&
    changedOrigin !== evidenceTransitOrigin
  )
    return;
  const index = Number(
    $(
      joint
        ? "evidence-transit-joint-frame"
        : evidenceTransitOrigin === "ordinary"
          ? "frame"
          : "evidence-guarded-frame",
    ).value,
  );
  const selected = joint ? evidenceTransitJointReport.frames[index] : null;
  const frame = joint ? selected?.transit : evidenceTransitReport.frames[index];
  if (!frame) return;
  const label = joint
    ? "原观测联合"
    : evidenceTransitOrigin === "ordinary"
      ? "普通测量"
      : "三方证据门控测量";
  const length = joint
    ? evidenceTransitJointReport.frames.length
    : evidenceTransitReport.frames.length;
  $("evidence-transit-source").textContent =
    `${label} · ${index + 1} / ${length} · ${frame.counting.counting.timestamp_us} μs`;
  $("evidence-transit-policy").textContent =
    `k = ${frame.counting.sigma_multiplier}；本帧 ${frame.counting.evidence.length} 项法向证据。侧别确认后配对均值弦过线；通行时长范围来自原始观测区间，不是概率置信区间。`;
  $("evidence-transit-pending").textContent = String(frame.pending_count);
  if (joint) {
    $("evidence-transit-joint-counter").textContent =
      `${index + 1} / ${length}`;
    $("evidence-transit-joint-closed").textContent =
      `关闭的测量片段：${selected.measurement.closed_segment_ids.join("、") || "无"}。`;
  }
  for (const suffix of [
    "counts",
    "passages",
    "cancellations",
    "rows",
    "joint-tracks",
  ])
    $("evidence-transit-" + suffix).replaceChildren();
  if (!$("evidence-transit-section").open) return;
  renderTransitRows(frame, "evidence-transit");
  $("evidence-transit-rows").replaceChildren(
    ...evidenceRows(frame.counting.evidence),
  );
  if (joint)
    $("evidence-transit-joint-tracks").replaceChildren(
      ...measurementRows(selected.measurement),
    );
}

function requestEvidenceTransit(configuration, measurements) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(configuration).length + encoder.encode(measurements).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器证据区间输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: configuration, measurements });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("证据区间请求超过 16 Mi 字符上限。");
  const response = moonground_evidence_transit(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器证据区间结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}
async function runEvidenceTransit(origin) {
  const reference = evidenceTransitSource(origin);
  if (!evidenceTransitSourceCurrent(origin, reference)) return;
  cancelEvidenceTransitJointPreparation();
  const current = ++evidenceTransitRevision,
    runToken = ++evidenceTransitRunToken,
    configuration = evidenceTransitInput.value;
  evidenceTransitPendingOrigin = origin;
  evidenceTransitMessage("正在按法向协方差证据确认过线并配对区间…");
  try {
    // Forward the entire original clock, including empty health-blocked and
    // replacement frames. Core validates strict continuation; never skip a
    // prefix merely because it predates a restored downstream watermark.
    const lines =
      origin === "ordinary"
        ? reference
        : reference.frames.map((frame) =>
            JSON.stringify(frame.analysis.measurement),
          );
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== evidenceTransitRevision ||
      configuration !== evidenceTransitInput.value ||
      !evidenceTransitSourceCurrent(origin, reference)
    )
      return;
    const { response, report } = requestEvidenceTransit(
      configuration,
      lines.join("\n") + "\n",
    );
    if (
      current !== evidenceTransitRevision ||
      configuration !== evidenceTransitInput.value ||
      !evidenceTransitSourceCurrent(origin, reference)
    )
      return;
    invalidateTransitWindowsSource("independent");
    evidenceTransitReport = report;
    evidenceTransitResponse = response;
    evidenceTransitOrigin = origin;
    evidenceTransitReference = reference;
    evidenceTransitConfiguration = configuration;
    evidenceTransitMode = "independent";
    const completed = report.frames.reduce(
      (total, frame) => total + frame.passages.length,
      0,
    );
    evidenceTransitMessage(
      `已处理 ${report.frames.length} 帧，完成 ${completed} 次证据区间通行。跟随所选来源的回放；下载包含整批结果和末帧独立检查点。`,
    );
    renderEvidenceTransit();
  } catch (error) {
    if (current === evidenceTransitRevision)
      evidenceTransitMessage(error.message, true);
  } finally {
    if (runToken === evidenceTransitRunToken)
      evidenceTransitPendingOrigin = null;
  }
}
evidenceTransitInput.addEventListener("input", () => {
  evidenceTransitEdited = true;
  clearEvidenceTransitJoint();
  clearEvidenceTransitResult();
  evidenceTransitMessage("证据区间配置已修改，请显式选择测量来源重新统计。");
});
$("evidence-transit-section").addEventListener("toggle", () =>
  renderEvidenceTransit(),
);
$("evidence-transit-ordinary").addEventListener("click", () =>
  runEvidenceTransit("ordinary"),
);
$("evidence-transit-guarded").addEventListener("click", () =>
  runEvidenceTransit("evidence-guarded"),
);
$("download-evidence-transit").addEventListener("click", () => {
  if (evidenceTransitMode === "independent" && evidenceTransitIsCurrent())
    saveFile(
      evidenceTransitResponse + "\n",
      "moonground-evidence-transit-results.json",
    );
});
$("save-evidence-transit-checkpoint").addEventListener("click", () => {
  if (evidenceTransitMode !== "independent" || !evidenceTransitIsCurrent())
    return;
  saveFile(
    JSON.stringify(evidenceTransitReport.checkpoint) + "\n",
    "moonground-evidence-transit-checkpoint.json",
  );
  evidenceTransitMessage(
    `已保存整批末帧 ${evidenceTransitReport.checkpoint.counting.state.last_timestamp_us} μs 的完整独立证据区间检查点。上游状态需在同一原始时钟另行保存。`,
  );
});
$("evidence-transit-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    cancelEvidenceTransitJointPreparation();
    const current = ++evidenceTransitRevision;
    evidenceTransitPendingOrigin = null;
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器证据区间检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== evidenceTransitRevision) return;
      const { report } = requestEvidenceTransit('{"resume":' + text + "}", "");
      const nextInput = JSON.stringify({ resume: report.checkpoint });
      if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
        throw new Error("证据区间恢复起点超过浏览器 8 MiB 输入上限。");
      if (current !== evidenceTransitRevision) return;
      clearEvidenceTransitJoint();
      clearEvidenceTransitResult();
      evidenceTransitEdited = true;
      evidenceTransitInput.value = nextInput;
      evidenceTransitMessage(
        `已载入完整独立证据区间检查点（末帧 ${report.checkpoint.counting.state.last_timestamp_us ?? "尚无观测"} μs）。将上游恢复至同一原始时钟水位，再选择仅含更晚帧的测量结果。`,
      );
    } catch (error) {
      if (current === evidenceTransitRevision)
        evidenceTransitMessage(error.message, true);
    } finally {
      event.target.value = "";
    }
  },
);
async function loadEvidenceTransitExample(explicit = false) {
  const current = explicit
    ? ++evidenceTransitRevision
    : evidenceTransitRevision;
  if (explicit) {
    cancelEvidenceTransitJointPreparation();
    evidenceTransitEdited = true;
    evidenceTransitPendingOrigin = null;
  }
  try {
    const response = await fetch("./evidence-transit-source.json");
    if (!response.ok) throw new Error("证据区间仓储配置读取失败。");
    const text = await response.text();
    if (
      current !== evidenceTransitRevision ||
      (!explicit &&
        (evidenceTransitEdited || evidenceTransitInput.value !== ""))
    )
      return;
    clearEvidenceTransitJoint();
    clearEvidenceTransitResult();
    evidenceTransitInput.value = text;
    evidenceTransitMessage(
      "已载入独立仓储证据区间配置。先生成仓储普通测量，再显式选择普通来源。",
    );
  } catch (error) {
    if (current === evidenceTransitRevision)
      evidenceTransitMessage(error.message, true);
  }
}
$("evidence-transit-example").addEventListener("click", () =>
  loadEvidenceTransitExample(true),
);
function evidenceTransitJointMessage(text, error = false) {
  $("evidence-transit-joint-message").textContent = "原观测联合：" + text;
  $("evidence-transit-joint-message").classList.toggle("error", error);
}
function cancelEvidenceTransitJointPreparation() {
  evidenceTransitJointRevision++;
  evidenceTransitJointPendingSource = null;
}
function evidenceTransitJointIsCurrent() {
  return (
    evidenceTransitJointReport !== null &&
    source.value === evidenceTransitJointSource &&
    evidenceTransitInput.value === evidenceTransitJointConfiguration
  );
}
function clearEvidenceTransitJoint() {
  invalidateTransitWindowsSource("joint");
  cancelEvidenceTransitJointPreparation();
  evidenceTransitJointReport = null;
  evidenceTransitJointResponse = null;
  evidenceTransitJointHeader = null;
  evidenceTransitJointSource = "";
  evidenceTransitJointConfiguration = "";
  $("evidence-transit-joint-frame").disabled = true;
  renderEvidenceTransit();
}
function invalidateEvidenceTransitJointSource() {
  // Recomputing ordinary results at the same raw input is independent. A raw
  // replacement, including a new example/reframe/resume, invalidates the joint.
  if (
    (evidenceTransitJointReport &&
      source.value !== evidenceTransitJointSource) ||
    (evidenceTransitJointPendingSource !== null &&
      source.value !== evidenceTransitJointPendingSource)
  ) {
    clearEvidenceTransitJoint();
    evidenceTransitJointMessage("原始测量输入已修改，请重新联合计算。");
  }
}
function requestEvidenceTransitAnalysis(header, observations) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(observations).length >
    8 * 1024 * 1024
  )
    throw new Error(
      "浏览器联合证据区间输入上限为 8 MiB；更大的流请使用原生命令。",
    );
  const request = JSON.stringify({ source: header, observations });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("联合证据区间请求超过 16 Mi 字符上限。");
  const response = moonground_evidence_transit_analysis(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器联合证据区间结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}
$("evidence-transit-analyze").addEventListener("click", async () => {
  const current = ++evidenceTransitJointRevision,
    runToken = ++evidenceTransitJointRunToken,
    input = source.value,
    transit = evidenceTransitInput.value;
  evidenceTransitRevision++;
  evidenceTransitPendingOrigin = null;
  evidenceTransitJointPendingSource = input;
  $("evidence-transit-analyze").disabled = true;
  evidenceTransitJointMessage("正在联合测量、确认法向证据并统计区间通行…");
  try {
    const lines = observationLines(input);
    if (lines.length < 2 || lines.length > 5001)
      throw new Error("请输入测量配置及 1—5000 行原始观测。");
    const header = JSON.stringify({ measurement: lines[0], transit });
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== evidenceTransitJointRevision ||
      input !== source.value ||
      transit !== evidenceTransitInput.value
    )
      return;
    const { response, report } = requestEvidenceTransitAnalysis(
      header,
      lines.slice(1).join("\n") + "\n",
    );
    if (
      current !== evidenceTransitJointRevision ||
      input !== source.value ||
      transit !== evidenceTransitInput.value
    )
      return;
    invalidateTransitWindowsSource("joint");
    evidenceTransitJointReport = report;
    evidenceTransitJointResponse = response;
    evidenceTransitJointHeader = header;
    evidenceTransitJointSource = input;
    evidenceTransitJointConfiguration = transit;
    evidenceTransitMode = "joint";
    $("evidence-transit-joint-frame").max = String(report.frames.length - 1);
    $("evidence-transit-joint-frame").value = String(report.frames.length - 1);
    $("evidence-transit-joint-frame").disabled = false;
    evidenceTransitJointMessage(
      `已联合计算 ${report.frames.length} 帧。测量、法向证据和区间通行在同一帧提交；普通测量及独立结果槽保持。`,
    );
    renderEvidenceTransit();
  } catch (error) {
    if (current === evidenceTransitJointRevision)
      evidenceTransitJointMessage(error.message, true);
  } finally {
    if (runToken === evidenceTransitJointRunToken) {
      evidenceTransitJointPendingSource = null;
      $("evidence-transit-analyze").disabled = false;
    }
  }
});
$("evidence-transit-mode").addEventListener("change", (event) => {
  evidenceTransitRevision++;
  evidenceTransitPendingOrigin = null;
  cancelEvidenceTransitJointPreparation();
  evidenceTransitMode = event.target.value;
  renderEvidenceTransit();
});
$("evidence-transit-joint-frame").addEventListener("input", () =>
  renderEvidenceTransit(),
);
$("download-evidence-transit-analysis").addEventListener("click", () => {
  if (evidenceTransitMode === "joint" && evidenceTransitJointIsCurrent())
    saveFile(
      evidenceTransitJointResponse + "\n",
      "moonground-evidence-transit-analysis-results.json",
    );
});
$("save-evidence-transit-analysis-checkpoint").addEventListener(
  "click",
  async () => {
    if (
      evidenceTransitJointCheckpointBusy ||
      evidenceTransitMode !== "joint" ||
      !evidenceTransitJointIsCurrent()
    )
      return;
    const current = evidenceTransitJointRevision,
      selected = $("evidence-transit-joint-frame").value,
      input = evidenceTransitJointSource,
      header = evidenceTransitJointHeader;
    evidenceTransitJointCheckpointBusy = true;
    refreshEvidenceTransitExports();
    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      if (
        current !== evidenceTransitJointRevision ||
        !evidenceTransitJointIsCurrent()
      )
        return;
      const { report } = requestEvidenceTransitAnalysis(
        header,
        observationLines(input)
          .slice(1, Number(selected) + 2)
          .join("\n") + "\n",
      );
      if (
        current !== evidenceTransitJointRevision ||
        evidenceTransitMode !== "joint" ||
        !evidenceTransitJointIsCurrent() ||
        selected !== $("evidence-transit-joint-frame").value
      )
        return;
      saveFile(
        JSON.stringify(report.checkpoint) + "\n",
        "moonground-evidence-transit-analysis-checkpoint.json",
      );
      evidenceTransitJointMessage(
        `已保存所选第 ${Number(selected) + 1} 帧的完整联合区间检查点，共同水位 ${report.checkpoint.transit.counting.state.last_timestamp_us} μs。`,
      );
    } catch (error) {
      if (current === evidenceTransitJointRevision)
        evidenceTransitJointMessage(error.message, true);
    } finally {
      evidenceTransitJointCheckpointBusy = false;
      refreshEvidenceTransitExports();
    }
  },
);
$("evidence-transit-analysis-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    const current = ++evidenceTransitJointRevision,
      runToken = ++evidenceTransitJointRunToken;
    evidenceTransitJointPendingSource = source.value;
    evidenceTransitRevision++;
    evidenceTransitPendingOrigin = null;
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器完整联合证据区间检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== evidenceTransitJointRevision) return;
      const { report } = requestEvidenceTransitAnalysis(
        '{"resume":' + text + "}",
        "",
      );
      const checkpoint = report.checkpoint,
        measurement = JSON.stringify({ resume: checkpoint.measurement }),
        transit = JSON.stringify({ resume: checkpoint.transit }, null, 2);
      requestEvidenceTransitAnalysis(
        JSON.stringify({ measurement, transit }),
        "",
      );
      if (
        new TextEncoder().encode(measurement + "\n").length +
          new TextEncoder().encode(transit).length >
        8 * 1024 * 1024
      )
        throw new Error("联合恢复起点超过浏览器 8 MiB 输入上限。");
      if (current !== evidenceTransitJointRevision) return;
      // Commit both canonical, fully validated components together. No raw
      // checkpoint component is used before the complete joint validation.
      source.value = measurement + "\n";
      evidenceTransitInput.value = transit;
      invalidate();
      clearEvidenceTransitJoint();
      clearEvidenceTransitResult();
      evidenceTransitEdited = true;
      configuration = checkpoint.measurement.configuration;
      draw();
      evidenceTransitJointMessage(
        `已载入完整联合区间检查点，共同恢复至 ${checkpoint.transit.counting.state.last_timestamp_us ?? "尚无观测"} μs。在原观测输入中添加更晚观测后继续联合计算。`,
      );
    } catch (error) {
      if (current === evidenceTransitJointRevision)
        evidenceTransitJointMessage(error.message, true);
    } finally {
      if (runToken === evidenceTransitJointRunToken) {
        evidenceTransitJointPendingSource = null;
        $("evidence-transit-analyze").disabled = false;
      }
      event.target.value = "";
    }
  },
);

function transitWindowsMessage(text, error = false) {
  $("transit-windows-message").textContent = text;
  $("transit-windows-message").classList.toggle("error", error);
}
function transitWindowsSource(origin) {
  if (origin === "independent") return evidenceTransitReport;
  if (origin === "joint") return evidenceTransitJointReport;
  if (origin === "guarded") return evidenceGuardedTransitReport;
  return null;
}
function transitWindowsSourceCurrent(origin, reference) {
  if (reference === null || transitWindowsSource(origin) !== reference)
    return false;
  if (origin === "independent") return evidenceTransitIsCurrent();
  if (origin === "joint") return evidenceTransitJointIsCurrent();
  if (origin === "guarded") return evidenceGuardedTransitIsCurrent();
  return false;
}
function refreshTransitWindowsSources() {
  for (const origin of ["independent", "joint", "guarded"])
    $("transit-windows-" + origin).disabled = !transitWindowsSourceCurrent(
      origin,
      transitWindowsSource(origin),
    );
}
function clearTransitWindowsResult(cancelPending = true) {
  if (cancelPending) {
    transitWindowsRevision++;
    transitWindowsPendingOrigin = null;
  }
  transitWindowsReport = null;
  transitWindowsResponse = null;
  transitWindowsOrigin = null;
  transitWindowsReference = null;
  transitWindowsConfiguration = "";
  renderTransitWindows();
}
function invalidateTransitWindowsSource(origin) {
  if (transitWindowsOrigin === origin) {
    clearTransitWindowsResult(
      transitWindowsPendingOrigin === null ||
        transitWindowsPendingOrigin === origin,
    );
    transitWindowsMessage("已统计的通行来源已更新，请显式选择来源重新分窗。");
  } else if (transitWindowsPendingOrigin === origin) {
    transitWindowsRevision++;
    transitWindowsPendingOrigin = null;
    transitWindowsMessage("待处理通行来源已更新，本次分窗已取消。");
  }
  refreshTransitWindowsSources();
}
function transitWindowsIsCurrent() {
  return (
    transitWindowsReport !== null &&
    transitWindowsInput.value === transitWindowsConfiguration &&
    transitWindowsSourceCurrent(transitWindowsOrigin, transitWindowsReference)
  );
}
function transitWindowsSlider(origin) {
  if (origin === "guarded") return $("evidence-guarded-transit-frame");
  if (origin === "joint") return $("evidence-transit-joint-frame");
  return evidenceTransitOrigin === "ordinary"
    ? slider
    : $("evidence-guarded-frame");
}
function transitWindowRows(window) {
  return window.sections.flatMap((section) =>
    section.duration_limits.map((limit) =>
      reportRow([
        section.section_id,
        limit.limit_us,
        limit.within,
        limit.exceeded,
        limit.indeterminate,
        section.completed,
      ]),
    ),
  );
}
function renderTransitWindow(window, prefix) {
  if (window === null) {
    $(prefix + "-summary").textContent = "本帧未关闭窗口。";
    return;
  }
  const interval =
    window.end_exclusive_us === null
      ? "[" + window.start_us + ", Int64 时钟上限]"
      : "[" + window.start_us + ", " + window.end_exclusive_us + ")";
  $(prefix + "-summary").textContent =
    interval +
    " μs · 输入 " +
    window.input_frames +
    " 帧 · 首帧 " +
    window.first_timestamp_us +
    " · 末帧 " +
    window.last_timestamp_us +
    " μs";
  $(prefix + "-limits").replaceChildren(...transitWindowRows(window));
  $(prefix + "-cancellations").replaceChildren(
    ...window.sections.map((section) =>
      reportRow([
        section.section_id,
        ...section.cancellations.map((reason) => reason.count),
      ]),
    ),
  );
}
function renderTransitWindows() {
  const valid = transitWindowsIsCurrent();
  $("download-transit-windows").disabled = !valid;
  $("save-transit-windows-checkpoint").disabled = !valid;
  for (const prefix of ["transit-windows-current", "transit-windows-closed"])
    for (const suffix of ["limits", "cancellations"])
      $(prefix + "-" + suffix).replaceChildren();
  if (!valid) {
    $("transit-windows-source").textContent = "尚未选择通行来源";
    $("transit-windows-gap").textContent = "";
    $("transit-windows-current-summary").textContent = "尚无输入窗口。";
    $("transit-windows-closed-summary").textContent = "尚无关闭窗口。";
    return;
  }
  const index = Number(transitWindowsSlider(transitWindowsOrigin).value);
  const frame = transitWindowsReport.frames[index];
  if (!frame) return;
  const labels = {
    independent: "独立证据区间",
    joint: "原观测联合区间",
    guarded: "健康证据通行",
  };
  $("transit-windows-source").textContent =
    labels[transitWindowsOrigin] +
    " · " +
    (index + 1) +
    " / " +
    transitWindowsReport.frames.length +
    " · 确认帧 " +
    frame.timestamp_us +
    " μs";
  $("transit-windows-gap").textContent =
    "本次跨窗跳过的未观察窗口：" +
    frame.unobserved_windows +
    "。分类依据为原观测弦的时长闭区间；关闭窗口不表示连续相机覆盖。";
  if (!$("transit-windows-section").open) return;
  renderTransitWindow(frame.current_window, "transit-windows-current");
  renderTransitWindow(frame.closed_window, "transit-windows-closed");
}
function requestTransitWindows(header, transits) {
  const encoder = new TextEncoder();
  if (
    encoder.encode(header).length + encoder.encode(transits).length >
    8 * 1024 * 1024
  )
    throw new Error("浏览器分窗统计输入上限为 8 MiB；更大的流请使用原生命令。");
  const request = JSON.stringify({ source: header, transits });
  if (request.length > 16 * 1024 * 1024)
    throw new Error("分窗统计请求超过 16 Mi 字符上限。");
  const response = moonground_transit_windows(request),
    report = unpack(response);
  if (encoder.encode(response).length > 8 * 1024 * 1024)
    throw new Error("浏览器分窗统计结果超过 8 MiB；请使用原生命令保存。");
  return { response, report };
}
function transitWindowsHeader(configuration, origin) {
  // Inspect only the first property name. Numeric values, duplicate properties,
  // unknown fields and resume documents remain raw for the strict core reader.
  const raw = configuration.replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, "");
  if (!raw.startsWith("{") || !raw.endsWith("}"))
    throw new Error("请输入分窗配置或完整恢复起点 JSON 对象。");
  const first = raw.match(/^\{[\t\n\r ]*("(?:[^"\\]|\\.)*")[\t\n\r ]*:/);
  if (first && JSON.parse(first[1]) === "resume") return raw;
  let checkpoint;
  if (origin === "independent") {
    checkpoint = requestEvidenceTransit(evidenceTransitConfiguration, "").report
      .checkpoint;
  } else if (origin === "joint") {
    checkpoint = requestEvidenceTransitAnalysis(evidenceTransitJointHeader, "")
      .report.checkpoint.transit;
  } else {
    checkpoint = requestEvidenceGuardedTransit(
      observationLines(evidenceGuardedTransitLoadedSource)[0],
      "",
    ).report.checkpoint.analysis.transit;
  }
  // Reopen the original source, never seed with the report's final checkpoint:
  // every supplied frame must advance the reducer from the same initial clock.
  const transit = JSON.stringify({ resume: checkpoint });
  const fields = raw.slice(1, -1);
  return (
    '{"transit":' +
    JSON.stringify(transit) +
    (fields.replace(/[\t\n\r ]/g, "") ? "," + fields : "") +
    "}"
  );
}
async function runTransitWindows(origin) {
  const reference = transitWindowsSource(origin);
  if (!transitWindowsSourceCurrent(origin, reference)) return;
  const current = ++transitWindowsRevision,
    runToken = ++transitWindowsRunToken,
    configuration = transitWindowsInput.value;
  transitWindowsPendingOrigin = origin;
  transitWindowsMessage("正在按确认帧时钟分窗并分类通行时限…");
  try {
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (
      current !== transitWindowsRevision ||
      configuration !== transitWindowsInput.value ||
      !transitWindowsSourceCurrent(origin, reference)
    )
      return;
    const header = transitWindowsHeader(configuration, origin);
    const frames = reference.frames.map((frame) =>
      origin === "independent"
        ? frame
        : origin === "joint"
          ? frame.transit
          : frame.analysis.transit,
    );
    const { response, report } = requestTransitWindows(
      header,
      frames.map((frame) => JSON.stringify(frame)).join("\n") + "\n",
    );
    if (
      current !== transitWindowsRevision ||
      configuration !== transitWindowsInput.value ||
      !transitWindowsSourceCurrent(origin, reference)
    )
      return;
    transitWindowsReport = report;
    transitWindowsResponse = response;
    transitWindowsOrigin = origin;
    transitWindowsReference = reference;
    transitWindowsConfiguration = configuration;
    transitWindowsMessage(
      "已统计 " +
        report.frames.length +
        " 个确认帧。跟随所选来源滑块；下载包含整批结果与末帧独立检查点。",
    );
    renderTransitWindows();
  } catch (error) {
    if (current === transitWindowsRevision)
      transitWindowsMessage(error.message, true);
  } finally {
    if (runToken === transitWindowsRunToken) transitWindowsPendingOrigin = null;
  }
}
transitWindowsInput.addEventListener("input", () => {
  clearTransitWindowsResult();
  transitWindowsMessage("分窗配置已修改，请显式选择通行来源重新统计。");
});
$("transit-windows-section").addEventListener("toggle", renderTransitWindows);
for (const origin of ["independent", "joint", "guarded"])
  $("transit-windows-" + origin).addEventListener("click", () =>
    runTransitWindows(origin),
  );
$("download-transit-windows").addEventListener("click", () => {
  if (transitWindowsIsCurrent())
    saveFile(
      transitWindowsResponse + "\n",
      "moonground-transit-windows-results.json",
    );
});
$("save-transit-windows-checkpoint").addEventListener("click", () => {
  if (!transitWindowsIsCurrent()) return;
  saveFile(
    JSON.stringify(transitWindowsReport.checkpoint) + "\n",
    "moonground-transit-windows-checkpoint.json",
  );
  transitWindowsMessage(
    "已保存整批末帧 " +
      transitWindowsReport.checkpoint.last_timestamp_us +
      " μs 的独立分窗检查点；续接需另行恢复同水位上游，并提供全部更晚通行帧。",
  );
});
$("transit-windows-checkpoint-file").addEventListener(
  "change",
  async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    const current = ++transitWindowsRevision,
      runToken = ++transitWindowsRunToken;
    transitWindowsPendingOrigin = "checkpoint";
    try {
      if (file.size > 8 * 1024 * 1024)
        throw new Error("浏览器分窗检查点文件上限为 8 MiB。");
      const text = await file.text();
      if (current !== transitWindowsRevision) return;
      const { report } = requestTransitWindows('{"resume":' + text + "}", "");
      const nextInput = JSON.stringify({ resume: report.checkpoint });
      if (new TextEncoder().encode(nextInput).length > 8 * 1024 * 1024)
        throw new Error("分窗恢复起点超过浏览器 8 MiB 输入上限。");
      if (current !== transitWindowsRevision) return;
      clearTransitWindowsResult();
      transitWindowsInput.value = nextInput;
      transitWindowsMessage(
        "已载入完整分窗检查点（末帧 " +
          (report.checkpoint.last_timestamp_us ?? "尚无输入") +
          " μs）。将上游恢复至同一水位后，选择仅含更晚帧的结果；页面保留原始时钟。",
      );
    } catch (error) {
      if (current === transitWindowsRevision)
        transitWindowsMessage(error.message, true);
    } finally {
      if (runToken === transitWindowsRunToken)
        transitWindowsPendingOrigin = null;
      event.target.value = "";
    }
  },
);
refreshTransitWindowsSources();
renderTransitWindows();

loadEvidenceTransitExample();

drawEvidenceGuardedTimeline();
drawGuardedTimeline();
drawHealthTimeline();
draw();
example();
