# 共享标定误差下的地面面积比较

`calibration.HomographySensitivity` 增加 `polygon_area` 和 `compare_areas`，计算明确给出的凸多边形在地面的面积，以及同一标定参数模式对面积差、面积比的一阶贡献。它沿用[点对](calibration-sensitivity.md)、[长度](calibration-distance.md)和[角度](calibration-angle.md)的共享模式，适用于固定相机下的地面标记、设施区域与占地比例测量。顶点由调用方给出，不从图像分割或轨迹推断轮廓。

## 多边形与共享参数

每片输入含 3..64 个已经去畸变的二维像素顶点，按边界顺序排列，位于原标定的闭 ROI 内。顺时针和逆时针都可用；不要重复首顶点来闭合。像素多边形及实际 binary64 投影得到的地面多边形都须满足已有 ROI 的严格凸性规则：先按包围盒最大边长归一化，每条有向边与所有非端点顶点的绕向修正侧值必须大于 `1e-12`。因此重复、共线、凹形、自交及数值分辨率不足的多边形都会报错。这是几何可接受域，不是统计置信度。

面积 `area_m2` 始终为正。`signed_area_m2` 保留地面绕向，逆时针为正；反射标定可能翻转输入绕向。第一片减第二片得到 `difference_m2`，第一片除第二片得到正的 `ratio`。返回的地面顶点保持输入顺序。

模式基线为 `GroundCalibration::matrix()` 实际返回的归一化 H。每个 M_i 是九个行优先系数，包含 h22；模型为 `H + Σ M_i ξ_i`。ξ_i 均值零、方差一、彼此协方差零，在所有顶点和两片多边形间共享。调用方提供模式，不从残差估计协方差，也不把两片区域当成独立误差源。

例子中，像素三角形边长为 32 和 64，H 的两个尺度均为 0.125，地面面积分别为 8 m² 和 32 m²。共同尺度模式使面积响应为 2 m² 和 8 m²，交叉贡献为 16 m⁴，面积差为 −24 m²、模式标准差为 6 m²，面积比为 0.25、该共同尺度的一阶贡献为零。忽略共享项会得到不同的面积差和比值贡献。

## 面积导数与单位

设地面顶点为 P_j，参数模式 i 的点响应为 r_ij。记 `cross(a,b)=a_x*b_y−a_y*b_x`，索引按多边形闭合循环：

```text
S = 1/2 Σ cross(P_j, P_(j+1))
A = |S|
g_i = sign(S)/2 Σ [cross(r_ij, P_(j+1)) + cross(P_j, r_i(j+1))]
V(A) = Σ g_i²
C12 = Σ g1_i*g2_i
D = A1−A2             d_i = g1_i−g2_i
R = A1/A2             q_i = (g1_i−R*g2_i)/A2
V(D) = Σ d_i²         V(R) = Σ q_i²
```

面积、面积响应、面积差和相应标准差单位为 m²；方差及交叉贡献为 m⁴；面积比及其响应、方差和标准差均无量纲。交叉贡献允许为负，例如透视模式可使不同位置的两片面积反向变化。先形成差值和比值响应再求平方和，保留共同误差抵消。

实现以首顶点为锚点，先相减地面位置和模式响应，再计算三角扇面积及导数，减少大绝对坐标相消，并让共同平移在乘积前抵消。半叉积先缩半因子，避免仅因两倍面积溢出而拒绝有限面积；一般方向复用补偿叉积和缩放范数。求和与对比响应使用原补偿核。

零一阶贡献仍可能有高阶效应：共同无穷小转动的一阶面积响应为零，但 `I+ξM` 的行列式可含二次项。本结果不包含像素观测噪声、地面噪声底、镜头参数误差及其相关项，不提供概率覆盖率或区间，不修改轨迹、标定健康或检查点。

每个顶点继承原单点共享响应的有限投影及 Gram 数值域；这里不要求把所有顶点拼成大 Gram 矩阵。舍入后地面形状失去严格凸性、非有限中间量、非零乘除项下溢、面积或贡献上溢、非零面积比下溢等均返回 `GroundError`。即使两片各自方差可表示，差值方差仍可能溢出并报错。binary64 返回值没有认证误差界。

## MoonBit API 与协议

