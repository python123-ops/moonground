# 共享标定误差下的方向与夹角

`calibration.HomographySensitivity` 增加 `segment_direction` 和 `compare_directions`，用明确给出的像素线段计算米制地面方向、有向夹角，以及原参数模式对角度的一阶贡献。它衔接已有的[点对共享误差](calibration-sensitivity.md)和[长度比较](calibration-distance.md)，适用于固定相机下的道路方向、设施夹角与几何对齐测量。

线段由调用方给出，端点先后决定方向。每段方向从标定地面坐标的 +x 轴逆时针计；比较结果为从第一段转向第二段的带符号角度。方向和夹角都以 rad 表示，规范到 `(−π, π]`，精确反向统一返回 `+π`，零统一为正零。它不推断目标运动朝向或地理方位。

## 共享误差与圆周切口

同一相机的两段方向共享标定误差。例如，唯一模式使地面坐标发生每单位潜变量 0.125 rad 的一阶共同转动，两段方向各自标准差均为 0.125 rad；其相对夹角的该项贡献为零。对称剪切则可使水平段与竖直段反向转动，交叉贡献为负，相对夹角的标准差增大。

模式仍以 `GroundCalibration::matrix()` 返回的实际归一化矩阵 H 为基线，每个模式 M_i 含九个行优先系数，包含 h22。模型为 `H + Σ M_i ξ_i`；ξ_i 均值零、方差一、彼此协方差零，并在所有端点间共享。模式由调用方提供，不从拟合残差估计。输入像素须已经去畸变，且位于原标定的闭 ROI 中。

`+π` 与 `−π` 表示同一圆周方向，显示值在这里有切口。结果中的响应和标准差描述局部圆周切向变化，在切口处仍可计算。例如，基线夹角为 π 且有非零响应时，小扰动可以把显示值从接近 π 改到接近 −π；不能直接相减这两个显示值，也不能把 `angle ± std` 当作普通实数区间。比较角度残差时应先按圆周折回。接口没有提供概率覆盖率或角度区间。

## 导数、贡献与数值域

设一段地面端点为 a、b，d=b−a，L=||d||>0，δd_i=r_i(b)−r_i(a)。其方向 θ 和模式响应 t_i 为：

```text
θ = atan2(d_y, d_x)
t_i = cross(d, δd_i) / L²
Var_mode(θ) = Σ t_i²
C12 = Σ t1_i*t2_i
φ = atan2(cross(d1,d2), dot(d1,d2))
g_i = t2_i−t1_i
Var_mode(φ) = Σ g_i²
```

方向、夹角、响应与标准差单位为 rad；贡献和交叉贡献为 rad²。实现复用原点对响应、缩放范数和补偿原方向叉积核，先计算法向分量再除以 L，避免直接形成可能上溢或下溢的 L²。相对夹角先求响应差再平方求和，保留共同误差的抵消。基线夹角使用原方向的补偿叉积，保留很接近平行时的非零转角。

两段都必须映成不同的地面端点；相同端点以及舍入后重合的端点均报错，空模式也遵守此规则。交换两段会反转相对夹角和局部响应；精确反向仍按规范返回 +π。反转一段的端点会把其显示方向移动 π，但保留该段的局部角度响应。

结果是给定基线处的一阶近似，零一阶贡献仍可能有高阶效应。它不包含像素观测噪声、地面噪声底、镜头参数误差或它们与参数模式的相关性，不修改轨迹、标定健康或检查点。计算继承原共享点对和补偿投影核的数值支持域；非有限数、非零项在缩放或乘除中丢失、角度贡献溢出或非零贡献下溢等均报错。返回的 binary64 数值没有认证误差界，接近重合的端点会放大数值误差及模式响应。

## MoonBit API

- `HomographySensitivity::segment_direction(first_pixel, second_pixel)` 返回 `CalibrationDirectionSensitivity`，含两个地面端点、单位方向、`distance_m`、`angle_rad`、`contribution_rad2` 与 `std_rad`。
- `HomographySensitivity::compare_directions(first_start, first_end, second_start, second_end)` 返回 `CalibrationAngleComparison`，保留两段方向结果、`cross_contribution_rad2`，以及第二段相对第一段的 `angle_rad`、`contribution_rad2` 与 `std_rad`。
- 两种结果的 `mode_responses_rad()` 都按原模式顺序返回防御性副本。结果只读，失败后模型可以继续使用。

公开签名见 [`calibration/pkg.generated.mbti`](../calibration/pkg.generated.mbti)。严格原文入口为 `codec.calibration_angle_json`，JavaScript 桥为 `moonground_calibration_angle`。

