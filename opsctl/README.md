# opsctl：OpsDeck 受控运维服务端

本目录交付第一阶段的 Linux 服务端和首次接入安装器。它不是 `opsget` 菜单脚本；OpsDeck 只打包已确认提交中的单文件 `bootstrap.py`，在用户核对目标 SSH 主机指纹后，通过一次性 root 会话安装。日常连接只使用专用 `opsdeck` 账号。

| 文件 | 版本 | 用途 |
| --- | --- | --- |
| `bootstrap.py` | 2.1.0 | root 首次安装、受限 SSH 入口、白名单 JSON 动作（含任务闭环、安全扫描修复、新机模板与节点绑定） |
| `SHA256SUMS` | 2.1.0 | 发布文件的 SHA-256 校验值 |

依赖：Debian 12 或兼容的 Linux，`/usr/bin/python3`、OpenSSH server、`sudo`，以及运行中的 systemd journald。安装器依赖 `useradd`、`chpasswd`、`userdel`、`visudo`、`sshd`、`systemctl`。没有 systemd 的测试容器可在装好后启动 sshd；正常服务器会在配置校验后 reload `ssh`。本阶段没有跳转账号安装器，目标机 `opsdeck` 始终禁止转发；需要跳转时由独立项目另行配置只准登记目标的 `direct-tcpip` 账号。

## 首次安装契约

客户端从固定提交获取 `opsctl/bootstrap.py` 与同目录 `SHA256SUMS`，先核对文件哈希，再把单文件以 `0600` 上传到 root 独占的 `/tmp/opsdeck-bootstrap-<UUID>/bootstrap.py`（目录 `0700`）。SSH 主机指纹必须先与可信渠道核对；未确认前不得发送 root 密码。root 会话执行固定的 `/usr/bin/python3 /tmp/opsdeck-bootstrap-<UUID>/bootstrap.py`，stdin 只发送一行 JSON 后关闭：

```json
{"version":1,"computer_id":"11111111-1111-4111-8111-111111111111","public_key":"ssh-ed25519 AAAA...","expected_host_fingerprint":"SHA256:..."}
```

`computer_id` 为小写 UUID；公钥仅接受 Ed25519。安装器从 `/etc/ssh/ssh_host_*_key.pub` 独立计算并核对 `expected_host_fingerprint`，不接收客户端自报的审计身份。成功响应：

```json
{"version":1,"ok":true,"data":{"asset_id":"<稳定 UUID>","opsctl_version":"1.0.0","artifact_sha256":"<64 位十六进制>","authorized_key_fingerprint":"SHA256:...","host_fingerprint":"SHA256:..."}}
```

失败响应为 `{"version":1,"ok":false,"error":{"code":"...","message":"..."}}`，不包含口令、环境变量或私钥。客户端收到成功响应后关闭 root 连接，删除上传的临时目录，并用新密钥单独调用 `host.discover` 验收。重复安装同一版本和同一电脑密钥不改变权限、资产 ID 或授权文件；新电脑可用相同安装器加入新公钥。同一电脑换钥匙、不同版本覆盖、已有同名账号或来源不受信的配置会被拒绝。本阶段不提供在线升级或密钥轮换。

安装结果在服务器端由 root 管理：`/etc/opsctl/asset.json` 保存稳定资产 ID，`keys.json` 保存电脑 ID 与公钥，`authorized_keys` 只给 sshd 读取而不允许 `opsdeck` 写入；代码在 `/usr/local/lib/opsctl/opsctl.py`，`/usr/local/bin/opsctl`、`opsctl-ssh`、`opsctl-admin` 是 root 管理入口。安装器检查现有对象及权限，校验 sudoers 和 sshd 的有效设置，失败则回滚本轮创建的账号、文件和目录。

### 不依赖 OpsDeck 的 root 手工吊销

在目标机 root 会话先只读列出电脑 ID 与公钥指纹：`/usr/local/bin/opsctl-admin keys list`。确认目标后，再单独执行 `/usr/local/bin/opsctl-admin key revoke SHA256:<指纹>`；最后再次 `keys list` 核对。管理员入口允许紧急撤销最后一把钥匙，之后只能凭带外 root 会话重新接入，并在两处服务端审计中标记 `root.local`。具体服务器上操作仍按私有运维手册分开给只读检查与改动命令；本公开仓库不放生产机器地址或真实指纹。

## 日常协议

