# 同一标定下的参考线偏移

给出两个参考端点和两个测点的已去畸变像素坐标，比较它们在地面上相对参考线的有符号垂距。参考端点与测点使用同一个 `HomographySensitivity`，共同参与标定参数扰动，适合分析通道边界附近的横向位置及两个位置的相对偏移。

参考线从 `line_start` 指向 `line_end`，左侧为正，右侧为负。它是两个端点定义的无限直线，端点延长线上的测点仍可计算；落在线上的点返回零偏移。两个端点必须映射为不同的地面位置。

## API 与单位

- `HomographySensitivity::line_offset(start, end, pixel)` 返回 `position_m`、`signed_offset_m`、`contribution_m2`、`std_m`；`mode_responses_m()` 返回原模式顺序的响应副本。
- `HomographySensitivity::compare_line_offsets(start, end, first, second)` 返回共同参考线的地面端点、方向和长度，两点各自的偏移、交叉贡献，以及第一点减第二点的偏移差、贡献和标准差。`difference_mode_responses_m()` 返回差值响应副本。

偏移、差值和标准差使用 m，交叉贡献与方差贡献使用 m²。差值直接对两点的地面位移及响应作投影，避免从两个很大的已舍入偏移中相减。输出末位因此可能与直接相减显示的两个偏移不同。

设 `u=B-A`、`v=P-A`、`t=u/|u|`，`n` 为 `t` 的左法向。偏移为 `n·v`，模式响应为：

```text
dh = n·(dP-dA) - [n·(dB-dA)/|u|] · (t·v)
```

第二项保留参考线自身的方向变化。共同平移与刚体转动在一阶偏移中抵消，共同尺度仍影响米制偏移；两侧测点可以有负的交叉贡献。像素观测噪声、镜头参数误差和地面噪声底由现有测量接口分别处理。

输入沿用原标定 ROI 和单点／点对数值域。计算检查投影、端点差、法向及切向分量和最终贡献的可表示性；数值错误返回 `GroundError`。

## 原文协议与使用

[完整示例](../examples/calibration-line-offset.json) 自带 `calibration`、`modes` 和 `comparisons`。每组比较包含 `probe_id`、`line_start`、`line_end`、`first_pixel`、`second_pixel`；四个位置均为二元素像素数组。

示例的两侧偏移为 `3 m` 与 `-2 m`，交叉贡献为 `-0.09375 m²`；偏移差为 `5 m`，其模式标准差为 `0.625 m`。

`codec.calibration_line_offset_json` 与 JavaScript 导出 `moonground_calibration_line_offset` 接受相同原文。schema 为 `0.1.0`，kind 为 `calibration_line_offset_comparison`，响应保留 `normalized_matrix`、模式数与比较顺序。

最多 32 个模式、256 组比较，`probe_id` 唯一且为 1..128 个 UTF-16 单元。请求上限 1 Mi UTF-16 单元、深度 32，完整输出上限 8 Mi UTF-16 单元。重复键、未知字段、非有限数字及非零 token 下溢均报错；任何比较失败时整份请求返回错误。

CLI `--calibration-line-offset` 读取一行 UTF-8 JSON，接受 LF、CRLF 或 EOF。默认物理行上限 1 MiB，错误退出码为 2；首行成功后若出现多余行，保留首行输出并报错。

```sh
moon build cmd/main --target native --release --deny-warn
node web/build.mjs
python validation/calibration_line_offset_verify.py --binary _build/native/release/build/cmd/main/main.exe --web
```

POSIX 下将上述可执行文件名改为 `main`。浏览器在“标定参数的共享误差”中选择“点到参考线”，可载入示例、计算、展开地面参考线与两点偏移、下载完整精度结果。五种比较各自保存草稿与结果；切换时取消未完成的计算与示例加载。

## 数值参考

独立参考从像素参考线出发，用精确 Fraction 计算 `H⁻ᵀ` 及其导数，再传播测点和线方程；160 位 Decimal 计算归一化、平方根及共享贡献。另以非线性投影后的端点叉积做中心差分核对，与库中的端点法向导数分别实现。

运行结果见 [数值记录](../validation/calibration-line-offset-results.json)。各单位分别记录误差，包含极大与极小合成尺度；数值比较描述软件计算一致性。
