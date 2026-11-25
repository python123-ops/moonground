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

## 直接评估 SQLite 回放任务

`0.43.0` 的安装管理器可直接读取任务数据库，无需先执行 `job-export`：

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --state measurements.sqlite --references references.ndjson --requirements requirements.json --output acceptance.json
```

`--state` 与 `--measurements` 二选一。默认要求任务已经完成；需要检查已提交的部分进度时，显式加 `--allow-partial`。部分评估仍与整份参考日志做完整时间外连接，尚未产生的测量计为缺测，不会自动截短参考范围。

读取先核对数据库结构、完整性、提交计数、结果顺序和时间戳，再在同一只读事务中逐行使用原始结果。它与回放、备份共用任务锁；任务正在写入或备份时返回 2，保持原报告。日志对齐完成后释放事务和锁，再启动原生评估程序；后续任务提交不改变已经对齐的评估内容。

报告增加 `measurement_source`，记录此次读取的帧数、提交次数、完成状态、输入偏移、原输入与产出程序哈希、结果字节哈希和检查点哈希，以及实际使用的读取脚本哈希。`binary_sha256` 仍表示执行本次评估的程序，`measurement_source.binary_sha256` 表示产生这些测量的程序，两者分别保留。报告不保存本地文件路径。

`--max-state-mib` 默认 256，限制数据库逻辑页大小；`--state-timeout` 默认 60 秒，约束数据库检查和日志对齐。`--timeout` 继续约束随后进行的原生计算。只读流保留当前结果行；对齐后的原生输入仍使用临时文件，临时磁盘用量随输入增长。空任务需提供 `--session-id`，有参考而无测量时按缺测评估。

输出不得覆盖任务数据库、锁及 SQLite 日志文件，也不得覆盖其硬链接、原输入或产出程序。统计与验收继续使用 0／3／2 的退出状态。可先通过 `job-backup` 保存任务快照，再对快照单独评估并留存参考数据与门槛文件。

## 分段评估与检查点

使用 `0.44.0` Release 附带的 `moonground_cli.py`。先处理第一段日志并将检查点保存在报告中：

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --measurements part-1-measurements.ndjson --references part-1-references.ndjson --checkpoint --output part-1.json
python moonground_cli.py --prefix ./moonground-install evaluate --measurements part-2-measurements.ndjson --references part-2-references.ndjson --resume part-1.json --requirements requirements.json --output part-2.json
```

`--resume` 自动在新报告中继续保存 `resume`。输入必须是后续时间段：对齐后的每个时间戳都严格晚于上一检查点的 `last_timestamp_us`。两份日志应在同一个时间边界拆分；重叠、重复或乱序的时刻返回 2，保留已有报告。此入口接收下一段日志，不会在原文件中查找偏移或重放之前的行。

`evaluation` 和验收检查覆盖全部累计样本；`alignment_scope: "current_inputs"` 表明 `alignment` 只统计本次两份输入。新报告记录本次日志哈希及 `inputs.resume_sha256`，据此连接分段报告。检查点、各段原始测量、参考数据及报告一同保存。输出使用新路径，拒绝覆盖作为输入的恢复报告及其硬链接。

会话身份和样本容量从检查点恢复，显式重复参数时必须一致。验收门槛由本次 `--requirements` 提供，可在同一统计状态上重新选择；不提供时只生成统计报告。门槛未达到而返回 3 的报告仍包含有效检查点。只有展示统计、没有 `resume` 的旧报告不能用于接续。

`--checkpoint` 也可与 `--state` 一起使用，将已提交快照的评估结果导出为检查点。默认的部分任务评估仍包含整份参考日志的缺测；补充旧时刻的测量时应重新评估该范围。接续文件日志只接收更晚的时间；接续同一数据库使用下面的显式时间范围。

