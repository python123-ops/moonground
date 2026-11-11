# MoonGround

MoonGround 把固定相机中的目标轨迹转换为米制地面位置、速度和观测路径，面向园区、仓储和其他近似平面的场地。输入是已有目标身份、地面接触锚点和真实时间戳；库负责标定有效域、投影协方差、运动估计和轨迹分段。

当前版本为本地开发的 `0.1.0`，尚未发布到 Mooncakes 或远程 GitHub 仓库。源码使用 Apache-2.0 许可证。

## 与现有项目的衔接

项目延续 [MoonTile](https://github.com/python123-ops/moontile)、[MoonDetEval](https://github.com/python123-ops/moondeteval)、[MBMOT](https://github.com/python123-ops/mbmot) 和 [moon-cv-geometry](https://github.com/python123-ops/moon-cv-geometry) 的视觉工具路线，增加固定相机下的地面测量层。

```text
检测结果 → MBMOT 身份轨迹 → 显式选择地面锚点 → MoonGround 米制测量
                            ↑                       ↑
                   检测质量可用 MoonDetEval     moon-cv-geometry
                                                + moon-kalman
```

MoonGround 复用 `moon-cv-geometry@0.2.2` 的几何能力与 `moon-kalman@0.2.1` 的线性 Kalman 更新、Joseph 协方差公式。这里新增的是视觉观测到地面测量的连接：凸 ROI 内的有效性检查、投影 Jacobian、相关协方差传播、真实时间间隔、身份生命周期和输出语义。完整 MBMOT 接入示例在 [`examples/consumer`](examples/consumer)。

| 入口 | 用途 |
| --- | --- |
| 根包 | `GroundCalibration`、`MeasurementSession`、像素观测和测量结果 |
| `calibration` | 控制点拟合、独立检查点、矩阵导入、有效域和协方差投影 |
| `motion` | 已有米制观测的时间处理、运动估计与分段 |
| `codec` | 原生 CLI 与浏览器共用的严格 JSON 协议 |

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
  ignore(session.update(200000L, [observe(110.0)]))
  let third = session.update(400000L, [observe(120.0)])
  match third.motion.tracks[0].speed_mps {
    Some(speed) => assert_true(speed > 0.45 && speed < 0.55)
    None => fail("three accepted observations should produce a speed")
  }
}
```

### 坐标、时间与测量条件

- 单应矩阵把图像中的 `(x, y)` 映射到地面的米制坐标。相机固定，ROI 内目标锚点位于同一测量平面；相机移动或标定改变时，创建新 session。
- 输入像素应完成镜头畸变校正。控制点、检查点、ROI 和目标锚点必须属于同一像素空间；图像裁剪或缩放后也要同步变换标定。
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

未满足就绪条件时，位置可用，速度和速率为 `null`。短时缺测不会生成预测速度或补零；`lost`、`removed` 立即关闭段，观测间隔达到上限也会切段。再次出现的同一目标身份使用新段并重新预热。段号为 session 内递增的十进制字符串。

`observed_path_length_m` 是已接受观测对应的因果滤波位置之间的折线弦长之和，受采样间隔和观测噪声影响；`net_displacement_m` 是该片段首末滤波位置的直线距离。这两项都没有补算缺测期间的真实运动路径。静止目标也可能因观测抖动产生正的折线长度。

输出协方差的条件是**固定标定、选定锚点及所配置噪声模型成立**。它不自动包含标定控制点误差、相机晃动或锚点与真实接触点的偏差。`uncertainty_scope` 会随 JSON 结果明确写出这一条件。

## 命令行与浏览器

```sh
moon update
moon build cmd/main --target native --release --deny-warn
./_build/native/release/build/cmd/main/main --stream < examples/warehouse.ndjson
```

Windows PowerShell 的等价回放命令为：

```powershell
Get-Content -Raw -Encoding UTF8 examples/warehouse.ndjson |
  & .\_build\native\release\build\cmd\main\main.exe --stream
