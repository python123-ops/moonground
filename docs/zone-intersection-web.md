# 当前模型位置椭圆与凸区域相交

在原“凸区域位置证据”中展开“位置椭圆与凸区域相交”，先运行普通测量，再点击“计算位置椭圆相交”。新入口复用上方区域原文及普通测量帧，使用区域的 sigma_multiplier；无需先计算逐边证据，不增加输入流、状态会话或检查点。

结果跟随普通滑块，每个 Ready 目标和区域显示一行：Q 最小值上下界、相交判定、候选边、参数 t 和舍入后的候选坐标。初始化、质量超限、观测拒绝及投影拒绝沿用原不可判定原因；缺测不补点、不读取隐藏预测。表格显示六位有效数字，悬停行及整批下载保留核心原值。

## 与逐边证据分别解释

位置椭圆使用当前米制均值 μ、完整二维 SPD 协方差 C 和 k，定义为闭集 E={(x−μ)ᵀC⁻¹(x−μ)≤k²}。新计算考察原闭凸区域 Z 中二次型的全局最小值 Q。核心给出包住该最小值的上下界，再与原二进制浮点 k 的精确实数平方界比较：

- Q 下界严格大于 k² 上界：确定不相交。
- Q 上界小于或等于 k² 下界：确定有公共点。
- 其余：相交关系未确认。

它判断是否有公共点，不判断椭圆完整包含于区域，也不表示概率、物理足迹、连续占用或到访。接近相切时可能保持未确认；不会用经验 epsilon 把边界强行判成不相交。

旧逐边支持证据保留原行为。角点附近，椭圆与多边形可以不相交，却没有单独一条原区域边给出分离证据。例如单位正方形、μ=(1.125,1.125)、C=diag(0.015625,0.015625)、k=1，精确 Q=2；旧逐边关系未确认，新几何判定可以确定不相交。

候选边按输入顶点顺序从 0 编号。t 是核心选定的二进制浮点边参数；返回位置仅是该候选实数位置的舍入诊断坐标，不是精确最近点。均值被证明位于区域内时 Q=0，边编号和 t 可以为空。

## 可执行的普通测量示例

以下 inputs.measurement 放入上方普通输入，inputs.position 放入原区域编辑器。相同目标观测在 0 和 1 μs 输入，普通滤波实际输出的协方差由核心计算；角点目标仍能呈现旧逐边未确认、新相交判定不相交的区别。

```javascript
const session = {
  session_id: "ellipse-zone-web",
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
const observations = ["0", "1"].map((timestamp_us) => ({
  timestamp_us,
  observations: [
    { track_id: 1, point: [1.125, 1.125], covariance: [0.03125, 0, 0.03125] },
    { track_id: 2, point: [0.5, 0.5], covariance: [0.03125, 0.01, 0.03125] },
    { track_id: 3, point: [2, 2], covariance: [0.03125, 0, 0.03125] },
  ],
}));
const inputs = {
  measurement: [session, ...observations].map(JSON.stringify).join("\n") + "\n",
  position: JSON.stringify({
    session_id: "ellipse-zone-web",
    max_tracks: 4,
    zones: [
      {
        zone_id: "square",
        vertices_m: [
          [0, 0],
          [1, 0],
          [1, 1],
          [0, 1],
        ],
        sigma_multiplier: 1,
      },
    ],
  }),
};
inputs;
```

以下代码在上述 inputs 后执行；api 是 moonground.mjs 模块命名空间。它实际生成普通测量，再分别调用旧逐边证据和新相交入口。浏览器界面直接传递用户原文；这里的对象仅用于构造固定示例。

```javascript
const readResult = (text) => {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value;
};
const raw = inputs.measurement.trimEnd().split("\n");
const { handle } = readResult(api.moonground_create(raw[0]));
let measurementFrames;
try {
  measurementFrames = raw
    .slice(1)
    .map((line) => readResult(api.moonground_update(handle, line)));
} finally {
  api.moonground_close(handle);
}
const request = JSON.stringify({
  source: inputs.position,
  measurements: measurementFrames.map(JSON.stringify).join("\n") + "\n",
});
const intersection = readResult(api.moonground_zone_intersection(request));
const faces = readResult(api.moonground_zone_evidence(request));
const example = { measurementFrames, intersection, faces };
example;
```

## 独立结果与原文校验

“下载整批椭圆相交证据”保存 moonground-zone-intersection.json，只包含 frames，不创建 CP。它与旧点、圆盘、凸形或逐目标足迹、速度及健康门控结果分别保留。

共享区域或普通原始输入实际修改，会使相应结果失效。普通重算时取消未完成的下游任务；同原文且完整测量载荷逐字相同可以重新绑定已完成结果，载荷改变则需要显式重新计算。示例、文件和恢复输入替换也遵循原文依赖；迟到任务不能覆盖新草稿，旧 finally 不能清除新请求。相同依赖下计算失败保留上次成功结果。折叠时不生成表行。

纯入口 moonground_zone_intersection(JSON.stringify({source:原区域JSON字符串, measurements:原schema0.2测量NDJSON})) 返回 {frames}。CLI 为 --zone-intersection。每帧 schema_version 为 0.1.0、kind 为 position_zone_intersection_frame、evidence_scope 为 model_position_ellipse_convex_zone_intersection，保留原 session_id 和规范 Int64 时间字符串。

evidence 逐行包含 track_id、segment_id、zone_id、sigma_multiplier、minimum_quadratic_lower／upper、witness_edge_index、witness_fraction、witness_position_m 及 decision。decision 为 disjoint／intersects／indeterminate。浏览器只格式化这些核心字段，不重算距离、矩阵逆或判定，不提前解析配置以舍入原始数值。

每个配置仍允许 1—16 个严格凸区域、每区最多 32 条边、最多 10000 个目标，max_tracks × 所有区域边数之和 ≤ 65536。配置与单帧各限 1 Mi UTF16 单元，深度 32；测量共 8 Mi／5000 帧，外层请求 16 Mi，整批输出 8 Mi。浏览器输入和输出各限 8 MiB UTF8。

核心对原始二进制浮点输入计算外向包围界。有限且 SPD 的输入仍可能超出可支持的数值域：若中间界不可表示、条件数使行列式区间包含零或算术溢出，会返回明确错误，不修复协方差或输出猜测判定。一般尺度变化使用二次幂缩放；精度与支持域以实际验证记录为准。
