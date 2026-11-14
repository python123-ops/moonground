# 同足迹证据确认序列

在普通测量的“米制凸区域的位置证据”中，选择“逐目标混合足迹”，展开“同足迹证据确认序列”。它直接使用当前普通测量、区域配置和逐帧分配原文，无需先计算独立足迹结果。

序列只延续同目标、同片段、同区域、同显式形状、连续同为 Inside 或 Outside 的可用样本。它记录模型证据样本，不记录到访、离开、占用或实际停留，也不推断采样间的运动。

## 选项与确认

默认选项为：

```json
{ "max_gap_us": "500000", "confirmation_us": "1000000", "min_samples": "2" }
```

三项均为规范十进制 Int64 字符串。帧间隔上限须大于零，确认跨度允许零，最少样本数须大于零。首个可用样本的样本数为 1，跨度为 0。只有同时达到最少样本数和确认跨度才取得资格；选项为一帧、零跨度时，首个可用样本即可达标。

样本跨度精确等于末样本时间减首样本时间。达到资格的序列继续列在当前状态中；仅第一次达标的帧带“本帧首次确认”标记，不为同一当前序列再添一行。

区间支持描述当前米制模型位置及显式形状。离散样本同为 Inside 不能证明其间持续在区域内，Outside 序列也不能证明其间从未进入。因此样本跨度不能作为实际停留时间、实际连续在内时长或概率置信区间使用。

## 结束与重新开始

旧序列按以下优先顺序结束。同一帧可结束旧序列，并从当前合法样本启动新序列。

| 原因                   | 含义                                                           |
| ---------------------- | -------------------------------------------------------------- |
| gap_exceeded           | 当前与上一帧时间差达到上限，等于上限也中断。                   |
| segment_closed         | 原测量明确关闭旧片段。                                         |
| segment_changed        | 当前目标片段改变，不能沿用旧身份。                             |
| missing_target         | 原核心测量帧没有当前目标。                                     |
| unavailable_evidence   | 原证据不可用，包括初始化、不确定性超限、异常观测和足迹未分配。 |
| shape_changed          | 显式形状类型、半径、顶点值或顶点顺序改变。                     |
| indeterminate_evidence | 当前区域关系未确认，不把它改成 Outside。                       |
| decision_changed       | Inside 与 Outside 确认结果改变。                               |

形状比较使用实际数值和有序顶点，正负零视为相同。不取凸包、不重排顶点、不估计朝向，也不保留上一帧分配。位置与协方差可以逐帧变化，但区域及 k 固定在监测配置中。

投影拒绝目标没有当前米制片段，原核心 FrameResult 不含该目标；已有序列通常以 missing_target 结束，更高优先级的间隔或片段关闭仍优先。JSON 结果的原 evidence 保留 rejected_projection 行，不能为它伪造关闭身份或分配。

## 当前结果和下载

唯一的序列表跟随上方普通测量滑块，列出当前序列和本帧结束记录。它分别展示首末时间、精确样本数、样本跨度、合取资格、结束原因和结束帧时间。行悬停保留核心原记录。折叠或切换物理足迹显示时不生成表格明细，已完成结果保留。

“下载整批序列与最终检查点”保存 moonground-footprint-runs.json，包含全部 frames 和完整最终 checkpoint。Web 不提供检查点导入或所选帧检查点按钮；最终检查点可由纯函数或命令行恢复。它保存当前序列、精确形状、末样本锚点与配置，不保存全部已结束历史，也不认证历史样本的真实性。

修改序列选项只清除本功能结果；修改区域、逐帧分配、普通原始输入或实际测量载荷使依赖结果失效。相同原文重算且测量全文相同可重新绑定。统一圆盘、统一凸足迹、速度、过线和健康配置编辑不清除本功能结果；切换显示不计算、不清除、不取消。准备中的编辑、示例和普通测量重算会取消旧任务，迟到结果不能覆盖新输入。同一依赖下计算失败保留已显示结果。

## 原文接口

JavaScript 纯函数 moonground_footprint_runs 接收：

```json
{
  "source": "{\"position\":\"原区域配置 JSON 原文\",\"options\":\"原序列选项 JSON 原文\"}",
  "frames": "逐帧 wrapper NDJSON 原文"
}
```

每行沿用逐目标混合足迹的两个原文字符串：

```json
{
  "measurement": "原 schema 0.2 测量帧 JSON 原文",
  "assignments": "同帧 timestamp_us 和 footprints 文档 JSON 原文"
}
```

浏览器只封装字符串和移除 NDJSON 行终止符，不解析、重写或过滤用户数值及目标。每份分配须与原测量一一对应，由核心核对时间、目标、片段、形状、全部原位置数值规则和容量。

返回值为 {frames, checkpoint}。每帧 kind 为 footprint_run_frame，evidence_scope 为 current_target_footprint_confirmed_sample_runs，包含 evidence、active、confirmed 和 closed。时间、样本数和跨度均为精确十进制字符串。checkpoint 的 kind 为 footprint_run_checkpoint，schema_version 为 0.1.0。恢复源为 {resume:完整检查点对象}；命令行入口为 --footprint-runs 和 --footprint-runs-checkpoint。

核心先验证整帧、数值与计数上限，再共同提交。错误保留原状态，纯函数不返回部分帧；CLI 保留完整成功前缀并以 2 退出。检查点恢复会重建区域并重算末样本证据，核对形状、片段、时间、计数、资格和跨区域锚点一致性，不信任外部传入的判定。

Web 输入与输出各限 8 MiB UTF8。核心 source、每个 wrapper 及内部文档各限 1 Mi UTF16 单元；完整恢复检查点限 8 Mi。批次最多 5000 行、总 frames 8 Mi，外层请求 16 Mi，含最终检查点的全部输出 8 Mi。原 max_tracks × 所有区域边数 ≤ 65536 和混合足迹支持投影工作上限保持不变；合法核心流不代表完整纯函数输出或扩展检查点一定容得下。

## 本批官方生态核查

本批采用三次限定 Mooncakes 的查询，并核对以下三个官方版本的公开 API：

- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 已有 RegionEntered、RegionExited(dwell_frames)、区域占用、累计按帧停留和原子 SpatialAnalyzer::update。所查 TrackSample 接口是 track_id、bbox、class_id，没有 covariance 或 segment_id。
- [Moon-Kalman 0.2.1](https://mooncakes.io/docs/Lyllyl789/moon-kalman@0.2.1) 已有标量 ConfidenceBand、UncertaintyBox3D、SafetyEnvelope 位置与协方差检查。所查页未见区域停留接口。
- [mooncollider 0.2.1](https://mooncakes.io/docs/uiwcvb/mooncollider@0.2.1) 已有 contains、overlaps、Shape::support、SAT/GJK 和连续碰撞检测。所查页未见协方差或停留接口。

普通区域进入、离开、停留和形状判定已有实现。本批补充当前协方差三态证据、精确 Int64 时钟、片段与显式形状绑定、未知证据中断及完整当前状态恢复的组合契约；没有把普通事件或计时作为新增算法。结论限于上述版本和页面。
