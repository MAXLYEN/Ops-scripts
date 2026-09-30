# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-30：按真机大演练（整套从零恢复）的发现修复

在两台临时机上按灾难恢复手册从零恢复了前置机、new-api 落地机和 LiteLLM，并把前置机到落地机的隧道串起来端到端调用成功。暴露出的问题里，下面这些在脚本侧修掉；手册侧的改动见 `docs/disaster-recovery.md`。

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.6 → 1.2.7 | 新增 `ensure_rclone`：rclone 缺失或低于 `RCLONE_MIN_VERSION`（默认 1.75.0）时，从 downloads.rclone.org 取当前版本，按同目录 `SHA256SUMS` 校验后装到 `/usr/local/bin/rclone`（`RCLONE_DL_BASE` 可换下载源，测试用）；新增 `rclone_version`、`ver_ge`。起因：备份包不收 rclone 二进制，新机从 apt 装到的是 Debian 12 的 1.60，对 OneDrive 能列目录、下载却报 `unauthenticated`，面板整机备份（只在 OneDrive）这条兜底路径因此断了；同一份授权换官方 1.75 立刻正常 |

## 2026-09-30：确认提示容忍空格、大小写与全角字符

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.5 → 1.2.6 | 新增 `is_yes`：处理退格、去掉首尾空白（含回车、全角空格）、全角转半角、不分大小写后等于 `yes` 才算同意；空输入、`y`、`yess` 仍然不算。`confirm` 改用它。起因：生产机上一次确认明明输了 yes，却被当成「取消」（多半是前后带了空格或输入法字符） |

## 2026-09-29：面板的项目类站点进包

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.4 → 1.2.5 | 新增 `bk_panel_projects`，由 `bk_system` 调用：收面板上级目录下的 `*_project`（反向代理项目 `proxy_project/sites/<站点>/<站点>.json` 等），每个不超过 5MB 才收，超过的记进 `rootfs-skipped.txt`。真机演练发现：面板把反向代理项目的记录放在这里，不收的话 nginx 照常转发，面板里却看不到、改不了这些站点 |

## 2026-09-29：面板监控历史不进包

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.3 → 1.2.4 | 新增 `bk_panel_data`：面板 `data/` 照收，但 `system.db`（监控历史）只收表结构，`warning/`（漏洞扫描库）与 `firewall/GeoLite2-Country.json` 不收，都记进 `rootfs-skipped.txt`。生产机首轮新版备份里 rootfs 291MB，其中 `system.db` 209MB、`warning/` 28MB、GeoLite2 9MB；vw 与 xboard 包各带一份（压缩后 37MB 与 31MB），每 6 小时一次、按分级保留约 70 份，会在几周内塞满 5GB 的 OneDrive |

## 2026-09-28：LiteLLM 备份用到的公共函数

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.2 → 1.2.3 | `bk_images` 可只列给定的容器（不给就和原来一样列全部），不存在的容器记 `-` 并告警；赋值失败不再让开着 `set -e` 的调用方中止。它只依赖 docker 与 `warn`，`litellm-fullbackup` 用 `declare -f` 把它送到节点上执行。新增 `vps_host_port`：按 `~/.vps-hosts.txt`（`user@host:端口`）取端口，主机整段比较、跳过注释，不会像正则匹配那样让 `1.2.3.4` 命中 `11.2.3.45`。`LITELLM_BACKUP_DIR` 算作备份落盘目录，vw / xboard 采集时不会把它收进包 |

## 2026-09-28：备份包收 SSH 两步验证

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `common.sh` | 1.2.1 → 1.2.2 | `bk_system` 新收 `/etc/pam.d/sshd` 与 `/root/.google_authenticator`（TOTP 密钥与应急码）。原机 SSH 的密码登录开了 Google 两步验证（密钥登录不需要验证码），缺这两样在新机上重启 SSH 后密码登录就过不去；密钥原样放回，手机上原来的验证器条目继续可用 |

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
