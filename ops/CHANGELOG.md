# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-30：SSH 放行名单改成菜单

改名单原来要手工编辑 `~/.vps-hosts.txt` 或 `env.conf` 再 `--apply`，然后另开窗口测试、再 `--confirm`。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `ssh-allowlist.sh` | 1.1.1 → 1.1.2 | 「新窗口能登录吗」改用公共库的 `is_yes`（`lib/common.sh` 1.2.6）：前后空格、大小写、全角字符不再让 yes 被当成回滚；「写进配置并执行？」走的 `confirm` 同样受益 |
| `ssh-allowlist.sh` | 1.1.0 → 1.1.1 | 生产机上试用时，客户端开新连接把运行菜单的窗口顶掉了：没人回答 yes，5 分钟的定时回滚只回滚了防火墙，`env.conf` 里留着新加的 IP。现在把这次顺带改过的配置（`env.conf`、`~/.vps-hosts.txt`）的备份记进待确认记录，定时回滚与 `--rollback` 连配置一起改回；提示里说明另开独立会话测试（别在同一标签页里重新连接），窗口断了就在新窗口里 `--confirm` |
| `ssh-allowlist.sh` | 1.0.0 → 1.1.0 | 在终端里直接运行进菜单：带编号列出名单，[1] 新增（规范后写进 `ADMIN_IPS`；已在名单里、认不出、比 /8 宽的拒绝）、[2] 按编号删除（从 `ADMIN_IPS`、`ALLOW_EXTRA_IPS`、`~/.vps-hosts.txt` 里一并去掉，各留 `.bak`；机群里的机器提示其他脚本也读这份清单，`ALLOW_EXTRA_IPS` 里的提示同步 LLM 白名单；不能删当前会话的来源）、[3] 只看改动。先按改后的配置算出防火墙变化给你看，确认后才写配置并执行；执行后当场问新窗口能不能登录，`yes` 保留并取消定时回滚，输别的或 270 秒内不输就回滚防火墙、这次改的配置一并改回（5 分钟的定时回滚照旧兜底，只回滚防火墙）。命令行等价写法 `--add` / `--remove`；没有终端时不带参数等于 `--preview` |

## 2026-09-30：前置机 SSH 放行名单

约定是每台机器用 ufw 只放行本地出口、前置机和各节点机连 SSH，真机演练时发现前置机的 SSH 端口一直是 `LIMIT IN Anywhere`，没有名单。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `ssh-allowlist.sh` | 新增 → 1.0.0 | 名单 = `~/.vps-hosts.txt` 里的机器 + `ADMIN_IPS` + `ALLOW_EXTRA_IPS`（去重，可写网段，比 /8 宽的与认不出的跳过并告警）；按 `sshd -T` 与当前会话的端口加 `ufw allow from <IP> to any port <端口> proto tcp comment 'ssh-allowlist'`，全部加上后才删不限来源的 allow / limit 规则（有一条没加上就不删）；只增删自己打注释的规则，名单变了再跑一次即同步。默认预演；`--apply` 先备份 `user.rules` / `user6.rules`、`systemd-run --on-active=300` 布置自动回滚，`--confirm` 取消、`--rollback` 立即回滚；当前会话来源不在名单里时拒绝执行 |

## 2026-09-29：面板整机备份自动化

面板整机备份（「设置 → 备份还原」）原来只能在面板里手动点，再用 `panel-backup-upload` 手动上传。真机演练时它派上了用场：面板的反向代理项目记录不在每日包里（已由 `lib/common.sh` 1.2.5 补上），当时靠手动上传的整机备份把面板里的记录找了回来。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `panel-backup-create.sh` | 新增 → 1.0.0 | 复制面板最近一次备份的任务配置、换新时间戳写回 `backup_task.json`（时间戳与已有的不重），前台运行面板自带的 `btpython backup_manager.py backup_data <时间戳>`（最长 4 小时）；出了包且 `gzip -t` 通过才算成功，面板报告有失败项时照样上传但单独告警；本机按时间戳只留最近 `PANEL_BACKUP_KEEP` 份；调用 `panel-backup-upload --file <包> --prune <份数>` 加密上传、清理云端。开始前检查面板备份程序、任务配置、`backup.pl`（面板正在备份）与磁盘余量（上一份包的 3 倍，至少 1GB）；失败时告警（邮件 → webhook → 落盘）、心跳 `/fail` |
| `install-backup-cron.sh` | 1.2.0 → 1.3.0 | 时间表加 `panel-backup-create`，每周日 UTC 19:30（北京周一 03:30）：18 点那批 6 小时备份已跑完，下一次整点的 newapi 还没到，是国内用户最少的时段 |

