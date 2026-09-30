# 整机迁移

三条路，按原机器还在不在、服务在不在备份包里挑：

| 情况 | 用什么 | 数据从哪来 | 会丢什么 | 服务中断 |
| --- | --- | --- | --- | --- |
| 原机还在，计划内换机器、换商家（前置机） | `live-migrate.sh`，**在旧机上**运行 | 切换时从旧机现做一份包，经 SSH 直传新机 | 不丢 | 从停写到 DNS 生效：出包、传包、恢复启动，加上 DNS 的 TTL |
| 原机已经没了 | `restore-from-backup.sh`，在新机上运行；完整步骤见 [灾难恢复手册](../docs/disaster-recovery.md) | 网盘上最近一次的每日加密包 | 最近一次备份之后的改动（vw、xboard 最多 6 小时） | 到恢复完成为止 |
| 服务不在 vw / xboard 的备份包里（别的机器、手工部署的服务） | 旧流程 `01`–`09`，分步做 | `03` 冷快照 | 不丢 | 从 `03` 停服到切换完成 |

new-api 落地机不走这里：演练与恢复见 `ops/newapi-drill`，换落地机见下面「不在一键迁移的范围内」。

## 文件

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `live-migrate.sh` | 1.0.0 | 原机还在：一键迁移，在旧机上运行（预检 → 演练 → 停写切换 → DNS，DNS 前可回滚） |
| `restore-from-backup.sh` | 1.3.1 | 原机已不在时，用每日加密备份包把新机恢复成原样；也是一键迁移在新机上调用的恢复步骤 |
| `01-inventory.sh` | 2.0.1 | 旧流程：在新旧机器采集迁移前环境清单 |
| `02-nat-probe.sh` | 2.0.2 | 旧流程：从外部验证迁入机的端口入站可达性 |
| `03-pre-migrate.sh` | 2.0.4 | 旧流程：在迁出机停服并制作完整冷快照 |
| `04-verify-migration.sh` | 2.0.3 | 旧流程：对比新旧机数据库、站点、证书与账号授权 |
| `05-fix-db-grants.sh` | 2.0.3 | 旧流程：修正迁移后数据库账号的 host 授权 |
| `06-export-images.sh` | 2.0.1 | 旧流程：在迁出机导出当前容器镜像 |
| `07-restore-containers.sh` | 2.0.2 | 旧流程：在迁入机恢复容器数据并生成启动命令 |
| `08-post-start-check.sh` | 2.1.2 | 在迁入机执行容器与站点端到端验收（一键迁移在新机上调用它） |
| `09-restore-backup-stack.sh` | 2.0.1 | 旧流程：在迁入机重建备份依赖和配置 |

### 01–09 怎么处理

保留，不删，作为「旧流程」；前置机换机器改用一键迁移。

- 一键迁移**不调用** `01`–`07` 与 `09`：它用备份脚本现做的完整包（`rootfs/` + `restore-manifest.tsv` + 全部账号与业务库）和 `restore-from-backup`，覆盖面比 `03` 冷快照 + `07`（只恢复 `CONTAINER_DATA_DIRS`、只生成启动命令）全。对前置机，`03` → 现做包，`06` → 包里的 `images.tsv` 按 digest 锁版本，`07` → 按还原清单全量放回并启动，`09` → 恢复时并入定时任务并统一排程，都已被取代。
- `08` 由一键迁移在新机上调用（演练后、切换后各一次）。
- 仍然有用的：服务不在备份包里的机器只能走 `01`–`09`；`01` / `04` 可以当额外核对；`02` 可以验证新机其它端口的入站可达性（一键迁移只经 443 访问站点）；`05` 在面板把账号 host 改掉时照样用。
- `03` 与一键迁移用同一个 `#MIGRATE-PAUSED ` 标记暂停备份定时任务，恢复时去掉前缀即可。

