#!/usr/bin/env bash
# db/sqlite-dsn.sh — 查看/修改存在 SQLite 里的连接串
# VERSION: 2.0.0
#
# 有些应用把数据库连接串存在自己的 SQLite 里，不是环境变量也不是配置文件。
# 换机器时这类写死的地址是隐藏地雷 —— 尤其是写了宿主机公网 IP 的：
#
#   原机公网 IP 直绑网卡 → 容器发往它的包走本地路由，源地址是容器网段，
#                          既匹配授权也过得了防火墙，所以一直正常
#   新机公网 IP 在 NAT 后 → 包发到网关就出去了，再也回不来
#
# 用法:
#   sqlite-dsn.sh scan <db文件> [特征串...]     只读扫描，密码掩码
#   sqlite-dsn.sh sethost <db文件> <旧值> <新值> [容器名]
#   sqlite-dsn.sh setpass <db文件> <用户名> [容器名]     交互输入新密码

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_cmd sqlite3 python3

ACTION=${1:-}; DB=${2:-}
[ -n "$ACTION" ] && [ -n "$DB" ] || { sed -n '15,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -f "$DB" ] || die "找不到 $DB"

stop_container() {  # 有 WAL，容器跑着改容易冲突
  [ -n "${1:-}" ] || return 0
  docker stop "$1" >/dev/null 2>&1 && log "已停止容器 $1"; sleep 2
}
start_container() {
  [ -n "${1:-}" ] || return 0
  docker start "$1" >/dev/null 2>&1 && log "已启动容器 $1"; sleep 8
  docker logs --tail 20 "$1" 2>&1 | sed 's/^/  /'
}

case "$ACTION" in
scan)
  shift 2
  PATTERNS="${*:-3306 5432 mysql:// postgres:// @tcp( ${OLD_HOST_IP:-} ${NEW_HOST_IP:-}}"
  section "扫描 $DB"
  PAT="$PATTERNS" python3 - "$DB" <<'PY'
import sqlite3, sys, re, os
db = sys.argv[1]
pats = [p for p in os.environ.get("PAT","").split() if p]
rx = re.compile("|".join(re.escape(p) for p in pats)) if pats else None
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
con.text_factory = lambda b: b.decode("utf-8","replace")
cur = con.cursor()
mask = lambda s: re.sub(r'(://[^:/@]+:|:)([^@:]{3,})(@)', r'\1***\3', s)
hits = 0
for (t,) in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
    try:
        cols = [c[1] for c in cur.execute(f'PRAGMA table_info("{t}")').fetchall()]
        rows = cur.execute(f'SELECT rowid, * FROM "{t}"').fetchall()
    except Exception:
        continue
    for r in rows:
        for c, v in zip(cols, r[1:]):
            if isinstance(v, str) and rx and rx.search(v):
                hits += 1
                print(f"  表 {t} | rowid {r[0]} | 列 {c}")
                print(f"    {mask(v)[:280]}")
con.close()
print(f"\n  共 {hits} 处命中" if hits else "\n  没有命中")
PY
  ;;

sethost)
  OLD=${3:?旧值}; NEW=${4:?新值}; CT=${5:-}
  section "把 $OLD 改成 $NEW"
  stop_container "$CT"
  B="$DB.bak.$(date -u +%Y%m%d%H%M%S)"; cp -a "$DB" "$B"; ok "已备份 $B"
  OLD="$OLD" NEW="$NEW" python3 - "$DB" <<'PY'
import sqlite3, sys, os
db, old, new = sys.argv[1], os.environ["OLD"], os.environ["NEW"]
con = sqlite3.connect(db); cur = con.cursor(); n = 0
for (t,) in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
    try: cols = [c[1] for c in cur.execute(f'PRAGMA table_info("{t}")').fetchall()]
    except Exception: continue
    for c in cols:
        try:
            cur.execute(f'UPDATE "{t}" SET "{c}" = replace("{c}", ?, ?) '
                        f'WHERE typeof("{c}")=\'text\' AND "{c}" LIKE ?',
                        (old, new, f"%{old}%"))
            if cur.rowcount > 0:
                print(f"  表 {t} 列 {c}: {cur.rowcount} 行"); n += cur.rowcount
        except Exception:
            pass
con.commit(); con.close()
print(f"  共改 {n} 行")
sys.exit(0 if n else 1)
PY
  rc=$?
  [ $rc -eq 0 ] || warn "一处都没改到 —— 确认旧值写法（先用 scan 看）"
  start_container "$CT"
  ;;

setpass)
  USER=${3:?用户名}; CT=${4:-}
  read -rsp '新密码: ' NP; echo
  [ -n "$NP" ] || die "空密码"
  case "$NP" in *[@:/]*) die "密码含 @ : / 会破坏 user:pass@host 形式的连接串，请用纯字母数字";; esac
  stop_container "$CT"
  B="$DB.bak.$(date -u +%Y%m%d%H%M%S)"; cp -a "$DB" "$B"; ok "已备份 $B"
  USERNAME="$USER" NP="$NP" python3 - "$DB" <<'PY'
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
  rc=$?
  [ $rc -eq 0 ] || warn "没找到 ${USER}:密码@ 形式的连接串"
  start_container "$CT"
  ;;

*) die "未知动作: $ACTION" ;;
esac
finish