## 2026-09-29：备份定时任务别丢配置、别互相挤掉

生产机上预演时发现：原 crontab 里 xboard 那行带着 `MAIL_TO=...`（它的告警单独发到另一个邮箱），vw / xboard / newapi 三行共用 `/var/lock/fullbackup.lock` 并用 `flock -w 3600` 排队。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `install-backup-cron.sh` | 1.1.0 → 1.2.0 | 旧行命令前的 `名字=值` 环境变量照留到新行（1.1.0 会丢掉，告警就改发到 `env.conf` 的 `MAIL_TO`）。几个备份脚本原来共用一把外层锁时不再沿用，各用 `/var/lock/<名>-cron.lock`：新行是 `flock -n`（撞上就跳过），共用一把时每小时的 newapi 撞上还在上传的 vw 就整轮跳过、心跳缺一次；各脚本自己都有防重入锁，外层分开是安全的 |

## 2026-09-28：LiteLLM 备份的定时、校验与演练

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `install-backup-cron.sh` | 1.0.0 → 1.1.0 | 时间表新增 `litellm-fullbackup`，每 6 小时 :40（与 vw :00、xboard :20 错开；newapi 仍是每小时 :05） |
| `verify-backup-pass.sh` | 2.1.0 → 2.2.0 | 本机装了哪个备份脚本（vw / xboard / newapi / litellm），它的云端目录（`VW_REMOTE_PATH`、`XBOARD_REMOTE_PATH`、`NEWAPI_CLOUD_DIR`、`LITELLM_CLOUD_DIR`，后两个有默认值）不在 `RCLONE_PATHS` 里时自动并入本次校验，并在输出与汇总里提示补配置。原先新增备份脚本后忘了改 `RCLONE_PATHS`，那个目录就永远没人校验，也不报错 |
| `litellm-drill.sh` | 新增 → 1.0.0 | 在备用机上演练 LiteLLM 包的恢复：`restore` 取网盘最新包或本地包，核对 sha256、导出与盐值（`.env` 没有盐值、盐值指纹与清单不符、compose 没锁 digest 都拒绝），按 `RESTORE.md` 的顺序恢复到 `/opt/litellm-drill` 并等健康检查；`verify` 与线上比行数（只读）、带 master key 列模型（key 经 stdin 给 curl）、查日志里的解密错误；`teardown` 只删带演练标记的目录，目标机原本没有 docker 就卸载。拒绝 `LITELLM_HOST`、`NEWAPI_HOST` 与本机；目标机已有 litellm 容器、生产工作目录、上次没清的演练目录或端口被占也拒绝 |

## 2026-09-28：备份定时任务安装器

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `install-backup-cron.sh` | 新增 → 1.0.0 | vw / xboard 每 6 小时（:00 / :20）、newapi 每小时（:05）；只排本机已装的；外层 `flock -n` 锁用 `/var/lock/<名>-cron.lock` 并沿用原有行的锁，但不用备份脚本自己的 `/run/lock/<名>.lock`（同一把会让脚本一启动就退出）；输出进 `-cron.log`；补 `PATH=`；替换原有行（含 `opsget backup/…` 写法），日志路径里的同名不误伤；不带参数只预演，`--apply` 写入并备份原 crontab |

## 2026-09-25：卸载清理与保留配置

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `cleanup-purge.sh` | 1.0.6 → 1.0.7 | 一并清掉 `opsget` / `opsbox` 自身更新留下的旧版备份（没有 `.sh` 后缀，原先漏掉）；`KEEP_ENV=1` 只保留 `env.conf` 与版本固定记录 `ref`（`ref` 删了，下次重装会悄悄跟 main 走），`env.conf` 的历史备份等照删；结尾的重装提示按是否保留配置区分 |

## 2026-09-25：补全配置声明

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `komari-metrics-check.sh` | 2.0.1 → 2.0.2 | 声明 `ENV-REQUIRED: MYSQL_DEFAULTS_FILE`：`mysql_ready` 需要它，原先漏声明，opsget 预检与菜单都当它不缺配置，执行后才报错。执行逻辑未变 |

