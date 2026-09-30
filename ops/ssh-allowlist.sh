#!/usr/bin/env bash
# ops/ssh-allowlist.sh — 本机 SSH 只放行名单里的 IP（ufw），执行时带 5 分钟自动回滚
# VERSION: 1.0.0
# 1.0.0: 首版。名单 = ~/.vps-hosts.txt 里的机器 + ADMIN_IPS + ALLOW_EXTRA_IPS；按 SSH 端口加 ufw allow（注释 ssh-allowlist），加完再删「对所有来源开放」的 allow / limit 规则；只增删自己打过注释的规则；当前会话的来源 IP 不在名单里就拒绝执行；执行前备份 ufw 规则并布置 5 分钟后自动回滚，新窗口登录成功后 --confirm 取消。
# ENV-REQUIRED: ADMIN_IPS
# 用法：ssh-allowlist.sh              预演：列出名单、SSH 端口现有规则与要做的改动，不动防火墙
#       ssh-allowlist.sh --apply      执行；5 分钟内不 --confirm 就自动回滚到执行前
#       ssh-allowlist.sh --confirm    新窗口能登录后运行：取消自动回滚，保留新规则
#       ssh-allowlist.sh --rollback   马上回滚到执行前的规则
# 名单变了（加了节点机、换了固定出口）就改 ~/.vps-hosts.txt 或 env.conf，再 --apply 一次。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env ADMIN_IPS
require_cmd ufw sshd python3

ACTION=preview
case "${1:-}" in
  '') ;;
  --apply) ACTION=apply ;;
  --confirm) ACTION=confirm ;;
  --rollback) ACTION=rollback ;;
  *) die "未知参数: $1（--apply / --confirm / --rollback）" ;;
esac

TAG=ssh-allowlist
UNIT=ssh-allowlist-rollback
PENDING=/var/lib/ops-scripts/ssh-allowlist.pending     # 内容：执行前规则的备份目录
HOSTS_FILE="${HOME:-/root}/.vps-hosts.txt"

restore_rules() {  # restore_rules <备份目录>：放回执行前的 ufw 规则并重载
  cp -a "$1"/user.rules "$1"/user6.rules /etc/ufw/ && ufw reload >/dev/null
}

case "$ACTION" in
  confirm)
    [ -f "$PENDING" ] || die "没有待确认的改动（$PENDING 不存在）"
    b=$(cat "$PENDING")
    systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
    rm -f "$PENDING"
    ok "已取消自动回滚，新规则保留（执行前的规则备份在 $b）"
    finish; exit $? ;;
  rollback)
    [ -f "$PENDING" ] || die "没有待确认的改动可回滚（$PENDING 不存在）；更早的备份在 /root/ops-backups/ufw.*"
    b=$(cat "$PENDING")
    systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
    restore_rules "$b" || die "放回 $b 失败"
    rm -f "$PENDING"
    ok "已回滚到执行前的规则（$b）"
    finish; exit $? ;;
esac

# ── SSH 端口：sshd 配置里的，加上当前会话连进来的那个 ─────────
PORTS=$({ sshd -T 2>/dev/null | awk '/^port /{print $2}'
          echo "${SSH_CONNECTION:-}" | awk '{print $4}'; } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
[ -n "${PORTS// /}" ] || die "确定不了 SSH 端口（sshd -T 失败？）"

# ── 名单 ────────────────────────────────────────────────────
section "放行名单（SSH 端口：${PORTS% }）"
[ -r "$HOSTS_FILE" ] || warn "读不到 $HOSTS_FILE：名单里只有 ADMIN_IPS、ALLOW_EXTRA_IPS 与本机"
LIST=$(
  { grep -vE '^[[:space:]]*(#|$)' "$HOSTS_FILE" 2>/dev/null \
      | sed -E 's/^[^@]*@//; s/:[0-9]+[[:space:]]*$//; s/[[:space:]]//g' | sed 's/$/ 机群/'
    for a in $ADMIN_IPS; do echo "$a ADMIN_IPS"; done
    for a in ${ALLOW_EXTRA_IPS:-}; do echo "$a ALLOW_EXTRA_IPS"; done
  } | python3 -c '
import ipaddress, sys
seen = {}
for line in sys.stdin:
    a, src = line.split(None, 1)
    try:
        n = ipaddress.ip_network(a, strict=False)
    except ValueError:
        print("BAD\t%s\t%s" % (a, src.strip())); continue
    if n.is_loopback or n.is_link_local:
        continue
    if n.prefixlen < (8 if n.version == 4 else 32):
        print("WIDE\t%s\t%s" % (a, src.strip())); continue
    k = str(n) if n.prefixlen != n.max_prefixlen else str(n.network_address)
    seen.setdefault(k, []).append(src.strip())
for k in sorted(seen, key=lambda s: (":" in s, s)):
    print("OK\t%s\t%s" % (k, "、".join(dict.fromkeys(seen[k]))))
')
while IFS=$'\t' read -r t a src; do
  case "$t" in
    BAD) warn "跳过认不出的地址：$a（$src）" ;;
    WIDE) warn "跳过太宽的网段：$a（$src），写进去就等于没有名单" ;;
  esac
done <<<"$LIST"
WANT=$(awk -F'\t' '$1 == "OK" { print $2 }' <<<"$LIST")
awk -F'\t' '$1 == "OK" { printf "  %-20s %s\n", $2, $3 }' <<<"$LIST"
[ -n "$WANT" ] || die "名单是空的"

