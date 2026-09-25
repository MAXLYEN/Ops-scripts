# 新机初始化

本目录按阶段完成 Debian 新机初始化。脚本可单独运行，不依赖 `lib/common.sh`；有 `/etc/ops-scripts/env.conf` 时，02 和 03 会读取其中的端口等配置。

## 执行顺序

```text
00 环境探测与更新 →（按提示重启）→ 01 Swap → 02 系统与网络
→ 03 SSH 与防火墙 →（重启）→ 04 持久性验证
```

`opsget init/run` 列出阶段与当前状态；`opsget init/run 00` 等命令执行指定阶段。调度器需要预先安装 `opsget`。也可以在确认依赖和执行环境后单独运行阶段脚本。

| 脚本 | 当前版本 | 作用 |
| --- | --- | --- |
| `run.sh` | 2.0.2 | 展示阶段和机器状态，通过 `opsget` 启动指定阶段 |
| `00-precheck.sh` | 1.0.2 | 探测系统、硬件、网络及软件源，更新系统并判断是否重启 |
| `01-swap-memory.sh` | 1.1.1 | 按内存与磁盘容量创建 Swap，配置内存参数 |
| `02-system-network.sh` | 1.2.0 | 配置 UTC、IPv4 优先、磁盘、BBR 和内核参数 |
| `03-ssh-firewall.sh` | 1.4.0 | 加固 SSH，启用 ufw、fail2ban 和空闲超时 |
| `04-verify.sh` | 1.1.1 | 重启后只读核对系统层配置是否生效 |

## 关键注意事项

- 00 会运行系统更新；软件源异常时，修复需交互确认。阶段脚本中有需要 root 权限的操作。
- 03 修改 SSH 与防火墙。开始前先连好第二个 SSH 窗口，并确认带外控制台可用。脚本设有 5 分钟自动回滚；新连接验证成功后还需明确取消回滚。
- 01、02、04 的 fstab 检查会把 Debian 光驱模板和 swapfile 语义误报单独列出，只将真实挂载点问题计为失败。
- 04 只检查系统层；容器和数据库还需运行 `migrate/08-post-start-check`。

各脚本的 `VERSION` 独立维护。历史改动及本次整理见 [CHANGELOG.md](CHANGELOG.md)。

## 已初始化的机器补启用 hidepid

`02-system-network.sh` 1.2.0 起会以 `hidepid` 挂载 `/proc` 并写入 fstab。之前初始化的机器不必重跑整个阶段 02，按下面两步手动补上：先临时 remount 观察一两天（面板、站点、每晚备份均正常），再写入 fstab。

```bash
mount -o remount,hidepid=invisible /proc          # 临时启用，重启即失效；撤回用 hidepid=0
```

```bash
cp -a /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S) && echo 'proc /proc proc nosuid,nodev,noexec,relatime,hidepid=invisible 0 0' >> /etc/fstab && systemctl daemon-reload && mount -o remount /proc && findmnt -no OPTIONS /proc
```

写入前先确认 fstab 里没有 `/proc` 条目（`grep ' /proc ' /etc/fstab`）。不要写 `defaults`：remount 时会把 `/proc` 原有的 `nosuid,nodev,noexec` 冲掉。内核低于 5.8 时把 `invisible` 换成 `2`。
