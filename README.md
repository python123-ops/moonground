# MoonGround

固定相机目标轨迹的米制地面测量库。输入已有目标身份、地面接触锚点和真实时间戳，提供镜头校正、严格与稳健标定、协方差投影、运动估计及轨迹分段。

支持通道过线、证据通行、逐目标足迹、确认序列和有界分窗，可与固定地标健康检查共同提交、完整恢复，并显式切换标定。另提供指定方向的速度证据、区域支持区间，以及位置协方差椭圆与凸区域相交的上下界诊断。显式标定扰动模式可传播单点、位移、长度差值／比值、线段方向、有向夹角、凸多边形面积差值／比值，以及点到参考线偏移的一阶共享误差。

可用独立米制参考评估位置与 Ready 速度，统计误差、偏差、可用率以及缺测和拒绝状态。SQLite 回放任务支持按已提交水位增量评估，接续前核对测量与参考前缀。

当前版本为 `0.45.0`。完整说明、随测试执行的 MoonBit 示例、CLI 协议与复现命令见 [README.mbt.md](https://github.com/python123-ops/moonground/blob/main/README.mbt.md)，该文件是文档源文件。

## 安装与接入

本版本使用 MoonBit `0.10.18+6c83a7f62`，计算库支持 `wasm`、`wasm-gc`、`js` 和 `native`。

```sh
moon add python123-ops/moonground@0.45.0
```

在调用方的 `moon.pkg` 中导入根包：

```moonbit
import {
  "python123-ops/moonground",
}
```

从 `GroundCalibration` 和 `MeasurementSession` 接入像素观测，或通过 `motion` 子包接入已有米制观测。[三个观测获得速度的示例](https://github.com/python123-ops/moonground/blob/main/README.mbt.md#从三个观测获得速度)随项目测试执行；[独立消费者示例](https://github.com/python123-ops/moonground/tree/main/examples/consumer)展示 MBMOT 和 MoonDetEval 接入。

单机 CLI 可从 [v0.45.0 Releases](https://github.com/python123-ops/moonground/releases/tag/v0.45.0) 下载 Windows x86-64 或 Linux x86-64 预编译包，解压后直接运行，无需 MoonBit 或编译器。[安装与回退说明](https://github.com/python123-ops/moonground/blob/main/docs/cli-distribution.md)包含校验、可选 Python 版本管理脚本和构建来源核对方法。

## 测量条件与文档

CLI 的 `replay` 可把测量结果、完整检查点和输入位置同步保存到 SQLite，中断后用同一输入和程序继续，按提交顺序导出 NDJSON。[回放、续跑与配额设置](https://github.com/python123-ops/moonground/blob/main/docs/cli-jobs.md)包含示例。

相机需要固定，目标锚点位于标定有效域内的同一测量平面。调用方提供真实时间戳、稳定身份和显式选择的地面锚点；检测置信度不自动转换为测量噪声。库输出观测路径及其估计，实际场地的物理测量精度需要独立真值评估。

- [核心接口、时间和协方差语义](https://github.com/python123-ops/moonground/blob/main/README.mbt.md)
- [对照独立真值评估测量结果](https://github.com/python123-ops/moonground/blob/main/docs/measurement-evaluation.md)
- [点到参考线的偏移比较](https://github.com/python123-ops/moonground/blob/main/docs/calibration-line-offset.md)
- [共享标定误差与凸多边形面积比较](https://github.com/python123-ops/moonground/blob/main/docs/calibration-area.md)
- [命令行与浏览器示例](https://github.com/python123-ops/moonground/tree/main/examples)
- [数值参考和复现记录](https://github.com/python123-ops/moonground/tree/main/validation)
- [更新记录](https://github.com/python123-ops/moonground/blob/main/CHANGELOG.md)

源码和发布包使用 [Apache-2.0](https://github.com/python123-ops/moonground/blob/main/LICENSE) 许可证。
