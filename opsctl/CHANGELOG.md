# opsctl 版本迭代记录

## 2026-11-01 — 2.1.1

界面和接口只宣称真正做到的事。

- 停用 `service.control`：可用动作里去掉；`plan`、`apply`（含旧任务重放）都返回 `ACTION_DENIED`；2.1.0 留下的旧 `service.control` 任务 `verify` 判失败。
- `verify` 默认失败：只有拿到属于本资产、本任务的正面证据才通过；没有验收器的动作直接 `ACTION_DENIED`。`verification` 新增 `scope`，以及恒为 `false` 的 `deployment_verified`。
- `template.apply`、`node.configure` 只写记录（结果带 `metadata_only: true`、`deployment_verified: false`，不装软件包、不改防火墙、不调用 Xboard / Komari / DNS）。它们的 `verify` 的 `scope` 是 `record_consistency`：比对服务器上当前的记录文件与该任务保存的结果是否逐字节一致；被后续任务覆盖后，旧任务不再通过。
- `node.configure` 的 `relay_bindings` 严格校验：字段固定为 `relay_asset_id`（UUID，须在 `entry_asset_ids` 中、不重复）、`relay_host`、`relay_name`、`relay_prefix`、`internal_node`、`subscription_name`、`landing_port`（同机不重复）、`entry_port`，最多 32 项；入口标识不再接受 `builtin-relay-<IP>`。
- Komari WebSSH 按运行中 `komari-agent` 进程的环境（`/proc/<pid>/environ`）判断，新增 `komari_runtime`、`komari_override_written` 字段和 `SEC-KOMARI-WEBSSH-RESTART` 发现项。`security.fix` 结果新增 `pending_reload`（sshd 配置被改写 → `ssh`，Komari override 被改写 → `komari-agent`）；opsctl 在 `sudo NOEXEC` 下不能重载服务，`pending_reload` 含 `ssh` 时 `verify` 不通过。
- 安装时的 `visudo -cf`、`sshd -t`、`sshd -T` 校验不变。

## 2026-11-01 — 2.1.0

- 对齐真实中转落地机与直连机 8 步上线流程：新增 `landing_node` 角色模板（只开 SSH、仅对中转入口放行 `30xxx`、Komari 禁用 WebSSH + `xboard-node`）。
- `security.scan` / `security.fix` 新增 `bookworm-security` 官方安全源检查与 `komari-agent` `AGENT_DISABLE_WEB_SSH=true` 策略检查及自动加固。
- `node.configure` 支持内置中转入口标识、`subdomain_prefix`（子域名前缀）、Xboard `machine_id`、内部落地节点名（`落地-xxx-L`）与 `30xxx` 端口映射列表。

## 2026-10-31 — 2.0.0

- 扩展任务执行闭环协议：`plan` / `apply`（带幂等 `job_id`） / `status`（带 `after_seq` 断线续读） / `verify`（独立验收） / `jobs.list`。
- 新增 `security.scan` 与 `security.fix`：检查运行内核与已装内核重启差异、sshd/sudoers 受限策略漂移、保存复检基线并输出新旧基线差异（新增/持续/已修复）。
- 新增 `template.apply`（4 类新机初始化角色模板）与 `node.configure`（VLESS+Reality 节点与订阅绑定）、`service.control`（2.1.1 起停用）。
- 兼容 `ssh` / `sshd` systemd 服务重载；保持 `sudo NOEXEC` 纯 Python 内建动作边界。

## 2026-10-31 — 1.0.0

- 首版单文件 Python 安装器与受限服务端，保留稳定资产 ID，按电脑公钥单独授权。
- 建立 `host.discover`、`plan`、`key.revoke` 的 v1 JSON 白名单协议和双通道审计。
- 安装 root 管理的授权文件、专用账号、固定 SSH 强制命令及最小 sudo 权限；加入真实 sshd 隔离测试。
