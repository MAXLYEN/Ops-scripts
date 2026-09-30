#!/usr/bin/env bash
# ops/ssh-allowlist.sh — 本机 SSH 只放行名单里的 IP（ufw）；改动当场验证，不确认就回滚
# VERSION: 1.1.2
# 1.1.2: 「新窗口能登录吗」改用公共库的 is_yes：前后空格、大小写、全角字符不再让 yes 被当成回滚。
# 1.1.1: 这次顺带改过的配置（env.conf、机群清单）记进待确认记录：定时回滚与 --rollback 连配置一起改回（生产机上试用时，运行菜单的窗口被客户端顶掉，定时回滚只回滚了防火墙，配置里留着新加的 IP）。提示里说明另开独立会话测试、窗口断了在新窗口里 --confirm。
# 1.1.0: 在终端里直接运行进菜单：列出带编号的名单，选新增（写进 ADMIN_IPS）或删除（从 ADMIN_IPS、ALLOW_EXTRA_IPS、~/.vps-hosts.txt 里一并去掉）；先看改完的防火墙变化，确认后才写配置并执行；执行后当场提示另开窗口测试，输 yes 保留，输别的或超时就立即回滚、这次改的配置一并改回（5 分钟的定时回滚照旧兜底，它只回滚防火墙）。新增 --add / --remove / --preview；不能删掉当前会话的来源。
# 1.0.0: 首版。名单 = ~/.vps-hosts.txt 里的机器 + ADMIN_IPS + ALLOW_EXTRA_IPS；按 SSH 端口加 ufw allow（注释 ssh-allowlist），加完再删「对所有来源开放」的 allow / limit 规则；只增删自己打过注释的规则；当前会话的来源 IP 不在名单里就拒绝执行；执行前备份 ufw 规则并布置 5 分钟后自动回滚，新窗口登录成功后 --confirm 取消。
# ENV-REQUIRED: ADMIN_IPS
# 用法：ssh-allowlist.sh                    菜单（在终端里运行时）：看名单、新增、删除；没有终端时等于 --preview
#       ssh-allowlist.sh --preview          列出名单与要做的改动，不动防火墙
#       ssh-allowlist.sh --add <IP或网段>    加进 ADMIN_IPS 并执行
#       ssh-allowlist.sh --remove <IP或网段> 从 ADMIN_IPS、ALLOW_EXTRA_IPS、~/.vps-hosts.txt 里去掉并执行
#       ssh-allowlist.sh --apply            按现有配置执行
#       ssh-allowlist.sh --confirm          保留新规则（没有终端、没当场确认时用）
#       ssh-allowlist.sh --rollback         马上回滚到执行前的规则
# 执行时先备份 ufw 规则、布置 5 分钟后自动回滚。在终端里会当场问你新窗口能不能登录；没有终端就要自己 --confirm。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env ADMIN_IPS
require_cmd ufw sshd python3

TAG=ssh-allowlist
UNIT=ssh-allowlist-rollback
PENDING=/var/lib/ops-scripts/ssh-allowlist.pending     # 内容：执行前规则的备份目录
HOSTS_FILE="${HOME:-/root}/.vps-hosts.txt"
KEEP_WAIT=270                                          # 当场确认等多久（秒），比定时回滚早一点
TTY=0; [ -t 0 ] && [ -t 1 ] && TTY=1
ME=${SSH_CONNECTION%% *}

ACTION=""; ARG=""
case "${1:-}" in
  '') [ "$TTY" = 1 ] && ACTION=menu || ACTION=preview ;;
  --preview) ACTION=preview ;;
  --apply) ACTION=apply ;;
  --confirm) ACTION=confirm ;;
  --rollback) ACTION=rollback ;;
  --add|--remove) ACTION=${1#--}; ARG=${2:-}; [ -n "$ARG" ] || die "$1 后面要跟 IP 或网段" ;;
  *) die "未知参数: $1（不带参数进菜单；--preview / --add / --remove / --apply / --confirm / --rollback）" ;;
esac

