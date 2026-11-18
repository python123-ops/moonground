# 共享标定误差下的长度比较

`calibration.HomographySensitivity` 在原点对传播上增加 `distance` 和 `compare_distances`。调用方提供同一标定、同一组参数扰动模式及明确的像素线段，得到地面长度、两次长度测量的交叉贡献，以及第一段减第二段的差值和第一段除第二段的比值贡献。它适合检查固定相机场地尺寸比较对标定参数的敏感性。

同一组有向线段还可使用[方向与夹角传播](calibration-angle.md)，保留共同转动误差在相对夹角中的抵消。

## 为什么保留共享误差

同一相机的长度测量共享标定误差，不能默认彼此独立。例如，两段真实地面向量长度分别为 5 m 和 10 m，唯一扰动模式使每个地面坐标按相同系数伸缩，则两段长度都有一阶误差，但其比值 0.5 的该项贡献为零。尺度误差仍会影响长度差值。另一个同时拉长横向、缩短纵向的模式，可以使两次长度误差呈负相关，从而增大差值贡献。

模式规范沿用 [标定共享误差](calibration-sensitivity.md)：以 `GroundCalibration::matrix()` 返回的归一化矩阵为基线，模式每列九个行优先系数；模型 H + Σ M_i ξ_i 中的 ξ_i 均值零、方差一、彼此协方差零，并在所有点间共享。输入像素须已经去畸变且位于原闭 ROI 中。模式由调用方给出，不从拟合残差估计。

## 一阶计算与单位

设地面端点为 a、b，d=b-a，L=||d||>0，单位方向 u=d/L；原点对模型给出各模式的端点响应 r_i。长度响应及两段比较为：

```text
g_i = uᵀ(r_i(b)-r_i(a))
Var_mode(L) = Σ g_i²
Cov_mode(L1,L2) = Σ g1_i*g2_i
D = L1-L2                 gD_i = g1_i-g2_i
R = L1/L2                 gR_i = (g1_i-R*g2_i)/L2
Var_mode(D) = Σ gD_i²     Var_mode(R) = Σ gR_i²
```

实现先求各模式的差值或比值响应，再求平方和，保留共享误差抵消；不会从几个很大的方差块相减。交叉贡献可为负。长度、差值、各自响应与标准差单位为 m，方差和交叉贡献单位为 m²；比值及其响应、方差和标准差均无量纲。`std` 仅是给定模式贡献的平方根，不是包括所有观测误差的总测量标准差。

两段长度都必须为正；相同端点以及因浮点舍入映成相同地面坐标的端点均报错，空模式也遵守这项规则，因为零向量处的欧氏距离没有唯一导数。交换一段的端点不改变长度响应；交换两段会改变差值符号和比值方向。

计算是给定基线处的一阶近似。零一阶贡献仍可能存在二阶效应：向量 (4,0) 受到垂直响应 (0,1) 时，长度导数为零，但单位有限扰动后的长度为 √17。结果不包含像素观测噪声、地面噪声底、镜头参数误差或这些量与标定参数的相关性，也不表示概率区间。它不修改滤波、轨迹、标定健康或历史状态。

长度采用缩放范数，方向响应复用原补偿投影核，继承原共享点对的数值支持域。非有限数、非零乘积／商下溢成零、不可表示的正比值、对比贡献溢出等均报错。接近抵消的响应及很接近的端点仍会损失相对精度；返回的 binary64 数值没有经过认证的误差界。

## MoonBit API

- `HomographySensitivity::distance(first_pixel, second_pixel)` 返回 `CalibrationDistanceSensitivity`，含两个地面端点、单位方向、`distance_m`、`contribution_m2` 与 `std_m`。
- `HomographySensitivity::compare_distances(first_start, first_end, second_start, second_end)` 返回 `CalibrationDistanceComparison`，保留两段距离结果、交叉贡献、差值、比值及其各自贡献和标准差。
- `mode_responses_m()`、`difference_mode_responses_m()`、`ratio_mode_responses()` 返回原模式顺序的防御性副本；结果只读，失败后模型仍可重用。

