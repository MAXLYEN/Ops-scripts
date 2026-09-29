# 灾难恢复手册

**适用场景：原来的机器已经彻底用不了**，开不了机、登不上、数据拿不出来，开发电脑可能也不在手边。按本文从零做，在任何一家商家的新机器上，把服务恢复成原样。

**原机器还活着**，只是想换机器、换商家的话，不要用本文，用一键迁移（见仓库 `migrate/` 目录）。两套方案的区别：

| | 极端恢复（本文） | 一键迁移 |
| --- | --- | --- |
| 什么时候用 | 原机已经没了 | 原机还能登录，计划内换机 |
| 数据从哪来 | 网盘上最近一次的备份包 | 迁移时从原机现做一份，直接传到新机 |
| 会丢什么 | 最近一次备份之后的改动（vw、xboard 最多 6 小时，new-api 最多 1 小时） | 不丢 |

本文放在公开仓库里，**不写任何真实的密码、IP、域名**。

目录：

1. [恢复靠什么](#1-恢复靠什么)
2. [唯一需要手动保存的：备份解密密码](#2-唯一需要手动保存的备份解密密码)
3. [小演练：每月 5 分钟](#3-小演练每月-5-分钟)
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

所有备份包（vw、xboard、new-api，以及之后的 LiteLLM）**都用同一个密码加密**。它存在前置机的 `/root/.vw_backup_pass` 里，也就是 `env.conf` 中 `BACKUP_PASS_FILE` 指向的文件。

**这个文件不会进任何备份包**（否则拿到包的人就同时拿到了钥匙），所以它**必须手动保存**。在前置机上查看：

```bash
cat "$(. /etc/ops-scripts/env.conf; echo "${BACKUP_PASS_FILE:-$VW_PASS_FILE}")"
```

**保存要求：**
- **至少两处，而且都不能只依赖 Vaultwarden**，比如一张纸，加上手机里的一条离线备忘。Vaultwarden 就在要恢复的备份包里，只存在它里面就成了死循环。
- **不要轻易换这个密码**。换了之后，旧的包仍然只能用旧密码打开。真要换，旧密码也要一直留着，直到旧包全部过期删完（云端最长保留 400 天）。

**其他一切都不需要单独保存**：MySQL 各账号密码、Xboard 的 `APP_KEY` 和数据库密码、rclone 授权、邮件配置、SSH 密钥、证书、`env.conf`、服务器清单，都在加密包里。

---

## 3. 小演练：每月 5 分钟

检查"手里保存的密码"和"网盘上的包"对不对得上。这是整套方案里最容易出问题、又最容易检查的一环。

**用手机或者另一台电脑做：**

1. 登录 OneDrive 网页版，打开 `Backup-Server` 目录，下载最新的 `srvbak_*.7z`；
2. 用 7-Zip（手机上用 ZArchiver 之类的软件）打开，输入**手动保存的备份解密密码**；
3. 能看到 `RESTORE.md`、`manifest.txt`、`payload.tar.gz` 三个文件，就算通过。打开 `manifest.txt` 看一眼备份时间，应该是最近几个小时内的；
4. 删掉下载的文件。

**打不开的话，当天就处理**：先去前置机上重新确认密码。

另外，前置机上每周一有 `verify-backup-pass` 定时任务，会在服务器上自动检查云端最新的包能不能解开。它检查的是服务器上的密码文件，这个小演练检查的是**你手里保存的**那份。两者都要做。

---

## 4. 恢复流程：从零开始

下面按"前置机彻底没了"来写。只是落地机没了的话，直接看第 4.8 节。

### 4.0 准备一台能用的电脑，以及 SSH 登录的三道关

1. 安装 **7-Zip**。Windows 10/11 自带 `ssh` 和 `scp`；macOS 和 Linux 也都自带。
2. **SSH 登录要过三道关**，恢复前先确认每一道都过得去：

| 关卡 | 现状 | 恢复时 |
| --- | --- | --- |
| **密钥** | 前置机和所有节点机用的是**同一把密钥**，不用新建 | 把这把私钥放到这台电脑的 `~/.ssh/`（Windows 是 `C:\Users\<你>\.ssh\`）。私钥存在 **Vaultwarden** 里（服务器挂了也能从已登录客户端的缓存里取），本地另有两份 |
| **Google 两步验证** | 登录时除了密钥，还要输手机验证器里的 6 位验证码 | TOTP 密钥随备份包恢复（`/root/.google_authenticator`），**手机上原来那个验证器条目继续可用，不用重新绑定**。手机丢了的话：备份包里 `rootfs/root/.google_authenticator` 文件末尾那几行 8 位数字是一次性应急码，每个只能用一次 |
| **来源 IP 放行名单** | 每台机器用 **ufw** 只允许**本地出口 IP、前置机、各节点机**连 SSH（规则在 `/etc/ufw`，随备份包恢复）。本地 IP 变了的话，先连上某台节点机的代理，再从它那里登录 | 见第 4.6 节最后和第 4.8 节：新前置机的 IP 要加进其他机器的名单；恢复出来的名单里要有你现在的 IP |

**刚开的新机器还没有恢复，所以没有两步验证，也没有放行名单**，只用密钥（或商家给的 root 密码）就能登录。恢复完成、重启 SSH 之后，三道关才全部生效。

### 4.1 判断范围

| 情况 | 做什么 |
| --- | --- |
| 前置机没了，落地机正常 | 4.2 到 4.7，然后 4.9、4.10 |
| 落地机没了，前置机正常 | 只做 4.8 |
| 两台都没了 | 全部都做 |

**前置机没了、落地机还活着的时候**，可以先用落地机上的 Cloudflare 备用通道，让 new-api 几分钟内恢复使用，见第 4.7 节最后。

### 4.2 下载备份包，读出服务器清单

登录 OneDrive 网页版（进不去就换 Google Drive），从三个目录里各下载**最新**的一份：

| 目录 | 文件 |
| --- | --- |
| `Backup-Server` | `srvbak_YYYYMMDD_HHMMSS.7z` |
| `Backup-Xboard` | `xboard_YYYYMMDD_HHMMSS.7z` |
| `Backup-NewAPI` | `newapi_YYYYMMDD_HHMMSS.7z`，旁边的 `.sha256` 也一起下载 |

用 7-Zip 打开 `srvbak_*.7z`，再打开里面的 `payload.tar.gz`。**恢复需要的信息都在这里：**

| 文件 | 看什么 |
| --- | --- |
| `manifest.txt` | 原机的 **MySQL、Nginx 版本**，有哪些站点，有哪些容器 |
| `rootfs/etc/ops-scripts/env.conf` | 落地机的 IP 和 SSH 端口（`NEWAPI_HOST`、`NEWAPI_SSH_PORT`）、网盘目录名等 |
| `rootfs/root/.vps-hosts.txt` | 其他机器的清单 |
| `system/nginx/` | 所有站点的域名（每个 `.conf` 文件对应一个站点），切 DNS 时要用 |

### 4.3 开新机器

- 系统选 **Debian 12**；配置不低于原机（在 `manifest.txt` 里看原机用了多少资源，宁可高一点）。
- 商家有"SSH 密钥"选项的话，填**原来那把密钥的公钥**。没有的话，先用商家给的 root 密码登录，然后执行：

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

1. **宝塔面板**：用宝塔官网给的 Debian 安装命令。装好后在面板里安装 **MySQL（跟 `manifest.txt` 里的大版本一样，原机是 5.7）**和 **Nginx**。
2. **Docker**：

   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

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

**脚本最后会列出"还要手动做的事"，以那份清单为准。** 常见的有：
- 在宝塔面板里"添加站点"，认领已经恢复的 Nginx 配置（面板的站点记录在它自己的数据库里）；
- DNS 生效后，在面板里逐个站点重新申请证书（EC256）；
- 确认没问题后，删掉恢复用的临时目录。里面是解开的明文数据库导出和密钥。

**切 DNS 之前**，先做一遍端到端检查：

```bash
opsget migrate/08-post-start-check
```

**重启 SSH 或重启机器之前（很重要，否则可能把自己锁在外面）：**

恢复出来的 SSH 配置、防火墙都是原机的，**恢复脚本故意没有重载它们**。重载之前：

1. **放行名单**：脚本会检查你当前这个 SSH 会话的 IP 在不在原机的放行名单里。不在的话，"还要手动做的事"里会给出一条 `ufw allow from <你的IP> to any port <端口> proto tcp`，**先执行它**。
2. **两步验证**：原机开了 Google 两步验证的话，脚本已经自动装好了 PAM 模块，并用 `sshd -t` 检查过配置。
3. **保持当前这个 SSH 窗口不断开**，然后重载：

   ```bash
   systemctl restart ssh && ufw reload && systemctl restart fail2ban
   ```

4. **另开一个窗口**，用密钥加手机验证码登录（端口是原机的 SSH 端口，可能跟现在不一样）。**能登录上，再关掉旧窗口。**登不上的话，回到旧窗口排查。

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
   - `docker run` 的参数照包里的写。
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

### 4.9 恢复备份体系

1. **网盘授权还能不能用：**

   ```bash
   rclone lsd onedrive: && rclone lsd gdrive:
   ```

   报授权错误的话，在电脑上装 rclone，运行 `rclone authorize "onedrive"`（Google Drive 是 `drive`），按提示在浏览器里登录；再在服务器上运行 `rclone config reconnect onedrive:`，把得到的令牌粘贴进去。
2. **告警邮件：**

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

4. **确认云端最新的包都能解开：**

   ```bash
   verify-backup-pass.sh
   ```

5. **定时任务**：恢复时已经按新频率装好了。确认一下：

   ```bash
   crontab -l
   ```

6. **心跳**：心跳地址随 `env.conf` 一起恢复了。等下一次定时备份跑完，到 Healthchecks.io 上确认三个检查项都是绿色。

### 4.10 收尾

- 删掉 `/root/pkgs/` 里的备份包，以及恢复时的临时目录。
- 电脑上下载的备份包也删掉。

---

## 5. 大演练：在临时机上完整走一遍

**目的**：确认第 4 节的流程真的能走通，并且知道恢复大约要多久。

**频率**：首次上线新的备份脚本之后做一次，之后每半年一次；脚本有大改动时也要做。

**做法：完全照第 4 节做，只有以下不同：**

| 第 4 节的步骤 | 演练时 |
| --- | --- |
| 4.3 开新机器 | 开一台**按小时计费**的 Debian 12 就行，配置可以低一些（比如 2 核 4G）。**最好换一家商家** |
| 4.6 正式恢复 | 命令末尾加 `--drill`：不装定时任务，不启用 systemd 单元，所以隧道不会去连生产环境的落地机 |
| 4.6 重启 SSH | 也要做一遍，顺带验证密钥、两步验证、放行名单这三道关在新机器上都正常 |
| 4.7 切换 DNS | **不做**。改用电脑上的 hosts 文件，把域名临时指向临时机来检查；**只看不改**，看完马上删掉 hosts 里加的那几行 |
| 4.8、4.9、4.10 | **不做** |

演练恢复的命令：

```bash
time restore-from-backup.sh restore /root/pkgs/srvbak_*.7z /root/pkgs/xboard_*.7z --drill
```

要检查的：Vaultwarden 能登录、密码条目都在；XBoard 后台能登录，用户和节点都在；Komari 能打开，服务器列表都在。另外再跑一次 `opsget migrate/08-post-start-check`。

**结束：**

```bash
restore-from-backup.sh teardown
```

然后在商家后台**销毁这台机器**。

**记下来**：日期、总耗时（从开机器到服务能用）、脚本列出的手动步骤、遇到的问题。

---

## 6. 不在备份范围内的东西

| 项目 | 现状 | 出事时怎么办 |
| --- | --- | --- |
| **LiteLLM 节点**（LiteLLM、Postgres、Redis） | **暂时还没有备份**（正在补） | 用 `opsget ops/deploy-litellm` 重新部署；模型、密钥这些配置要重新填写。**在备份补上之前**，`/opt/litellm/.env` 里的 `LITELLM_SALT_KEY` 丢了，存量凭据就再也解不开 |
| Xboard 的代理节点机器 | 不在这套备份里 | 面板域名不变的话，节点会自己重新连上；域名变了，要在每台节点上重新指定面板地址 |
| Komari 的历史监控数据（`metrics` 库） | 按设计只在本地保留，不上传云端 | 恢复后从零开始记录 |
| 宝塔面板的站点记录和证书自动续期 | 包里只有 Nginx 配置和证书文件 | 在面板里"添加站点"，然后逐个站点重新申请证书（第 4.6 节） |
| 开发电脑上的东西 | 仓库在 GitHub 上 | 重新克隆：`git clone https://github.com/MAXLYEN/ops-scripts.git` |