旧流程的执行位置：`01` 和 `04` 在新旧机各运行一次并比较输出；`02` 用迁入机监听、迁出机探测入站端口；`03` 与 `06` 在迁出机运行，其余恢复和验收步骤在迁入机运行。具体参数见各脚本头部及命令输出。

- `03` 会停服并制作全量冷快照，结束后服务保持停止。
- `05` 修正授权后不要再用面板的数据库“权限”按钮，面板可能将账号 host 重置为 `127.0.0.1`。
- `06` 导出迁出机当前镜像；迁入机不要直接拉取 `latest`，标签漂移可能触发不兼容的数据库迁移。
- `07` 只恢复文件、生成容器启动命令，需人工检查后执行。
- `08` 在切换 DNS 前通过 `--resolve` 验证 nginx、证书、反代与容器的访问路径。
- `09` 重建备份体系，但不自动恢复 cron；切换并观察正常后再用 `ops/restore-cron.sh`。

## 原机还在：一键迁移

在**旧机**上运行。前提：旧机能用密钥登录新机的 root（`opsget ops/setup-key-login <IP> <端口>`）；新机是 Debian 12、做完 `init/`、装好 docker、与旧机同一大版本的 MySQL（凭据文件可用）、nginx 或宝塔，`opsget` 固定到与旧机相同的版本；旧机的 `vw-fullbackup` 2.6.0 / `xboard-fullbackup` 2.5.0 起（支持 `--local-only`）。新机的 `env.conf` 与备份密码文件没有时，演练开始前从旧机复制过去（`env.conf` 已有但缺恢复要用的键时只补那几个键）。

```bash
opsget migrate/live-migrate <新机IP> --ssh-port 22 --check          # 只预检、列计划，两台都不动
opsget migrate/live-migrate <新机IP> --ssh-port 22 --rehearse-only  # 演练：旧机照常服务
opsget migrate/live-migrate <新机IP> --ssh-port 22                  # 演练 → 切换 → DNS，每段开始前确认
opsget migrate/live-migrate <新机IP> --ssh-port 22 --cutover        # 已经演练过：直接切换；切换中断了也用它接着做
opsget migrate/live-migrate <新机IP> --ssh-port 22 --dns            # 列出要改的 DNS 记录，改好后经公共 DNS 复核
opsget migrate/live-migrate status                                   # 进行到哪一步、回滚脚本在哪
opsget migrate/live-migrate rollback                                 # DNS 切换前：回到旧机
```

菜单里是「整机迁移 → 一键迁移（原机还在）」，完整迁移、切换、回滚要输主机名。

**预检**（只读，每次运行都先做）：两台机器各跑一遍同一个探测，逐项对比并拒绝不合要求的：SSH 密钥登录不通、系统不是 Debian 12、`init/` 没做完、`opsget` 没装或固定的版本不同、旧机有 docker 新机没有、MySQL 连不上或大版本（MySQL / MariaDB、主版本号）不同（小版本系列不同只告警）、旧机有 nginx / 宝塔新机没有、新机磁盘放不下（旧机的服务目录与业务库合计的 3 倍再加 1G：演练、切换各放一份，解开的包暂存一份；已演练过的按 2 倍）、旧机磁盘不够出包、两台的备份密码不同、新机上已有数据（在跑的容器、业务库、恢复记录）且不是本次迁移演练出来的、新机上有没清理的恢复演练、旧机的备份脚本太旧。拒绝时两台都不动。

**演练**（旧机照常服务，不停任何东西、不动定时任务、不上传）：

