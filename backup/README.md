# 生产备份

本目录提供 Vaultwarden 等服务、Xboard、new-api 与 LiteLLM 的备份脚本。备份包在本地生成并校验后上传；密码从权限受控的文件读取。脚本通过 `/etc/ops-scripts/env.conf` 获取路径、远端和告警配置。

## 脚本

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `litellm-fullbackup.sh` | 2.0.1 | 从汇总机拉取 LiteLLM 节点的库导出与工作目录，加密上传 |
| `newapi-fullbackup.sh` | 2.0.1 | 从汇总机拉取 new-api 数据，生成一致性快照并加密上传 |
| `vault-backup.sh` | 1.0.1 | 只备份 Vaultwarden（库、数据目录、配置），每小时一次 |
| `hk-host-backup.sh` | 1.1.0 | 前置机整机备份：系统、面板、全部 MySQL 账号与业务库（Xboard 等）、宝塔 PostgreSQL 的角色与库（Open WebUI 等）、Xboard 目录、Komari、SubConverter、站点，每天一次 |

## 运行与更新

定时任务调用**已安装在本机的脚本**，避免备份启动依赖 GitHub。先用 `opsget -i backup/<脚本名>` 安装新版，再手动运行并检查产物；确认正常后，现有 cron 下一次会使用本地新版。不要让 cron 直接调用 `opsget`。

- 四类包（2026-10 起）：`vault`（只有 Vaultwarden）、`hk-host`（前置机整机，不含 Vaultwarden）、`newapi`、`litellm`。**恢复前置机要 hk-host 与 vault 两个包一起**（`migrate/restore-from-backup`）；系统部分只在 hk-host 包里，不重复。
- 包名 `<包名>_YYYYMMDD_HHMMSS.7z`，时间一律 UTC（不看系统时区）；旁边配 `.sha256`，两个都上传。本机放 `<BACKUP_LOCAL_ROOT>/<包名>/`（默认 `/box/backup`），每个网盘放 `<BACKUP_CLOUD_ROOT>/<包名>/`（默认 `Backups`）。
- 加密都用 `BACKUP_PASS_FILE`（兼容旧的 `VW_PASS_FILE`），是密码文件路径。
- 日志和历史数据只收表结构、不收数据（恢复后应用照常启动，这些记录从零开始）：Xboard 的日志与统计、机器负载曲线、管理审计、流量重置记录、失败队列，vaultwarden 的 `event`，Komari 的 `logs`、`task_results`，new-api 的 `quota_data`、`audit_logs`、`perf_metrics` 与程序日志目录，LiteLLM 的花费明细与按天用量、健康检查、错误与审计日志。订单、支付、佣金、new-api 的调用明细 `logs` 照收。清单可用 `BACKUP_HISTORY_TABLES`、`NEWAPI_HISTORY_TABLES`、`LITELLM_HISTORY_TABLES` 改。
- `hk-host-backup.sh` 用 `MYSQL_DEFAULTS_FILE` 导出全部账号与业务库（Vaultwarden 的库在 vault 包，指标库只留本地），整个 Xboard 目录原样收进 rootfs（框架日志除外），Komari 用 `.backup` 取一致性副本；mysql / mysqldump 优先用宝塔自带的客户端（`/www/server/mysql/bin`，PATH 里的可能是找错 socket 的 MariaDB 客户端），连不上 MySQL 隔 30 秒重试、共 3 次，告警里带报错原文；面板程序配置、nginx 依赖、GeoLite2-City、ufw 国家屏蔽规则照收，恢复时少下载。配了 `PG_BIN_DIR` 就导宝塔 PostgreSQL：`pg_dumpall --globals-only` 导角色与密码哈希（`db/pg-globals.sql`），每个非模板库 `pg_dump -Fc`（`db/pg/<库>.dump`，导完用 `pg_restore --list` 读一遍；`postgres` 库和 `PG_SKIP_DBS` 不导），`pg_hba.conf`、`postgresql.auto.conf` 记为 `pg-conf`（恢复时等装好 PostgreSQL 才放回），`postgresql.conf` 只作参考；连不上隔 30 秒重试、共 3 次，告警带报错原文，不中断整轮。compose 用 `env_file` 引用的文件（如连接串 `db.env`）随 compose 文件一起收。
- `newapi-fullbackup.sh` 从落地机拉取数据；SQLite 用在线备份 API 生成一致性快照，避免直接复制运行中的 WAL 数据库。
- `litellm-fullbackup.sh` 从 LiteLLM 节点拉取数据：在节点上 `docker exec litellm-postgres pg_dump -U litellm -Fc litellm`（事务快照，一致且不停服；**绝不复制运行中的 `pgdata/`**），并用容器自己的 `pg_restore --list` 读一遍，读不开就整轮失败；工作目录 `LITELLM_WORKDIR` 除 `pgdata/` 与日志外全收（`.env`、`config.yaml`、`docker-compose.yml`）。SSH 端口取 `LITELLM_SSH_PORT`，没有就取 `~/.vps-hosts.txt`，再没有用 22。
- **LiteLLM 的 Redis 不备份**：`ops/deploy-litellm` 起的 Redis 只作响应缓存（`config.yaml` 的 `cache_params`），compose 里就关了持久化（`--save "" --appendonly no`），重启本来就是空的，里面没有要留的状态。
- **`LITELLM_SALT_KEY` 在 LiteLLM 包的 `workdir/.env` 里**：面板里加的模型和上游 Key 在 Postgres 里用它加密，恢复时必须用原来那一个，换了就永远解不开。包里 `RESTORE.md` 开头就讲这一点，并附盐值的指纹（sha256 前 12 位）供核对。
- 备份是否可解开，另用 `ops/verify-backup-pass.sh` 检查；完整恢复能力仍需演练。

