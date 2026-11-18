# 健康门控的原始测量与足迹确认序列

在“逐目标混合足迹”的“同足迹证据确认序列”中选择“健康门控联合”。三种显示模式保留各自的结果、任务和选帧，共用当前／结束序列表。切换只改变显示。

门控联合读取五份原文：上方原始像素流、固定地标健康流、区域配置、逐帧显式分配和序列选项。它不使用普通测量、旧门控或独立序列已输出的结果。只支持像素输入；区域和足迹仍使用同一已知米制坐标。

## 全程发现身份，再手工分配

点击“全程预览门控候选身份”，候选滑块会显示每帧核心实际返回的健康状态、allowed／blocked、目标片段和被抑制的输入目标 ID。健康尚在预热、漂移或地标不足时，实际候选测量为空；恢复健康后产生新片段，不能沿用普通测量中的片段 ID。

预览在临时会话中逐帧推进健康和测量，包含标定切换，使用内部空分配发现真实身份。它不返回序列或检查点、不提交正式结果、不自动填写形状。分配仍由用户按每个实际候选显式绑定。预览不依赖当前分配文本；正式重放会重新计算并验证所有实际分配。

只有当前健康已确认 healthy 才允许对象测量。其他状态中断全部活动片段并结束旧序列；blocked 帧仍严格检查原始对象和分配文档，必须给出同时间的显式空 footprints。核心不会悄悄丢弃非空分配或补造零速度。

## 原文行如何对齐

普通原始像素流首行为测量配置，后续每条普通观测消耗地标流首行配置之后的一条地标观测，以及分配编辑器的一条分配文档。按行顺序配对，精确时间由核心核对。

像素编辑器允许单独的 {"replace_projection":"原替换 JSON 字符串"} 控制行。该行保持原文，不消耗任何地标或分配行。替换要求时间严格晚于前水位，关闭旧对象／序列，重置健康确认；后续地标像素需对应新投影。米制区域、固定地标与足迹坐标保持原含义。普通测量和旧原始联合入口继续拒绝该控制行。

## 完整输入示例

下面 JavaScript 生成可分别粘贴到五个现有编辑器的 inputs 字符串。正常帧间隔 200000 μs，800000／1000000 μs 的地标漂移引起阻断；1700000 μs 切换到新的米／像素比例，随后重新确认。分配手工列明了三个实际片段；阻断帧为空，控制行没有对应分配或地标行。

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
inputs;
```

## 共同提交、结果与恢复

健康、测量和同足迹确认序列全部成功后才共同提交。分配错误、容量或数值错误不会提前推进任一组件、消耗新片段或部分替换投影。序列语义沿用 [确认序列](footprint-runs-web.md)：按同形状三态证据确认样本，样本跨度不表示物理停留、到访或连续占用。阻断与投影切换显示核心原始结束原因，例如 segment_closed。

“下载门控结果与完整共同检查点”保存 moonground-footprint-run-guarded.json。每帧包含 decision、health、suppressed_track_ids 和 analysis；analysis 含原测量与完整序列帧。最终 checkpoint 的 format 为 moonground.footprint-run-guarded，checkpoint_version 为字符串 1，组件为完整 analysis 和 health。恢复会核对健康、投影、水位、真实片段与确认序列见证。Web 该版本提供整批最终检查点下载，API 可使用完整 resume；界面没有导入或所选帧检查点。

五份原文实际编辑会使正式结果和待请求失效；预览忽略分配编辑。相同原文的普通或健康重算不影响门控结果，旧任务不能覆盖新草稿。任务失败且原文未改时保留成功结果，模式切换不取消任务。表和候选摘要仅在相应区域展开时渲染。

## 复用接口

纯 JavaScript 正式入口为 moonground_footprint_run_guarded(JSON.stringify({source, frames}))，批量身份预览为 moonground_footprint_run_guarded_preview(JSON.stringify({source, frames}))。source 为 {analysis:原 v27 源字符串, health:原健康源字符串} 或 {resume:完整共同检查点}；v27 源内仍保留 measurement 和 runs 原字符串。

正式普通行保留三个原字符串 measurement、health、assignments；预览行只有 measurement 和 health。批量预览返回 {frames:[候选]}，无 runs、分配或检查点。CLI --guarded-footprint-runs、--guarded-footprint-runs-checkpoint 提供正式流；--preview-guarded-footprint-run 仍严格只接收一条配对普通帧，不提交或预览控制行。

核心源上限 8 Mi UTF16 单元加恢复 envelope，完整检查点 8 Mi，普通 wrapper 与内部文档各 1 Mi；frames 共 8 Mi／5000 行，外层请求 16 Mi，包含最终检查点的全部输出 8 Mi。浏览器每次输入与输出各限 8 MiB UTF8。浏览器只包装原字符串与识别最外层控制键，原始数值、重复键及未知字段交给核心验证。