1. 旧机用装好的 `vw-fullbackup` / `xboard-fullbackup --local-only` 现做加密包到 `/root/live-migrate/pkgs`（不上传、不清理、不报心跳）
2. 经 SSH 直传新机 `/root/live-migrate-in`，新机上再算一遍 sha256 核对
3. 新机 `restore-from-backup restore <包> --no-cron`：正式恢复并起服务，但**不装定时任务**（旧机还在服务，新机不能往网盘传包、按保留期删云端的包）。新机上已有本次迁移上次恢复出来的数据时带 `--force`
4. 核对：新机 `restore-from-backup check` 逐项比对（恢复计划里还标着放置、冲突的就是没对上的）；新机 `08-post-start-check`；旧机经 `--resolve` 分别访问旧机（127.0.0.1）和新机 IP 上的每个站点，对比状态码；配了 `NEWAPI_TUNNEL_UNIT` 的，检查新机到落地机的隧道和 `NEWAPI_LOCAL_URL`
5. 新机停掉全部容器，只留数据和拉好的镜像（切换时启动快；也免得 Xboard 的定时任务在副本上给用户发邮件）

`--no-start` 让演练只放文件、导库，不在新机上起容器，这时 08 验收和逐站对比跳过。演练发现差异时，交互运行会在切换前列出差异再问；`OPS_YES=1` 自动模式不往下切换。

**切换**（再确认一次；从这里起服务中断，直到 DNS 切过去）：

1. 先写回滚脚本 `/root/live-migrate/rollback.sh`（记下此刻在跑的容器）
2. 旧机 crontab 里调用备份脚本的行（`*-fullbackup`，加上 `BACKUP_SCRIPTS` 里的）加 `#MIGRATE-PAUSED ` 前缀，别的行不动。旧机以后也不会再把停服那一刻的旧数据当成最新的包传上网盘
3. 旧机停掉全部容器（停写；MySQL、nginx 照常，出包要用 MySQL）
4. 再核对一次落地机等机器的放行名单，再做一次包（备份脚本的锁改为等上一轮结束），传到新机
5. 新机 `restore … --force` 并启动：这次装定时任务，新机接手备份
6. 新机 08 验收、逐站对比（和演练时旧机的状态码比）、隧道

新机恢复失败时停在这里：修好后 `--cutover` 接着做（沿用第一次写的回滚脚本），或回滚。

**DNS**（人工）：从 vhost（或 `DOMAINS`）列出要改的记录，经公共 DNS（DoH，默认 Cloudflare 与 Google，环境变量 `LIVE_MIGRATE_DOH` 可换）查出现在的值；AAAA 记录改成新机的 IPv6 或删掉；开了 Cloudflare 代理的改源站 IP。不接 Cloudflare API，原因与从备份包恢复相同。改好后在终端里输 `yes`（`OPS_YES` 不算；或加 `--verify-dns`）开始复核：每个域名的公共 DNS 答案要是新机 IP（或代理地址且公网访问正常）才算完成，还没生效就过一会儿再跑 `--dns --verify-dns`。复核通过后删掉新机上临时放行旧机的规则，问一次后删掉落地机等机器上旧机的放行。

**回滚**（DNS 切换前任何时候）：`live-migrate.sh rollback` 或 `bash /root/live-migrate/rollback.sh`（不依赖 ops-scripts，可以直接跑）：新机停掉全部容器并暂停备份定时任务（连不上就跳过：DNS 没切，新机没接流量）；旧机去掉备份任务的 `#MIGRATE-PAUSED ` 前缀、启动切换时停掉的容器。新机 IP 留在落地机等机器的放行名单里，放弃这次迁移的话自己删掉。回滚后可以重新演练、切换。

### SSH 放行名单

每台机器只放行名单里的 IP 连 SSH（本地出口、前置机、各节点）。Google 两步验证只管密码登录，密钥登录不问验证码，所以旧机到新机、到落地机的自动 SSH 不受它影响；要处理的只有放行名单。刚开的新机器还没有名单；恢复会把旧机的 SSH 与 ufw 配置放回新机，但**不重载**。

