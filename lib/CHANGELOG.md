# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-28：备份包收 SSH 两步验证

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.1 → 1.2.2 | `bk_system` 新收 `/etc/pam.d/sshd` 与 `/root/.google_authenticator`（TOTP 密钥与应急码）。原机 SSH 开了 Google 两步验证时，`sshd_config` 要求 keyboard-interactive，缺这两样在新机上重启 SSH 后就登不进去；密钥原样放回，手机上原来的验证器条目继续可用 |

## 2026-09-28：/usr/local/bin 同名文件不进包

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.0 → 1.2.1 | `bk_usr_local_bin` 跳过与 `/usr/bin`、`/bin`、`/usr/sbin`、`/sbin` 同名的文件并记进 `rootfs-skipped.txt`。`/usr/local/bin` 在 PATH 里排在前面，这类文件（如调试用的 docker 桩）放回新机会遮住真命令。只收 `*.sh` 不可行：`opsget`、`opsbox` 没有扩展名 |

## 2026-09-28：备份包公共函数

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.1.4 → 1.2.0 | 新增 `bk_*` 一组函数，供 `backup/` 下三个脚本共用：rootfs 采集与 `restore-manifest.tsv`（`bk_init`、`bk_file`、`bk_dir`、`bk_link`、`bk_opt`、`bk_system`、`bk_systemd_units`、`bk_compose_projects`），MySQL 全部账号（带密码哈希）与业务库导出（`bk_mysql_users`、`bk_mysql_dbs`），镜像 digest（`bk_images`），GFS 分级保留（`bk_gfs_select`、`bk_prune_local`、`bk_prune_remote`）。原有函数未改 |

## 2026-09-24：清理 shellcheck 警告

CI 的 shellcheck 门槛由 error 收紧到 warning。仓库根目录新增 `.shellcheckrc` 关闭 SC1090（source 的是运行时才存在的文件）。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.1.3 → 1.1.4 | `sha_write` 改用 glob 收集文件：修正文件名含空格被拆开（校验和漏记）、子目录导致报错、空目录时 sha256sum 转读 stdin 卡住三个问题。`backup_file` 的 local 声明与赋值拆开；两个输出变量标注用途 |

## 2026-09-24：版本固定

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.1.2 → 1.1.3 | 新增 `ops_base()`，按与 opsget 相同的顺序判定 ref 并给出云端地址 |

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.1.1 → 1.1.2 | 精简注释，同步库内版本常量 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `common.sh`

- **1.1.1**：server_name 里的 IP 字面量、localhost、通配符不再被当成域名 ——
  面板会给站点的 server_name 带上 127.0.0.1，它进不了 wwwroot 也申不了证书。
  这类跳过项会列出来但不计告警：它是正常配置，不该污染告警计数。
- **1.1.0**：新增 scan_vhost_domains / resolve_domains —— 手维护的域名清单会双向漂移
  （多出废域名 = 噪音，漏掉真站点 = 静默不检查），统一在这里处理

后续更新按文件记录版本、日期、改动原因和行为变化。
