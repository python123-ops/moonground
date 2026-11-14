# 原始测量、足迹确认序列与分窗联合计算

在“足迹确认序列分窗”中选择“原始联合”，即可从当前原始像素／米制观测、区域、精确逐帧分配、序列选项和窗口选项共同重放。无需先运行普通测量、旧联合序列或下游分窗。

“普通测量下游”和“原始联合”保留各自结果和任务，共用一张统计表。下游跟随普通滑块，联合结果使用自己的滑块，并显示当前核心测量身份。切换只改变显示；原有三种序列显示模式不变。

## 真实候选身份与共同提交

“预览联合分窗首帧候选”调用新联合核心，返回当前起点第一帧的实际测量。预览不提交、不预留片段，不读取或自动填写分配。已有普通测量可以辅助发现后续身份，但正式联合计算仍逐帧检查时间、目标、片段和显式形状；旧片段不能自动改成新片段。

一个联合会话只拥有一个测量引擎和一个原分窗 monitor；序列状态仅在该 monitor 内保存一次。测量候选准备完成后，再核对分配、足迹证据、序列和窗口。全部成功才共同提交；数值、分配、原点或计数错误不提前推进任一层或消耗新片段。

Inside／Outside 首次确认、八种结束原因的已确认／未确认分组、报告帧归窗、开窗池和未观察窗口均沿用 [原分窗契约](footprint-run-windows-web.md)。它们不表示实际到访、连续占用或物理停留。本入口不处理健康配对流或 replace_projection 控制行。

## 可执行的五输入示例

下面生成可分别粘贴到现有五个编辑器的 inputs。选择“原始联合”后可直接预览和计算。区域内／外首次确认、更换形状、未分配、移除、新片段与跨窗均包含在同一例中。

```javascript
const times = [
  "0",
  "200000",
  "400000",
  "600000",
  "800000",
  "1000000",
  "2000000",
  "2200000",
  "2400000",
];
const measurementConfig = {
  session_id: "footprint-window-web",
  mode: "ground",
  motion: {
    q: 0.01,
    gate: 1e12,
    initial_velocity_std: 2,
    max_tracks: 4,
    min_observations: 2,
    min_span_us: "0",
    max_gap_us: "500000",
  },
};
const observations = times.map((timestamp_us, index) =>
  index === 5
    ? { timestamp_us, observations: [], removed: [1, 2] }
    : {
        timestamp_us,
        observations: [
          { track_id: 1, point: [0, 0], covariance: [0.0001, 0, 0.0001] },
          { track_id: 2, point: [5, 0], covariance: [0.0001, 0, 0.0001] },
        ],
      },
);
const assignments = times.map((timestamp_us, index) => ({
  timestamp_us,
  footprints:
    index === 5
      ? []
      : [
          ...(index === 4
            ? []
            : [
                {
                  track_id: 1,
                  segment_id: index >= 6 ? "3" : "1",
                  shape: { kind: "disk", radius_m: index === 3 ? 0.2 : 0.1 },
                },
              ]),
          {
            track_id: 2,
            segment_id: index >= 6 ? "4" : "2",
            shape: {
              kind: "convex",
              vertices_offset_m: [
                [-0.1, -0.1],
                [0.1, -0.1],
                [0.1, 0.1],
                [-0.1, 0.1],
              ],
            },
          },
        ],
}));
const ndjson = (lines) =>
  lines.map((line) => JSON.stringify(line)).join("\n") + "\n";
const inputs = {
  measurement: ndjson([measurementConfig, ...observations]),
  position: JSON.stringify({
    session_id: "footprint-window-web",
    max_tracks: 4,
    zones: [
      {
        zone_id: "floor",
        vertices_m: [
          [-1, -1],
          [1, -1],
          [1, 1],
          [-1, 1],
        ],
        sigma_multiplier: 2,
      },
    ],
  }),
  assignments: ndjson(assignments),
  options:
    '{"max_gap_us":"500000","confirmation_us":"200000","min_samples":"2"}',
  window: '{"window_us":"500000","origin_us":"0"}',
};
inputs;
```

## 完整检查点与实际续接

“下载联合分窗与完整共同检查点”保存 moonground-footprint-run-window-analysis.json，包含全部 measurement、windows 帧和批末完整 checkpoint。滑块选帧不改变最终检查点水位。Web 本批不提供检查点导入或所选帧检查点。

完整 CP 的 format 为 moonground.footprint-run-window-analysis，checkpoint_version 为字符串 1，组件为原完整 measurement 和完整 v29 windows；唯一的 runs 副本在 windows 内。恢复会校验原组件、共同水位、像素／米制会话、当前质量、位置与协方差、片段、序列及窗口稀疏输入见证的一致性；不认证全部历史观测。

以下代码在上述 inputs 后运行；api 是导出的 moonground.mjs 模块命名空间。它先完整计算并核对首帧预览，再恢复完整 CP，并从 2600000 μs 续接。示例只解析自己构造的固定分配文档以保留显式形状；页面仍直接传递用户原文。

