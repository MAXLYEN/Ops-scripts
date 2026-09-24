# OpenClash DNS 反投毒

本目录的 `dns-anti-poison.sh` 向 OpenClash 的 `openclash_custom_overwrite.sh` 注入 `OPS-DNS` 配置块：国内域名使用国内 DoH，境外域名使用境外 DoH 并经代理解析；可为节点或自建域名指定国内 DoH 直连解析，避免解析链路互相依赖。这样可减少境外域名被错误解析后触发规则误判的情况。

## 使用

```sh
sh dns-anti-poison.sh                 # 安装或更新
sh dns-anti-poison.sh --check         # 只读检查
sh dns-anti-poison.sh --dry-run       # 预览将写入的配置块
sh dns-anti-poison.sh --uninstall     # 移除配置块
```

默认目标文件为 `/etc/openclash/custom/openclash_custom_overwrite.sh`。可通过 `OPS_OVERWRITE` 指定其他位置。

| 环境变量 | 作用 | 默认值 |
| --- | --- | --- |
| `OPS_DNS_CN` | 国内 DoH，逗号分隔 | 腾讯、阿里 DoH |
| `OPS_DNS_FQ` | 境外 DoH，逗号分隔 | Cloudflare、Google DoH |
| `OPS_DNS_DIRECT` | 强制使用国内 DoH 的自有域名，逗号分隔 | 空，不添加专用规则 |

例如：`OPS_DNS_DIRECT="example.com,example.net" sh dns-anti-poison.sh`。

安装或卸载会先备份目标文件。安装时，配置块放在第一个 `exit 0` 之前；运行后需执行 `/etc/init.d/openclash restart` 使配置生效。回滚可运行 `sh dns-anti-poison.sh --uninstall`，再重启 OpenClash。

版本变化见 [CHANGELOG.md](CHANGELOG.md)。脚本头部只记录当前版本和简要用法，详细说明放在本文件。