严格原文入口为 `codec.calibration_distance_json`，JavaScript 桥为 `moonground_calibration_distance`。它们与原点对协议分别调用，原公开类型、协议和检查点保留原行为。

## 单请求协议

完整可运行请求见 [`examples/calibration-distance.json`](../examples/calibration-distance.json)。

```json
{
  "calibration": {
    "matrix": [0.125,0,0,0,0.125,0,0,0,1],
    "roi": [[0,0],[100,0],[100,100],[0,100]]
  },
  "modes": [[0.015625,0,0,0,0.015625,0,0,0,0]],
  "comparisons": [{
    "probe_id": "common-scale",
    "first_segment": [[0,0],[24,32]],
    "second_segment": [[0,0],[80,0]]
  }]
}
```

每段恰有两个二维像素点。最多 32 个模式、256 组比较；probe_id 唯一，长度 1..128 UTF-16 单元。空模式、空比较有效；零或奇异参数贡献不添加噪声底。标定配置沿用原 matrix、roi、可选 max_meters_per_pixel 和 ground_noise_floor_m 的校验，噪声底不加入本计算。

结果使用 schema `0.1.0`、kind `calibration_distance_comparison`、scope `first_order_shared_homography_distance_contrasts`；含 `normalized_matrix`、`mode_count` 和原顺序 `comparisons`。每组保留 probe_id、first、second、cross_contribution_m2、difference_m、difference_mode_responses_m、difference_contribution_m2、difference_std_m、ratio、ratio_mode_responses、ratio_contribution、ratio_std。单段结果含两个地面端点、方向、距离、逐模式响应、贡献和标准差。

原始重复键、未知字段、非有限数及非零数字 token 下溢成零均报错。请求上限 1,048,576 UTF-16 单元，嵌套深度 32，完整输出最多 8,388,608 UTF-16 单元。纯函数任何晚阶段失败均无部分结果，桥仍返回 `{error: string}`，不分配句柄。

原生命令 `--calibration-distance` 恰读一个请求行，接受 LF、CRLF 或 EOF 结束；默认字节行上限 1 MiB，不接受流专用 --max-line-bytes。错误退出 2。若第一行已成功，随后才输入额外行，保留第一行完整输出并对额外请求报错。

```powershell
moon version --all --no-path
moon build cmd/main --target native --release --deny-warn
python -c "import json,subprocess; x=json.load(open('examples/calibration-distance.json',encoding='utf-8')); r=subprocess.run(['_build/native/release/build/cmd/main/main.exe','--calibration-distance'],input=json.dumps(x).encode(),stdout=subprocess.PIPE,check=True); print(r.stdout.decode())"
node web/build.mjs
python validation/calibration_distance_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/calibration-distance-results.json
```

## 浏览器与验证

在原“标定参数的共享误差”面板选择“两段长度”。四种比较内容分别保留草稿和结果；切换模式取消旧模式的待任务和示例加载，旧续接不会改写当前模式。修改当前输入仅使当前模式结果失效；同输入重算失败保留已有成功结果。折叠释放表格行，下载保留原精度基线、响应及交叉贡献。

长度模式先显示差值与比值及各自模式标准差，展开查看两段长度及交叉贡献。输入自带明确标定，独立于上方轨迹和控制点拟合；普通测量编辑不会隐式换掉这里的基线。下载文件为 `moonground-calibration-distance.json`。浏览器另有 1 MiB UTF-8 输入上限。

独立参考直接用 Fraction 对单应投影商式求导，再用 110 位 Decimal 计算欧氏长度及差值／比值的导数和贡献；以记录中的浮点比较容差核对实际产物，不把该数值比较当成认证界。非线性中心差分另行核对两段长度、差值和比值响应。实际命令、固定种子、依赖版本、计数与摘要见 [`validation/calibration-distance-results.json`](../validation/calibration-distance-results.json)。


有序凸多边形的地面面积、共享误差交叉贡献及面积差／比值见[面积比较说明](calibration-area.md)。