# ── 小工具 ──────────────────────────────────────────────────
norm() {  # norm <地址>：规范成 1.2.3.4 或 1.2.3.0/24；认不出、太宽就失败并说明
  python3 -c '
import ipaddress, sys
try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit("认不出的地址：" + sys.argv[1])
if n.prefixlen < (8 if n.version == 4 else 32):
    sys.exit("网段太宽：%s（写进去就等于没有名单）" % sys.argv[1])
print(n.network_address if n.prefixlen == n.max_prefixlen else n)
' "$1"
}

build_list() {  # build_list <ADMIN_IPS> <ALLOW_EXTRA_IPS> <机群文件>：每行「OK|BAD|WIDE<TAB>地址<TAB>来源」
  { grep -vE '^[[:space:]]*(#|$)' "$3" 2>/dev/null \
      | sed -E 's/^[^@]*@//; s/:[0-9]+[[:space:]]*$//; s/[[:space:]]//g' | sed 's/$/ 机群/'
    for a in $1; do echo "$a ADMIN_IPS"; done
    for a in $2; do echo "$a ALLOW_EXTRA_IPS"; done
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
'
}

covered() {  # covered <地址> <名单...>：地址落在名单里（含网段）
  python3 -c '
import ipaddress, sys
me = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(me in ipaddress.ip_network(n, strict=False) for n in sys.argv[2:]) else 1)
' "$@"
}

show_list() {  # show_list：带编号列出 $LIST
  awk -F'\t' '$1 == "OK" { printf "  [%2d] %-20s %s\n", ++i, $2, $3 }' <<<"$LIST"
  while IFS=$'\t' read -r t a src; do
    case "$t" in
      BAD) warn "跳过认不出的地址：$a（$src）" ;;
      WIDE) warn "跳过太宽的网段：$a（$src），写进去就等于没有名单" ;;
    esac
  done <<<"$LIST"
}

restore_rules() {  # restore_rules <备份目录>：放回执行前的 ufw 规则并重载
  cp -a "$1"/user.rules "$1"/user6.rules /etc/ufw/ && ufw reload >/dev/null
}
# PENDING 第一行是执行前 ufw 规则的备份目录，之后每行「配置备份<TAB>原位置」：这次顺带改过的配置
do_confirm() {
  local b; b=$(head -1 "$PENDING")
  systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
  rm -f "$PENDING"
  ok "已取消自动回滚，新规则保留（执行前的规则备份在 $b）"
}
do_rollback() {
  local b bak dst; b=$(head -1 "$PENDING")
  systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
  restore_rules "$b" || die "放回 $b 失败"
  ok "已回滚到执行前的规则（$b）"
  # 配置也改回去，免得配置和防火墙对不上
  while IFS=$'\t' read -r bak dst; do
    [ -n "$bak" ] && cp -a "$bak" "$dst" && ok "$dst 也改回去了"
  done < <(tail -n +2 "$PENDING")
  rm -f "$PENDING"
}

