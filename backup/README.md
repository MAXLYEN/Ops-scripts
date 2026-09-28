# 生产备份

本目录提供 Vaultwarden 等服务、Xboard 与 new-api 的备份脚本。备份包在本地生成并校验后上传；密码从权限受控的文件读取。脚本通过 `/etc/ops-scripts/env.conf` 获取路径、远端和告警配置。

## 脚本

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `newapi-fullbackup.sh` | 1.1.0 | 从汇总机拉取 new-api 数据，生成一致性快照并加密上传 |
| `vw-fullbackup.sh` | 2.5.0 | 备份 Vaultwarden、Komari、SubConverter 与系统配置 |
| `xboard-fullbackup.sh` | 2.4.0 | 生成 Xboard 加密备份包并上传云端 |

## 运行与更新

定时任务调用**已安装在本机的脚本**，避免备份启动依赖 GitHub。先用 `opsget -i backup/<脚本名>` 安装新版，再手动运行并检查产物；确认正常后，现有 cron 下一次会使用本地新版。不要让 cron 直接调用 `opsget`。

- `vw-fullbackup.sh` 与 `xboard-fullbackup.sh` 使用 `BACKUP_PASS_FILE`，兼容旧的 `VW_PASS_FILE`；两者都是密码文件路径。
- `newapi-fullbackup.sh` 从落地机拉取数据；SQLite 用在线备份 API 生成一致性快照，避免直接复制运行中的 WAL 数据库。
- 备份是否可解开，另用 `ops/verify-backup-pass.sh` 检查；完整恢复能力仍需演练。

- 三个脚本都依赖公共库 `lib/common.sh` 1.2.0 起的 `bk_*` 函数；`opsget -i` 会一并同步，库缺失或过旧时脚本报失败并告警。
- 三个脚本各自持有 `/run/lock/<脚本名>.lock`，上一轮没结束时新一轮直接退出、不报心跳。

各脚本在头部声明 `ENV-REQUIRED`。版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 频率与分级保留

目标频率：`vw-fullbackup` 与 `xboard-fullbackup` 每 6 小时一次，`newapi-fullbackup` 每小时一次。cron 由 `ops/install-backup-cron.sh` 安装（不在本目录）；改频率后，外部心跳监控的周期也要同步改。

清理按包文件名里的时间戳（`<前缀>_YYYYMMDD_HHMMSS.7z`，按 UTC 解释）分档，本地和每个 rclone 远端各自执行：

| 档位 | vw / xboard | new-api | 保留 |
| --- | --- | --- | --- |
| 全留 | 7 天内 | 2 天内 | 全部 |
| 按天 | 30 天内 | 30 天内 | 每天最早的一份 |
| 按周 | 90 天内 | 90 天内 | 每个 ISO 周最早的一份 |
| 按月 | 本地 180 / 云端 400 天内 | 同左 | 每月最早的一份 |

- 每档留**最早**的一份：它正是上一档留下来的那份，档位边界移动时不会今天留 A、明天换 B。
- 最新的一份无论多旧都保留；同名 `.sha256` 旁注跟随它的包；不符合命名规则的文件不动。
- 本次运行有失败（致命错误、任一远端上传或校验失败）时整轮不清理。
- 档位不合法（非整数、逐级递减）或包名日期无法解析时不清理，并记一条告警。
- 远端逐个 `rclone deletefile`，不用带过滤器的 `rclone delete`，名单外的文件碰不到。
- 档位配置见 `config/env.example.conf` 的 `BACKUP_KEEP_*` 与 `NEWAPI_KEEP_ALL_DAYS`、`NEWAPI_*_KEEP_DAYS`。
- 从旧的「按天数」清理切换过来后，第一次运行会一次删掉大量按天保留的旧包（例如 400 份每日包删到约 50 份），属预期。

## 包结构

