# 版本迭代记录

各文件独立编号。本次按现有头注释建立目录记录；旧注释未标日期的版本保持日期未记载，不补造历史。

## 2026-09-24：注释与目录文档整理

| 文件 | 原版本 → 当前版本 | 变更 |
| --- | --- | --- |
| `apply-newapi-quota-fix.sh` | 1.2.0 → 1.2.1 | 精简注释，执行逻辑未变 |
| `bind-localhost.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `check-llm-security.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `cleanup-purge.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `cleanup-tidy.sh` | 1.1.0 → 1.1.1 | 精简注释，执行逻辑未变 |
| `compare-backup-content.sh` | 1.0.3 → 1.0.4 | 精简注释，执行逻辑未变 |
| `containerize-and-pin.sh` | 1.1.0 → 1.1.1 | 精简注释，执行逻辑未变 |
| `decommission-archive.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `deploy-litellm.sh` | 1.2.0 → 1.2.1 | 精简注释，执行逻辑未变 |
| `diag-key.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `fix-newapi-fallback-quota.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `fix-newapi-quota-data.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `komari-metrics-check.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `mail-doctor.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `newapi-drill.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `newapi-linkcheck.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `newapi-log-prune.sh` | 1.0.1 → 1.0.2 | 精简注释，执行逻辑未变 |
| `panel-backup-upload.sh` | 1.0.2 → 1.0.3 | 精简注释，执行逻辑未变 |
| `panel-cron-inspect.sh` | 2.0.2 → 2.0.3 | 精简注释，执行逻辑未变 |
| `panel-data-locate.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `preflight-backup.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `push-keys.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `restore-cron.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |
| `save-fw.sh` | 2.0.0 → 2.0.1 | 精简注释，执行逻辑未变 |
| `script-inventory.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `setup-key-login.sh` | 1.0.0 → 1.0.1 | 精简注释，执行逻辑未变 |
| `ssl-audit.sh` | 2.1.1 → 2.1.2 | 精简注释，执行逻辑未变 |
| `sync-llm-allowlist.sh` | 2.0.2 → 2.0.3 | 精简注释，执行逻辑未变 |
| `upgrade-vaultwarden.sh` | 1.2.0 → 1.2.1 | 精简注释并修正帮助输出 |
| `verify-backup-pass.sh` | 2.0.1 → 2.0.2 | 精简注释，执行逻辑未变 |

历史条目仅迁移原脚本头部已有的版本说明。保留在正文中的注释用于解释关键判断或写入配置文件。

## 既有版本（日期未记录）

### `apply-newapi-quota-fix.sh`

- **1.2.0**：落地机地址、端口、数据目录、容器名改从 env.conf 读 —— 原来写死在脚本里，
  而本仓库公开托管，等于把落地机 IP 与 SSH 端口一起推了上去。
  ssh 用户沿用 backup/newapi-fullbackup 的约定，固定 root@，不另设键。
- **1.1.0**：第 3 步补上 quota_data 的重算 —— logs 与 users 改了之后，看板读的是
  按小时预聚合的 quota_data，不跟着改就会一直显示旧的虚高金额。

### `check-llm-security.sh`

- **1.0.1**：第 2 项的 find 补上 *block* —— 原来只匹配文件名含 allow/deny 的，
  blocklist.conf 两个词都不占，内容打不出来，等于漏看了真正生效的封禁配置。

### `cleanup-tidy.sh`

- **1.1.0**：① 只列出真正会被删的类别。原来「共 2，保留最新 2」这种行照样打印，
  看着像要清理、实际删 0 个 —— 一眼分不出该不该跑 --apply。
  无需清理的类别折叠成末尾一行。
  ② 汇总打印可回收数量与体积。TOTAL 一直在累加却从没输出过，
  预演最该回答的问题（能腾出多少）反而看不到。
  ③ 新增 vpsscore 采集产物一节：collect.sh 每跑一次就新增一批
  JSON 与 route.txt，原来完全不在扫描范围，只能手工清。

### `compare-backup-content.sh`

- **1.0.3**：结尾那句「只有体积差、清单一致 = 等价」原本无条件打印，有差异时会和
  上面的差异列表一起出现，同屏两个相反结论，看的人容易被后一句带偏。
  改为按清单是否有差异分别给结论。
- **1.0.2**：差异判定不再把 diff 放进 if 的管道 —— lib/common.sh 设了 pipefail，
  管道退出码取最右边的非零值，而 diff 在「有差异」时返回 1（这是它的正常
  结果，不是错误），于是有差异反而走 else，打印「文件清单完全一致」。
  结论方向正好是反的，最危险。改为先把差异落成文件，按文件是否为空判定。
