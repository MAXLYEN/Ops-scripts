# ops-scripts

服务器迁移与日常运维脚本集。所有环境相关的值（域名、IP、端口、容器名、路径、库名）都在 `config/env.conf` 里，**脚本本身不含任何环境信息**，因此可以公开托管。

## 快速开始

```bash
# 1. 装引导器
curl -fsSL https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget \
  -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget

# 2. 生成配置（首次）
opsget -c            # 拉取 env.example.conf 到 /etc/ops-scripts/env.conf
vi /etc/ops-scripts/env.conf

# 3. 用
opsget -l                          # 列出可用脚本
opsget migrate/01-inventory        # 拉取并执行
opsget -i ops/preflight-backup     # 只安装到 /usr/local/bin，不执行
```

路径写成 `migrate/03-pre-migrate` 或 `migrate/03-pre-migrate.sh` 都可以，参数直接跟在后面：`opsget ops/cleanup-tidy --apply`。

注意 `-i` 是 opsget 自己的选项，要写在路径**前面**。`opsget ops/ssl-audit -i` 会把 `-i` 当成传给脚本的参数，照常执行。

## 脚本清单

**看 [MANIFEST](MANIFEST)，或在机器上跑 `opsget -l`。**

这里不再重复列表——两处维护必然漂移，实测过：README 的编号和实际差了一位，两个脚本改过名，整个 `vpsscore/` 目录漏掉了，照 README 敲会 404。

## 目录

```
bin/opsget              引导器：拉取、安装、执行
lib/common.sh           公共函数库
config/env.example.conf 配置模板
init/                   新机初始化，按编号顺序执行
migrate/                整机迁移流程，按编号顺序执行
backup/                 生产备份（每天 cron 跑）
ops/                    日常运维
db/                     数据库相关维护
vpsscore/               VPS 质量评估：采集 + 打分
```

`init/` 与 `vpsscore/` 有一点不同：**它们不依赖 `lib/common.sh`**。这些脚本要能在一台什么都没有的新机（或刚开的裸机）上单跑，少一个依赖就少一个失败点。它们也不强制要求 `env.conf` —— 没有就用内置默认值，有就以配置为准。`ops/decommission-archive` 出于同样理由是自包含的：它的使用场景就是「机器即将退役」，不该假设它装了什么。

## 两个顺序执行的流程

**新机初始化**：`00` →(需要则重启)→ `01` → `02` → `03` →(重启)→ `04`

```bash
opsget init/run          # 列出阶段与当前状态
opsget init/run 03       # 执行指定阶段
```

**跑 03 之前务必确认带外控制台能进。** 脚本布置了 5 分钟自动回滚兜底，但那是最后一道保险，不是第一道。调度器在 03 之前也会强制确认第二个 SSH 窗口已就绪。

**整机迁移**：`migrate/` 下按编号顺序，配合《服务器整机迁移教程》使用。每个脚本头部写明了该在哪台机器跑（迁出机 / 迁入机 / 两台各一次），MANIFEST 里也有一句话说明。

## 配置文件

真实配置在 **`/etc/ops-scripts/env.conf`**，权限 `600`，**永远不进仓库**（`.gitignore` 已排除）。

脚本在缺少配置项时会直接 `die`，不会回落到任何默认值——这是刻意的：宁可报错，也不要用错误的值静默执行。

### 清单类配置优先留空

`DOMAINS` 和 `XBOARD_SITES` 留空时会**自动扫描 vhost 目录**，面板上增删域名不用回来改配置。

填了则按列表走，并与实际情况**双向比对**后告警：

- 列了但 vhost 里没有 → 站点已删，配置该清理（噪音）
- vhost 里有但没列 → **这些站点不会被检查**（致命）

第二种才是真问题：漏掉的站点压根不进循环，输出还是全绿，看起来像"检查过了"。实测踩过——证书审计里一个已删的域名报了半年假警，而真在跑的站从来没被检查过。

同理，凡是"要人记得同步"的清单，时间足够长就一定会不同步。新增这类配置时优先做成"留空 = 自动发现"。

## 定时任务与云端的关系

**cron 永远调用本地已安装的脚本，绝不调用 `opsget`。**

```
# 对
30 3 * * * flock -w 3600 /var/lock/fullbackup.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1

# 错
30 3 * * * opsget backup/vw-fullbackup
```

