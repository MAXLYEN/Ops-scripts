# 生产备份

本目录提供 Vaultwarden 等服务、Xboard 与 new-api 的备份脚本。备份包在本地生成并校验后上传；密码从权限受控的文件读取。脚本通过 `/etc/ops-scripts/env.conf` 获取路径、远端和告警配置。

## 脚本

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `newapi-fullbackup.sh` | 1.0.3 | 从汇总机拉取 new-api 数据，生成一致性快照并加密上传 |
| `vw-fullbackup.sh` | 2.3.7 | 备份 Vaultwarden、Komari、SubConverter 与系统配置 |
| `xboard-fullbackup.sh` | 2.3.2 | 生成 Xboard 加密备份包并上传云端 |

## 运行与更新

定时任务调用**已安装在本机的脚本**，避免备份启动依赖 GitHub。先用 `opsget -i backup/<脚本名>` 安装新版，再手动运行并检查产物；确认正常后，现有 cron 下一次会使用本地新版。不要让 cron 直接调用 `opsget`。

- `vw-fullbackup.sh` 与 `xboard-fullbackup.sh` 使用 `BACKUP_PASS_FILE`，兼容旧的 `VW_PASS_FILE`；两者都是密码文件路径。
- `newapi-fullbackup.sh` 从落地机拉取数据；SQLite 用在线备份 API 生成一致性快照，避免直接复制运行中的 WAL 数据库。
- 备份是否可解开，另用 `ops/verify-backup-pass.sh` 检查；完整恢复能力仍需演练。

各脚本在头部声明 `ENV-REQUIRED`。版本记录见 [CHANGELOG.md](CHANGELOG.md)。
