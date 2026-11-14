# 健康门控、足迹确认序列与分窗共同计算

在“足迹确认序列分窗”选择“健康门控联合”。三个分窗模式保存各自的结果、任务和选帧，共用原有统计表；普通下游跟随普通滑块，两个原始联合模式各有独立滑块。原有三种足迹序列模式继续独立使用。

新入口读取六份原文：上方原始像素流、固定地标健康流、区域配置、逐帧显式分配、确认序列选项和窗口选项。它不读取普通、旧门控或其他联合入口已经输出的帧。健康只有当前确认 healthy 才允许对象测量；其余状态中断全部活动片段并结束旧序列，同帧结果仍进入报告时间窗口。

## 先发现真实身份，再显式绑定

“全程预览门控分窗身份”调用本联合核心，在临时会话中推进全部普通观测及标定切换，显示每帧实际 decision、health、测量身份和 suppressed_track_ids。阻断时实际候选为空；恢复健康或切换标定后产生的新片段不能从普通测量身份猜出。

预览不读取分配，不返回确认序列、窗口结果或检查点，不提交正式会话或预留片段。正式计算重新重放并逐帧核对显式分配。blocked 帧仍严格校验原始对象，必须有同时间的空 footprints 文档；非空分配不会被浏览器过滤。

原始像素流、地标流首行分别是原始配置或合法恢复源。普通观测按顺序各消耗一条地标观测和分配文档，精确时间交给核心检查。单独的 {"replace_projection":"原始控制 JSON 字符串"} 行原样转发，不消耗地标或分配行。控制帧关闭旧片段和序列、重置健康确认，同时成为一次真实分窗输入。米制区域和固定地标仍属于原坐标系。

## 可执行的六输入示例

下面生成现有六个编辑器的 inputs。地标漂移导致阻断，1700000 μs 切换投影，随后重新确认并产生新片段。分配按实际身份手工列明，控制没有对应地标或分配行。

```javascript
const calibration = {
  matrix: [0.1, 0, 0, 0, 0.1, 0, 0, 0, 1],
  roi: [
    [0, 0],
    [100, 0],
    [100, 100],
    [0, 100],
  ],
  ground_noise_floor_m: 0.01,
};
const measurement = {
  session_id: "guarded-footprint-web",
  mode: "pixel",
  calibration,
  motion: {
    q: 0.01,
    gate: 1e12,
    max_tracks: 4,
    min_observations: 2,
    min_span_us: "0",
    max_gap_us: "500000",
  },
};
const health = {
  monitor_id: "fixed-floor",
  calibration,
  landmarks: [
    { landmark_id: "A", ground_m: [1, 1] },
    { landmark_id: "B", ground_m: [2, 1] },
    { landmark_id: "C", ground_m: [1, 2] },
  ],
  health: {
    min_landmarks: 3,
    rms_limit_m: 0.1,
    max_error_m: 0.2,
    confirmation_us: "200000",
    min_observations: 2,
    max_gap_us: "500000",
  },
};
const times = [
  "0",
  "200000",
  "400000",
  "600000",
  "800000",
  "1000000",
  "1200000",
  "1400000",
  "1600000",
  "1800000",
  "2000000",
  "2200000",
  "2400000",
  "2600000",
];
const segments = [
  null,
  "1",
  "1",
  "1",
  null,
  null,
  null,
  "2",
  "2",
  null,
  "3",
  "3",
  "3",
  "3",
];
const replacement = {
  replace_projection: JSON.stringify({
    timestamp_us: "1700000",
    calibration: { ...calibration, matrix: [0.2, 0, 0, 0, 0.2, 0, 0, 0, 1] },
    camera: null,
  }),
};
const objects = times.map((timestamp_us, index) => ({
  timestamp_us,
  observations: [
    {
      track_id: 1,
      point: index >= 9 ? [6, 5] : [12, 10],
      covariance: [0.01, 0, 0.01],
    },
  ],
}));
objects.splice(9, 0, replacement);
const landmarks = times.map((timestamp_us, index) => ({
  timestamp_us,
  observations: ["A", "B", "C"].map((landmark_id, landmark) => ({
    landmark_id,
    point:
      index === 4 || index === 5
        ? [
            [30, 10],
            [40, 10],
            [30, 20],
          ][landmark]
        : (index >= 9
            ? [
                [5, 5],
                [10, 5],
                [5, 10],
              ]
            : [
                [10, 10],
                [20, 10],
                [10, 20],
              ])[landmark],
  })),
}));
const assignments = times.map((timestamp_us, index) => ({
  timestamp_us,
  footprints:
    segments[index] === null
      ? []
      : [
          {
            track_id: 1,
            segment_id: segments[index],
            shape: { kind: "disk", radius_m: 0.1 },
          },
        ],
}));
const ndjson = (lines) =>
  lines.map((line) => JSON.stringify(line)).join("\n") + "\n";
const inputs = {
  measurement: ndjson([measurement, ...objects]),
  health: ndjson([health, ...landmarks]),
  position: JSON.stringify({
    session_id: "guarded-footprint-web",
    max_tracks: 4,
    zones: [
      {
        zone_id: "floor",
        vertices_m: [
          [-5, -5],
          [20, -5],
          [20, 20],
          [-5, 20],
        ],
        sigma_multiplier: 2,
      },
    ],
  }),
  assignments: ndjson(assignments),
  options:
    '{"max_gap_us":"500000","confirmation_us":"200000","min_samples":"2"}',
};
inputs.window = '{"window_us":"500000","origin_us":"0"}';
inputs;
```

