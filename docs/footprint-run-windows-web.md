# 足迹确认序列的报告帧分窗

在“逐目标混合足迹”的“同足迹证据确认序列”内展开“普通测量的确认序列分窗”。本入口直接读取当前普通测量、区域、逐帧显式分配和序列选项，再共同计算序列与分窗；无需先点击任何序列计算按钮。

它独立于“独立下游／原始联合／健康门控联合”三种显示模式，使用普通测量滑块，不读取或覆盖那些结果。原始联合和健康门控的原始流不能直接作为本入口输入；这里接收的是原 schema 0.2 测量输出和精确足迹分配。

## 确认和结束如何归窗

窗口选项为：

```json
{ "window_us": "500000", "origin_us": "0" }
```

窗口宽度须为正，原点非负，均使用规范十进制 Int64 字符串。窗口为半开区间；首次确认和结束按报告它们的输入帧时间归窗，不按序列首样本、上次样本或推算的运动时间归窗。位于窗口右边界的帧属于下一窗口。

每区域分别累计首次确认 Inside、首次确认 Outside，并按八种原结束原因分别累计“已确认／未确认”结束数。仍在延续的已确认序列不重复计数；未确认结束不会被记成首次确认。同帧结束旧序列并确认新序列时，两项都计入。

开窗活动数、开窗已确认数和本窗新起序列数辅助核对状态流。它们与首次确认及结束数的平衡由核心验证，不代表区域占用、到访率、连续在内时间或实际停留。

首个输入才建立当前窗口，恢复起点本身不计作输入。跨窗时只返回上一个有输入的关闭窗口和新的当前窗。中间未输入的窗口计入 unobserved_windows，不逐个展开、不补写零计数，也不据此推断相机有效观察时间。当前窗的输入帧数和首末时间描述实际提供的帧；空测量帧仍是输入。

## 可执行的五输入示例

下面生成可分别粘贴到普通原始流、区域、显式分配、序列选项和窗口选项编辑器的 inputs。先运行普通测量，再点击“按普通测量分窗确认序列”。目标 1 在区域内、目标 2 在区域外；600000 μs 更换目标 1 的形状，800000 μs 显式不分配该目标，1000000 μs 移除两目标，之后从新片段恢复。2000000 μs 跨过一个无输入窗口。

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

## 提交、检查点和界面依赖

新的 FootprintRunWindowMonitor 独立拥有原 FootprintRunMonitor；每帧先完整验证原测量与分配，再在候选状态上更新序列和窗口。数值、分配、容量或计数错误不推进任何一侧。窗口不是接受外部预计算序列报告的通用计数器。

“下载整批分窗与完整最终检查点”保存 moonground-footprint-run-windows.json，包含全部 frames 和最终 checkpoint。每帧的 runs 保持原 footprint_run_frame，statistics 包含当前窗、本帧关闭窗和未观察窗口数。表跟随普通滑块，下载始终包含整批与批末检查点。

检查点 format 为 moonground.footprint-run-windows，checkpoint_version 为字符串 1，包含完整旧 runs 检查点、window_us、origin_us、baseline_timestamp_us 和可空 current_window。它共同恢复序列与窗口，不拥有上游运动会话。恢复时需另行从相同水位恢复上游，提供全部更晚原测量与显式分配。已启动的序列起点不追补历史确认；后续结束仍按实际确认资格分别累计。

恢复验证原 monitor、精确时钟、桶边界、各区域／结束原因顺序、计数容量、活动／确认流平衡及稀疏样本见证。这些检查约束当前可验证事实，不重建全部历史。界面本批不提供检查点导入或所选帧检查点。

结果绑定普通原始流和实际测量载荷、区域、分配、序列选项、窗口选项。实际编辑使分窗结果失效；相同原文重算且测量全文相同可重新绑定。普通重算取消旧准备，迟到请求不能覆盖新草稿，旧 finally 不能清除新任务。相同依赖下失败保留成功结果。健康、其他联合结果和统一形状配置不属于依赖，切换原三种序列显示模式也不计算或清除本统计。折叠时不生成分窗表格明细。

## 原文接口和限额

JavaScript 纯函数 moonground_footprint_run_windows 接收 JSON 字符串请求：

```json
{
  "source": "{\"runs\":\"原 v26 序列源 JSON 字符串\",\"window\":\"窗口选项 JSON 原文\"}",
  "frames": "原 schema 0.2 测量与显式分配的 wrapper NDJSON"
}
```

runs 源仍为 {position:原区域配置字符串, options:原序列选项字符串}，每个帧 wrapper 为 {measurement:原测量输出字符串, assignments:原精确分配字符串}。完整恢复源为 {resume:完整新检查点对象}。浏览器只包装字符串，不重写用户数字、时间或目标片段，不过滤分配。CLI 对应 --footprint-run-windows 和 --footprint-run-windows-checkpoint。

返回 {frames, checkpoint}；帧 schema_version 为 0.1.0、kind 为 footprint_run_window_frame。窗口右界在数学值超过 Int64 最大值时为 null，其余精确时间及计数使用十进制字符串。

Web 输入和输出各限 8 MiB UTF8；核心源 8 Mi UTF16 单元加恢复 envelope、完整检查点 8 Mi，窗口选项及每个 wrapper／内部测量／分配文档各 1 Mi。批次 frames 共 8 Mi／5000 帧，外层请求 16 Mi，包含最终检查点的全部输出 8 Mi。原足迹几何、状态及支持工作上限保持不变。

## 与已查官方生态能力的关系

本批有界执行三次 Mooncakes 限定查询，核对三个官方版本页面：

- [MoonEventTime 0.2.1](https://mooncakes.io/docs/Ag108/MoonEventTime@0.2.1) 已提供 keyed tumbling／sliding／session、精确整数、自定义聚合、水位线、资源上限和溢出原子拒绝。旧 Engine 支持 canonical 版本化快照／恢复；页面明确新泛型 WindowEngine 当前没有快照或通用 JSONL CLI。
- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 已提供原子 SpatialAnalyzer::update、RegionEntered／RegionExited、区域 entries／exits 和按帧 dwell。所查 TrackSample 是 ID、bbox、类别，页面未见 covariance、segment_id 或显式 footprint 接口。
- [robust_stats 0.2.2](https://mooncakes.io/docs/hxiuzheng/robust_stats@0.2.2) 已有 StreamingWindow、aggregate_window_summary 和数值汇总接口。

通用分窗、有界聚合、整数计数、原子更新和快照均已有实现。本批补充严格视觉足迹序列的首次确认与八种结束原因适配，以及原 monitor 和窗口共同更新、完整源域检查点的组合；结论限于上述版本和已查页面。
