# ops-scripts 协作约定

## 测试环境

开发机是 Windows，脚本跑在 Linux。测试一律在 WSL 的 Debian 里以 root 执行：

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d Debian -u root --cd /mnt/d/Projects/Github/Ops-scripts --exec bash tests/run.sh
```

- 必须用 `--exec`。`wsl.exe -- <命令>` 会先经过一层 shell，`$?`、`$var` 在进 Linux 之前就被展开成空值，输出看起来正常但全是错的
- `MSYS_NO_PATHCONV=1` 防止 Git Bash 把 `/mnt/...` 改写成 Windows 路径
- 临时命令写成脚本文件再 `--exec bash <文件>`，不要在命令行里叠多层引号
- WSL 里已装 shellcheck、bats、docker；端到端测试在 `tests/Dockerfile` 的一次性 Debian 12 容器里跑，不会弄脏 WSL

`tests/run.sh [--lint | --e2e] [用例名过滤]`：
- **静态检查** `tests/lint.sh`：换行符、语法、shellcheck、VERSION 头、MANIFEST、opsbox 菜单归类、ENV-REQUIRED 键。CI 的 lint 任务跑的就是它
- **端到端** `tests/*.bats`：本地起 HTTP 服务模拟仓库（`main` = 当前工作区，含未提交改动），跑 opsget 的安装、固定版本、配置预检，以及 opsbox 每个菜单、确认步骤和联动。被调用的运维脚本换成记录调用的桩（`stub` / `local_stub`），断言调用顺序。交互用 `tests/drive.py` 在伪终端里逐行送入按键

## 完成的标准

- 改了脚本就跑 `tests/run.sh`，全部通过才能说完成。汇报时贴汇总结果；失败就如实说哪项、为什么
- 改 `bin/opsget`、`bin/opsbox` 或新增菜单功能、联动流程：在 `tests/opsget.bats` / `tests/opsbox.bats` 补用例。新用例先确认它会失败（临时注入对应的 bug），再确认修好后通过
- 测不到的要说清楚：桩只证明「菜单按正确顺序、带正确参数调用了脚本」，不证明运维脚本本身在真实服务上的行为。需要 systemd、ufw、sshd、宝塔面板、网盘、真实容器的部分，没有真机验证就明说没验证

## 绝不在测试里做的事

- 不连生产机，不用生产配置。生产机固定在验证过的 tag 上，发版流程见 README「固定版本」
- 不在 WSL 本体里直接执行 `init/`、`ops/` 的改动类脚本；需要时进容器，或用专门的一次性测试机

## 仓库约定

- 每个脚本头部 `# VERSION:` 加一行版本说明；改动同步所在目录的 README 版本表和 CHANGELOG
- 需要配置的脚本声明 `# ENV-REQUIRED:`，键必须在 `config/env.example.conf` 里
- 新增脚本：加进 `MANIFEST`，并在 `bin/opsbox` 登记进菜单或写 `# MENU-EXCLUDE:` 说明原因（lint 会检查）
- cron 只调用本地已安装脚本，不调用 `opsget`
