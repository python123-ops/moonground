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

任务文件旁的 `.lock` 使用操作系统文件锁，防止两个回放同时写入；进程退出后锁自动释放。SQLite 使用 DELETE 回滚日志和 FULL 同步级别，中断日志由 SQLite 在重新打开时恢复。备份数据库前应停止回放。导出读取一份已提交快照，建议暂停或完成回放后导出，避免长时间导出阻塞写入。

导出按原顺序逐行写临时文件，再同步并替换目标文件，保留原生数值文本。目标已存在时需显式增加 `--replace-existing`；数据库、锁、回滚日志以及与原输入或程序哈希相同的文件会被拒绝作为覆盖目标。SQLite 数据库保存全部已提交结果，内存不随历史结果行数累积。