## 2026-09-25：中文菜单

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `cleanup-purge.sh` | 1.0.5 → 1.0.6 | 没有安装台账时也移除 `/usr/local/bin/opsbox`（有台账时它经 `opsget -u` 安装、本来就在台账里） |

## 2026-09-25：云端备份每周校验

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `verify-backup-pass.sh` | 2.0.2 → 2.1.0 | 新增 `--cron`：失败时按「邮件 → webhook → 落盘」告警，可选心跳 `VERIFY_HEARTBEAT_URL`；最新包超过 `VERIFY_MAX_AGE_DAYS` 天即告警（发现备份悄悄停止上传）；按修改时间而非文件名取最新包；超过 `VERIFY_MAX_MB` 的包跳过并注明；末尾输出汇总。cron 安装方法见 README |

## 2026-09-25：复查修正

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `bind-localhost.sh` | 2.1.0 → 2.1.1 | 被拒绝重建、由 compose 管理的容器计入告警：循环原在管道子 shell 里，计数丢失，总报 0 告警 |
| `panel-cron-inspect.sh` | 2.0.4 → 2.0.5 | 「脚本文件不存在」计入告警：同上，循环由管道改为进程替换 |

## 2026-09-25：低风险问题清理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `diag-key.sh` | 1.0.2 → 1.1.0 | 新增 `-p`：密码从终端静默读取或取 `SSHPASS`；旧的第二参数写法仍兼容，但会提示 |
| `push-keys.sh` | 1.0.3 → 1.0.4 | 诊断提示改为 `diag-key -p` |
| `newapi-linkcheck.sh` | 1.0.2 → 1.0.3 | webhook 的 JSON 正确转义 |
| `newapi-drill.sh` | 1.0.3 → 1.0.4 | 状态文件的值用 `printf %q` 写入：teardown 时会 `source` 它，而 `IMAGE` 取自备份包内容 |
| `panel-cron-inspect.sh` | 2.0.3 → 2.0.4 | `--run` 只接受 32 位十六进制 hash，拒绝 `../` 等路径 |
| `cleanup-tidy.sh` | 1.1.1 → 1.1.2 | 第 7 节改为只列出容器数据目录里的 `.bak.<时间戳>`：原先想按份数删，却总被保护名单拦下，从未生效；这些往往是数据库改动前的唯一副本，改为交给人判断 |
| `cleanup-purge.sh` | 1.0.4 → 1.0.5 | 同一路径只列一次（`ops-common.sh` 原先会重复显示） |

## 2026-09-24：bind-localhost 安全重建

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `bind-localhost.sh` | 2.0.1 → 2.1.0 | 每轮在 `rebind/<时间戳>/` 独立生成，`--apply` 只执行本轮的（原先会连上一轮残留的脚本一起执行，把升级过的容器按旧配置重建）。生成前检查重建命令复现不了的配置：匿名卷或 `--mount` 卷（重建会换成空卷）、cap、设备、资源限制、日志驱动、多网络、固定 IP、自定义 entrypoint/user/workdir 等，有则拒绝生成并说明原因。重建不再 `docker rm -f`：旧容器关闭自动重启后改名保留，新容器起不来时自动改回原名并启动。`on-failure` 的重试次数一并保留 |

## 2026-09-24：中风险问题修复

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `save-fw.sh` | 2.0.1 → 2.0.2 | 修正 ufw 恢复命令：原命令给已带 `ufw` 前缀的行再加前缀，reset 后规则全部加不回去，防火墙停在关闭状态。现分三步，确认 SSH 端口在规则里才重新启用；另存 `ufw status verbose` 以保留默认策略 |
| `panel-backup-upload.sh` | 1.0.4 → 1.0.5 | `--prune` 原先按文件名排序删掉云端目录里除最新 N 个外的所有文件，多机共用目录时会删掉其他服务器的备份。改为只清理本机台账里、校验通过的包；校验 `--prune` 参数为整数 |
| `sync-llm-allowlist.sh` | 2.0.3 → 2.0.4 | sshd jail 端口原写死 59967，改从 `sshd -T` 与当前连接读取；`jail.local` 里有本脚本不管理的 jail 时中止，不再整文件覆盖掉它们 |
| `cleanup-purge.sh` | 1.0.3 → 1.0.4 | 原先会删除台账里的备份脚本，却声称不删，cron 随后静默失效。现默认保留 crontab 在用的脚本、`BACKUP_SCRIPTS` 及其依赖的 `env.conf` 与 `ops-common.sh`；`PURGE_CRON_SCRIPTS=1` 才一并删除 |