- 各脚本都依赖公共库 `lib/common.sh` 的 `bk_*` 函数（`vault-backup`、`hk-host-backup` 要 1.4.0 起）；`opsget -i` 会一并同步，库缺失或过旧时脚本报失败并告警。
- 各脚本各自持有 `/run/lock/<脚本名>.lock`，上一轮没结束时新一轮直接退出、不报心跳。
- `vault-backup.sh` 与 `hk-host-backup.sh` 支持 `--local-only <目录>`：包（连同 `.sha256`）只写进这个目录，不上传、不做分级保留清理、不报心跳、不发告警邮件；上一轮还在跑时等它结束（最多 2 小时）而不是跳过。给 `migrate/live-migrate` 在旧机上现做包、经 SSH 直传新机用；这份包不是例行备份，不该挤掉网盘上的旧包，也不该让心跳监控以为例行备份已上云。

各脚本在头部声明 `ENV-REQUIRED`。版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 频率与分级保留

频率（UTC，由 `ops/install-backup-cron.sh` 安装，不在本目录；改频率后外部心跳监控的周期也要同步改）：

| 包 | 脚本 | 频率 | 心跳周期 |
| --- | --- | --- | --- |
| vault | `vault-backup` | 每小时 :15 | 1 小时 |
| hk-host | `hk-host-backup` | 每天 20:00 | 1 天 |
| newapi | `newapi-fullbackup` | 每 6 小时：04:30、10:30、16:30、22:30 | 6 小时 |
| litellm | `litellm-fullbackup` | 每周日 20:40 | 1 周 |
| panel | `ops/panel-backup-create` | 每周日 19:30 | 1 周 |

清理按包文件名里的时间戳（按 UTC 解释）分档，本地和每个 rclone 远端各自执行（档位见公共库 `bk_tiers`，`<包名>_KEEP_TIERS` 可改）：

| 档位 | vault / newapi | hk-host（每天一次） | litellm（每周一次） | 保留 |
| --- | --- | --- | --- | --- |
| 全留 | 3 天内 | — | — | 全部 |
| 按天 | 30 天内 | 30 天内 | — | 每天最早的一份 |
| 按周 | 90 天内 | 90 天内 | 90 天内 | 每个 ISO 周最早的一份 |
| 按月 | 本地 180 / 云端 400 天内 | 同左 | 同左 | 每月最早的一份 |