- `HomographySensitivity::polygon_area(pixels)` 返回 `CalibrationAreaSensitivity`：`signed_area_m2`、`area_m2`、`contribution_m4`、`std_m2`，以及防御性副本 `positions_m()` 和按原模式顺序的 `mode_responses_m2()`。
- `HomographySensitivity::compare_areas(first_pixels, second_pixels)` 返回 `CalibrationAreaComparison`：`first`、`second`、`cross_contribution_m4`、`difference_m2`、`difference_contribution_m4`、`difference_std_m2`、`ratio`、`ratio_contribution`、`ratio_std`。`difference_mode_responses_m2()` 和 `ratio_mode_responses()` 返回防御性副本。
- 严格原文入口为 `codec.calibration_area_json`；无状态 JS 桥为 `moonground_calibration_area`，失败返回 `{error: string}`。

公开签名见 [`calibration/pkg.generated.mbti`](../calibration/pkg.generated.mbti)，完整请求见 [`examples/calibration-area.json`](../examples/calibration-area.json)。

```json
{
  "calibration": {
    "matrix": [0.125,0,0,0,0.125,0,0,0,1],
    "roi": [[0,0],[100,0],[100,100],[0,100]]
  },
  "modes": [[0.015625,0,0,0,0.015625,0,0,0,0]],
  "comparisons": [{
    "probe_id": "common-scale",
    "first_polygon": [[0,0],[32,0],[0,32]],
    "second_polygon": [[0,0],[64,0],[0,64]]
  }]
}
```

最多 32 个模式、64 组比较，每片 3..64 个顶点。该批量上限使最坏输入为 262,144 次模式与顶点组合计算。空模式和空比较有效；`probe_id` 唯一，长度 1..128 UTF-16 单元。标定沿用原 matrix、roi、可选 max_meters_per_pixel 和 ground_noise_floor_m 的验证，噪声底不加入本贡献。

输出 schema 为 `0.1.0`，kind 为 `calibration_area_comparison`，`evidence_scope` 为 `first_order_shared_homography_area_contrasts`，顶层保留 normalized_matrix、mode_count 和原顺序 comparisons。每组包含 probe_id 及上述比较字段；first、second 各含 positions_m、signed_area_m2、area_m2、mode_responses_m2、contribution_m4、std_m2。

原始重复键、未知字段、非有限数及非零数字 token 下溢成零均报错。请求上限 1,048,576 UTF-16 单元，嵌套深度 32，完整输出最多 8,388,608 UTF-16 单元。任何晚阶段错误都不返回部分请求结果；不分配状态句柄。

CLI `--calibration-area` 恰读一行 UTF-8 JSON，接受 LF、CRLF 或 EOF；默认物理行上限 1 MiB，不接受流专用 --max-line-bytes。错误退出 2。首行成功后再读到多余行，会保留首行完整输出并报错。

```powershell
moon version --all --no-path
moon build cmd/main --target native --release --deny-warn
python -c "import json,subprocess; x=json.load(open('examples/calibration-area.json',encoding='utf-8')); r=subprocess.run(['_build/native/release/build/cmd/main/main.exe','--calibration-area'],input=json.dumps(x).encode(),stdout=subprocess.PIPE,check=True); print(r.stdout.decode())"
node web/build.mjs
python validation/calibration_area_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/calibration-area-results.json
```

## 浏览器与独立验证

原“标定参数的共享误差”面板增加“两片面积”。四种模式分别保留草稿、成功结果和下载；切换取消旧计算和旧示例请求，编辑输入仅清除当前模式结果。同输入重算失败仍保留原成功下载，折叠释放表格行。普通测量编辑不改变这里明确给出的标定。浏览器输入另限 1 MiB UTF-8。

表格先显示面积差、面积比及模式标准差；展开显示两片面积、有向面积、顶点数和 m⁴ 交叉贡献。下载文件为 `moonground-calibration-area.json`，保留完整输出精度、地面顶点和逐模式响应。

独立参考用 Fraction 对完整闭合鞋带公式和单应商式求精确面积、导数，再用 110 位 Decimal 核对贡献和平方根；极端面积用例提高到 800 位。它不复用库的三角扇面积实现。非线性中心差分使用投影后去均值的闭合鞋带公式，分别检查两片面积、面积差和比值。位置商式的绝对项尺度传播为数值比较容差；这些容差不是认证界。

实际参考覆盖 31 个请求、297 组比较、44,339 个标量和 2,460 组非线性差分，包括负交叉贡献、共同平移／转动／尺度／齐次规范、绕向与反射、远原点小区域、有限极大和极小面积、随机透视及最大容量。数值误差按 m、m²、m⁴ 和无量纲分别记录；极大面积的绝对误差不能当作普通尺度的物理误差。命令、种子、版本、产物摘要和实际结果见 [`validation/calibration-area-results.json`](../validation/calibration-area-results.json)。