# ── 规则：算出要改什么（ADD / DEL / OPEN），列出来 ────────────
PORTS=$({ sshd -T 2>/dev/null | awk '/^port /{print $2}'
          echo "${SSH_CONNECTION:-}" | awk '{print $4}'; } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
plan() {  # plan：按 $WANT 算改动；没有改动返回 1
  local p a added have
  added=$(ufw show added 2>/dev/null | grep -E '^ufw ')
  have=$(grep -F "comment '$TAG'" <<<"$added" | sed -E 's/^ufw allow from ([^ ]+) to any port ([0-9]+) proto tcp .*/\1 \2/' | grep -E '^[^ ]+ [0-9]+$')
  OPEN="" ADD="" DEL=""
  for p in $PORTS; do
    # 不限来源的：ufw allow|limit 59967/tcp、ufw allow 59967、ufw limit in 59967/tcp 之类
    OPEN="$OPEN$(grep -E "^ufw (allow|limit)( in)? $p(/tcp)?( |\$)" <<<"$added")"$'\n'
    for a in $WANT; do grep -qxF "$a $p" <<<"$have" || ADD="$ADD$a $p"$'\n'; done
  done
  OPEN=$(grep . <<<"$OPEN")
  while read -r a p; do
    [ -n "$a" ] || continue
    grep -qxF "$a" <<<"$WANT" && [[ " $PORTS " == *" $p "* ]] || DEL="$DEL$a $p"$'\n'
  done <<<"$have"
  section "要做的改动"
  [ -n "$ADD$DEL$OPEN" ] || { ok "规则已经和名单一致，不用改"; return 1; }
  while read -r a p; do [ -n "$a" ] && echo "  + ufw allow from $a to any port $p proto tcp comment '$TAG'"; done <<<"$ADD"
  while read -r a p; do [ -n "$a" ] && echo "  - ufw delete allow from $a to any port $p proto tcp        （不在名单里了）"; done <<<"$DEL"
  while read -r a; do [ -n "$a" ] && echo "  - ufw delete ${a#ufw }        （对所有来源开放，最后删）"; done <<<"$OPEN"
  return 0
}

check_me() {  # check_me：当前会话的来源必须在 $WANT 里，否则一执行就把自己关在外面
  if [ -z "$ME" ]; then log "不是经 SSH 登录的会话（控制台？），不核对当前来源"; return 0; fi
  # shellcheck disable=SC2086
  if covered "$ME" $WANT; then ok "当前会话的来源 $ME 在名单里"; return 0; fi
  warn "当前会话的来源 $ME 不在名单里：执行后这个 IP 就连不上了"
  return 1
}

apply_changes() {  # apply_changes：备份 → 布置自动回滚 → 先加名单 → 再删多余与全开的
  local b fails=0 a p l
  [ -f "$PENDING" ] && die "上一次的改动还没确认（$PENDING）：先 --confirm 或 --rollback"
  require_cmd systemd-run
  b=/root/ops-backups/ufw.$(date -u +%Y%m%d%H%M%S)
  mkdir -p "$b" && cp -a /etc/ufw/user.rules /etc/ufw/user6.rules "$b"/ || die "备份 ufw 规则失败"
  chmod 700 "$b"
  # 这次顺带改过的配置（env.conf、机群清单）一起记下：定时回滚、--rollback 连它们一起改回，
  # 运行菜单的窗口断了也不会留下「防火墙回滚了、配置没回滚」
  local cfg="" undo=""
  [ -n "$ENV_BAK" ] && cfg="$cfg$ENV_BAK"$'\t'"$OPS_ENV_FILE"$'\n' && undo="$undo && cp -a '$ENV_BAK' '$OPS_ENV_FILE'"
  [ -n "$HOSTS_BAK" ] && cfg="$cfg$HOSTS_BAK"$'\t'"$HOSTS_FILE"$'\n' && undo="$undo && cp -a '$HOSTS_BAK' '$HOSTS_FILE'"
  systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1
  systemd-run --on-active=300 --unit="$UNIT" --description='ops-scripts: roll back ssh-allowlist' \
    /bin/sh -c "cp -a $b/user.rules $b/user6.rules /etc/ufw/ && ufw reload$undo && rm -f $PENDING" >/dev/null 2>&1 \
    || die "布置自动回滚失败，没有动防火墙"
  mkdir -p "$(dirname "$PENDING")"; printf '%s\n%s' "$b" "$cfg" > "$PENDING"
  ok "执行前的规则备份在 $b；5 分钟后自动回滚（除非确认保留）"
  while read -r a p; do
    [ -n "$a" ] || continue
    ufw allow from "$a" to any port "$p" proto tcp comment "$TAG" >/dev/null || { warn "加不上：$a → $p"; fails=$((fails + 1)); }
  done <<<"$ADD"
  # 名单有一条没加上就不删全开的规则：宁可多开，不能把人关在外面
  if [ "$fails" -gt 0 ]; then
    warn "有 $fails 条放行没加上，没有删「对所有来源开放」的规则；看清原因后 --rollback 或重跑"
    return 1
  fi
  while read -r a p; do [ -n "$a" ] && { ufw --force delete allow from "$a" to any port "$p" proto tcp >/dev/null || warn "删不掉：$a → $p"; }; done <<<"$DEL"
  while read -r l; do
    [ -n "$l" ] || continue
    l=${l#ufw }; l=${l%% comment *}     # 删除时按规则本身匹配，注释不参与
    # shellcheck disable=SC2086  # 规则要按词拆开交给 ufw
    ufw --force delete $l >/dev/null || warn "删不掉：$l"
  done <<<"$OPEN"
  ok "已按名单放行$([ -n "$OPEN" ] && echo "，SSH 端口不再对所有来源开放")"
}

keep_or_rollback() {  # 执行完：终端里当场确认，否则说明怎么确认
  section "现在就测"
  echo "  这个窗口不要关。另开一个窗口，从你平时的出口登录（端口 ${PORTS% }）"
  if [ "$TTY" = 0 ]; then
    echo "  能登录：ssh-allowlist.sh --confirm；登不上：什么都不用做，5 分钟后自动回滚，或者马上 ssh-allowlist.sh --rollback"
    return 0
  fi
  echo "  用客户端另开一个独立的会话测试，别在这个标签页里「重新连接」（有的客户端会把这个窗口顶掉）"
  echo "  这个窗口要是断了：新窗口能登录就在新窗口里 ssh-allowlist.sh --confirm；什么都不做则 5 分钟后连配置一起回滚"
  local a=""
  printf '  新窗口能登录吗？输 yes 保留新规则；输别的立即回滚（%s 秒内不输也回滚）：' "$KEEP_WAIT"
  read -r -t "$KEEP_WAIT" a || echo
  if is_yes "$a"; then do_confirm; else do_rollback; fi
}

# ── 编辑：算出新配置 → 看改动 → 确认 → 写配置 → 执行 ─────────
NEW_ADMIN="$ADMIN_IPS" NEW_EXTRA="${ALLOW_EXTRA_IPS:-}" NEW_HOSTS="" ENV_BAK="" HOSTS_BAK=""
edit_add() {  # edit_add <地址>
  local n; n=$(norm "$1") || die "没有改动"
  grep -qxF "$n" <<<"$WANT" && die "$n 已经在名单里"
  NEW_ADMIN=$(printf '%s %s' "$ADMIN_IPS" "$n" | xargs)
  log "把 $n 加进 ADMIN_IPS"
}
edit_remove() {  # edit_remove <地址>
  local n src
  n=$(norm "$1") || die "没有改动"
  src=$(awk -F'\t' -v a="$n" '$1 == "OK" && $2 == a { print $3 }' <<<"$LIST")
  [ -n "$src" ] || die "$n 不在名单里"
  [ -n "$ME" ] && [ "${n%/*}" = "$ME" ] && die "$n 是你当前会话的来源，删了马上就连不上；换一个在名单里的出口登录再删"
  NEW_ADMIN=$(for a in $ADMIN_IPS; do [ "$(norm "$a" 2>/dev/null)" = "$n" ] || printf '%s ' "$a"; done | xargs)
  NEW_EXTRA=$(for a in ${ALLOW_EXTRA_IPS:-}; do [ "$(norm "$a" 2>/dev/null)" = "$n" ] || printf '%s ' "$a"; done | xargs)
  if [[ $src == *机群* ]]; then
    NEW_HOSTS=$(mktemp)
    grep -vE "^([^@#]*@)?${n//./\\.}(:[0-9]+)?[[:space:]]*$" "$HOSTS_FILE" > "$NEW_HOSTS"
    warn "$n 是 ~/.vps-hosts.txt 里的机器：LLM 白名单、推公钥等脚本也读这份机群清单，删掉就是把它移出机群"
  fi
  log "从 ${src} 里去掉 $n"
  [[ $src == *ALLOW_EXTRA_IPS* ]] && log "ALLOW_EXTRA_IPS 也是 LLM 站点白名单的来源：之后跑一次 opsget ops/sync-llm-allowlist 同步"
}
persist() {  # 写回 env.conf 里变了的键、替换机群文件（各留 .bak）
  local ts; ts=$(date -u +%Y%m%d%H%M%S)
  if [ "$NEW_ADMIN" != "$ADMIN_IPS" ] || [ "$NEW_EXTRA" != "${ALLOW_EXTRA_IPS:-}" ]; then
    ENV_BAK="$OPS_ENV_FILE.bak.$ts"
    cp -a "$OPS_ENV_FILE" "$ENV_BAK" || die "备份 $OPS_ENV_FILE 失败"
    python3 - "$OPS_ENV_FILE" ADMIN_IPS "$NEW_ADMIN" ALLOW_EXTRA_IPS "$NEW_EXTRA" <<'PY' || die "写不了 env.conf"
import re, sys
path, kv = sys.argv[1], dict(zip(sys.argv[2::2], sys.argv[3::2]))
lines = open(path, encoding='utf-8').read().split('\n')
done = set()
for i, l in enumerate(lines):
    m = re.match(r'^([A-Z_][A-Z0-9_]*)=', l)
    if m and m.group(1) in kv and m.group(1) not in done:
        lines[i] = '%s="%s"' % (m.group(1), kv[m.group(1)])
        done.add(m.group(1))
extra = ['%s="%s"' % (k, v) for k, v in kv.items() if k not in done and v]
if extra:
    while lines and lines[-1] == '':
        lines.pop()
    lines += extra + ['']
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
PY
    ok "env.conf 已更新（原文件 $OPS_ENV_FILE.bak.$ts）"
  fi
  if [ -n "$NEW_HOSTS" ]; then
    HOSTS_BAK="$HOSTS_FILE.bak.$ts"
    cp -a "$HOSTS_FILE" "$HOSTS_BAK" && cat "$NEW_HOSTS" > "$HOSTS_FILE" && rm -f "$NEW_HOSTS" \
      || die "写不了 $HOSTS_FILE"
    ok "$HOSTS_FILE 已更新（原文件 $HOSTS_FILE.bak.$ts）"
  fi
}

# ── 动作 ────────────────────────────────────────────────────
case "$ACTION" in
  confirm)
    [ -f "$PENDING" ] || die "没有待确认的改动（$PENDING 不存在）"
    do_confirm; finish; exit $? ;;
  rollback)
    [ -f "$PENDING" ] || die "没有待确认的改动可回滚（$PENDING 不存在）；更早的备份在 /root/ops-backups/ufw.*"
    do_rollback; finish; exit $? ;;
