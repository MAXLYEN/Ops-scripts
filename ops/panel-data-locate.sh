#!/usr/bin/env bash
# ops/panel-data-locate.sh — 在面板目录里定位某项数据的真实存储位置
# VERSION: 2.0.0
# 2.0.0 变更：特征串与面板路径改为参数/配置驱动，不再写死域名
#
# 面板把数据摊在多个 sqlite 模块库里，主库常常只是个空壳。
# 想知道"某个东西存在哪"时用它：给一个特征串（域名、库名、任务名…），
# 它会遍历所有 sqlite 的所有表去找，并顺带看续期脚本自己读的是什么。
#
# 用法: panel-data-locate.sh [特征串]
#       不给则取 env.conf 里 DOMAINS 的第一个
set -o pipefail
. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
PANEL="${PANEL_ROOT:?配置里缺 PANEL_ROOT}"
PROBE="${1:-$(echo $DOMAINS | awk '{print $1}')}"
[ -n "$PROBE" ] || { echo "用法: $(basename "$0") <特征串>"; exit 1; }
echo "以域名 $PROBE 作为特征串搜索"

echo
echo "===== 1. panel 下所有 sqlite 文件 ====="
find "$PANEL" -maxdepth 4 -name '*.db' -o -maxdepth 4 -name '*.sqlite*' 2>/dev/null \
  | while read -r f; do printf '  %8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"; done

echo
echo "===== 2. 每个库里与 ssl/cert/site 相关的表 ====="
command -v sqlite3 >/dev/null || { echo "  [跳过] 无 sqlite3"; }
find "$PANEL" -maxdepth 4 -name '*.db' 2>/dev/null | while read -r f; do
  t=$(sqlite3 "$f" ".tables" 2>/dev/null | tr -s ' ' '\n' | grep -iE 'ssl|cert|site|domain' | tr '\n' ' ')
  [ -n "$t" ] && printf '  %-52s %s\n' "$(basename "$f")" "$t"
done

echo
echo "===== 3. 哪个库里能查到这个域名 ====="
find "$PANEL" -maxdepth 4 -name '*.db' 2>/dev/null | while read -r f; do
  for t in $(sqlite3 "$f" ".tables" 2>/dev/null | tr -s ' ' '\n'); do
    n=$(sqlite3 "$f" "SELECT COUNT(*) FROM \"$t\" WHERE CAST(\"$t\".rowid AS TEXT) IS NOT NULL" 2>/dev/null)
    hit=$(sqlite3 "$f" "SELECT * FROM \"$t\"" 2>/dev/null | grep -c "$PROBE" || true)
    [ "${hit:-0}" -gt 0 ] && echo "  $f | 表 $t | 命中 $hit 行"
  done
done

echo
echo "===== 4. 非数据库文件里的命中 ====="
grep -rl "$PROBE" "$PANEL"/data "$PANEL"/config 2>/dev/null \
  | grep -viE '\.log$|\.db$' | head -20 | sed 's/^/  /'

echo
echo "===== 5. 证书目录结构（对照新机）====="
ls -la "$PANEL"/vhost/cert/ | head -15 | sed 's/^/  /'
echo "  --- 单个证书目录 ---"
ls -la "$PANEL"/vhost/cert/"$PROBE"/ 2>/dev/null | sed 's/^/  /'

echo
echo "===== 6. 续期脚本读的是什么（权威答案）====="
grep -nE "_conf_file|def .*renew|\.db|json" "$PANEL"/class/acme_v2.py 2>/dev/null \
  | head -25 | sed 's/^/  /'
echo
echo "提示：脚本自己声明读哪个文件，比任何猜测都可靠。"
echo "     旧机销毁前记得把整个 $PANEL/data/db/ 归档一份。"
