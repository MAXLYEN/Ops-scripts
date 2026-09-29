# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-28：只在本地出包（一键迁移用）

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.5.0 → 2.6.0 | 新增 `--local-only <目录>`：包写到该目录（该目录也不进包），不上传、不清理、不报心跳、不发告警；防重入锁改为等上一轮结束（最多 2 小时），因为调用方等着要包。不带参数时行为不变；参数写错直接退出，不出包 |
| `xboard-fullbackup.sh` | 2.4.1 → 2.5.0 | 同上 |

## 2026-09-28：xboard 包不再带指标库

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `xboard-fullbackup.sh` | 2.4.0 → 2.4.1 | 导出其余业务库时跳过 `METRICS_DB_NAME`（默认 `metrics`），与 `vw-fullbackup` 一致。2.4.0 漏了这一项，每 6 小时会把整个 Komari 指标库（生产机上约 185MB）打进包并上传两个网盘，而按方案它只留本地。 |

## 2026-09-28：整机可还原的包结构与分级保留

目标：新机按包还原后与原机一致，还原尽量自动。包结构、覆盖范围与保留规则见 [README.md](README.md)。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.4.0 → 2.5.0 | 新增 `rootfs/`、`restore-manifest.tsv`、`images.tsv`、`db/mysql-users.sql`（全部账号带密码哈希）、其余业务库 dump；系统配置补齐 SSH（含主机密钥与 root 私钥）、fail2ban、sysctl、面板整个 `vhost/`（旧版漏了 proxy、rewrite、extension、well-known）、面板 `config/` 与 `data/`、nginx 主配置、自定义 systemd 单元等。业务数据硬链接进 rootfs，包不变大。清理改为 GFS 分级保留，上传有失败时不清理。加防重入锁。 |
| `xboard-fullbackup.sh` | 2.3.3 → 2.4.0 | 同上的 rootfs、还原清单、账号与业务库、镜像 digest；整个 Xboard 目录进 rootfs；新增 crontab（旧版没收）。**包内改为先打 `payload.tar.gz` 再 7z 加密**：7z 不记属主，旧版解开后容器数据属主全变 root（RESTORE.md 里「Redis 属主修复」即因此而来）；包内路径不变，多解一层。上传失败时不清理，GFS 分级保留，防重入锁。 |
| `newapi-fullbackup.sh` | 1.0.4 → 1.1.0 | GFS 分级保留（全留 2 天，供每小时一次使用），任一远端上传失败时不清理；远端生成 `images.tsv`；防重入锁 |

## 2026-09-28：告警邮件配置与 new-api 隧道单元进每日包

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.3.8 → 2.4.0 | 包内新增 `system/msmtprc`（以 600 写入暂存区，原文件可能是 640）与 `system/systemd/<单元>`（取自 `NEWAPI_TUNNEL_UNIT`，连同 `<单元>.d/` drop-in；不按 `*tunnel*` 通配猜测）。缺 msmtprc 且配置了 `MAIL_TO`、或配置的单元文件不存在时计一条告警；未配置对应项则只记日志、不告警。`RESTORE.md` 补还原步骤：msmtprc 归位并 `chmod 600`、隧道单元 `daemon-reload && enable --now`，并提示 SSH 私钥与 host key 不在包内 |

## 2026-09-25：低风险问题清理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `newapi-fullbackup.sh` | 1.0.3 → 1.0.4 | `umask 077`：解包期间暂存区原先有几秒对其他用户可读，其中 `one-api.db` 含上游渠道 Key；成品包也改为 600。webhook 的 JSON 改为正确转义（正文含引号或换行时原先生成非法 JSON，webhook 发送失败） |
| `xboard-fullbackup.sh` | 2.3.2 → 2.3.3 | option 文件的 `password` 加双引号并转义 `\` 与 `"`（含 `#` 时原先会被当注释截断）；`ASSETS_SITE` 为空时原先会把整个 wwwroot 收进包，现改为跳过并记录 |

## 2026-09-24：备份暂存区收紧权限

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.3.7 → 2.3.8 | 开头设 `umask 077`。原先暂存目录 755、生成文件 644，备份窗口内明文数据库 dump、含环境变量密钥的 `docker inspect`、证书私钥与 `payload.tar.gz` 对本机任何用户可读（生产机备份目录整条路径均为 755，已确认可达）。现在新建目录 700、文件 600，成品 7z 也为 600。修正「env.conf 里没有密码」的注释 |

## 2026-09-24：清理 shellcheck 警告

CI 的 shellcheck 门槛由 error 收紧到 warning。仓库根目录新增 `.shellcheckrc` 关闭 SC1090（source 的是运行时才存在的文件）。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `newapi-fullbackup.sh` | 1.0.2 → 1.0.3 | 未使用的重试计数改为 `_`，执行逻辑未变 |
| `vw-fullbackup.sh` | 2.3.6 → 2.3.7 | 清单里的站点列表由 `ls | xargs basename` 改为 glob 循环，输出不变 |