# 当前会话的来源必须在名单里（含网段），否则一执行就把自己关在外面
ME=${SSH_CONNECTION%% *}
if [ -n "$ME" ]; then
  if python3 -c '
import ipaddress, sys
me = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(me in ipaddress.ip_network(n, strict=False) for n in sys.argv[2:]) else 1)
' "$ME" $WANT
  then ok "当前会话的来源 $ME 在名单里"
  else
    warn "当前会话的来源 $ME 不在名单里：执行后这个 IP 就连不上了"
    [ "$ACTION" = apply ] && die "先把 $ME 加进 ADMIN_IPS（或 ~/.vps-hosts.txt），或者换一个在名单里的出口再执行"
  fi
else
  log "不是经 SSH 登录的会话（控制台？），不核对当前来源"
fi

# ── 现有规则 ────────────────────────────────────────────────
ADDED=$(ufw show added 2>/dev/null | grep -E '^ufw ')
HAVE=$(grep -F "comment '$TAG'" <<<"$ADDED" | sed -E 's/^ufw allow from ([^ ]+) to any port ([0-9]+) proto tcp .*/\1 \2/' | grep -E '^[^ ]+ [0-9]+$')
OPEN=""
for p in $PORTS; do
  # 不限来源的：ufw allow|limit 59967/tcp、ufw allow 59967、ufw limit in 59967/tcp 之类
  OPEN="$OPEN$(grep -E "^ufw (allow|limit)( in)? $p(/tcp)?( |\$)" <<<"$ADDED")"$'\n'
done
OPEN=$(grep . <<<"$OPEN")
ADD="" DEL=""
for p in $PORTS; do
  for a in $WANT; do grep -qxF "$a $p" <<<"$HAVE" || ADD="$ADD$a $p"$'\n'; done
done
while read -r a p; do
  [ -n "$a" ] || continue
  grep -qxF "$a" <<<"$WANT" && [[ " $PORTS " == *" $p "* ]] || DEL="$DEL$a $p"$'\n'
done <<<"$HAVE"

section "要做的改动"
[ -n "$ADD$DEL$OPEN" ] || { ok "规则已经和名单一致，不用改"; finish; exit $?; }
while read -r a p; do [ -n "$a" ] && echo "  + ufw allow from $a to any port $p proto tcp comment '$TAG'"; done <<<"$ADD"
while read -r a p; do [ -n "$a" ] && echo "  - ufw delete allow from $a to any port $p proto tcp        （不在名单里了）"; done <<<"$DEL"
while read -r l; do [ -n "$l" ] && echo "  - ufw delete ${l#ufw }        （对所有来源开放，最后删）"; done <<<"$OPEN"

if [ "$ACTION" = preview ]; then
  echo
  log "预演结束，防火墙没动。确认后加 --apply；执行前先另开一个 SSH 窗口备用"
  finish; exit $?
fi

# ── 执行：备份 → 布置自动回滚 → 先加名单 → 再删多余与全开的 ─────
[ -f "$PENDING" ] && die "上一次的改动还没确认（$PENDING）：先 --confirm 或 --rollback"
require_cmd systemd-run
BAK=/root/ops-backups/ufw.$(date -u +%Y%m%d%H%M%S)
mkdir -p "$BAK" && cp -a /etc/ufw/user.rules /etc/ufw/user6.rules "$BAK"/ || die "备份 ufw 规则失败"
chmod 700 "$BAK"
systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
systemd-run --on-active=300 --unit="$UNIT" --description='ops-scripts: roll back ssh-allowlist' \
  /bin/sh -c "cp -a $BAK/user.rules $BAK/user6.rules /etc/ufw/ && ufw reload && rm -f $PENDING" >/dev/null 2>&1 \
  || die "布置自动回滚失败，没有动防火墙"
mkdir -p "$(dirname "$PENDING")"; echo "$BAK" > "$PENDING"
ok "执行前的规则备份在 $BAK；5 分钟后自动回滚（除非 --confirm）"

fails=0
while read -r a p; do
  [ -n "$a" ] || continue
  ufw allow from "$a" to any port "$p" proto tcp comment "$TAG" >/dev/null || { warn "加不上：$a → $p"; fails=$((fails + 1)); }
done <<<"$ADD"
# 名单有一条没加上就不删全开的规则：宁可多开，不能把人关在外面
if [ "$fails" -gt 0 ]; then
  warn "有 $fails 条放行没加上，没有删「对所有来源开放」的规则；看清原因后 --rollback 或重跑"
  finish; exit $?
fi
while read -r a p; do [ -n "$a" ] && { ufw --force delete allow from "$a" to any port "$p" proto tcp >/dev/null || warn "删不掉：$a → $p"; }; done <<<"$DEL"
while read -r l; do
  [ -n "$l" ] || continue
  l=${l#ufw }; l=${l%% comment *}     # 删除时按规则本身匹配，注释不参与
  # shellcheck disable=SC2086  # 规则要按词拆开交给 ufw
  ufw --force delete $l >/dev/null || warn "删不掉：$l"
done <<<"$OPEN"
ok "已按名单放行，SSH 端口不再对所有来源开放"

section "现在就测"
cat <<EOF
  1. 这个窗口不要关。另开一个窗口，从你平时的出口登录（端口 ${PORTS% }）
  2. 能登录：回到任意一个窗口运行  ssh-allowlist.sh --confirm
  3. 登不上：什么都不用做，5 分钟后自动回滚；或者在这个窗口里马上 ssh-allowlist.sh --rollback
EOF
finish