## 完整检查点与控制后续接

“下载门控分窗与完整共同检查点”保存 moonground-footprint-run-window-guarded.json，包括全部帧和批末完整 checkpoint。选帧不改变下载检查点的水位。页面没有导入或所选帧检查点。

新会话拥有一个原 v30 测量／序列／分窗联合会话和一个健康 monitor；唯一 runs 副本保存在 analysis.windows 内。所有层成功才共同提交；分配、健康、几何、计数或窗口错误不会提前推进任一层。恢复检查组件、水位、投影、真实身份以及保留的健康和分窗输入见证，不认证已丢弃的全部历史。

以下代码紧接上述示例运行，api 是 moonground.mjs 模块命名空间。它执行全程预览和正式计算，验证完整 CP，再从该 CP 切换投影并重新确认到片段 4。代码只解析自己构造的固定示例文档；页面仍传递用户原字符串。

```javascript
const measurementLines = inputs.measurement.trimEnd().split("\n");
const healthLines = inputs.health.trimEnd().split("\n");
const assignmentLines = inputs.assignments.trimEnd().split("\n");
const rawSource = JSON.stringify({
  guarded: JSON.stringify({
    analysis: JSON.stringify({
      measurement: measurementLines[0],
      runs: JSON.stringify({
        position: inputs.position,
        options: inputs.options,
      }),
    }),
    health: healthLines[0],
  }),
  window: inputs.window,
});
const readResult = (text) => {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value;
};
let companion = 0;
const wrapped = measurementLines.slice(1).map((measurement) => {
  if (Object.hasOwn(JSON.parse(measurement), "replace_projection"))
    return measurement;
  const index = companion++;
  return JSON.stringify({
    measurement,
    health: healthLines[index + 1],
    assignments: assignmentLines[index],
  });
});
const previewFrames =
  wrapped
    .map((line) => {
      const value = JSON.parse(line);
      if (Object.hasOwn(value, "replace_projection")) return line;
      return JSON.stringify({
        measurement: value.measurement,
        health: value.health,
      });
    })
    .join("\n") + "\n";
const preview = readResult(
  api.moonground_footprint_run_window_guarded_preview(
    JSON.stringify({ source: rawSource, frames: previewFrames }),
  ),
);
const initial = readResult(
  api.moonground_footprint_run_window_guarded(
    JSON.stringify({ source: rawSource, frames: wrapped.join("\n") + "\n" }),
  ),
);
const resume = JSON.stringify({ resume: initial.checkpoint });
const verified = readResult(
  api.moonground_footprint_run_window_guarded(
    JSON.stringify({ source: resume, frames: "" }),
  ),
);
const nextCalibration = {
  ...calibration,
  matrix: [0.25, 0, 0, 0, 0.25, 0, 0, 0, 1],
};
const suffix = [
  JSON.stringify({
    replace_projection: JSON.stringify({
      timestamp_us: "2800000",
      calibration: nextCalibration,
      camera: null,
    }),
  }),
];
for (const [index, timestamp_us] of [
  "3000000",
  "3200000",
  "3400000",
  "3600000",
].entries()) {
  suffix.push(
    JSON.stringify({
      measurement: JSON.stringify({
        timestamp_us,
        observations: [
          { track_id: 1, point: [4.8, 4], covariance: [0.01, 0, 0.01] },
        ],
      }),
      health: JSON.stringify({
        timestamp_us,
        observations: ["A", "B", "C"].map((landmark_id, i) => ({
          landmark_id,
          point: [
            [4, 4],
            [8, 4],
            [4, 8],
          ][i],
        })),
      }),
      assignments: JSON.stringify({
        timestamp_us,
        footprints:
          index === 0
            ? []
            : [
                {
                  track_id: 1,
                  segment_id: "4",
                  shape: { kind: "disk", radius_m: 0.1 },
                },
              ],
      }),
    }),
  );
}
const continued = readResult(
  api.moonground_footprint_run_window_guarded(
    JSON.stringify({ source: resume, frames: suffix.join("\n") + "\n" }),
  ),
);
const continuation = { preview, initial, verified, continued };
continuation;
```

