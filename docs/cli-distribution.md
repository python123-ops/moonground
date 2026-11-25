# 单机 CLI 二进制安装与回退

发行包分别面向 Windows x86-64 和 Linux x86-64。原生程序直接解压后运行，无需 MoonBit、编译器或 Node.js。可选的版本管理脚本使用 Python 3.8 及以上版本。

完整发行包、`SHA256SUMS` 和独立的 `moonground_cli.py` 从本仓库 [Releases](https://github.com/python123-ops/moonground/releases) 获取。版本信息由 `moonground --version` 或 `moonground --version-json` 输出。

## 安装与运行

在保存管理脚本的目录中执行，`--prefix` 为本机用户可写的安装目录：

```sh
python moonground_cli.py --prefix ./moonground-install install --version 0.46.0
python moonground_cli.py --prefix ./moonground-install status
python moonground_cli.py --prefix ./moonground-install run -- --version
python moonground_cli.py --prefix ./moonground-install run -- --stream < observations.ndjson
```

离线安装使用已下载的平台 ZIP 和 `SHA256SUMS` 中对应的 SHA-256：

```sh
python moonground_cli.py --prefix ./moonground-install install --archive moonground-cli-0.46.0-linux-x86_64.zip --sha256 <64位校验值>
```

Windows 使用名称含 `windows-x86_64` 的 ZIP。`path` 子命令输出当前原生程序的完整路径，也可据此直接启动程序。`run` 将标准输入、输出、错误交给原生进程，并保留其退出码；管理脚本不累积测量结果。安装器不修改全局 PATH 或系统目录。

`0.42.0` 起的 ZIP 增加日志评估脚本与 `CLI_EVALUATION.md`，可通过 `evaluate` 对齐测量和参考日志，并应用显式验收门槛。安装这一版时使用同一 Release 提供的新版管理脚本；新版安装器同时支持旧版的 7、9 文件包和新版 11 文件包，原有升级、回退及内容校验规则继续适用。

## 升级和回退

安装另一个版本即完成升级。新版本先解包到独立目录，检查包及全部文件的哈希、目标架构、运行库条件和实际程序版本，最后原子切换 `current.json`。旧程序文件保持原位，已经启动的进程继续使用原版本。

```sh
python moonground_cli.py --prefix ./moonground-install rollback
python moonground_cli.py --prefix ./moonground-install status
```

回退重新校验上一版本文件并试运行，再交换当前与上一版本。首装没有上一版本时返回错误。相同版本、相同内容的安装是幂等操作；同一版本槽出现不同构建时拒绝覆盖。

切换前的校验、运行或选择文件写入失败时保留原选择。中断可能留下未被选择的完整版本目录，重试时会重新校验；临时解包目录单独清理。安装和回退由操作系统文件锁串行化，进程退出后自动释放锁。此流程切换程序版本，业务日志和检查点继续由调用方保存。

安装目录使用以下浅层布局：

```text
moonground-install/
  current.json
  .install.lock
  versions/
    0.46.0-linux-x86_64/
      manifest.json
      bin/moonground
      moonground_cli.py
      moonground_jobs.py
      CLI_JOBS.md
      evaluate_measurements.py
      CLI_EVALUATION.md
      LICENSE
      THIRD_PARTY_NOTICES.md
      THIRD_PARTY_LICENSES.txt
      CLI_README.md
```

## 构建与来源

`replay`、`job-status` 和 `job-export` 提供可恢复的测量文件回放，详见[任务回放说明](https://github.com/python123-ops/moonground/blob/main/docs/cli-jobs.md)。新版管理脚本也能验证及选回 `0.39.0` 的旧包；回放新任务需要选择附带回放工具的版本。

发布构建固定 MoonBit `0.10.18+6c83a7f62`，Windows 使用 Server 2022 构建机，Linux 使用 Ubuntu 22.04 构建机。Linux 发行构建要求 glibc 符号基线不高于 2.35；实际系统库名称记录在每包的 `manifest.json`。Windows 包检查静态导入 DLL，拒绝未打包的非系统运行库。

MoonBit 构建使用 `--release --strip`；Linux 产物还执行 `strip --strip-all _build/native/release/build/cmd/main/main.exe` 清理 ELF 符号及调试信息。打包前继续检查可执行文件中是否包含源码检出目录，残留路径会阻止打包。

清单记录完整源码提交、工具链、各文件大小及哈希。主分支 CI 在上述平台构建并验证安装、升级和回退，对测试过的 ZIP 生成构建来源证明。发布流程等待同一提交的 CI 完成，下载这两份现成的受测包，核对哈希及来源后发布。可使用 `gh attestation verify <发行包.zip> --repo python123-ops/moonground --signer-workflow python123-ops/moonground/.github/workflows/ci.yml` 核对来源。

发行包随附项目的 Apache-2.0 许可证及编译依赖的署名、标准库与原生运行库第三方许可文本。

Linux 包还在干净的 Ubuntu 22.04 容器内安装和回放测量输入，该环境安装 Python 3 和 libssl3，不含 MoonBit、C 编译器或 Node.js。其镜像标识和回放结果随 CI 保存。

维护者在同一提交的主分支 CI 通过后，运行 Actions 中的 `Publish MoonGround CLI`，填写 `moon.mod` 中的版本。流程保留已有标签及已发布文件；标签指向其他提交或同名资产内容不同时停止发布。每个 Release 附 `verification-<平台>.json`，对应实际发布包的哈希。

发布默认使用本次工作流提交。修复发布脚本后补发已测试的版本时，可在 `source_commit` 填写原受测提交的完整 SHA；流程核对该提交的主分支 CI、清单和验证脚本哈希，直接提取原 ZIP。发行包的来源证明对应受测源码提交，发布清单和管理脚本的来源证明对应执行发布的工作流提交。已有草稿通过登录后的发行列表定位，再补齐缺少的文件。

验证使用两个真实编译的 CLI 候选版本，比较版本切换前后的测量协议和检查点结果，并覆盖正在运行的旧进程、错误包、损坏文件、选择文件写入失败及并发操作。测试候选只用于验证，不作为公开发行版本。
