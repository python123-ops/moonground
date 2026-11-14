# 原始测量与足迹确认序列联合计算

在“逐目标混合足迹”的“同足迹证据确认序列”中，将显示模式从默认“独立下游”切换为“原始联合”。两种模式保留各自的结果和任务，共用一张当前／结束序列表；切换只改变显示。

联合入口直接读取上方普通测量的原始配置和后续原始像素／米制观测，以及当前区域、逐帧分配和序列选项。它不读取普通测量已经输出的帧，也不覆盖普通结果、独立足迹或独立序列结果。联合结果有自己的回放滑块，普通滑块不改变它的选帧。

## 先发现身份，再显式绑定

“预览首帧候选身份”从当前原始配置／恢复起点准备第一帧，只显示核心实际返回的 session_id、timestamp_us、track_id、segment_id 和 status。预览不提交任何联合状态、不预留身份，也不自动填入形状或分配。

逐帧分配仍使用 [混合足迹](assigned-zones-web.md) 的精确时间与目标片段契约。可先使用现有普通测量查看完整候选轨迹，按滑块读取后续新片段，再使用“生成待审混合分配示例”形成可编辑草稿，最后从相同原始起点联合重放。首帧预览不代替后续各帧身份核对。

联合核心会重新准备测量，并核对当前分配的精确片段；浏览器不补 ID、不把旧片段改成新片段、不过滤额外目标。编辑预览 JSON 或沿用错误草稿不能改变正式计算的候选身份。预览只执行第一帧，后续原始观测仍由正式联合重放逐行验证。

## 同一帧共同提交

联合会话先在候选测量上生成真实片段身份，再检查原位置数值、显式足迹、区域证据、序列状态和容量。全部成功才共同推进测量与序列；失败不会提前消耗新片段、推进测量时间或更新序列。同一时间可在纠正分配后重试。

可复用的 typed API 提供 FootprintRunSession::prepare_pixel / prepare_ground。返回的 opaque preparation 可读取深分离的 measurement()，再 commit(FootprintAssignments)。失败可使用同一候选重试；成功后不能重复提交，另一候选已推进原 owner 后旧候选失效。Web 的纯首帧预览不是该 token，每次正式重放都重新计算和验证。

同足迹、同目标片段、同区域和同类 Inside／Outside 样本的确认条件、八种结束原因及精确样本跨度均沿用 [独立确认序列](footprint-runs-web.md)。Indeterminate 和不可用证据会中断，样本跨度不表示实际连续在内、到访、离开、占用或停留。

## 结果、检查点和输入变化

“下载联合结果与完整共同检查点”保存 moonground-footprint-run-analysis.json。每帧同时包含 measurement 和 runs，最终 checkpoint 包含原测量检查点与完整序列检查点，水位一致。Web 本批不提供检查点导入或所选帧检查点。

检查点恢复会验证共同会话与水位、片段、当前 Ready 质量、原始位置和上三角协方差、预热条件、样本数及必要时间见证的一致性；不认证全部历史观测。已启动的独立测量恢复起点不能悄悄接上全新序列监测器。此类组合会报错，实际续接在 API 使用完整共同检查点，不修改旧输入来掩盖失配。

联合结果绑定四份原文：普通原始流、区域配置、逐帧分配和序列选项。实际编辑任一份都会使相应结果与待请求失效。相同原文的普通测量重算、普通结果更换或统一足迹等其他配置修改不会清除联合结果。候选预览不使用分配，单独修改分配不会清除仍对应当前起点的预览。

预览与联合计算有独立的任务和消息。迟到的旧请求不能覆盖后续编辑，旧 finally 不能清除新任务。相同依赖下失败保留原成功结果。切换模式不计算、不清除、不取消任务，折叠时不生成序列表与候选明细。

## 原文接口

联合 JavaScript 纯函数：

```javascript
moonground_footprint_run_analysis(
  JSON.stringify({
    source: JSON.stringify({
      measurement: rawMeasurementSource,
      runs: JSON.stringify({
        position: rawZoneSource,
        options: rawRunOptions,
      }),
    }),
    frames: rawWrappedNDJSON,
  }),
);
```

各 source 变量是原 JSON 字符串。每行 wrapper 的 measurement 是原始观测，不是 schema 0.2 测量输出：

```json
{
  "measurement": "原始 timestamp_us、observations、lost、removed JSON 原文",
  "assignments": "原始 timestamp_us 与 footprints 文档 JSON 原文"
}
```

返回 {frames, checkpoint}。帧 kind 为 footprint_run_analysis_frame，measurement 保持原 schema 0.2 与诊断策略，runs 保持原 footprint_run_frame。共同检查点 format 为 moonground.footprint-run-analysis，checkpoint_version 为字符串 1，组件字段为 measurement 和 runs。完整恢复源为 {resume:完整共同检查点对象}。

首帧预览为 moonground_footprint_run_preview({source, frame}) 的 JSON 字符串请求，返回 {measurement}，不返回状态或检查点。CLI 对应 --analyze-footprint-runs、--analyze-footprint-runs-checkpoint 和 --preview-footprint-run。CLI 预览严格接收配置后恰好一帧；缺帧或多帧报错。Web 从已有多帧输入显式选取第一帧发送。

浏览器只包装原字符串和移除 NDJSON 行终止符，不预解析用户数字。核心 source 上限为 8 Mi UTF16 单元加恢复 envelope，完整检查点 8 Mi；每个 wrapper、内部帧和分配文档 1 Mi，frames 共 8 Mi／5000 行，外层请求 16 Mi，包含最终检查点的全部输出 8 Mi。Web 每次发送与接收各限 8 MiB UTF8。完整输出或检查点达到上限时会明确报错；流式 CLI 成功前缀与纯函数整批错误语义沿用项目约定。

## 本批官方生态核查

本批执行三次限定 Mooncakes 的查询，并核对三个官方版本页面：

- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 的 SpatialAnalyzer::update 已提供逐帧原子空间分析。所查 TrackSample 是 ID、bbox、类别，页面未见 checkpoint、prepare／commit 或 segment_id。
- [Moon-Kalman 0.2.1](https://mooncakes.io/docs/Lyllyl789/moon-kalman@0.2.1) 已有 KalmanND::checkpoint / restore_checkpoint，FilterCheckpoint 保存 state、covariance 和 Int timestamp。所查页未见足迹、segment_id 或 prepare／commit。
- [Fiducial Marker 0.1.1](https://mooncakes.io/docs/2515050242/fiducial_marker@0.1.1) 已有 CameraCalibrator 和含协方差的 ExtendedKalmanFilter6DOF predict／update。所查页未见上述共同事务或完整检查点接口。

原子更新、标定、滤波与检查点已有实现。本批补充原始米制测量候选、精确目标片段分配、同形状三态证据序列的共同提交与恢复契约；结论限于上述版本和公开 API 页面。
