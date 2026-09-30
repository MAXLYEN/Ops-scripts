# 日常运维

本目录包含巡检、部署、修复、清理与演练脚本。每支脚本的执行条件与版本号见头注释；需要配置的脚本保留 `ENV-REQUIRED` 声明，`opsget -e ops/<脚本名>` 可查看缺失的配置项。

## 检查与诊断

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `check-llm-security.sh` | 1.0.3 | 只读盘点 LiteLLM 与 new-api 的访问控制 |
| `compare-backup-content.sh` | 1.0.5 | 比对两个加密备份包的内容清单 |
| `diag-key.sh` | 1.1.0 | 诊断指定主机的 SSH 密钥登录失败原因 |
| `komari-metrics-check.sh` | 2.0.2 | 检查 Komari 指标库的保留期与增长速度 |
| `mail-doctor.sh` | 1.0.3 | 诊断告警邮件的配置与发送链路 |
| `panel-cron-inspect.sh` | 2.0.5 | 查看面板计划任务的真实命令与运行状态 |
| `panel-data-locate.sh` | 2.0.2 | 定位面板数据在磁盘上的存储位置 |
| `preflight-backup.sh` | 2.1.0 | 检查备份脚本运行前的依赖与配置 |
| `save-fw.sh` | 2.0.2 | 在修改防火墙前保存当前配置快照 |
| `script-inventory.sh` | 1.0.2 | 盘点本机脚本并区分仓库来源与本地文件 |
| `ssl-audit.sh` | 2.1.2 | 核对证书文件、站点引用与续期记录 |
| `verify-backup-pass.sh` | 2.2.0 | 验证本地密码能否解开云端备份包，并检查最新包是否过旧 |


### 云端备份每周校验

备份脚本每次只做 `7z t` 自检，证明的是「刚打好的包能解开」；云端的包有没有损坏、密码文件和包还对不对得上、备份是否早已悄悄停止上传，要另外验证。`verify-backup-pass.sh --cron` 对每个 `RCLONE_REMOTES × RCLONE_PATHS` 取最新包下载解开，最新包超过 `VERIFY_MAX_AGE_DAYS`（默认 2 天）也算失败；失败时按「邮件 → webhook → 落盘」发告警，配了 `VERIFY_HEARTBEAT_URL` 还会上报心跳。超过 `VERIFY_MAX_MB` 的包不下载，只在汇总里注明。

```bash
opsget -i ops/verify-backup-pass
( crontab -l 2>/dev/null; echo '0 6 * * 1 /usr/bin/flock -n /run/verify-backup-pass.lock /usr/local/bin/verify-backup-pass.sh --cron >> /var/log/verify-backup-pass.log 2>&1' ) | crontab -
```

每周一 06:00（UTC）运行，排在凌晨备份之后。`RCLONE_PATHS` 要列全所有备份目录（`Backup-Server Backup-Xboard Backup-NewAPI Backup-LiteLLM` 这类）。漏列时：本机装了的备份脚本（vw / xboard / newapi / litellm）的云端目录会自动并入本次校验，并在输出与汇总里提示补进 `RCLONE_PATHS`；其余目录（如面板整机备份）漏了就不会被校验。不带 `--cron` 手动运行时只输出结果，不发告警。

### 备份定时任务

```bash
opsget ops/install-backup-cron            # 预演：显示改后的 crontab 与差异
opsget ops/install-backup-cron --apply    # 写入
```

`vw-fullbackup`、`xboard-fullbackup`、`litellm-fullbackup` 每 6 小时（分别在 :00、:20、:40，不同时上云），`newapi-fullbackup` 每小时 :05。只给 `/usr/local/bin` 里已装的备份脚本排任务；每个脚本一把 `flock -n` 锁 `/var/lock/<脚本>-cron.lock`（原有行带锁就沿用，换表那一刻正在跑的备份仍互斥，菜单的「立即备份」也读这把锁；但不用 `/run/lock/<脚本>.lock` —— 那是备份脚本自己的锁，外层拿了它，脚本一启动就会撞上退出），输出进 `/var/log/<脚本>-cron.log`，没有 `PATH=` 时补上。原有调用这几个脚本的行（包括不该有的 `opsget backup/…`）一律替换，其他行不动；可以反复运行，改之前的 crontab 存在 `/root/ops-backups/`。`migrate/restore-from-backup` 恢复时会自动调用它。上一次还没跑完时本次直接跳过、不报心跳，外部心跳监控的周期要跟着改成 6 小时 / 1 小时（加宽限）。

