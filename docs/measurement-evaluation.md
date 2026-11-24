# 对照米制真值评估测量结果

将 MoonGround 输出的位置、速度与独立参考数据按时间和身份对齐，计算误差、偏差和可用率。现场参考位置应来自独立测量，评估点与标定拟合点分开；位置使用同一地面坐标系的 m，速度使用 m/s。

## 库接口

导入 `python123-ops/moonground/evaluation`，用 `ReferenceSample::new(track_id, position_m, speed_mps?)` 提供参考样本。速度未知时省略 `speed_mps`，零速度通过 `speed_mps=0.0` 明确给出。

`EvaluationSession::new(session_id, max_tracks?, max_samples?)` 创建评估器。`update(frame, reference_timestamp_us, references, projection_failures?)` 消费 `motion.FrameResult`，返回累计 `EvaluationReport`；`report()` 读取摘要，`fork()` 建立独立分支。

从 `MeasurementFrame` 接入时传入 `frame.motion`，另将 `frame.projection_failures.map(failure => failure.track_id)` 交给 `projection_failures`。投影拒绝身份须与运动结果身份分离。

时间戳使用精确 Int64 微秒，同一对记录必须完全相等，后续帧严格递增。参考 `track_id` 直接对应输出身份；外部标注使用其他身份时，由调用方先提供明确映射。评估器按这些身份对齐。

位置误差是估计位置与参考位置的欧氏距离，报告 MAE、RMSE、最大误差及有符号 x/y 平均偏差。速度误差为报告的 `speed_mps` 减参考速度，报告 MAE、RMSE、最大绝对误差及有符号平均偏差。

- 位置采用 `initializing`、`ready`、`uncertain` 中本帧新鲜接受的位置。
- 速度采用 `ready` 且具有参考速度的样本。预热或质量未就绪的速度保持不可用。
- 位置可用率的分母是所有参考位置；速度可用率的分母是所有显式参考速度，均包含对应的缺测和拒绝。
- `counts` 中各状态及 `missing` 针对参考样本计数；`without_reference` 单列没有参考的测量，不参与误差统计。
- 没有可评分样本时，误差、最大值及偏差为 `null`；有参考而全部缺测时可用率为零，没有对应参考时可用率为 `null`。

每帧完整校验后共同提交计数、统计量和时间水位，失败可修正同一时刻重试。默认每帧最多 4,096 个测量／参考身份，测量总样本和参考总样本各最多 10,000,000；`max_tracks` 可设为 1..4,096，`max_samples` 可设为正 Int32。常驻统计状态不保存样本历史；每帧临时映射受目标容量限制。RMSE 使用缩放平方和，处理有限的大、小误差。

## 两个日志文件的评估

已有 `--stream` 输出可直接作为测量文件。参考文件按行保存：

```json
{"timestamp_us":"400000","samples":[{"track_id":1,"position_m":[0,0],"speed_mps":0}]}
```

两个文件各自按时间严格递增。工具按时间做完整外连接：参考独有时刻补空测量帧以记录缺测，测量独有时刻使用空参考帧并计为没有参考。输出的 `alignment` 保留三类帧数。

```sh
moon build cmd/main --target native --release --deny-warn
python examples/evaluate_measurements.py --binary _build/native/release/build/cmd/main/main.exe --measurements examples/measurement-evaluation-measurements.ndjson --references examples/measurement-evaluation-reference.ndjson --output _build/evaluation.json
```

该工具使用 Python 标准库，保留当前两条日志记录，并将对齐输入暂存到临时文件；临时磁盘用量随日志增长。指标由原生 MoonGround 计算。报告记录输入、执行文件和适配脚本的 SHA-256、实际配置及处理耗时，完整生成后才替换输出文件。输入错误、执行失败或超时保留已有输出；输入文件和执行文件不能作为输出目标。`--timeout` 默认 300 秒，约束完成日志对齐后的原生计算。

仓库示例是合成数据：测量位置故意偏移 `(0.1, 0.2) m`，并保留一帧缺测与一帧没有参考的输出。位置 RMSE 约 `0.223607 m`，位置可用率 `0.75`；速度可用率 `0.25`，可评分速度误差为零。

## 原文 CLI 与 JavaScript

`--evaluate-measurements` 首行是 `{"session_id":"...","max_tracks":4096,"max_samples":10000000}`，后续每行是：

```json
{"measurement":{"schema_version":"0.2.0","session_id":"example","timestamp_us":"0","tracks":[],"closed_segment_ids":[],"uncertainty_scope":"conditional_on_fixed_calibration_camera_and_anchor"},"reference":{"timestamp_us":"0","samples":[]}}
```

