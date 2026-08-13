#!/usr/bin/env bash
# db/rotate-db-pass.sh — 轮换数据库账号密码
# VERSION: 2.0.0
#
# 一个账号常有多条 host 记录（如 172.% 和 localhost）。面板改密码时
# **只会改它自己记录的那个 host**，另一条会留着旧密码 —— 状态不一致，
# 且下游改完连接串后立刻挂。所以改完必须核对所有 host 的密码哈希一致。
#
# 用法:
#   rotate-db-pass.sh check <用户名>              只读核对（改前改后各跑一次）
#   rotate-db-pass.sh rotate <用户名> [下游sqlite] [容器名]
#
# 只用字母数字生成密码：user:pass@host 形式的连接串里 @ : / 都是分隔符。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
mysql_ready

ACTION=${1:-}; USER=${2:-}
[ -n "$ACTION" ] && [ -n "$USER" ] || { sed -n '12,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

show_state() {
  section "$USER 的 host 记录与密码哈希"
  my -e "SELECT host,
                LEFT(authentication_string, 12) AS 哈希前12位,
                plugin
           FROM mysql.user WHERE user='$USER' ORDER BY host"
  local distinct
  distinct=$(myq "SELECT COUNT(DISTINCT authentication_string) FROM mysql.user WHERE user='$USER'")
  local total
  total=$(myq "SELECT COUNT(*) FROM mysql.user WHERE user='$USER'")
  echo "  记录数 $total，不同哈希 $distinct"
  if [ "$total" -gt 1 ] && [ "$distinct" -gt 1 ]; then
    warn "多条 host 的密码不一致 —— 说明只改到了其中一部分"
    echo "  补齐: ALTER USER '$USER'@'<落下的host>' IDENTIFIED BY '<新密码>';"
  fi
}

case "$ACTION" in
check)
  show_state
  section "当前活跃连接来源"
  my -e "SELECT user, LEFT(host, LOCATE(':',CONCAT(host,':'))-1) AS src, db, COUNT(*) AS conns
           FROM information_schema.processlist WHERE user='$USER' GROUP BY user, src, db"
  echo "  （改密码后旧连接还能活一阵，看起来正常 —— 连接池重建时才会暴露问题）"
  ;;

rotate)
  DOWNSTREAM=${3:-}; CT=${4:-}
  show_state

  NEWPASS="${NEWPASS:-$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)}"
  [ ${#NEWPASS} -ge 24 ] || die "密码太短"
  section "新密码"
  echo "  $NEWPASS"
  echo "  ↑ 现在就抄下来，脚本不会再显示第二次"
  confirm "开始轮换？"

  [ -n "$CT" ] && { docker stop "$CT" >/dev/null 2>&1 && log "已停止容器 $CT"; sleep 2; }

  section "改 MySQL（所有 host 记录）"
  myq "SELECT host FROM mysql.user WHERE user='$USER'" | while read -r h; do
    [ -z "$h" ] && continue
    my -e "ALTER USER '$USER'@'$h' IDENTIFIED BY '$NEWPASS'" \
      && ok "$USER@'$h'" || warn "$USER@'$h' 失败"
  done
  my -e "FLUSH PRIVILEGES"

  if [ -n "$DOWNSTREAM" ] && [ -f "$DOWNSTREAM" ]; then
    section "改下游连接串 $DOWNSTREAM"
    B="$DOWNSTREAM.bak.$(date -u +%Y%m%d%H%M%S)"; cp -a "$DOWNSTREAM" "$B"; ok "已备份 $B"
    USERNAME="$USER" NP="$NEWPASS" python3 - "$DOWNSTREAM" <<'PY'
import sqlite3, sys, re, os
db, u, np = sys.argv[1], os.environ["USERNAME"], os.environ["NP"]
con = sqlite3.connect(db); cur = con.cursor(); n = 0
pat = re.compile(rf'({re.escape(u)}:)[^@]+(@)')
for (t,) in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
    try:
        cols = [c[1] for c in cur.execute(f'PRAGMA table_info("{t}")').fetchall()]
        rows = cur.execute(f'SELECT rowid, * FROM "{t}"').fetchall()
    except Exception: continue
    for r in rows:
        for c, v in zip(cols, r[1:]):
            if isinstance(v, str) and pat.search(v):
                cur.execute(f'UPDATE "{t}" SET "{c}"=? WHERE rowid=?',
                            (pat.sub(r'\1'+np+r'\2', v), r[0]))
                print(f"  表 {t} rowid {r[0]} 列 {c} 已更新"); n += 1
con.commit(); con.close()
print(f"  共改 {n} 处")
sys.exit(0 if n else 1)
PY
    [ $? -eq 0 ] || warn "下游没改到 —— 用 db/sqlite-dsn.sh scan 确认连接串写法"
  elif [ -n "$DOWNSTREAM" ]; then
    warn "下游文件不存在: $DOWNSTREAM"
  fi

  [ -n "$CT" ] && { docker start "$CT" >/dev/null 2>&1 && log "已启动容器 $CT"; sleep 10
                    docker logs --tail 20 "$CT" 2>&1 | sed 's/^/  /'; }

  show_state
  section "连接来源确认"
  my -e "SELECT user, LEFT(host, LOCATE(':',CONCAT(host,':'))-1) AS src, db, COUNT(*) AS conns
           FROM information_schema.processlist WHERE user='$USER' GROUP BY user, src, db"

  cat <<EOF

  别忘了：如果这个库是由某个面板创建的，面板自己也存了一份密码。
  不同步的话，以后在面板里对这个库做任何操作，它都会用旧密码重建账号。
  处理方式二选一：直接在面板里改密码（然后再跑一次本脚本的 check 核对），
  或手动同步面板的记录。
EOF
  ;;

*) die "未知动作: $ACTION" ;;
esac
finish
