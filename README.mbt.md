# MoonGround

MoonGround 把固定相机中的目标轨迹转换为米制地面位置、速度和观测路径，面向园区、仓储和其他近似平面的场地。输入是已有目标身份、地面接触锚点和真实时间戳；库负责标定有效域、投影协方差、运动估计、轨迹分段和双向通道过线统计，并支持两侧原子更新与完整状态恢复。固定地标检查持续核对原标定的米制残差；需要按检查结果决定是否计算对象测量时，可显式使用 `guarded` 入口。

当前开发版本为 `0.9.0`，尚未发布到 Mooncakes。源码使用 Apache-2.0 许可证，仓库为 [python123-ops/moonground](https://github.com/python123-ops/moonground)。

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
| `events` | 消费 `motion.FrameResult` 的有向有限通道、双向计数与独立 `GateCheckpoint` |
| `analysis` | 像素／米制测量与通道计数的原子更新、完整 `AnalysisCheckpoint`、独立分支与像素换算 |
| `health` | 独立固定地标的逐点残差、连续采样证据确认、完整 `HealthCheckpoint` 与像素换算 |
| `guarded` | 仅当前地标确认健康时计算对象测量与过线，阻断时结束全部片段，保存完整 `GuardedCheckpoint` |
| `codec` | 原生 CLI 与浏览器共用的严格 JSON 协议、检查点、`ReplayReframer`、`GateReplay`、`AnalysisReplay`、`HealthReplay` 与 `GuardedReplay` |

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

测量 JSON 的 `schema_version` 为 `0.2.0`，`uncertainty_scope` 为 `conditional_on_fixed_calibration_camera_and_anchor`。这是 v0.2.0 引入的结果格式，v0.9.0 继续使用；从 v0.1.0 接入的调用方需处理 `uncertain` 状态和两个标准差字段。

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

### 联合测量、计数与恢复

`analysis.AnalysisSession::from_pixel(measurement, counter)` 验证并复制位于同一水位的两个现有实例；两者均未开始时也可直接组合。输入已经是米制观测时使用 `from_ground(estimator, counter)`。通过 `update_pixel` 或 `update_ground` 直接传入原始观测、时间与 `lost`／`removed`，一次返回 `AnalysisFrame.measurement` 和 `counting`，无需先把测量结果编码再交给计数器。

联合更新先建立独立候选分支，测量和计数都完成后提交。计数溢出、不可表示的通道几何或计数容量错误也会回滚该帧的测量状态、协方差、路径、接受次数、段号分配和时间；修正后可用同一时间重试。按目标报告的投影拒绝、创新拒绝和数值失败仍是一个已提交帧，计数器按原有规则清除相应参考点。两层容量可不同，较严的计数限制可能拒绝整帧。

`AnalysisSession::checkpoint()` 导出版本 1 的 `AnalysisCheckpoint`；`from_checkpoint` 验证并创建独立实例。检查点的 `measurement` 为 `Pixel(MeasurementCheckpoint)` 或 `Ground(MotionCheckpoint)`，`counting` 保存完整 `GateCheckpoint`。除了各自的原有验证，还检查 session 与帧水位相同、当前接受且通过计数质量门限的目标集合完全一致、目标片段匹配，以及参考点属于该段的接受时间区间。当前点在带外时，参考点必须等于当前滤波点并具有当前时间；当前点在闭死区内时，可保留有效的旧带外参考点。当前滤波状态不足以重建过去全部位置，因此恢复只核对历史参考点的结构和时间关系。

`AnalysisSession::fork()` 创建独立计算分支；`MotionEstimator`、`MeasurementSession` 与 `GateCounter` 也提供 `fork()`。它们复制可变容器，内部已接受数组在后续更新中以新值替换；组合执行不逐帧导出、深拷贝和重新验证检查点。导出与导入检查点继续隔离全部可变数组。`AnalysisSession::reframed(transform)` 仅用于 pixel 模式：新实例同步换算相机与标定，完整保留米制运动、通道、参考点和计数，后续像素观测也须使用同一变换。

一个完整检查点消除了手工配对两侧水位的步骤。外部观测日志、文件原子替换和结果交付进度仍由宿主处理；检查点没有签名，也不自动去重下游事件。下游可用 `(session_id, gate_id, track_id, segment_id, to_timestamp_us)` 识别单次事件。

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
}
```

组合只支持 pixel 模式。分析与健康检查必须具有相同的时间水位，以及逐值相同的存储归一化单应矩阵、原顺序 ROI、`max_meters_per_pixel` 和地面噪声方差；`GroundCalibration::same_projection` 提供此身份检查，拟合／核验诊断不参与比较。相机必须同时存在或同时省略；存在时九项内参与 Brown 系数以及归一化有效半径都须相同。这里校验固定配置身份，不尝试用浮点容差判断两个不同标定是否近似等价。

计数器的 `max_tracks` 须至少覆盖运动测量的 `max_tracks`，确保任意阻断帧都能完整关闭全部片段。阻断不会只清除本帧可见目标：上一帧未输出但仍在滤波器中保留的活跃轨迹也会关闭，`closed_segment_ids` 明确列出片段。该帧仍提交健康证据、共同时间和空分析结果，保留两方向累计计数及下一段号。恢复健康后，同一目标身份获得新段、从一次接受观测重新预热，观测路径和过线参考点不会跨越阻断区间。

阻断期间原始对象载荷仍须通过有限像素、正定协方差、身份唯一／互斥和容量检查，随后才抑制对象计算；这些像素不经过被阻断的标定投影。`suppressed_track_ids` 仅包含本帧提交的观测身份并按数值排序，关闭的旧片段则另见分析结果。放行时沿用原有的逐目标投影拒绝、创新拒绝和数值失败语义。健康、测量或计数发生整帧错误时，三个组件都保留原状态，可修正后用同一时间重试。

`GuardedCheckpoint` 版本 1 同时保存完整分析和健康检查点。恢复先验证原有状态，再检查共同配置与水位：非健康状态不得带有活跃运动轨迹或过线参考点；健康状态中的片段首时间不得早于该证据序列可能达到确认跨度和最小样本数的时刻。这些是状态自洽检查，检查点不证明过去每次地标观测的真实性。`fork()` 创建独立分支，`reframed(transform)` 同时换算两侧固定像素配置，保持米制地标、路径、计数、证据和时间；未来对象与地标观测都须应用同一变换。

`AnalysisSession::interrupt(timestamp_us)` 也可由宿主显式调用，使用普通原子更新结束全部活跃段。`CalibrationMonitor::status()` 读取最后已提交地标帧的状态，不增加样本数或按墙上时间推断新证据。原有独立分析和健康检查继续分别工作；门控入口的放行含义仍受固定地标覆盖与原有测量条件限制，不认证未观测区域，也不自动重标定。

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

纯函数 `codec.guarded_json(...)` 与 JavaScript `moonground_guarded(...)` 接收 `{"source":<原始门控首行JSON字符串>,"observations":<原始成对观测NDJSON字符串>}`，返回 `{"frames":[...],"checkpoint":...}`。不分配会话句柄；原始观测总文本限 8,388,608 个 UTF-16 代码单元、5,000 帧，外层请求限 16,777,216，整个返回 JSON 连同最终检查点限 8,388,608。批量失败不返回部分结果。

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

“保存当前帧检查点”会重放到选定帧并下载完整状态，避免把未来帧状态误存为当前帧。导入检查点后，在输入区追加后续观测即可继续；格式或状态验证失败时保留原输入与结果。恢复流绑定原标定，修改标定需新建会话。“续接示例”可直接检查恢复流程；页面只展示恢复后本次处理的历史帧。

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

浏览器桥最多保留 64 个活跃 session，调用方用 `moonground_close` 释放。`moonground_checkpoint(handle)` 返回原始检查点 JSON；`moonground_restore(source)` 验证成功后分配新句柄，失败时不改变原句柄。`moonground_create(source)` 支持普通配置或原始 resume 包装文本。桥方法失败时返回 `{"error":...}`，恢复不会原位替换其他会话。

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
python validation/checkpoint_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/checkpoint-v0.9-results.json
python validation/robust_fit_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/robust-fit-v0.9-results.json
python validation/reframe_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/reframe-v0.9-results.json
python validation/gates_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/gates-v0.9-results.json
python validation/analysis_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/analysis-v0.9-results.json
python validation/health_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/health-v0.9-results.json
python validation/guarded_verify.py --binary _build/native/release/build/cmd/main/main.exe --web --output validation/guarded-results.json
```

