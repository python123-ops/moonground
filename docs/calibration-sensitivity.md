# 标定参数的共享误差

`calibration.HomographySensitivity` 接受明确给出的单应矩阵扰动模式，计算固定标定下的单点响应、两点交叉贡献和相对位移贡献。它可用于检查场地距离测量对标定参数的敏感性。原 `GroundCalibration::project` 继续表示给定标定条件下的像素协方差传播及地面噪声底。

## 模型与矩阵规范

先取得 `GroundCalibration::matrix()` 返回的归一化行优先矩阵 H。每个模式 M_i 有九个系数，含最后一个 h22；其单位与这个 H 一致。模型为 H + Σ M_i ξ_i，其中 ξ_i 均值为零、方差为一、彼此协方差为零，且所有被测点共享同一组 ξ_i。无需假设高斯分布。模式可来自调用方已有的参数协方差因子，也可作为明确指定的敏感性场景；库不从拟合残差或核验 RMS 推断模式。

若参数因子 F 原先基于未归一化矩阵 G，而 H = G/s，需同时使用 F/s。返回值包含实际归一化基线，便于核对模式的规范。API 将原标定和模式绑定为不可变值；更换标定或像素坐标系后，应明确转换模式并建立新模型。

对已校正像素 p=(u,v,1)，记 H 的三行与 p 的乘积为 n_x、n_y、w，地面位置为 g=(n_x/w,n_y/w)。第 i 个模式对应 d_x、d_y、d_w，其响应为：

```text
r_i(p) = ((d_x*w - n_x*d_w)/w², (d_y*w - n_y*d_w)/w²)
C(p)   = Σ r_i(p) r_i(p)ᵀ
C(a,b) = Σ r_i(a) r_i(b)ᵀ
C(b-a) = Σ (r_i(b)-r_i(a)) (r_i(b)-r_i(a))ᵀ
```

交叉块 C(a,b) 通常不对称，顺序是 Cov(first, second)。交换两点后该块转置，相对位移取反，位移贡献保持相同。实现先计算响应差再求 Gram 矩阵，避免从几个很大的协方差块相减；相同像素得到精确零位移贡献。共同平移可使单点贡献非零而相对贡献为零。

这些是原基线处的一阶近似，不是有限扰动的包络或概率区间。较大扰动、接近投影地平线的扰动，以及接近抵消的模式，需要调用方另行检查线性化是否适用。返回值不包含像素观测噪声、地面噪声底、镜头参数误差或这些量与标定参数的相关性。它不会改写测量协方差或滤波状态；共享的静态标定误差也不应逐帧当成新的独立测量噪声。

## MoonBit 接口

- `HomographySensitivity::new(calibration, modes)`：绑定标定并复制 0..32 个模式，每个九个有限系数。
- `evaluate(pixel)`：返回位置、按原模式顺序排列的二维响应和单点贡献。
- `evaluate_pair(first_pixel, second_pixel)`：返回两点结果、second-first 位移、交叉块及位移贡献。
- `matrix()`、`modes()`、`mode_responses_m()`、`cross_contribution_m2()`：均返回防御性副本。

`CalibrationContribution2` 是只读结果，提供 xx、xy、yy；允许零矩阵和奇异矩阵，独立于严格 SPD 的 `types.Covariance2`。交叉块使用行优先 `[xx,xy,yx,yy]`。它们均为普通 binary64 数值估计，舍入可能使矩阵偏离精确半正定关系，不添加噪声底或修补特征值。

点必须位于原标定的闭 ROI 中，并使用已去畸变像素。拒绝非有限数、不可表示的中间运算，以及非零乘积或商下溢成零的情况。支持域以内仍可能存在近零响应的相对精度损失；接口不提供经过认证的数值误差界。错误不修改模型，修正输入后可重复计算。

## 原文协议与运行

完整示例是 [`examples/calibration-sensitivity.json`](../examples/calibration-sensitivity.json)。请求仅接受三个字段：

```json
{
  "calibration": {
    "matrix": [0.1,0,0,0,0.1,0,0,0,1],
    "roi": [[0,0],[100,0],[100,100],[0,100]]
  },
  "modes": [[0,0,0.25,0,0,0.5,0,0,0]],
  "probes": [{"probe_id":"shared","first_pixel":[20,20],"second_pixel":[80,60]}]
}
```

配置沿用原标定的 `matrix`、`roi`、可选 `max_meters_per_pixel` 与 `ground_noise_floor_m` 校验；噪声底不加入本诊断。最多 256 个点对，probe_id 唯一，长度 1..128 UTF-16 单元。空模式、空点对、零模式、奇异贡献和闭 ROI 边界均有效。不接受 camera、会话、轨迹或恢复字段。

`codec.calibration_sensitivity_json(raw)` 和 `moonground_calibration_sensitivity(raw)` 接受原始 JSON 文本；重复键、未知字段、非有限数及非零数字 token 下溢成零均报错。文本最多 1,048,576 UTF-16 单元，嵌套最多 32 层，完整结果最多 8,388,608 UTF-16 单元。纯函数失败返回无部分结果，桥以原 `{error: string}` 格式返回错误且不分配句柄。

原生命令 `--calibration-sensitivity` 只读一个请求行，可用 LF、CRLF 或 EOF 结束。沿用默认 1 MiB 字节行上限；不接受流专用 `--max-line-bytes`。完整请求含错误时退出 2，stdout 无结果；若第一行已成功、随后才输入第二行，保留第一行完整输出并对额外请求退出 2。

```powershell
moon version --all --no-path
moon build cmd/main --target native --release --deny-warn
python -c "import json,subprocess; p='examples/calibration-sensitivity.json'; x=json.load(open(p,encoding='utf-8')); r=subprocess.run(['_build/native/release/build/cmd/main/main.exe','--calibration-sensitivity'],input=json.dumps(x).encode(),stdout=subprocess.PIPE,check=True); print(r.stdout.decode())"
python validation/calibration_sensitivity_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/calibration-sensitivity-results.json
```

结果固定使用 schema `0.1.0`、kind `calibration_sensitivity`、evidence_scope `first_order_shared_homography_parameters`；包含 `normalized_matrix`、`mode_count` 和原顺序 `probes`。每个点对提供 `first`、`second`、`displacement_m`、`cross_contribution_m2`、`displacement_contribution_m2`；单点提供 `position_m`、`mode_responses_m`、`contribution_m2`。

## 浏览器

展开“从地面控制点生成标定”内的“标定参数的共享误差”。编辑框自带完整标定、模式和点对，独立于普通轨迹和控制点拟合；上方轨迹修改不会改变这里已经计算的明确基线。点击计算后先显示位移贡献，逐行展开可查看单点与交叉块，下载保留基线与全部模式响应。

修改本输入会清除结果并取消待计算任务；迟到的示例不会覆盖用户草稿。同一输入的重新计算失败保留上次成功结果。折叠面板释放表格行，下载仍可使用。浏览器额外使用 1 MiB UTF-8 输入上限。

在“比较内容”选择“两段长度”可检查共享标定下的长度差值和比值；点对位移、两段长度、方向与夹角、两片面积四种模式分别保留草稿与结果。计算与输入约定见 [长度比较说明](calibration-distance.md)。
