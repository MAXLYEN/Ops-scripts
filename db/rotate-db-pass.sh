#!/usr/bin/env bash
# db/rotate-db-pass.sh — 轮换数据库密码并核对所有 host 记录
# VERSION: 2.0.4
# 2.0.4: 校验经 NEWPASS 传入的密码字符，含 ' \ @ : / 时拒绝。
# 用法: rotate-db-pass.sh check|rotate <用户名> [下游sqlite] [容器名]

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
mysql_ready

ACTION=${1:-}; USER=${2:-}
[ -n "$ACTION" ] && [ -n "$USER" ] || {
  printf '%s\n' \
    '用法: rotate-db-pass.sh check <用户名>' \
    '      rotate-db-pass.sh rotate <用户名> [下游sqlite] [容器名]'
  exit 1
}

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
  # 手工经 NEWPASS 传入时：' 和 \ 会破坏 ALTER USER 语句，@ : / 会破坏 user:pass@host 连接串
  case "$NEWPASS" in *[\'\\@:/]*) die "NEWPASS 不能含 ' \\ @ : / 这几个字符" ;; esac
  section "新密码"
  echo "  $NEWPASS"
  echo "  ↑ 现在就抄下来，脚本不会再显示第二次"
  confirm "开始轮换？"

  [ -n "$CT" ] && { docker stop "$CT" >/dev/null 2>&1 && log "已停止容器 $CT"; sleep 2; }

  section "改 MySQL（所有 host 记录）"
  # 用进程替换而不是管道：管道里的 while 是子 shell，失败记录传不出来
  FAILED_HOSTS=""
  while read -r h; do
    [ -z "$h" ] && continue
    # SQL 走 stdin 而不是 -e：-e 的参数（含新密码）同机任何用户都能从 /proc 读到
    if printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$USER" "$h" "$NEWPASS" | my; then
      ok "$USER@'$h'"
    else
      warn "$USER@'$h' 失败"; FAILED_HOSTS="$FAILED_HOSTS '$h'"
    fi
  done < <(myq "SELECT host FROM mysql.user WHERE user='$USER'")
  my -e "FLUSH PRIVILEGES"

  # 有 host 没改成就停在这里：继续改下游，服务会拿新密码去连一个还是旧密码的账号
  if [ -n "$FAILED_HOSTS" ]; then
    [ -n "$CT" ] && { docker start "$CT" >/dev/null 2>&1 && log "已启动容器 $CT"; }
    show_state
    die "以下 host 改密失败:$FAILED_HOSTS —— 下游连接串未改动。排查后用同一个密码重跑：NEWPASS='<上面显示的新密码>' $(basename "$0") rotate $USER ${DOWNSTREAM:+$DOWNSTREAM }$CT"
  fi

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
