# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-25：/proc hidepid

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `env.example.conf` | 1.7.0 → 1.8.0 | 新增 `PROC_HIDEPID` |

## 2026-09-25：云端备份每周校验

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `env.example.conf` | 1.6.0 → 1.7.0 | 新增 `VERIFY_HEARTBEAT_URL`、`VERIFY_MAX_AGE_DAYS`、`VERIFY_MAX_MB` |

## 2026-09-24：fail2ban 封禁白名单

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `env.example.conf` | 1.5.1 → 1.6.0 | 新增 `ADMIN_IPS`（fail2ban 永不封禁的固定出口）；补上 init/03 早已读取、模板里却缺失的 `SSH_IDLE_TIMEOUT` |

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `env.example.conf` | 1.5.0 → 1.5.1 | 配置键与默认值未变 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `env.example.conf`

- **1.5.0**：补 LITELLM_HOST / LITELLM_WORKDIR / LITELLM_PORT 与 KOMARI_SITE /
  SUBCONV_SITE —— ops/deploy-litellm 与 ops/containerize-and-pin 本轮
  把写死的目标机、服务目录、自检域名全部外置，这些是它们要读的键。
- **1.4.0**：补全 NEWAPI_* 区块 —— backup/newapi-fullbackup、ops/newapi-linkcheck、
  ops/newapi-drill 三个脚本早已依赖这些键，模板里却一个都没有，按模板配
  新机器时这三个脚本直接报缺配置。同时新增日志清理用的两个键。
- **1.3.0**：新增 LITELLM_SITE / NEWAPI_SITE / ALLOW_EXTRA_IPS —— ops/sync-llm-allowlist
  用，站点名与固定 IP 不写进脚本（脚本要公开托管）。
- **1.2.0**：新增 BACKUP_PASS_FILE —— 原来两个备份脚本共用 VW_PASS_FILE，一台只跑
  Xboard、根本没有 Vaultwarden 的机器会被要求填一个名字里带 VW 的键，
  报错时人会先去找 Vaultwarden 在哪。VW_PASS_FILE 保留作回落，老机器不用改。
- **1.1.0**：DOMAINS 支持留空自动扫描 vhost（与 XBOARD_SITES 同一套约定）

后续更新按文件记录版本、日期、改动原因和行为变化。