- **1.0.1**：① 密码键跟上 backup/*.sh 2.3.x：BACKUP_PASS_FILE 优先，VW_PASS_FILE 回落。
  原来只认 VW_PASS_FILE，旧键一旦清掉就会掉到 BACKUP_PASS_FILES（复数，
  是另一个键——密码文件**列表**）取第一项，多半是别的密码文件，
  于是报「解包失败」，人会以为是备份包坏了，而不是脚本取错了密码。
  ② 补 -h/--help；原来给任何非法参数都只吐一行 die，看不到用法。

### `containerize-and-pin.sh`

- **1.1.0**：三个服务目录与两个自检域名改从 env.conf 读 —— 原来写死，而本仓库公开托管。

### `decommission-archive.sh`

- **2.0.0**：**重写为自包含**，不再依赖 lib/common.sh 与 env.conf。
  理由和 init/ 一样：这个脚本的使用场景就是「机器即将退役」，
  不该假设它装了什么。缺配置就自动探测，探不到就跳过并说明。

### `deploy-litellm.sh`

- **1.2.0**：目标机 IP、工作目录、端口改从 env.conf 读 —— 原来写在头部常量区，
  而本仓库公开托管；操作说明里的 new-api 地址也改成按 env 打印。
  PG_VERSION / REDIS_VERSION 是技术选型，仍留在脚本内。
- **1.1.0**：凭据改由面板添加：不再询问上游 Key，config.yaml 不再写 model_list

### `komari-metrics-check.sh`

- **2.0.0**：不再交互式输入用户名密码（会出现在 shell 历史与终端里），
  改用 --defaults-file 读凭据；库名与预期保留期从 env.conf 取

### `mail-doctor.sh`

- **1.0.1**：失败计数把 exitcode=EX_OK 也算进去了，导致"1 成功 1 失败"被报成"2 次失败"

### `newapi-drill.sh`

- **1.0.1**：状态文件的值加引号（含空格的时间戳 source 时被当成命令）；脱敏改为按值判断，
  原先按 key 名匹配会把 false/true/5 这类布尔与短数字也打码，看着像有值其实没有

### `newapi-log-prune.sh`

- **1.0.1**：终止状态补 succeeded —— 接口实际返回的就是这个词，原来只判
  completed/success/finished，任务早已成功却一直轮询到 300 秒超时。

### `panel-backup-upload.sh`

- **1.0.2**：上传那行原本写成 if rclone copy ...; then :; fi —— 两个分支都不做事，
  退出码被丢弃，这个 if 写了等于没写。判据本就是下面的 rclone check，
  直接调用即可，少一层会让人误以为这里在判成功与否的壳。
- **1.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `panel-cron-inspect.sh`

- **2.0.2**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.0.1**：修正"没有日志文件"的措辞 —— 手动触发不会产生日志，日志重定向写在 crontab 行里

### `panel-data-locate.sh`

- **2.0.0**：特征串与面板路径改为参数/配置驱动，不再写死域名

### `preflight-backup.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `restore-cron.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

### `ssl-audit.sh`

- **2.1.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
- **2.1.0**：原头注释未写明改动原因。
  · 第 5 节的域名来源改用 resolve_domains() —— 原来直接 for dom in $DOMAINS，
  配置漂移时既会对废域名误报，也会静默漏掉没列进配置的真站点
  · 通配符证书覆盖的域名跳过 HTTP-01 目录检查。通配符签发只能走 DNS-01，
  对它检查 .well-known 目录必然误报
- **2.0.1**：结论按实际检测结果分支（原来无条件打印"不会续期"）；
  站点根目录改为从 vhost 配置里查，兼容多域名共用一个站点的情况

### `sync-llm-allowlist.sh`

- **2.0.2**：401 过滤规则里补注释，说明为何不能匹配 [日期]（便于日后改动时不踩回去）。
- **2.0.1**：① IP 提取不再用 tr 删空白 —— tr 会把换行一并删掉，整份清单粘成一行且末尾
  无换行，while read 直接返回非零，循环一次都不执行，机群 IP 静默为 0。
  ② failregex 不再匹配 [日期]：fail2ban 匹配前会把识别到的时间戳从行里摘除，
  方括号变空，[^\]]+ 必然失配，结果是 0 matched。

### `upgrade-vaultwarden.sh`

- **1.2.0**：compose 路径与备份目录改从 env.conf 读 —— 原来写死，而本仓库公开托管。
  GH_REPO / IMAGE_REPO 是上游项目标识、BAK 是脚本自己的工作目录，仍留在脚本内。

### `verify-backup-pass.sh`

- **2.0.1**：头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）

后续更新按文件记录版本、日期、改动原因和行为变化。
