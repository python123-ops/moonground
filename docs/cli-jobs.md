# 可恢复的文件回放

`0.40.0` 起，发行包附带 SQLite 回放工具。结果行、完整测量检查点和输入字节位置在同一事务中提交。停止后再次运行相同命令，会从最后一次完整提交续跑。

```sh
python moonground_cli.py --prefix ./moonground-install replay --input observations.ndjson --state measurements.sqlite
python moonground_cli.py --prefix ./moonground-install job-status --state measurements.sqlite
python moonground_cli.py --prefix ./moonground-install job-export --state measurements.sqlite --output measurements.ndjson
```

工具使用 Python 3.8 及以上版本和标准库 `sqlite3`。也可直接运行发行包中的 `python moonground_jobs.py run --binary ./bin/moonground --input observations.ndjson --state measurements.sqlite`；Windows 的程序名为 `moonground.exe`。该入口的 `status` 和 `export` 子命令可独立读取任务数据库。

输入是固定的 UTF-8 NDJSON 文件，首行为测量配置或原有测量恢复头，后续为像素或米制观测帧。工具在启动时流式计算完整输入哈希，并绑定所选原生程序的哈希；输入或程序改变时拒绝接续。需要升级程序时，先完成当前任务，或选回原程序继续；新任务使用新的数据库。

默认每批最多 128 帧、4 MiB 输入，单行上限 16 MiB。`--batch-frames` 和 `--batch-bytes` 可调；一条合法大帧可单独成批。`--max-frames 1000` 表示本次最多处理 1000 帧后保存进度退出，再次运行可继续。每批只启动一个原生进程，使用上一批的完整恢复头，避免重放整个历史。

原生 `--stream-checkpoint` 在输出测量行后，于成功 EOF 输出一行 `{"resume":<完整检查点>}`。输入错误时返回状态 2，不输出最终恢复头。回放工具只有在原生进程成功退出、结果数量和末尾恢复头均完整时才提交该批；故障批次的部分结果不进入已提交结果。

任务默认限制数据库逻辑页为 256 MiB，通过 `--max-state-mib` 调整。数据库配额耗尽时保留上一次提交；增加配额后可用同一命令续跑。临时批次、原生输出与 SQLite 回滚日志还需要额外磁盘空间。每批原生进程默认超时 60 秒，通过 `--timeout-seconds` 调整；超时会终止该批进程并保留已提交进度。

任务文件旁的 `.lock` 使用操作系统文件锁，防止两个回放同时写入；进程退出后锁自动释放。SQLite 使用 DELETE 回滚日志；`0.41.0` 起使用 EXTRA 同步级别，在 FULL 的基础上增加删除回滚日志后的目录同步。中断日志由 SQLite 在重新打开时恢复。导出读取一份已提交快照，建议暂停或完成回放后导出，避免长时间导出阻塞写入。

导出按原顺序逐行写临时文件，再同步并替换目标文件，保留原生数值文本。目标已存在时需显式增加 `--replace-existing`；数据库、锁、回滚日志以及与原输入或程序哈希相同的文件会被拒绝作为覆盖目标。SQLite 数据库保存全部已提交结果，内存不随历史结果行数累积。

## 备份与恢复

`0.41.0` 增加完整性检查、单文件快照和恢复。暂停或完成回放后执行：

```sh
python moonground_cli.py --prefix ./moonground-install job-verify --state measurements.sqlite
python moonground_cli.py --prefix ./moonground-install job-backup --state measurements.sqlite --output measurements-backup.sqlite
```

备份输出 JSON 包含快照 `sha256`、字节数、结果与检查点摘要，以及已提交帧数、输入偏移和原输入／程序哈希。保存这份输出，将快照与原输入、对应版本程序一起留存。恢复时填写备份报告中的 SHA-256：

```sh
python moonground_cli.py --prefix ./moonground-install job-restore --backup measurements-backup.sqlite --sha256 <备份的SHA256> --state recovered.sqlite
python moonground_cli.py --prefix ./moonground-install replay --input observations.ndjson --state recovered.sqlite
python moonground_cli.py --prefix ./moonground-install job-export --state recovered.sqlite --output recovered.ndjson
```