## 2026-09-24：dump 校验改看解压内容

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.3.5 → 2.3.6 | 原 `[ -s x.sql.gz ]` 恒为真（gzip 压缩空输入也有 20 字节头），空 dump 会被放行。改为解压后统计 `CREATE TABLE`：为 0 则中止；末尾缺 `-- Dump completed` 标记则告警（与 `xboard-fullbackup.sh` 一致）。成功日志附带表数。先读完整个流再判断，避免 pipefail 下 `zcat \| grep -q` 的 SIGPIPE 把好 dump 判坏 |

## 2026-09-24：修正 2.3.4 数据库导出失败

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.3.4 → 2.3.5 | 2.3.4 用 `--defaults-extra-file` 传密码，但 MySQL 之后还会读 `~/.my.cnf`，其中 `[client]` 的 root 密码覆盖了 vaultwarden 的密码，mysqldump 报 `Access denied (using password: YES)`，备份中止。改用 `--defaults-file` 只读临时文件，先 `!include` 存在的 `/etc/my.cnf`、`/etc/mysql/my.cnf` 保留全局设置，password 放在最后。**2.3.4 不要使用** |

## 2026-09-24：凭据移出进程命令行

同机任何用户都能读 `/proc/*/cmdline`；面板上以 www 运行的站点被攻破后，可在任务运行窗口拿到凭据。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `vw-fullbackup.sh` | 2.3.3 → 2.3.4 | 数据库密码改写入 `mktemp` 建的 600 临时 option 文件，经 `--defaults-extra-file` 传给 mysqldump/mysql，退出时删除；7z 的 `-p` 暂未处理 |

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `newapi-fullbackup.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `vw-fullbackup.sh` | 2.3.2 → 2.3.3 | 精简注释，执行逻辑未变 |
| `xboard-fullbackup.sh` | 2.3.1 → 2.3.2 | 精简注释，执行逻辑未变 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `newapi-fullbackup.sh`

- **1.0.1**：rclone check 两边都必须是目录，原先传单个文件路径导致 "is a file not a directory" 误报失败

### `vw-fullbackup.sh`

- **2.3.1**：ENV-REQUIRED 里的密码键改写成 BACKUP_PASS_FILE|VW_PASS_FILE 二选一 ——
  脚本内部本就有回落，声明按字面写会让 opsget 把能跑的机器拦下来。
- **2.3.0**：备份加密密码改读 BACKUP_PASS_FILE，VW_PASS_FILE 作回落。原来两个备份
  脚本共用 VW_PASS_FILE，一台只跑 Xboard、根本没有 Vaultwarden 的机器
  也被要求填一个名字里带 VW 的键，报错时人会先去找 Vaultwarden 在哪。
  老机器的 env.conf 不用改。
- **2.2.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.2.0**：加反向监控心跳（dead man's switch）。正向告警盖不住「脚本压根没跑」
  —— 宕机、cron 挂掉、crontab 被面板重写，这三种情况一封邮件都不会有。
  心跳由外部观察者盯着：约定时间没收到就由它告警。
- **2.1.0**：告警发送加重试与落盘兜底 —— 实测遇到过一次瞬时 ENETUNREACH，
  单次网络抖动不该让告警丢掉（告警丢了 = 静默失效）
- **2.0.0**：环境相关的值全部外置到 /etc/ops-scripts/env.conf，**主体逻辑一行未动**。
  RESTORE.md 里的账号 host 从写死的 '%' 改为按配置生成，并补了三处提醒。

### `xboard-fullbackup.sh`

- **2.3.1**：ENV-REQUIRED 里的密码键改写成 BACKUP_PASS_FILE|VW_PASS_FILE 二选一 ——
  脚本内部本就有回落，声明按字面写会让 opsget 把能跑的机器拦下来。
- **2.3.0**：备份加密密码改读 BACKUP_PASS_FILE，VW_PASS_FILE 作回落。这台机器可能
  根本没有 Vaultwarden，却被要求填一个名字里带 VW 的键 —— 报错时人会
  先去找 Vaultwarden 在哪。老机器的 env.conf 不用改。
- **2.2.2**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.2.1**：XBOARD_SITES 留空时改为**自动扫描 vhost 目录**收集全部站点与证书。
  写死列表的毛病是：每次在面板增删域名都要记得同步改配置，
  忘了就报假警（或更糟——静默漏备份一个站）。
- **2.2.0**：加反向监控心跳（同 vw-fullbackup）
- **2.1.0**：告警发送加重试与落盘兜底（同 vw-fullbackup，实测遇到过瞬时 ENETUNREACH）
- **2.0.1**：vhost 改为按 server_name 反查，不再假设文件名等于域名
  （实测漏了一个站点的 vhost —— 面板给它的文件名带了前缀）
- **2.0.0**：环境相关的值全部外置到 /etc/ops-scripts/env.conf，**主体逻辑一行未动**。
  RESTORE.md 里的域名与 host 段改为按配置生成；补 sleep 10 再校验；
  7z 自检加 </dev/null（-mhe=on 的包缺密码会交互式等输入）。

后续更新按文件记录版本、日期、改动原因和行为变化。
