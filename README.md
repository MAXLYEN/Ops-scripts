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
lib/common.sh           公共函数库，所有脚本 source 它
config/env.example.conf 配置模板
migrate/                整机迁移流程，按编号顺序执行
ops/                    日常运维
db/                     数据库相关维护
```

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

### db/ — 数据库维护

| 脚本 | 作用 |
|---|---|
| `rotate-db-pass.sh` | 轮换业务库密码并同步下游配置 |
| `komari-dsn.sh` | 查看/修改存在 SQLite 里的连接串 |

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
