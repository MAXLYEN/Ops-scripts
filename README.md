# ops-scripts

服务器迁移与日常运维脚本集。环境相关的值通过本机 `/etc/ops-scripts/env.conf` 配置，仓库只保存 [配置模板](config/env.example.conf)；真实域名、IP 和凭据不进入公开仓库。`init/`、`vpsscore/` 等自包含脚本可在没有配置文件的新机上运行。

## 快速开始

```bash
# 1. 装引导器
curl -fsSL https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget \
  -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget

# 2. 按已安装脚本的需求生成或补齐配置
opsget -c            # 只补当前需要的配置键
vi /etc/ops-scripts/env.conf

# 3. 用
opsget -l                          # 列出可用脚本
opsget migrate/01-inventory        # 拉取并执行
opsget -i ops/preflight-backup     # 只安装到 /usr/local/bin，不执行

# 4. 生产机固定到验证过的版本（见「固定版本」）
opsget --pin v2026.09.24 && opsget -u
```

路径写成 `migrate/03-pre-migrate` 或 `migrate/03-pre-migrate.sh` 都可以，参数直接跟在后面：`opsget ops/cleanup-tidy --apply`。

注意 `-i` 是 opsget 自己的选项，要写在路径**前面**。`opsget ops/ssl-audit -i` 会把 `-i` 当成传给脚本的参数，照常执行。

## 脚本清单

**看 [MANIFEST](MANIFEST)，或在机器上跑 `opsget -l`。** 这两处列出通过引导器展示的脚本；目录介绍包含该目录全部文件的作用与版本。

这里不再重复列表——两处维护必然漂移，实测过：README 的编号和实际差了一位，两个脚本改过名，整个 `vpsscore/` 目录漏掉了，照 README 敲会 404。

## 目录

| 目录 | 内容 | 目录文档 |
| --- | --- | --- |
| `bin/` | 脚本引导器 | [介绍](bin/README.md) · [版本记录](bin/CHANGELOG.md) |
| `config/` | 环境配置模板 | [介绍](config/README.md) · [版本记录](config/CHANGELOG.md) |
| `lib/` | 公共函数库 | [介绍](lib/README.md) · [版本记录](lib/CHANGELOG.md) |
| `init/` | 新机初始化 | [介绍](init/README.md) · [版本记录](init/CHANGELOG.md) |
| `migrate/` | 整机迁移流程 | [介绍](migrate/README.md) · [版本记录](migrate/CHANGELOG.md) |
| `backup/` | 生产备份 | [介绍](backup/README.md) · [版本记录](backup/CHANGELOG.md) |
| `ops/` | 日常运维 | [介绍](ops/README.md) · [版本记录](ops/CHANGELOG.md) |
| `db/` | 数据库维护 | [介绍](db/README.md) · [版本记录](db/CHANGELOG.md) |
| `vpsscore/` | VPS 质量采集与评分 | [介绍](vpsscore/README.md) · [版本记录](vpsscore/CHANGELOG.md) |
| `openclash/` | OpenClash DNS 分流 | [介绍](openclash/README.md) · [版本记录](openclash/CHANGELOG.md) |

`init/` 与 `vpsscore/` 不依赖 `lib/common.sh`，方便在新机上单独运行，也不强制要求 `env.conf`。`ops/decommission-archive` 同样自包含，以适应机器即将退役的场景。

## 两个顺序执行的流程

**新机初始化**：`00` →(需要则重启)→ `01` → `02` → `03` →(重启)→ `04`

```bash
opsget init/run          # 列出阶段与当前状态
opsget init/run 03       # 执行指定阶段
```

**跑 03 之前务必确认带外控制台能进。** 脚本布置了 5 分钟自动回滚兜底，但那是最后一道保险，不是第一道。调度器在 03 之前也会强制确认第二个 SSH 窗口已就绪。

**整机迁移**：`migrate/` 下按编号顺序，执行机器与各阶段产物见 [迁移目录介绍](migrate/README.md)。

## 配置文件

真实配置在 **`/etc/ops-scripts/env.conf`**，权限 `600`，**永远不进仓库**（`.gitignore` 已排除）。

需要配置的脚本在头部声明 `# ENV-REQUIRED:`；`opsget -e <路径>` 可查看所需和缺失的键，`opsget -c <路径>` 可按需补齐。声明为 `A|B` 时任一有值即可。对这些必填项，缺失时脚本会报错退出，避免用错值静默执行。

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

## 固定版本