- **新机的名单里没有旧机**：放回的是旧机的名单（里面没有旧机自己），新机一重载防火墙或重启，旧机就连不上了。所以每次恢复之后，在新机上临时 `ufw allow` 旧机的来源 IP（当前 SSH 端口和放回的 `sshd_config` 里的端口，注释 `live-migrate <迁移ID>`），切换时的传包、验证不会被挡；DNS 复核通过后删掉
- **落地机、LiteLLM 节点与主机清单里的机器**（`NEWAPI_HOST`、`LITELLM_HOST`、`~/.vps-hosts.txt`）：它们只放行旧前置机，新前置机的隧道、new-api 与 LiteLLM 的备份拉取都会被挡。演练开始时和切换时，旧机（还在它们的名单里）逐台照自己的规则给新机的出口 IP 加上同样端口的放行；sshd 里有 `Match Address` 写着旧机 IP 的只提示、不自动改。DNS 复核通过后问一次，删掉旧机的规则（只在新机已放行的端口上删）。连不上的机器列出要手动执行的命令
- **操作者自己的 IP**：恢复脚本核对「当前 SSH 会话的来源 IP」在不在放回的名单里；经旧机转过去时那是旧机的 IP，所以一键迁移把旧机上操作者会话的来源 IP 传给它核对，不在名单里就在恢复输出的手动步骤里给出 `ufw allow` 命令，重载前先执行
- **主机密钥**：恢复后新机对外用旧机的主机密钥。本次迁移专用的 `known_hosts`（`/root/live-migrate/known_hosts`）预先记上旧机的公钥，不会报主机密钥变更
- **迁移完成前不要重启新机、不要重载新机的 SSH 与防火墙**：等 DNS 复核通过再按恢复输出的手动步骤做。真重启了，新机的 SSH 端口会变成旧机的，下次运行带 `--ssh-port <旧机端口>`

### 不在一键迁移的范围内

- **Komari 的监控历史**：指标库（`METRICS_DB_NAME`）不进包，和从备份包恢复一样从零开始：恢复时建空库、照原机恢复它的账号，Komari 启动时自己建表。要保留历史就在切换前自己 `mysqldump` 这个库、在新机导入
- **宝塔面板**里的站点记录要认领、证书续期要核对（恢复输出的手动步骤里有）
- **落地机**：new-api 容器在落地机上，前置机迁移只把隧道换成从新机连过去（并在落地机的放行名单里加上新机）。要换落地机本身：先停旧落地机的 new-api 容器，在前置机上手动跑一次 `newapi-fullbackup.sh` 拿到停写后的包；在新落地机上按包里 `RESTORE.md` 恢复（镜像版本以 `system/image-tag.txt` 为准，不用 `latest`，步骤同 [灾难恢复手册](../docs/disaster-recovery.md) 4.8「落地机也没了」）；然后在前置机上把隧道单元里的目标 IP、`env.conf` 的 `NEWAPI_HOST` / `NEWAPI_SSH_PORT` 改成新落地机，`systemctl daemon-reload && systemctl restart <隧道单元>`，`opsget ops/newapi-linkcheck` 验证；新落地机的放行名单里要有前置机

### DNS 切换之后要切回

新机已经接了写入，旧机的数据停在切换那一刻，直接把 DNS 改回去会丢掉这之间的数据，`rollback` 也会拒绝。要反过来再迁一次（新机 → 旧机）；旧机上有数据，一键迁移的预检会拒绝，所以手动做：

1. 新机：crontab 里调用备份脚本的行加 `#MIGRATE-PAUSED ` 前缀，`docker stop` 全部容器
2. 新机：`/usr/local/bin/vw-fullbackup.sh --local-only /root/back` 与 `/usr/local/bin/xboard-fullbackup.sh --local-only /root/back`
3. 把 `/root/back` 里的包传到旧机，旧机上 `opsget migrate/restore-from-backup restore <包…> --force`（旧机原有的目录留 `.bak.<时间>`，原有的库先导出再删）。它会重新排好备份定时任务，旧机上原来 `#MIGRATE-PAUSED ` 开头的行删掉即可
4. 把 DNS 改回旧机，确认公共 DNS 生效
5. 迁移完成时如果删掉了落地机等机器上旧机的放行，重新加上

