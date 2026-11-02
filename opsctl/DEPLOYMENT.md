# opsctl 3.0.0 真实部署配置

Windows 只提交受限 JSON 计划。汇总机保管服务凭据与独立编排密钥，工作机保管本机策略。运行中的 root runner 与 SSH 请求入口分离，日常 sudo NOEXEC 保留。

## 安装与升级

使用 OpsDeck 随包的、固定提交及 SHA-256 的 bootstrap.py，通过已独立核对指纹的 root 会话安装。安装后必须用 opsdeck 密钥独立扫描。支持从 2.0.0 / 2.1.0 / 2.1.1 / 2.2.0 root 授权升级，保留稳定 asset_id、其他已授权电脑与业务记录。拒绝已安装代码被篡改、权限异常或存在运行中部署任务的升级。

生产系统需要 systemd、OpenSSH server、sudo、Python 3、OpenSSL。汇总机另需 certbot、python3-certbot-dns-cloudflare、Nginx 配置检查入口及固定哈希的 sing-box 验收程序。无 systemd 容器仅用于协议与断线测试，不能当成业务服务验收。

## 一次性配置

1. 管理员在汇总机生成独立 Ed25519 编排密钥（私钥 0600），只用于 opsdeck 的固定命令，不复用电脑私钥或 root 免密登录。
2. 每台工作机使用带外 root 的 `opsctl-admin key authorize` 登记这把公钥；stdin 为一行 `{ "computer_id": "<编排身份 UUID>", "public_key": "ssh-ed25519 <公钥>" }`。重复登记同一身份幂等，冲突拒绝。
3. 编辑 deployment.example.json，使用已接入的实际稳定资产 ID、已独立核对的完整 Ed25519 主机公钥、域名、机器 ID 和版本。生产配置不放进 Git。
4. 中心策略 mode 为 coordinator；节点策略 mode 为 worker。节点策略只需域名后缀、本机资产、允许端口、编排指纹、panel_url、komari_url 和固定 artifacts；不需要面板主凭据。
5. 用带外 root 的 `opsctl-admin deployment configure` 从 stdin 读取一行完整策略。配置失败保留旧文件。该命令不向日常 SSH 通道开放。
6. 独立执行只读 `opsctl-admin deployment check`，并核对 `systemctl status opsctl-runner`。Windows 工作区填写已接管的部署中心地址；留空沿用汇总机地址。

部署策略存放 `/etc/opsctl/deployment.json`，root:root、0600。凭据使用 root 管理的独立文件，策略只引用路径。Cloudflare token 文件内容是一行指定 Zone 的 DNS 编辑令牌；Xboard 与 Komari token 文件同样只放各自令牌，不含 Bearer 前缀。

示例中的 UUID、192.0.2.0/24、example.net、公钥及软件包哈希都必须换成实际登记值。示例故意不提供可用密钥或下载包；不能直接用于生产。

### 资产与软件

- 所有服务地址、IP、域名、主机公钥都在服务端策略；客户端请求不能覆盖它们。
- `entry_ports` 是默认快捷端口。默认允许表单「其他」输入的合法端口；SSH、回源和其他落地机流量仍受硬性保护。管理员如需额外限制，可设置 `allow_custom_ports: false`，此时入口仅允许该列表。
- `assets[UUID].name/domain/ip/ssh_port/host_key/runner_version` 必填。入口 role=direct，另登记 machine_id 和经核对的中转 template_node_id。
- 新目标没有 Xboard machine_id 时通过管理 API 建机器；已有机器必须登记准确 ID。已有 xboard-node 配置必须额外登记 xboard_config_sha256，且其 machine_id 一致；否则保留原服务并拒绝覆盖。原有 service 单元保持不变。
- 软件 artifacts 固定 url/version/sha256，可指定 tar 包内固定 member。只取该普通成员，拒绝链接、路径遍历式解包及非 ELF 文件。
- `probe_binary` 是中心现有 sing-box 的绝对路径，必须填写其 SHA-256。`probe_uuid_file` 使用已有且有权访问测试链路的验收账号 UUID。程序不创建用户、不扩大用户授权分组，不把该账号代入业务出站。
- 汇总机使用宝塔 Nginx 时设置 `nginx_provider: "bt"`，按固定路径检查配置后调用 `/etc/init.d/nginx reload`；默认 `system` 使用系统 Nginx。配置检查失败不会重载。工作机 Reality 回源仍要求系统 Nginx。
- `registration` 指定现有主机清单和 Nginx 来源白名单文件。可选 ingress_port 只为新登记目标 IP 增加指定端口来源规则，不修改 SSH 监听或防火墙默认策略。