## 部署与日常维护

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `bind-localhost.sh` | 2.1.1 | 将容器端口映射从公网绑定改为本机绑定 |
| `containerize-and-pin.sh` | 1.1.1 | 把服务改为 compose 管理并锁定镜像 digest |
| `decommission-archive.sh` | 2.0.1 | 在机器退役前归档最终状态与数据 |
| `deploy-litellm.sh` | 1.2.4 | 部署 LiteLLM、Postgres 与 Redis 容器 |
| `panel-backup-upload.sh` | 1.0.5 | 加密并上传面板生成的整机备份包 |
| `panel-backup-create.sh` | 1.0.0 | 照面板上次的设置生成整机备份，加密上传，本机与云端各留最近几份 |
| `ssh-allowlist.sh` | 1.1.2 | 本机 SSH 只放行名单里的 IP（ufw）；菜单里新增、删除，改完当场验证，不确认就回滚 |
| `push-keys.sh` | 1.0.4 | 按主机清单批量下发 SSH 公钥 |
| `install-backup-cron.sh` | 1.3.0 | 按统一时间表安装备份定时任务（幂等） |
| `restore-cron.sh` | 2.0.2 | 从快照恢复仓库管理的 cron 任务 |
| `setup-key-login.sh` | 1.0.2 | 配置新机器的 SSH 密钥登录并验证 |
| `sync-llm-allowlist.sh` | 2.0.4 | 同步 LLM 站点白名单与 fail2ban 规则 |
| `upgrade-vaultwarden.sh` | 1.2.1 | 检查并升级 Vaultwarden，锁定镜像 digest |

## LiteLLM

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `litellm-drill.sh` | 1.0.0 | 在备用机上演练 LiteLLM 备份包的恢复、核对与清理 |

```bash
opsget ops/litellm-drill restore <备用机IP> [包路径]   # 不给包就从网盘取最新的 litellm_*.7z
opsget ops/litellm-drill verify <备用机IP>             # 与线上比行数、列模型、查日志里的解密错误
opsget ops/litellm-drill teardown <备用机IP>           # 删掉演练实例；目标机原本没有 docker 就卸载
```

在汇总机运行，备用机的 SSH 端口从 `~/.vps-hosts.txt` 取。拒绝 `LITELLM_HOST`、`NEWAPI_HOST` 与本机；目标机已有 litellm 容器、`/opt/litellm`（或 `LITELLM_WORKDIR`）、上次没清的 `/opt/litellm-drill`，或端口被占时也拒绝。恢复严格按包里 `RESTORE.md` 的顺序：`.env` 先放回（600），只起 `postgres`，`pg_restore --clean --if-exists`，再按包里锁了 digest 的 compose 起全部并等 `/health/liveliness`。容器名与生产相同（`litellm`、`litellm-postgres`、`litellm-redis`），工作目录是 `/opt/litellm-drill`；teardown 只删带演练标记的目录。模型列表只能证明库导进去了，盐值对不对要在面板里对模型点 Test，`verify` 会给出隧道命令。

## new-api 数据与链路

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `apply-newapi-quota-fix.sh` | 1.3.1 | 停止 new-api 后修正消费统计并校验回传；`--dry-run` 在在线备份的副本上完整演练 |
| `fix-newapi-fallback-quota.sh` | 1.0.1 | 修正 new-api 兜底倍率造成的虚高消费 |
| `fix-newapi-quota-data.sh` | 1.1.0 | 按已修正的日志重算 new-api 配额统计（按组合汇总核对，兼容拆行） |
| `fix-newapi-reprice.sh` | 1.0.0 | 按后台当前价格重算指定模型的历史消费（日志、用户、令牌） |
| `newapi-drill.sh` | 1.0.4 | 在备用机演练 new-api 备份的恢复与清理 |
| `newapi-linkcheck.sh` | 1.0.3 | 检查 new-api 隧道和公网访问全链路 |
| `newapi-log-prune.sh` | 1.0.3 | 清理超过保留期的 new-api 消费日志 |

## 清理

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `cleanup-purge.sh` | 1.0.7 | 按安装台账移除 ops-scripts 及其产物 |
| `cleanup-tidy.sh` | 1.1.2 | 清理历史输出、旧版备份与中间产物 |

## 操作约定

`cleanup-tidy.sh`、`cleanup-purge.sh` 和 `bind-localhost.sh` 默认先预演，带 `--apply` 才执行。涉及数据库修正的 `fix-newapi-*.sh` 应在容器停止并完成备份后使用；`apply-newapi-quota-fix.sh` 串联停服、拉库、修正、校验和恢复。

