# 整机迁移流程

按编号执行迁移脚本。每一步都有明确的执行机器和产物；冷快照与恢复步骤会改变服务状态，操作前先核对快照目录、配置和回滚路径。

## 阶段

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `01-inventory.sh` | 2.0.1 | 在新旧机器采集迁移前环境清单 |
| `02-nat-probe.sh` | 2.0.2 | 从外部验证迁入机的端口入站可达性 |
| `03-pre-migrate.sh` | 2.0.4 | 在迁出机停服并制作完整冷快照 |
| `04-verify-migration.sh` | 2.0.3 | 对比新旧机数据库、站点、证书与账号授权 |
| `05-fix-db-grants.sh` | 2.0.3 | 修正迁移后数据库账号的 host 授权 |
| `06-export-images.sh` | 2.0.1 | 在迁出机导出当前容器镜像 |
| `07-restore-containers.sh` | 2.0.2 | 在迁入机恢复容器数据并生成启动命令 |
| `08-post-start-check.sh` | 2.1.2 | 在迁入机执行容器与站点端到端验收 |
| `09-restore-backup-stack.sh` | 2.0.1 | 在迁入机重建备份依赖和配置 |
| `restore-from-backup.sh` | 1.0.1 | 原机已不在时，用每日加密备份包把新机恢复成原样 |

`01` 和 `04` 在新旧机各运行一次并比较输出；`02` 用迁入机监听、迁出机探测入站端口；`03` 与 `06` 在迁出机运行，其余恢复和验收步骤在迁入机运行。具体参数见各脚本头部及命令输出。

- `03` 会停服并制作全量冷快照，结束后服务保持停止。
- `05` 修正授权后不要再用面板的数据库“权限”按钮，面板可能将账号 host 重置为 `127.0.0.1`。
- `06` 导出迁出机当前镜像；迁入机不要直接拉取 `latest`，标签漂移可能触发不兼容的数据库迁移。
- `07` 只恢复文件、生成容器启动命令，需人工检查后执行。
- `08` 在切换 DNS 前通过 `--resolve` 验证 nginx、证书、反代与容器的访问路径。
- `09` 重建备份体系，但不自动恢复 cron；切换并观察正常后再用 `ops/restore-cron.sh`。

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
- **季度演练**：在临时机上 `restore --drill`，本机有任何数据就拒绝，不装定时任务（否则会从演练机往生产网盘传包并按保留期删云端旧包），不启用 systemd 单元（隧道会连到生产机）；验证完 `teardown` 删掉恢复出来的容器、库、账号、文件，替换过的系统配置从 `.bak` 放回，`env.conf` 还原，演练时装的 docker 一并卸载。正式恢复过的机器拒绝 `teardown`。
- 暂存目录 `/root/dr_restore` 里是解开的明文包（dump、密钥、证书私钥），验证完删掉。

包的两种布局都认：现有的 vw（`payload.tar.gz` 内 `db/ vaultwarden/ komari/ subconverter/ system/`）与 xboard（`db/ app/ nginx/ deploy/`），以及新布局 `rootfs/` + `restore-manifest.tsv`（列：路径、权限、属主、类型；类型有 `file` `dir` `sqlite` `systemd-unit` `mysql-db` `mysql-user` `compose-project` `crontab`）。旧版包只收 vhost 目录顶层的 `*.conf`，站点 include 的伪静态、反代配置缺失时 `nginx -t` 不通过，这时不重载并列进手动步骤；新布局收了整个面板 `vhost/`。new-api 的包不归这个脚本，用 `ops/newapi-drill`；LiteLLM 的包也不归它，正式恢复照包里的 `RESTORE.md` 在 LiteLLM 节点上做，备用机演练用 `ops/litellm-drill`。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
