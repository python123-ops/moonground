# 依赖与外部资源

MoonGround 自身采用 [Apache License 2.0](LICENSE)。下列依赖通过模块管理器获得，源码没有复制进 MoonGround 的算法文件。

| 依赖 | 固定版本 | 用途 | 上游许可与来源 |
| --- | --- | --- | --- |
| `python123-ops/moon-cv-geometry` | 0.2.2 | 控制点几何估计及相关数学基础 | Apache-2.0；[源码](https://github.com/python123-ops/moon-cv-geometry)、[注册表](https://mooncakes.io/docs/python123-ops/moon-cv-geometry@0.2.2/) |
| `Lyllyl789/moon-kalman` | 0.2.1 | Kalman 预测、更新及 Joseph 协方差公式 | Apache-2.0；[源码](https://github.com/Lyllyl789/moon-kalman)、[注册表](https://mooncakes.io/docs/Lyllyl789/moon-kalman@0.2.1/) |
| `moonbitlang/async` | 0.21.3 | 原生命令的标准输入、输出和参数适配 | Apache-2.0；[源码](https://github.com/moonbitlang/async)、[注册表](https://mooncakes.io/docs/moonbitlang/async@0.21.3/) |

MoonBit 标准库和工具链由 MoonBit 安装环境提供，遵循其各自上游许可证。MoonGround 的打包产物不包含这些依赖的源码副本。

## 开发与可选演示

- 独立消费者使用 `python123-ops/mbmot@0.3.0`（MIT，[上游](https://github.com/python123-ops/mbmot)）验证目标身份轨迹接入。它不是 MoonGround 核心测量包的运行依赖。
- 同一消费者使用 `python123-ops/moondeteval@0.2.1`（Apache-2.0，[上游](https://github.com/python123-ops/moondeteval)）核对检测框与类别映射；它不参与物理运动估计。
- `validation/verify.py` 使用外部安装的 NumPy 构建独立参考。NumPy 采用 BSD-3-Clause，[上游许可](https://github.com/numpy/numpy/blob/main/LICENSE.txt)。参考计算通过数组和线性代数独立实现，没有调用 MoonGround、moon-cv-geometry 或 moon-kalman。
- 浏览器测试使用外部安装的 Playwright `1.62.1` 及其 Chromium。Playwright 采用 Apache-2.0，[上游](https://github.com/microsoft/playwright)；浏览器本身遵循其随附许可。测试依赖和浏览器二进制不进入库包。
- `examples/video_demo.py` 运行时导入调用方指定 MBMOT 源目录中的 `tools/video_demo/detector.py`，使用其中未经修改的 `HogPersonDetector`；身份跟踪使用已发布 MBMOT `0.3.0` 的原生命令。检测器和预训练参数没有复制到 MoonGround 源码。OpenCV 通过外部 `opencv-python==4.10.0.84` 安装，OpenCV 4.10 采用 Apache-2.0，[许可说明](https://opencv.org/license/)；wheel 随附组件遵循其各自声明。

## ETH Walking Pedestrians 数据

可选验证脚本从 ETH 官方地址读取 [ETH Walking Pedestrians 数据包](https://data.vision.ee.ethz.ch/cvl/aem/ewap_dataset_full.tgz)。数据用于研究回放，使用条件以[官方数据页面](https://vision.ee.ethz.ch/datsets.html)为准，不随 MoonGround 的 Apache-2.0 许可重新授权。

下载的原始轨迹、视频和相机矩阵存放于忽略的 `validation/data/`，不进入库 ZIP。随项目保留的验证记录只报告参数、哈希、计数和实际指标。世界轨迹经单应矩阵逆映射再投影的验证属于往返一致性检查，不构成独立的标定或速度精度真值。