cron 只调用本地脚本，挡住的是「云端改动在无人值守时生效」；但下一次有人手动 `opsget`，`main` 上最新的提交照样会装上来。`main` 上一个坏提交，所有机器下次更新都会中招 —— `vw-fullbackup` 2.3.4 就是这样把生产备份弄坏的。

生产机固定到验证过的 tag：

```bash
opsget --pin v2026.09.24     # 之后 -i / -u / -l / 执行都只从这个 tag 拉
opsget -u                    # 引导器和 common.sh 也换成这一版
opsget --pin                 # 查看当前 ref 与来源
opsget --unpin               # 取消固定，回到 main
```

固定写在 `/etc/ops-scripts/ref`。环境变量 `OPS_REF` 优先于它，用于单次覆盖；`opsget` 执行脚本时会导出 `OPS_REF`，`common.sh` 的 `ops_base()` 按同样顺序判定，所以 `script-inventory` 等脚本比对的是同一个版本。

发版流程：

1. 改动推到 `main`，CI 通过
2. 挑一台机器按**完整提交号**单次覆盖装上新版并手动跑一次：`OPS_REF=<40 位提交号> opsget -i <路径>`（`common.sh` 会一并换成该提交的版本）。不要用 `OPS_REF=main`：raw.githubusercontent 会把分支指向的提交缓存几分钟，查询参数绕不过，刚推送后拉到的可能还是旧版，验证就白做了
3. 验证通过后打 tag 并推送：`git tag -a v2026.09.24 -m "<说明>" && git push origin v2026.09.24`，同一天再发用 `v2026.09.24.1`
4. 其余机器 `opsget --pin <新 tag> && opsget -u`，需要更新的脚本再逐个 `opsget -i`

tag 发布后不要移动，有问题就打新 tag。`--pin` 会拒绝 `main`、拒绝仓库里取不到的 ref，也拒绝 opsget 早于 1.4.0 的 ref —— 固定到那里再 `opsget -u`，会装回一个不读固定文件的旧引导器，固定就悄悄失效了。

## 改完云端立刻验证

`opsget` 从 1.2.1 起给每次请求加了 cache-buster。原因是 raw.githubusercontent 有约 5 分钟 CDN 缓存，而"改完立刻验证"恰恰是最常见的场景——拿到旧版会让人误判成"改了没效果"，然后去改本来正确的代码。

如果你的 opsget 还是 1.2.0，症状是：提交了新版，重跑却显示 `[=] 已是最新`、`common.sh 已更新` 一行都没有。要么等几分钟，要么自己带参数绕过：

```bash
curl -fsSL "https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget?nc=$(date +%s)" \
  -o /tmp/opsget.new && grep -m1 '^# VERSION' /tmp/opsget.new
```

**固定了版本的机器拉不到 `main` 上的新提交**，这是设计如此；验证新提交用 `OPS_REF=<完整提交号>` 单次覆盖（分支名有几分钟缓存，见上）。

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

仓库采用以下通用约定，具体以各脚本的实现为准：

- **幂等安装**：写入前比对，内容相同直接执行，不同则备份旧版后替换
- **危险操作需确认**，且尽量提供回滚路径
- **凭据永不出现在命令行**，一律从 `600` 权限的文件或 stdin 读。例外是 7z：它没有从文件读密码的选项，备份相关脚本仍以 `-p` 传入。由 `init/02` 以 `hidepid` 挂载 `/proc` 兜底 —— 普通用户看不到其他用户的进程与命令行；老机器按 `init/README.md` 手动启用
- **日志时间戳在调用时计算**，不用启动时冻结的变量
- **`set -o pipefail`**，管道错误不吞
- **告警计数要值钱**：正常配置引发的提示用 `log` 不用 `warn`。如果"1 条告警"永远消不掉，很快就没人看这个计数了
- 每个脚本头部保留作用、`# VERSION:`、本版改动原因和必要的运行约束；旧版本的详细说明写入所在目录的 `CHANGELOG.md`
- 脚本正文保留解释关键判断和回滚条件的注释；会写入目标配置文件的注释属于输出内容，不能随意删除
- 各脚本独立编号；修改时递增相应版本，并同步目录版本记录

## 安全边界

仓库公开，所以：

- ❌ 不放任何密码、密钥、token（包括心跳 URL —— 拿到就能伪造心跳）
- ❌ 不放域名、IP、邮箱、容器名、库名
- ❌ 不放运维文档（文档含真实拓扑，另行私有保存）
- ✅ 只放通用逻辑

如果你要新增脚本，问自己一句：**把这个文件贴到公开网页上，会泄露什么？** 答案必须是"只有我的运维习惯"。
