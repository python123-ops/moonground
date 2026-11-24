# 测量日志评估与验收

`0.42.0` 的发行包附带日志对齐工具。使用新版 `moonground_cli.py` 安装后，可直接评估已有测量和独立参考日志：

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --measurements measurements.ndjson --references references.ndjson --output evaluation.json
```

测量文件来自原生 `--stream` 或任务 `job-export`。参考文件每行提供精确时间戳和已经对应的目标身份：

```json
{"timestamp_us":"400000","samples":[{"track_id":1,"position_m":[0,0],"speed_mps":0}]}
```

两份日志按完整时间外连接；缺测计入可用率分母。位置使用米，速度使用米／秒；只有 `ready` 速度且有显式速度参考时才进入速度误差统计。未知速度省略 `speed_mps`。坐标系、时间同步、身份映射及独立参考测量方法需与现场数据一同保存。

需要自动验收时，通过 `--requirements requirements.json` 提供门槛。以下配置用于仓库合成示例，现场门槛由实际场景确定：

```json
{
  "position_m": {"min_samples":3,"min_coverage":0.75,"max_rmse":0.25,"max_error":0.25},
  "speed_mps": {"min_samples":1,"min_coverage":0.25,"max_mae":0.05}
}
```

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --measurements measurements.ndjson --references references.ndjson --requirements requirements.json --output acceptance.json
```

每个选中量都必须设置正整数 `min_samples`、`[0,1]` 内的 `min_coverage`，以及至少一项误差上限：`max_mae`、`max_rmse`、`max_error`。未启用的上限直接省略。位置与速度可单独选用，空配置拒绝。样本量和可用率采用包含等号的下界，误差采用包含等号的上界；无可评分样本时误差为 `null`，对应检查失败。

通过时退出 0；门槛未达到时仍写入完整报告并退出 3；输入、执行或保存出错时退出 2，保留已有输出。报告的 `acceptance` 列出全部检查的实际值、门槛、比较方向和结果，`evaluation` 保留原有误差、偏差、可用率与状态计数。报告记录两份输入、原生程序、适配脚本及门槛文件的 SHA-256。

输出与输入、门槛、适配脚本及执行程序分开保存；管理器还会拒绝把报告写入已安装版本目录、版本选择文件或安装锁。用户自己的报告可保存在安装目录的其他位置。

原生入口 `moonground --accept-measurements` 接收配置首行及逐行 `{measurement,reference}`，在 EOF 输出一份报告。配置中的 `requirements` 使用上述对象格式；其余字段为 `session_id`、可选的 `max_tracks`、`max_samples`。文件工具按原始数字文本传递门槛，支持排版后的 JSON，文件上限 64 KiB。

也可直接运行发行包中的 `python evaluate_measurements.py --binary ./bin/moonground ...`；Windows 程序名为 `moonground.exe`。恢复旧版本后，可通过已校验的新版辅助脚本运行旧程序已有的统计评估；使用验收门槛时需选择带验收功能的程序版本。

库与协议说明：[测量评估](https://github.com/python123-ops/moonground/blob/main/docs/measurement-evaluation.md)。计算检查使用仓库合成与独立数值参考；现场精度验收使用独立实测数据。
