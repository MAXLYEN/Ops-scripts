# 灾难恢复手册

**适用场景：原来的机器已经彻底用不了**，开不了机、登不上、数据拿不出来，开发电脑可能也不在手边。按本文从零做，在任何一家商家的新机器上，把服务恢复成原样。

**原机器还活着**，只是想换机器、换商家的话，不要用本文，用一键迁移：在**旧机**上运行 `opsget migrate/live-migrate <新机IP>`（也可以在 `opsbox` 菜单的「整机迁移 → 一键迁移（原机还在）」里做），用法见 [migrate/README.md](../migrate/README.md)。两套方案的区别：

| | 极端恢复（本文） | 一键迁移 |
| --- | --- | --- |
| 什么时候用 | 原机已经没了 | 原机还能登录，计划内换机 |
| 数据从哪来 | 网盘上最近一次的备份包 | 迁移时从原机现做一份，直接传到新机 |
| 会丢什么 | 最近一次备份之后的改动（vw、xboard、LiteLLM 最多 6 小时，new-api 最多 1 小时） | 不丢 |

本文放在公开仓库里，**不写任何真实的密码、IP、域名**。

目录：

1. [恢复靠什么](#1-恢复靠什么)
2. [唯一需要手动保存的：备份解密密码](#2-唯一需要手动保存的备份解密密码)
3. [小演练：5 分钟核对密码与包](#3-小演练5-分钟核对密码与包)
4. [恢复流程：从零开始](#4-恢复流程从零开始)
5. [大演练：在临时机上完整走一遍](#5-大演练在临时机上完整走一遍)
6. [不在备份范围内的东西](#6-不在备份范围内的东西)

---

## 1. 恢复靠什么

```
网盘（OneDrive、Google Drive 各一份）
  └─ 加密备份包 ── 用「备份解密密码」解开（第 2 节，唯一手动保存的东西）
       └─ 包里的一切：env.conf、rclone 网盘授权、告警邮件配置、SSH 密钥（含登录落地机的私钥）、
                      MySQL 全部账号、证书、Nginx、面板数据、各服务数据、定时任务、服务器清单

各种账号（网盘、Cloudflare、VPS 商家）
  └─ 都存在 Vaultwarden 里 ── 服务器挂了也能看（见下面第 2 条）；实在不行，走各家的找回密码
```

- **机器**：任何一家商家、任何一台 Debian 12 新机器都行，不依赖原来的商家。
- **账号密码**：Vaultwarden 服务器挂了之后，**已经登录过的 Bitwarden 客户端（手机 App、浏览器插件、桌面端）里还有一份本地缓存，可以离线查看**。前提是客户端没有退出登录。所以**至少让一台设备（最好是手机）一直保持登录**。
- **两步验证**：Cloudflare、Google 这类账号，找回密码时一般还要过两步验证。验证器 App 装在手机上，别跟服务器、开发电脑绑在一起。

---

## 2. 唯一需要手动保存的：备份解密密码

所有备份包（vw、xboard、new-api、LiteLLM）**都用同一个密码加密**。它存在前置机的 `/root/.vw_backup_pass` 里，也就是 `env.conf` 中 `BACKUP_PASS_FILE` 指向的文件。

**这个文件不会进任何备份包**（否则拿到包的人就同时拿到了钥匙），所以它**必须手动保存**。在前置机上查看：

```bash
cat "$(. /etc/ops-scripts/env.conf; echo "${BACKUP_PASS_FILE:-$VW_PASS_FILE}")"
```

**保存要求：**
- **至少两处，而且都不能只依赖 Vaultwarden**，比如一张纸，加上手机里的一条离线备忘。Vaultwarden 就在要恢复的备份包里，只存在它里面就成了死循环。
- **不要轻易换这个密码**。换了之后，旧的包仍然只能用旧密码打开。真要换，旧密码也要一直留着，直到旧包全部过期删完（云端最长保留 400 天）。

**其他一切都不需要单独保存**：MySQL 各账号密码、Xboard 的 `APP_KEY` 和数据库密码、LiteLLM 的 `.env`（含 `LITELLM_SALT_KEY` 和 master key）、rclone 授权、邮件配置、SSH 密钥、证书、`env.conf`、服务器清单，都在加密包里。

---

## 3. 小演练：5 分钟核对密码与包

检查"手里保存的密码"和"网盘上的包"对不对得上。这是整套方案里最容易出问题、又最容易检查的一环。

**什么时候做**：改过或重新保存备份解密密码之后、换了网盘或备份方案之后、真要恢复之前。平时不必定期做，服务器上的 `verify-backup-pass` 每周会自动检查一次。

**用手机或者另一台电脑做：**

1. 登录 OneDrive 网页版，打开 `Backup-Server` 目录，下载最新的 `srvbak_*.7z`；
2. 用 7-Zip（手机上用 ZArchiver 之类的软件）打开，输入**手动保存的备份解密密码**；
3. 能看到 `RESTORE.md`、`manifest.txt`、`payload.tar.gz` 三个文件，就算通过。打开 `manifest.txt` 看一眼备份时间，应该是最近几个小时内的；
4. 删掉下载的文件。

**打不开的话，当天就处理**：先去前置机上重新确认密码。

另外，前置机上每周一有 `verify-backup-pass` 定时任务，会在服务器上自动检查云端最新的包能不能解开。它检查的是服务器上的密码文件，这个小演练检查的是**你手里保存的**那份，所以上面那几种时候仍要做一次。

---

## 4. 恢复流程：从零开始

下面按"前置机彻底没了"来写。只是落地机没了的话，直接看第 4.8 节；只是 LiteLLM 节点没了，直接看第 4.9 节。

### 4.0 准备一台能用的电脑，以及 SSH 登录的三道关

1. 安装 **7-Zip**。Windows 10/11 自带 `ssh` 和 `scp`；macOS 和 Linux 也都自带。
2. **SSH 登录要过三道关**，恢复前先确认每一道都过得去：

| 关卡 | 现状 | 恢复时 |
| --- | --- | --- |
| **密钥** | 前置机和所有节点机用的是**同一把密钥**，不用新建 | 把这把私钥放到这台电脑的 `~/.ssh/`（Windows 是 `C:\Users\<你>\.ssh\`）。私钥存在 **Vaultwarden** 里（服务器挂了也能从已登录客户端的缓存里取），本地另有两份 |
| **Google 两步验证** | **只有密码登录才要**输手机验证器里的 6 位验证码，**密钥登录不需要**。备份、隧道这些自动化连接都用密钥，不受两步验证影响 | TOTP 密钥随备份包恢复（`/root/.google_authenticator`），**手机上原来那个验证器条目继续可用，不用重新绑定**。手机丢了的话：备份包里 `rootfs/root/.google_authenticator` 文件末尾那几行 8 位数字是一次性应急码，每个只能用一次 |
| **来源 IP 放行名单** | 每台机器用 **ufw** 只允许**本地出口 IP、前置机、各节点机**连 SSH（规则在 `/etc/ufw`，随备份包恢复）。前置机的名单由 `ops/ssh-allowlist` 按 `~/.vps-hosts.txt`、`ADMIN_IPS`、`ALLOW_EXTRA_IPS` 生成，名单要加、要删，在前置机上直接运行 `ssh-allowlist.sh`，菜单里选新增或删除，改完当场另开窗口验证。本地 IP 变了的话，先连上某台节点机的代理，再从它那里登录 | 见第 4.6 节最后和第 4.8 节：新前置机的 IP 要加进其他机器的名单；恢复出来的名单里要有你现在的 IP |

**刚开的新机器还没有恢复，所以没有两步验证，也没有放行名单**，只用密钥（或商家给的 root 密码）就能登录。恢复完成、重启 SSH 之后，三道关才全部生效。

### 4.1 判断范围

| 情况 | 做什么 |
| --- | --- |
| 前置机没了，落地机和 LiteLLM 节点正常 | 4.2 到 4.7，然后 4.10、4.11 |
| 落地机没了，前置机正常 | 只做 4.8 |
| LiteLLM 节点没了，前置机正常 | 只做 4.9 |
| 都没了 | 全部都做 |

**前置机没了、落地机还活着的时候**，可以先用落地机上的 Cloudflare 备用通道，让 new-api 几分钟内恢复使用，见第 4.7 节最后。

### 4.2 下载备份包，读出服务器清单

登录 OneDrive 网页版（进不去就换 Google Drive），从四个目录里各下载**最新**的一份（LiteLLM 节点还活着的话，`Backup-LiteLLM` 可以不下）：

| 目录 | 文件 |
| --- | --- |
| `Backup-Server` | `srvbak_YYYYMMDD_HHMMSS.7z` |
| `Backup-Xboard` | `xboard_YYYYMMDD_HHMMSS.7z` |
| `Backup-NewAPI` | `newapi_YYYYMMDD_HHMMSS.7z`，旁边的 `.sha256` 也一起下载 |
| `Backup-LiteLLM` | `litellm_YYYYMMDD_HHMMSS.7z`，旁边的 `.sha256` 也一起下载 |

用 7-Zip 打开 `srvbak_*.7z`，再打开里面的 `payload.tar.gz`。**恢复需要的信息都在这里：**

| 文件 | 看什么 |
| --- | --- |
| `manifest.txt` | 原机的 **MySQL、Nginx 版本**，有哪些站点，有哪些容器 |
| `rootfs/etc/ops-scripts/env.conf` | 落地机的 IP 和 SSH 端口（`NEWAPI_HOST`、`NEWAPI_SSH_PORT`）、LiteLLM 节点的 IP（`LITELLM_HOST`）、网盘目录名等 |
| `rootfs/root/.vps-hosts.txt` | 其他机器的清单 |
| `system/nginx/` | 所有站点的域名（每个 `.conf` 文件对应一个站点），切 DNS 时要用 |

### 4.3 开新机器

- 系统选 **Debian 12**；配置不低于原机（在 `manifest.txt` 里看原机用了多少资源，宁可高一点）。
- **安全组 / 防火墙一开始就放行原机的 SSH 端口**（`env.conf` 或 `manifest.txt` 里能看到，常见的不是 22），连同 22、80、443。恢复后重启 SSH 就换到原机端口；到那时才发现商家的安全组没放行，就只剩当前这个会话能用，断了只能进商家控制台救。
- 商家有"SSH 密钥"选项的话，填**原来那把密钥的公钥**。**云镜像大多不许 root 直接登录**（用 root 连会提示 `Please login as the user "debian"`，AWS 是 `admin`）：先用它提示的用户登录，`sudo -i` 后执行 `install -m 600 /home/<那个用户>/.ssh/authorized_keys /root/.ssh/authorized_keys`，之后都用 root（传包、恢复都要 root）。没有密钥选项的话，先用商家给的 root 密码登录，然后执行：

  ```bash
  mkdir -p ~/.ssh && echo '<原来那把密钥的公钥>' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
  ```

  公钥可以从私钥算出来（在电脑上运行，把 `id_ed25519` 换成你的私钥文件名）：

  ```bash
  ssh-keygen -y -f ~/.ssh/id_ed25519
  ```

- 恢复时，脚本会把 `/root/.ssh` 换成原机的，里面本来就有这把公钥；恢复前能登录的公钥也会再加回去，所以不会被关在外面。

### 4.4 系统初始化

```bash
curl -fsSL https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget
```

固定到最新的发布版本。版本号在仓库的 Tags 页面查：<https://github.com/MAXLYEN/ops-scripts/tags>

```bash
opsget --pin <最新的 tag> && opsget -u
```

```bash
opsget init/run
```

按提示把 00 到 04 走完，中间要重启的地方就重启。

### 4.5 装环境

1. **宝塔面板**：用宝塔官网给的 Debian 安装命令，装最新版就行（比原机新没关系：恢复时放回的是面板的配置与数据，相当于一次面板升级；反过来比原机旧才有风险）。装好后在面板软件商店里用**极速安装**装 **MySQL（跟 `manifest.txt` 里的大版本一样，原机是 5.7）**和 **Nginx**（与原机相同或最接近的版本）。
2. **Docker**：

   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

3. **备份依赖与 rclone**：`restore-from-backup` 1.5.0 起恢复时自动装（任何模式），这里不用手动做。要自己装时注意两点：rclone **一定用官方版**（`curl -fsSL https://rclone.org/install.sh -o /tmp/rclone-install.sh && bash /tmp/rclone-install.sh`；发行版源里的 rclone 太旧，Debian 12 是 1.60，对 OneDrive 能列目录、下载却报 `unauthenticated`，面板整机备份只在 OneDrive 上，这条兜底路径就断了）；其余用 `DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta p7zip-full rsync sqlite3`。**装软件一律加 `DEBIAN_FRONTEND=noninteractive`**：有的终端显示不了 debconf 的全屏对话框，看起来就像卡死。

宝塔安装本身要 40 分钟以上（真机演练实测 46 分钟），是整个恢复里最长的一步，可以趁这时候去做落地机（4.8）。

### 4.6 最小配置，然后恢复

MySQL 的 root 凭据。密码用**新机器**的，在宝塔面板的"数据库"页面能看到：

```bash
printf '[client]\nuser=root\npassword="新机器的MySQL root密码"\n' > /root/.my.cnf && chmod 600 /root/.my.cnf
```

备份解密密码，填你手动保存的那个：

```bash
install -m 600 /dev/null /root/.vw_backup_pass && nano /root/.vw_backup_pass
```

最小的 `env.conf`。其余配置项，恢复时会从包里原机的 `env.conf` 自动补上：

```bash
mkdir -p /etc/ops-scripts && cat > /etc/ops-scripts/env.conf <<'EOF'
BACKUP_PASS_FILE="/root/.vw_backup_pass"
DB_CLIENT_HOST="172.%"
MYSQL_DEFAULTS_FILE="/root/.my.cnf"
PANEL_VHOST_DIR="/www/server/panel/vhost/nginx"
PANEL_CERT_DIR="/www/server/panel/vhost/cert"
EOF
chmod 600 /etc/ops-scripts/env.conf
```

在**电脑**上把包传到新机器：

```bash
ssh root@新机器IP "mkdir -p /root/pkgs"
```

```bash
scp srvbak_*.7z xboard_*.7z root@新机器IP:/root/pkgs/
```

在**新机器**上安装恢复脚本，先检查：

```bash
opsget -i migrate/restore-from-backup
```

```bash
restore-from-backup.sh check /root/pkgs/srvbak_*.7z /root/pkgs/xboard_*.7z
```

`check` 只解包、校验，列出恢复时会做什么，不改动本机。看一下没有报错，然后正式恢复：

```bash
restore-from-backup.sh restore /root/pkgs/srvbak_*.7z /root/pkgs/xboard_*.7z
```

恢复会自动完成：文件（权限、属主跟原机一致）、数据库和全部账号、各服务数据、按原版本拉镜像并启动容器、systemd 单元（包括连落地机的隧道）、Nginx、定时任务（按新频率）。最后 MySQL 的 root 密码也会改成原机的。

恢复放回的是原机的面板配置，面板一重启就换到**原机的面板端口**（之前经 SSH 通道开面板的，通道要改转新端口）；反代到面板的那个站点在面板换端口之前是 404。

**脚本最后会列出"还要手动做的事"，以那份清单为准。** 常见的有：
- 在宝塔面板里"添加站点"，认领已经恢复的 Nginx 配置（面板的站点记录在它自己的数据库里）；
- DNS 生效后，在面板里逐个站点重新申请证书（EC256）；
- 确认没问题后，删掉恢复用的临时目录。里面是解开的明文数据库导出和密钥。

**先确认告警邮件能发出去**（恢复后第一件事）：

```bash
opsget ops/mail-doctor --send
```

原机的 Vaultwarden 开了「新设备登录必须发邮件通知」（管理后台里的 `require_device_email`）：**邮件发不出去，就不能在任何新设备上登录网页版**，只有已经登录过的客户端还能用。发不出去时，先查新机器的商家是否封了 SMTP 端口（有的商家默认封 25，要开工单），再查 `/etc/msmtprc` 与 Vaultwarden 的 SMTP 设置。

**切 DNS 之前**，先做一遍端到端检查：

```bash
opsget migrate/08-post-start-check
```

**重启 SSH 或重启机器之前（很重要，否则可能把自己锁在外面）：**

恢复出来的 SSH 配置、防火墙都是原机的，**恢复脚本故意没有重载它们**。重载之前：

1. **放行名单**：脚本会检查你当前这个 SSH 会话的 IP 在不在原机的放行名单里。不在的话，"还要手动做的事"里会给出一条 `ufw allow from <你的IP> to any port <端口> proto tcp`，**先执行它**。
2. **两步验证**（只管密码登录）：原机开了 Google 两步验证的话，脚本已经自动装好了 PAM 模块，并用 `sshd -t` 检查过配置。
3. **保持当前这个 SSH 窗口不断开**，然后重载：

   ```bash
   systemctl restart ssh && ufw reload && systemctl restart fail2ban
   ```

4. **另开一个窗口**，用密钥登录（端口是原机的 SSH 端口，可能跟现在不一样）。**能登录上，再关掉旧窗口。**登不上的话，回到旧窗口排查。

### 4.7 切换 DNS

登录 Cloudflare（密码在 Vaultwarden 客户端的缓存里；找不到就走 Cloudflare 的找回密码），把 `system/nginx/` 里列出的**所有域名**的 A 记录都改成新机器的 IP。代理状态（灰色还是橙色云朵）保持原样。

**临时备用通道**：落地机上装了 `cloudflared`，平时没有 Public Hostname，不对外服务。前置机挂了、落地机还活着的时候，可以先在 Cloudflare 的 Zero Trust → Tunnels 里，给 new-api 的域名加一个 Public Hostname，服务填 `http://localhost:3000`，几分钟就能让 new-api 先恢复使用。**加之前要先删掉这个域名原来的 A 记录。**正式恢复完成后，删掉这个 Public Hostname，再把 A 记录加回来。

### 4.8 落地机（new-api）

**先把新前置机的 IP 加进其他机器的 SSH 放行名单。** 落地机、LiteLLM 节点只允许原来那台前置机的 IP 连 SSH。新前置机的 IP 不一样，不加的话，隧道连不上落地机，new-api 和 LiteLLM 的备份也拉不下来。

从你本地（或经某台节点机的代理）登录落地机和 LiteLLM 节点，分别执行（端口换成那台机器的 SSH 端口）：

```bash
ufw allow from <新前置机IP> to any port <SSH端口> proto tcp
```

原前置机的 IP 已经没用了，可以顺手删掉那条规则：

```bash
ufw status numbered
```

找到旧 IP 那条规则的编号，然后：

```bash
ufw delete <编号>
```

**落地机还活着**：加好放行名单之后，其余都不用做。隧道单元和私钥都随备份恢复了，检查一下：

```bash
systemctl status newapi-tunnel --no-pager
```

```bash
curl -s http://127.0.0.1:3000/api/status | head -c 100
```

**落地机也没了：**

1. 开一台新的落地机。**必须是日本、美国这类上游 API 支持的地区**，而且**不能用国内厂商**（有被上游屏蔽的风险）。放行名单、两步验证这些，按原落地机的做法重新配一遍：只允许本地出口 IP、前置机和各节点机连 SSH。
2. 装 Docker：

   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

3. 用 7-Zip 解开 `newapi_*.7z`，**严格按包里的 `RESTORE.md` 做**：
   - 数据目录放回 `one-api.db`；
   - 镜像版本以 `system/image-tag.txt` 为准，**不要用 `latest`**；
   - `docker run` 用 RESTORE.md 里那段从 `system/container-inspect.json` 生成的命令（环境变量、端口、挂载照原容器）。2026-09-30 之前的包，RESTORE.md 里是手写示例，会漏掉原机另加的环境变量，要对照 inspect 补上。
   - 后台**要用正式域名登录**：人机验证和通行密钥都绑定了域名，用 `IP:3000` 打开登不上。等前置机的隧道接好、或按第 5 节的办法让浏览器把域名解析到新机后再登。
4. 如果 IP 变了，在前置机上：
   - 改 `/etc/systemd/system/newapi-tunnel.service` 里的目标 IP 和端口，然后：

     ```bash
     systemctl daemon-reload && systemctl restart newapi-tunnel
     ```

   - 改 `/etc/ops-scripts/env.conf` 里的 `NEWAPI_HOST` 和 `NEWAPI_SSH_PORT`；
   - 把前置机的公钥加进新落地机的 `/root/.ssh/authorized_keys`：

     ```bash
     cat /root/.ssh/id_ed25519.pub
     ```

   - 首次连接要确认新的主机指纹：

     ```bash
     ssh -p 端口 root@新落地机IP true
     ```

5. 在新落地机上确认能访问上游。不带 key 请求时，返回 **401** 才对；返回 403 说明这个 IP 所在的地区被拒绝了：

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://api.openai.com/v1/models
   ```

6. 在 new-api 后台 → 渠道列表，每个渠道点一次"测试"。

### 4.9 LiteLLM 节点

LiteLLM 和 new-api 在同一台机器上时，那台机器没了就 4.8 和本节都做。

**LiteLLM 节点还活着**：前置机是新的话，先按 4.8 开头把新前置机的 IP 加进 LiteLLM 节点的 SSH 放行名单，其余都不用做。`env.conf` 里的 `LITELLM_HOST` 和连它用的私钥都随前置机的备份恢复了。手动跑一次确认备份能拉下来：

```bash
litellm-fullbackup.sh
```

**LiteLLM 节点也没了：**

> ⚠️ **盐值 `LITELLM_SALT_KEY` 必须用包里原来那一个。** 面板里加的模型和上游 API Key 都用它加密存在 Postgres 里，换了盐值就再也解不开，而且没有任何办法找回。**不要用 `opsget ops/deploy-litellm` 重新部署**：它会生成一套新的 `.env`，也就是新的盐值。

1. 开一台新机器。和落地机一样，**要在上游 API 支持的地区**。放行名单、两步验证按原节点的做法重新配一遍：只允许本地出口 IP、前置机和各节点机连 SSH。**前置机的 IP 一定要放行**，否则 `litellm-fullbackup` 连不上，每 6 小时失败一次。
2. 装 Docker：

   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

3. 从网盘 `Backup-LiteLLM` 下载最新的 `litellm_*.7z`，传到新机器，用 7-Zip 解开，**严格按包里的 `RESTORE.md` 做**，顺序不能乱：
   - 先把 `workdir/` 放回 `/opt/litellm`，`.env` 设成 600，compose 换成包里锁了 digest 的 `system/docker-compose.pinned.yml`；
   - 只起数据库：`docker compose up -d postgres`（服务名是 `postgres`，容器名才是 `litellm-postgres`）；
   - 用 `pg_restore --clean --if-exists` 导入 `db/litellm.dump`；
   - 再 `docker compose up -d` 起全部。**镜像不要改成 `latest`**。
4. 验证：`/health/liveliness` 返回 200；带 master key 列出的模型和包里 `db/row-counts.tsv` 对得上；**在面板里对每个模型点一次 Test**，能调通才说明盐值是对的（模型列表本身不加密，列得出来不代表凭据能解开）。
5. 如果 IP 变了，在前置机上：
   - 改 `/etc/ops-scripts/env.conf` 里的 `LITELLM_HOST`，端口写进 `LITELLM_SSH_PORT` 或 `/root/.vps-hosts.txt`；
   - 把前置机的公钥加进新节点的 `/root/.ssh/authorized_keys`（放行名单见第 1 步），首次连接确认新的主机指纹：

     ```bash
     ssh -p 端口 root@新节点IP true
     ```

   - 前置机到 LiteLLM 的隧道、Nginx 反代里的目标 IP 也要改；
   - 手动跑一次 `litellm-fullbackup.sh`，确认新节点的备份能拉下来。

### 4.10 恢复备份体系

1. **网盘授权还能不能用：**

   ```bash
   rclone lsd onedrive: && rclone lsd gdrive:
   ```

   报授权错误的话，在电脑上装 rclone，运行 `rclone authorize "onedrive"`（Google Drive 是 `drive`），按提示在浏览器里登录；再在服务器上运行 `rclone config reconnect onedrive:`，把得到的令牌粘贴进去。
2. **告警邮件**（第 4.6 节恢复后已经确认过的话，这里再发一封确认即可）：

   ```bash
   opsget ops/mail-doctor --send
   ```

3. **每个备份脚本手动跑一次**，看有没有告警：

   ```bash
   vw-fullbackup.sh
   ```

   ```bash
   xboard-fullbackup.sh
   ```

   ```bash
   newapi-fullbackup.sh
   ```

   ```bash
   litellm-fullbackup.sh
   ```

4. **确认云端最新的包都能解开：**

   ```bash
   verify-backup-pass.sh
   ```

5. **定时任务**：恢复时已经按新频率装好了。确认一下：

   ```bash
   crontab -l
   ```

6. **心跳**：心跳地址随 `env.conf` 一起恢复了。等下一次定时备份跑完，到 Healthchecks.io 上确认四个检查项都是绿色。

### 4.11 收尾

- 删掉 `/root/pkgs/` 里的备份包，以及恢复时的临时目录。
- 电脑上下载的备份包也删掉。

---

## 5. 大演练：在临时机上完整走一遍

**目的**：确认第 4 节的流程真的能走通，并且知道恢复大约要多久。

**什么时候做**：上线新的备份方案、或备份 / 恢复脚本有大改动之后做一次，不设固定周期。

**做法：完全照第 4 节做，只有以下不同：**

| 第 4 节的步骤 | 演练时 |
| --- | --- |
| 4.3 开新机器 | 开一台**按小时计费**的 Debian 12 就行，配置可以低一些（比如 2 核 4G）。**最好换一家商家** |
| 4.6 正式恢复 | 命令末尾加 `--drill`：不装定时任务，不启用 systemd 单元，所以隧道不会去连生产环境的落地机；容器不许主动连外网，恢复出来的 Xboard、Komari 不会给用户发邮件、往告警渠道发通知（Vaultwarden 的网站图标、发信测试因此会失败，属于预期） |
| 4.6 重启 SSH | 也要做一遍，顺带验证密钥、两步验证、放行名单这三道关在新机器上都正常 |
| 4.7 切换 DNS | **不做**，也不改任何 hosts 文件。用下面「用浏览器检查站点的办法」看；Cloudflare 里可以登录进去**只看不改**，确认每条记录在哪、代理状态、估一下改完要多久 |
| 4.8、4.9 | 只演前置机时**不做**（LiteLLM 另有单独的演练，见本节最后）。要演整套，另开一台上游支持地区的临时机当落地机 / LiteLLM，按 4.8、4.9「也没了」做，见下面「整套演练」 |
| 4.10 | **只做只读的**：`rclone lsd`、`verify-backup-pass.sh`、下载一份面板整机备份用 `7z t` 测能解开。**绝不跑任何 `*-fullbackup.sh`**：rclone 授权随包恢复，一跑就往生产网盘写包、按保留期删云端的包 |
| 4.11 | 不做 |

**演练机上的另外三条红线**：

- **不启用 `komari-agent`**：它用原机的凭据连生产 Komari，一启动演练机就冒充原机上报。`--drill` 不启用单元，恢复后用 `systemctl is-active komari-agent` 确认是 inactive。
- **先清空心跳地址**：恢复出来的 `env.conf` 带着生产的 Healthchecks 心跳，演练机上任何脚本误触发都会打乱生产的监控。恢复后第一时间执行 `sed -i -E 's/^([A-Z_]*HEARTBEAT_URL)=.*/\1=/' /etc/ops-scripts/env.conf`（teardown 会还原 env.conf）。
- 演练机上是解密后的全量生产数据：SSH 只放自己的出口 IP，不开商家的快照 / 备份功能，当天销毁。

演练恢复的命令：

```bash
time restore-from-backup.sh restore /root/pkgs/srvbak_*.7z /root/pkgs/xboard_*.7z --drill 2>&1 | tee /root/drill-restore.log
```

演练里的每个脚本都用 `2>&1 | tee /root/drill-<步骤>.log` 留一份完整输出。告警原文会在收尾的「完成（N 条告警）」下面再列一遍（公共库 1.2.8 起），但前面的明细只在日志里；终端往回翻不到，机器一销毁就没了（2026-09-30 的演练里 teardown 报了 1 条告警，事后查不到是哪条）。

要检查的：Vaultwarden 能登录、密码条目都在；XBoard 后台能登录，用户和节点都在；宝塔面板能登录，站点和反向代理都在；Komari 能打开，服务器列表都在。另外再跑一次 `opsget migrate/08-post-start-check`。

**用浏览器检查站点的办法**（电脑、演练机的 hosts 都不改）：把电脑的 443 经 SSH 转到演练机，再开一个**只在这个窗口里**把这些域名解析到本机的独立 Chrome。代理客户端开着全局接管（TUN）也没关系：只有这几个域名走本机，其他网站照常。

1. 电脑上开通道（窗口保持打开，挂着不动是正常的；Windows 普通用户也能占 443）：

   ```bash
   ssh -o ServerAliveInterval=30 -N -L 443:127.0.0.1:443 -p <SSH端口> root@演练机IP
   ```

2. 另开一个 PowerShell，开独立 Chrome。**参数必须整体写成一个字符串、规则加引号**：`Start-Process -ArgumentList` 给数组时不会给带空格的参数加引号，规则会被拆散，Chrome 把拆出来的词当网址打开，**实际连的是 DNS 上的生产机**（真机演练里踩过）：

   ```powershell
   $d = '域名1','域名2','域名3'
   $r = ($d | ForEach-Object { "MAP $_ 127.0.0.1" }) -join ','
   Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList "--user-data-dir=`"$env:TEMP\drill-chrome`" --no-proxy-server `"--host-resolver-rules=$r`" --no-first-run https://Komari的域名/"
   ```

3. **判断连的是演练机**：Komari 的服务器全部显示离线（各台机器的探针还在向生产机上报）。显示在线就说明连到了生产机，先别往下看。拿不准时在电脑上看 Chrome 有没有连本机 443：`Get-NetTCPConnection -State Established -RemotePort 443 | ? RemoteAddress -in '127.0.0.1','::1'`。
4. 一律用 `https://` 打开（本机 80 可能被别的程序占着）。看完：关浏览器、结束 SSH 通道，删掉 `$env:TEMP\drill-chrome`。

**注意事项**（2026-09-29 首次演练踩过的）：

- **演练期间生产机上只跑只读命令。** 在两台机器之间切换窗口时，每条命令先看一眼提示符是哪台机器（那次演练里误停过几分钟生产机的 nginx）。
- **国内直连海外的演练机，SSH 可能被干扰**（表现为 `connection closed by foreign host`）。换个网络，或经某台节点机中转。
- **Vaultwarden 在演练机上登不进是预期的**：演练拦了容器外连，「新设备登录通知」邮件发不出去，登录就被拒绝。这时两步验证其实已经通过了，再用**同一个**验证码重试会被防重放拒绝，页面显示「无效的验证码」，别被误导。要验证登录，在演练机上临时关掉这一项（只改演练机，teardown 会删掉），等手机上的验证码换一个新的再登。用 python 改 JSON（原先的 `sed` 按固定写法匹配，真机上没改到）：

  ```bash
  cd /opt/vaultwarden/data && python3 -c "import json;p='config.json';d=json.load(open(p));d['require_device_email']=False;json.dump(d,open(p,'w'),indent=2)" && docker restart vaultwarden
  ```

- **SSH 三道关**：重启 SSH 后端口是原机的；密钥登录不要验证码；密码登录先输验证码（手机上原机那个条目），再输**演练机自己的 root 密码**（系统密码不随包恢复，忘了就在演练机上 `passwd root` 重设）。输错几次 fail2ban 就会封 IP，被封了在已登录的窗口里 `fail2ban-client set sshd unbanip <IP>`。
- **面板里不要改 MySQL 的 root 密码。** 面板里存的是原机的 root 密码，演练不改本机 root，所以面板的「数据库」页连不上是正常的；在面板里改 root 会顺手重启 MySQL，还会让 `teardown` 连不上库。
- **宝塔面板自己的告警照常会发**（比如「面板登录提醒」发到微信）：面板是宿主机上的程序，不受容器外连限制，收到来自演练机的提醒是正常的。

**整套演练**（前置机 + 落地机 + LiteLLM，验证「前置机 → 隧道 → 落地机 → 上游」整条链路）：

1. 另开一台上游支持地区的临时机，按 4.8、4.9「也没了」恢复 new-api 和 LiteLLM（服务只绑 127.0.0.1）。它的 SSH 要放行演练前置机的 IP；前置机上恢复出来的私钥就是原机那把，这台装了同一把公钥就能连。
2. **不要启用恢复出来的 `newapi-tunnel` / `litellm-tunnel` 单元**（它们指向生产），在演练前置机上手开一条临时隧道代替：

   ```bash
   ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -L 127.0.0.1:3000:127.0.0.1:3000 -L 127.0.0.1:4000:127.0.0.1:4000 root@演练落地机IP
   ```

3. 在演练前置机上 `curl --resolve <new-api 域名>:443:127.0.0.1 https://<new-api 域名>/api/status`，返回 JSON 就说明 nginx → 隧道 → 落地机通了；再用上面的浏览器办法以管理员登录 new-api，在「渠道」逐个点「测试」。
4. 收尾时 `pkill -f 'ssh -f -N .*演练落地机IP'`，再 teardown、销毁两台机器。

**首次演练（2026-09-29，Vultr 东京 2 核 4G）**：从开机器到服务在本机都能访问约 65 分钟，其中系统初始化约 20 分钟、装面板与软件约 30 分钟、恢复脚本本身 1 分 11 秒。发现的问题（nginx 没重载、Komari 指标库账号缺失、teardown 没停容器、面板反向代理项目不在包里、两个包重复处理）都已修复。

**第二次演练（2026-09-30，整套：香港 4 核 8G 前置机 + 首尔 2 核 4G 落地机）**：按「三台同时没了、只能用网盘的包和手存的密码」模拟。从假定出事到全部服务可用并验证约 3 小时：前置机各服务约 2 小时 5 分，经隧道的 new-api / LiteLLM 约 2 小时 33 分，浏览器 → 前置机 → 落地机 → OpenAI 真实调用成功。宝塔安装 46 分钟，恢复脚本 2 分 22 秒。发现的问题：备份依赖在 `--drill` 下没装、rclone 从 apt 装到 1.60（OneDrive 下载失败）、new-api 的 RESTORE.md 漏环境变量——已在 `restore-from-backup` 1.5.0、`preflight-backup` 2.1.0、`newapi-fullbackup` 1.2.0、`lib/common.sh` 1.2.7 修复；云镜像不许 root 登录、安全组没提前放行原机 SSH 端口、浏览器启动参数被拆散连到生产、Vaultwarden 的 `sed` 没改到——已写进本手册。另外确认：主机密钥恢复为原机的、两步验证用手机原条目即可、首尔能正常调用 OpenAI 等上游。

**结束：**

```bash
restore-from-backup.sh teardown 2>&1 | tee /root/drill-teardown.log
```

先把日志取回电脑：演练机上 `tar czf /root/drill-logs.tgz /root/drill-*.log`，电脑上 `scp -P <SSH端口> root@演练机IP:/root/drill-logs.tgz .`（Windows 的 scp 不认 `*`，所以先打成一个包）。确认收尾处列出的告警都看过了，再在商家后台**销毁这台机器**。

**记下来**：日期、总耗时（从开机器到服务能用）、脚本列出的手动步骤、遇到的问题、各步骤的告警原文。

**LiteLLM 单独演练**：不用开整套大演练，有一台空闲机器就行。首次上线 LiteLLM 备份后、或改了 LiteLLM 部署之后做一次。在前置机上：

```bash
opsget ops/litellm-drill restore <备用机IP>
```

```bash
opsget ops/litellm-drill verify <备用机IP>
```

它按包里 `RESTORE.md` 的步骤在备用机上恢复一份，再和线上比行数、列模型。然后照 `verify` 最后给的隧道命令进面板，对模型点 Test，确认盐值是对的。看完清理：

```bash
opsget ops/litellm-drill teardown <备用机IP>
```

脚本拒绝对 LiteLLM 生产节点、落地机和前置机本机动手。

---

## 6. 不在备份范围内的东西

| 项目 | 现状 | 出事时怎么办 |
| --- | --- | --- |
| Xboard 的代理节点机器 | 不在这套备份里 | 面板域名不变的话，节点会自己重新连上；域名变了，要在每台节点上重新指定面板地址 |
| Komari 的历史监控数据（`metrics` 库） | 按设计只在本地保留，不上传云端 | 恢复脚本建一个空库、照原机恢复它的账号，Komari 启动时自己建表，监控历史从零开始记录 |
| 宝塔面板的证书自动续期 | 包里有 Nginx 配置、证书文件、面板的站点记录（`panel/data/`）和反向代理项目（`/www/server/proxy_project`），续期记录不一定对得上 | DNS 生效后逐个站点重新申请证书（第 4.6 节）。面板里有东西没恢复出来时，用每周的面板整机备份（网盘 `BTBackup-AllServer`，最近 3 份，7z 加密、同一个密码）在面板「设置 → 备份还原」里导入 |
| 开发电脑上的东西 | 仓库在 GitHub 上 | 重新克隆：`git clone https://github.com/MAXLYEN/ops-scripts.git` |