客户端以 `opsdeck` 公钥认证，SSH exec 命令固定为 `opsctl`，stdin 发一行不超过 64 KiB 的 UTF-8 JSON 并关闭，响应是一行 JSON。请求顶层仅允许 `version`、`id`、`action`、`params`，`id` 为小写 UUID；重复键、未知字段与动作拒绝。`SSH_ORIGINAL_COMMAND` 不为 `opsctl` 时受限入口拒绝。服务端从 root 管理的授权密钥行所绑定的强制命令取得来源公钥指纹；请求字段不能覆盖它。

| 动作 | `params` | 结果 |
| --- | --- | --- |
| `host.discover` | `{}` | `asset_id`、主机名、OS、内核、架构、已知服务和软件包、可用动作、安全摘要与角色/节点绑定；只读 |
| `security.scan` | `{}` | 内核重启状态、sshd/sudo 策略状态、风险项、与上次基线的差异（新增/持续/已修复）、上线门槛结果 |
| `plan` | `{"action":"...","params":{...}}` | 支持 `key.revoke`、`security.fix`、`template.apply`、`node.configure`、`service.control`；返回环境绑定的 `plan_id` |
| `apply` | `{"job_id":"<UUID>","action":"...","plan_id":"<64 位十六进制>","params":{...}}` | 校验 `plan_id` 后幂等执行计划并持久化任务记录与事件流 |
| `status` | `{"job_id":"<UUID>","after_seq":0}` | 断线后查询原任务状态并续读增量事件 |
| `verify` | `{"job_id":"<UUID>"}` | 对已完成任务做独立运行/落盘验收并记录 `verification` |
| `jobs.list` | `{"limit":20}` | 列出本机历史任务记录 |
| `key.revoke` | `{"fingerprint":"SHA256:...","plan_id":"<64 位十六进制>"}` | 吊销目标公钥，允许紧急撤销最后一把 |

`plan_id` 是资产 ID、规范化参数、当前授权文件 SHA-256 与 `opsctl` 版本的摘要。执行时重新计算，不一致即拒绝；它用于阻止状态变化后的旧计划执行，客户端的高危操作仍需按 OpsDeck 设计重新验证主密码。可以吊销最后一把密钥以紧急收回访问：之后所有 `opsdeck` 新连接均被拒绝，只能用带外 root 会话重新接入。没有任意命令、任意脚本或泛用 sudo 动作。

服务端将每次动作的 UTC 时间、来源密钥指纹、动作、参数哈希、计划 ID 和结果写到 journald（`SYSLOG_IDENTIFIER=opsctl`）及 `/var/log/opsctl/audit-YYYY-MM-DD.jsonl`。日志只保存参数摘要，不保存原始参数。journald 不可用时动作失败关闭；吊销写入后若最终审计失败，会恢复授权文件。SSH 握手阶段的拒绝另由 sshd 记录，尚未进入 opsctl 的请求不会产生 opsctl 文件审计。

## 测试与边界

`tests/opsctl.bats` 在一次性 Debian 12 容器里启动真实 sshd，验证主机指纹、密码拒绝、固定命令、PTY、转发、协议校验、只读扫描、安装回滚、重复安装、计划和吊销。运行整个仓库测试见 [tests/README.md](../tests/README.md)。测试不连接生产机；真实 systemd、面板、ufw、跨机跳转和客户端主密码流程尚未在生产环境验收。

Windows→WSL 客户端联调可在已登记的 Debian 环境中启动一次性容器，映射本机 `127.0.0.1:22222` 到容器 SSH 端口：

```powershell
wsl.exe -d Debian -u root --exec docker build -t opsctl-test -f /mnt/d/Projects/Github/Ops-scripts/tests/Dockerfile /mnt/d/Projects/Github/Ops-scripts/tests
wsl.exe -d Debian -u root --exec docker run --rm -p 127.0.0.1:22222:22 -v /mnt/d/Projects/Github/Ops-scripts:/src:ro opsctl-test python3 /src/tests/opsctl-dev-server.py
```

容器启动后在终端显示一次性测试用 root 密码和主机指纹。它**不自动安装 opsctl**，供客户端完整走上传、安装、独立新密钥发现流程；测试 sshd 启动时已加载受限账号规则，安装后测试进程再创建专用 `opsdeck-jump` 账号，复用安装时登记的公钥。跳板只准 `direct-tcpip` 到同容器的 `127.0.0.1:22`，目标 `opsdeck` 仍禁止转发。停止容器后测试账号与密钥全部消失。此端口不能用于生产机。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