`measurement` 使用原测量输出完整格式；`reference` 只含精确时间和样本。CLI 在 EOF 输出一份累计摘要，晚阶段错误退出 2 并不输出摘要。它接受 LF、CRLF 和无末尾换行。默认物理行上限 1 MiB，`--max-line-bytes` 最多 16 MiB；每份 JSON 仍受 1 Mi UTF-16 单元、深度 32 限制，重复键、未知字段和非有限／非零下溢数字拒绝。

`codec.measurement_evaluation_json` 及 JavaScript 导出 `moonground_measurement_evaluation` 接受 `{"source":"配置原文","frames":"逐行包装帧原文"}`，返回同一摘要。纯批次外层最多 16 Mi UTF-16 单元，帧文本最多 8 Mi、5,000 行。原生流不受纯批次数量上限限制，保留配置的总样本容量。

## 显式验收门槛

`0.42.0` 增加 `AccuracyRequirements::new(min_samples~, min_coverage~, max_mae?, max_rmse?, max_error?)` 和 `EvaluationSession::assess(position?, speed?)`。同一份累计统计可应用不同门槛，调用不改变累计状态。位置上限使用 m，速度上限使用 m/s；至少选中一个量，每个量至少配置一项有限、非负的误差上限。

样本量检查采用该量实际进入误差统计的样本数，速度仍只取带参考的 `ready` 样本。样本数和可用率取包含等号的下界，误差取包含等号的上界。没有误差统计时对应的 `actual` 为 `null`，检查失败。`AcceptanceReport` 同时包含原 `EvaluationReport`、整体 `accepted` 和逐项 `checks`，未选择的量不参与判定。

```mbt check
///|
test "empty measurements cannot satisfy accuracy requirements" {
  let evaluator = @evaluation.EvaluationSession::new("acceptance-example")
  let limits = @evaluation.AccuracyRequirements::new(
    min_samples=1,
    min_coverage=0.95,
    max_rmse=0.1,
  )
  assert_false(evaluator.assess(position=limits).accepted)
}
```

独立文件工具增加 `--requirements`；预编译发行包内置相同脚本，并通过管理器的 `evaluate` 命令调用：

```sh
python examples/evaluate_measurements.py --binary _build/native/release/build/cmd/main/main.exe --measurements examples/measurement-evaluation-measurements.ndjson --references examples/measurement-evaluation-reference.ndjson --requirements examples/measurement-acceptance-requirements.json --output _build/acceptance.json
```

仓库门槛文件用于上文的合成偏移示例。两份日志使用完整外连接，额外参考时刻的缺测会降低可用率，额外测量时刻不会充当参考数据。门槛未达到时仍保存完整报告并退出 3；输入或执行错误退出 2，保留已有输出。省略门槛文件时，原有统计输出与退出行为保持一致。

原文入口 `--accept-measurements` 的首行增加 `requirements`，其值为 `{"position_m":{...},"speed_mps":{...}}`。每项包含 `min_samples`、`min_coverage`，以及任选的 `max_mae`、`max_rmse`、`max_error`；省略未启用的误差上限。后续帧使用原来的 `{measurement,reference}` 协议，在 EOF 输出 `measurement_acceptance`，包含 `requirements`、`checks`、`accepted` 和完整 `evaluation`。晚阶段输入错误不输出判定摘要。

`codec.MeasurementAcceptanceReplay` 与纯函数 `codec.measurement_acceptance_json`、JavaScript `moonground_measurement_acceptance` 使用同一规则；纯批次容量与原评估适配器一致。门槛文件允许排版空白，最大 64 KiB，原始数字文本交给 MoonGround 校验；重复键、未知字段、非有限及非零下溢数字拒绝。

参考数据的坐标系、时间同步、身份对应和测量方法应随现场数据保留。误差与可用率门槛执行软件判定，独立参考数据的获取和测量条件由现场验收记录说明。安装后的完整命令见 [CLI 日志验收说明](cli-evaluation.md)。

## 复现数值检查

```sh
node web/build.mjs
python validation/measurement_evaluation_verify.py --binary _build/native/release/build/cmd/main/main.exe --web
python validation/measurement_acceptance_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output _build/measurement-acceptance.json
```

独立参考将匹配样本离线展开，用 160 位 Decimal 直接求总体误差、平方和及偏差，结果见 [数值记录](../validation/measurement-evaluation-results.json)。记录中的合成尺度压力场景核对软件计算；现场精度使用独立实测参考数据评估。