浏览器交互测试需要外部安装 Playwright 或 Playwright Core `1.62.1` 与浏览器。设置 `PLAYWRIGHT_MODULE` 为该包路径后，执行 `node --test web/ui.test.cjs`；默认使用配套 Chromium，设置 `MOONGROUND_BROWSER_CHANNEL=chrome` 可使用已安装的 Google Chrome。CI 使用 GitHub Ubuntu runner 预装的 Chrome，并从固定上游 blob 下载、校验 Noto Sans CJK SC 字体，记录实际浏览器版本与字体，避开系统软件源下载。交互用例覆盖桌面与 390 像素移动视口、本地导入、下载、旧结果失效、原始像素标定配置、选帧检查点的导出与续接、坐标变换、双向过线与死区、独立配对恢复和完整联合恢复、固定地标状态、门控阻断与末帧完整检查点、整数 token 保留、控制点草稿保护和异步操作取消。

安装 NumPy 后，可执行独立参考与长流检查。固定工具链在 Linux 和 Windows 上的原生产物均命名为 `main.exe`。

```sh
python validation/verify.py --binary _build/native/release/build/cmd/main/main.exe --output validation/regression-v0.9-results.json
python validation/stream_test.py --binary _build/native/release/build/cmd/main/main.exe --frames 3000 --targets 10 --latency-samples 100 --output validation/stream-v0.9-results.json
moon package
python validation/camera_verify.py --binary _build/native/release/build/cmd/main/main.exe --output validation/camera-v0.9-results.json
python examples/consumer/archive_smoke.py --archive _build/publish/python123-ops-moonground-0.9.0.zip --output validation/package-v0.9-results.json
```

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
