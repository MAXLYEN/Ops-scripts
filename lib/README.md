# 公共函数库

`common.sh` 提供日志、配置加载、依赖检查、数据库访问以及站点域名扫描等公共函数。多数 `backup/`、`migrate/`、`ops/` 脚本会加载它；`init/` 和 `vpsscore/` 保持自包含，以便在新机上单独运行。

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `common.sh` | 1.1.4 | 提供配置加载、日志、数据库与站点扫描等公共函数 |

使用 `opsget` 执行脚本时，公共库会同步到 `/usr/local/lib/ops-common.sh`。因此修改公共函数会影响多个脚本，更新后应检查调用方。真实配置默认从 `/etc/ops-scripts/env.conf` 读取。需要访问云端的脚本用 `ops_base()` 取地址，它与 `opsget` 的 ref 判定一致，两处要同步修改。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