- 每档留**最早**的一份：它正是上一档留下来的那份，档位边界移动时不会今天留 A、明天换 B。
- 最新的一份无论多旧都保留；同名 `.sha256` 旁注跟随它的包；不符合命名规则的文件不动。
- 本次运行有失败（致命错误、任一远端上传或校验失败）时整轮不清理。
- 档位不合法（非整数、逐级递减）或包名日期无法解析时不清理，并记一条告警。
- 远端逐个 `rclone deletefile`，不用带过滤器的 `rclone delete`，名单外的文件碰不到。
- 档位配置见 `config/env.example.conf` 的 `<包名>_KEEP_TIERS`、`BACKUP_KEEP_LOCAL_DAYS`、`BACKUP_KEEP_CLOUD_DAYS`。
- 从旧的「按天数」清理切换过来后，第一次运行会一次删掉大量按天保留的旧包（例如 400 份每日包删到约 50 份），属预期。

## 包结构

hk-host 与 vault 的 7z 里是 `payload.tar.gz`（保留属主与权限，7z 不记属主）以及外层各一份 `manifest.txt` 和 `RESTORE.md`。解开 `payload.tar.gz` 后（2026-10 起不再带旧布局的 `app/`、`nginx/`、`system/` 副本，恢复只认 rootfs）：

| 路径 | 内容 |
| --- | --- |
| `restore-manifest.tsv` | 还原清单，`#` 开头的行是注释，其余每行 `path mode owner kind`，制表符分隔 |
| `rootfs/<绝对路径>` | 原样可以放回新机的文件与目录；父目录的权限、属主照抄原机 |
| `images.tsv` | `# container image repo_digest`，每个容器的配置镜像与 RepoDigest（本地构建的镜像为 `-`） |
| `db/mysql-users.sql` | 全部 MySQL 账号：`CREATE USER IF NOT EXISTS …` 与 `ALTER USER …`（带 `AS '<哈希>'`）、`GRANT …;`、结尾 `FLUSH PRIVILEGES;` |
| `db/<库名>.sql.gz` | 其余业务库的单库 dump（不含 `CREATE DATABASE` / `USE`）；各库字符集见 `db/databases.tsv` |
| `system/crontab.txt` | root 的 `crontab -l` |
| `system/rootfs-skipped.txt` | 没进包的路径与原因（解密密码、超过 5MB 的二进制、日志；`mysql:<库>.<表>` / `sqlite:<库文件>.<表>` 是只收表结构的历史表；hk-host 包里还记着「在 vault 包里」的 Vaultwarden） |
| `system/ref/` | 只作参考、不自动放回：fstab、hostname、hosts、apt 源与手动安装的包、已启用的单元、被 mask 的单元、IP |

`kind` 与各列含义（`mode` / `owner` 为 `-` 表示沿用归档里的值）：

| kind | path | 还原动作 |
| --- | --- | --- |
| `file` | 绝对路径，内容在 `rootfs/<path>` | 放回文件 |
| `dir` | 绝对路径，内容在 `rootfs/<path>` | 整棵替换 |
| `sqlite` | 绝对路径，内容在 `rootfs/<path>`，已是 `.backup` 一致性副本 | 停对应 compose 项目后放回，跑 `integrity_check` |
| `systemd-unit` | `/etc/systemd/system/<单元>`，内容在 `rootfs/<path>` | 放回后 `daemon-reload` 与 `enable --now`（原机上已启用的才记这一类；未启用的记 `file`） |
| `mysql-db` | 包内相对路径 `db/<库名>.sql[.gz]`，库名取自文件名 | 建库并导入 |
| `mysql-user` | 包内相对路径 `db/mysql-users.sql` | 执行 |
| `compose-project` | 项目目录的绝对路径；compose 文件另有 `file` 行 | 按 `images.tsv` 的 digest 拉镜像后启动 |
| `crontab` | 包内相对路径 `system/crontab.txt` | `crontab` 导入 |

new-api 包只新增 `images.tsv`，没有 rootfs 与还原清单（见下节「不在包里」）。

LiteLLM 包（`litellm_YYYYMMDD_HHMMSS.7z`，不套 `payload.tar.gz`）也没有 rootfs，还原照包里的 `RESTORE.md` 手动做，或先用 `ops/litellm-drill` 在备用机演练：