esac

[ -n "${PORTS// /}" ] || die "确定不了 SSH 端口（sshd -T 失败？）"
[ -r "$HOSTS_FILE" ] || warn "读不到 $HOSTS_FILE：名单里只有 ADMIN_IPS 与 ALLOW_EXTRA_IPS"
LIST=$(build_list "$ADMIN_IPS" "${ALLOW_EXTRA_IPS:-}" "$HOSTS_FILE")
WANT=$(awk -F'\t' '$1 == "OK" { print $2 }' <<<"$LIST")
section "放行名单（SSH 端口：${PORTS% }）"
show_list
[ -n "$ME" ] && echo "  当前会话来源：$ME"

if [ "$ACTION" = menu ]; then
  echo
  printf '  [1] 新增  [2] 删除  [3] 只看要做的改动  [0] 退出\n  选择: '
  read -r c
  case "$c" in
    1) printf '  要放行的 IP 或网段: '; read -r ARG; ACTION=add ;;
    2) printf '  要删的编号: '; read -r c
       ARG=$(awk -F'\t' -v k="$c" '$1 == "OK" && ++i == k { print $2 }' <<<"$LIST")
       [ -n "$ARG" ] || die "没有编号 $c"
       ACTION=remove ;;
    3) ACTION=preview ;;
    *) log "没有改动"; exit 0 ;;
  esac
