# 灾难恢复手册

适用场景：前置机（汇总机）、落地机任意一台或全部失联，**开发电脑也用不了**，手边什么都没有。按本文从零做，就能把服务恢复成原样。

本文放在公开仓库里，**不写任何真实的密码、IP、域名**。这些都放在第 2 节说的「应急包」里，由你离线保管。

目录：

1. [恢复靠什么：信任链](#1-恢复靠什么信任链)
2. [应急包：必须离线保存的东西](#2-应急包必须离线保存的东西)
3. [应急包怎么保存、怎么更新](#3-应急包怎么保存怎么更新)
4. [小演练：每月 5 分钟验证应急包](#4-小演练每月-5-分钟验证应急包)
5. [恢复流程：从零开始](#5-恢复流程从零开始)
6. [大演练：在临时机上完整走一遍](#6-大演练在临时机上完整走一遍)
7. [不在备份范围内的东西](#7-不在备份范围内的东西)

---

## 1. 恢复靠什么：信任链

```
应急包（离线保存，本文第 2 节）
  ├─ 网盘账号 ──────────→ 下载加密备份包（OneDrive、Google Drive 各一份）
  ├─ 备份解密密码 ──────→ 解开备份包 ──→ 包里的一切：
  │                                        env.conf、rclone 网盘授权、告警邮件配置、
  │                                        SSH 密钥（含登录落地机的私钥）、MySQL 全部账号、
  │                                        证书、Nginx、面板数据、各服务数据、定时任务
  ├─ VPS 商家账号 ──────→ 买新机器、用控制台登录
  ├─ Cloudflare 账号 ───→ 把域名解析改到新机器
  └─ Vaultwarden 主密码 → 恢复后打开密码库，其余账号密码都在里面
```

**要点：备份包里什么都有，但包是加密的，而且在网盘上。** 离线只需要保存"打开第一把锁"的东西：能登录网盘、能解开包、能买机器、能改 DNS。

**绝不能只存在 Vaultwarden 里的东西**：备份解密密码、网盘账号、Vaultwarden 主密码。Vaultwarden 本身就在要恢复的包里，这些只存在它里面，就成了死循环。

---

## 2. 应急包：必须离线保存的东西

### 🔴 没有就无法恢复

| 项目 | 为什么需要 | 从哪里取 |
| --- | --- | --- |
| **备份解密密码** | 所有备份包（vw、xboard、new-api）都用它加密，AES-256，文件名也加密了 | 前置机 `/root/.vw_backup_pass` 的内容，也就是 `env.conf` 里 `BACKUP_PASS_FILE` 指向的文件 |
| **网盘账号**：微软账号（OneDrive）、Google 账号（Google Drive），各自的密码和**两步验证恢复码** | 下载备份包。两个网盘各有一份，**至少要能登上其中一个** | 你自己的账号。恢复码在账号安全设置里生成 |
| **Cloudflare 账号**：密码和两步验证恢复码 | 把域名解析改到新机器 | 同上 |
| **VPS 商家账号**：前置机、落地机、LiteLLM 节点所在的每一家，都要有密码和两步验证恢复码 | 买新机器；用网页控制台登录旧机器；开工单 | 同上 |
| **Vaultwarden 主密码**（开了两步验证的话，再加恢复码） | 恢复后打开密码库，其余账号密码都在里面 | 你自己记着的 |
| **应急包自身的主密码** | 打开应急包（见第 3 节） | 你自己设的，**写在纸上** |

### 🟡 没有会很麻烦

| 项目 | 为什么需要 | 从哪里取 |
| --- | --- | --- |
| **服务器清单** | 恢复时要知道：有哪几台机器、各在哪家商家、IP、SSH 端口，哪个域名对应哪个服务，宝塔、MySQL、Nginx 的版本 | 在前置机上运行第 3.2 节的命令，把输出存进应急包 |
| **管理用 SSH 私钥**，设了口令就连口令一起 | 从新电脑登录现有的机器，比如落地机还活着的时候 | 开发电脑的 `~/.ssh/`。**没有也能恢复**：用商家网页控制台登录，再添加新电脑的公钥 |
| **GitHub 账号**和恢复码 | 仓库是公开的，恢复时不用登录；只有要改脚本、发版时才用得上 | 同上 |
| **域名注册商账号** | 域名续费；要把域名转到别的 DNS 服务时 | 同上 |
| **宝塔面板的入口地址、账号、密码** | 恢复后登录面板。**忘了也能重置**：以 root 身份运行 `bt`，选修改面板密码 | 面板设置页 |
| **Healthchecks.io 账号**（心跳监控） | 恢复后确认心跳正常；修改监控周期 | 同上 |
| **告警邮箱的登录方式** | 接收备份告警邮件 | 同上。发信用的 SMTP 配置在备份包里，这里说的是收信邮箱的登录 |

### 🟢 包里已经有，放进应急包只是方便对照

| 项目 | 说明 |
| --- | --- |
| `env.conf` 副本 | vw 和 xboard 的备份包里都有（`rootfs/etc/ops-scripts/env.conf`；vw 包另有 `system/env.conf`）。里面有 `NEWAPI_ROOT_PAT` 和心跳地址，**只能放在加密的应急包里** |
| 最近一份备份包的离线副本（U 盘） | 网盘账号出问题时的最后退路。不用每次都更新，每季度更新一次就够 |

### 不需要单独保存（都在加密的备份包里）

rclone 的网盘授权（`rclone.conf`）、告警邮件配置（`/etc/msmtprc`）、MySQL 的 root 和各账号密码、Xboard 的 `APP_KEY` 和数据库密码文件、SSH 主机密钥、登录落地机的私钥、隧道单元、证书、面板数据。

---

## 3. 应急包怎么保存、怎么更新

### 3.1 推荐做法

1. 装 **KeePassXC**（免费、开源、离线），新建一个数据库文件作为应急包，比如 `emergency.kdbx`。设一个**主密码**，写在纸上。
2. 把第 2 节的🔴和🟡项目都存进去：密码、恢复码存成条目；服务器清单、`env.conf` 副本存成附件或备注；SSH 私钥存成附件。
3. **保存 3 份，彼此互不依赖：**
   - U 盘，放在家里；
   - 手机（KeePassXC 有安卓和 iOS 版可以打开）；
   - 一个**跟这套备份无关**的地方，比如发到另一个邮箱当附件，或者存到另一个网盘账号。**不要只放在 OneDrive 或 Google Drive 里**：它们的登录密码本身就在应急包里。
4. **纸上**写下这三样：应急包主密码、备份解密密码、至少一个网盘账号的恢复码。放在家里安全的地方。
5. 可选：注册一个 Bitwarden 官方云的免费账号，把 Vaultwarden 定期导出一份进去（加密的 `.json`），作为密码库的第二份，不依赖你自建的服务器。

### 3.2 从前置机取内容

以下命令都是**只读**的。在前置机上以 root 身份运行，把输出复制进应急包。

**备份解密密码：**

```bash
cat "$(. /etc/ops-scripts/env.conf; echo "${BACKUP_PASS_FILE:-$VW_PASS_FILE}")"
```

**`env.conf` 副本：**

```bash
cat /etc/ops-scripts/env.conf
```

**服务器清单：**

```bash
{
  echo "== 本机"; hostname; curl -s -m 5 ifconfig.me; echo
  echo "== 固定的版本"; cat /etc/ops-scripts/ref 2>/dev/null
  echo "== 软件版本"; /www/server/mysql/bin/mysql -V 2>/dev/null; nginx -v 2>&1; docker --version
  echo "== 宝塔"; cat /www/server/panel/class/common.py 2>/dev/null | grep -m1 -oE 'g\.version *= *.[0-9.]+'
  echo "== 其他机器（~/.vps-hosts.txt）"; cat /root/.vps-hosts.txt 2>/dev/null
  echo "== 落地机与网盘"; grep -E '^(NEWAPI_HOST|NEWAPI_SSH_PORT|NEWAPI_DATA_DIR|LITELLM_HOST|RCLONE_REMOTES|RCLONE_PATHS|VW_REMOTE_PATH|XBOARD_REMOTE_PATH|NEWAPI_CLOUD_DIR)=' /etc/ops-scripts/env.conf
  echo "== 站点"; ls /www/server/panel/vhost/nginx/*.conf 2>/dev/null | xargs -n1 basename
  echo "== 容器"; docker ps --format '{{.Names}}  {{.Image}}'
  echo "== 定时任务"; crontab -l
}
```

**落地机上的 new-api 信息**（在落地机上运行）：

```bash
hostname; curl -s -m 5 ifconfig.me; echo; docker ps --format '{{.Names}}  {{.Image}}'; docker inspect new-api --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

### 3.3 什么时候更新应急包

**当天就要更新：**
- 改了任何一个🔴项目：备份密码、网盘、Cloudflare、商家账号的密码，或者重新生成了两步验证恢复码；
- 换了机器、换了 IP、换了商家；
- 增删了站点或服务。

**其余情况**：每季度对照一次第 3.2 节的输出。

---

## 4. 小演练：每月 5 分钟验证应急包

最容易出问题的不是脚本，而是**应急包里的密码对不上**：改过密码忘了更新，或者当初抄错了一位。这个演练就是专门检查这一点的。

**用手机或者另一台电脑，只靠应急包做：**

1. 打开应急包（验证主密码没问题）；
2. 用应急包里的账号登录 OneDrive 网页版，打开 `Backup-Server` 目录，下载最新的 `srvbak_*.7z`；
3. 用 7-Zip（手机上用 ZArchiver 之类的软件）打开它，输入应急包里的**备份解密密码**；
4. 能看到 `RESTORE.md`、`manifest.txt`、`payload.tar.gz` 三个文件，就算通过。打开 `manifest.txt` 看一眼备份时间，应该是最近几个小时内的；
5. 删掉下载的文件。

**任何一步不通过，当天就把应急包修好。**

另外，前置机上每周一有 `verify-backup-pass` 定时任务，会在服务器上自动检查云端最新的包能不能解开。这个小演练检查的是**你手里的**应急包。两者都要做。

---

## 5. 恢复流程：从零开始

下面按"前置机彻底没了"来写。只是落地机没了的话，直接看第 5.9 节。

### 5.0 新电脑上的准备（约 10 分钟）

1. 安装 **KeePassXC** 和 **7-Zip**。Windows 10/11 自带 `ssh` 和 `scp`；macOS 和 Linux 也都自带。
2. 打开应急包。
3. 生成新电脑的 SSH 密钥：

   ```bash
   ssh-keygen -t ed25519
   ```

   公钥在 `~/.ssh/id_ed25519.pub`（Windows 上是 `C:\Users\<你>\.ssh\id_ed25519.pub`）。

### 5.1 判断范围

| 情况 | 做什么 |
| --- | --- |
| 前置机没了，落地机正常 | 5.2 到 5.8，然后 5.10、5.11 |
| 落地机没了，前置机正常 | 只做 5.9 |
| 两台都没了 | 全部都做 |

先到商家后台看一眼机器还在不在，能不能用网页控制台（VNC）登录，能不能开工单。**只是暂时连不上的话**，先用第 5.8 节的方法把 new-api 临时切到备用通道，等商家处理，不一定要重建。

### 5.2 下载备份包

登录 OneDrive 网页版（进不去就换 Google Drive），从三个目录里各下载**最新**的一份：

| 目录 | 文件 | 旁边的校验文件 |
| --- | --- | --- |
| `Backup-Server` | `srvbak_YYYYMMDD_HHMMSS.7z` | — |
| `Backup-Xboard` | `xboard_YYYYMMDD_HHMMSS.7z` | — |
| `Backup-NewAPI` | `newapi_YYYYMMDD_HHMMSS.7z` | `.sha256`，也一起下载 |

先用 7-Zip 打开 `srvbak_*.7z`，看一下 `manifest.txt`，记下里面的 **MySQL 和 Nginx 版本**，下一步装环境时要用。

### 5.3 开新机器

- 系统选 **Debian 12**；配置不低于原来那台（服务器清单里有）。
- 商家有"SSH 密钥"选项的话，填 5.0 生成的公钥。没有的话，先用商家给的 root 密码登录，然后执行：

  ```bash
  mkdir -p ~/.ssh && echo '<你的公钥>' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
  ```

- 恢复时，脚本会把 `/root/.ssh` 换成原机的，**但会把恢复前就能登录的公钥加回去**，所以新电脑的密钥不会失效。

### 5.4 系统初始化

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

### 5.5 装环境

1. **宝塔面板**：用宝塔官网给的 Debian 安装命令。装好后在面板里安装 **MySQL（跟 `manifest.txt` 里的大版本一样，原机是 5.7）**和 **Nginx**。
2. **Docker**：

   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

### 5.6 最小配置

MySQL 的 root 凭据。密码用**新机器**的，在宝塔面板的"数据库"页面能看到：

```bash
printf '[client]\nuser=root\npassword="新机器的MySQL root密码"\n' > /root/.my.cnf && chmod 600 /root/.my.cnf
```

备份解密密码，从应急包里复制：

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

### 5.7 恢复

在**新电脑**上把包传到新机器：

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

### 5.8 切换 DNS

登录 Cloudflare，把服务器清单里的**所有域名**的 A 记录都改成新机器的 IP。代理状态（灰色还是橙色云朵）保持原样。

**临时备用通道**：落地机上装了 `cloudflared`，平时没有 Public Hostname，不对外服务。前置机挂了、落地机还活着的时候，可以先在 Cloudflare 的 Zero Trust → Tunnels 里，给 new-api 的域名加一个 Public Hostname，服务填 `http://localhost:3000`，几分钟就能让 new-api 先恢复使用。**加之前要先删掉这个域名原来的 A 记录。**正式恢复完成后，删掉这个 Public Hostname，再把 A 记录加回来。

### 5.9 落地机（new-api）

**落地机还活着**：什么都不用做。隧道单元和私钥都随备份恢复了，检查一下：

```bash
systemctl status newapi-tunnel --no-pager
```

```bash
curl -s http://127.0.0.1:3000/api/status | head -c 100
```

**落地机也没了：**

1. 开一台新的落地机。**必须是日本、美国这类上游 API 支持的地区**，而且**不能用国内厂商**（有被上游屏蔽的风险）。
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

### 5.10 恢复备份体系

1. **网盘授权还能不能用：**

   ```bash
   rclone lsd onedrive: && rclone lsd gdrive:
   ```

   报授权错误的话，在新电脑上装 rclone，运行 `rclone authorize "onedrive"`（Google Drive 是 `drive`），按提示在浏览器里登录；再在服务器上运行 `rclone config reconnect onedrive:`，把得到的令牌粘贴进去。
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

### 5.11 收尾

- **更新应急包**：新的 IP、商家；在新机器上重新运行第 3.2 节的命令，把输出存进去。
- 删掉 `/root/pkgs/` 里的备份包，以及恢复时的临时目录。
- 在新电脑上，把新的管理 SSH 私钥存进应急包。

---

## 6. 大演练：在临时机上完整走一遍

**目的**：确认第 5 节的流程和你的应急包真的能用，并且知道恢复大约要多久。

**频率**：首次上线新的备份脚本之后做一次，之后每半年一次；脚本有大改动时也要做。

**做法：完全照第 5 节做，只有以下不同：**

| 第 5 节的步骤 | 演练时 |
| --- | --- |
| 5.3 开新机器 | 开一台**按小时计费**的 Debian 12 就行，配置可以低一些（比如 2 核 4G）。**最好换一家商家** |
| 5.7 正式恢复 | 命令末尾加 `--drill`：不装定时任务，不启用 systemd 单元，所以隧道不会去连生产环境的落地机 |
| 5.8 切换 DNS | **不做**。改用电脑上的 hosts 文件，把域名临时指向临时机来检查；**只看不改**，看完马上删掉 hosts 里加的那几行 |
| 5.9、5.10、5.11 | **不做** |

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

**记录下来**（存进应急包）：日期、总耗时（从开机器到服务能用）、脚本列出的手动步骤、遇到的问题。

---

## 7. 不在备份范围内的东西

| 项目 | 现状 | 出事时怎么办 |
| --- | --- | --- |
| **LiteLLM 节点**（LiteLLM、Postgres、Redis） | **没有任何备份** | 用 `opsget ops/deploy-litellm` 重新部署；模型、密钥这些配置要重新填写 |
| Xboard 的代理节点机器 | 不在这套备份里 | 面板域名不变的话，节点会自己重新连上；域名变了，要在每台节点上重新指定面板地址 |
| Komari 的历史监控数据（`metrics` 库） | 按设计只在本地保留，不上传云端 | 恢复后从零开始记录 |
| 宝塔面板的站点记录和证书自动续期 | 包里只有 Nginx 配置和证书文件 | 在面板里"添加站点"，然后逐个站点重新申请证书（第 5.7 节） |
| 开发电脑上的东西 | 仓库在 GitHub 上 | 重新克隆：`git clone https://github.com/MAXLYEN/ops-scripts.git` |