新 fresh source 从合法已启动的原 v28 门控完整状态开始时，仅以原水位建立窗口基线，不补记历史确认或结束。完整新 CP 恢复则保留原基线、当前窗口和全部保留状态。

## 原文依赖与接口

正式结果绑定六份原文。全程预览忽略分配，其余五份仍精确绑定。实际编辑取消相应待请求并清除旧结果；health 编辑不清普通或原始非门控分窗结果，窗口编辑不清原有未分窗序列结果。同原文普通或健康重算、独立模式计算与滑块移动不影响新会话。各任务使用自己的 revision／runToken，迟到结果和旧 finally 不能覆盖新任务。相同依赖下计算失败保留成功结果；模式切换只显示，折叠时不生成明细。

纯正式入口 moonground_footprint_run_window_guarded(JSON.stringify({source, frames})) 返回 {frames, checkpoint}；source 为 {guarded:原 v28 源字符串, window:原窗口选项字符串}，或 sole {resume:完整新 CP}。正式普通行仍保留 measurement、health、assignments 三个原始 JSON 字符串；控制行原样独立存在。

普通输出 kind 为 footprint_run_window_guarded_frame，控制输出为 footprint_run_window_guarded_projection_replaced；两者保留 decision、health、suppressed_track_ids 和 analysis。analysis 是完整原 v30 帧，包含 measurement 和 windows；windows.runs 保留原 evidence／active／confirmed／closed，windows.statistics 保留分窗结果。CP 的 format 为 moonground.footprint-run-window-guarded，checkpoint_version 为字符串 1，组件 analysis 是完整 v30 CP，health 是原完整健康 CP。

纯 moonground_footprint_run_window_guarded_preview({source, frames}) 使用 JSON 字符串请求，返回 {frames:[真实候选]}。每个候选复用原 decision、health、measurement、suppressed_track_ids 字段，无 CP。CLI --guarded-footprint-run-windows 与 --guarded-footprint-run-windows-checkpoint 提供正式流；--preview-guarded-footprint-run-window 严格预览一条普通配对帧，返回单个原 v28 候选，不推进正式状态。CLI 单帧预览与纯全程发现的返回形状不同。

source 8 Mi UTF16 单元加恢复 envelope，完整 CP 8 Mi；普通 wrapper 和内部文档各 1 Mi，深度 32。frames 共 8 Mi／5000 行，外层请求 16 Mi；包含最终 CP 的全部输出 8 Mi，全程预览输出 8 Mi。Web 每次输入与输出各限 8 MiB UTF8。输入达到 5000 行仍可能先超过整批输出预算。浏览器仅包装原文本和识别最外层控制键，数值、重复键、未知字段、时间与片段均由核心验证。

首次确认、结束次数、开窗池及未观察窗口沿用 [原分窗契约](footprint-run-windows-web.md)，不表示实际到访、连续占用或物理停留。

## 本批官方生态核查

本批执行三次 Mooncakes 限定查询并实际核对以下三个官方版本页面：

- [MoonEventTime 0.2.1](https://mooncakes.io/docs/Ag108/MoonEventTime@0.2.1) 已有通用 tumbling／sliding／session、自定义聚合、水位线与原子 ingest。旧 Engine 提供 snapshot／restore；新泛型 WindowEngine 尚无快照，其聚合器不由旧快照格式序列化。
- [Moon-Kalman 0.2.1](https://mooncakes.io/docs/Lyllyl789/moon-kalman@0.2.1) 已有 OperationalMonitor 健康统计、状态／协方差视图，以及 KalmanND::checkpoint／restore_checkpoint。所查页未见精确片段足迹与报告帧分窗的共同事务。
- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 已有原子 SpatialAnalyzer::update 和区域分析。所查 TrackSample 使用 ID、bbox、类别，页面未见 checkpoint、footprint 或 segment_id。

通用健康监测、窗口、原子更新与滤波检查点已有实现。本批补充固定地标健康控制下真实候选身份、精确片段足迹确认及报告帧分窗的共同提交和完整恢复；差异限定上述版本和已查页面。