```javascript
const measurementLines = inputs.measurement.trimEnd().split("\n");
const assignmentLines = inputs.assignments.trimEnd().split("\n");
const rawSource = JSON.stringify({
  analysis: JSON.stringify({
    measurement: measurementLines[0],
    runs: JSON.stringify({
      position: inputs.position,
      options: inputs.options,
    }),
  }),
  window: inputs.window,
});
const readResult = (text) => {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value;
};
const preview = readResult(
  api.moonground_footprint_run_window_preview(
    JSON.stringify({ source: rawSource, frame: measurementLines[1] }),
  ),
);
const initial = readResult(
  api.moonground_footprint_run_window_analysis(
    JSON.stringify({
      source: rawSource,
      frames:
        measurementLines
          .slice(1)
          .map((measurement, index) =>
            JSON.stringify({
              measurement,
              assignments: assignmentLines[index],
            }),
          )
          .join("\n") + "\n",
    }),
  ),
);
const resume = JSON.stringify({ resume: initial.checkpoint });
const verified = readResult(
  api.moonground_footprint_run_window_analysis(
    JSON.stringify({ source: resume, frames: "" }),
  ),
);
const nextMeasurement = JSON.stringify({
  timestamp_us: "2600000",
  observations: [
    { track_id: 1, point: [0, 0], covariance: [0.0001, 0, 0.0001] },
    { track_id: 2, point: [5, 0], covariance: [0.0001, 0, 0.0001] },
  ],
});
const nextAssignments = JSON.stringify({
  ...JSON.parse(assignmentLines.at(-1)),
  timestamp_us: "2600000",
});
const continued = readResult(
  api.moonground_footprint_run_window_analysis(
    JSON.stringify({
      source: resume,
      frames:
        JSON.stringify({
          measurement: nextMeasurement,
          assignments: nextAssignments,
        }) + "\n",
    }),
  ),
);
const continuation = { preview, initial, verified, continued };
continuation;
```

完整 CP 保留当前窗口，不用单独恢复上游再人工配水位。fresh 入口若从合法的已启动 v27 完整状态开始，则以原水位建立尚未观察的分窗基线，不追补过去确认。单独的已启动测量状态不能悄悄接上新序列。typed preparation 提供真实候选及严格 commit，失败候选可纠正后重试；Web 的纯预览不序列化这种 token。

## 原文与独立任务

联合结果精确绑定五份原文。实际编辑普通原始流、区域、分配、序列或窗口选项会使相应结果与准备失效。首帧预览不使用分配，单独编辑分配不取消仍对应当前候选的预览。

原始联合不依赖普通测量输出或其 revision；同原文重算普通测量、旧结果更换或普通滑块移动不影响联合结果及任务。健康和其他分析配置也不属于依赖。各任务独立使用 revision 和 runToken，迟到结果不能覆盖新草稿，旧 finally 不能清除新任务。相同依赖下失败保留上次成功结果，折叠时不生成明细。

纯入口为 moonground_footprint_run_window_analysis(JSON.stringify({source, frames}))；fresh source 为 {analysis:原 v27 源字符串, window:原窗口选项字符串}，或 sole {resume:完整新 CP}。正式每行是 {measurement:原始观测字符串, assignments:原精确分配字符串}；measurement 不是已经计算的 schema 0.2 输出。

返回帧 kind 为 footprint_run_window_analysis_frame，measurement 沿用原 schema 0.2，windows 保持原完整 footprint_run_window_frame。moonground_footprint_run_window_preview({source, frame}) 的 JSON 字符串请求严格预览一帧，返回 {measurement}，不含 CP 或分配。CLI 为 --analyze-footprint-run-windows、--analyze-footprint-run-windows-checkpoint 和 --preview-footprint-run-window。

源上限为 8 Mi UTF16 单元加恢复 envelope，完整 CP 8 Mi；原组件、普通 wrapper 和内部文档各 1 Mi，深度 32。frames 共 8 Mi／5000 帧，外层请求 16 Mi，包含最终 CP 的全部输出 8 Mi，preview 输出 8 Mi。Web 每次输入和输出各限 8 MiB UTF8。浏览器只包装原字符串，不重写整数、时间、重复键、未知字段或分配。

## 本批官方生态核查

本批重新执行三次限定 Mooncakes 的查询，实际核对三个官方版本页面：

- [MoonEventTime 0.2.1](https://mooncakes.io/docs/Ag108/MoonEventTime@0.2.1) 仍提供通用 tumbling／sliding／session、自定义聚合、水位线和原子 ingest。旧 Engine 支持版本化 snapshot／restore；新泛型 WindowEngine 的聚合器不由旧快照格式序列化。
- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 已有原子 SpatialAnalyzer::update、区域进入／离开和按帧 dwell。所查 TrackSample 是 ID、bbox、类别，页面未见 footprint、covariance、segment_id 或 checkpoint。
- [robust_stats 0.2.2](https://mooncakes.io/docs/hxiuzheng/robust_stats@0.2.2) 已有 StreamingWindow、aggregate_window_summary 和通用数值汇总，所查页未见显式足迹或片段接口。

通用窗口、原子更新和快照已有实现。本批补充原始视觉测量候选、精确片段足迹确认序列与报告帧分窗共同事务、完整共同 CP 的视觉域组合；结论限定于上述版本和已查页面。
