# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

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
