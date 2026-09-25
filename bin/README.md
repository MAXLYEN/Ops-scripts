# 脚本引导器

`opsget` 从仓库拉取脚本，安装到本机并按需执行。更新时保留旧版备份，安装台账供清理脚本精确回收；公共库 `lib/common.sh` 随执行同步。`opsbox` 是它上面的中文菜单。

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `opsget` | 1.5.0 | 从仓库拉取、安装和执行运维脚本 |
| `opsbox` | 1.0.0 | 中文菜单：按分类或场景挑功能，常用组合自动串联 |

## 常用命令

```bash
opsget -l                         # 列出 MANIFEST 中的脚本
opsget migrate/01-inventory       # 拉取、安装并执行
opsget -i backup/vw-fullbackup    # 仅安装，不执行
opsget -e backup/vw-fullbackup    # 查看该脚本需要的配置键
opsget -c backup/vw-fullbackup    # 补齐该脚本需要的配置键
opsget -u                         # 更新引导器与公共库
opsget --pin v2026.09.24          # 固定到验证过的 tag；--pin 查看，--unpin 取消
```

## 中文菜单 opsbox

在终端里敲 `opsbox`，或不带参数敲 `opsget`（没装会先装）。`opsget -u` 会一并更新它，所以它和本机固定的版本一致；在管道或 cron 里不带参数运行 `opsget` 仍只打印帮助。

- **头部**：主机、系统、固定的版本、负载与磁盘、env.conf 状态、待重启与遗留回滚定时器、初始化进度
- **按场景找**（`?`）：从「磁盘快满了」「收不到告警邮件」这类要办的事直接找到功能
- **说明卡片**：选中功能先显示什么时候用、会做什么、等价命令，回车才执行；每次执行都打印实际调用的 `opsget` 命令
- **标记**：`[只读]` 不改动；`[需确认]` 先预演，看完再确认；`[高危]` 要手输主机名；`[联动]`、`[向导]` 是多步组合；`[未配置]` 表示本机缺配置，执行失败时引导用 `opsget -c` 补齐并打开编辑器
- **联动**：一键巡检、备份体检（校验不过自动诊断告警邮件）、LLM 访问控制（盘点 → 快照 → 同步 → 复查）、容器端口收回本机（预演 → 快照 → 重建 → 验收）、Vaultwarden 升级（查版本 → 先备份 → 升级），结束时输出汇总表
- **向导**：新机初始化记住进度（`/var/lib/ops-scripts/opsbox.state`），重启后回来从下一步接着走；整机迁移先选迁出机或迁入机，只列这台该跑的步骤
- 「立即备份」直接运行本机已装的备份脚本，并从 crontab 里读出同一把 flock 锁，不会和定时备份撞车

退出码分不清「有告警」和「失败」（`common.sh` 的 `finish` 与 `die` 都是 1），所以联动里的只读检查一律跑完再汇总，改动前都由菜单单独确认。

**没进菜单的脚本**仍可用 `opsget <路径>` 运行，原因写在 `opsbox` 的 `MENU-EXCLUDE` 注释里：一次性的修复与部署（`apply-newapi-quota-fix`、`fix-newapi-*`、`deploy-litellm`、`containerize-and-pin`）、退役归档 `decommission-archive`、备用机演练 `newapi-drill`、改应用库连接串的 `db/sqlite-dsn`、在路由器上运行的 `openclash/`。CI 会核对 MANIFEST 里的每个脚本要么登记进菜单、要么写明排除，新增脚本忘了归类会被拦下。

脚本头部的 `# ENV-REQUIRED:` 声明用于按需预检；`A|B` 表示两个键任一有值即可。未声明的脚本不要求 `env.conf`。`OPS_REPO` 可指定仓库。ref 按「环境变量 `OPS_REF` > `/etc/ops-scripts/ref`（`--pin` 写入）> `main`」判定，执行脚本时导出 `OPS_REF`；固定与发版流程见根目录 README 的「固定版本」。无人值守的 cron 应调用已安装脚本的本地路径。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