快照保留数据库结构版本 1、原始结果字节和完整检查点；部分任务恢复后从原偏移继续，完成任务恢复后再次回放保持幂等。检查包含 SQLite `integrity_check`、表结构、提交计数与结果行的对应关系、严格递增的时间戳及 JSON 格式。它核对存储一致性；测量精度使用独立参考数据验收。

备份使用 SQLite Backup API，将一致快照写入同目录临时文件，校验并同步后以硬链接发布到新路径。Windows NTFS 与 Linux 的本地文件系统已纳入安装测试。备份与恢复均拒绝覆盖已有文件、拒绝目标旁的已有 SQLite 日志；恢复还拒绝带外部日志的快照。源任务或快照正在被回放时，操作返回状态 2。SHA-256 不匹配、结构不支持或复制失败时保留原任务；成功发布前强制终止可能留下 `.moonground-snapshot-*` 暂存文件，重试请选择尚未存在的目标路径。

三个入口均接受 `--max-state-mib`（默认 256）和 `--timeout-seconds`（默认 60）。同目录暂存快照需要一份完整数据库的额外空间。恢复始终写入新任务路径，原损坏文件留作排查。独立脚本的对应命令为 `moonground_jobs.py verify`、`backup`、`restore`，参数相同；无需安装目录或原生程序即可检查、备份和恢复，继续计算时仍需原输入和哈希一致的原生程序。

## 版本与运行验证

数据库结构版本 1 可由 `0.40.0` 与 `0.41.0` 的回放工具读取；升级不会重写已有测量结果。未来结构版本会通过 `PRAGMA user_version` 区分，当前工具遇到不支持的版本会停止。程序回退切换可执行文件，任务继续按原程序哈希绑定；保存旧版本后可继续旧任务，新程序另建任务。恢复工具会优先使用当前安装中支持所需操作的已校验脚本，必要时使用上一版本槽中的脚本。

持续作业检查入口：

```sh
python validation/cli_job_soak.py --binary _build/native/release/build/cmd/main/main.exe --run-dir _build/sqlite-24h --seconds 86400
```

默认每个活动帧 10 个目标、限速 10 帧／秒、每个固定文件 1,024 帧。每 32 个观测帧显式移除目标并更换身份；每个任务在中点备份、恢复到新库后继续，完成后逐字节核对原生单次结果。脚本轮换并删除已核对的任务文件，保留当前任务，工作文件预算默认 256 MiB。因此这项检查覆盖持续文件作业和反复恢复；单个大型数据库的容量边界另行测定。

`run-dir` 必须为空；`result.json` 每五秒更新实际时长、已提交帧数、恢复次数、内存、磁盘峰值和最后进度。短时 CI 使用相同入口运行 30 秒。只有真实运行达到所需时长、结果匹配、完成恢复循环且资源检查通过，才写入 `passed`；捕获到中断或错误时写入 `interrupted` 或 `failed`。强杀验证进程或整机重启可能留下最后一份 `running` 报告，应结合更新时间和进程状态判断。Windows 上脚本请求系统保持运行，屏幕可以关闭；采样间隔超过 60 秒会判定持续运行中断。整机断电及现场测量精度尚需各自的验收记录。

实现依据：[SQLite Backup API](https://www.sqlite.org/backup.html)、[同步级别](https://www.sqlite.org/pragma.html#pragma_synchronous)。

## 将任务直接用于精度验收

`0.43.0` 起，安装后的 `evaluate --state measurements.sqlite --references references.ndjson` 可直接评估已提交结果，并可通过 `--requirements requirements.json` 应用位置、速度、样本量和可用率门槛。默认只读取已完成任务；检查部分进度需显式使用 `--allow-partial`。报告保留此次提交范围和原结果哈希，随后接续任务不会改变已经生成的报告。完整命令、读取预算及部分进度语义见 [日志评估与验收](https://github.com/python123-ops/moonground/blob/main/docs/cli-evaluation.md#直接评估-sqlite-回放任务)。