## 2026-09-24：快照权限与 WAL 保护

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `apply-newapi-quota-fix.sh` | 1.2.1 → 1.2.2 | 停容器后先在落地机执行 `PRAGMA wal_checkpoint(TRUNCATE)`，确认 WAL 为空才拉库；删除 `-wal` 前再次确认为空。原先只拉主文件、随后删除 `-wal`，WAL 中已提交的事务会永久丢失 |

## 2026-09-24：清理 shellcheck 警告

CI 的 shellcheck 门槛由 error 收紧到 warning。仓库根目录新增 `.shellcheckrc` 关闭 SC1090（source 的是运行时才存在的文件）。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `cleanup-purge.sh` | 1.0.2 → 1.0.3 | 待删清单直接传 glob，不再 `$(ls ...)` 分词；文件名含空格时不再拆散 |
| `check-llm-security.sh` | 1.0.2 → 1.0.3 | vhost 列表改用 glob 循环，输出不变 |
| `mail-doctor.sh` | 1.0.2 → 1.0.3 | msmtp 的 TLS 参数改用数组传递，参数不变 |
| `newapi-drill.sh` | 1.0.2 → 1.0.3 | 可选的 `data-rest` 改用位置参数传给 tar；找不到端口的提示写出实际路径 |
| `panel-data-locate.sh` | 2.0.1 → 2.0.2 | 删除结果未被使用的逐表 `COUNT(*)` 查询，少跑一半 sqlite 查询 |
| `compare-backup-content.sh` | 1.0.4 → 1.0.5 | local 声明与赋值拆开，执行逻辑未变 |
| `deploy-litellm.sh` | 1.2.3 → 1.2.4 | 未使用的循环计数改为 `_`，执行逻辑未变 |
| `newapi-linkcheck.sh` | 1.0.1 → 1.0.2 | 未使用的重试计数改为 `_`，执行逻辑未变 |
| `panel-backup-upload.sh` | 1.0.3 → 1.0.4 | 删除未使用的 `FAILED`（告警由 `finish` 统计），执行逻辑未变 |
| `push-keys.sh` | 1.0.2 → 1.0.3 | 删除未使用的 `PUBKEY`，执行逻辑未变 |

## 2026-09-24：版本固定

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `script-inventory.sh` | 1.0.1 → 1.0.2 | 云端地址改用 `ops_base()`：固定了版本的机器按固定的 ref 比对，不再全部误报与 main 不一致 |
| `cleanup-purge.sh` | 1.0.1 → 1.0.2 | 云端地址改用 `ops_base()`，在清理前算好，重装提示沿用本机原先的 ref |

## 2026-09-24：凭据移出进程命令行

同机任何用户都能读 `/proc/*/cmdline`；面板上以 www 运行的站点被攻破后，可在任务运行窗口拿到凭据。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `deploy-litellm.sh` | 1.2.2 → 1.2.3 | 验收请求的 master key 改经 ssh 的 stdin 传给远端 `curl -H @-`，不再出现在本机 ssh 与远端 curl 的命令行 |
| `newapi-log-prune.sh` | 1.0.2 → 1.0.3 | 访问令牌改经 stdin 传给 `curl -H @-`；需要 curl ≥ 7.55 |
| `setup-key-login.sh` | 1.0.1 → 1.0.2 | 密码参数改为可选：省略时终端静默输入，非交互时取环境变量 `SSHPASS`；原三参数写法仍兼容 |
| `diag-key.sh` | 1.0.1 → 1.0.2 | 修复提示改为省略密码参数的 `setup-key-login` 用法，执行逻辑未变 |
| `push-keys.sh` | 1.0.1 → 1.0.2 | 同上，执行逻辑未变 |

