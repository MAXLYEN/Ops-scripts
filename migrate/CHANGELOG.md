# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-28：LiteLLM 包的去向

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `restore-from-backup.sh` | 1.0.0 → 1.0.1 | `litellm_*` 包明确拒绝，指明正式恢复照包里的 `RESTORE.md` 在 LiteLLM 节点上做、演练用 `ops/litellm-drill`（原先会报「认不出的包布局」） |

## 2026-09-28：从备份包恢复整机

原机已经没了时，只有 `03` 冷快照能用的 `07` / `09` 无从下手；new-api 有 `ops/newapi-drill`，Vaultwarden 等服务与 Xboard 的每日加密包却没有对应的恢复与演练脚本。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `restore-from-backup.sh` | 新增 → 1.0.0 | `check` / `restore` / `status` / `teardown`。取本地包或网盘最新包，解密并核对 sha256、清单校验和、dump 完整性；按包还原 `env.conf` 缺的键、库与账号（容器账号用 `DB_CLIENT_HOST`，备份脚本用的回环账号照建；系统账号与无关账号不碰）、数据目录、compose（镜像按 RepoDigest / 清单版本锁定，锁不住不启动）、SQLite（`integrity_check`）、站点配置与证书、systemd 单元、定时任务（并入原机的，再按统一时间表重排备份），然后起容器、`nginx -t` 后重载、本机预演访问；DNS、面板站点记录、证书重签列为手动步骤并写明原因。本机已有数据时拒绝，`--force` 才覆盖并留 `.bak.<时间>`；状态文件支持重跑；`--drill` 演练（不装定时任务、不启用单元）与 `teardown` 清理。同时认现有包布局与 `rootfs/` + `restore-manifest.tsv` 新布局；新布局里业务数据算冲突，系统配置留 `.bak` 后替换，工具箱与凭据保留本机的，`/root/.ssh` 并回恢复前的公钥，root 在正式恢复的最后改成原机的并换用原机的凭据文件 |

## 2026-09-25：补全配置声明

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `03-pre-migrate.sh` | 2.0.3 → 2.0.4 | 声明 `ENV-REQUIRED: MYSQL_DEFAULTS_FILE`：`mysql_ready` 需要它，原先漏声明，opsget 预检与菜单都当它不缺配置，执行后才报错。执行逻辑未变 |
| `04-verify-migration.sh` | 2.0.2 → 2.0.3 | 声明 `ENV-REQUIRED: MYSQL_DEFAULTS_FILE`：`mysql_ready` 需要它，原先漏声明，opsget 预检与菜单都当它不缺配置，执行后才报错。执行逻辑未变 |
| `05-fix-db-grants.sh` | 2.0.2 → 2.0.3 | 声明 `ENV-REQUIRED: MYSQL_DEFAULTS_FILE`：`mysql_ready` 需要它，原先漏声明，opsget 预检与菜单都当它不缺配置，执行后才报错。执行逻辑未变 |
| `08-post-start-check.sh` | 2.1.1 → 2.1.2 | 声明 `ENV-REQUIRED: MYSQL_DEFAULTS_FILE`：`mysql_ready` 需要它，原先漏声明，opsget 预检与菜单都当它不缺配置，执行后才报错。执行逻辑未变 |

## 2026-09-24：快照权限与 WAL 保护

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `03-pre-migrate.sh` | 2.0.2 → 2.0.3 | 设 `umask 077`：快照目录 700、文件 600。原先全部库的明文 dump 与含备份密码文件、MySQL root 凭据、rclone token 的 `files.tar.gz` 为 755/644，快照留存期间本机任何用户可读。临时用户列表由 `/tmp/.ops_users.$$` 改为 `mktemp` |

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `01-inventory.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `02-nat-probe.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `03-pre-migrate.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `04-verify-migration.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `05-fix-db-grants.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `06-export-images.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `07-restore-containers.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `08-post-start-check.sh` | 2.1.0 → 2.1.1 | 精简注释，执行逻辑未变 |
| `09-restore-backup-stack.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `02-nat-probe.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `03-pre-migrate.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `04-verify-migration.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `05-fix-db-grants.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `07-restore-containers.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `08-post-start-check.sh`

- **2.1.0**：第 3 节的域名来源改用 resolve_domains()。原来直接遍历 DOMAINS ——
  配置漏了哪个站点，那个站点就不会被探测，而输出仍然全绿。
  切换前的最后一道验收出这种假绿，代价太大。

后续更新按文件记录版本、日期、改动原因和行为变化。