### 没有在真机上验证过的

端到端测试（`tests/live-migrate.bats`）在一次性容器里真跑旧机这一侧：定时任务的暂停与恢复、容器的停启、`--local-only` 出加密包、传包与 sha 核对、回滚脚本、放行名单增删哪几条规则的判断、DNS 复核的判定。新机由假 ssh 扮演，恢复、验收、停服只记录调用顺序和参数（恢复本身由 `tests/restore.bats` 覆盖）。**没有在真实的两台机器上跑过**：两台之间的 SSH（连接复用、放行名单在 ufw 里真正生效、恢复后主机密钥切换）、MySQL 导入、Docker 启动、宝塔面板、nginx、DNS 与 DoH 查询。第一次用之前，先在两台临时机上完整走一遍（`--rehearse-only` → `--cutover` → `rollback`）。

## 原机已不在：从备份包恢复

`01`–`09` 依赖迁出机还活着（`03` 的冷快照、`06` 的镜像导出）。原机已经没了，就只剩 `backup/` 每天上传的加密包，用 `restore-from-backup.sh`。前提：新机跑完 `init/`，填好 `env.conf`、放好备份密码文件、配好 rclone，装好 MySQL（版本照包里 manifest）与宝塔 / nginx。

```bash
opsget migrate/restore-from-backup check              # 从网盘取 vw 与 xboard 的最新包，解开、校验，列出恢复计划；不动本机
opsget migrate/restore-from-backup restore            # 正式恢复
opsget migrate/restore-from-backup restore /root/srvbak_x.7z /root/xboard_y.7z   # 用本地包
```

一条 `restore` 依次做完：解密并核对 sha256 / 清单校验和 / dump 完整性 → 本机 `env.conf` 空着的键用包里原机的 `env.conf` 补上（本机填过的不动）→ 建库、导入、建账号 → 放回数据目录、compose 文件、站点配置与证书、部署元数据 → SQLite 做 `integrity_check` → 并入原机的定时任务，再由 `ops/install-backup-cron` 按统一时间表重排备份 → 按锁定的版本拉镜像、起容器，做 Xboard 的 Redis 属主修复与 `config:cache` → 启用 systemd 单元 → `nginx -t` 通过才重载 → 用 `--resolve` 预演访问每个站点 → 列出剩下的手动步骤和原因。