检查点保留样本数、状态计数、偏差、完整缩放平方和及精确时间水位，不保存样本历史。需要选择支持检查点的当前发行版本；选回旧版本后，原有统计和 SQLite 评估入口继续可用。原文协议、计算库与 JavaScript 接口见 [评估检查点](https://github.com/python123-ops/moonground/blob/main/docs/measurement-evaluation.md#评估检查点)。

## 随回放进度增量评估

`0.45.0` 增加 `--committed-only`。它将参考范围限定到任务最后一个已提交测量时刻，自动保存完整评估检查点和参考游标。未完成的任务仍需显式加 `--allow-partial`：

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --state measurements.sqlite --allow-partial --committed-only --references references.ndjson --output evaluation-1.json
# 继续回放同一任务后，使用新路径保存下一份报告。
python moonground_cli.py --prefix ./moonground-install evaluate --state measurements.sqlite --allow-partial --committed-only --references references.ndjson --resume evaluation-1.json --requirements requirements.json --output evaluation-2.json
```

首次调用计算水位之前的全部测量和参考记录；后续调用核对上一报告的任务身份、测量前缀和参考前缀，只将新增测量与 `(上一水位, 当前水位]` 内的参考送入原生计算器。区间内只有参考的时刻仍计为缺测，水位之后的参考暂缓计算。`evaluation`、`resume` 和验收结论覆盖累计样本，`alignment` 与输入流哈希只对应本次计算。没有新提交时，累计统计和检查点保持一致。

报告用 `state_scope: "through_committed_measurements"` 标明此范围。`measurement_source` 保存完整快照的帧数、哈希及精确 `last_timestamp_us`，另记录本次 `evaluated_frames`、`evaluated_results_sha256` 和上次快照信息。`reference_cursor` 保存已处理记录数、记录前缀哈希、时间水位、本次／暂缓记录数及整份参考文件哈希。计数和时间游标使用精确十进制字符串；记录前缀逐行保留 JSON 原文，忽略 LF／CRLF 分隔符差异。原始输入、每份参考和报告应一同保留。

可以追加尚未处理的未来参考；修改、删除或补入已经越过水位的参考会拒绝接续。测量历史变化、任务回退、输入或产出程序不一致也返回 2，并保留原有报告。通过备份／恢复得到的同一逻辑任务可以接续。旧的 `--checkpoint --state` 报告缺少参考游标，需重新生成一份 `--committed-only` 报告作为起点。此模式要求当前选中的发行版本同时带有增量评估和读取工具；回退旧版后需重新选回支持版本。

每次仍逐行检查数据库和参考历史，读取成本随历史增长；原生计算和对齐临时文件只包含新增范围。参考全文件的 JSON、时间顺序和重复字段在扫描时检查，暂缓记录的样本字段在进入计算范围时由原生程序检查。空快照暂缓全部参考，首次评估需提供会话身份。未加 `--committed-only` 的 SQLite 评估继续包含整份参考日志；文件分段接续方式保持不变。

## 保存评估任务状态

`0.46.0` 可用独立的 `--evaluation-state` 文件保存完整报告和检查点。重复运行同一命令时，自动使用最后一条已提交记录作为起点，无需手工选择上一份报告：

```sh
python moonground_cli.py --prefix ./moonground-install evaluate --state measurements.sqlite --allow-partial --committed-only --evaluation-state evaluations.sqlite --references references.ndjson --requirements requirements.json --output current-evaluation.json
python moonground_cli.py --prefix ./moonground-install evaluation-status --evaluation-state evaluations.sqlite
python moonground_cli.py --prefix ./moonground-install evaluation-export --evaluation-state evaluations.sqlite --sequence 1 --output first-evaluation.json
```

评估状态与测量回放数据库分开保存，原回放数据库格式保持不变。此入口要求 `--state --committed-only`，与 `--resume` 互斥。任务身份、历史测量和参考前缀仍按增量评估规则核对；会话身份和样本容量自动恢复，验收门槛继续由每次调用显式提供。需要选择同时支持此功能的当前程序和辅助脚本。

每次完成计算都会提交一条记录，包括验收返回 3 的情况。记录中的 `evaluation_state.sequence` 是精确十进制字符串，`parent_sha256` 与 `inputs.resume_sha256` 同时指向上一条报告的字节哈希。首次记录的父哈希为 `null`。没有新增测量时仍保存本次检查，累计样本数不增加；改变门槛可重新检查同一份累计统计。

进程在提交前中断时，继续使用上一条记录；提交后中断时，新记录已经可用。状态先提交，再写 `--output` 或标准输出；输出失败后，可用 `evaluation-status` 确认记录数，再用 `evaluation-export` 取回报告。导出逐字节保留原报告，省略 `--sequence` 时取最新记录；覆盖已有导出文件需显式加 `--replace-existing`。状态文件、其侧文件、回放输入与程序均不能作为报告的覆盖目标。

状态查询核对数据库结构、完整性、连续序号、报告哈希和父记录关系。并发调用同一评估状态时，后来的调用返回 2；原生计算期间不持有评估数据库的 SQLite 事务，提交前再次核对记录水位。输入、计算或提交失败不增加记录，原报告保留。

`--max-evaluation-mib` 默认 256，限制评估数据库大小；达到预算后可提高预算继续运行。`--evaluation-timeout` 默认 60 秒，分别约束状态检查和提交阶段，`--timeout` 仍约束原生计算。状态文件位于可写目录，便于锁定、提交和中断后的 SQLite 恢复。每次会逐条核对已有记录，内存只保留当前报告和最新检查点；存储量、检查时间随评估次数增长。单份报告上限 1 MiB。继续计算仍需保留原回放数据库和参考日志。

## 备份和恢复评估状态

`0.47.0` 增加独立的评估状态备份。安装对应版本后，使用发布包中的管理脚本：

```sh
python moonground_cli.py --prefix ./moonground-install evaluation-status --evaluation-state evaluations.sqlite
python moonground_cli.py --prefix ./moonground-install evaluation-backup --evaluation-state evaluations.sqlite --output evaluations-backup.sqlite --expected-report-sha256 <latest_sha256>
python moonground_cli.py --prefix ./moonground-install evaluation-restore --backup evaluations-backup.sqlite --sha256 <备份返回的sha256> --evaluation-state recovered-evaluations.sqlite
python moonground_cli.py --prefix ./moonground-install evaluate --state measurements.sqlite --allow-partial --committed-only --evaluation-state recovered-evaluations.sqlite --references references.ndjson --requirements requirements.json --output recovered-report.json
```

备份保存全部报告原文、父哈希和完整检查点，生成单个已关闭的 SQLite 文件；支持尚无报告、部分完成和已经完成的评估状态，也支持源数据库处于 WAL 模式。返回值包含文件 `sha256`、字节数、记录数和最新报告哈希。`--expected-report-sha256` 可省略；提供时在锁定的数据库快照内核对最新报告，水位已变化则拒绝备份。它是报告字节的哈希，恢复时的 `--sha256` 则是整个备份文件的哈希，两者用途不同。

恢复必须提供备份文件校验和，并使用新的目标路径。已有目标、遗留 SQLite 日志、错误数据库类型、损坏的历史记录或不符的校验和均返回 2。复制完成后再次检查结构、历史和数据库身份，最后发布文件；发布前中断可重试，发布后中断可查询目标状态。恢复不会修改源备份，原报告仍可按序号逐字节导出。继续评估时只计算恢复水位之后的新增测量；没有新提交时不重复累计样本。

两个命令均支持 `--max-evaluation-mib`（默认 256）和 `--evaluation-timeout`（默认 60 秒）。预算覆盖源检查、复制和发布前校验，容量限制包含已分配但尚未回收的数据库页。备份时保留返回的校验和，并另存原测量回放数据库、参考日志和验收门槛；继续原回放任务还需保留原产出程序。

评估数据库格式仍为 MGE1、版本 1，测量回放数据库格式不变。状态备份和恢复只使用经安装清单校验的辅助脚本；选回旧版后，管理器可使用保留的上一版本中支持该操作的脚本。继续原生评估仍要求当前选中的版本支持相应入口。安装及版本回退见 [CLI 分发说明](cli-distribution.md)。