| 路径 | 内容 |
| --- | --- |
| `workdir/` | 原工作目录：`.env`（含 `LITELLM_SALT_KEY`、`LITELLM_MASTER_KEY`、`POSTGRES_PASSWORD`）、`config.yaml`、`docker-compose.yml`；不含 `pgdata/` 与日志 |
| `db/litellm.dump` | `pg_dump -Fc` 导出；`db/litellm.dump.sha256` 是节点上算的校验和（拉回后核对），`db/litellm.toc` 是 `pg_restore --list` 的输出，`db/row-counts.tsv` 是几张关键表的行数 |
| `images.tsv` | `litellm`、`litellm-postgres`、`litellm-redis` 的镜像与 RepoDigest |
| `system/docker-compose.pinned.yml` | 镜像换成 digest 的 compose，还原用它 |
| `system/inspect-<容器>.json`、`container-ps.txt`、`docker-version.txt`、`os-release.txt` 等 | 现场信息，只作参考 |
| `manifest.txt`、`RESTORE.md` | 清单（含盐值指纹）与自包含的还原步骤 |

## 备份覆盖范围

目标是换一台新机能还原成与原机一致；日志不收。

**进包（hk-host 包，`bk_system`；vault 包只有 Vaultwarden 的库、`data/`、`vaultwarden.env`、`compose.yaml`）**

| 类别 | 内容 | 说明 |
| --- | --- | --- |
| 工具箱 | `/etc/ops-scripts`（`env.conf`、版本固定 `ref`）、`/usr/local/lib/ops-common.sh`、`/usr/local/bin` 下 5MB 以内的文件 | 大的二进制（如 rclone）、与系统命令同名的文件（放回会遮住真命令）记进 `rootfs-skipped.txt` |
| 凭据 | `MYSQL_DEFAULTS_FILE`、`XBOARD_DB_PASS_FILE`、`/root/.config/rclone`、`/etc/msmtprc` | 包本身 AES 加密、文件名也加密 |
| SSH | `sshd_config` 与 `sshd_config.d`、主机密钥 `ssh_host_*`、`/root/.ssh`（私钥、authorized_keys、known_hosts、config）、`/root/.vps-hosts.txt`、`/root/.ssh_base.txt` | 带主机密钥：新机沿用原指纹，客户端不报主机变更；隧道与 new-api 拉取用的私钥也在里面 |
| 防火墙与系统 | `/etc/ufw`、`/etc/default/ufw`、`/etc/fail2ban`、`/etc/sysctl.conf`、`/etc/sysctl.d`、`/etc/modules-load.d`、`/etc/udev/rules.d`、`/etc/gai.conf`、`/etc/security/limits.d`、journald / timesyncd 的 `.conf.d`、`/etc/docker/daemon.json`、`/etc/cron.d`、`/etc/logrotate.d`、`/etc/my.cnf` | 覆盖 init/ 写过的系统文件 |
| systemd | `/etc/systemd/system` 下的自定义单元（非软链接）与各 `*.d` drop-in | 启用的记 `systemd-unit`；被 mask 的与模板单元的实例记在 `system/ref/` |
| nginx 与证书 | nginx 主配置目录（按 `nginx -V` 的 conf-path）、面板整个 `vhost/`（nginx、proxy、rewrite、extension、well-known、cert、ssl）、`/root/.acme.sh`、`/etc/letsencrypt` | 旧版只收 `vhost/nginx/*.conf`，反向代理、rewrite、LLM 白名单都会丢，且 `nginx -t` 过不了 |
| 面板 | 面板的 `config/`、`data/`（其中的 SQLite 库走在线备份；监控历史 `system.db` 只收表结构，漏洞扫描库 `warning/` 与 GeoLite2 国家库不收，面板会重新生成或下载）、`ssl/`、计划任务脚本目录 `PANEL_CRON_DIR`、`WWWROOT` | 站点记录、续期记录、crontab 调用的脚本体都在这里。**整体放回这条路尚未在真机验证** |
| MySQL | 全部非系统账号（带密码哈希）与授权；除跳过项外的全部业务库 | 用 `MYSQL_DEFAULTS_FILE` 的 root 凭据；没配或连不上时告警 |
| 容器 | 每个容器的镜像 digest；compose 项目的 compose 文件与 `.env` | 数据已进包的项目才记 `compose-project`（还原时自动启动）；数据没进包的告警 |
| cron | root 的 crontab | |
| 额外路径 | `EXTRA_SNAPSHOT_PATHS`、`CRITICAL_FILES` 里的每一项 | `CRITICAL_FILES` 缺了告警 |

