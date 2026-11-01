# opsctl 版本迭代记录

## 2026-10-31 — 1.0.0

- 首版单文件 Python 安装器与受限服务端，保留稳定资产 ID，按电脑公钥单独授权。
- 建立 `host.discover`、`plan`、`key.revoke` 的 v1 JSON 白名单协议和双通道审计。
- 安装 root 管理的授权文件、专用账号、固定 SSH 强制命令及最小 sudo 权限；加入真实 sshd 隔离测试。
