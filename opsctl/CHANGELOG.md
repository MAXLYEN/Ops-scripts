# opsctl 版本迭代记录

## 2026-11-01 — 2.1.0

- 对齐真实中转落地机与直连机 8 步上线流程：新增 `landing_node` 角色模板（只开 SSH、仅对中转入口放行 `30xxx`、Komari 禁用 WebSSH + `xboard-node`）。
- `security.scan` / `security.fix` 新增 `bookworm-security` 官方安全源检查与 `komari-agent` `AGENT_DISABLE_WEB_SSH=true` 策略检查及自动加固。
- `node.configure` 支持内置中转入口标识、`subdomain_prefix`（如 `zchk1` / `zcjp1`）、Xboard `machine_id`、内部落地节点名（`落地-xxx-L`）与 `30xxx` 端口映射列表。

## 2026-10-31 — 2.0.0

- 扩展任务执行闭环协议：`plan` / `apply`（带幂等 `job_id`） / `status`（带 `after_seq` 断线续读） / `verify`（独立验收） / `jobs.list`。
- 新增 `security.scan` 与 `security.fix`：检查运行内核与已装内核重启差异、sshd/sudoers 受限策略漂移、保存复检基线并输出新旧基线差异（新增/持续/已修复）。
- 新增 `template.apply`（4 类新机初始化角色模板）与 `node.configure`（VLESS+Reality 节点与订阅绑定）、`service.control`。
- 兼容 `ssh` / `sshd` systemd 服务重载；保持 `sudo NOEXEC` 纯 Python 内建动作边界。

## 2026-10-31 — 1.0.0

- 首版单文件 Python 安装器与受限服务端，保留稳定资产 ID，按电脑公钥单独授权。
- 建立 `host.discover`、`plan`、`key.revoke` 的 v1 JSON 白名单协议和双通道审计。
- 安装 root 管理的授权文件、专用账号、固定 SSH 强制命令及最小 sudo 权限；加入真实 sshd 隔离测试。