```

`--stream` 接收 UTF-8 NDJSON：第一行为配置，后续每行为一个完整帧。

```jsonl
{"session_id":"warehouse","mode":"ground","motion":{"q":1}}
{"timestamp_us":"0","observations":[{"track_id":7,"point":[1,2],"covariance":[0.01,0,0.01]}]}
{"timestamp_us":"200000","observations":[{"track_id":7,"point":[1.1,2],"covariance":[0.01,0,0.01]}]}
{"timestamp_us":"400000","observations":[{"track_id":7,"point":[1.2,2],"covariance":[0.01,0,0.01]}]}
```

`mode:"pixel"` 还需要 `calibration.matrix` 和凸多边形 `calibration.roi`，格式见 [`examples/warehouse.ndjson`](examples/warehouse.ndjson)。`lost`、`removed` 为可选身份数组；配置中设置 `diagnostics:true` 可输出完整状态与 4×4 行优先协方差，供数值核对。

结构错误、重复或冲突身份、时间错误和容量错误会拒绝整帧，保留之前的状态。ROI 外或投影不可用的目标返回 `rejected_projection`，同帧其他目标继续测量。创新门限拒绝及数值失败也按目标报告，不把旧位置当作当前测量。

CLI 默认限制每物理行 1 MiB，可通过 `--max-line-bytes N` 调整，最大为 16 MiB；JSON 层另有 1,048,576 个 UTF-16 代码单元的文本上限，字节选项不会放宽这一限制。非法 UTF-8、坏 JSON 或协议错误写入 stderr 并以状态 2 退出；之前完成的结果行保留，失败帧不输出半行。CRLF 和最后一行没有换行符均可读取。

JSON 文本另限 1048576 个 UTF-16 代码单元、最多 32 层嵌套，重复键和未知字段会被拒绝。目标身份必须是正的 32 位整数。

`--project` 单独接收一行 `{ "calibration": ..., "points": [{ "point": [x,y], "covariance": [xx,xy,yy] }] }`，返回位置、协方差和 Jacobian。`--calibrate` 接收六对以上拟合点、两对以上独立检查点和 ROI，返回可用于配置的标定及残差报告；单行示例见 [`examples/calibration.json`](examples/calibration.json)。控制点拟合也可以直接调用 `GroundCalibration::fit`。

```sh
./_build/native/release/build/cmd/main/main --calibrate < examples/calibration.json
```

```sh
node web/build.mjs
node web/serve.mjs
```

浏览器页面可导入本地 NDJSON、逐帧查看测量、从控制点拟合标定、检查有效域并下载结果；计算沿用同一 MoonBit JSON 协议。页面输入改变后会清除旧结果。浏览器桥最多保留 64 个活跃 session，调用方用 `moonground_close` 释放。

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
```

浏览器交互测试需要外部安装 Playwright `1.62.1` 与 Chromium。设置 `PLAYWRIGHT_MODULE` 为该包路径后，执行 `node --test web/ui.test.cjs`；CI 配置在 Ubuntu 中安装浏览器。已运行的交互用例覆盖桌面与 390 像素移动视口、本地导入、下载和旧结果失效。

安装 NumPy 后，可执行独立参考与长流检查。下面采用 Linux/macOS 的二进制路径；Windows 加上 `.exe`。

```sh
python validation/verify.py --binary _build/native/release/build/cmd/main/main
python validation/stream_test.py --binary _build/native/release/build/cmd/main/main --frames 100000 --targets 10 --latency-samples 500
moon package
python examples/consumer/archive_smoke.py --archive _build/publish/python123-ops-moonground-0.1.0.zip --output validation/package-results.json
```

- [`validation/results.json`](validation/results.json) 记录 384 个投影点、4×64 帧运动差分、10,000 点协方差蒙特卡洛检查及 ETH Hotel 回放；NumPy 独立参考比较完整状态、协方差、速度与折线路径，绝对和相对容差均为 `1e-8`。蒙特卡洛相对协方差误差约 1.29%。静止真值案例的滤波折线仍累计约 4.23 米，说明该指标不能直接解释为真实行走距离。
- [`validation/stream-results.json`](validation/stream-results.json) 记录 23 项真实 CLI 检查，以及 100000 帧×10 目标的运行。该次 Windows 运行约 3201 帧/秒、进程峰值工作集约 8.73 MiB；吞吐包含 Python 产流、管道和哈希。逐帧管道往返 p50 约 0.293 ms、p95 约 0.353 ms，包含进程调度和管道开销。
- [`validation/capacity-results.json`](validation/capacity-results.json) 验证默认上限：1000 帧×1000 活跃目标，约 37.38 帧/秒，峰值工作集 15.26 MiB，管道往返 p95 约 29.46 ms。性能文件保留二进制哈希、命令与运行环境。
- [`examples/consumer/archive_smoke.py`](examples/consumer/archive_smoke.py) 把打包产物解压到临时目录，再通过独立模块和已发布的 MBMOT `0.3.0`、MoonDetEval `0.2.1` 检查四个后端，不链接源码工作区。检测 AP 侧链只核对框与类别，不核验物理测速精度。
- [`validation/linux-results.json`](validation/linux-results.json) 记录隔离 Ubuntu 24.04 验证：MoonBit 0.10.18、Node 22、NumPy 1.26.4，四后端各 46 项测试、原生数值参考和 23 项流协议检查通过。Linux 从校验过的发布依赖源码重新编译，没有复用 Windows 构建产物。

可选的 ETH Hotel 数据回放入口为 `python validation/verify.py --binary <native-binary> --eth`。它基于公开世界坐标轨迹做带噪声的单应往返，不提供独立的像素接触点或测速精度真值。真实视频流程的参数入口为 `python examples/video_demo.py --help`，使用外部 OpenCV HOG 检测、MBMOT 和原生 MoonGround；依赖见 [`examples/video-requirements.txt`](examples/video-requirements.txt)。外部视频、研究数据和渲染产物留在忽略的 `validation/data/`，不进入库发布包。

[`validation/video-results.json`](validation/video-results.json) 记录了实际视频前 60 秒、1500 帧的链路：775 次 HOG 检测进入原生跟踪和测量，11 个身份产生 77 条速度就绪输出。原始 Hotel 矩阵使用行、列顺序，接入时显式交换为 x、y；HOG 在该俯视画面产生了多人合并框。报告保留这些现象、参数和阶段哈希，不将输出数量解释为跟踪或测速精度。

依赖、数据及外部演示代码的来源见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。CI 固定工具链，检查四个后端、原生/JavaScript 一致性、浏览器交互、独立数值参考、流协议和打包消费者；大体积外部视频下载不属于普通 CI。
