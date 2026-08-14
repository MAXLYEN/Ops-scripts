#!/usr/bin/env bash
# ops/decommission-archive.sh — 机器退役前的最终归档
# VERSION: 2.0.0
# 2.0.0 变更：**重写为自包含**，不再依赖 lib/common.sh 与 env.conf。
#            理由和 init/ 一样：这个脚本的使用场景就是「机器即将退役」，
#            不该假设它装了什么。缺配置就自动探测，探不到就跳过并说明。
#
# 在**即将退役的机器**上运行。收集所有「这台机器没了就永远查不到」的东西。
#
# 与备份脚本的区别：备份是为了恢复服务，本脚本是为了**保留证据** ——
# 以后排查「当时是怎么配的」时唯一的参照物。体积很小，值得留很久。
#
# 用法: decommission-archive.sh [--with-db]
#       --with-db 额外导出全部数据库（已迁移并核对过行数的话不必）

set -o pipefail
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }

WITH_DB=0; [ "${1:-}" = "--with-db" ] && WITH_DB=1
TS=$(date -u +%Y%m%d%H%M%S)
D="/root/decommission_$(hostname)_$TS"
mkdir -p "$D"/{panel,system,creds,scripts,db}

sec()  { printf '\n===== %s =====\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
note() { printf '  [跳过] %s\n' "$*"; }
hum()  { du -sh "$1" 2>/dev/null | cut -f1; }

# ── 配置：有 env.conf 就用，没有就自动探测 ──────────────────
ENV_FILE=/etc/ops-scripts/env.conf
if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"; echo "读取配置: $ENV_FILE"
else
  echo "没有 $ENV_FILE，改用自动探测"
fi
PANEL_ROOT="${PANEL_ROOT:-}"
[ -z "$PANEL_ROOT" ] && [ -d /www/server/panel ] && PANEL_ROOT=/www/server/panel
WWWROOT="${WWWROOT:-/www/wwwroot}"
MYCNF="${MYSQL_DEFAULTS_FILE:-/root/.my.cnf}"
DB_NAMES="${DB_NAMES:-}"
# 没配库名就问 MySQL 要（排除系统库）
if [ -z "$DB_NAMES" ] && [ -f "$MYCNF" ] && command -v mysql >/dev/null 2>&1; then
  DB_NAMES=$(mysql --defaults-file="$MYCNF" -N -B -e "SHOW DATABASES" 2>/dev/null \
    | grep -vE '^(information_schema|performance_schema|mysql|sys)$' | tr '\n' ' ')
fi
CRED_FILES="${BACKUP_PASS_FILES:-} $MYCNF /etc/msmtprc /root/.xboard-db-pass /root/.vw_backup_pass"

sec "1. 面板的全部记录"
# 面板把数据摊在多个 sqlite 模块库里，整机迁移只搬它认识的那部分。
# 几百 KB 而已，但机器一没，「当时面板里是怎么配的」就永久查不到。
if [ -n "$PANEL_ROOT" ] && [ -d "$PANEL_ROOT" ]; then
  cp -a "$PANEL_ROOT/data/db" "$D/panel/data-db" 2>/dev/null && ok "data/db（模块库，$(hum "$D/panel/data-db")）"
  cp -a "$PANEL_ROOT/config"  "$D/panel/config"  2>/dev/null && ok "config（含续期配置与 ACME 账户）"
  cp -a "$PANEL_ROOT/vhost"   "$D/panel/vhost"   2>/dev/null && ok "vhost（站点配置 + 证书 + ssl_saved）"
  ls -lh "$PANEL_ROOT/data"/*.db > "$D/panel/data-db-toplevel.txt" 2>/dev/null
  [ -d "$WWWROOT" ] && cp -a "$WWWROOT" "$D/panel/wwwroot" 2>/dev/null && ok "wwwroot（$(hum "$D/panel/wwwroot")）"
else
  note "没找到面板目录（PANEL_ROOT 未配置且 /www/server/panel 不存在）"
fi

sec "2. 系统状态"
crontab -l                 > "$D/system/crontab.txt"     2>/dev/null
ufw status numbered        > "$D/system/ufw.txt"         2>&1
iptables-save              > "$D/system/iptables.rules"  2>&1
ip -4 -br addr             > "$D/system/network.txt"     2>&1
ip route                  >> "$D/system/network.txt"     2>&1
ss -lntup                  > "$D/system/listen.txt"      2>&1
systemctl list-unit-files --state=enabled > "$D/system/enabled-units.txt" 2>&1
cp -a /etc/sysctl.d        "$D/system/sysctl.d"          2>/dev/null
cp -a /etc/ufw             "$D/system/ufw-conf"          2>/dev/null
cp -a /etc/ssh/sshd_config "$D/system/"                  2>/dev/null
[ -d /etc/ssh/sshd_config.d ]     && cp -a /etc/ssh/sshd_config.d "$D/system/"
[ -f /root/.ssh/authorized_keys ] && cp -a /root/.ssh/authorized_keys "$D/system/"
[ -f /etc/fstab ]                 && cp -a /etc/fstab "$D/system/"
ok "crontab / 防火墙 / sshd / 网络 / 监听端口 / 自启单元"

if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$D/system/containers.txt" 2>/dev/null
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' > "$D/system/images.txt" 2>/dev/null
  docker network ls > "$D/system/networks.txt" 2>/dev/null
  for c in $(docker ps -aq 2>/dev/null); do
    n=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /)
    docker inspect "$c" > "$D/system/inspect_${n}.json" 2>/dev/null
  done
  ok "容器状态与 inspect（$(ls -1 "$D/system"/inspect_*.json 2>/dev/null | wc -l) 个）"
else
  note "未装 docker"
fi

sec "3. 凭据与配置文件"
# 新机上都有，但留一份可交叉验证「是不是同一个值」——迁移出问题时能省大量猜测
SEEN=""
for f in $CRED_FILES; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case " $SEEN " in *" $f "*) continue ;; esac
  SEEN="$SEEN $f"
  cp -a "$f" "$D/creds/$(basename "$f")" 2>/dev/null && ok "$f"
done
[ -d /root/.config/rclone ] && cp -a /root/.config/rclone "$D/creds/rclone" && ok "rclone 配置（含 OAuth token）"
[ -d /root/deploy ]         && cp -a /root/deploy "$D/creds/deploy" && ok "/root/deploy"
[ -f "$ENV_FILE" ]          && cp -a "$ENV_FILE" "$D/creds/env.conf" && ok "env.conf"
chmod -R go-rwx "$D/creds" 2>/dev/null

sec "4. 本机脚本"
cp -a /usr/local/bin/*.sh "$D/scripts/" 2>/dev/null
cp -a /usr/local/bin/*.py "$D/scripts/" 2>/dev/null
cp -a /root/*.sh          "$D/scripts/" 2>/dev/null
ok "$(ls -1 "$D/scripts" 2>/dev/null | wc -l) 个"

sec "5. 数据库"
if [ -f "$MYCNF" ] && command -v mysql >/dev/null 2>&1 && [ -n "$DB_NAMES" ]; then
  echo "  库: $DB_NAMES"
  # 逐表行数很便宜，将来对账用
  for db in $DB_NAMES; do
    for t in $(mysql --defaults-file="$MYCNF" -N -B -e "SHOW TABLES FROM \`$db\`" 2>/dev/null); do
      printf '%s\t%s\t%s\n' "$db" "$t" \
        "$(mysql --defaults-file="$MYCNF" -N -B -e "SELECT COUNT(*) FROM \`$db\`.\`$t\`" 2>/dev/null)"
    done
  done > "$D/db/rowcounts.txt"
  ok "逐表行数已留档（$(wc -l < "$D/db/rowcounts.txt") 张表）"
  # 账号授权
  mysql --defaults-file="$MYCNF" -N -B -e \
    "SELECT CONCAT(\"'\",user,\"'@'\",host,\"'\") FROM mysql.user
     WHERE user NOT IN ('mysql.sys','mysql.session') ORDER BY user,host" 2>/dev/null \
    | while IFS= read -r u; do
        [ -z "$u" ] && continue
        printf -- '-- %s\n' "$u"
        mysql --defaults-file="$MYCNF" -N -B -e "SHOW GRANTS FOR $u" 2>/dev/null | sed 's/$/;/'
        printf '\n'
      done > "$D/db/grants.txt"
  ok "账号授权已留档"
  if [ "$WITH_DB" -eq 1 ]; then
    for db in $DB_NAMES; do
      echo "  导出 $db ..."
      mysqldump --defaults-file="$MYCNF" --no-tablespaces --single-transaction --quick \
        --routines --triggers --events --default-character-set=utf8mb4 "$db" \
        | gzip -6 > "$D/db/${db}.sql.gz" && ok "$db  $(hum "$D/db/${db}.sql.gz")"
    done
  else
    echo "  未导出数据（加 --with-db 才导）。已迁移并核对过行数的话不必。"
  fi
else
  note "MySQL 不可用或没有库名，跳过"
fi

sec "6. 最后一次摸底"
if [ -x /usr/local/bin/01-inventory.sh ]; then
  /usr/local/bin/01-inventory.sh > "$D/system/final-inventory.txt" 2>&1 && ok "final-inventory.txt"
elif [ -x /usr/local/bin/srv-inventory.sh ]; then
  /usr/local/bin/srv-inventory.sh > "$D/system/final-inventory.txt" 2>&1 && ok "final-inventory.txt（旧版脚本）"
else
  note "没有摸底脚本，已由第 2 节的分项采集覆盖大部分内容"
fi

sec "7. 本地备份包清单（不打进归档，太大）"
for d in ${BACKUP_DIRS:-/box/vaul_bak /box/xboard_bak} ${SNAPSHOT_ROOT:-/box}; do
  [ -d "$d" ] || continue
  echo "  --- $d ($(hum "$d")) ---"
  ls -lht "$d" 2>/dev/null | head -6 | sed 's/^/    /'
done
cat <<'EOF'

  ⚠️ 这些要单独拉走：
     · 本地备份包 —— 换过备份密码的话，旧密码加密的包只有这里还有
     · premigrate_* 迁移快照 —— 整个迁移期间唯一的完整回退点
EOF

sec "8. 打包"
tar -czf "$D.tar.gz" -C "$(dirname "$D")" "$(basename "$D")" && rm -rf "$D"
chmod 600 "$D.tar.gz"
sha256sum "$D.tar.gz" > "$D.tar.gz.sha256"
ok "$D.tar.gz  $(hum "$D.tar.gz")"
echo "  内容概览:"
tar -tzf "$D.tar.gz" | awk -F/ '{print $2"/"$3}' | sort -u | head -20 | sed 's/^/    /'

cat <<EOF

  拉到本地：
    scp -P <本机SSH端口> root@<本机IP>:$D.tar.gz* ./
  在本地验证（不要只信这边的输出）：
    sha256sum -c $(basename "$D").tar.gz.sha256
    tar -tzf $(basename "$D").tar.gz | head -30

  ⚠️ 归档里含凭据（备份密码、数据库密码、rclone 的 OAuth token）。
     权限已设 600，别随手丢进同步盘或聊天工具。
EOF