## 单请求协议

完整请求见 [`examples/calibration-angle.json`](../examples/calibration-angle.json)。输入结构与长度比较相同，但调用独立角度入口：

```json
{
  "calibration": {
    "matrix": [0.125,0,0,0,0.125,0,0,0,1],
    "roi": [[0,0],[100,0],[100,100],[0,100]]
  },
  "modes": [[0,-0.015625,0,0.015625,0,0,0,0,0]],
  "comparisons": [{
    "probe_id": "shared-rotation",
    "first_segment": [[0,0],[24,32]],
    "second_segment": [[0,0],[0,80]]
  }]
}
```

每段恰有两个二维像素点。最多 32 个模式、256 组比较；probe_id 唯一，长度 1..128 UTF-16 单元。空模式、空比较有效。标定仍验证原 matrix、roi 和可选 max_meters_per_pixel、ground_noise_floor_m，地面噪声底不加入本项贡献。

输出 schema 为 `0.1.0`，kind 为 `calibration_angle_comparison`，scope 为 `first_order_shared_homography_angular_tangents`，angle_convention 为 `second_relative_to_first_ccw`。顶层保留 `normalized_matrix`、`mode_count` 和原顺序 `comparisons`。每组包含 probe_id、first、second、cross_contribution_rad2、angle_rad、mode_responses_rad、contribution_rad2、std_rad；两段结果各保留端点、方向、距离、绝对方向角及相应响应和贡献。

原始重复键、未知字段、非有限数及非零数字 token 下溢成零均报错。请求上限 1,048,576 UTF-16 单元，嵌套深度 32，完整输出最多 8,388,608 UTF-16 单元。纯函数任何晚阶段失败都不返回部分结果，桥返回 `{error: string}`，不分配句柄。

CLI `--calibration-angle` 恰读一个 UTF-8 请求行，接受 LF、CRLF 或 EOF 结束；默认物理行上限 1 MiB，不接受流专用 --max-line-bytes。错误退出 2。若首行已成功输出，随后才读到多余请求行，会保留首行完整输出并报错。

```powershell
$env:MOON_HOME='C:/Users/px830/.codex/tools/moonground-moon-0.10.18'
$env:PATH=$env:MOON_HOME+'/bin;'+$env:PATH
moon build cmd/main --target native --release --deny-warn
python -c "import json,subprocess; x=json.load(open('examples/calibration-angle.json',encoding='utf-8')); r=subprocess.run(['_build/native/release/build/cmd/main/main.exe','--calibration-angle'],input=json.dumps(x).encode(),stdout=subprocess.PIPE,check=True); print(r.stdout.decode())"
node web/build.mjs
python validation/calibration_angle_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/calibration-angle-results.json
```

## 浏览器与独立验证

原“标定参数的共享误差”面板新增“方向与夹角”。四种模式分别保存草稿、成功结果和下载；切换取消旧计算及旧示例请求，输入修改仅清除当前模式的结果。同输入重算失败保留原成功下载，折叠释放表格行。普通测量的编辑不替换这份显式标定基线。浏览器输入另限 1 MiB UTF-8。

表格先显示有向夹角及模式标准差，展开可看两段方向、标准差、长度和交叉贡献。单位分别标为 rad、m 和 rad²。完整精度结果下载为 `moonground-calibration-angle.json`。

独立参考以 Fraction 对原单应商式及角度求精确有理导数，用 110 位 Decimal 的约简级数 atan、Machin π 和范数核对方向、夹角及共享贡献；1e±200 线段尺度用例提高到 800 位，避免参考舍入主导米制绝对误差。非线性中心差分按圆周折回残差后检查两段方向和相对夹角。统计分别记录 m、rad、rad² 和无量纲数值误差，比较容差及误差不表示物理测量精度或认证界。实际命令、种子、依赖版本、产物摘要和结果见 [`validation/calibration-angle-results.json`](../validation/calibration-angle-results.json)。

2026-11-15 的生态检查使用两条定向检索，并查阅官方 [moon-cv-geometry@0.2.2/core](https://mooncakes.io/docs/python123-ops/moon-cv-geometry%400.2.2/core) 与 [camera](https://mooncakes.io/docs/python123-ops/moon-cv-geometry%400.2.2/camera) 接口页。被检查的接口提供基础几何、相机与投影能力；本批在已有基础之上增加共享单应参数模式的方向导数与圆周夹角贡献，未在本次检查范围发现同语义入口。

有序凸多边形的地面面积、共享误差交叉贡献及面积差／比值见[面积比较说明](calibration-area.md)。
