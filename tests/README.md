# 测试

`tests/run.sh` 一次跑完静态检查和端到端测试。需要 Linux 与 docker；Windows 开发机上在 WSL 里运行，命令见仓库根目录的 `CLAUDE.md`。CI 跑的是同一份。

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `run.sh` | 1.0.0 | 入口：`--lint` 只跑静态检查，`--e2e` 只跑端到端，第二个参数按用例名过滤 |
| `lint.sh` | 1.0.0 | 换行符、语法、shellcheck、VERSION 头、MANIFEST、菜单归类、ENV-REQUIRED 键 |
| `Dockerfile` | — | 端到端用的一次性 Debian 12 环境 |
| `helpers.bash` | — | 模拟仓库、本地 HTTP 服务、脚本桩、断言 |
| `drive.py` | — | 在伪终端里运行交互命令并逐行送入按键（菜单读 `/dev/tty`，管道喂不进去） |
| `opsget.bats` | — | 引导器：安装、`-u`、固定旧版本、配置预检、菜单入口 |
| `opsbox.bats` | — | 菜单：界面、说明卡片、两段式与主机名确认、缺配置引导、各联动流程、向导进度 |

## 端到端怎么测

容器里起一个 HTTP 服务当作仓库：`main` 是当前工作区（包括没提交的改动），旧 tag 从 git 里取。每个用例开始前把机器恢复成「只装了 opsget」。

菜单调用的运维脚本换成**桩**：它只把自己被调用的方式记进 `/tmp/calls`，然后按指定的退出码退出。用例断言调用记录，例如「备份体检里云端校验失败时，接着调用了 mail-doctor」「没确认就没有 `--apply`」。

这证明的是菜单按正确的顺序、带正确的参数调用了脚本；运维脚本本身在真实服务上的行为不在这里测。

## 新增用例

```bash
@test "两段式：确认后才带 --apply 执行" {
  stub ops/cleanup-tidy 0                  # 仓库路径、退出码、可选的 ENV-REQUIRED 键
  drive opsbox 5 1 "" y "" 0 q             # 按屏幕顺序送入按键
  calls_are "ops/cleanup-tidy" "ops/cleanup-tidy --apply"
}
```

写完先故意把被测逻辑改坏，确认用例会失败，再改回来。
