# 脚本引导器

`opsget` 从仓库拉取脚本，安装到本机并按需执行。更新时保留旧版备份，安装台账供清理脚本精确回收；公共库 `lib/common.sh` 随执行同步。

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `opsget` | 1.3.2 | 从仓库拉取、安装和执行运维脚本 |

## 常用命令

```bash
opsget -l                         # 列出 MANIFEST 中的脚本
opsget migrate/01-inventory       # 拉取、安装并执行
opsget -i backup/vw-fullbackup    # 仅安装，不执行
opsget -e backup/vw-fullbackup    # 查看该脚本需要的配置键
opsget -c backup/vw-fullbackup    # 补齐该脚本需要的配置键
opsget -u                         # 更新引导器与公共库
```

脚本头部的 `# ENV-REQUIRED:` 声明用于按需预检；`A|B` 表示两个键任一有值即可。未声明的脚本不要求 `env.conf`。`OPS_REPO` 可指定仓库，`OPS_REF` 可锁定分支或 tag。无人值守的 cron 应调用已安装脚本的本地路径。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
