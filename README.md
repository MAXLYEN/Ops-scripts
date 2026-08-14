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
```

`init/` 与其它目录有一点不同：**它不依赖 `lib/common.sh`**。这些脚本要能在
一台什么都没有的新机上单跑，少一个依赖就少一个失败点。它们也不强制要求
`env.conf` —— 没有就用内置默认值，有就以配置为准。

## 配置文件

真实配置在 **`/etc/ops-scripts/env.conf`**，权限 `600`，**永远不进仓库**（`.gitignore` 已排除）。

脚本在缺少配置项时会直接 `die`，不会回落到任何默认值——这是刻意的：宁可报错，也不要用错误的值静默执行。

## 脚本清单

### migrate/ — 整机迁移

按编号顺序，配合《服务器整机迁移教程》使用。

| 脚本 | 在哪台机器跑 | 作用 |
|---|---|---|
| `01-inventory.sh` | 新旧机各一次 | 摸底，输出逐段对比 |
| `02-nat-probe.sh` | 新机 listen / 旧机 probe | 验证入站可达性 |
| `03-pre-migrate.sh` | 旧机 | 冷快照：停服、全量导出、打包 |
| `04-snapshot-extra.sh` | 旧机 | 补齐快照（授权、面板数据、校验和） |
| `05-verify-migration.sh` | 新旧机各一次 | 逐表行数/站点/证书/授权比对 |
| `06-fix-db-grants.sh` | 新机 | 修正被面板改掉的账号 host |
| `07-export-images.sh` | 旧机 | 导出容器镜像（不要重新 pull） |
| `08-restore-containers.sh` | 新机 | 恢复数据目录，生成启动命令 |
| `09-post-start-check.sh` | 新机 | 端到端验收 |
| `10-restore-backup-stack.sh` | 新机 | 重建备份体系 |

### init/ — 新机初始化

推荐顺序：`00` →(需要则重启)→ `01` → `02` → `03` →(重启)→ `04`

```bash
opsget init/run          # 列出阶段与当前状态
opsget init/run 00       # 执行指定阶段
```

| 脚本 | 作用 |
|---|---|
| `run.sh` | 阶段调度器，03 之前会强制确认第二个 SSH 窗口已就绪 |
| `00-precheck.sh` | 环境探测与系统更新，判断是否需重启 |
| `01-swap-memory.sh` | 按内存分档创建 swapfile，内存参数 |
| `02-system-network.sh` | UTC 时区、IPv4 优先、SUID、磁盘 udev、BBR、内核参数、日志上限 |
| `03-ssh-firewall.sh` | SSH 加固、ufw、fail2ban，含 5 分钟自动回滚 |
| `04-verify.sh` | 重启后持久性验证（只读） |

**跑 03 之前务必确认带外控制台能进。** 脚本有自动回滚兜底，但那是最后一道
保险，不是第一道。

### backup/ — 生产备份

| 脚本 | 作用 |
|---|---|
| `vw-fullbackup.sh` | 全服务备份：密码库 + 监控 + 订阅转换 + 系统配置 |
| `xboard-fullbackup.sh` | Xboard 单包备份 |

两者共用同一个加密密码文件、同一把 `flock` 锁，云端目录分开。
**由 cron 调用本地路径**，更新用 `opsget -i backup/<名字>` 显式安装后手动验证一次。

### ops/ — 日常运维

| 脚本 | 作用 |
|---|---|
| `save-fw.sh` | 改防火墙前保存现状 |
| `restore-cron.sh` | 从快照恢复自有 cron |
| `preflight-backup.sh` | 备份脚本的依赖与前置检查 |
| `verify-backup-pass.sh` | 用真密码验证云端备份包能打开 |
| `ssl-audit.sh` | 证书文件、站点引用、面板记录三方对账 |
| `bt-cron-inspect.sh` | 查明面板计划任务的真实身份 |
| `bind-localhost.sh` | 把容器端口从 0.0.0.0 收到 127.0.0.1 |
| `cleanup-tidy.sh` | 清理冗余：历史输出、旧版备份、中间产物 |
| `cleanup-purge.sh` | 彻底移除本套脚本及其全部产物 |
| `script-inventory.sh` | 盘点本机脚本：哪些来自云端、哪些只在本地 |
| `panel-backup-upload.sh` | 把面板整机备份包加密上传到网盘（手动执行） |
| `komari-metrics-check.sh` | 指标库的保留期与增速体检 |
| `panel-data-locate.sh` | 在面板目录里定位某项数据的真实存储位置 |

### db/ — 数据库维护

| 脚本 | 作用 |
|---|---|
| `rotate-db-pass.sh` | 轮换业务库密码并同步下游配置 |
| `komari-dsn.sh` | 查看/修改存在 SQLite 里的连接串 |

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

`cleanup-purge` 按 `/var/lib/ops-scripts/installed.list` 台账精确回收，
不会误删同目录下你自己的脚本。两个脚本都对以下路径做了硬拦截，任何情况下都不删：

- `BACKUP_DIRS` 备份产物
- `CONTAINER_DATA_DIRS` 容器数据
- 凭据文件（`BACKUP_PASS_FILES`、`MYSQL_DEFAULTS_FILE`、rclone 配置、msmtprc）
- `PANEL_ROOT` 面板目录
- 云端的任何文件

## 约定

所有脚本遵循同一套规则：

- **幂等安装**：写入前比对，内容相同直接执行，不同则备份旧版后替换
- **危险操作需确认**，且尽量提供回滚路径
- **凭据永不出现在命令行**，一律从 `600` 权限的文件读
- **日志时间戳在调用时计算**，不用启动时冻结的变量
- **`set -o pipefail`**，管道错误不吞
- 每个脚本头部有 `# VERSION:`，改动时递增

## 安全边界

仓库公开，所以：

- ❌ 不放任何密码、密钥、token
- ❌ 不放域名、IP、邮箱、容器名、库名
- ❌ 不放运维文档（文档含真实拓扑，另行私有保存）
- ✅ 只放通用逻辑

如果你要新增脚本，问自己一句：**把这个文件贴到公开网页上，会泄露什么？** 答案必须是"只有我的运维习惯"。
