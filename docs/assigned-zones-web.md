# 逐目标混合足迹的区域证据

普通测量下方的物理足迹显示新增“逐目标混合足迹”。它与统一圆盘、统一凸足迹分别保存输入、结果和准备任务，共用现有摘要、选中各边和不可判定表。切换只改变显示，不计算、不沿用其他策略的形状，也不清除已完成结果。

先完成普通测量并填写原 [区域配置](zones-web.md)，再填写逐帧分配 NDJSON。每行与一行原普通测量一一对应；时间和片段必须使用该帧核心报告的精确字符串：

```json
{
  "timestamp_us": "1000000",
  "footprints": [
    {
      "track_id": 1,
      "segment_id": "1",
      "shape": { "kind": "disk", "radius_m": 0.25 }
    },
    {
      "track_id": 2,
      "segment_id": "2",
      "shape": {
        "kind": "convex",
        "vertices_offset_m": [
          [-0.25, -0.25],
          [1, -0.25],
          [1, 0.25],
          [-0.25, 0.25]
        ]
      }
    }
  ]
}
```

同帧可以混合不同圆盘半径和不同凸形。圆盘以当前模型锚点为圆心，有限非负半径允许为零；凸形顶点是相对原锚点、已按 ground 坐标轴定向的米制偏移，原点须在闭凸形内，可以位于边或顶点。沿用 [固定凸足迹](footprint-zones-web.md) 的严格几何和数值域，不自动取凸包、重定中心、从框估计尺寸或从速度推断朝向。

“生成待审混合分配示例”显式读取每帧核心已接受的时间、目标和片段，交替填写固定 0.25 m 圆盘和固定非对称凸形。它生成可编辑的草稿，不估计目标物理形状。空测量帧也有一行带精确时间、空 `footprints` 的文档；不自动省略行。投影拒绝行没有片段 ID，示例不为它生成分配；用户填写的原文仍完整交核心验证。

## 本帧绑定与缺失的含义

每个分配文档包含自己的精确 `timestamp_us`。即使两帧目标和片段相同，也不能把前一帧文档直接用于后一帧；核心先核对时间，再核对每个 `(track_id, segment_id)`。

- 当前 Ready 目标有合法分配：输出该目标、各区域的物理足迹证据。
- 当前 Ready 目标没有分配：每个目标产生一行“足迹未分配”，原因为 `missing_footprint`，不按区域重复，不回退到点或默认形状。
- 当前非 Ready 目标可以有精确绑定的合法分配，但保持原初始化、不确定性超限、异常观测或数值不可用原因，不计算物理支持；没有分配也优先保留原位置原因。
- 重复目标、旧片段、额外或已消失目标、只有关闭记录而未报告的目标、错误时间、未知字段或形状使整批报错。投影拒绝没有当前片段，不能给它绑定足迹。

分配只服务一次当前帧求值，不在后续帧保留映射，也没有检查点。同一个 track ID 开启新片段后，必须重新使用新片段 ID。独立的合法帧与分配对可以重复或乱序求值；这里不建立新的全局时钟或连续事件状态。

核心先检查原位置证据的全部数值规则，即使某个 Ready 目标缺少足迹，也不能用缺失分配掩盖原位置错误。有效输入的原位置区间与法向标准差保持不变。

## 结果与原文协议

摘要显示实际 `shape_kind`：圆盘列出半径，凸形列出顶点数。选中一行后，共用的各边表分别展示原位置区间、带符号物理支持和合成区间。圆盘的物理支持是 `[-r,r]`，凸形两侧可以不对称。核心仍按所有合成上界 ≤ 0 确认在内、某个下界 > 0 确认在外，其余未确认；角点附近的未确认不表示相交。区间不是概率置信区间，也不认证实际观测轮廓。

结果跟随原普通测量滑块。隐藏或折叠时不生成各边明细，行悬停与整批下载保留核心原值，表内六位有效数字仅用于阅读。浏览器不计算支持函数、协方差或几何判定。

纯函数 `moonground_assigned_zone_evidence` 接收 `{source: rawZoneConfiguration, frames: rawWrappedNDJSON}`。source 直接是原区域配置，每个 wrapper 只封装两份原文：

```json
{
  "measurement": "原 schema 0.2 测量帧 JSON 原文",
  "assignments": "该帧 timestamp_us 与 footprints 文档 JSON 原文"
}
```

浏览器不解析或重写用户数字，不过滤额外目标，不把一张全局映射自动应用到多帧。只在封装时移除 NDJSON 行终止符，并检查文档行数；时间、身份和完整原文由核心校验。

返回 `{frames}` 的 kind 为 `assigned_zone_evidence_frame`，`evidence_scope` 为 `model_position_halfplane_bands_plus_current_target_footprints`。圆盘保留 `radius_m`，凸形保留 `vertices_offset_m`，不为圆盘伪造顶点。下载文件为 `moonground-assigned-zone-evidence.json`；命令行入口为 `--assigned-zone-evidence`。纯函数错误不返回部分帧，CLI 流式错误保留已成功的完整前缀并以 2 退出。

修改逐帧分配只清除该策略结果。修改共享区域、普通原始输入或实际测量载荷使相应结果失效；同原文重算且测量全文相同可重新绑定旧结果。统一足迹、速度、过线或健康输入编辑不会清除逐目标结果。准备期间的编辑、示例或上游重算取消旧任务，迟到结果不能覆盖新输入；相同依赖下计算失败保留已显示结果。

Web 输入和输出各限 8 MiB UTF8；核心 source、每个 wrapper、内部文档和原测量帧各限 1 Mi UTF16 单元，转义计入 wrapper。批次最多 5000 行、总输入 8 Mi UTF16 单元，外层请求 16 Mi，整批输出 8 Mi。原 `max_tracks × 所有区域边数 ≤ 65536` 保持不变；混合形状每次最多 65536 次物理边扩展、2097152 次原边支持投影，成本高于单一统一形状的共享预计算。

## 本批官方生态核查

本批核查了以下三个官方版本的公开接口：

- [mooncollider 0.2.1](https://mooncakes.io/docs/uiwcvb/mooncollider@0.2.1) 已有按刚体 ID 保存 shape、`World::add_body/body` 及凸形支持。普通逐对象形状映射已有实现。
- [moon_rapier 0.5.2 collision](https://mooncakes.io/docs/Milky2018/moon_rapier@0.5.2/collision) 已有 collider handle 的插入、查询和 parent 关联；`round_convex_hull/round_convex_polyline` 已接受 `border_radius`，圆角凸形本身也已有接口。
- [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 的 `TrackSample::new(track_id,bbox,class_id)` 和 `SpatialAnalyzer::update(frame_id,samples,lost,removed)` 支持目标、区域和生命周期分析；所查页没有 segment_id 或 covariance。

所查接口未见直接将当前 Ready 米制位置及完整协方差，与逐帧精确时间和目标片段绑定的显式混合足迹组合，并区分 missing、stale、duplicate 和 extra 的接口。本批增量是该测量与身份契约，补齐不同形状需由调用者外部分组的使用缺口；不把普通映射、多 collider 或圆角凸形作为新增算法。结论限于上述版本和页面。