改了模型价格、要把历史消费按新价格重算时：先 `apply-newapi-quota-fix.sh --reprice <模型1,模型2> --align-tokens --dry-run` 预演（在线备份一份副本，在副本上把修正、看板表重算和传回前的全部校验完整跑一遍，不停容器），看过明细再去掉 `--dry-run` 执行。价格从库里读（表达式计费 → 按次价格 → 倍率，与 new-api 的优先级相同），不写死在脚本里；动手前先用每条表达式计费日志自带的表达式重算、与实际扣费比对，对不上超过 2% 就拒绝。仍按兜底倍率 37.5 计费的记录一起按其模型的当前价格重算，模型没有价格时用 `--map 旧名=参考名` 指定。用户额度只改「已用额度原本等于日志合计」的用户（只有渠道测试记录的管理员不改）；`--align-tokens` 把令牌已用额度对齐到它名下日志的合计，日志被清理过的库不要用。灾难恢复演练 `newapi-drill.sh`、`litellm-drill.sh` 只在备用机运行，并拒绝生产目标。

`containerize-and-pin.sh` 保留改名前的旧容器以便回滚，并锁定当前镜像 digest，不执行升级。`deploy-litellm.sh` 将容器端口绑定本机；加入模型后 `LITELLM_SALT_KEY` 必须保持不变，丢失该密钥将无法解开已加密的凭据；它随 `backup/litellm-fullbackup` 的加密包备份（包里的 `workdir/.env`）。`panel-backup-upload.sh` 默认用 7z 加密，`--raw` 会上传未加密原包；`--prune N` 只清理本机上传台账 `/var/lib/ops-scripts/panel-backup-uploaded.list` 里的包，不碰其他服务器的文件。`ssh-allowlist.sh` 的名单是 `~/.vps-hosts.txt` 里的机器、`ADMIN_IPS`、`ALLOW_EXTRA_IPS`（与 `sync-llm-allowlist` 同一套来源），按 `sshd -T` 的端口加 `ufw allow from <IP> ... comment 'ssh-allowlist'`，加完才删不限来源的 allow / limit 规则；只增删自己打过注释的规则，其他端口不动。在终端里直接运行进菜单：带编号列出名单，选新增（写进 `ADMIN_IPS`）或删除（从 `ADMIN_IPS`、`ALLOW_EXTRA_IPS`、`~/.vps-hosts.txt` 里一并去掉，机群里的机器会提示其他脚本也在用），先看改完的防火墙变化、确认后才写配置并执行，执行后当场问新窗口能不能登录：输 `yes` 保留，输别的或 270 秒内不输就回滚防火墙、这次改的配置也改回（运行菜单的窗口断了时，定时回滚与 `--rollback` 同样连配置一起改回；新窗口能登录就在新窗口里 `--confirm`）；不能删当前会话的来源。命令行等价写法 `--add <IP>` / `--remove <IP>`，没有终端时（或 `--preview`）只预演；`--apply` 前备份 `/etc/ufw/user*.rules` 到 `/root/ops-backups/ufw.<时间>` 并用 `systemd-run` 布置 5 分钟后自动回滚，另开窗口登录成功后 `--confirm` 取消，`--rollback` 立即回滚。当前会话的来源 IP 不在名单里时拒绝执行；有一条放行没加上时不删全开的规则。`panel-backup-create.sh` 由 `install-backup-cron` 排在每周日 UTC 19:30：复制面板「设置 → 备份还原」里最近一次备份的任务配置（备份内容一致）、换新时间戳，前台运行面板自带的 `backup_manager.py backup_data`，出了包再交给 `panel-backup-upload --prune`；本机按时间戳只留最近 `PANEL_BACKUP_KEEP` 份（包、工作目录、面板里的任务记录一起删，面板手动建的也算在内）。面板里至少要手动建过一次备份，它照那次勾选的内容备份；失败时告警、心跳 `/fail`，本机旧包不动。`cleanup-purge.sh` 默认保留 crontab 正在调用的脚本、`BACKUP_SCRIPTS` 及它们依赖的 `env.conf` 与 `ops-common.sh`，`PURGE_CRON_SCRIPTS=1` 才一并删除。

`sync-llm-allowlist.sh` 的 fail2ban/ufw 封禁会影响所有端口，`ignoreip` 需覆盖整组可信机器，并检查 nginx 的 allow/deny 顺序。`upgrade-vaultwarden.sh` 即使回退 compose 配置也未必能回退数据库迁移，升级前须有近期备份。

无人值守任务调用已安装的本地脚本；升级和有破坏性的操作先确认备份与回滚方式。版本记录见 [CHANGELOG.md](CHANGELOG.md)。