vw 与 xboard 的 7z 里是 `payload.tar.gz`（保留属主与权限，7z 不记属主）以及外层各一份 `MANIFEST.txt` / `manifest.txt` 和 `RESTORE.md`。解开 `payload.tar.gz` 后，旧版的目录（`db/`、`vaultwarden/`、`komari/`、`app/`、`nginx/`、`system/` 等）原样都在，另有：

| 路径 | 内容 |
| --- | --- |
| `restore-manifest.tsv` | 还原清单，`#` 开头的行是注释，其余每行 `path mode owner kind`，制表符分隔 |
| `rootfs/<绝对路径>` | 原样可以放回新机的文件与目录；父目录的权限、属主照抄原机 |
| `images.tsv` | `# container image repo_digest`，每个容器的配置镜像与 RepoDigest（本地构建的镜像为 `-`） |
| `db/mysql-users.sql` | 全部 MySQL 账号：`CREATE USER IF NOT EXISTS …` 与 `ALTER USER …`（带 `AS '<哈希>'`）、`GRANT …;`、结尾 `FLUSH PRIVILEGES;` |
| `db/<库名>.sql.gz` | 其余业务库的单库 dump（不含 `CREATE DATABASE` / `USE`）；各库字符集见 `db/databases.tsv` |
| `system/crontab.txt` | root 的 `crontab -l` |
| `system/rootfs-skipped.txt` | 没进包的路径与原因（解密密码、超过 5MB 的二进制等） |
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

## 备份覆盖范围

目标是换一台新机能还原成与原机一致；日志不收。

**进包（vw 与 xboard 共用，`bk_system`）**

| 类别 | 内容 | 说明 |
| --- | --- | --- |
| 工具箱 | `/etc/ops-scripts`（`env.conf`、版本固定 `ref`）、`/usr/local/lib/ops-common.sh`、`/usr/local/bin` 下 5MB 以内的文件 | 大的二进制（如 rclone）、与系统命令同名的文件（放回会遮住真命令）记进 `rootfs-skipped.txt` |
| 凭据 | `MYSQL_DEFAULTS_FILE`、`XBOARD_DB_PASS_FILE`、`/root/.config/rclone`、`/etc/msmtprc` | 包本身 AES 加密、文件名也加密 |
| SSH | `sshd_config` 与 `sshd_config.d`、主机密钥 `ssh_host_*`、`/root/.ssh`（私钥、authorized_keys、known_hosts、config）、`/root/.vps-hosts.txt`、`/root/.ssh_base.txt` | 带主机密钥：新机沿用原指纹，客户端不报主机变更；隧道与 new-api 拉取用的私钥也在里面 |
| 防火墙与系统 | `/etc/ufw`、`/etc/default/ufw`、`/etc/fail2ban`、`/etc/sysctl.conf`、`/etc/sysctl.d`、`/etc/modules-load.d`、`/etc/udev/rules.d`、`/etc/gai.conf`、`/etc/security/limits.d`、journald / timesyncd 的 `.conf.d`、`/etc/docker/daemon.json`、`/etc/cron.d`、`/etc/logrotate.d`、`/etc/my.cnf` | 覆盖 init/ 写过的系统文件 |
| systemd | `/etc/systemd/system` 下的自定义单元（非软链接）与各 `*.d` drop-in | 启用的记 `systemd-unit`；被 mask 的与模板单元的实例记在 `system/ref/` |
| nginx 与证书 | nginx 主配置目录（按 `nginx -V` 的 conf-path）、面板整个 `vhost/`（nginx、proxy、rewrite、extension、well-known、cert、ssl）、`/root/.acme.sh`、`/etc/letsencrypt` | 旧版只收 `vhost/nginx/*.conf`，反向代理、rewrite、LLM 白名单都会丢，且 `nginx -t` 过不了 |
| 面板 | 面板的 `config/`、`data/`（其中的 SQLite 库走在线备份）、`ssl/`、计划任务脚本目录 `PANEL_CRON_DIR`、`WWWROOT` | 站点记录、续期记录、crontab 调用的脚本体都在这里。**整体放回这条路尚未在真机验证** |
| MySQL | 全部非系统账号（带密码哈希）与授权；除跳过项外的全部业务库 | 用 `MYSQL_DEFAULTS_FILE` 的 root 凭据；没配或连不上时告警 |
| 容器 | 每个容器的镜像 digest；compose 项目的 compose 文件与 `.env` | 数据已进包的项目才记 `compose-project`（还原时自动启动）；数据没进包的告警 |
| cron | root 的 crontab | |
| 额外路径 | `EXTRA_SNAPSHOT_PATHS`、`CRITICAL_FILES` 里的每一项 | `CRITICAL_FILES` 缺了告警 |