## 2026-09-24：修正短凭据掩码输出

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `deploy-litellm.sh` | 1.2.1 → 1.2.2 | `mask()` 处理 8 位及以下凭据时，printf 格式符多于参数，长度显示为 0，分隔空格也被替换成 `*`；改为先生成星号串再输出 |

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `apply-newapi-quota-fix.sh` | 1.2.0 → 1.2.1 | 精简注释，执行逻辑未变 |
| `bind-localhost.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `check-llm-security.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `cleanup-purge.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `cleanup-tidy.sh` | 1.1.0 → 1.1.1 | 精简注释，执行逻辑未变 |
| `compare-backup-content.sh` | 1.0.3 → 1.0.4 | 精简注释，执行逻辑未变 |
| `containerize-and-pin.sh` | 1.1.0 → 1.1.1 | 精简注释，执行逻辑未变 |
| `decommission-archive.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `deploy-litellm.sh` | 1.2.0 → 1.2.1 | 精简注释，执行逻辑未变 |
| `diag-key.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `fix-newapi-fallback-quota.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `fix-newapi-quota-data.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `komari-metrics-check.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `mail-doctor.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `newapi-drill.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `newapi-linkcheck.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `newapi-log-prune.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `panel-backup-upload.sh` | 1.0.2 → 1.0.3 | 精简注释，执行逻辑未变 |
| `panel-cron-inspect.sh` | 2.0.2 → 2.0.3 | 精简注释，执行逻辑未变 |
| `panel-data-locate.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `preflight-backup.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `push-keys.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `restore-cron.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `save-fw.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `script-inventory.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `setup-key-login.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `ssl-audit.sh` | 2.1.1 → 2.1.2 | 精简注释，执行逻辑未变 |
| `sync-llm-allowlist.sh` | 2.0.2 → 2.0.3 | 精简注释，执行逻辑未变 |
| `upgrade-vaultwarden.sh` | 1.2.0 → 1.2.1 | 精简注释并修正帮助输出 |
| `verify-backup-pass.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `apply-newapi-quota-fix.sh`

- **1.2.0**：落地机地址、端口、数据目录、容器名改从 env.conf 读 —— 原来写死在脚本里，
  而本仓库公开托管，等于把落地机 IP 与 SSH 端口一起推了上去。
  ssh 用户沿用 backup/newapi-fullbackup 的约定，固定 root@，不另设键。
- **1.1.0**：第 3 步补上 quota_data 的重算 —— logs 与 users 改了之后，看板读的是
  按小时预聚合的 quota_data，不跟着改就会一直显示旧的虚高金额。

### `check-llm-security.sh`

- **1.0.1**：第 2 项的 find 补上 *block* —— 原来只匹配文件名含 allow/deny 的，
  blocklist.conf 两个词都不占，内容打不出来，等于漏看了真正生效的封禁配置。

### `cleanup-tidy.sh`

- **1.1.0**：① 只列出真正会被删的类别。原来「共 2，保留最新 2」这种行照样打印，
  看着像要清理、实际删 0 个 —— 一眼分不出该不该跑 --apply。
  无需清理的类别折叠成末尾一行。
  ② 汇总打印可回收数量与体积。TOTAL 一直在累加却从没输出过，
  预演最该回答的问题（能腾出多少）反而看不到。
  ③ 新增 vpsscore 采集产物一节：collect.sh 每跑一次就新增一批
  JSON 与 route.txt，原来完全不在扫描范围，只能手工清。

### `compare-backup-content.sh`

- **1.0.3**：结尾那句「只有体积差、清单一致 = 等价」原本无条件打印，有差异时会和
  上面的差异列表一起出现，同屏两个相反结论，看的人容易被后一句带偏。
  改为按清单是否有差异分别给结论。
- **1.0.2**：差异判定不再把 diff 放进 if 的管道 —— lib/common.sh 设了 pipefail，
  管道退出码取最右边的非零值，而 diff 在「有差异」时返回 1（这是它的正常
  结果，不是错误），于是有差异反而走 else，打印「文件清单完全一致」。
  结论方向正好是反的，最危险。改为先把差异落成文件，按文件是否为空判定。
