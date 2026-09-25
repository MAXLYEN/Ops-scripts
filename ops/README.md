# 日常运维

本目录包含巡检、部署、修复、清理与演练脚本。每支脚本的执行条件与版本号见头注释；需要配置的脚本保留 `ENV-REQUIRED` 声明，`opsget -e ops/<脚本名>` 可查看缺失的配置项。

## 检查与诊断

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `check-llm-security.sh` | 1.0.3 | 只读盘点 LiteLLM 与 new-api 的访问控制 |
| `compare-backup-content.sh` | 1.0.5 | 比对两个加密备份包的内容清单 |
| `diag-key.sh` | 1.0.2 | 诊断指定主机的 SSH 密钥登录失败原因 |
| `komari-metrics-check.sh` | 2.0.1 | 检查 Komari 指标库的保留期与增长速度 |
| `mail-doctor.sh` | 1.0.3 | 诊断告警邮件的配置与发送链路 |
| `panel-cron-inspect.sh` | 2.0.3 | 查看面板计划任务的真实命令与运行状态 |
| `panel-data-locate.sh` | 2.0.2 | 定位面板数据在磁盘上的存储位置 |
| `preflight-backup.sh` | 2.0.2 | 检查备份脚本运行前的依赖与配置 |
| `save-fw.sh` | 2.0.1 | 在修改防火墙前保存当前配置快照 |
| `script-inventory.sh` | 1.0.2 | 盘点本机脚本并区分仓库来源与本地文件 |
| `ssl-audit.sh` | 2.1.2 | 核对证书文件、站点引用与续期记录 |
| `verify-backup-pass.sh` | 2.0.2 | 验证本地密码能否解开云端备份包 |

## 部署与日常维护

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `bind-localhost.sh` | 2.0.1 | 将容器端口映射从公网绑定改为本机绑定 |
| `containerize-and-pin.sh` | 1.1.1 | 把服务改为 compose 管理并锁定镜像 digest |
| `decommission-archive.sh` | 2.0.1 | 在机器退役前归档最终状态与数据 |
| `deploy-litellm.sh` | 1.2.4 | 部署 LiteLLM、Postgres 与 Redis 容器 |
| `panel-backup-upload.sh` | 1.0.4 | 加密并上传面板生成的整机备份包 |
| `push-keys.sh` | 1.0.3 | 按主机清单批量下发 SSH 公钥 |
| `restore-cron.sh` | 2.0.2 | 从快照恢复仓库管理的 cron 任务 |
| `setup-key-login.sh` | 1.0.2 | 配置新机器的 SSH 密钥登录并验证 |
| `sync-llm-allowlist.sh` | 2.0.3 | 同步 LLM 站点白名单与 fail2ban 规则 |
| `upgrade-vaultwarden.sh` | 1.2.1 | 检查并升级 Vaultwarden，锁定镜像 digest |

## new-api 数据与链路

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `apply-newapi-quota-fix.sh` | 1.2.2 | 停止 new-api 后修正消费统计并校验回传 |
| `fix-newapi-fallback-quota.sh` | 1.0.1 | 修正 new-api 兜底倍率造成的虚高消费 |
| `fix-newapi-quota-data.sh` | 1.0.1 | 按已修正的日志重算 new-api 配额统计 |
| `newapi-drill.sh` | 1.0.3 | 在备用机演练 new-api 备份的恢复与清理 |
| `newapi-linkcheck.sh` | 1.0.2 | 检查 new-api 隧道和公网访问全链路 |
| `newapi-log-prune.sh` | 1.0.3 | 清理超过保留期的 new-api 消费日志 |

## 清理

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `cleanup-purge.sh` | 1.0.3 | 按安装台账移除 ops-scripts 及其产物 |
| `cleanup-tidy.sh` | 1.1.1 | 清理历史输出、旧版备份与中间产物 |

## 操作约定

`cleanup-tidy.sh`、`cleanup-purge.sh` 和 `bind-localhost.sh` 默认先预演，带 `--apply` 才执行。涉及数据库修正的 `fix-newapi-*.sh` 应在容器停止并完成备份后使用；`apply-newapi-quota-fix.sh` 串联停服、拉库、修正、校验和恢复。灾难恢复演练 `newapi-drill.sh` 只在备用机运行，并拒绝生产目标。

`containerize-and-pin.sh` 保留改名前的旧容器以便回滚，并锁定当前镜像 digest，不执行升级。`deploy-litellm.sh` 将容器端口绑定本机；加入模型后 `LITELLM_SALT_KEY` 必须保持不变，丢失该密钥将无法解开已加密的凭据。`panel-backup-upload.sh` 默认用 7z 加密，`--raw` 会上传未加密原包。

`sync-llm-allowlist.sh` 的 fail2ban/ufw 封禁会影响所有端口，`ignoreip` 需覆盖整组可信机器，并检查 nginx 的 allow/deny 顺序。`upgrade-vaultwarden.sh` 即使回退 compose 配置也未必能回退数据库迁移，升级前须有近期备份。

无人值守任务调用已安装的本地脚本；升级和有破坏性的操作先确认备份与回滚方式。版本记录见 [CHANGELOG.md](CHANGELOG.md)。