**各脚本自己的业务数据**

- vw：vaultwarden 库（自己的账号导出）、Vaultwarden `data/`（不含 icon_cache）、`vaultwarden.env`、compose；komari.db（`.backup`）、plugin、plugin-data、auto-discovery.json、compose；SubConverter 整个目录；new-api 隧道单元（旧位置 `system/systemd/`）。
- xboard：xboard 库；**整个 Xboard 目录**（含 git 检出、`.env`、compose、`.docker/.data`、主题、插件，不含 `storage/logs`），不用再 `git clone` 一个可能更新的版本；`/root/deploy`、`/etc/xboard-toolkit.conf`。

**不在包里，以及原因**

| 内容 | 原因 |
| --- | --- |
| 备份解密密码（`BACKUP_PASS_FILE`、`VW_PASS_FILE`、`BACKUP_PASS_FILES` 列出的文件） | 拿到包的人同时拿到钥匙，加密就白做了。另行保管 |
| 日志（`*.log`、`*.log.N`、`/var/log`、Xboard `storage/logs`） | 按要求不收 |
| 备份自己的落盘目录（`*_BACKUP_DIR`、`BACKUP_DIRS`、`SNAPSHOT_ROOT` 等） | 包里套包，越滚越大 |
| metrics 库（`METRICS_DB_NAME`） | 体积大，按方案由面板在本地 dump、不上云；还原后监控历史从零开始 |
| Redis | 纯缓存 |
| Docker 镜像本体 | 按 `images.tsv` 的 digest 拉回，与原来逐字节一致 |
| Komari 主题 | 可在面板里重新下载，清单在 `komari/theme-list.txt` |
| 超过 5MB 的 `/usr/local/bin` 二进制 | 静态二进制（rclone 等），重装即可；每 6 小时一份时不值得反复上传 |
| fstab、hostname、hosts、网卡与 IP、apt 源 | 带原机磁盘 UUID 或 IP，原样放回会弄坏新机；只放 `system/ref/` 作参考，挂载参数（hidepid）由 init/02 重建 |
| 时区、swap | 由 init/ 按 `TZ_EXPECTED` 与内存重建 |
| **new-api 落地机的系统配置**（sshd、ufw、fail2ban、docker 设置等）与 **LiteLLM**（Postgres 数据、compose、`.env`） | `newapi-fullbackup` 只从汇总机拉 new-api 的数据目录。尚未覆盖，需要另行补上 |
| 非 compose 起的容器 | 还原脚本无法自动启动；启动参数见 vw 包的 `system/docker/run-commands.sh`，建议用 `ops/containerize-and-pin` 转成 compose。每次备份会告警 |
| 数据没进包的 compose 项目 | 只收 compose 文件，不记 `compose-project`，并告警；需要的话把数据目录加进 `EXTRA_SNAPSHOT_PATHS`，确实无状态的写进 `BACKUP_IGNORE_CONTAINERS` |

**已知限制**

- 面板 `data/` 与 `WWWROOT` 不设体积上限，首轮备份后看 `manifest.txt` 里的 rootfs 大小再决定要不要排除。
- 目录里的普通文件是运行中直接复制的；SQLite 库走在线备份，MySQL 走 `--single-transaction`，其余（如 `.docker/.data` 里的 Redis 文件）与旧版一样不保证一致。
- 模板单元（`foo@.service`）的实例、被 mask 的单元只记录、不会自动恢复。