- **不会做的**：切 DNS（真实流量交给这台机器的最后一步，保留人工；不接 Cloudflare API，因为在演练机上误跑一次就会劫持生产流量）；宝塔面板里「添加站点」、DNS 生效后逐站重签证书（面板的站点与续期记录不在包里）；Komari 监控历史（按设计不进云端包，从零开始）。这些都会在结尾列出。
- **数据库账号**：容器用的账号建在 `DB_CLIENT_HOST`，不用 `%`、不用具体容器 IP；备份脚本经 `127.0.0.1` 连库，所以同时建一条回环账号。新布局的 `db/mysql-users.sql` 里，`%`、具体 IP、网段通配改成 `DB_CLIENT_HOST`，`localhost` / `127.0.0.1` 照旧；`mysql.*` 等系统账号、远程 root、从别处登录却对恢复的库没有授权的账号不恢复（逐个列出）；只在本机登录的管理账号（如只有全局权限的 `bkroot@localhost`）照样恢复。库的字符集与排序规则照 `db/databases.tsv`。vw 与 xboard 两个包都带的目录、文件和库，按较新的包放一次。
- **MySQL root**：面板数据整体放回后，面板里存的是原机的 root 密码。正式恢复在其余库操作做完后，把 `root@localhost` 改成原机的设置（包里没有原机的凭据文件就不改）；原机的 `MYSQL_DEFAULTS_FILE`（可能用 root，也可能用 `bkroot` 这类本机管理账号）先拿来试连，连得上才换上（新机原来的留 `.bak.<时间>`），连不上就保留新机的并列进手动步骤。演练不动 root。
- **本机已有的东西怎么处理**：业务数据（compose 项目目录里的、SQLite、库、账号、在跑的项目）算冲突；系统配置（`/etc` 下、SSH、ufw、面板、证书、站点）原有的留 `.bak.<时间>` 后替换，不拦；工具箱自身（`opsget`、`opsbox`、公共库、正在跑的这个脚本）、`/etc/ops-scripts/ref`、rclone 与数据库凭据保留本机的，原机的另存 `.from-backup`；`env.conf` 只补空键。`/root/.ssh` 换成原机的之后，把恢复前本机能登录的公钥并回去，免得把自己锁在外面。SSH、ufw、fail2ban 的新配置不自动重载（端口若与现在不同会断开当前会话），列为手动步骤：核对后重启机器。
- **镜像版本**：来自包里的 `images.tsv`（RepoDigest）或 manifest 的容器列表；compose 里是 `latest` 的，Vaultwarden 按 manifest 里的版本号锁定。锁不住的项目不启动（绝不拉 `latest`，新版启动时的数据库迁移会改掉按旧版恢复的库），用 `--image 容器名=镜像@sha256:…` 指定后重跑。
- **已有数据**：有上面说的冲突时直接拒绝；加 `--force` 才覆盖，原有目录移到 `.bak.<时间>`，原有库先导出到暂存目录再删。
- **可以重跑**：状态记在 `/var/lib/ops-scripts/dr-restore.state`。同一批包重跑时，已恢复过的跳过（服务跑起来后改过的数据目录不会被覆盖）、导了一半的库删掉重导、crontab 不重复。
- **`--no-cron`**：正式恢复并启动，但不装定时任务（不并入原机的定时任务、不排备份）。原机还在服务时的迁移演练用（一键迁移就是这样调用的），接手服务时不带它再恢复一次。
- **季度演练**：在临时机上 `restore --drill`，本机有任何数据就拒绝，不装定时任务（否则会从演练机往生产网盘传包并按保留期删云端旧包），不启用 systemd 单元（隧道会连到生产机），起容器前在 `DOCKER-USER` 链拒绝容器主动外连（容器用的是生产数据，不拦会给真实用户发提醒邮件、往告警渠道发离线通知；写成开机自启、排在 docker 之前的 `ops-drill-egress` 单元，加不上就不起容器）；验证完 `teardown` 先停掉恢复出来的容器（停不下就中止，外连限制、库和文件都不动），再删库、账号、文件，撤掉外连限制，替换过的系统配置从 `.bak` 放回，`env.conf` 还原，演练时装的 docker 一并卸载。正式恢复过的机器拒绝 `teardown`。
- 暂存目录 `/root/dr_restore` 里是解开的明文包（dump、密钥、证书私钥），验证完删掉。

包的两种布局都认：现有的 vw（`payload.tar.gz` 内 `db/ vaultwarden/ komari/ subconverter/ system/`）与 xboard（`db/ app/ nginx/ deploy/`），以及新布局 `rootfs/` + `restore-manifest.tsv`（列：路径、权限、属主、类型；类型有 `file` `dir` `sqlite` `systemd-unit` `mysql-db` `mysql-user` `compose-project` `crontab`）。旧版包只收 vhost 目录顶层的 `*.conf`，站点 include 的伪静态、反代配置缺失时 `nginx -t` 不通过，这时不重载并列进手动步骤；新布局收了整个面板 `vhost/`。new-api 的包不归这个脚本，用 `ops/newapi-drill`；LiteLLM 的包也不归它，正式恢复照包里的 `RESTORE.md` 在 LiteLLM 节点上做，备用机演练用 `ops/litellm-drill`。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
