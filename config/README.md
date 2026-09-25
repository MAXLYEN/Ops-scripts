# 环境配置

`env.example.conf` 是可公开的配置模板。真实配置复制到 `/etc/ops-scripts/env.conf`，设置权限 `600`，由需要配置的脚本读取；真实值不得提交到仓库。

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `env.example.conf` | 1.8.0 | 供运维脚本读取的环境配置模板 |

```bash
install -d -m 700 /etc/ops-scripts
install -m 600 config/env.example.conf /etc/ops-scripts/env.conf
```

也可用 `opsget -c <脚本路径>` 只补该脚本声明需要的键，用 `opsget -c all` 生成完整模板。模板是 Shell 片段，含空格的值需加引号。路径和端口等配置以实际环境为准；凭据应放入单独的 `600` 权限文件，配置中只保存文件路径。清单类配置的留空与自动发现规则见仓库首页 README。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
