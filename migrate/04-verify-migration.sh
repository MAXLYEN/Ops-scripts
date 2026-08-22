#!/usr/bin/env bash
# 04-verify-migration.sh — 迁移后逐项比对
# VERSION: 2.0.0
#
# 在新旧机各跑一次，diff 两份输出。比对四项：
#   1. 每张表的精确行数（不是 information_schema 的估算值）
#   2. 站点配置清单
#   3. 证书及到期日
#   4. 数据库账号授权
#
# 输出刻意不含主机名，diff 才干净。
# ENV-REQUIRED: DB_NAMES

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env DB_NAMES
mysql_ready

OUT="/root/verify_$(hostname)_$(date -u +%Y%m%d%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

section "数据库精确行数"
for db in $DB_NAMES; do
  if ! db_exists "$db"; then echo "[缺失] $db"; continue; fi
  echo "--- $db ---"
  for t in $(myq "SHOW TABLES FROM \`$db\`"); do
    c=$(myq "SELECT COUNT(*) FROM \`$db\`.\`$t\`" 2>/dev/null)
    printf '%-44s %s\n' "$t" "${c:-ERR}"
  done
done

section "站点配置"
[ -d "${PANEL_VHOST_DIR:-}" ] && ls -1 "$PANEL_VHOST_DIR" | sort || echo "(未配置或不存在)"

section "证书及到期日"
if [ -d "${PANEL_CERT_DIR:-}" ]; then
  for d in "$PANEL_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if [ -f "$d/fullchain.pem" ]; then
      exp=$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)
      san=$(openssl x509 -noout -ext subjectAltName -in "$d/fullchain.pem" 2>/dev/null \
            | tail -1 | sed 's/DNS://g' | tr -d ' ')
      printf '%-26s %-26s %s\n' "$n" "$exp" "$san"
    else
      printf '%-26s (无 fullchain.pem)\n' "$n"
    fi
  done | sort
else
  echo "(未配置或不存在)"
fi

section "数据库账号授权"
myq "SELECT CONCAT(\"'\",user,\"'@'\",host,\"'\") FROM mysql.user
     WHERE user NOT IN ('mysql.sys','mysql.session') ORDER BY user,host" \
  | while IFS= read -r u; do
      [ -z "$u" ] && continue
      myq "SHOW GRANTS FOR $u" 2>/dev/null
    done

section "组件版本"
myq "SELECT VERSION()"
nginx -v 2>&1
php -v 2>/dev/null | head -1

section "本机侧提示（不参与 diff）"
echo "  主机: $(hostname)"
echo "  时区: $(timedatectl show -p Timezone --value 2>/dev/null)  MySQL: $(myq 'SELECT @@system_time_zone')"
echo
echo "  比对方式: diff <旧机输出> <新机输出>"
echo "  已知的正常差异：组件版本里的 PHP 编译日期"
echo "  必须关注的差异：账号 host（面板迁移常把它改成 127.0.0.1，见教程坑 1）"
printf '\n输出已保存: %s\n' "$OUT"