- **1.0.1**：① 密码键跟上 backup/*.sh 2.3.x：BACKUP_PASS_FILE 优先，VW_PASS_FILE 回落。
  原来只认 VW_PASS_FILE，旧键一旦清掉就会掉到 BACKUP_PASS_FILES（复数，
  是另一个键——密码文件**列表**）取第一项，多半是别的密码文件，
  于是报「解包失败」，人会以为是备份包坏了，而不是脚本取错了密码。
  ② 补 -h/--help；原来给任何非法参数都只吐一行 die，看不到用法。

### `containerize-and-pin.sh`

- **1.1.0**：三个服务目录与两个自检域名改从 env.conf 读 —— 原来写死，而本仓库公开托管。

### `decommission-archive.sh`

- **2.0.0**：**重写为自包含**，不再依赖 lib/common.sh 与 env.conf。
  理由和 init/ 一样：这个脚本的使用场景就是「机器即将退役」，
  不该假设它装了什么。缺配置就自动探测，探不到就跳过并说明。

### `deploy-litellm.sh`

- **1.2.0**：目标机 IP、工作目录、端口改从 env.conf 读 —— 原来写在头部常量区，
  而本仓库公开托管；操作说明里的 new-api 地址也改成按 env 打印。
  PG_VERSION / REDIS_VERSION 是技术选型，仍留在脚本内。
- **1.1.0**：凭据改由面板添加：不再询问上游 Key，config.yaml 不再写 model_list

### `komari-metrics-check.sh`

- **2.0.0**：不再交互式输入用户名密码（会出现在 shell 历史与终端里），
  改用 --defaults-file 读凭据；库名与预期保留期从 env.conf 取

### `mail-doctor.sh`

- **1.0.1**：失败计数把 exitcode=EX_OK 也算进去了，导致"1 成功 1 失败"被报成"2 次失败"

### `newapi-drill.sh`

- **1.0.1**：状态文件的值加引号（含空格的时间戳 source 时被当成命令）；脱敏改为按值判断，
  原先按 key 名匹配会把 false/true/5 这类布尔与短数字也打码，看着像有值其实没有

### `newapi-log-prune.sh`

- **1.0.1**：终止状态补 succeeded —— 接口实际返回的就是这个词，原来只判
  completed/success/finished，任务早已成功却一直轮询到 300 秒超时。

### `panel-backup-upload.sh`

- **1.0.2**：上传那行原本写成 if rclone copy ...; then :; fi —— 两个分支都不做事，
  退出码被丢弃，这个 if 写了等于没写。判据本就是下面的 rclone check，
  直接调用即可，少一层会让人误以为这里在判成功与否的壳。
- **1.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `panel-cron-inspect.sh`

- **2.0.2**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.0.1**：修正"没有日志文件"的措辞 —— 手动触发不会产生日志，日志重定向写在 crontab 行里

### `panel-data-locate.sh`

- **2.0.0**：特征串与面板路径改为参数/配置驱动，不再写死域名

### `preflight-backup.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `restore-cron.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `ssl-audit.sh`

- **2.1.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.1.0**：原头注释未写明改动原因。
  · 第 5 节的域名来源改用 resolve_domains() —— 原来直接 for dom in $DOMAINS，
  配置漂移时既会对废域名误报，也会静默漏掉没列进配置的真站点
  · 通配符证书覆盖的域名跳过 HTTP-01 目录检查。通配符签发只能走 DNS-01，
  对它检查 .well-known 目录必然误报
- **2.0.1**：结论按实际检测结果分支（原来无条件打印"不会续期"）；
  站点根目录改为从 vhost 配置里查，兼容多域名共用一个站点的情况

### `sync-llm-allowlist.sh`

- **2.0.2**：401 过滤规则里补注释，说明为何不能匹配 [日期]（便于日后改动时不踩回去）。
- **2.0.1**：① IP 提取不再用 tr 删空白 —— tr 会把换行一并删掉，整份清单粘成一行且末尾
  无换行，while read 直接返回非零，循环一次都不执行，机群 IP 静默为 0。
  ② failregex 不再匹配 [日期]：fail2ban 匹配前会把识别到的时间戳从行里摘除，
  方括号变空，[^\]]+ 必然失配，结果是 0 matched。

### `upgrade-vaultwarden.sh`

- **1.2.0**：compose 路径与备份目录改从 env.conf 读 —— 原来写死，而本仓库公开托管。
  GH_REPO / IMAGE_REPO 是上游项目标识、BAK 是脚本自己的工作目录，仍留在脚本内。

### `verify-backup-pass.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

后续更新按文件记录版本、日期、改动原因和行为变化。