### 面板契约

优先使用 Xboard V2 管理 API：server/machine/fetch|save|getToken|drop 与 server/manage/getNodes|save|update|drop。管理 secure_path 来自服务端策略。对应官方路由与 ServerSave、ManageController、MachineController 源码；实际部署版本必须在试点核对，不自动猜测私有分支接口或直接写数据库。

节点初始 show=0、enabled=true，先让服务端运行，完成证书与真实 VLESS/Reality 出口验收后才 show=1。对外组和内部组由中心固定。中转出站复制已核对的模板，只更换本次落地地址、端口和 Reality 公钥参数。

Komari 使用 1.5.0-fix1 管理路由：client/list、client/add、client/<uuid>/token 与 remove。高危管理令牌留在中心，只下发新机器自己的探针 token，探针运行时禁用 WebSSH。CLIProxyAPI 不在本协议中。

## 任务和运维

`deployment.plan` 返回 15 分钟有效、绑定设备身份、中心资产、执行器哈希、策略与 Xboard/DNS 快照的计划和唯一任务 ID。每份计划只能使用该 ID；`deployment.apply` 持久入队即返回，不等待长任务。

`status` 返回完整 steps 和可按 after_seq 续读的 events；失败后保留原任务，`deployment.resume` 只执行未通过步骤。响应丢失先查询原 ID，不自动重新提交。软件关闭或 SSH 断线不会取消 runner。

`deployment.rollback` 只处理本任务资源。检测到外部修改或节点引用时停止。已完成系统更新不回退；证书归档与 ACME 账户保留。工作机回滚会恢复配置、原服务启用/运行状态，并保留其他任务规则。

每条业务 ufw 新规则带任务标记和 180 秒独立 SSH 确认期限；超时只撤销本任务未确认的规则。未知占用、共享服务、SSH 端口和其他落地机占用端口不能覆盖。

初始部署通过后，中心登记证书续期任务，每 12 小时检查一次 DNS-01 签发与单机证书下发，节点校验证书、密钥后重载回源 Nginx。续期失败保留错误码，1 小时后再检查；修改域名/资产策略后需要重新核对登记。回滚会撤销本任务建立的续期登记。

审计在 journald 与 /var/log/opsctl；私密参数与资源备份在 /var/lib/opsctl/deployment-private/，均只允许 root 读取。状态和事件不包含私钥、token、原始上游响应或命令 stderr。

## 验证边界

Python 隔离测试覆盖真实回环 HTTP、失去创建响应后的幂等恢复、计划过期和漂移、编排密钥保护、撤销后停止、文件/节点回滚保护与防火墙超时。

一次性 sshd 容器用于 Windows 实际安装与身份核对；显式测试 fixture 可启动独立 runner 和临时 CA/TLS 服务，验证关闭 SSH 后任务继续、重连读到真实握手证据。测试 fixture 必须在显式选择的一次性容器运行，不能安装到生产机。

这些检查不代表生产 Xboard、ACME、ufw 与 systemd 的联合业务验收已完成。上线前需要隔离完整流程测试机及用户确认的单机试点，记录每步实际证据，再扩展其他入口。