三个理由：

1. **不能让备份依赖外网才能启动。** 凌晨三点半 GitHub 连不上，备份就静默不跑了 —— 而备份失败恰恰是最难发现的一类故障
2. **不能让未经验证的代码在无人值守时自动生效。** 云端改一行，当晚就跑在生产备份上，没人看着
3. opsget 每次更新都会留 `.bak`，cron 频率下会堆积

所以云端是**分发源**，本地文件才是**运行的东西**，更新是一个显式动作：

```bash
opsget -i <路径>        # 只安装，不执行
/usr/local/bin/<脚本>   # 手动跑一次验证
                        # 确认没问题，下次 cron 自然用新版
```

安装路径与 cron 里写的路径一致，所以**更新脚本不需要动 crontab**。

## 改完云端立刻验证

`opsget` 从 1.2.1 起给每次请求加了 cache-buster。原因是 raw.githubusercontent 有约 5 分钟 CDN 缓存，而"改完立刻验证"恰恰是最常见的场景——拿到旧版会让人误判成"改了没效果"，然后去改本来正确的代码。

如果你的 opsget 还是 1.2.0，症状是：提交了新版，重跑却显示 `[=] 已是最新`、`common.sh 已更新` 一行都没有。要么等几分钟，要么自己带参数绕过：

```bash
curl -fsSL "https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget?nc=$(date +%s)" \
  -o /tmp/opsget.new && grep -m1 '^# VERSION' /tmp/opsget.new
```

`common.sh` 不用单独安装——每次执行任何脚本时 `sync_lib` 都会同步一次。改了 `common.sh` 就等于所有脚本都拿到了新版，这也意味着**改它要格外小心**。

## 清理

两个脚本都**默认只列不删**，加 `--apply` 才执行。

```bash
opsget ops/cleanup-tidy            # 预演：会删哪些冗余
opsget ops/cleanup-tidy --apply    # 执行，每类保留最新 2 份
KEEP=5 opsget ops/cleanup-tidy --apply

opsget ops/cleanup-purge           # 预演：彻底移除会删什么
opsget ops/cleanup-purge --apply   # 执行，还需输入 yes 二次确认
KEEP_ENV=1 opsget ops/cleanup-purge --apply   # 保留 env.conf
```

`cleanup-purge` 按 `/var/lib/ops-scripts/installed.list` 台账精确回收，不会误删同目录下你自己的脚本。两个脚本都对以下路径做了硬拦截，任何情况下都不删：

- `BACKUP_DIRS` 备份产物
- `CONTAINER_DATA_DIRS` 容器数据
- 凭据文件（`BACKUP_PASS_FILES`、`MYSQL_DEFAULTS_FILE`、rclone 配置、msmtprc）
- `PANEL_ROOT` 面板目录
- 云端的任何文件

**注意这份保护名单是从配置拼出来的。** 新增了备份目录却忘了写进 `BACKUP_DIRS`，硬拦截就不覆盖它——前面那些漂移是"少检查了"，这个漂移是"少保护了"。改 `BACKUP_DIRS` / `CONTAINER_DATA_DIRS` 时想一想这件事。

## 约定

所有脚本遵循同一套规则：

- **幂等安装**：写入前比对，内容相同直接执行，不同则备份旧版后替换
- **危险操作需确认**，且尽量提供回滚路径
- **凭据永不出现在命令行**，一律从 `600` 权限的文件读
- **日志时间戳在调用时计算**，不用启动时冻结的变量
- **`set -o pipefail`**，管道错误不吞
- **告警计数要值钱**：正常配置引发的提示用 `log` 不用 `warn`。如果"1 条告警"永远消不掉，很快就没人看这个计数了
- 每个脚本头部有 `# VERSION:`，改动时递增，并在下面写一行**为什么改**——一年后你只会记得改了，不会记得为什么

## 安全边界

仓库公开，所以：

- ❌ 不放任何密码、密钥、token（包括心跳 URL —— 拿到就能伪造心跳）
- ❌ 不放域名、IP、邮箱、容器名、库名
- ❌ 不放运维文档（文档含真实拓扑，另行私有保存）
- ✅ 只放通用逻辑

如果你要新增脚本，问自己一句：**把这个文件贴到公开网页上，会泄露什么？** 答案必须是"只有我的运维习惯"。