fi

case "$ACTION" in
  add|remove)
    "edit_$ACTION" "$ARG"
    LIST=$(build_list "$NEW_ADMIN" "$NEW_EXTRA" "${NEW_HOSTS:-$HOSTS_FILE}")
    WANT=$(awk -F'\t' '$1 == "OK" { print $2 }' <<<"$LIST")
    [ -n "$WANT" ] || die "改完名单就空了，没有改动"
    check_me || die "没有改动"
    plan || { persist; finish; exit $?; }
    [ "$TTY" = 1 ] && confirm "写进配置并执行？（执行前会另开窗口测试，不确认就回滚）"
    persist
    apply_changes || { finish; exit $?; }
    keep_or_rollback ;;
  preview|apply)
    [ -n "$WANT" ] || die "名单是空的"
    if ! check_me && [ "$ACTION" = apply ]; then
      die "先把 $ME 加进名单（ssh-allowlist.sh --add $ME），或者换一个在名单里的出口再执行"
    fi
    plan || { finish; exit $?; }
    if [ "$ACTION" = preview ]; then
      echo; log "预演结束，防火墙没动。确认后加 --apply；执行前先另开一个 SSH 窗口备用"
      finish; exit $?
    fi
    apply_changes || { finish; exit $?; }
    keep_or_rollback ;;
esac
finish
