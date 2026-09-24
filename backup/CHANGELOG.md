# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

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