**各脚本自己的业务数据**

- vault：vaultwarden 库（用它自己的账号导出，`event` 只导结构）、Vaultwarden `data/`（不含 icon_cache、日志）、`vaultwarden.env`、compose。账号由 hk-host 包建。
- hk-host：**整个 Xboard 目录**（含 git 检出、`.env`、compose、`.docker/.data`、主题、插件，不含 `storage/logs`），不用再 `git clone` 一个可能更新的版本；Xboard 的库随全部业务库导出；`/root/deploy`、`/etc/xboard-toolkit.conf`；komari.db（`.backup`，`logs`、`task_results` 清空）、plugin、plugin-data、auto-discovery.json、compose；SubConverter 整个目录；隧道单元随 `/etc/systemd/system` 的自定义单元进包。

**不在包里，以及原因**

| 内容 | 原因 |
| --- | --- |
| 备份解密密码（`BACKUP_PASS_FILE`、`VW_PASS_FILE`、`BACKUP_PASS_FILES` 列出的文件） | 拿到包的人同时拿到钥匙，加密就白做了。另行保管 |
| 日志（`*.log`、`*.log.N`、`/var/log`、Xboard `storage/logs`、new-api 的 `logs/`） | 按要求不收 |
| 历史数据的**内容**（日志、统计、监控曲线、花费明细类的表，清单见上文「运行与更新」） | 按要求只收表结构：恢复后应用照常启动，这些记录从零开始 |
| 备份自己的落盘目录（`*_BACKUP_DIR`、`BACKUP_DIRS`、`SNAPSHOT_ROOT` 等） | 包里套包，越滚越大 |
| metrics 库（`METRICS_DB_NAME`） | 体积大，按方案由面板在本地 dump、不上云；还原后监控历史从零开始 |
| Redis（Xboard 的、LiteLLM 的） | 纯缓存；LiteLLM 的 Redis 连持久化都关了 |
| Docker 镜像本体 | 按 `images.tsv` 的 digest 拉回，与原来逐字节一致 |
| Komari 主题 | 可在面板里重新下载，清单记在 `system/rootfs-skipped.txt` |
| 超过 5MB 的 `/usr/local/bin` 二进制 | 静态二进制（rclone 等），重装即可，不值得每天反复上传 |
| fstab、hostname、hosts、网卡与 IP、apt 源 | 带原机磁盘 UUID 或 IP，原样放回会弄坏新机；只放 `system/ref/` 作参考，挂载参数（hidepid）由 init/02 重建 |
| 时区、swap | 由 init/ 按 `TZ_EXPECTED` 与内存重建；`restore-from-backup` 恢复时把时区设成 UTC（定时任务按 UTC 写） |
| **new-api 落地机、LiteLLM 节点的系统配置**（sshd、ufw、fail2ban、docker 设置等） | `newapi-fullbackup`、`litellm-fullbackup` 只从汇总机拉各自服务的数据。系统配置尚未覆盖，换机时按 `init/` 重建 |
| 非 compose 起的容器 | 还原脚本无法自动启动，建议用 `ops/containerize-and-pin` 转成 compose。每次备份会告警 |
| 数据没进包的 compose 项目 | 只收 compose 文件，不记 `compose-project`，并告警；需要的话把数据目录加进 `EXTRA_SNAPSHOT_PATHS`，确实无状态的写进 `BACKUP_IGNORE_CONTAINERS` |

**已知限制**

- 面板 `data/` 去掉监控历史等之后通常只有几 MB；`WWWROOT` 不设体积上限，备份后看日志里的 rootfs 大小，异常变大时再决定要不要排除。
- 目录里的普通文件是运行中直接复制的；SQLite 库走在线备份，MySQL 走 `--single-transaction`，其余（如 `.docker/.data` 里的 Redis 文件）与旧版一样不保证一致。
- 模板单元（`foo@.service`）的实例、被 mask 的单元只记录、不会自动恢复。
