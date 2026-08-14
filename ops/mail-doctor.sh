#!/usr/bin/env bash
# ops/mail-doctor.sh — 告警邮件链路诊断
# VERSION: 1.0.1
# 1.0.1 修正：失败计数把 exitcode=EX_OK 也算进去了，导致"1 成功 1 失败"被报成"2 次失败"
#
# 备份脚本"失败了会发邮件"这件事，只有真发过一次才算数。
# 本脚本从配置、连通性、实发三个层面查，并打印 msmtp 自己的错误。
#
# 用法: mail-doctor.sh          只诊断，不发信
#       mail-doctor.sh --send   诊断并实际发一封测试邮件

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

SEND=0; [ "${1:-}" = "--send" ] && SEND=1
RC=/etc/msmtprc

section "1. 配置文件"
if [ -f "$RC" ]; then
  printf '  权限: %s（应为 600）\n' "$(stat -c %a "$RC")"
  # 打印结构但不泄露密码
  sed -E 's/^(password|passwordeval)[[:space:]].*/\1 <已省略>/' "$RC" | sed 's/^/  /'
else
  die "没有 $RC —— 备份失败时不会有任何告警"
fi

ACCOUNTS=$(grep -E '^account ' "$RC" | awk '{print $2}' | grep -v ':' | tr '\n' ' ')
DEFAULT=$(grep -E '^account default' "$RC" | sed 's/.*: *//')
echo "  账号: ${ACCOUNTS:-无}   默认: ${DEFAULT:-未设置}"
[ -n "$DEFAULT" ] || warn "没有 'account default : xxx' 那一行，msmtp -t 会不知道用哪个账号"

section "2. 收件地址"
echo "  env.conf 的 MAIL_TO: ${MAIL_TO:-未设置}"
[ -n "${MAIL_TO:-}" ] || warn "MAIL_TO 为空 —— 脚本里的 notify() 会直接 return，什么都不发"
echo "  webhook 兜底: ${ALERT_WEBHOOK:-未配置}"
echo "  落盘兜底: ${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"

section "3. 名字解析顺序"
# ENETUNREACH（Network is unreachable）常见于「解析先给了 IPv6，而本机没有全局 IPv6」。
# 判据：IPv4 是否排在前面 + 有没有 IPv6 默认路由。
HOST=$(grep -E '^host ' "$RC" | head -1 | awk '{print $2}')
PORT=$(grep -E '^port ' "$RC" | head -1 | awk '{print $2}')
if [ -n "$HOST" ]; then
  getent ahosts "$HOST" | awk '$2=="STREAM"{print "  "$1}'
  FIRST=$(getent ahosts "$HOST" | awk '$2=="STREAM"{print $1; exit}')
  case "$FIRST" in
    *:*) warn "解析先给 IPv6（$FIRST）";
         ip -6 route show default | grep -q . \
           && echo "     有 IPv6 默认路由，问题可能不在这" \
           || echo "     且没有 IPv6 默认路由 —— 这会立刻 ENETUNREACH，检查 /etc/gai.conf" ;;
    *)   ok "IPv4 优先（$FIRST）" ;;
  esac
fi

section "4. SMTP 连通性"
echo "  目标: ${HOST:-?}:${PORT:-?}"
if [ -n "$HOST" ] && [ -n "$PORT" ]; then
  if timeout 8 bash -c "cat < /dev/null > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
    ok "TCP 可达"
  else
    warn "连不上 ${HOST}:${PORT} —— 端口被封或地址写错"
    echo "     很多云厂商默认封 25，用 465(SSL) 或 587(STARTTLS)"
  fi
fi

section "5. msmtp 自检"
# --serverinfo 会真的连上去握手，能一次性暴露证书、端口、TLS 模式的问题
msmtp --serverinfo --host="$HOST" --port="$PORT" \
      $([ "$PORT" = 465 ] && echo --tls --tls-starttls=off || echo --tls) 2>&1 \
  | head -12 | sed 's/^/  /'

section "6. 发信历史"
LOGF=$(grep -E '^logfile ' "$RC" | head -1 | awk '{print $2}')
LOGF="${LOGF:-/var/log/msmtp.log}"
if [ -f "$LOGF" ]; then
  TOTAL=$(grep -c 'exitcode=' "$LOGF" 2>/dev/null)
  # 只数非 EX_OK 的才是失败 —— EX_OK 也带 exitcode= 前缀
  FAILS=$(grep 'exitcode=' "$LOGF" 2>/dev/null | grep -vc 'exitcode=EX_OK')
  printf '  共 %s 次投递，失败 %s 次\n' "${TOTAL:-0}" "${FAILS:-0}"
  if [ "${FAILS:-0}" -gt 0 ]; then
    echo "  失败记录:"
    grep 'exitcode=' "$LOGF" | grep -v 'exitcode=EX_OK' | tail -5 | sed 's/^/    /'
    echo
    echo "  怎么读这个数：偶发 1~2 次是网络抖动，重试机制已覆盖；"
    echo "  每周都在涨说明是系统性问题（端口被限、授权码失效、解析顺序），值得深查。"
  fi
  echo "  最近 5 条:"; tail -5 "$LOGF" | sed 's/^/    /'
else
  warn "没有 $LOGF —— msmtp 从来没被调用过，或 logfile 没配"
fi

section "7. 备份脚本日志里的告警"
for f in "${VW_LOG_FILE:-/var/log/vw-fullbackup.log}" /var/log/vw-fullbackup-cron.log \
         "${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"; do
  [ -f "$f" ] || continue
  hits=$(grep -iE '告警邮件|未送达|msmtp' "$f" | tail -5)
  [ -n "$hits" ] && { echo "  --- $f ---"; echo "$hits" | sed 's/^/    /'; }
done

if [ "$SEND" -eq 0 ]; then
  section 下一步
  echo "  诊断完毕。实际发一封测试邮件："
  echo "    $(basename "$0") --send"
  finish; exit $?
fi

section "8. 实发测试"
[ -n "${MAIL_TO:-}" ] || die "MAIL_TO 为空，无法发送"
printf 'To: %s\nSubject: [%s] 告警链路测试\nContent-Type: text/plain; charset=UTF-8\n\n这封信证明备份失败时你能收到告警。\n\n主机: %s\n时间: %s UTC\n' \
  "$MAIL_TO" "$(hostname)" "$(hostname)" "$(date -u '+%F %T')" | msmtp -t
SRC=$?
if [ $SRC -eq 0 ]; then
  ok "msmtp 返回 0 —— 已投递给 SMTP 服务器"
  echo "  但这只说明服务器收下了。**去邮箱确认真的收到**，"
  echo "  收不到就看垃圾箱，再看 $LOGF 里这一条的 exitcode。"
else
  warn "msmtp 退出码 $SRC"
  tail -5 "$LOGF" 2>/dev/null | sed 's/^/    /'
fi
finish
