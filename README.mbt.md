# MoonGround

MoonGround 把固定相机中的目标轨迹转换为米制地面位置、速度和观测路径，面向园区、仓储和其他近似平面的场地。输入是已有目标身份、地面接触锚点和真实时间戳；库负责标定有效域、投影协方差、运动估计、轨迹分段和双向通道过线统计，并支持原子组合更新与完整状态恢复。固定地标检查持续核对原标定的米制残差；需要按检查结果决定是否计算对象测量时，可显式使用 `guarded` 入口。

当前开发版本为 `0.19.0`，尚未发布到 Mooncakes。源码使用 Apache-2.0 许可证，仓库为 [python123-ops/moonground](https://github.com/python123-ops/moonground)。

## 与现有项目的衔接

项目延续 [MoonTile](https://github.com/python123-ops/moontile)、[MoonDetEval](https://github.com/python123-ops/moondeteval)、[MBMOT](https://github.com/python123-ops/mbmot) 和 [moon-cv-geometry](https://github.com/python123-ops/moon-cv-geometry) 的视觉工具路线，增加固定相机下的地面测量层。

```text
检测结果 → MBMOT 身份轨迹 → 显式选择地面锚点 → MoonGround 米制测量 → 通道过线事件
                            ↑                       ↑
                   检测质量可用 MoonDetEval     moon-cv-geometry
                                                + moon-kalman
```

MoonGround 复用 `moon-cv-geometry@0.2.2` 的几何能力与 `moon-kalman@0.2.1` 的线性 Kalman 更新、Joseph 协方差公式。这里新增的是视觉观测到地面测量的连接：凸 ROI 内的有效性检查、投影 Jacobian、相关协方差传播、真实时间间隔、身份生命周期和输出语义。完整 MBMOT 接入示例在 [`examples/consumer`](examples/consumer)。

| 入口 | 用途 |
| --- | --- |
| 根包 | `GroundCalibration`、`MeasurementSession`、`MeasurementCheckpoint`、`PixelTransform`、像素观测和测量结果 |
| `calibration` | 严格与稳健控制点拟合、逐点诊断、独立检查点、矩阵导入、有效域和协方差投影 |
| `camera` | 有效域受限的 Brown–Conrady 镜头校正、像素协方差转换与地面投影组合 |
| `motion` | 已有米制观测的时间处理、运动估计、分段与 `MotionCheckpoint` |
| `events` | 消费 `motion.FrameResult` 的有向有限通道；均值计数 `GateCounter` 与法向协方差证据计数 `EvidenceGateCounter` 各自保存完整状态 |
| `analysis` | 像素／米制测量与均值或法向证据计数的原子更新，分别保存完整检查点，并可直接联合证据区间通行及确认时刻分窗，支持独立分支与像素换算 |
| `health` | 独立固定地标的逐点残差、连续采样证据确认、完整 `HealthCheckpoint` 与像素换算 |
| `guarded` | 当前地标确认健康后计算对象，阻断时结束片段；均值／法向证据门控及证据通行分别保存完整检查点，支持投影切换与重新确认 |
| `transit` | 同目标同片段的有向入口／出口配对、通行时间界与插值估计、取消原因；均值／法向证据策略分别保存独立完整检查点；已完成证据通行可按确认时刻分窗、按时长界分类 |
| `codec` | 原生 CLI 与浏览器共用的严格 JSON 协议、检查点、坐标转换，以及独立／联合测量、通道、证据、地标健康、门控与区间回放 |

计算包支持 `wasm`、`wasm-gc`、`js`、`native`。流式命令使用 native，浏览器桥使用 JavaScript；图像解码、检测、跟踪及相机采集由调用方接入。

## 从三个观测获得速度

项目固定使用 MoonBit `0.10.18+6c83a7f62`。下面的示例随 `moon test` 执行：同一目标每 0.2 秒移动 10 像素，标定比例为 0.01 米/像素，第三个观测后获得约 0.5 米/秒的速度。

```mbt check
///|
test "README: three contact observations produce a measured speed" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      @moonground.Point2::new(0.0, 0.0),
      @moonground.Point2::new(640.0, 0.0),
      @moonground.Point2::new(640.0, 480.0),
      @moonground.Point2::new(0.0, 480.0),
    ],
  )
  let session = @moonground.MeasurementSession::new(
    "warehouse-contact-points",
    calibration,
    @moonground.MotionConfig::new(),
  )
  let observe = (x : Double) => {
    @moonground.PixelObservation::new(
      7,
      @moonground.Point2::new(x, 200.0),
      @moonground.Covariance2::isotropic(0.25),
    )
  }
  let first = session.update(0L, [observe(100.0)])
  assert_true(first.motion.tracks[0].speed_mps is None)
  let counter = @events.GateCounter::new(
    "warehouse-contact-points",
    [
      @events.LineGate::new(
        "aisle",
        @moonground.Point2::new(1.15, 0.0),
        @moonground.Point2::new(1.15, 4.0),
        deadband_m=0.01,
      ),
    ],
    @events.GateConfig::new(),
  )
  ignore(counter.update(first.motion))
  let second = session.update(200000L, [observe(110.0)])
  ignore(counter.update(second.motion))
  let third = session.update(400000L, [observe(120.0)])
  let counted = counter.update(third.motion)
  assert_eq(counted.counts[0].positive_to_negative, 1L)
  assert_eq(counted.crossings[0].direction, @events.PositiveToNegative)
  match third.motion.tracks[0].speed_mps {
    Some(speed) => assert_true(speed > 0.45 && speed < 0.55)
    None => fail("three accepted observations should produce a speed")
  }
  // Both components are at 400000 us; joining validates and detaches them.
  let analysis = @analysis.AnalysisSession::from_pixel(session, counter)
  let analysis_restored = @analysis.AnalysisSession::from_checkpoint(
    analysis.checkpoint(),
  )
  let restored = @moonground.MeasurementSession::from_checkpoint(
    session.checkpoint(),
  )
  let continued = session.update(600000L, [observe(130.0)])
  let resumed = restored.update(600000L, [observe(130.0)])
  let combined = analysis.update_pixel(600000L, [observe(130.0)])
  let combined_resumed = analysis_restored.update_pixel(600000L, [
    observe(130.0),
  ])
  assert_eq(
    combined.measurement.motion.tracks[0].filtered_state,
    continued.motion.tracks[0].filtered_state,
  )
  assert_eq(
    combined_resumed.measurement.motion.tracks[0].filtered_state,
    combined.measurement.motion.tracks[0].filtered_state,
  )
  assert_eq(combined.counting.counts[0].positive_to_negative, 1L)
  assert_eq(
    resumed.motion.tracks[0].filtered_state,
    continued.motion.tracks[0].filtered_state,
  )
  assert_eq(
    resumed.motion.tracks[0].filtered_covariance,
    continued.motion.tracks[0].filtered_covariance,
  )
  assert_eq(
    resumed.motion.tracks[0].observed_path_length_m,
    continued.motion.tracks[0].observed_path_length_m,
  )
  let transform = @moonground.PixelTransform::new(
    scale_x=0.5,
    scale_y=0.75,
    offset_x=-40.0,
    offset_y=16.0,
  )
  let reframed = session.reframed(transform)
  assert_eq(
    reframed.checkpoint().motion.tracks[0].state,
    session.checkpoint().motion.tracks[0].state,
  )
  let next = reframed.update(800000L, [observe(140.0).reframed(transform)])
  assert_eq(next.motion.tracks[0].accepted_count, 5)
  assert_eq(next.motion.tracks[0].segment_id, "1")
  let analysis_reframed = analysis.reframed(transform)
  let combined_next = analysis_reframed.update_pixel(800000L, [
    observe(140.0).reframed(transform),
  ])
  assert_eq(
    combined_next.measurement.motion.tracks[0].filtered_state,
    next.motion.tracks[0].filtered_state,
  )
  assert_eq(combined_next.counting.counts[0].positive_to_negative, 1L)
}
```

### 坐标、时间与测量条件

- 单应矩阵把图像中的 `(x, y)` 映射到地面的米制坐标。相机固定，ROI 内目标锚点位于同一测量平面；相机移动或重新进行物理标定时，创建新 session。
- 不配置 `camera` 时，输入像素应完成镜头畸变校正。配置 `camera` 时，目标锚点、控制点和检查点使用原始像素，库先进行校正；单应矩阵和 ROI 始终使用已校正像素。图像裁剪或缩放后也要同步变换内参与标定。
- 地面锚点由调用方显式选择，例如经过检查的框底中点。检测置信度不自动转换为测量噪声，框底中点也不自动等于真实接触点。
- 核心 API 的时间为非负 `Int64` 微秒；同一 session 的帧时间严格递增。JSON 使用十进制字符串，例如 `"timestamp_us":"9223372036854000000"`，避免 JavaScript 浮点数丢失整数精度。
- 协方差使用 `[xx, xy, yy]`，像素输入单位为像素平方，米制输入单位为米平方；矩阵必须有限、对称、正定。

### 默认运动模型

状态为 `[x, y, vx, vy]`，每次按实际时间间隔构造转移矩阵。连续白加速度强度 `q=1 m²/s³`；每轴过程噪声为 `q·[[dt³/3, dt²/2], [dt²/2, dt]]`。初始速度均值为零、标准差为 `5 m/s`，初始速度只是模型先验。

| 配置 | 默认值 |
| --- | --- |
| 速度就绪条件 | 至少 3 次接受观测，首末接受观测跨度至少 0.3 秒 |
| 接受观测最大间隔 | 0.5 秒；达到边界即关闭旧段 |
| NIS 创新门限 | 9.21034 |
| 活跃目标上限 | 1000 |
| CLI 像素观测标准差 | 未指定协方差时为 2 像素 |
| CLI ground 模式标准差 | 未指定协方差时为 0.05 米 |
| 地面附加噪声下限 | 标准差 0.001 米 |
| `max_position_std_m`、`max_velocity_std_mps` | 未设置；可分别启用位置、速度不确定性门限 |

未满足就绪条件时，位置可用，速度和速率为 `null`。短时缺测不会生成预测速度或补零；`lost`、`removed` 立即关闭段，观测间隔达到上限也会切段。再次出现的同一目标身份使用新段并重新预热。段号为 session 内递增的十进制字符串。

`observed_path_length_m` 是已接受观测对应的因果滤波位置之间的折线弦长之和，受采样间隔和观测噪声影响；`net_displacement_m` 是该片段首末滤波位置的直线距离。这两项都没有补算缺测期间的真实运动路径。静止目标也可能因观测抖动产生正的折线长度。

输出协方差的条件是**固定标定、选定锚点及所配置噪声模型成立**。它不自动包含标定控制点误差、相机晃动或锚点与真实接触点的偏差。`uncertainty_scope` 会随 JSON 结果明确写出这一条件。

### 镜头校正与输出可用性

`CameraModel` 支持零偏斜内参 `fx,fy,cx,cy` 和 Brown–Conrady 系数 `k1,k2,p1,p2,k3`。校正后沿用同一内参矩阵；鱼眼和其他投影模型需由调用方先校正。`max_normalized_radius` 限制的是**校正后**归一化坐标的半径，默认 1，不直接裁剪畸变像素的半径。

模型构造使用整个声明圆盘的保守界：`L=3|k1|R²+5|k2|R⁴+7|k3|R⁶+6R·hypot(p1,p2)<1`。该条件验证圆盘内的唯一逆分支；超出界的模型会被拒绝，即使其中某些模型在更小区域仍可使用。逐点校正有固定迭代上限，并检查残差与半径。不能校正或校正后落在 ROI 外的目标返回 `rejected_projection`。原始像素的协方差沿总 Jacobian 传播：`J_ground · J_rectify`；地面噪声下限只添加一次。相机参数自身的不确定性不计入输出协方差。

在像素 session 配置和 `--project`、`--calibrate` 请求顶层添加如下字段，即可输入原始像素：

```json
{"camera": {"fx":600,"fy":580,"cx":320,"cy":240,"k1":-0.12,"k2":0.015,"p1":0.001,"p2":-0.002,"k3":0.001,"max_normalized_radius":0.8}}
```

完整合成输入见 [`examples/distorted-camera.ndjson`](examples/distorted-camera.ndjson)，原始控制点拟合请求见 [`examples/distorted-calibration.json`](examples/distorted-calibration.json)。拟合响应同时返回顶层 `camera` 与 `calibration`，两者应一起放入 session 配置。`GroundCalibration::fit` 本身仍接收已校正点；纯库调用者先用 `CameraModel::rectify` 校正控制点，再向 `MeasurementSession::new(..., camera=model)` 传入相机模型。

`position_std_m` 和 `velocity_std_mps` 是各自 2×2 协方差最大特征值的平方根，即最差方向的一倍标准差。速度初始化期间 `velocity_std_mps` 与速度向量均为 `null`。可在 `motion` 中设置有限正数门限，例如 `"max_velocity_std_mps":0.2`。满足预热条件后，任一标准差**大于**对应门限便返回 `uncertain`，`speed_mps=null`；位置、速度向量、协方差和路径仍保留。后续不确定性下降即可恢复 `ready`。该规则不拒绝观测、不改 Kalman 状态；初始化、创新拒绝与数值失败保留原有含义。这些标准差描述二维向量的不确定性，不能直接当作非负速率的置信区间，尤其是在接近静止时。

测量 JSON 的 `schema_version` 为 `0.2.0`，`uncertainty_scope` 为 `conditional_on_fixed_calibration_camera_and_anchor`。这是 v0.2.0 引入的结果格式，v0.18.0 继续使用；从 v0.1.0 接入的调用方需处理 `uncertain` 状态和两个标准差字段。

### 缩放、裁剪与补边后的像素坐标

检测器的输入尺寸可能与原标定图像不同。`PixelTransform::new` 表示 `p′=Dp+t`：`x′=scale_x*x+offset_x`、`y′=scale_y*y+offset_y`，两个倍率必须有限且严格大于零，偏移必须有限。它覆盖不同轴缩放、裁剪原点平移和 padding；旋转、镜像、剪切和透视变换不在此接口内。

`PixelTransform::point` 换算像素点，`covariance` 使用 `DΣDᵀ`；平移不增加噪声。令对应齐次变换为 `A=[[scale_x,0,offset_x],[0,scale_y,offset_y],[0,0,1]]`，`GroundCalibration::reframed` 使用 `H′=H A⁻¹` 换算单应矩阵并同步变换已校正像素 ROI，米制拟合／核验残差和地面噪声下限保持。`CameraModel::reframed` 对原始与校正像素共同使用该变换：`fx′=scale_x*fx`、`fy′=scale_y*fy`，主点按点坐标换算，Brown 系数和归一化有效半径保持。

这些方法只改变同一物理标定的像素坐标表达，不重新估计标定，也不执行图像重采样、像素取整或可见区裁剪。ROI 和观测点可落在新图像可见范围以外；调用方根据实际图像和检测流程处理可见性。图像库若使用半像素对齐，需要把相应偏移明确计入 `offset_x`、`offset_y`，不能只提供宽高比。

`MeasurementSession::reframed(transform)` 返回独立的新会话，并原样保留已接受的米制状态、协方差、路径、时间、计数和段号；原会话可以继续使用原坐标。新会话的后续观测必须通过 `PixelObservation::reframed(transform)` 或等价计算进入新坐标。像素换算后的浮点运算可能有末位差异，米制测量含义保持。

每次变换把验证用的 `max_meters_per_pixel` 保守调整为 `old/min(scale_x,scale_y)`，再验证完整 ROI。它是域验证上限，不是噪声倍率。多次处理时优先用 `first.then(next)` 按实际应用顺序组合后再应用；逐次调整上限可能比一次组合更宽。`inverse()` 给出逆变换，不可表示的逆、溢出、下溢导致的无效协方差或无效标定会报错，不会改动原会话。

### 稳健控制点标定

人工控制点可能存在误配。默认 `GroundCalibration::fit` 使用全部控制点拟合，任何控制点超出拟合误差上限都会拒绝。显式调用 `GroundCalibration::fit_robust` 时，库只用控制点搜索模型，找出米制前向误差不超过 `inlier_threshold_m` 的内点，并用最终内点重新拟合。

```mbt check
///|
test "README: robust fitting reports mislabeled controls" {
  let controls : Array[@moonground.Point2] = [
    { x: 0.0, y: 0.0, },
    { x: 100.0, y: 0.0, },
    { x: 100.0, y: 100.0, },
    { x: 0.0, y: 100.0, },
    { x: 25.0, y: 50.0, },
    { x: 70.0, y: 30.0, },
    { x: 40.0, y: 80.0, },
    { x: 60.0, y: 10.0, },
  ]
  let world = controls.map(p => @moonground.Point2::{
    x: p.x * 0.02,
    y: p.y * 0.02,
  })
  world[6] = { x: 1.8, y: 0.6, }
  world[7] = { x: 0.2, y: 2.2, }
  let checks : Array[@moonground.Point2] = [
    { x: 20.0, y: 30.0, },
    { x: 80.0, y: 70.0, },
  ]
  let fitted = @moonground.GroundCalibration::fit_robust(
    controls,
    world,
    checks,
    checks.map(p => @moonground.Point2::{ x: p.x * 0.02, y: p.y * 0.02, }),
    controls[:4].to_owned(),
    options=@moonground.RobustFitOptions::new(inlier_threshold_m=0.01),
  )
  assert_eq(fitted.inlier_mask(), [
    true, true, true, true, true, true, false, false,
  ])
  assert_eq(fitted.calibration().report().fit_count(), 6)
}
```

`RobustCalibration` 返回可直接创建 session 的 `calibration()`，以及独立拷贝的 `inlier_mask()` 和 `control_errors_m()`。两组数组按**全部原控制点顺序**排列。残差是返回标定把该像素映射到地面后，与给定地面点的欧氏距离；等于阈值时算内点。`CalibrationReport.fit_count`、拟合 RMS 和最大误差仅统计最终内点，检查点报告仍统计全部独立检查点。

| `RobustFitOptions` 字段 | 默认值与范围 |
| --- | --- |
| `inlier_threshold_m` | 0.05 米，有限正数 |
| `min_inlier_ratio` | 0.6，范围 `(0,1]`；最终还须至少六个内点 |
| `max_trials` | 512，范围 1—4096 |
| `seed` | 1，范围 1—2147483647 |

每个候选使用六对控制点，复用既有几何包的归一化多点拟合。控制点不超过 12 对且全部六点组合在预算内时穷举；其余情况用固定种子的 core ChaCha8 洗牌取样。`trials_run()` 包含退化和重复样本，`valid_hypotheses()` 统计解算成功、完整 ROI 校验通过且残差有限的候选。选出模型后，最多八次重拟合并重新分类；内点集合不稳定、数量或比例不足时返回错误。有限搜索预算可能找不到可接受共识，次数不表示统计置信度。

独立检查点在搜索前与**全部原控制点**核对，之后即使某控制点被排除，也不能复用为检查点。检查点不参与模型选择、阈值调整或细化；最终模型必须通过全部检查点。控制点重复、非有限数或 ROI 外的输入直接拒绝；退化候选会跳过，最终内点集仍须在两个坐标空间内有二维分布。严格拟合原有的 `max_fit_error_m`、`max_check_error_m`、地平线与米／像素限制继续生效。

在 `--calibrate` 请求中加入 `"robust":{}` 使用默认选项，也可显式给出上表四项。省略 `robust` 继续严格拟合。成功时除原有 `calibration`、`report` 和可选 `camera`，还返回 `robust_report`：全部控制点的掩码与误差、从零开始的 `outlier_indices`、有效选项及搜索和细化次数。JSON 拟合入口最多接受 256 对控制点和 256 对检查点；纯库接口各上限为 4096 对。原始像素仍先通过相机模型校正，ROI 始终使用已校正像素。

完整单行合成请求见 [`examples/robust-calibration.json`](examples/robust-calibration.json)。其中 10 对控制点有两个误标，另含三个独立检查点：

```sh
./_build/native/release/build/cmd/main/main.exe --calibrate < examples/robust-calibration.json
```

标定残差和内点选择描述这组对应点的拟合质量，不会自动写入测量协方差。后续测量继续使用显式像素协方差和地面噪声下限。下载的标定结果可保留逐点诊断；配置 session 时使用其中的 `calibration` 与可选 `camera`。检查点沿用现有格式保存实际标定和运动状态。

### 用独立固定地标检查原标定

相机安装后的轻微移动、镜头变化、地标识别偏差或地标本身移动，都可能使原标定的投影残差增大。`health` 包用仍固定在测量平面上的已知米制地标核对这些残差。它不修改相机、单应矩阵或对象运动状态，也不把超限原因自动归结为相机漂移。`healthy` 只表示本次已观测地标满足配置的误差门限；地标的位置和分布决定了检查覆盖，不能据此推断整个 ROI 的误差。

地标的真实位置应独立测量，并优先使用未参与拟合的地标，减少用拟合点反复验证自身。地标身份对应同一个物理点，不能直接使用移动目标的 `track_id`。有 `camera` 时提交原始畸变像素；否则提交已校正像素。检测器负责找到这些点，像素协方差由调用方明确提供。

下面用合成地标演示原标定下的健康、持续超限、检查点恢复和证据不足：

```mbt check
///|
test "README: fixed landmarks confirm calibration evidence and reset on missing data" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.01, 0.0, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 640.0, y: 0.0, },
      { x: 640.0, y: 480.0, },
      { x: 0.0, y: 480.0, },
    ],
  )
  let landmarks = [
    @health.KnownLandmark::new("A", { x: 1.0, y: 1.0, }),
    @health.KnownLandmark::new("B", { x: 5.0, y: 1.0, }),
    @health.KnownLandmark::new("C", { x: 5.0, y: 4.0, }),
  ]
  let monitor = @health.CalibrationMonitor::new(
    calibration,
    landmarks,
    @health.HealthConfig::new(),
  )
  let observations = (shift_pixels : Double) => {
    landmarks.map(landmark => {
      @health.LandmarkObservation::new(
        landmark.landmark_id,
        {
          x: landmark.ground_m.x / 0.01 + shift_pixels,
          y: landmark.ground_m.y / 0.01,
        },
        @moonground.Covariance2::isotropic(0.25),
      )
    })
  }
  assert_eq(monitor.update(0L, observations(0.0)).status, @health.Pending)
  ignore(monitor.update(150000L, observations(0.0)))
  assert_eq(monitor.update(300000L, observations(0.0)).status, @health.Healthy)
  assert_eq(monitor.update(400000L, observations(30.0)).status, @health.Pending)
  ignore(monitor.update(550000L, observations(30.0)))
  assert_eq(monitor.update(700000L, observations(30.0)).status, @health.Drift)
  let restored = @health.CalibrationMonitor::from_checkpoint(
    monitor.checkpoint(),
  )
  let incomplete = restored.update(800000L, [])
  assert_eq(incomplete.status, @health.HealthStatus::Insufficient)
  assert_eq(incomplete.streak_since_us, None)
  assert_eq(incomplete.rms_error_m, None)
}
```

`KnownLandmark::new(id, ground_m)` 定义 1—128 个 UTF-16 代码单元的身份和有限米制位置。每个 `CalibrationMonitor` 接受 1—64 个唯一地标，`min_landmarks` 不得超过配置数量。`LandmarkObservation::new(id, pixel, covariance)` 提供当前像素与正定协方差。`update(timestamp_us, observations)` 每次返回全部配置地标，顺序与配置一致；`residual_m=projected_position_m-ground_m`，`error_m` 为二维残差范数，RMS 按可用地标的误差平方均值开根号计算。

| `HealthConfig` | 默认值与含义 |
| --- | --- |
| `min_landmarks` | 3；至少多少个当前可用地标才判定证据，范围 1—64 |
| `rms_limit_m`、`max_error_m` | 0.1 米、0.2 米；各自为有限非负数，两个门限同时满足才符合阈值，等号包含 |
| `confirmation_us`、`min_observations` | 连续同类证据跨度至少 300,000 微秒且至少 3 次采样；跨度可为 0，样本数范围 1—1,000,000 |
| `max_gap_us` | 500,000 微秒；相邻帧间隔达到上限即重新开始确认 |
| `max_position_std_m` | 默认未设置；启用后跳过最差方向位置标准差超限的地标 |

`evidence` 描述当前帧：地标数不足为 `insufficient`，数量足够且 RMS 与最大误差都不超限为 `within_tolerance`，否则为 `beyond_tolerance`。只要至少一个地标可用，就返回这些点的 RMS 和最大误差，即使整体仍为证据不足；可用数为零时两项为 `null`。`status` 在同类证据尚未同时达到跨度与样本数门限时为 `pending`，达到后分别为 `healthy` 或 `drift`。证据变化、数量不足或长间隔立即终止原确认序列，不沿用旧的健康状态。`streak_observations` 在 `min_observations` 处饱和，表示是否达到确认样本数，不是累计帧数。

时间使用严格递增、非负的 Int64 微秒；确认跨度按采样时间差计算，不补算没有观测的中间时刻。输入未知或重复身份、无效像素或协方差、数量超限及时间错误会拒绝整帧，保留上一水位供同时间重试。缺失、投影失败、位置质量超限和不可表示的残差只拒绝相应地标，`rejection_reason` 分别为 `missing`、`projection: ...`、`position_uncertainty` 和 `numerical: ...`。质量与数值拒绝保留已计算的投影、协方差和标准差，但不把该点纳入残差汇总。

协方差沿相机校正和地面投影传播，并加入既有地面噪声下限；它以固定标定和输入像素噪声模型为条件，不自动计入真实地标位置误差或标定参数误差。米制残差门限和可选位置质量门限分别控制几何偏差与可用观测质量，不能互相替代。

`checkpoint()` 保存固定配置、水位和当前证据序列，`from_checkpoint()` 验证后独立恢复，不增加采样次数。未饱和的样本数必须与首末时间及最大帧间隔自洽；恢复不根据机器当前时间延长或淘汰证据。`fork()` 建立独立分支，`reframed(transform)` 同步变换相机与标定，保持真实米制地标、证据和时间；后续观测也需调用 `LandmarkObservation::reframed(transform)` 或等价变换。健康检查的配置和状态独立于运动测量、过线计数与 `AnalysisSession`，不会自动暂停这些入口或给它们替换标定。

### 保存与恢复测量状态

`MeasurementSession::checkpoint()` 保存相机、标定与运动检查点；`MeasurementSession::from_checkpoint(...)` 验证后创建新会话。直接使用米制观测时，对应 API 为 `MotionEstimator::checkpoint()` 和 `MotionEstimator::from_checkpoint(...)`。检查点数组与运行中的滤波器相互独立，修改导出数组不会改变原会话，修改导入数组也不会改变已恢复会话。

检查点包含完整有效运动配置、每条活跃轨迹的 `[x,y,vx,vy]` 与 16 项行优先协方差、首末滤波位置、累计观测折线长度、接受次数及首末接受时间。同时保存最后处理帧的时间和下一段号：空帧、投影或创新拒绝也会推进帧时间，全部轨迹关闭后仍要保留段号计数。恢复时不会预测或重置滤波，不用机器墙上时间淘汰轨迹；后续帧时间继续决定缺测与分段。

恢复会检查状态形状与有限性、协方差的对称性和半正定性、位置与速度子块的正定性、身份唯一性、时间顺序、容量、段号和路径关系。协方差验证只使用诊断副本，保存的条目原样恢复。检查点可以验证结构与状态自洽性；它没有签名或身份认证。调用方仍需管理存储权限和来源。

`codec.ReplaySession::checkpoint_json()` 导出一个版本独立的 JSON 文档，`ReplaySession::from_checkpoint_json(...)` 直接恢复它；`ReplaySession::open(...)` 接受普通配置或精确的 `{"resume":<检查点>}` 包装。检查点带有 `format:"moonground.session"`、`checkpoint_version:"1"`、`configuration` 和 `motion`。有效配置显式保存默认值，恢复只使用内嵌配置，不能覆盖标定、相机、诊断或运动参数。物理标定或运动参数改变时应创建新会话；仅换算像素坐标时使用本库的 `reframed` 或 `--reframe`，同步变换相机、标定与后续观测。

JSON 检查点最多包含 10,000 条活跃轨迹，文本最多 8,388,608 个 UTF-16 代码单元、32 层嵌套；超限导出报错，不会截断状态。恢复首行额外预留最短 `{"resume":...}` 包装的 11 个代码单元，整行最多 8,388,619 个；添加空白也占用这个上限。普通配置和帧仍各限 1,048,576 个代码单元。Int64 时间与段号使用规范十进制字符串。检查点保存继续计算所需的状态，已经输出的历史帧仍由调用方保存；恢复后的输出从后续帧开始。

### 从米制位置统计通道过线

`events.LineGate::new(gate_id, start_m, end_m, deadband_m=0.05)` 定义有限的有向线段 A→B，单位为米，左侧为正侧。端点必须有限且不同，身份长度为 1—128 个 UTF-16 代码单元。`events.GateCounter::new(session_id, gates, config)` 接受测量层的 `motion.FrameResult`；根包不额外导出事件类型。像素 session 用 `counter.update(measurement.motion)` 接入，直接米制估计则传入对应的运动结果。

死区是到通道所在直线的距离不超过 `deadband_m` 的**闭区间**；带内点不建立或改变侧别。计数器保留最近一个同侧带外点，遇到异侧带外点时，检查这两个滤波位置的连线是否穿过有限通道，通道端点包含在内。穿过延长线但没有穿过通道不计数；新位置仍成为该侧参考点。每次确认过线都会累计，往返多次会计多次，不是去重人数。

位置来自已接受的 `initializing`、`ready` 或 `uncertain` 测量，不要求速度已就绪。可在独立的 `GateConfig` 设置有限正数 `max_position_std_m`；默认不启用，启用后位置最差方向标准差超限的帧跳过该目标。缺测、投影或创新拒绝、数值失败、质量跳过、片段改变以及参考点间隔达到 `max_gap_us` 都清除相应参考点，后续不会跨越这些中断补算过线。死区内的接受帧也推进输入水位，但不会把旧参考点变成新时间。

`GateFrame` 同时返回本帧 `crossings` 和按配置顺序排列的累计 `counts`。事件按目标身份、通道顺序排列，携带目标、片段、方向、两端位置及交点。`from_timestamp_us`、`to_timestamp_us` 保留精确 Int64 微秒区间；`to_timestamp_us` 是离开死区并确认换侧的帧时间，`crossing_fraction` 是该弦上交点的比例。库不生成浮点绝对过线时间，也不把滤波弦交点解释为未观测的真实路径或真实过线时刻。几何运算溢出或过线比例舍入至区间端点时会报错；整帧验证或计算失败不提交计数、水位及参考点。

`GateConfig` 默认 `max_gap_us=500000`、`max_tracks=1000`，轨迹上限范围为 1—10,000。每个计数器配置 1—16 条通道，`通道数 × max_tracks` 不超过 65,536，限制参考点槽位。计数用非负 Int64 保存，溢出报错。通道身份必须唯一，输入会话、严格递增时间和片段身份也须自洽；计数器不修改测量滤波器或生成预测点。

`GateCounter::checkpoint()` 和 `GateCounter::from_checkpoint(...)` 保存、验证并独立恢复版本 1 的配置、时间水位、两方向累计计数及各目标的参考点。独立入口分别保存测量与通道检查点，宿主需在同一 session、同一已处理帧配对；下面的联合入口统一管理两侧状态。通道或参数改变时新建计数器；米制坐标系改变时重新定义通道，同一物理标定的像素 `reframed` 不改变米制通道。

### 用法向协方差确认通道侧别

同一位置协方差在通道法向和切向可能差别很大。`events.EvidenceGateCounter::new(session_id, gates, config, sigma_multiplier=2.0)` 直接读取运动帧中的位置协方差 `Σ`，沿通道单位法向 `n` 计算 `σ=√(nᵀΣn)`。令带符号距离为 `d`，整个 `[d-kσ,d+kσ]` 严格高于 `deadband_m` 才确认正侧，严格低于 `-deadband_m` 才确认负侧；接触闭死区或跨越死区均为未确认。`k` 必须有限且非负。

下面的输入来自真实运动估计器：切向标准差为 10 米，法向标准差为 0.1 米，仍可确认水平通道的侧别。保存检查点后，使用同一上游的下一运动帧继续统计：

```mbt check
///|
test "README: normal covariance evidence resumes from an independent checkpoint" {
  let motion = @moonground.MotionEstimator::new(
    "normal-evidence",
    @moonground.MotionConfig::new(gate=1.0e12, max_tracks=10),
  )
  let counter = @events.EvidenceGateCounter::new(
    "normal-evidence",
    [@events.LineGate::new("aisle", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, })],
    @events.GateConfig::new(max_tracks=10),
  )
  let observe = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::new(100.0, 0.0, 0.01),
    )
  }
  let initial = counter.update(motion.update(0L, [observe(-1.0)]))
  assert_eq(initial.evidence[0].side, -1)
  assert_true((initial.evidence[0].normal_std_m - 0.1).abs() < 1.0e-12)
  let continued = @events.EvidenceGateCounter::from_checkpoint(
    counter.checkpoint(),
  )
  let result = continued.update(motion.update(100000L, [observe(1.0)]))
  assert_eq(result.counting.counts[0].negative_to_positive, 1L)
  assert_eq(result.counting.crossings[0].from_timestamp_us, 0L)
  assert_eq(result.counting.crossings[0].to_timestamp_us, 100000L)
  assert_eq(counter.checkpoint().last_timestamp_us, Some(0L))
}
```

`EvidenceGateFrame` 返回原有 `counting:GateFrame` 和当前有效目标的 `evidence`，包括距离、法向标准差、带端点及 `side`（`-1/0/1`）。侧别未确认时保留先前确认点的坐标、协方差与**原时间**，不会刷新其 `max_gap_us` 寿命；任一侧重新确认时更新参考点。缺测、拒绝、位置质量跳过、换段与过期沿用原计数器的清除规则。可选 `max_position_std_m` 仍检查测量提供的最差方向标量，并未改为法向门限。接受状态须携带真实正定位置协方差；提供的无效协方差在质量跳过前也会使整帧失败。`k=0` 仍计算法向诊断，在数值支持域内直接使用原均值侧别。

该带只用于确认两侧；过线仍检查两个确认位置的**均值弦**与有限通道相交。它不表达概率覆盖率、有限端点或过线时长的置信范围；协方差继续以固定标定、相机和锚点为条件。相关协方差先作幂二缩放与补偿行列式计算：缩放后的主元为 `a`、另一对角为 `c`、行列式为 `det`，要求 `det/(a*c)>64ε`（`ε=2^-52`），且缩放后的 LDL 残差 `det/a≥16·2^-1022`。近完美相关或残差下溢会报错；无相关项的对角协方差单独计算，支持原正定验证允许的极各向异性。法向标准差须有限正值；正 `k` 的半径须有限正值，两个端点还须有限且严格满足 `lower<d<upper`，舍入后未展开也会拒绝，不会输出虚假的零或无穷值。

这是独立的下游计数器，原 `AnalysisSession`、`guarded`、`transit` 的计数策略保持。使用门控结果时，逐帧转发 `frame.analysis.measurement.motion`，包括空帧、阻断帧和 `replace_projection` 的空切换帧，才能及时清除参考点。独立计数失败只保留自身状态，已提交的上游测量由宿主管理；需要共同更新与恢复时，使用下面的 `EvidenceAnalysisSession`。

`checkpoint()`／`from_checkpoint(...)` 使用独立 `EvidenceGateCheckpoint`，完整保存 `k`、配置、累计及各参考点的原协方差，验证形状、容量、年龄、正定性和确认侧别；`fork()` 建立独立分支。旧公开 record 和 `GateCheckpoint` 保持，缺少协方差的旧检查点不能自动迁移为新检查点，也不能静默降级丢失策略。恢复核对保存状态自洽性，不认证历史观测。

### 联合测量、计数与恢复

`analysis.AnalysisSession::from_pixel(measurement, counter)` 验证并复制位于同一水位的两个现有实例；两者均未开始时也可直接组合。输入已经是米制观测时使用 `from_ground(estimator, counter)`。通过 `update_pixel` 或 `update_ground` 直接传入原始观测、时间与 `lost`／`removed`，一次返回 `AnalysisFrame.measurement` 和 `counting`，无需先把测量结果编码再交给计数器。

联合更新先建立独立候选分支，测量和计数都完成后提交。计数溢出、不可表示的通道几何或计数容量错误也会回滚该帧的测量状态、协方差、路径、接受次数、段号分配和时间；修正后可用同一时间重试。按目标报告的投影拒绝、创新拒绝和数值失败仍是一个已提交帧，计数器按原有规则清除相应参考点。两层容量可不同，较严的计数限制可能拒绝整帧。

`AnalysisSession::checkpoint()` 导出版本 1 的 `AnalysisCheckpoint`；`from_checkpoint` 验证并创建独立实例。检查点的 `measurement` 为 `Pixel(MeasurementCheckpoint)` 或 `Ground(MotionCheckpoint)`，`counting` 保存完整 `GateCheckpoint`。除了各自的原有验证，还检查 session 与帧水位相同、当前接受且通过计数质量门限的目标集合完全一致、目标片段匹配，以及参考点属于该段的接受时间区间。当前点在带外时，参考点必须等于当前滤波点并具有当前时间；当前点在闭死区内时，可保留有效的旧带外参考点。当前滤波状态不足以重建过去全部位置，因此恢复只核对历史参考点的结构和时间关系。

`AnalysisSession::fork()` 创建独立计算分支；`MotionEstimator`、`MeasurementSession` 与 `GateCounter` 也提供 `fork()`。它们复制可变容器，内部已接受数组在后续更新中以新值替换；组合执行不逐帧导出、深拷贝和重新验证检查点。导出与导入检查点继续隔离全部可变数组。`AnalysisSession::reframed(transform)` 仅用于 pixel 模式：新实例同步换算相机与标定，完整保留米制运动、通道、参考点和计数，后续像素观测也须使用同一变换。

一个完整检查点消除了手工配对两侧水位的步骤。外部观测日志、文件原子替换和结果交付进度仍由宿主处理；检查点没有签名，也不自动去重下游事件。下游可用 `(session_id, gate_id, track_id, segment_id, to_timestamp_us)` 识别单次事件。

### 联合测量与法向证据

`analysis.EvidenceAnalysisSession::from_pixel(measurement, evidence_counter)` 与 `from_ground(estimator, evidence_counter)` 验证并独立拥有位于同一水位的两个实例。它直接拥有测量引擎，与原均值 `AnalysisSession` 并列；`update_pixel`／`update_ground` 输入原始观测，返回 `EvidenceAnalysisFrame { measurement, counting:EvidenceGateFrame }`。两侧在分支中完成后一起提交，法向数值域、几何、容量或累计溢出也会回滚测量状态、协方差、路径、水位与段号分配，可用同一时刻修正重试。逐目标投影、创新拒绝与数值失败仍按原测量语义提交该帧，并清除对应证据参考点。

下面从一份完整检查点继续米制测量与证据计数，再显式结束当前片段：

```mbt check
///|
test "README: evidence analysis resumes both engines from one checkpoint" {
  let session = @analysis.EvidenceAnalysisSession::from_ground(
    @moonground.MotionEstimator::new(
      "joint-evidence",
      @moonground.MotionConfig::new(gate=1.0e12, max_tracks=10),
    ),
    @events.EvidenceGateCounter::new(
      "joint-evidence",
      [
        @events.LineGate::new("aisle", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
  )
  let observe = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  ignore(session.update_ground(0L, [observe(-1.0)]))
  let restored = @analysis.EvidenceAnalysisSession::from_checkpoint(
    session.checkpoint(),
  )
  let crossed = restored.update_ground(100000L, [observe(1.0)])
  assert_eq(crossed.counting.counting.counts[0].negative_to_positive, 1L)
  let stopped = restored.interrupt(200000L)
  assert_eq(stopped.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(stopped.counting.evidence.length(), 0)
  assert_eq(stopped.counting.counting.counts[0].negative_to_positive, 1L)
  assert_eq(session.checkpoint().counting.last_timestamp_us, Some(0L))
}
```

`EvidenceAnalysisCheckpoint` 内嵌原 `AnalysisMeasurement` 和完整 `EvidenceGateCheckpoint`。恢复先校验两个原状态，再核对会话、水位，以及本帧已接受且通过原标量位置质量门限的目标集合与片段。当前侧别复用 `LineGate::evidence_side` 的完整输入校验与数值核；质量跳过先于该核，未确认也须有可表示的当前证据。确认侧别要求参考点具有当前时刻、当前滤波坐标及**原位置协方差**；读取运动保存的 `P00/P01/P11`，不把允许的下三角舍入差异平均进去。未确认时可没有参考点，或保留仍在片段时间区间内的合法旧参考点；恰位于片段首时刻的点必须等于保存的首滤波位置。当前状态不能证明任意历史坐标与协方差的来源，恢复只核对可证明的状态关系。

`fork()` 独立分支不逐帧导出检查点；pixel `reframed(transform)` 同步换算标定、相机与未来像素输入，保留米制运动和全部证据状态。两模式均可 `interrupt(timestamp_us)`，在严格更晚的空帧关闭全部活跃片段，包括上一帧未输出的对象，清除参考点并保留累计与下一段号。两侧容量可不同，较严的计数容量也可能原子拒绝中断。该入口沿用前述侧别证据含义，不改变健康门控或区间统计策略；外部存储、日志与输出交付仍由宿主协调。

### 显式按地标健康状态控制对象分析

`guarded.GuardedSession::new(analysis, health)` 把像素分析与地标检查绑定为一个独立实例。每帧 `update(timestamp_us, landmarks, observations, lost~, removed~)` 先计算当前地标证据，仅 `HealthStatus::Healthy` 放行对象观测；其他状态都在同一时间中断全部活跃对象片段。刚从符合阈值切换为超限证据时，状态已是 `pending`，该帧立即阻断，无需等待 `drift` 确认。

下面显式使用一个样本、零确认跨度，缩短放行与阻断示例；默认地标确认要求仍是三个样本和 300,000 微秒。

```mbt check
///|
test "README: explicit landmark policy ends blocked paths and starts a fresh segment" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 20.0, y: 0.0, },
      { x: 20.0, y: 20.0, },
      { x: 0.0, y: 20.0, },
    ],
  )
  let analysis = @analysis.AnalysisSession::from_pixel(
    @moonground.MeasurementSession::new(
      "guarded-example",
      calibration,
      @moonground.MotionConfig::new(max_tracks=10),
    ),
    @events.GateCounter::new(
      "guarded-example",
      [@events.LineGate::new("door", { x: 1.0, y: 0.0, }, { x: 1.0, y: 2.0, })],
      @events.GateConfig::new(max_tracks=10),
    ),
  )
  let known = [
    @health.KnownLandmark::new("A", { x: 0.0, y: 0.0, }),
    @health.KnownLandmark::new("B", { x: 1.0, y: 0.0, }),
    @health.KnownLandmark::new("C", { x: 0.0, y: 1.0, }),
  ]
  let health = @health.CalibrationMonitor::new(
    calibration,
    known,
    @health.HealthConfig::new(confirmation_us=0L, min_observations=1),
  )
  let session = @guarded.GuardedSession::new(analysis, health)
  let landmarks = known.map(point => {
    @health.LandmarkObservation::new(
      point.landmark_id,
      { x: point.ground_m.x * 10.0, y: point.ground_m.y * 10.0, },
      @moonground.Covariance2::isotropic(0.1),
    )
  })
  let object = @moonground.PixelObservation::new(
    7,
    { x: 5.0, y: 5.0, },
    @moonground.Covariance2::isotropic(0.1),
  )
  assert_eq(session.update(0L, landmarks, [object]).decision, @guarded.Allowed)
  let blocked = session.update(100000L, [], [object])
  assert_eq(blocked.decision, @guarded.Blocked)
  assert_eq(blocked.suppressed_track_ids, [7])
  assert_eq(blocked.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(blocked.analysis.measurement.motion.tracks.length(), 0)
  let restored = @guarded.GuardedSession::from_checkpoint(session.checkpoint())
  let resumed = restored.update(200000L, landmarks, [object])
  assert_eq(resumed.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(resumed.analysis.measurement.motion.tracks[0].accepted_count, 1)
  assert_eq(resumed.analysis.measurement.motion.tracks[0].speed_mps, None)
  let barrier = restored.replace_projection(300000L, calibration, camera=None)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["2"])
  let reconfirmed = restored.update(400000L, landmarks, [object])
  assert_eq(reconfirmed.analysis.measurement.motion.tracks[0].segment_id, "3")
  assert_eq(reconfirmed.analysis.measurement.motion.tracks[0].accepted_count, 1)
}
```

组合只支持 pixel 模式。分析与健康检查必须具有相同的时间水位，以及逐值相同的存储归一化单应矩阵、原顺序 ROI、`max_meters_per_pixel` 和地面噪声方差；`GroundCalibration::same_projection` 提供此身份检查，拟合／核验诊断不参与比较。相机必须同时存在或同时省略；存在时九项内参与 Brown 系数以及归一化有效半径都须相同。这里校验固定配置身份，不尝试用浮点容差判断两个不同标定是否近似等价。

计数器的 `max_tracks` 须至少覆盖运动测量的 `max_tracks`，确保任意阻断帧都能完整关闭全部片段。阻断不会只清除本帧可见目标：上一帧未输出但仍在滤波器中保留的活跃轨迹也会关闭，`closed_segment_ids` 明确列出片段。该帧仍提交健康证据、共同时间和空分析结果，保留两方向累计计数及下一段号。恢复健康后，同一目标身份获得新段、从一次接受观测重新预热，观测路径和过线参考点不会跨越阻断区间。

阻断期间原始对象载荷仍须通过有限像素、正定协方差、身份唯一／互斥和容量检查，随后才抑制对象计算；这些像素不经过被阻断的标定投影。`suppressed_track_ids` 仅包含本帧提交的观测身份并按数值排序，关闭的旧片段则另见分析结果。放行时沿用原有的逐目标投影拒绝、创新拒绝和数值失败语义。健康、测量或计数发生整帧错误时，三个组件都保留原状态，可修正后用同一时间重试。

`GuardedCheckpoint` 版本 1 同时保存完整分析和健康检查点。恢复先验证原有状态，再检查共同配置与水位：非健康状态不得带有活跃运动轨迹或过线参考点；健康状态中的片段首末时刻与门参考点须符合可达到的确认时间；即时确认及较短健康采样间隔的连续片段例外见下节。这些是状态自洽检查，检查点不证明过去每次地标观测的真实性。`fork()` 创建独立分支，`reframed(transform)` 同时换算两侧固定像素配置，保持米制地标、路径、计数、证据和时间；未来对象与地标观测都须应用同一变换。

`AnalysisSession::interrupt(timestamp_us)` 也可由宿主显式调用，使用普通原子更新结束全部活跃段。`CalibrationMonitor::status()` 读取最后已提交地标帧的状态，不增加样本数或按墙上时间推断新证据。原有独立分析和健康检查继续分别工作；门控入口的放行含义仍受固定地标覆盖与原有测量条件限制，不认证未观测区域，也不自动重标定。

`GuardedSession::replace_projection(timestamp_us, calibration, camera~)` 显式安装宿主提供的新标定与相机。`camera` 是必填命名选项：`Some(model)` 安装模型，`None` 撤除校正；后续像素须遵循新配置的约定。新标定仍须使用原米制地面坐标系，因为会话身份、全部地标身份及真值、通道定义、测量／健康配置、双向累计和下一段号继续保留。地面坐标系或这些物理定义改变时，新建相应会话。

切换消耗一个空帧，时间严格晚于共同水位，未开始时可从非负时间切换。它关闭全部活跃段，包括最近一帧未输出的滤波器，清除过线参考点与健康证据，返回 `Blocked`、`Insufficient`、空对象和完整关闭段，`suppressed_track_ids=[]`。后续时间必须更晚，并重新采样确认健康、分配新段及预热；本例即使使用等值标定也执行完整重置，零确认跨度／一个样本仍需下一观测帧才可放行。候选全部成功后才替换运行状态，失败保留旧投影、滤波状态、证据和计数，可修正后用同一时间重试。

切换后的完整检查点保存两侧新的相同投影和共同水位，沿用原恢复约束与版本，不保存历史标定日志。切换帧也应送到下游 `TransitCounter`，正常取消待入口；分别保存上游和区间状态时仍须协调共同水位。像素缩放、裁剪和补边继续使用 `reframed`，保留同一物理投影及米制历史；显式替换用于改变标定或相机模型并重新开始证据。

### 地标健康与法向证据的三方原子分析

`guarded.EvidenceGuardedSession::new(evidence_analysis, health)` 直接拥有 v0.13 的证据分析与原地标监测器，与均值 `GuardedSession` 并列。`update` 使用相同的原始地标、对象和生命周期输入，返回 `EvidenceGuardedFrame { decision, health, analysis:EvidenceAnalysisFrame, suppressed_track_ids }`。仅本帧 `Healthy` 放行；其余状态立即关闭全部活跃片段并清除证据参考点，包括上一帧未输出的对象。原对象载荷仍先经过结构校验，阻断时不投影，也不运行法向数值核。

下游证据计算失败时，健康候选也不提交：即使本帧本来会从 `Pending` 首次变成 `Healthy`，确认样本数、时间水位、运动状态与段号仍全部保留，可修正对象后用同一时间重试。逐目标拒绝继续按原语义提交该帧；`kσ` 仍只确认通道侧别，不增加概率、有限端点或过线时间置信含义。

此例将地标数设为 1、确认条件设为两个样本与 100,000 微秒，用一份完整检查点恢复后显式切换投影，再重新采样确认：

```mbt check
///|
test "README: evidence guard restores three components and reconfirms after projection replacement" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 1.0],
    [
      { x: 0.0, y: 0.0, },
      { x: 20.0, y: 0.0, },
      { x: 20.0, y: 20.0, },
      { x: 0.0, y: 20.0, },
    ],
  )
  let session = @guarded.EvidenceGuardedSession::new(
    @analysis.EvidenceAnalysisSession::from_pixel(
      @moonground.MeasurementSession::new(
        "evidence-guard",
        calibration,
        @moonground.MotionConfig::new(max_tracks=10),
      ),
      @events.EvidenceGateCounter::new(
        "evidence-guard",
        [
          @events.LineGate::new("door", { x: 1.0, y: 0.0, }, { x: 1.0, y: 2.0, }),
        ],
        @events.GateConfig::new(max_tracks=10),
        sigma_multiplier=3.0,
      ),
    ),
    @health.CalibrationMonitor::new(
      calibration,
      [@health.KnownLandmark::new("A", { x: 1.0, y: 1.0, })],
      @health.HealthConfig::new(
        min_landmarks=1,
        confirmation_us=100000L,
        min_observations=2,
      ),
    ),
  )
  let covariance = @moonground.Covariance2::isotropic(0.1)
  let references = [
    @health.LandmarkObservation::new("A", { x: 10.0, y: 10.0, }, covariance),
  ]
  let object = @moonground.PixelObservation::new(
    7,
    { x: 5.0, y: 5.0, },
    covariance,
  )
  assert_eq(session.update(0L, references, [object]).decision, @guarded.Blocked)
  assert_eq(
    session.update(100000L, references, [object]).decision,
    @guarded.Allowed,
  )
  let restored = @guarded.EvidenceGuardedSession::from_checkpoint(
    session.checkpoint(),
  )
  let barrier = restored.replace_projection(150000L, calibration, camera=None)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(
    restored.update(200000L, references, [object]).decision,
    @guarded.Blocked,
  )
  let fresh = restored.update(300000L, references, [object])
  assert_eq(fresh.decision, @guarded.Allowed)
  assert_eq(fresh.analysis.measurement.motion.tracks[0].segment_id, "2")
  assert_eq(restored.checkpoint().analysis.counting.sigma_multiplier, 3.0)
}
```

`EvidenceGuardedCheckpoint` 保存完整 `EvidenceAnalysisCheckpoint` 和 `HealthCheckpoint`，只接受 pixel 模式。恢复沿用证据分析的当前协方差／历史参考点关系，再绑定共同水位、完整投影及 Brown 相机配置，要求计数容量覆盖测量容量。非健康状态不能保留活跃运动或计数目标；健康状态检查全部活跃片段（含隐藏轨迹）的首末时刻与门参考点，约束如下。历史坐标、协方差与地标观测仍是状态自洽检查，检查点不认证历史来源，也不扩大固定地标对场地的覆盖结论。

`fork()`、`reframed(transform)` 和 `replace_projection(timestamp_us, calibration, camera~)` 延续前述分支、共同像素换算和空帧屏障语义。显式替换保留原 `sigma_multiplier`、通道累计、下一段号、地标真值与配置，关闭全部旧段并清除健康确认序列；后续更晚帧重新确认和预热。该入口不改旧门控／区间统计的策略，外部日志、文件和事件交付由宿主管理。

### 健康门控下的证据通行事务

`guarded.EvidenceGuardedTransitSession` 直接拥有一个 `analysis.EvidenceTransitSession` 和原地标监测器，把健康确认、运动、法向证据、待入口及完成累计一起提交。`update(timestamp_us, landmarks, observations, ...)` 仅在当前地标状态 `Healthy` 时计算对象，其余状态用同一个空帧关闭全部活跃片段并以 `Discontinuity` 取消待入口。阻断仍验证对象身份、有限像素、正定协方差及容量，随后跳过对象投影和法向数值核。

下游数值或累计失败也回滚本帧健康样本、确认进度和水位，包括首次达到健康的帧。`EvidenceGuardedTransitFrame.analysis` 是原 v0.16 联合帧，包含 `measurement` 与 `transit`；完整检查点同时保存该联合状态和原健康状态，使用一个恢复入口。

```mbt check
///|
test "README: health-controlled evidence transit restores pending entry and preserves completion on replacement" {
  let calibration = @moonground.GroundCalibration::from_homography(
    [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    [
      { x: -10.0, y: -10.0, },
      { x: 10.0, y: -10.0, },
      { x: 10.0, y: 10.0, },
      { x: -10.0, y: 10.0, },
    ],
    max_meters_per_pixel=2.0,
  )
  let transit = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "guarded-transit-example",
      [
        @events.LineGate::new("entry", { x: -5.0, y: 0.0, }, { x: 5.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: -5.0, y: 2.0, }, { x: 5.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
      sigma_multiplier=2.0,
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let session = @guarded.EvidenceGuardedTransitSession::new(
    @analysis.EvidenceTransitSession::from_pixel(
      @moonground.MeasurementSession::new(
        "guarded-transit-example",
        calibration,
        @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
      ),
      transit,
    ),
    @health.CalibrationMonitor::new(
      calibration,
      [@health.KnownLandmark::new("A", { x: 1.0, y: 1.0, })],
      @health.HealthConfig::new(
        min_landmarks=1,
        confirmation_us=100000L,
        min_observations=2,
      ),
    ),
  )
  let covariance = @moonground.Covariance2::isotropic(0.01)
  let landmarks = [
    @health.LandmarkObservation::new("A", { x: 1.0, y: 1.0, }, covariance),
  ]
  let object = (y : Double) => {
    @moonground.PixelObservation::new(7, { x: 0.0, y, }, covariance)
  }
  assert_eq(
    session.update(0L, landmarks, [object(-1.0)]).decision,
    @guarded.Blocked,
  )
  ignore(session.update(100000L, landmarks, [object(-1.0)]))
  assert_eq(
    session.update(200000L, landmarks, [object(1.0)]).analysis.transit.pending_count,
    1,
  )
  let restored = @guarded.EvidenceGuardedTransitSession::from_checkpoint(
    session.checkpoint(),
  )
  assert_eq(
    restored.update(300000L, landmarks, [object(3.0)]).analysis.transit.passages.length(),
    1,
  )
  let barrier = restored.replace_projection(350000L, calibration, camera=None)
  assert_eq(barrier.decision, @guarded.Blocked)
  assert_eq(barrier.health.status, @health.Insufficient)
  assert_eq(barrier.analysis.transit.counts[0].completed, 1L)
  assert_eq(barrier.analysis.measurement.motion.closed_segment_ids, ["1"])
  assert_eq(
    restored.update(400000L, landmarks, [object(-1.0)]).decision,
    @guarded.Blocked,
  )
  let fresh = restored.update(500000L, landmarks, [object(-1.0)])
  assert_eq(fresh.decision, @guarded.Allowed)
  assert_eq(fresh.analysis.measurement.motion.tracks[0].segment_id, "2")
}
```

`from_checkpoint` 先验证 v0.16 联合状态及已知历史端点，再绑定 pixel 模式、共同投影／相机、水位及容量。非健康状态不能保留活跃运动、证据目标或待入口。所有门控恢复还检查活跃片段首末点、门参考点和本入口的待入口端点所对应的健康确认时间。

通常，已接受时刻须不早于当前健康序列可能满足确认跨度和最少样本数的时刻。有一个可达例外：`min_observations=1`、`confirmation_us=0` 且健康 `max_gap_us` 小于运动 `max_gap_us` 时，一帧长间隔可重启健康序列并立即仍为 `Healthy`，运动片段则继续。此时允许早于新序列起点 `S` 的已知时刻 `t`，但必须满足 `S-t >= health.max_gap_us`；落在该开区间内的已知接受时刻会否定健康采样断档，恢复应拒绝。该检查覆盖隐藏轨迹，不补造未保存的历史样本。v0.17 同时修复原两种门控对这类自身可生成检查点的误拒，旧更新、record 和协议格式保持。

`fork()` 独立复制可变状态；`reframed(transform)` 共同换算两侧像素配置，保留米制运动、原证据协方差、待入口及健康序列。`replace_projection(timestamp_us, calibration, camera~)` 使用严格更晚的空帧屏障：取消待入口、关闭全部活跃段并重新冷确认，保留门／区间定义、等待期限、倍率、过线及完成累计、下一段号和地标真值。等值投影的显式替换也重置；失败整体保留原状态。外部日志、存储和事件交付由宿主协调。

### 两个通道之间的通行时间

`transit.TransitCounter` 拥有独立的 `GateCounter`，直接消费 `motion.FrameResult`，复用有限通道、死区、接受状态和位置质量规则。`Section::new(id, entry_gate_id, entry_direction, exit_gate_id, exit_direction)` 指定两个不同通道及各自方向。下面把真实运动估计帧交给区间统计，保留入口检查点后继续到出口：

```mbt check
///|
test "README: measured motion completes a directional transit after checkpoint recovery" {
  let motion = @moonground.MotionEstimator::new(
    "transit-example",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let transit = @transit.TransitCounter::new(
    @events.GateCounter::new(
      "transit-example",
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let observation = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  ignore(transit.update(motion.update(0L, [observation(-1.0)])))
  assert_eq(
    transit.update(motion.update(100000L, [observation(1.0)])).pending_count,
    1,
  )
  let restored = @transit.TransitCounter::from_checkpoint(transit.checkpoint())
  let result = restored.update(motion.update(200000L, [observation(3.0)]))
  assert_eq(result.passages.length(), 1)
  assert_eq(result.counts[0].completed, 1L)
  assert_eq(result.passages[0].elapsed_upper_us, 200000L)
  assert_true(result.passages[0].estimated_elapsed_us > 0.0)
}
```

区间按同一 `track_id` 和 `segment_id` 配对，每区间每目标最多保留一个待出口入口。缺测、逐目标拒绝、位置质量跳过、关闭或换段，以及相邻帧间隔达到通道 `max_gap_us`，都立即以 `discontinuity` 取消。处理 `guarded` 结果时，须逐帧传入 `frame.analysis.measurement.motion`，包括阻断后的空帧；省略空帧会丢失连续性证据。

`max_duration_us` 默认 300,000,000 微秒，限制从入口**确认帧**到当前帧的等待：差值达到上限即 `expired`，在本帧出口处理之前取消。连续性失效优先于超时。反向穿过任一边界取消为 `reversed`；重新正向穿过入口，以 `reentered` 取消旧入口后保存新入口。没有入口的出口不补配过去记录。

同帧事件不按通道配置顺序处理。仅当入口括号末端不晚于出口括号起点，或两事件具有逐值相同的首末时刻及端点、且入口比例严格较小时，才证实顺序并生成 `TransitPassage`。后者支持同一弦内的同帧双过线。不同弦的重叠括号或同弦相同比例为 `ambiguous_order`，取消该目标在该区间的待入口，也不从这两条事件建立新入口。

`entry`、`exit` 保留原始精确 Int64 时间括号。`elapsed_lower_us=max(0, exit.from-entry.to)`、`elapsed_upper_us=exit.to-entry.from` 是这些括号推导的保守闭包界；`estimated_elapsed_us` 单独假设沿过滤弦线性插值。先做整数差，再计算相对浮点时长，不将绝对时钟转为浮点。这里的界不是置信区间，估计也不是精确物理过线时刻；确认等待上限不是插值时长上限。两个通道没有声明路径长度，库不把门间距、交点直线距离或过滤折线路径当作实际路程，也不输出区间平均速度。

`TransitFrame` 同时返回原有 `counting`、本帧 `passages`、`cancellations`、各区间累计完成数及 `pending_count`。输出按区间配置顺序、目标身份排列；同一身份的多次取消保留因果顺序。区间数量为 1—16，区间数乘通道目标容量不得超过 65,536。整帧验证、几何或累计溢出失败时，通道与配对状态一起保留，可修正后用同一时间重试；上游已经提交的运动测量由宿主协调。

`new` 复制并验证给定计数器；允许已开始的计数器，保留通道累计，区间完成数从零开始，不追溯入口。`checkpoint()` 同时保存通道、区间、完成数和待入口；`from_checkpoint` 核对几何、方向、当前目标片段、时间、期限及累计关系，隔离可变数组。它验证状态自洽性，不认证历史过线。`fork()` 建立独立分支。区间检查点不含上游测量或健康状态；分别持久化时，宿主须保存同一已处理帧的状态并从更晚帧续接。

### 以法向证据确认入口和出口

`transit.EvidenceTransitCounter` 拥有独立的 `EvidenceGateCounter`，复用 `Section`、`TransitPassage` 和取消原因。`new(counting, sections, max_duration_us~)`、`update(FrameResult)`、`checkpoint()`、`from_checkpoint()`、`fork()` 与前述均值入口并列；结果 `EvidenceTransitFrame.counting` 保留完整法向证据及原通道结果。入口、出口都须通过各自 `d ± kσ` 的闭死区确认；未确认位置保留各门原参考点和时间，质量策略仍取原位置标准差。

```mbt check
///|
test "README: covariance-confirmed transit restores its endpoint evidence" {
  let motion = @moonground.MotionEstimator::new(
    "evidence-transit-example",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let transit = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "evidence-transit-example",
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let observation = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  ignore(transit.update(motion.update(0L, [observation(-1.0)])))
  assert_eq(
    transit.update(motion.update(100000L, [observation(1.0)])).pending_count,
    1,
  )
  let restored = @transit.EvidenceTransitCounter::from_checkpoint(
    transit.checkpoint(),
  )
  let result = restored.update(motion.update(200000L, [observation(3.0)]))
  assert_eq(result.passages.length(), 1)
  assert_eq(result.counts[0].completed, 1L)
  assert_eq(result.passages[0].elapsed_upper_us, 200000L)
  assert_true(result.passages[0].estimated_elapsed_us > 0.0)
}
```

不同门可以在不同帧确认，也可以从不同参考点产生同帧事件。配对复用前述精确时间括号／逐值相同弦的判序规则；同一输出帧不意味着同一弦，重叠异弦不能按比例或配置顺序强行完成。时长界仍来自确认位置的均值弦括号，插值仍是单独估计，均不附加过线时刻的概率含义。`max_duration_us` 从入口确认帧计算，未确认帧不刷新它。

`EvidenceTransitCheckpoint` 保存完整证据计数器、区间、累计和待入口；每条 `EvidenceTransitPending` 额外保存真实入口两端的 `from_covariance`、`to_covariance`。恢复除原几何、片段、期限和累计约束外，还用保存的 `sigma_multiplier` 重验两端确实确认相反侧别。检查的是状态自洽性，不能认证历史数据来源；旧均值检查点没有这些信息，不能直接迁移。更新使用独立分支，一次提交证据和配对状态，失败保留整个下游；不回滚已经提交的上游。

逐帧传入普通 `MeasurementFrame.motion`，或 `EvidenceGuardedFrame.analysis.measurement.motion`，包括阻断与投影替换的空帧。空帧立即取消待入口；恢复健康后的新片段不会补配旧入口。完整下游检查点不含上游运动或健康状态，宿主须保存共同已处理水位，从严格更晚的原时钟续接。

### 从原始观测联合计算证据通行

`analysis.EvidenceTransitSession` 直接拥有像素／米制测量引擎和一个 `EvidenceTransitCounter`。`from_pixel(measurement, transit)`／`from_ground(measurement, transit)` 接受初始或已开始的两个组件，验证共同状态后建立独立会话。每帧先计算运动候选，证据与配对成功后共同提交；下游数值、容量或累计错误会保留原运动状态、协方差、路径、水位、下一段号，以及待入口和全部累计，可修正后用同一时间重试。

`EvidenceTransitSessionFrame` 包含原 `measurement` 和 `transit`。完整 `EvidenceTransitSessionCheckpoint` 同时保存原测量检查点和 v0.15 证据通行检查点，恢复验证共同会话、水位、当前接受目标、质量策略、片段和当前位置协方差。待入口两端必须在对应运动片段内；首时刻端点匹配片段首点，当前端点匹配当前滤波位置及其原位置协方差。

恢复还合并每条轨迹的首末点、所有门参考点和待入口端点：同一时刻的位置必须逐值一致，已知协方差也必须一致，去重后的时刻数不能超过该轨迹的接受观测数。片段首协方差未保存在运动状态中时，不从当前协方差反推它。这些约束检查保存状态的局部一致性，不认证未保存的观测历史；时长界与插值仍沿用 v0.15 的均值弦含义。

`fork()` 复制可变容器；`reframed(transform)` 对 pixel 模式建立独立换算分支，米制运动、证据协方差、待入口端点和累计保持。`interrupt(timestamp_us)` 关闭全部活跃片段，包括上一帧未输出的隐藏轨迹，并用同一个更晚空帧取消待入口、清除门参考点，保留累计和下一段号。

```mbt check
///|
test "README: joint evidence transit restores measurement and pending entry together" {
  let motion = @moonground.MotionEstimator::new(
    "joint-evidence-transit-example",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let transit = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "joint-evidence-transit-example",
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let joined = @analysis.EvidenceTransitSession::from_ground(motion, transit)
  let observation = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  ignore(joined.update_ground(0L, [observation(-1.0)]))
  assert_eq(
    joined.update_ground(100000L, [observation(1.0)]).transit.pending_count,
    1,
  )
  let restored = @analysis.EvidenceTransitSession::from_checkpoint(
    joined.checkpoint(),
  )
  let result = restored.update_ground(200000L, [observation(3.0)]).transit
  assert_eq(result.passages.length(), 1)
  assert_eq(result.counts[0].completed, 1L)
  assert_eq(result.passages[0].elapsed_upper_us, 200000L)
  assert_true(result.passages[0].estimated_elapsed_us > 0.0)
}
```

### 按确认时刻汇总证据通行

`transit.EvidenceTransitWindowCounter` 消费原 `EvidenceTransitFrame`，将完成通行和取消按输入确认帧的精确 Int64 时间分入固定窗口。它只保留一个当前窗口，状态大小取决于区间和时限数量，均最多 16 项，不保留全部通行记录。v0.15 独立结果、v0.16 联合帧的 `transit` 和 v0.17 门控帧的 `analysis.transit` 可直接交给它。

每个配置时限使用已有观测弦时长闭区间 `[L,U]`：`U <= limit` 计入 `within`，`L > limit` 计入 `exceeded`，其余计入 `indeterminate`。三项之和等于该区间本窗完成数，表示相对于已有观测界的确定达标、确定超时与无法判定；原时长界没有增加真实行驶时长或概率含义。五类取消单独计数，不作为零时长完成。

```mbt check
///|
test "README: evidence transit windows resume aggregates at the original confirmation clock" {
  let motion = @moonground.MotionEstimator::new(
    "window-example",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let upstream = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "window-example",
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let windows = @transit.EvidenceTransitWindowCounter::new(
    upstream.checkpoint(),
    window_us=200000L,
    duration_limits_us=[0L, 100000L, 200000L],
  )
  let observation = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  for index, y in [-1.0, 1.0] {
    let transit = upstream.update(
      motion.update(index.to_int64() * 100000L, [observation(y)]),
    )
    ignore(windows.update(transit))
  }
  let restored = @transit.EvidenceTransitWindowCounter::from_checkpoint(
    windows.checkpoint(),
  )
  let transit = upstream.update(motion.update(200000L, [observation(3.0)]))
  let result = restored.update(transit)
  assert_eq(result.closed_window.unwrap().input_frames, 2L)
  assert_eq(result.current_window.start_us, 200000L)
  assert_eq(result.current_window.sections[0].completed, 1L)
  assert_eq(
    result.current_window.sections[0].duration_limits[1].indeterminate,
    1L,
  )
  assert_eq(result.current_window.sections[0].duration_limits[2].within, 1L)
  assert_eq(result.unobserved_windows, 0L)
}
```

`new(upstream_checkpoint, window_us~, duration_limits_us~, origin_us~=0)` 完整验证原上游检查点，提取配置、共同起点和完成累计基线。即使上游已经开始，新统计仍从 `current_window=None` 开始；不会把检查点自身当作新输入帧，也不回填原有完成数。原待入口继续由上游保存，之后确认完成时计入相应确认窗。下一输入必须晚于基线水位，且不早于 `origin_us`。已有上游水位也须不早于该原点。

输入帧包括空帧、阻断和投影替换。严格验证会话、顺序、门与区间定义、过线几何、完成时长、当前出口与累计增量；各区间的完成累计增量必须恰等于所提供的完成条数。重复帧或漏掉完成结果会拒绝整帧，失败保留当前窗、累计与水位，可修正后同时间重试。统计不重放过去的测量、健康确认或原协方差判定，宿主负责结果来源与完整转发。

窗口按 `T-origin` 的整数余数求起点，不把绝对时钟转为浮点。恰在排他终点的帧属于下一窗；`end_exclusive_us=None` 表示该窗数学终点超出 Int64 可表示时钟，仍可处理 `Int64.MAX`。跨窗只返回一个 `closed_window` 和一个新 `current_window`，中间没有收到输入的窗数由 `unobserved_windows` 给出，不枚举或补零。首帧前没有虚构窗口；`input_frames` 与首末输入时刻只描述收到的样本，不表示连续相机覆盖或健康观察时长。封存当前桶也不会推断未输入时段的流量。

`checkpoint()`、`from_checkpoint()` 和 `fork()` 隔离可变数组；恢复检查桶边界、采样时序、原始累计基线、阈值分区和跨阈值单调关系，保留已收到的聚合结果，不保存历史关闭窗。独立统计检查点不含上游运动、地标或待入口，宿主须保存共同水位；恢复后按原时钟继续，不移动或过滤旧帧。

## 命令行与浏览器

```sh
moon update
moon build cmd/main --target native --release --deny-warn
./_build/native/release/build/cmd/main/main.exe --stream < examples/warehouse.ndjson
```

Windows PowerShell 的等价回放命令为：

```powershell
Get-Content -Raw -Encoding UTF8 examples/warehouse.ndjson |
  & .\_build\native\release\build\cmd\main\main.exe --stream
```

`--stream` 接收 UTF-8 NDJSON：第一行为配置或 `{"resume":<检查点>}`，后续每行为一个完整帧。恢复后的帧时间必须大于检查点中的最后处理帧时间。

```jsonl
{"session_id":"warehouse","mode":"ground","motion":{"q":1}}
{"timestamp_us":"0","observations":[{"track_id":7,"point":[1,2],"covariance":[0.01,0,0.01]}]}
{"timestamp_us":"200000","observations":[{"track_id":7,"point":[1.1,2],"covariance":[0.01,0,0.01]}]}
{"timestamp_us":"400000","observations":[{"track_id":7,"point":[1.2,2],"covariance":[0.01,0,0.01]}]}
```

`mode:"pixel"` 还需要 `calibration.matrix` 和凸多边形 `calibration.roi`，格式见 [`examples/warehouse.ndjson`](examples/warehouse.ndjson)。`lost`、`removed` 为可选身份数组；配置中设置 `diagnostics:true` 可输出完整状态与 4×4 行优先协方差，供数值核对。

结构错误、重复或冲突身份、时间错误和容量错误会拒绝整帧，保留之前的状态。ROI 外或投影不可用的目标返回 `rejected_projection`，同帧其他目标继续测量。创新门限拒绝及数值失败也按目标报告，不把旧位置当作当前测量。

CLI 默认限制每物理行 1 MiB，可通过 `--max-line-bytes N` 调整，最大为 16 MiB。该选项也用于包含大型检查点的首行，JSON 层的配置、帧和检查点上限分别保持原值。非法 UTF-8、坏 JSON 或协议错误写入 stderr 并以状态 2 退出；`--stream` 之前完成的结果行保留，失败帧不输出半行。CRLF 和最后一行没有换行符均可读取。

重复键和未知字段会被拒绝。目标身份必须是正的 32 位整数；整数参数按原始十进制 token 验证，`4.0`、`4e0`、`40e-1` 均表示整数 4，`4.0000000000000000001` 会被拒绝。

`--checkpoint` 使用同样的输入协议，成功读到 EOF 后只输出一行检查点；中途任一输入失败时以状态 2 退出且 stdout 为空。它适合为已持久化的观测前缀制作恢复点。下面的命令先保存完整示例的最终状态，再构造续接首行；实际续接时在首行后追加时间更晚的观测帧：

```sh
./_build/native/release/build/cmd/main/main.exe --checkpoint < examples/warehouse.ndjson > checkpoint.json
python -c 'import json; print(json.dumps({"resume":json.load(open("checkpoint.json",encoding="utf-8"))}))' > resume.ndjson
./_build/native/release/build/cmd/main/main.exe --stream --max-line-bytes 16777216 < resume.ndjson
```

带后续帧的完整示例见 [`examples/resume.ndjson`](examples/resume.ndjson)：它保存镜头校正示例前三帧的状态，再续接其余十二帧。CLI 负责完整计算和输出检查点；临时文件、原子替换、输出消费进度和观测日志由宿主应用协调，避免崩溃后重复处理已经交付的结果。

`--reframe` 把已有像素流转换成可直接交给 `--stream` 或 `--checkpoint` 的新 NDJSON。第一行为 `{"source":<原配置或resume包装>,"transform":{"scale_x":0.5,"scale_y":0.75,"offset_x":-40,"offset_y":16}}`，后续每行仍是原坐标的观测帧。它先输出目标配置或恢复头，再按帧换算点和协方差；没有指定协方差的像素观测先按原坐标的 2 像素标准差生成协方差，再显式写出变换结果，避免错误地在新坐标中继续使用默认 2 像素噪声。时间、身份、`lost` 和 `removed` 保持；ground 模式会被拒绝。

下面把镜头校正示例换算到上述坐标。Python 仅包装首行，观测行保持原文本交给转换器：

```sh
python -c 'import json; p=open("examples/distorted-camera.ndjson",encoding="utf-8").read().splitlines(); print(json.dumps({"source":json.loads(p[0]),"transform":{"scale_x":0.5,"scale_y":0.75,"offset_x":-40,"offset_y":16}})); print(*p[1:],sep="\n")' |
  ./_build/native/release/build/cmd/main/main.exe --reframe > reframed.ndjson
./_build/native/release/build/cmd/main/main.exe --stream < reframed.ndjson
```

对应的完整输出见 [`examples/reframe.ndjson`](examples/reframe.ndjson)。若 `source` 是 `{"resume":...}`，转换后的恢复头仅换算相机与标定，内嵌米制 `motion` 原样保留；后续帧仍须严格晚于保存的帧时间。直接使用库时，`codec.ReplayReframer::new` 接收同样的流头，`header_line()` 和 `process_line(...)` 分别生成初始输出头与下一帧；处理后续帧不会更新缓存的初始头。转换器只保留当前验证状态，支持长流；某帧转换或验证失败时该帧不提交，可以修正后用同一时间重试。CLI 出错以状态 2 退出，已完整输出的头与前缀保留。

纯函数 `codec.reframe_json(...)` 与 JavaScript `moonground_reframe(...)` 接收 `{"ndjson":<原始NDJSON字符串>,"transform":{...}}`，成功返回 `{"ndjson":<新NDJSON字符串>,"frame_count":...}`。输入保留为原始字符串，使重复键与十进制 token 继续由严格解析器检查；批量转换不分配浏览器会话句柄，失败不返回部分结果。批量原始 NDJSON 和转换后 NDJSON 各限 8,388,608 个 UTF-16 代码单元，最多 5,000 帧；外层 JSON 请求最多 16,777,216 个代码单元、32 层嵌套。嵌入的 `source` 配置与检查点按规范化 JSON 分别校验 1,048,576 与 8,388,608 个代码单元上限；原始帧每行仍限 1,048,576 个代码单元，CLI 物理行字节限制仍需按输入大小显式调整。

`--analyze` 直接测量原始观测并统计通道。首行为 `{"measurement":<原始测量配置或resume的JSON字符串>,"counting":<原始通道配置或resume的JSON字符串>}`，或 `{"resume":<完整联合检查点对象>}`；后续每行使用与 `--stream` 相同的原始 pixel／ground 观测。首次组合和恢复均检查两侧 session 与水位，不接受已预热测量配上未开始的计数器。

下面把现有仓储输入与通道配置组合；Python 只包装两段原始配置文字，观测行保持原文：

```sh
python -c 'import json; from pathlib import Path; p=Path("examples/warehouse.ndjson").read_text(encoding="utf-8").splitlines(); print(json.dumps({"measurement":p[0],"counting":Path("examples/gates.json").read_text(encoding="utf-8")})); print(*p[1:],sep="\n")' > analysis-input.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze < analysis-input.ndjson > analysis.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-checkpoint < analysis-input.ndjson > analysis-checkpoint.json
python -c 'import json; print(json.dumps({"resume":json.load(open("analysis-checkpoint.json",encoding="utf-8"))}))' > analysis-resume.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze --max-line-bytes 16777216 < analysis-resume.ndjson
```

`--analyze` 为每帧输出 `schema_version:"0.1.0"`、`kind:"analysis_frame"`，内嵌 `measurement` 沿用测量 `0.2.0`，`counting` 沿用事件 `0.1.0`。`--analyze-checkpoint` 成功读取 EOF 后只输出一份 `format:"moonground.analysis"`、`checkpoint_version:"1"` 的完整检查点，其 `measurement` 和 `counting` 分别内嵌原有完整检查点。后续观测时间须晚于共同水位。出错退出码为 2；流式分析保留已完整输出的前缀，检查点模式失败时 stdout 为空。

`codec.AnalysisReplay::open(source)` 接受同样的原始首行，`process_line` 处理下一原始观测，`checkpoint_json()` 导出完整联合检查点。原始联合首行最多 8,388,619 个 UTF-16 代码单元，联合检查点本体最多 8,388,608；内嵌的普通配置各保留 1,048,576 上限，原有恢复包装各保留 8,388,619 上限。原始观测每行限 1,048,576，JSON 嵌套限 32。CLI 物理行的默认 1 MiB 和最大 16 MiB 字节限制仍生效；联合输出行的规模由目标、通道和参考点预算约束，不额外套用输入行的 1 Mi 上限。

纯函数 `codec.analysis_json(...)` 与 JavaScript `moonground_analysis(...)` 接收 `{"source":<原始联合首行JSON字符串>,"observations":<原始观测NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。它们不分配浏览器会话句柄，批量失败不返回部分帧。原始观测总文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216 个代码单元、32 层嵌套；包含最终检查点的整个返回 JSON 限 8,388,608 个代码单元。source 和观测均保留原始文字，由 MoonBit 检查重复键、未知字段与精确整数 token。

`--count` 接收另一条 NDJSON 流：首行为通道配置或 `{"resume":<通道检查点>}`，后续每行直接使用 `--stream` 已输出的测量 JSON `0.2.0`，而不是像素观测。通道配置见 [`examples/gates.json`](examples/gates.json)，与仓储示例使用相同 `session_id`。例如，先测量，再把配置文本压成首行并连接原始测量行：

```sh
./_build/native/release/build/cmd/main/main.exe --stream < examples/warehouse.ndjson > measurements.ndjson
python -c 'from pathlib import Path; print("".join(Path("examples/gates.json").read_text(encoding="utf-8").splitlines())); print(Path("measurements.ndjson").read_text(encoding="utf-8"),end="")' > count-input.ndjson
./_build/native/release/build/cmd/main/main.exe --count < count-input.ndjson > gate-events.ndjson
./_build/native/release/build/cmd/main/main.exe --count-checkpoint < count-input.ndjson > gates-checkpoint.json
```

`--count` 每个输入帧输出一行 `schema_version:"0.1.0"`、`kind:"gate_events"` 的事件和累计计数；`event_scope:"filtered_ground_positions"` 明确位置来源。方向字符串为 `negative_to_positive` 或 `positive_to_negative`，累计次数、时间及片段号为十进制字符串。测量状态、位置、时间和生命周期字段经过严格解析，不把拒绝帧保留的旧位置当作当前接受位置。

`--count-checkpoint` 成功读取 EOF 后仅输出一份 `format:"moonground.gates"`、`checkpoint_version:"1"` 的通道检查点，其中 `configuration` 与 `state` 包含继续统计所需状态。恢复只接受内嵌配置，不能同时覆盖参数。两种命令的错误退出码均为 2；`--count` 保留已完整输出的前缀，`--count-checkpoint` 失败时 stdout 为空。通道配置原始文本限 1,048,576 个 UTF-16 代码单元，检查点限 8,388,608，恢复包装最多额外 11 个；原始测量每行限 1,048,576，嵌套深度限 32。默认物理行 1 MiB 和 `--max-line-bytes` 仍生效，较大恢复头需显式放宽；事件行携带旧参考点，可能比对应输入行更大，其状态规模受通道与参考点预算约束。

库接口 `codec.GateReplay::open(source)` 接受原始配置或恢复包装字符串；`process_line(measurement)` 返回下一事件行，`checkpoint_json()` 导出独立通道检查点。纯函数 `codec.gates_json(...)` 和 JavaScript `moonground_gates(...)` 接收 `{"source":<原始配置或恢复JSON字符串>,"measurements":<原始测量NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`，不分配会话句柄；出错时不返回部分结果。两层输入都保留原文，使重复键、未知字段和原始整数 token 继续由 MoonBit 验证。批量测量文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216 个代码单元、32 层嵌套；**整个返回 JSON** 限 8,388,608 个代码单元，包含帧及最终检查点。

`--transit` 同样读取已经输出的测量 JSON `0.2.0`。首行为 `{"counting":<原始通道配置或resume JSON字符串>,"sections":[{"section_id":"aisle","entry_gate_id":"entry","entry_direction":"positive_to_negative","exit_gate_id":"exit","exit_direction":"positive_to_negative"}],"max_duration_us":"300000000"}`，或 `{"resume":<完整区间检查点对象>}`。配置示例见 [`examples/transit.json`](examples/transit.json)，其通道与仓储示例的米制坐标对应：

```sh
./_build/native/release/build/cmd/main/main.exe --stream < examples/warehouse.ndjson > measurements.ndjson
python -c 'from pathlib import Path; print("".join(Path("examples/transit.json").read_text(encoding="utf-8").splitlines())); print(Path("measurements.ndjson").read_text(encoding="utf-8"),end="")' > transit-input.ndjson
./_build/native/release/build/cmd/main/main.exe --transit < transit-input.ndjson > transit-results.ndjson
./_build/native/release/build/cmd/main/main.exe --transit-checkpoint < transit-input.ndjson > transit-checkpoint.json
python -c 'import json; print(json.dumps({"resume":json.load(open("transit-checkpoint.json",encoding="utf-8"))}))' > transit-resume.ndjson
./_build/native/release/build/cmd/main/main.exe --transit --max-line-bytes 16777216 < transit-resume.ndjson
```

续接首行后追加更晚的测量帧，保留全部空帧与拒绝帧。每帧输出 `schema_version:"0.1.0"`、`kind:"transit_events"`，内嵌 `counting` 及区间结果；时间界、累计和段号使用十进制字符串，插值时长为数值。`--transit-checkpoint` 成功读取 EOF 后只输出 `format:"moonground.transit"`、`checkpoint_version:"1"` 的下游检查点。整帧错误退出码为 2；流式模式保留完整前缀，检查点模式失败时 stdout 为空。

`codec.TransitReplay::open(source)`、`process_line(measurement)` 和 `checkpoint_json()` 使用同一协议。普通区间首行限 1,048,576 个 UTF-16 代码单元，完整检查点限 8,388,608，恢复包装限 8,388,619；原始测量每行限 1,048,576，JSON 嵌套限 32。内嵌 `counting` 保留原始文本并沿用通道配置／恢复校验，普通区间首行的总上限仍须满足。CLI 的物理行字节上限继续生效；原生输出不额外套用输入行的 1 Mi 上限。

纯函数 `codec.transit_json(...)` 与 JavaScript `moonground_transit(...)` 接收 `{"source":<原始区间首行JSON字符串>,"measurements":<原始测量NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`，不分配会话句柄。原始测量总文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216，整个返回 JSON 含最终检查点限 8,388,608。失败不返回部分区间结果；配置与测量原文由 MoonBit 检查重复键和精确整数 token。

`--health` 接受独立固定地标 NDJSON。首行为包含 `monitor_id`、`calibration`、`landmarks:[{"landmark_id":"A","ground_m":[x,y]},...]` 和可选 `camera`、`health` 门限的配置，或 `{"resume":<地标检查点>}`。后续观测行为 `{"timestamp_us":"...","observations":[{"landmark_id":"A","point":[x,y],"covariance":[xx,xy,yy]},...]}`；省略协方差时使用原像素坐标中的 2 像素标准差。完整 Brown 合成输入见 [`examples/health.ndjson`](examples/health.ndjson)：包含原标定下的正常地标、0.3 米偏移、缺失和长间隔。

```sh
./_build/native/release/build/cmd/main/main.exe --health < examples/health.ndjson > health-results.ndjson
./_build/native/release/build/cmd/main/main.exe --health-checkpoint < examples/health.ndjson > health-checkpoint.json
python -c 'import json; print(json.dumps({"resume":json.load(open("health-checkpoint.json",encoding="utf-8"))}))' > health-resume.ndjson
./_build/native/release/build/cmd/main/main.exe --health --max-line-bytes 16777216 < health-resume.ndjson
```

续接时在恢复首行后追加时间更晚的固定地标观测。`--health` 每帧输出 `schema_version:"0.1.0"`、`kind:"calibration_health"`，`scope:"observed_fixed_landmarks_under_fixed_calibration"` 明确检查条件。输出保留精确时间、当前证据、确认状态和全部配置地标的诊断。`--health-checkpoint` 成功读取 EOF 后仅输出一份 `format:"moonground.health"`、`checkpoint_version:"1"` 的完整检查点；有效配置和状态分别放在 `configuration`、`state`。恢复要求内嵌有效配置完整，不能混入覆盖参数。格式、身份、协方差和时间错误以状态 2 退出；流式模式保留完整前缀，检查点模式失败时 stdout 为空。逐点拒绝仍提交该帧及新的证据状态。

`codec.HealthReplay::open(source)` 接受原始配置或恢复包装，`process_line` 输入下一原始地标帧，`checkpoint_json()` 保存完整状态。普通配置与每帧原文各限 1,048,576 个 UTF-16 代码单元，检查点限 8,388,608，恢复首行限 8,388,619，嵌套深度限 32。CLI 仍使用默认 1 MiB、可配置到 16 MiB 的物理行字节上限。重复键、未知字段和非整数的原始参数 token 按既有严格规则拒绝。

纯函数 `codec.health_json(...)` 与 JavaScript `moonground_health(...)` 接收 `{"source":<原始地标配置或resume JSON字符串>,"observations":<原始地标观测NDJSON字符串>}`，成功返回 `{"frames":[...],"checkpoint":...}`。嵌入原文交给 MoonBit 解析，保留精确整数和重复键检查，不分配浏览器会话句柄。原始观测总文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216 个代码单元、32 层嵌套；整个返回 JSON 连同最终检查点限 8,388,608 个代码单元，批量失败不返回部分结果。

`--guarded` 显式按当前地标健康状态控制像素分析。首行为 `{"analysis":<原始分析首行JSON字符串>,"health":<原始地标首行JSON字符串>}`，或 `{"resume":<完整门控检查点对象>}`。后续每行是 `{"measurement":<原始像素观测帧JSON字符串>,"health":<原始地标观测帧JSON字符串>}`，两段观测须具有完全相同的微秒时间。分析首行中的测量和计数配置也保留各自的原始 JSON 字符串；两层包装都不预先解析再序列化整数或重复键。完整输入见 [`examples/guarded.ndjson`](examples/guarded.ndjson)。

```sh
./_build/native/release/build/cmd/main/main.exe --guarded < examples/guarded.ndjson > guarded-results.ndjson
./_build/native/release/build/cmd/main/main.exe --guarded-checkpoint < examples/guarded.ndjson > guarded-checkpoint.json
python -c 'import json; print(json.dumps({"resume":json.load(open("guarded-checkpoint.json",encoding="utf-8"))}))' > guarded-resume.ndjson
./_build/native/release/build/cmd/main/main.exe --guarded --max-line-bytes 16777216 < guarded-resume.ndjson
```

续接时追加晚于共同水位的成对观测。每帧输出 `schema_version:"0.1.0"`、`kind:"guarded_analysis_frame"`、`decision:"allowed"|"blocked"` 和 `suppressed_track_ids`，内嵌原有 `health` 与 `analysis` 结果。`--guarded-checkpoint` 成功读取 EOF 后仅输出 `format:"moonground.guarded"`、`checkpoint_version:"1"`，内嵌完整 `analysis`、`health` 检查点。整帧错误以状态 2 退出；流式模式保留完整前缀，检查点模式失败时 stdout 为空。

`codec.GuardedReplay::open(source)`、`process_line(...)` 和 `checkpoint_json()` 使用同一协议。原始首行限 8,388,619 个 UTF-16 代码单元，完整检查点限 8,388,608；内嵌入口沿用各自的配置与恢复上限。每个成对观测的**外层原文**限 1,048,576 个代码单元，内嵌两帧也分别受原有 1,048,576 上限约束；转义后的包装可能先达到外层限制。JSON 嵌套限 32，CLI 的物理行字节限制继续生效。

纯函数 `codec.guarded_json(...)` 与 JavaScript `moonground_guarded(...)` 接收 `{"source":<原始门控首行JSON字符串>,"observations":<原始门控后续行NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。不分配会话句柄；后续行总文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216，整个返回 JSON 连同最终检查点限 8,388,608。批量失败不返回部分结果。

门控流可插入 `{"replace_projection":<原始切换请求JSON字符串>}`，内层只接受 `timestamp_us`、`calibration`、必填 `camera`；`camera:null` 显式撤除校正，对象则安装完整模型。这一行不同时携带对象、地标或其他配置覆盖。原始控制行及其内层请求各限 1,048,576 个 UTF-16 代码单元，沿用严格重复键、未知字段与整数 token 检查；控制行也计入批量 5,000 帧和总文本预算。

完整 Brown 切换输入见 [`examples/projection-replace.ndjson`](examples/projection-replace.ndjson)，继续使用原有命令与 JavaScript 入口：

```sh
./_build/native/release/build/cmd/main/main.exe --guarded < examples/projection-replace.ndjson > projection-replace-results.ndjson
./_build/native/release/build/cmd/main/main.exe --guarded-checkpoint < examples/projection-replace.ndjson > projection-replace-checkpoint.json
```

成功控制行输出 `kind:"guarded_projection_replaced"`，仍为 `schema_version:"0.1.0"`，内嵌阻断空帧、健康重置及原计数；后续普通帧继续使用 `guarded_analysis_frame`。完整检查点仍是 `moonground.guarded` 版本 1，两侧有效配置均改为最新标定及相机。解析或切换失败保留旧状态和配置；流式完整前缀、检查点失败无 stdout、批量失败无部分结果等规则保持。恢复后的首个观测或切换时间须晚于保存水位。

`--project` 单独接收一行 `{ "calibration": ..., "points": [{ "point": [x,y], "covariance": [xx,xy,yy] }] }`，返回位置、协方差和 Jacobian。`--calibrate` 接收六对以上拟合点、两对以上独立检查点和 ROI，返回可用于配置的标定及残差报告；单行示例见 [`examples/calibration.json`](examples/calibration.json)。控制点拟合也可以直接调用 `GroundCalibration::fit`。

```sh
./_build/native/release/build/cmd/main/main.exe --calibrate < examples/calibration.json
```

```sh
node web/build.mjs
node web/serve.mjs
```

浏览器页面可导入本地 NDJSON、逐帧查看测量、从控制点拟合标定、检查有效域并下载结果；计算沿用同一 MoonBit JSON 协议。页面显示位置、速度标准差和 `uncertain` 状态。原始像素 session 更换标定时，拟合请求也必须包含 `camera`，避免无意切换像素空间。页面输入改变后会清除旧结果。

标定面板的“稳健标定示例”载入含误标点的原始像素请求；点击拟合后显示保留数量、被排除的控制点编号和逐点米制残差。页面编号从 1 开始，并支持下载完整标定结果。更改控制点输入或拟合失败时，旧诊断与下载立即失效；失败不改变观测输入，迟到的示例也不会覆盖已编辑内容。

“保存当前帧检查点”会重放到选定帧并下载完整状态，避免把未来帧状态误存为当前帧。导入检查点后，在输入区追加后续观测即可继续；格式或状态验证失败时保留原输入与结果。普通测量恢复流绑定原标定，修改标定需新建会话；下方门控流另有显式切换入口。“续接示例”可直接检查恢复流程；页面只展示恢复后本次处理的历史帧。

“变换观测坐标”使用水平／垂直倍率和偏移，一次换算输入中的配置、恢复头与全部后续观测，成功后清除旧显示并提示重新计算；错误时保留原输入、测量结果及下载。修改四个参数本身保留现有测量，迟到的示例不会覆盖新参数或输入草稿。“缩放裁剪示例”可直接回放已变换数据。浏览器额外按 UTF-8 字节限制输入与输出各为 8 MiB；更大的流使用 CLI。

坐标变换后，标定面板保留原控制点和核验点为草稿，清除旧诊断并锁定拟合；先按新坐标编辑这些点才能再次拟合，避免旧坐标覆盖已变换的标定。实际重新拟合仍创建新的测量起点；已恢复流继续绑定原物理标定，只能通过统一坐标换算接入新像素空间。

“测量并统计”从当前原始观测和通道配置一次计算两侧状态，画布和逐帧视图同时展示测量与过线。“下载完整分析结果”保存全部联合帧和末帧完整检查点；“保存当前帧完整检查点”重放到滑块所选帧，保存该帧两侧共同的状态。“载入完整检查点”先让 MoonBit 校验完整输入及两侧关系，成功后才把两段已验证的恢复输入写入观测区和通道区。追加晚于共同水位的原始观测后，点击“测量并统计”即可继续，计数无需手工配对水位。

联合计算或导入失败保留原显示与下载；观测或通道配置编辑后旧联合下载失效，迟到操作不会覆盖新输入。浏览器额外限制联合首行与观测合计 8 MiB UTF-8、返回 JSON 为 8 MiB；更大的流使用 CLI。导入后的像素换算继续使用同一米制通道与参考点。

原有“统计过线”仍可单独读取当前测量结果，配置区接受普通通道配置或恢复包装。统计后在画布叠加 A→B 通道与所选帧交点，并显示该帧的双向累计次数、事件位置、精确微秒区间及弦比例；独立过线下载包含全部事件帧和**整批最终帧**的通道检查点。“保存当前帧检查点”则只保存滑块所选的测量帧。使用这两个独立下载配对恢复时，先把滑块移到末帧再保存测量检查点，并核对测量检查点 `motion.last_timestamp_us` 与通道检查点 `state.last_timestamp_us` 一致；中途测量检查点不能与整批最终通道检查点配对。

修改通道配置清除旧统计及下载，但保留测量；观测、标定、恢复起点或像素变换成功替换输入后，旧统计也失效。统计失败保留已有测量，迟到的默认通道示例不会覆盖配置草稿。页面将原始通道文本与核心返回的原始测量行直接交给 MoonBit，额外限制过线输入与输出各为 8 MiB UTF-8；较长流使用原生命令。

“固定地标检查”使用独立输入区和回放滑块。“地标示例”载入 13 帧 Brown 合成数据，状态时间线区分等待证据、符合阈值、持续超限和地标不足；表格列出投影、残差、标准差和拒绝原因。“下载检查结果”包含全批帧和最终检查点，“保存末帧地标检查点”始终保存整批末帧，不随回放滑块改成中间帧。“载入地标检查点”先验证完整原文，再写入恢复首行；追加更晚观测后继续检查。它与上方对象轨迹、计数、标定及像素变换面板分别操作，修改一侧不会替另一侧更换物理配置。

地标输入编辑后旧检查结果与下载失效；文件、示例或恢复失败时保留原输入与显示，迟到操作不会覆盖新编辑。浏览器额外限制地标配置与观测合计 8 MiB UTF-8，返回 JSON 为 8 MiB。大规模或长时间检查使用 CLI。

“按地标健康状态分析”使用独立的门控 NDJSON 输入。“门控示例”包含 16 帧，其中 6 帧放行、10 帧阻断，并产生 3 次过线；状态条同时显示地标状态与放行决定，逐帧结果列出被抑制身份、关闭片段及保留的累计计数。“下载门控分析结果”保存全批结果和最终检查点，“保存末帧完整门控检查点”始终保存整批末帧。“载入完整门控检查点”先由核心验证，再写入一行完整恢复包装，不拆分两侧状态；追加更晚的成对观测即可继续。

该面板与原有独立分析、地标检查分别操作。输入编辑使自身旧结果和下载失效；导入或计算失败保留已有输入与显示，迟到操作不会覆盖新编辑。浏览器额外限制门控首行与观测合计 8 MiB UTF-8、返回 JSON 为 8 MiB。

“标定切换示例”在同一门控流中展示原标定的持续偏移、显式切换、重新确认和新段过线。时间线上用紫线标记控制帧，当前帧显示“切换标定”、证据不足和保留累计；结果及末帧检查点沿用原下载／恢复按钮。需切换时在输入中显式提供控制行，不从地标超限自动推算或替换标定。下游区间统计读取相同完整帧序列，包含切换空帧。

“两通道之间的区间通行时间”使用独立通道与区间配置。生成上游结果后，显式选择“使用普通测量结果”或“使用健康门控结果”；后者保留阻断空帧，正常取消待入口。视图跟随所选来源的回放滑块，显示入口／出口括号、时长界、插值估计、取消原因和累计完成数；结果下载包含全批帧和最终检查点，“保存末帧区间检查点”始终保存整批末帧。

“载入区间检查点”先由核心验证，再写入恢复首行；它不恢复上游，须先将上游恢复至同一水位，再选择更晚的测量结果。配置编辑或所选来源更新使旧区间结果失效，另一来源的编辑不替换当前显示；失败保留原结果，迟到操作不会覆盖新编辑。浏览器额外限制区间配置与测量合计 8 MiB UTF-8、返回 JSON 为 8 MiB。

浏览器桥最多保留 64 个活跃 session，调用方用 `moonground_close` 释放。`moonground_checkpoint(handle)` 返回原始检查点 JSON；`moonground_restore(source)` 验证成功后分配新句柄，失败时不改变原句柄。`moonground_create(source)` 支持普通配置或原始 resume 包装文本。桥方法失败时返回 `{"error":...}`，恢复不会原位替换其他会话。

### 法向证据计数协议

`--count-evidence` 读取同一测量 JSON `0.2.0` 流。首行为 `{"counting":<原始新建通道配置的JSON字符串>,"sigma_multiplier":2}`，或 `{"resume":<完整证据检查点对象>}`；`counting` 只接受新建配置，不能内嵌旧通道恢复输入。合成配置见 [`examples/gate-evidence.json`](examples/gate-evidence.json)。沿用前面的 `measurements.ndjson`：

```sh
python -c "import pathlib,sys; sys.stdout.write(pathlib.Path('examples/gate-evidence.json').read_text().replace('\n','')+'\n'+pathlib.Path('measurements.ndjson').read_text())" > evidence-input.ndjson
./_build/native/release/build/cmd/main/main.exe --count-evidence < evidence-input.ndjson > evidence-results.ndjson
./_build/native/release/build/cmd/main/main.exe --evidence-checkpoint < evidence-input.ndjson > evidence-checkpoint.json
python -c "import pathlib,sys; sys.stdout.write('{\"resume\":'+pathlib.Path('evidence-checkpoint.json').read_text().strip()+'}\n')" > evidence-resume.ndjson
```

续接首行后添加晚于共同水位的测量行，并保留所有空帧。帧使用 `schema_version:"0.1.0"`、`kind:"gate_evidence_frame"`，内嵌原 `counting`，另给出 `evidence_scope:"normal_band_on_filtered_mean_chord"`、倍率与逐点证据；JSON 侧别为 `positive`、`negative` 或 `unconfirmed`。`--evidence-checkpoint` 在成功 EOF 后仅输出 `format:"moonground.gate-evidence"`、`checkpoint_version:"1"` 的完整独立检查点，包含原规范通道配置、倍率及带原协方差的参考点。错误退出码为 2；流式入口保留完整前缀，检查点入口失败时 stdout 为空。

`codec.EvidenceGateReplay::open(source)`、`process_line(measurement)` 和 `checkpoint_json()` 使用同一原始文本协议。普通首行限 1,048,576 个 UTF-16 代码单元，检查点本体限 8,388,608、恢复包装限 8,388,619；每条原测量行限 1,048,576，嵌套限 32。CLI 物理行默认 1 MiB，可用 `--max-line-bytes` 放宽到 16 MiB；原生输出不另套用输入行的 1 Mi 上限。

纯函数 `codec.gate_evidence_json(...)` 与 JavaScript `moonground_gate_evidence(...)` 接受 `{"source":<原始首行JSON字符串>,"measurements":<原始测量NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`，不分配会话句柄，失败不返回部分结果。两层文本保留原 token 检查；测量文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216，整个返回 JSON（含检查点）限 8,388,608。

浏览器的“法向协方差证据”折叠面板有独立配置，可显式选择普通测量或健康门控测量结果，查看法向标准差、距离带、侧别及累计。结果下载和证据检查点均对应全批末帧；恢复须先把上游恢复至同一水位，再送入更晚的完整测量流。上方均值过线、联合分析和区间统计继续使用各自原策略。

### 原始观测的联合证据协议

`--analyze-evidence` 直接读取原始 pixel／ground 观测，首行为 `{"measurement":<原始测量配置或resume JSON字符串>,"counting":<原始证据配置或resume JSON字符串>}`，或 `{"resume":<完整联合证据检查点对象>}`。`counting` 是上一节 `EvidenceGateReplay` 的完整输入文字，不是旧均值通道配置或旧检查点。两段现有恢复输入也须处于共同会话与水位；未开始的计数器不能与已预热测量直接拼接。下面组合原仓储输入与证据配置：

```sh
python -c 'import json; from pathlib import Path; lines=Path("examples/warehouse.ndjson").read_text(encoding="utf-8").splitlines(); print(json.dumps({"measurement":lines[0],"counting":Path("examples/gate-evidence.json").read_text(encoding="utf-8")})); print("\n".join(lines[1:]))' > evidence-analysis-input.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-evidence < evidence-analysis-input.ndjson > evidence-analysis-results.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-evidence-checkpoint < evidence-analysis-input.ndjson > evidence-analysis-checkpoint.json
python -c 'from pathlib import Path; print("{\"resume\":"+Path("evidence-analysis-checkpoint.json").read_text(encoding="utf-8").strip()+"}")' > evidence-analysis-resume.ndjson
```

续接首行后添加更晚的原始观测即可，完整检查点不需拆开恢复。联合帧使用 `schema_version:"0.1.0"`、`kind:"evidence_analysis_frame"`，内嵌原测量 `0.2.0` 和原 `gate_evidence_frame`；检查点使用 `format:"moonground.evidence-analysis"`、`checkpoint_version:"1"`，完整嵌入原测量与证据检查点。CLI 错误退出码为 2，流式模式保留已完整输出的前缀，检查点模式失败时 stdout 为空。

`codec.EvidenceAnalysisReplay::open(source)`、`process_line(observation)` 与 `checkpoint_json()` 使用同一协议。source 原文限 8,388,619 个 UTF-16 代码单元，完整检查点**合计**限 8,388,608；内嵌普通测量／证据配置保留各自 1,048,576 上限，恢复包装保留各自 8,388,619 上限，嵌套限 32。每行原观测限 1,048,576。CLI 默认物理行 1 MiB，较大的恢复头可用 `--max-line-bytes` 放宽至 16 MiB；原生输出不另套用输入行的 1 Mi 上限。

纯函数 `codec.evidence_analysis_json(...)` 与 JavaScript `moonground_evidence_analysis(...)` 接受 `{"source":<原始联合首行JSON字符串>,"observations":<原始观测NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。原始文本保留重复键、未知字段和精确整数 token 检查；不分配会话句柄，批量失败不返回部分帧。观测合计限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层包装限 16,777,216，整个返回 JSON（含完整检查点）限 8,388,608。

浏览器同一证据面板的“测量并按法向证据统计”直接使用上方原始观测与本区证据配置，拥有独立回放滑块；“下载完整联合证据结果”保存全批帧与最终完整检查点，“保存当前帧联合证据检查点”重放到所选帧并保存共同状态。“载入完整联合证据检查点”验证完整输入后设置共同恢复起点，追加更晚原始观测后继续联合计算。原有两个来源按钮仍单独统计已计算的普通／门控测量，它们使用独立下游检查点，不会自动加入新事务。

### 法向证据的健康门控协议

`--guarded-evidence` 首行为 `{"analysis":<原始联合证据配置或resume JSON字符串>,"health":<原始地标配置或resume JSON字符串>}`，或 `{"resume":<完整证据门控检查点对象>}`。`analysis` 使用 v0.13 的 `EvidenceAnalysisReplay` 格式；该入口不会把旧均值门控头自动转换成证据来源。完整 Brown 合成输入见 [`examples/evidence-guarded.ndjson`](examples/evidence-guarded.ndjson)。

后续普通帧为 `{"measurement":<原始像素观测JSON字符串>,"health":<原始地标观测JSON字符串>}`，两段时间必须完全相同；显式替换沿用 `{"replace_projection":<原始控制JSON字符串>}`，其中包含时间、完整新标定及必填 `camera`（模型对象或 `null`）。这些原始文字逐层交给核心校验，不在宿主先转换整数 token。

```sh
./_build/native/release/build/cmd/main/main.exe --guarded-evidence < examples/evidence-guarded.ndjson > evidence-guarded-results.ndjson
./_build/native/release/build/cmd/main/main.exe --guarded-evidence-checkpoint < examples/evidence-guarded.ndjson > evidence-guarded-checkpoint.json
python -c 'from pathlib import Path; print("{\"resume\":"+Path("evidence-guarded-checkpoint.json").read_text(encoding="utf-8").strip()+"}")' > evidence-guarded-resume.ndjson
```

恢复首行后追加更晚的成对观测或控制行。普通帧使用 `schema_version:"0.1.0"`、`kind:"evidence_guarded_frame"`，替换帧使用 `kind:"evidence_guarded_projection_replaced"`，内嵌原健康报告与联合证据分析。完整检查点使用 `format:"moonground.evidence-guarded"`、`checkpoint_version:"1"`，保存完整分析和健康状态，无需手工配对三方水位。错误退出码为 2；流式入口保留已完整输出的前缀，检查点入口失败时 stdout 为空。

`codec.EvidenceGuardedReplay::open(source)`、`process_line(frame)` 与 `checkpoint_json()` 使用同一协议。source 原文限 8,388,619 个 UTF-16 代码单元，完整检查点合计限 8,388,608；每条成对帧或控制行的**外层原文合计**限 1,048,576，内嵌来源还保留各自原限制，嵌套限 32。CLI 默认物理行 1 MiB，大恢复头可显式放宽至 16 MiB；原生输出不另套用输入行的 1 Mi 上限。

纯函数 `codec.evidence_guarded_json(...)` 与 JavaScript `moonground_evidence_guarded(...)` 接受 `{"source":<原始新首行JSON字符串>,"observations":<原始成对帧及控制NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。观测文本限 8,388,608 个 UTF-16 代码单元、5,000 行，外层请求限 16,777,216，整个返回 JSON（含完整检查点）限 8,388,608；不分配会话句柄，失败不返回部分结果。完整检查点验证状态自洽，不认证地标历史；外部日志、存储和输出交付仍由宿主协调。

浏览器“健康门控与法向证据联合分析”使用上方**同一个门控原文输入框**，通过本区入口运行新协议；不适配旧均值门控头，也不读取独立证据配置框。新示例提供完整来源、成对观测及投影切换流。它有独立结果和回放滑块：完整结果下载包含全批帧及末帧完整检查点，所选帧检查点通过原始前缀重放取得。导入完整检查点先交核心校验，再把一行完整恢复包装写回共享输入，后续仍从本区入口续接。

### 法向证据通行协议

`--transit-evidence` 首行为 `{"counting":<原始证据来源JSON字符串>,"sections":[...],"max_duration_us":<可省略的十进制字符串>}`，`counting` 使用 `--count-evidence` 的完整 fresh 或 resume 协议。外层也可直接使用 `{"resume":<完整证据区间检查点对象>}`，此时不允许覆盖字段。后续为原 schema-0.2 测量 JSON，空帧、逐目标拒绝和关闭信息均完整保留。

```sh
./_build/native/release/build/cmd/main/main.exe --stream < examples/warehouse.ndjson > measurements.ndjson
python -c 'from pathlib import Path; print(Path("examples/evidence-transit-source.json").read_text(encoding="utf-8").strip()); print(Path("measurements.ndjson").read_text(encoding="utf-8"), end="")' > evidence-transit-input.ndjson
./_build/native/release/build/cmd/main/main.exe --transit-evidence < evidence-transit-input.ndjson > evidence-transit-results.ndjson
./_build/native/release/build/cmd/main/main.exe --transit-evidence-checkpoint < evidence-transit-input.ndjson > evidence-transit-checkpoint.json
```

输出使用 `schema_version:"0.1.0"`、`kind:"evidence_transit_frame"`，`counting` 嵌套原 `gate_evidence_frame`，其余 `passages`、`cancellations`、`counts`、`pending_count` 与均值区间结果同义。时间与计数均保留十进制字符串。检查点使用 `format:"moonground.evidence-transit"`、`checkpoint_version:"1"`，嵌套完整证据检查点；pending 两端协方差用 `[xx,xy,yy]`，不可缺失或从默认值补全。

`codec.EvidenceTransitReplay::open/process_line/checkpoint_json` 与 CLI 同协议。fresh 首行限 1,048,576 个 UTF-16 代码单元，恢复首行限 8,388,619、完整检查点限 8,388,608，每测量原文限 1,048,576、嵌套限 32。CLI 默认物理行 1 MiB，大恢复头用 `--max-line-bytes` 显式放宽，最大 16 MiB；失败退出 2，流式保留完整前缀，检查点模式失败 stdout 为空。

纯函数 `codec.evidence_transit_json`／JavaScript `moonground_evidence_transit` 接受 `{"source":<原始首行字符串>,"measurements":<原始测量NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。请求限 16,777,216 个 UTF-16 代码单元，测量文本及完整返回各限 8,388,608、最多 5,000 帧；无持久句柄，失败不返回前缀。浏览器提供独立证据通行面板，显式选择普通或证据健康门控测量，操作与恢复边界见 [Web 使用说明](docs/evidence-transit-web.md)。

本批的有限 Mooncakes 检索核读了 [MBMOT 0.3.1 analytics](https://mooncakes.io/docs/python123-ops/mbmot@0.3.1/analytics) 的空间事件、区域转换与帧数停留，以及 [Moon-Kalman 0.2.1](https://mooncakes.io/docs/Lyllyl789/moon-kalman@0.2.1) 的滤波协方差和检查点 API。所查公开 API 未见“协方差确认双门通行、原时钟时长括号、独立完整恢复”的直接对应；这一结论限于所查页面。

### 联合证据通行协议

`--analyze-transit-evidence` 首行为 `{"measurement":<原始测量来源JSON字符串>,"transit":<原始证据区间来源JSON字符串>}`，两侧可分别为 fresh 或完整 resume；也可直接使用 `{"resume":<完整联合检查点对象>}`。后续直接输入原 pixel／ground 观测行，保留原始整数 token、重复键和未知字段检查。

```sh
python -c 'import json; from pathlib import Path; lines=Path("examples/warehouse.ndjson").read_text(encoding="utf-8").splitlines(); print(json.dumps({"measurement":lines[0],"transit":Path("examples/evidence-transit-source.json").read_text(encoding="utf-8")})); print("\n".join(lines[1:]))' > joint-transit-input.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-transit-evidence < joint-transit-input.ndjson > joint-transit-results.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-transit-evidence-checkpoint < joint-transit-input.ndjson > joint-transit-checkpoint.json
```

恢复首行后追加严格更晚的原始观测。普通结果为 `schema_version:"0.1.0"`、`kind:"evidence_transit_analysis_frame"`，嵌套原 `measurement` 和 v0.15 `transit` 结果。完整检查点使用 `format:"moonground.evidence-transit-analysis"`、`checkpoint_version:"1"`，同时保存两侧状态；旧测量、计数和独立区间格式保持各自含义。

`codec.EvidenceTransitAnalysisReplay::open/process_line/checkpoint_json` 使用同一协议。首行原文限 8,388,619 个 UTF-16 代码单元，完整检查点合计限 8,388,608；内嵌来源仍受各自 fresh／resume 限制，单观测原文限 1,048,576，嵌套限 32。CLI 默认物理行 1 MiB，恢复大检查点时可用 `--max-line-bytes` 放宽至 16 MiB；失败退出 2，流式保留已完整输出的前缀，检查点模式失败 stdout 为空。

纯函数 `codec.evidence_transit_analysis_json`／JavaScript `moonground_evidence_transit_analysis` 接受 `{"source":<原始联合首行字符串>,"observations":<原始观测NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。请求限 16,777,216 个 UTF-16 代码单元，观测文本及整个返回各限 8,388,608、最多 5,000 帧；无持久句柄，失败不返回批次前缀。联合提交覆盖内存计算状态；外部日志、存储和事件交付由宿主管理。

浏览器在证据区间面板增加原观测联合模式，读取上方观测原文与本区原始配置，提供独立滑块、完整结果、所选帧完整检查点及共同恢复。与独立下游模式分别保存结果，操作说明见 [Web 使用说明](docs/evidence-transit-web.md)。本批沿用所查 Mooncakes 基础滤波／空间事件的复用边界，所查公开 API 未见原始测量与协方差确认双门通行的完整原子恢复组合，检索范围见该说明。

### 健康门控的联合证据通行协议

`--guarded-transit-evidence` 的首行为 `{"analysis":<原始v0.16联合证据通行首行JSON字符串>,"health":<原始地标首行JSON字符串>}`，或 `{"resume":<完整门控证据通行检查点对象>}`。内层联合头仍为 `{"measurement":<原始测量来源字符串>,"transit":<原始v0.15证据通行来源字符串>}`。后续沿用原成对像素／地标字符串及显式投影替换行；两侧时间必须完全相同。完整合成输入见 [`examples/evidence-guarded-transit.ndjson`](examples/evidence-guarded-transit.ndjson)。

```sh
./_build/native/release/build/cmd/main/main.exe --guarded-transit-evidence < examples/evidence-guarded-transit.ndjson > evidence-guarded-transit-results.ndjson
./_build/native/release/build/cmd/main/main.exe --guarded-transit-evidence-checkpoint < examples/evidence-guarded-transit.ndjson > evidence-guarded-transit-checkpoint.json
python -c 'from pathlib import Path; print("{\"resume\":"+Path("evidence-guarded-transit-checkpoint.json").read_text(encoding="utf-8").strip()+"}")' > evidence-guarded-transit-resume.ndjson
```

普通帧与投影替换帧分别为 `kind:"evidence_guarded_transit_frame"`、`kind:"evidence_guarded_transit_projection_replaced"`，使用 `schema_version:"0.1.0"`，内嵌原地标报告及 v0.16 联合帧。完整检查点为 `format:"moonground.evidence-guarded-transit"`、`checkpoint_version:"1"`，内嵌完整 `analysis` 和 `health`，无需手工配对水位。

`codec.EvidenceGuardedTransitReplay::open`、`process_line`、`checkpoint_json` 共用该协议；source 限 8,388,619 个 UTF-16 代码单元，检查点合计限 8,388,608，每条成对帧／控制行外层合计限 1,048,576，内层沿用原限制，嵌套限 32。纯函数 `codec.evidence_guarded_transit_json` 与 JavaScript `moonground_evidence_guarded_transit` 接受 `{"source":<原始首行字符串>,"observations":<原始成对及控制NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`，不分配会话句柄。外层限 16,777,216、观测限 8,388,608／5,000 行，完整返回限 8,388,608。CLI 错误退出 2，流式模式保留完整前缀、检查点模式失败无 stdout；纯批量失败无部分结果。

浏览器证据健康面板显式选择“证据过线”或“证据通行”，共享原始门控输入，分别保留回放、结果及检查点。新模式显示待入口、完成、取消和时间界；所选帧检查点重放至该帧，导入先由核心验证，再设置完整恢复头。编辑共享输入使依赖结果失效，迟到加载不会覆盖新输入。详见 [`docs/evidence-transit-web.md`](docs/evidence-transit-web.md)。

### 通行时限分窗协议

`--transit-windows` 首行为 `{"transit":<原始v0.15证据通行配置或resume字符串>,"window_us":"500000","duration_limits_us":["100000","300000","600000"],"origin_us":"0"}`，或 `{"resume":<完整统计检查点对象>}`。`origin_us` 可省略；所有 Int64 参数、时刻和计数沿用规范非负十进制字符串。时限为 1–16 个严格递增值，允许 0 和 Int64.MAX。后续每行为原 `evidence_transit_frame`，联合与门控宿主取其原嵌套 `transit` 结果，完整保留空帧和取消。

```sh
./_build/native/release/build/cmd/main/main.exe --transit-windows < transit-windows-input.ndjson > transit-windows-results.ndjson
./_build/native/release/build/cmd/main/main.exe --transit-windows-checkpoint < transit-windows-input.ndjson > transit-windows-checkpoint.json
```

`codec.EvidenceTransitWindowReplay::open`、`process_line`、`checkpoint_json` 共用该协议。结果使用 `kind:"evidence_transit_window_frame"`、`schema_version:"0.1.0"` 和 `classification_scope:"observed_chord_elapsed_bounds"`，输出当前窗、本帧关闭窗与未观察窗数。检查点为 `format:"moonground.evidence-transit-windows"`、`checkpoint_version:"1"`。输入结果中的原门、证据、完成、取消及累计字段均保留严格字段和数值校验；统计不认证外部历史来源。

source 原文限 8,388,619 个 UTF-16 代码单元、完整检查点合计限 8,388,608；每条原通行结果可到 8,388,608，容纳大于 1 Mi 的已有结果行，嵌套限 32。CLI 默认物理行仍为 1 MiB，大来源／结果输入可通过 `--max-line-bytes` 放宽至 16 MiB；错误退出 2，流式输出保留完整前缀，检查点模式失败无 stdout。

纯函数 `codec.transit_windows_json` 与 JavaScript `moonground_transit_windows` 接受 `{"source":<原始统计首行字符串>,"transits":<原始通行NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`，不分配会话句柄。外层限 16,777,216、通行文本限 8,388,608／5,000 行、完整返回限 8,388,608；批量失败无部分结果。

浏览器“通行时限分窗统计”显式选择已有独立区间、原观测联合或健康门控通行结果，跟随所选来源滑块。统计报告、配置和完整检查点独立保存；导入先由核心验证，追加帧仍须晚于共同水位，不自动筛除旧帧。来源变化只使依赖该来源的统计失效。交互和本批所查生态能力关系见 [`docs/evidence-transit-web.md`](docs/evidence-transit-web.md)。

### 原始观测与分窗的共同恢复

`analysis.EvidenceTransitWindowSession::new(analysis, window_us~, duration_limits_us~, origin_us~)` 分离并验证现有 v0.16 会话，以其当前证据通行检查点建立统计基线。它接受新建或已开始的 pixel／ground 会话；之前完成的通行不补进新窗口，原待入口可以在之后完成。每帧先在独立上游分支计算，再更新原 v0.18 统计器，两步成功后提交同一水位。结果包含原 `analysis` 和 `windows`，完整检查点同时保存运动、法向证据、待入口、累计、统计基线和当前窗。

```mbt check
///|
test "README: raw observations restore measurement pending entry and statistics together" {
  let motion = @moonground.MotionEstimator::new(
    "joint-window-example",
    @moonground.MotionConfig::new(q=1000000.0, gate=1.0e12, max_tracks=10),
  )
  let transit = @transit.EvidenceTransitCounter::new(
    @events.EvidenceGateCounter::new(
      "joint-window-example",
      [
        @events.LineGate::new("entry", { x: 0.0, y: 0.0, }, { x: 10.0, y: 0.0, }),
        @events.LineGate::new("exit", { x: 0.0, y: 2.0, }, { x: 10.0, y: 2.0, }),
      ],
      @events.GateConfig::new(max_tracks=10),
    ),
    [
      @transit.Section::new(
        "aisle",
        "entry",
        @events.NegativeToPositive,
        "exit",
        @events.NegativeToPositive,
      ),
    ],
  )
  let joined = @analysis.EvidenceTransitWindowSession::new(
    @analysis.EvidenceTransitSession::from_ground(motion, transit),
    window_us=200000L,
    duration_limits_us=[0L, 100000L, 200000L],
  )
  let observation = (y : Double) => {
    @moonground.GroundObservation::new(
      7,
      { x: 5.0, y, },
      @moonground.Covariance2::isotropic(0.01),
    )
  }
  ignore(joined.update_ground(0L, [observation(-1.0)]))
  assert_eq(
    joined.update_ground(100000L, [observation(1.0)]).analysis.transit.pending_count,
    1,
  )
  let restored = @analysis.EvidenceTransitWindowSession::from_checkpoint(
    joined.checkpoint(),
  )
  let frame = restored.update_ground(200000L, [observation(3.0)])
  let result = frame.analysis.transit
  assert_eq(result.passages.length(), 1)
  assert_eq(result.counts[0].completed, 1L)
  assert_eq(result.passages[0].elapsed_upper_us, 200000L)
  assert_true(frame.windows.closed_window is Some(_))
  assert_eq(frame.windows.current_window.start_us, 200000L)
  assert_eq(frame.windows.current_window.input_frames, 1L)
  assert_eq(frame.windows.current_window.sections[0].completed, 1L)
  assert_eq(
    frame.windows.current_window.sections[0].duration_limits[2].within,
    1L,
  )
}
```

恢复先验证两份原组件，再逐值绑定会话、水位、门和区间顺序、端点、方向、死区、策略、证据倍率和完成累计。还合并运动首末点、隐藏轨迹、门参考点及待入口端点，核对起点、当前窗已知时刻数与输入帧数；接受次数给出的最少当前窗帧数也须可满足。确定全部统计输入位于首个当前窗时，完成增量须全部计入该窗。当前窗五类取消加终身完成及当前待入口不能超过各区间入口方向的过线累计。上述是保存状态的必要关系，不恢复已丢弃的逐帧历史。

`interrupt(timestamp_us)` 关闭全部活跃片段并将同一空帧的取消计入一次统计；`fork()` 创建独立分支，pixel `reframed(transform)` 保留全部米制状态和原窗口。上游数值或计数错误可以修正后同时间重试。未开始会话若输入早于 `origin_us`，上游候选成功后仍被统计器拒绝，整个会话保持未开始；下一次输入须使用符合起点的时刻。

### 原始观测与分窗的联合协议

CLI `--analyze-transit-windows` 首行为 `{"analysis":<原始v0.16配置或resume字符串>,"windows":<原始统计选项或v0.18 resume字符串>}`。新统计选项只含 `window_us`、`duration_limits_us` 和可省略的 `origin_us`，均沿用规范十进制字符串，基线取实际联合分析状态；已有统计恢复头须通过共同状态绑定。也可直接传入 `{"resume":<完整联合检查点对象>}`，后续每行沿用原始 pixel／ground 观测格式。

```sh
./_build/native/release/build/cmd/main/main.exe --analyze-transit-windows < observations.ndjson > results.ndjson
./_build/native/release/build/cmd/main/main.exe --analyze-transit-windows-checkpoint < observations.ndjson > checkpoint.json
```

`codec.EvidenceTransitWindowAnalysisReplay` 共用该协议，帧为 `kind:"evidence_transit_window_analysis_frame"`、`schema_version:"0.1.0"`，内嵌原 `analysis` 和 `windows`。完整检查点格式为 `moonground.evidence-transit-window-analysis`、版本 `1`。纯函数 `codec.evidence_transit_window_analysis_json` 和 JavaScript `moonground_evidence_transit_window_analysis` 接受 `{"source":<原始首行字符串>,"observations":<原始观测NDJSON字符串>}`，返回帧和完整检查点，不占用会话句柄。

纯函数外层请求限 16 Mi UTF-16 代码单元，观测文本 8 Mi／5,000 行，原观测单行 1 Mi，完整输出含检查点 8 Mi；新统计选项限 1 Mi，完整检查点限 8 Mi。CLI 沿用默认 1 Mi 物理行预算及显式放宽选项，普通模式错误前的完整前缀可以已输出，检查点模式失败无输出。浏览器在现分窗面板选择“原观测联合”模式，可导出所选帧的完整检查点并恢复三份输入；导入先验证共同状态再提交，追加观测仍须晚于共同水位。交互及所查生态 API 边界见 [`docs/evidence-transit-web.md`](docs/evidence-transit-web.md)。

## 验证与复现

以下开发命令在完整项目目录运行。Mooncakes 源码包只保留库、命令、JavaScript 桥及其必要文件，开发示例、验证脚本和网页资源保留在项目仓库中。

```sh
moon fmt --check
moon info
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
node web/build.mjs
node --test web/parity.test.mjs
python validation/checkpoint_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/checkpoint-v0.19-results.json
python validation/robust_fit_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/robust-fit-v0.19-results.json
python validation/reframe_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/reframe-v0.19-results.json
python validation/gates_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/gates-v0.19-results.json
python validation/analysis_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/analysis-v0.19-results.json
python validation/health_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/health-v0.19-results.json
python validation/guarded_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/guarded-v0.19-results.json
python validation/transit_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/transit-v0.19-results.json
python validation/projection_replace_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/projection-replace-v0.19-results.json
python validation/evidence_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-v0.19-results.json
python validation/evidence_analysis_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-analysis-v0.19-results.json
python validation/evidence_guarded_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-guarded-v0.19-results.json
python validation/evidence_transit_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-transit-v0.19-results.json
python validation/evidence_transit_analysis_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-transit-analysis-v0.19-results.json
python validation/evidence_guarded_transit_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-guarded-transit-v0.19-results.json
python validation/transit_windows_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/transit-windows-v0.19-results.json
python validation/evidence_transit_window_analysis_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/evidence-transit-window-analysis-results.json
```

浏览器交互测试需要外部安装 Playwright 或 Playwright Core `1.62.1` 与浏览器。设置 `PLAYWRIGHT_MODULE` 为该包路径后，执行 `node --test web/ui.test.cjs`；默认使用配套 Chromium，设置 `MOONGROUND_BROWSER_CHANNEL=chrome` 可使用已安装的 Google Chrome。CI 使用 GitHub Ubuntu runner 预装的 Chrome，并从固定上游 blob 下载、校验 Noto Sans CJK SC 字体，记录实际浏览器版本与字体，避开系统软件源下载。交互用例覆盖桌面与 390 像素移动视口、本地导入、下载、旧结果失效、原始像素标定配置、选帧检查点的导出与续接、坐标变换、双向过线与死区、独立配对恢复和完整联合恢复、固定地标状态、门控阻断、标定切换与末帧完整检查点、区间统计来源选择和下游恢复、整数 token 保留、控制点草稿保护和异步操作取消。

安装 NumPy 后，可执行独立参考与长流检查。固定工具链在 Linux 和 Windows 上的原生产物均命名为 `main.exe`。

```sh
python validation/verify.py --binary _build/native/release/build/cmd/main/main.exe --output validation/regression-v0.19-results.json
python validation/stream_test.py --binary _build/native/release/build/cmd/main/main.exe --frames 3000 --targets 10 --latency-samples 100 --output validation/stream-v0.19-results.json
moon package
python validation/camera_verify.py --binary _build/native/release/build/cmd/main/main.exe --output validation/camera-v0.19-results.json
python examples/consumer/archive_smoke.py --archive _build/publish/python123-ops-moonground-0.19.0.zip --output validation/package-v0.19-results.json
```

v0.19.0 的原观测联合分窗验证见 [`validation/evidence-transit-window-analysis-results.json`](validation/evidence-transit-window-analysis-results.json)：22 个确定性场景、120 帧，含 7 次完成、5 次取消和 40 个封存窗。逐项比较原 v0.16 测量／证据通行到 v0.18 分窗的宿主链，并用 Python 整数对完整输入离线分组，完整帧与最终状态一致；142 个原生切点分别从完整联合检查点和两份原组件恢复，44 项严格拒绝通过，其中 18 对检查点的组件可各自合法恢复，组合关系却不成立。

同一记录包含 Node 8 项测试，28 个切点完成 112 次原生／JavaScript 四方向续接；Brown 预热四帧后像素换算并续接 11 帧，原米制运动、待入口与整个窗口状态保持。实际验证 16 个区间 × 16 个时限，4,000 空帧成功返回 7,097,225 个 UTF-16 代码单元；5,000 帧因完整返回超过 8 Mi 拒绝，5,001 帧先因帧数超限拒绝。起点之前的帧在上游计算成功后整体回滚；上游计数溢出验证同时间修正，未以不相容的合成检查点宣称可达的窗口计数溢出。

库四后端各 514 项、工作区消费者连库各 550 项通过，其中消费者 36 项。独立 ZIP 消费者记录见 [`validation/package-v0.19-results.json`](validation/package-v0.19-results.json)。Chromium 151.0.7922.34 与 Chrome 157.0.8103.52 的完整交互流程均通过，包含 pixel／ground 共同恢复、所选帧检查点、旧三来源兼容、异步取消，以及 390／1440 像素视口检查。

v0.19 对此前 18 项独立参考及运动长流重新回归，记录见 [`regression`](validation/regression-v0.19-results.json)、[`camera`](validation/camera-v0.19-results.json)、[`checkpoint`](validation/checkpoint-v0.19-results.json)、[`robust-fit`](validation/robust-fit-v0.19-results.json)、[`reframe`](validation/reframe-v0.19-results.json)、[`gates`](validation/gates-v0.19-results.json)、[`analysis`](validation/analysis-v0.19-results.json)、[`health`](validation/health-v0.19-results.json)、[`guarded`](validation/guarded-v0.19-results.json)、[`transit`](validation/transit-v0.19-results.json)、[`projection-replace`](validation/projection-replace-v0.19-results.json)、[`evidence`](validation/evidence-v0.19-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.19-results.json)、[`evidence-guarded`](validation/evidence-guarded-v0.19-results.json)、[`evidence-transit`](validation/evidence-transit-v0.19-results.json)、[`evidence-transit-analysis`](validation/evidence-transit-analysis-v0.19-results.json)、[`evidence-guarded-transit`](validation/evidence-guarded-transit-v0.19-results.json)、[`transit-windows`](validation/transit-windows-v0.19-results.json) 和 [`stream`](validation/stream-v0.19-results.json)。长流性能仍针对既有运动协议，包含宿主产流、管道和调度。

v0.18.0 的精确分窗验证见 [`validation/transit-windows-results.json`](validation/transit-windows-results.json)：39 个确定性场景、184 帧，含 29 次完成、24 次取消和 74 个封存窗口。独立参考使用 Python 整数对完整输入离线分组，再逐项分类与计数，与逐帧生产归约结果完全一致；223 个原生恢复切点和 60 项严格输入／状态关系拒绝通过。覆盖全部五种取消、起始检查点中旧待入口的后续完成、长期未确认及参考点重建、阈值等号、大于 2^53 的时钟、Int64.MAX、不可表示的排他终点与巨大无输入间隔。

同一记录包含 Node 8 项测试，11 个切点完成 44 次原生／JavaScript 四方向续接。实测 16 个区间 × 16 个时限，以及同帧 6,400 次完成通行的大于 1 MiB 原结果输入；CLI 在显式放宽物理行预算后与纯函数结果一致，默认物理行预算仍按规则拒绝。完整返回的 8 Mi 上限、5,000 行边界与原 64 个会话句柄容量也已验证。

库四后端各 484 项、工作区消费者连库各 517 项通过，其中消费者 33 项；新用例检验完整统计恢复、原始累计基线、终端窗口和取消计数溢出后的同时间修正。独立 ZIP 消费者结果见 [`validation/package-v0.18-results.json`](validation/package-v0.18-results.json)。

v0.18 原有功能回归记录见 [`regression`](validation/regression-v0.18-results.json)、[`camera`](validation/camera-v0.18-results.json)、[`checkpoint`](validation/checkpoint-v0.18-results.json)、[`robust-fit`](validation/robust-fit-v0.18-results.json)、[`reframe`](validation/reframe-v0.18-results.json)、[`gates`](validation/gates-v0.18-results.json)、[`analysis`](validation/analysis-v0.18-results.json)、[`health`](validation/health-v0.18-results.json)、[`guarded`](validation/guarded-v0.18-results.json)、[`transit`](validation/transit-v0.18-results.json)、[`projection-replace`](validation/projection-replace-v0.18-results.json)、[`evidence`](validation/evidence-v0.18-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.18-results.json)、[`evidence-guarded`](validation/evidence-guarded-v0.18-results.json)、[`evidence-transit`](validation/evidence-transit-v0.18-results.json)、[`evidence-transit-analysis`](validation/evidence-transit-analysis-v0.18-results.json)、[`evidence-guarded-transit`](validation/evidence-guarded-transit-v0.18-results.json) 和 [`stream`](validation/stream-v0.18-results.json)。长流性能仍针对既有运动协议。

v0.17.0 的健康证据通行验证见 [`validation/evidence-guarded-transit-results.json`](validation/evidence-guarded-transit-results.json)：14 个确定性场景、222 帧，其中 114 帧放行、108 帧阻断，含 17 次投影替换、356 条法向证据、118 次过线、34 次完成及 36 次取消。宿主分别运行原健康与 v0.16 联合通行组件，完整运动、协方差、路径、健康序列、待入口及累计与新入口逐值一致；236 个原生切点分别从完整检查点和两份组件检查点恢复，41 项严格输入／状态关系拒绝通过。另构造 5 份各组件单独合法、健康确认时间却矛盾的检查点，均被组合恢复拒绝，覆盖隐藏轨迹、历史门参考点与待入口端点。

独立 NumPy 地标残差范数最大绝对差约 `4.20e-11 m`，有限通道交点差约 `4.44e-16 m`，法向标准差最大相对差约 `1.40e-16`。精确 `Fraction` 插值时长参考的最大绝对差约 `1.32e-11 μs`、最大相对差约 `1.01e-16`；整数时长界保持精确。这些差值描述固定合成输入上的实现比较，不代表现场测量精度。

同一记录包含 Node 9 项测试，30 个切点完成 120 次原生／JavaScript 四方向续接；Brown 预热四帧后共同换算，再续接 14 帧，健康序列及米制运动、证据、待入口保持。库四后端各 454 项、工作区消费者连库各 484 项通过，其中消费者 30 项；新增公开 API 用例实际检验首次健康确认数值失败、真实待入口出口计数溢出与同时间修复，以及换算、阻断和投影替换。独立 ZIP 消费者结果见 [`validation/package-v0.17-results.json`](validation/package-v0.17-results.json)。

v0.17 原有功能回归记录见 [`regression`](validation/regression-v0.17-results.json)、[`camera`](validation/camera-v0.17-results.json)、[`checkpoint`](validation/checkpoint-v0.17-results.json)、[`robust-fit`](validation/robust-fit-v0.17-results.json)、[`reframe`](validation/reframe-v0.17-results.json)、[`gates`](validation/gates-v0.17-results.json)、[`analysis`](validation/analysis-v0.17-results.json)、[`health`](validation/health-v0.17-results.json)、[`guarded`](validation/guarded-v0.17-results.json)、[`transit`](validation/transit-v0.17-results.json)、[`projection-replace`](validation/projection-replace-v0.17-results.json)、[`evidence`](validation/evidence-v0.17-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.17-results.json)、[`evidence-guarded`](validation/evidence-guarded-v0.17-results.json)、[`evidence-transit`](validation/evidence-transit-v0.17-results.json)、[`evidence-transit-analysis`](validation/evidence-transit-analysis-v0.17-results.json) 和 [`stream`](validation/stream-v0.17-results.json)。长流性能仍针对既有运动协议。

v0.16.0 的联合证据通行验证见 [`validation/evidence-transit-analysis-results.json`](validation/evidence-transit-analysis-results.json)：17 个确定性场景、111 帧、212 条证据、17 次过线、5 次完成通行，覆盖全部六种运动输出状态。完整运动状态、协方差、路径、段号、证据参考点、待入口两端协方差和累计与原测量／独立通行链路逐值一致；128 个原生切点分别从完整检查点和两份组件检查点续接，44 项严格输入及状态关系拒绝通过。

独立 `Fraction`／`Decimal` 参考核对相对时长及法向证据：本批最大插值时长绝对差约 `1.32e-11 μs`、相对差约 `6.59e-17`，法向标准差最大相对差约 `3.33e-16`，带端点尺度归一化最大差约 `6.66e-16`，有限交点最大绝对差约 `2.22e-16 m`。另用大绝对时钟的微秒间隔实际完成双门通行，精确时长界为 `[1,3] μs`；未把绝对时钟转为 Double。

同一记录包含 Node 9 项测试，28 个切点完成 112 次原生／JavaScript 四方向续接；Brown 预热四帧后共同像素换算，再续接 11 帧，米制运动和待入口状态保持。库四后端各 421 项、工作区消费者连库各 448 项通过，其中消费者 27 项；独立 ZIP 结果见 [`validation/package-v0.16-results.json`](validation/package-v0.16-results.json)。本批新增消费者验证公开 API 的同时间修正、完整待入口恢复、Brown 换算与关闭隐藏片段。

v0.16 原有功能回归记录见 [`regression`](validation/regression-v0.16-results.json)、[`camera`](validation/camera-v0.16-results.json)、[`checkpoint`](validation/checkpoint-v0.16-results.json)、[`robust-fit`](validation/robust-fit-v0.16-results.json)、[`reframe`](validation/reframe-v0.16-results.json)、[`gates`](validation/gates-v0.16-results.json)、[`analysis`](validation/analysis-v0.16-results.json)、[`health`](validation/health-v0.16-results.json)、[`guarded`](validation/guarded-v0.16-results.json)、[`transit`](validation/transit-v0.16-results.json)、[`projection-replace`](validation/projection-replace-v0.16-results.json)、[`evidence`](validation/evidence-v0.16-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.16-results.json)、[`evidence-guarded`](validation/evidence-guarded-v0.16-results.json)、[`evidence-transit`](validation/evidence-transit-v0.16-results.json) 和 [`stream`](validation/stream-v0.16-results.json)。长流性能仍针对既有运动协议。

v0.15.0 的证据通行验证见 [`validation/evidence-transit-results.json`](validation/evidence-transit-results.json)：28 个确定性场景、112 帧、216 条证据、61 次过线、19 次完成通行，140 个原生切点恢复后状态一致，65 项严格拒绝通过；另用两条原门控／投影替换链消费 47 帧，在 49 个切点核对恢复，4 次替换屏障不跨段补配。`k=0` 在相同协方差支持域下重放 28 个场景，与旧区间输出逐值一致，完成 21 次通行。

独立 `Fraction`／`Decimal` 参考核对原 binary64 数值：法向标准差最大相对差约 `1.92e-16`，带端点尺度归一化最大差约 `3.14e-16`，有限交点最大绝对差约 `4.44e-16 m`。时间括号和上下界保持精确 Int64；单独的 Double 插值估计在上界不超过 `1e6 μs` 的场景中最大绝对差约 `1.20e-11 μs`，近 Int64 上限长弦的绝对差约 `513.2 μs`、相对差约 `9.27e-17`，不能把后者解释为微秒绝对精度。

同一记录包含 Node 10 项测试，15 个切点完成 60 次原生／JavaScript 四方向续接。原生实测 12,800 条待入口及完成通行，待入口检查点为 4,339,375 个 UTF-16 代码单元；完整完成帧超过 8 Mi 时，纯批量入口按完整返回上限拒绝并不返回前缀。65,536 槽仅测试构造容量边界。库四后端各 393 项、工作区消费者连库各 417 项通过，其中消费者 24 项；独立 ZIP 结果见 [`validation/package-v0.15-results.json`](validation/package-v0.15-results.json)。Chromium 151 与 Chrome 157 的完整交互用例分别通过，含原时钟续接、空帧取消、来源失效和迟到导入保护；390／1440 像素预览已检查。

v0.15 原有功能回归记录见 [`regression`](validation/regression-v0.15-results.json)、[`camera`](validation/camera-v0.15-results.json)、[`checkpoint`](validation/checkpoint-v0.15-results.json)、[`robust-fit`](validation/robust-fit-v0.15-results.json)、[`reframe`](validation/reframe-v0.15-results.json)、[`gates`](validation/gates-v0.15-results.json)、[`analysis`](validation/analysis-v0.15-results.json)、[`health`](validation/health-v0.15-results.json)、[`guarded`](validation/guarded-v0.15-results.json)、[`transit`](validation/transit-v0.15-results.json)、[`projection-replace`](validation/projection-replace-v0.15-results.json)、[`evidence`](validation/evidence-v0.15-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.15-results.json)、[`evidence-guarded`](validation/evidence-guarded-v0.15-results.json) 和 [`stream`](validation/stream-v0.15-results.json)。长流性能仍针对既有运动协议。

v0.14.0 的三方证据验证见 [`validation/evidence-guarded-results.json`](validation/evidence-guarded-results.json)：11 个场景、206 帧，放行与阻断各 103 帧，含 16 次投影切换、231 条证据和 81 次过线。健康序列、完整运动状态、协方差、路径、累计、参考点原协方差与投影配置均与原组件构造的宿主参考逐值一致；217 个原生切点分别从完整检查点及两份组件检查点恢复，41 项严格拒绝通过。独立地标残差范数与通道交点最大绝对差分别约 `4.20e-11 m`、`4.44e-16 m`，法向标准差最大相对差约 `1.40e-16`。

同一记录包含 7 项 Node 测试，30 个切点完成 120 次原生／JavaScript 四方向续接；Brown 预热状态换算后续接 14 帧，换算时保留的健康序列、米制运动和证据状态不变。库四后端各 362 项测试通过；工作区消费者连库各 383 项通过，其中 21 项为消费者用例。新增两项在同一运行实例中核对首次健康确认帧的数值失败保留整份检查点，再以同一时间修正，以及 Brown 共同换算、撤除镜头校正并切换投影后的冷确认和完整恢复。独立 ZIP 消费者记录见 [`validation/package-v0.14-results.json`](validation/package-v0.14-results.json)。

v0.14 回归记录见 [`regression`](validation/regression-v0.14-results.json)、[`camera`](validation/camera-v0.14-results.json)、[`checkpoint`](validation/checkpoint-v0.14-results.json)、[`robust-fit`](validation/robust-fit-v0.14-results.json)、[`reframe`](validation/reframe-v0.14-results.json)、[`gates`](validation/gates-v0.14-results.json)、[`analysis`](validation/analysis-v0.14-results.json)、[`health`](validation/health-v0.14-results.json)、[`guarded`](validation/guarded-v0.14-results.json)、[`transit`](validation/transit-v0.14-results.json)、[`projection-replace`](validation/projection-replace-v0.14-results.json)、[`evidence`](validation/evidence-v0.14-results.json)、[`evidence-analysis`](validation/evidence-analysis-v0.14-results.json) 和 [`stream`](validation/stream-v0.14-results.json)。流式性能仍针对既有运动协议。

v0.13.0 的联合证据验证见 [`validation/evidence-analysis-results.json`](validation/evidence-analysis-results.json)：13 个场景、96 帧、176 条证据和 7 次过线，与原测量及独立证据计数链路的完整运动状态、协方差、路径、片段、累计和参考点原协方差逐值一致。109 个原生切点分别从完整检查点及两份组件检查点恢复；42 项严格输入和状态关系拒绝通过。独立 `Fraction`／`Decimal` 法向参考的标准差最大相对差约 `3.33e-16`，带端点尺度归一化最大差约 `6.67e-16`；NumPy 交点最大绝对差约 `2.22e-16 m`。

同一记录包含 8 项 Node 测试，28 个切点完成 112 次原生／JavaScript 四方向续接。Brown 像素前缀经换算后续接 11 帧，保存的米制运动与证据状态保持。库在四后端各 335 项测试通过；工作区消费者连库各 354 项通过，其中 19 项为消费者用例。新增两项检验 Brown 预热后的共同换算／完整恢复，以及包含新身份的溢出帧整体回滚和同时间重试。独立 ZIP 消费者记录见 [`validation/package-v0.13-results.json`](validation/package-v0.13-results.json)。

v0.13 回归记录见 [`regression`](validation/regression-v0.13-results.json)、[`camera`](validation/camera-v0.13-results.json)、[`checkpoint`](validation/checkpoint-v0.13-results.json)、[`robust-fit`](validation/robust-fit-v0.13-results.json)、[`reframe`](validation/reframe-v0.13-results.json)、[`gates`](validation/gates-v0.13-results.json)、[`analysis`](validation/analysis-v0.13-results.json)、[`health`](validation/health-v0.13-results.json)、[`guarded`](validation/guarded-v0.13-results.json)、[`transit`](validation/transit-v0.13-results.json)、[`projection-replace`](validation/projection-replace-v0.13-results.json)、[`evidence`](validation/evidence-v0.13-results.json) 和 [`stream`](validation/stream-v0.13-results.json)。流式性能仍针对既有运动协议。

v0.12.0 的法向证据验证见 [`validation/evidence-results.json`](validation/evidence-results.json)：41 个确定性场景、132 帧、233 条证据和 135 次过线，173 个原生切点恢复后完整累计、参考点时间、位置及原协方差一致。独立参考使用原 binary64 数值的精确 `Fraction` 二次型、120 位 `Decimal` 平方根及 NumPy 有限弦交点；法向标准差最大相对差约 `4.16e-16`，距离与带端点按各自尺度归一化后的最大差约 `6.67e-16`。极大尺度场景的绝对误差单独记录，不能把归一化误差解释为米制绝对精度。

同一记录包含 10 项 Node 测试，12 个切点完成 48 次原生／JavaScript 四方向续接；38 项严格输入／恢复拒绝和 9 项数值域拒绝通过。另以 `k=0` 重放全部 41 个场景、132 帧，对原均值计数器的 140 次过线、全部计数结果和参考点状态逐值相等。库在四后端各 305 项测试通过；工作区消费者连库各 322 项通过，其中 17 项为消费者用例。新增两项分别检验同源运动协方差的方向性与完整恢复，以及 Brown 模型生成像素的门控阻断／投影切换流如何清除独立证据参考点。独立 ZIP 消费者记录见 [`validation/package-v0.12-results.json`](validation/package-v0.12-results.json)。

v0.12 回归记录见 [`regression`](validation/regression-v0.12-results.json)、[`camera`](validation/camera-v0.12-results.json)、[`checkpoint`](validation/checkpoint-v0.12-results.json)、[`robust-fit`](validation/robust-fit-v0.12-results.json)、[`reframe`](validation/reframe-v0.12-results.json)、[`gates`](validation/gates-v0.12-results.json)、[`analysis`](validation/analysis-v0.12-results.json)、[`health`](validation/health-v0.12-results.json)、[`guarded`](validation/guarded-v0.12-results.json)、[`transit`](validation/transit-v0.12-results.json)、[`projection-replace`](validation/projection-replace-v0.12-results.json) 和 [`stream`](validation/stream-v0.12-results.json)。流式性能记录针对既有运动协议，不作为新证据计数器的性能测量；此前各版记录继续保留。

v0.11.0 的标定切换验证见 [`validation/projection-replace-results.json`](validation/projection-replace-results.json)：5 个场景、98 帧含 16 次切换，完整运动状态、协方差、路径、计数、参考点及投影配置与原有独立组件构造的宿主参考一致。103 个原生切点分别从完整检查点、两侧旧检查点重组后续接；28 项非法输入被拒绝，支持从保存状态按原时间修正。独立 NumPy 地标残差范数最大绝对差约 `4.20e-11 m`，通道交点差约 `2.22e-16 m`。

同一记录包含 7 项 Node 测试，30 个切点在原生与 JavaScript 四种方向完成 120 次续接；实际验证 1 MiB 控制行边界，放宽 CLI 字节限制后仍受 JSON UTF-16 上限约束。下游区间统计在切换帧取消 2 条待入口，未产生跨切换通行。库在四后端各 277 项测试通过；工作区消费者连库各 292 项通过，其中 15 项为消费者用例。新增两个消费者场景使用两套 Brown 模型生成的像素与米制标定，核对切换前后检查点续接、保留累计及新段预热，并将空切换帧交给已恢复的区间计数器，确认旧入口取消而孤立出口不会补配。独立 ZIP 消费者记录见 [`validation/package-v0.11-results.json`](validation/package-v0.11-results.json)。

v0.11 回归记录见 [`regression`](validation/regression-v0.11-results.json)、[`camera`](validation/camera-v0.11-results.json)、[`checkpoint`](validation/checkpoint-v0.11-results.json)、[`robust-fit`](validation/robust-fit-v0.11-results.json)、[`reframe`](validation/reframe-v0.11-results.json)、[`gates`](validation/gates-v0.11-results.json)、[`analysis`](validation/analysis-v0.11-results.json)、[`health`](validation/health-v0.11-results.json)、[`guarded`](validation/guarded-v0.11-results.json)、[`transit`](validation/transit-v0.11-results.json) 和 [`stream`](validation/stream-v0.11-results.json)。此前各版记录继续保留。

v0.10.0 的区间验证见 [`validation/transit-results.json`](validation/transit-results.json)：21 个场景、87 帧、12 次完成通行，108 个检查点切点续接一致，覆盖全部五类取消。参考使用原有过线命令、独立 NumPy 交点及 Python `Fraction` 相对时间计算，最大位置差约 `2.22e-16 m`、插值时长绝对差约 `7.28e-12 μs`；42 项非法输入被拒绝，并实际验证累计溢出的完整前缀及修正重试。

同一记录包含 8 项 Node 测试，11 个切点在原生与 JavaScript 四种方向完成 44 次续接。实测保存 12,800 条待入口的 3,502,524 UTF-16 代码单元检查点，并完成 12,800 次同帧通行；原生完整结果行长 8,475,384 个代码单元，纯函数按整个返回 JSON 的 8 Mi 上限拒绝。65,536 槽位只验证了构造边界。库在四后端各 260 项测试通过；工作区消费者连库各 273 项通过，其中 13 项为消费者用例，新增真实运动帧续接及 Brown 健康阻断取消／恢复用例。独立 ZIP 消费者记录见 [`validation/package-v0.10-results.json`](validation/package-v0.10-results.json)。

v0.10 回归记录见 [`regression`](validation/regression-v0.10-results.json)、[`camera`](validation/camera-v0.10-results.json)、[`checkpoint`](validation/checkpoint-v0.10-results.json)、[`robust-fit`](validation/robust-fit-v0.10-results.json)、[`reframe`](validation/reframe-v0.10-results.json)、[`gates`](validation/gates-v0.10-results.json)、[`analysis`](validation/analysis-v0.10-results.json)、[`health`](validation/health-v0.10-results.json)、[`guarded`](validation/guarded-v0.10-results.json) 和 [`stream`](validation/stream-v0.10-results.json)。

v0.9.0 的门控验证见 [`validation/guarded-results.json`](validation/guarded-results.json)：6 个场景、108 帧各有 54 帧放行与阻断，关闭 24 段、产生 47 次过线；完整运动状态、协方差、路径、计数和参考点与使用原有地标／分析接口独立组合的宿主链路逐值相同。114 个原生切点分别从完整检查点和两份旧检查点重组后续接，结果一致。独立 NumPy 核对地标残差及通道交点，最大绝对差分别约 `9.16e-12 m`、`4.44e-16 m`。37 项非法输入被拒绝，并验证整帧错误后从保存状态使用同一时间修正。

同一记录包含 7 项 Node 测试，19 个切点在原生与 JavaScript 四种方向完成 76 次续接，覆盖两层原始文本、批量和整个返回 JSON 的边界。库在四后端各 232 项测试通过；工作区消费者连库各 243 项通过，其中 11 项为消费者用例。独立 ZIP 消费者记录见 [`validation/package-v0.9-results.json`](validation/package-v0.9-results.json)；新增 Brown 场景核对阻断关闭隐藏活跃段、完整检查点及预热换系、恢复后重新分段和真实过线累计。v0.9 回归记录见 [`regression`](validation/regression-v0.9-results.json)、[`camera`](validation/camera-v0.9-results.json)、[`checkpoint`](validation/checkpoint-v0.9-results.json)、[`robust-fit`](validation/robust-fit-v0.9-results.json)、[`reframe`](validation/reframe-v0.9-results.json)、[`gates`](validation/gates-v0.9-results.json)、[`analysis`](validation/analysis-v0.9-results.json)、[`health`](validation/health-v0.9-results.json) 和 [`stream`](validation/stream-v0.9-results.json)。

v0.8.0 的固定地标验证见 [`validation/health-results.json`](validation/health-results.json)：16 个场景、113 帧、449 项地标诊断，使用独立 NumPy Brown Newton 逆解、投影 Jacobian 和米制残差参考，覆盖四种确认状态及四类逐点拒绝。残差范数的最大绝对差约 `9.16e-12 m`，RMS 差约 `2.52e-12 m`。129 个原生检查点切点的续接保持逐帧诊断与最终状态，另有 6 组独立像素换系检查；50 项非法输入被拒绝，包括缺失有效配置字段、未饱和样本数不可达到的时间跨度和最大间隔为 1 微秒时的跨帧伪造。

同一记录包含 7 项 Node 测试，32 个切点在原生与 JavaScript 四种方向完成 128 次续接；实际触发 5,000 帧、UTF-16 文本和整个返回 JSON 含最终检查点的边界，并验证纯健康检查不占用 64 个测量会话句柄。消费者新增从 Brown 合成像素坐标到健康确认、持续偏移、恢复和预热换系的真实包接口用例；库在四后端各 205 项测试通过；工作区消费者连库各 215 项通过，其中 10 项为消费者用例。独立 ZIP 消费者记录见 [`validation/package-v0.8-results.json`](validation/package-v0.8-results.json)。

v0.8.0 重新运行的投影、镜头、恢复、稳健标定、像素换系、过线、联合状态和流式回归分别保存在 [`validation/regression-v0.8-results.json`](validation/regression-v0.8-results.json)、[`validation/camera-v0.8-results.json`](validation/camera-v0.8-results.json)、[`validation/checkpoint-v0.8-results.json`](validation/checkpoint-v0.8-results.json)、[`validation/robust-fit-v0.8-results.json`](validation/robust-fit-v0.8-results.json)、[`validation/reframe-v0.8-results.json`](validation/reframe-v0.8-results.json)、[`validation/gates-v0.8-results.json`](validation/gates-v0.8-results.json)、[`validation/analysis-v0.8-results.json`](validation/analysis-v0.8-results.json) 和 [`validation/stream-v0.8-results.json`](validation/stream-v0.8-results.json)。此前版本的记录继续保留。

v0.7.0 的联合验证见 [`validation/analysis-results.json`](validation/analysis-results.json)：10 个场景、89 帧包含 8 次实际过线，联合结果及完整状态、协方差、路径、计数和参考点与原有独立命令链路完全一致。在 99 个原生切点分别从完整联合检查点、两份旧检查点重组后续接，后续结果和最终状态一致；NumPy 独立核对有限通道交点和弦比例。36 项非法输入被拒绝，另实际验证计数溢出后的同时间修正、带内保留旧参考点、超过 `2^53` 的精确计数，以及 CLI 完整前缀和检查点失败无输出。

同一记录包含 9 项 Node 测试：55 个切点在原生与 JavaScript 四种导出／恢复方向完成 220 次续接，并验证联合纯函数不占用 64 个会话句柄、大输出行及整个返回 JSON 的边界。库在四后端各 180 项测试通过。消费者模块新增完整测量与计数更新、单一检查点恢复、预热像素换算和计数失败回滚用例；工作区四后端各 189 项测试通过，其中 9 项为消费者用例。独立 ZIP 消费者记录见 [`validation/package-v0.7-results.json`](validation/package-v0.7-results.json)。

既有投影、镜头、恢复、稳健标定、坐标变换、过线和流式回归分别保存在 [`validation/regression-v0.7-results.json`](validation/regression-v0.7-results.json)、[`validation/camera-v0.7-results.json`](validation/camera-v0.7-results.json)、[`validation/checkpoint-v0.7-results.json`](validation/checkpoint-v0.7-results.json)、[`validation/robust-fit-v0.7-results.json`](validation/robust-fit-v0.7-results.json)、[`validation/reframe-v0.7-results.json`](validation/reframe-v0.7-results.json)、[`validation/gates-v0.7-results.json`](validation/gates-v0.7-results.json) 和 [`validation/stream-v0.7-results.json`](validation/stream-v0.7-results.json)。此前版本的验证记录继续保留。

v0.6.0 的独立过线验证见 [`validation/gates-results.json`](validation/gates-results.json)：48 个场景、359 帧、1,057 次过线，使用 NumPy 线性方程独立求解有限线段交点，最大位置差约 `3.55e-15 m`，弦比例差约 `6.66e-16`。场景覆盖旋转通道和端点、有限延长线、闭区间死区、最近同侧参考点、初始化及不确定状态、Int64 时间边界、缺测与拒绝中断、质量和间隔边界、多通道及真实测量输入。

同一记录核对 9 个原生检查点切点的续接结果，拒绝 52 项非法输入；7 项 Node 测试比较原生与 JavaScript 的事件、累计及恢复行为，并实际触发旋转闭端点、极端比例原子拒绝、原始恢复包装边界及整个返回 JSON 的 8 Mi 展开上限。消费者新增真实 `MeasurementSession` 到 `GateCounter` 的接入，检查同帧配对恢复，以及像素坐标换算后继续使用米制通道。库四后端各 163 项测试通过。独立 ZIP 消费者记录见 [`validation/package-v0.6-results.json`](validation/package-v0.6-results.json)，包含 8 项消费者用例，连同库测试在四个后端运行。既有投影、镜头、恢复、稳健标定、坐标变换及流式回归分别保存在 [`validation/regression-v0.6-results.json`](validation/regression-v0.6-results.json)、[`validation/camera-v0.6-results.json`](validation/camera-v0.6-results.json)、[`validation/checkpoint-v0.6-results.json`](validation/checkpoint-v0.6-results.json)、[`validation/robust-fit-v0.6-results.json`](validation/robust-fit-v0.6-results.json)、[`validation/reframe-v0.6-results.json`](validation/reframe-v0.6-results.json) 和 [`validation/stream-v0.6-results.json`](validation/stream-v0.6-results.json)。此前版本的验证记录保留如下。

v0.5.0 的独立坐标变换验证见 [`validation/reframe-results.json`](validation/reframe-results.json)：576 个投影点以 NumPy 和独立 Brown Newton 逆解核对，最大位置差约 `9.51e-12 m`、协方差差约 `3.76e-16`、Jacobian 差约 `1.44e-14`。16 个完整流与 48 个续接切点覆盖完整滤波状态、协方差、路径和生命周期，状态最大差约 `3.52e-14`，协方差最大差约 `8.05e-15`；换算恢复头时米制 `motion` 数据逐值保持。

该记录还包含 35 项原生拒绝输入与完整前缀检查，以及 6 项 Node 测试：32 组测量方向对比、32 个精确保留运动数据的恢复头和 64 个续接流。原始 token、协议与帧错误共 25 项被拒绝，批量输入、输出、外层请求和帧数边界由实际调用触发。库四后端各 141 项测试通过；既有数值、相机、恢复、稳健标定及流式回归分别保存在 [`validation/regression-v0.5-results.json`](validation/regression-v0.5-results.json)、[`validation/camera-v0.5-results.json`](validation/camera-v0.5-results.json)、[`validation/checkpoint-v0.5-results.json`](validation/checkpoint-v0.5-results.json)、[`validation/robust-fit-v0.5-results.json`](validation/robust-fit-v0.5-results.json) 和 [`validation/stream-v0.5-results.json`](validation/stream-v0.5-results.json)。

独立 ZIP 消费者记录见 [`validation/package-v0.5-results.json`](validation/package-v0.5-results.json)：7 项消费者用例覆盖已发布 MBMOT、MoonDetEval 接入、镜头校正、恢复及预热会话坐标换算，并在四个后端连同库测试一起运行；记录保留归档哈希和各后端汇总，不链接源码工作区。

v0.4.0 的独立标定验证见 [`validation/robust-fit-results.json`](validation/robust-fit-results.json)：10 组场景、共 3,570 个密集投影点，覆盖原始像素、首四点共线、两个输入重排、像素和世界尺度变化、极大有限误标值，以及确实需要两轮重拟合的内点重分类。NumPy 从返回的最终内点独立进行归一化最小二乘解算，不复刻生产采样器。基础米制尺度下，密集点对独立重拟合的最大差约 `5.58e-12 m`；普通合成场景包含 `0.002 m` 控制点标注噪声和 25% 大误标，其对已知真值的最大投影差约 `0.00314 m`。更高噪声和世界坐标放大场景各自的误差、尺度、参数和矩阵单独保存在记录中。

该验证同时核对逐点残差与最终掩码、严格拟合默认行为、检查点隔离及 21 项拒绝输入；4 项 Node 用例比较原生与 JavaScript 的标定响应，并将稳健标定接入测量及会话恢复。库在四后端各 121 项测试通过；[`validation/package-v0.4-results.json`](validation/package-v0.4-results.json) 记录从独立 ZIP 运行的 6 项消费者用例。既有数值、镜头、恢复及流式回归见 [`validation/regression-v0.4-results.json`](validation/regression-v0.4-results.json)、[`validation/camera-v0.4-results.json`](validation/camera-v0.4-results.json)、[`validation/checkpoint-v0.4-results.json`](validation/checkpoint-v0.4-results.json) 和 [`validation/stream-v0.4-results.json`](validation/stream-v0.4-results.json)。

v0.3.0 的恢复基线见 [`validation/checkpoint-results.json`](validation/checkpoint-results.json)：36 个原生切点的后续帧和最终检查点逐值一致；30 个切点在原生与 JavaScript 四种导出／恢复组合中完成 120 次续接。用手写完整状态执行独立 NumPy 更新，状态、路径和位移误差为 0，协方差最大绝对误差约 `8.67e-19`。38 项损坏输入和 5 项原始小数 token 被拒绝，9 种数学整数形式接受；3,000 条轨迹形成的 2,012,898 字节恢复流在显式放宽 CLI 字节上限后完整往返。极端混合尺度数值失败也保留可恢复的上次接受状态。

v0.3.0 的四后端各 105 项库测试通过；包含 5 项消费者用例的独立归档检查见 [`validation/package-v0.3-results.json`](validation/package-v0.3-results.json)。[`validation/linux-v0.3-results.json`](validation/linux-v0.3-results.json) 记录隔离 Ubuntu 24.04 中从源码编译的四后端、数值参考和恢复验证，功能源码逐文件校验。该版 Windows 数值基线、相机回归和性能分别见 [`validation/regression-v0.3-results.json`](validation/regression-v0.3-results.json)、[`validation/camera-v0.3-results.json`](validation/camera-v0.3-results.json)、[`validation/stream-v0.3-results.json`](validation/stream-v0.3-results.json) 与 [`validation/capacity-v0.3-results.json`](validation/capacity-v0.3-results.json)。性能测量包含 Python 产流、管道、调度及输出哈希，具体参数和二进制哈希保存在各记录中。

v0.2.0 的独立验证保留在 [`validation/camera-results.json`](validation/camera-results.json)：2,350 个畸变点、8 个拟合点与 28 个留出点、80 帧原始像素运动序列、64 帧门限对照。相机点的世界位置最大差约 `1.13e-11 m`，组合 Jacobian 最大差约 `4.30e-15`；门限开启和关闭时，完整状态、协方差、路径和生命周期逐帧相同。脚本采用独立 Newton 逆解，生产实现采用有界收缩迭代。微小有效半径的域外拒绝也由实际 CLI 检查。

[`validation/regression-v0.2-results.json`](validation/regression-v0.2-results.json) 重新执行无相机配置的数值基线；[`validation/stream-v0.2-results.json`](validation/stream-v0.2-results.json) 记录 23 项进程协议检查和 3000 帧×10 目标运行。独立包验证记录在 [`validation/package-v0.2-results.json`](validation/package-v0.2-results.json)，隔离 Linux 记录在 [`validation/linux-v0.2-results.json`](validation/linux-v0.2-results.json)。验证记录保留各自脚本、二进制与归档哈希及命令。

以下保留 v0.1.0 的长流、外部数据和真实视频基线：

- [`validation/results.json`](validation/results.json) 记录 384 个投影点、4×64 帧运动差分、10,000 点协方差蒙特卡洛检查及 ETH Hotel 回放；NumPy 独立参考比较完整状态、协方差、速度与折线路径，绝对和相对容差均为 `1e-8`。蒙特卡洛相对协方差误差约 1.29%。静止真值案例的滤波折线仍累计约 4.23 米，说明该指标不能直接解释为真实行走距离。
- [`validation/stream-results.json`](validation/stream-results.json) 记录 23 项真实 CLI 检查，以及 100000 帧×10 目标的运行。该次 Windows 运行约 3201 帧/秒、进程峰值工作集约 8.73 MiB；吞吐包含 Python 产流、管道和哈希。逐帧管道往返 p50 约 0.293 ms、p95 约 0.353 ms，包含进程调度和管道开销。
- [`validation/capacity-results.json`](validation/capacity-results.json) 验证默认上限：1000 帧×1000 活跃目标，约 37.38 帧/秒，峰值工作集 15.26 MiB，管道往返 p95 约 29.46 ms。性能文件保留二进制哈希、命令与运行环境。
- [`examples/consumer/archive_smoke.py`](examples/consumer/archive_smoke.py) 把打包产物解压到临时目录，再通过独立模块和已发布的 MBMOT `0.3.0`、MoonDetEval `0.2.1` 检查四个后端，不链接源码工作区。检测 AP 侧链只核对框与类别，不核验物理测速精度。
- [`validation/linux-results.json`](validation/linux-results.json) 记录隔离 Ubuntu 24.04 验证：MoonBit 0.10.18、Node 22、NumPy 1.26.4，四后端各 46 项测试、原生数值参考和 23 项流协议检查通过。Linux 从校验过的发布依赖源码重新编译，没有复用 Windows 构建产物。

可选的 ETH Hotel 数据回放入口为 `python validation/verify.py --binary <native-binary> --eth`。它基于公开世界坐标轨迹做带噪声的单应往返，不提供独立的像素接触点或测速精度真值。真实视频流程的参数入口为 `python examples/video_demo.py --help`，使用外部 OpenCV HOG 检测、MBMOT 和原生 MoonGround；依赖见 [`examples/video-requirements.txt`](examples/video-requirements.txt)。外部视频、研究数据和渲染产物留在忽略的 `validation/data/`，不进入库发布包。

[`validation/video-results.json`](validation/video-results.json) 记录了实际视频前 60 秒、1500 帧的链路：775 次 HOG 检测进入原生跟踪和测量，11 个身份产生 77 条速度就绪输出。原始 Hotel 矩阵使用行、列顺序，接入时显式交换为 x、y；HOG 在该俯视画面产生了多人合并框。报告保留这些现象、参数和阶段哈希，不将输出数量解释为跟踪或测速精度。

依赖、数据及外部演示代码的来源见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。CI 固定工具链，检查四个后端、原生/JavaScript 一致性、浏览器交互、独立数值参考、流协议和打包消费者；大体积外部视频下载不属于普通 CI。
