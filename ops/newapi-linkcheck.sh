#!/usr/bin/env bash
# ops/newapi-linkcheck.sh — 检查 new-api 隧道和公网访问全链路
# VERSION: 1.1.0
# 1.1.0: 探测不通先隔 NEWAPI_LINK_RETRY_WAIT 秒（默认 20）再探一次，两次都不通才算失败：原先单次不通就报 /fail，而 Healthchecks 收到失败信号会立刻标 DOWN 并通知（宽限期只管「到点没收到信号」），线路抖一下就是一封 DOWN。内层重探后仍不通才重启隧道；重探后恢复的记一行日志，事后能数出抖了几次。
# 1.0.3: webhook 的 JSON 正确转义（正文含引号或换行时原先会发送失败）。
# ENV-REQUIRED: NEWAPI_TUNNEL_UNIT NEWAPI_LOCAL_URL NEWAPI_PUBLIC_URL

set -o pipefail

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

LOG="${NEWAPI_LINKCHECK_LOG:-/var/log/newapi-linkcheck.log}"
LOCAL_TIMEOUT="${NEWAPI_LOCAL_TIMEOUT:-10}"
PUBLIC_TIMEOUT="${NEWAPI_PUBLIC_TIMEOUT:-20}"
RESTART_STATE="${NEWAPI_RESTART_STATE:-/var/lib/ops-scripts/newapi-tunnel-restarts}"
ALERT_FALLBACK_FILE="${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
# 24 小时内重启超过这个次数就告警：隧道频繁重启本身是信号
RESTART_ALERT_THRESHOLD="${NEWAPI_RESTART_ALERT_THRESHOLD:-3}"
# 不通时隔多久再探一次：抖一下就恢复的不算失败
RETRY_WAIT="${NEWAPI_LINK_RETRY_WAIT:-20}"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*" >> "$LOG"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*" >> "$LOG"; }
fail() { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*" >> "$LOG"; }

hb() {
  [ -z "${NEWAPI_LINK_HEARTBEAT_URL:-}" ] && return 0
  curl -fsS -m 10 --retry 2 "${NEWAPI_LINK_HEARTBEAT_URL}$1" >/dev/null 2>&1 || true
}

# webhook 的 JSON 要转义：正文是日志尾部，含引号、反斜杠或换行时原样拼进去
# JSON 就坏了，webhook 静默失败，告警只剩本地落盘那一份
json_esc() {
  printf '%s' "$1" | tr -d '\r' \
    | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); if (NR>1) print "\\n"; print}'
}

send_mail() {
  local subject="$1" body="$2"
  if command -v msmtp >/dev/null 2>&1 && [ -n "${MAIL_TO:-}" ]; then
    for _ in 1 2 3; do
      printf 'To: %s\nSubject: %s\n\n%s\n' "$MAIL_TO" "$subject" "$body" \
        | msmtp -t 2>>"$LOG" && return 0
      sleep 20
    done
  fi
  if [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -fsS -m 15 -X POST "$ALERT_WEBHOOK" -H 'Content-Type: application/json' \
      --data "{\"text\":\"$(json_esc "$subject"$'\n'"$body")\"}" \
      >/dev/null 2>&1 && return 0
  fi
  printf '%s %s\n%s\n---\n' "$(date -u '+%F %T')" "$subject" "$body" \
    >> "$ALERT_FALLBACK_FILE" 2>/dev/null
  return 1
}

require_env() {
  local k v
  for k in "$@"; do
    eval "v=\${$k:-}"
    [ -z "$v" ] && { fail "env.conf 缺少必填项 $k"; exit 1; }
  done
}

require_env NEWAPI_TUNNEL_UNIT NEWAPI_LOCAL_URL NEWAPI_PUBLIC_URL

probe() {  # $1=url $2=timeout  -> 打印 HTTP 码
  curl -s -o /dev/null -w '%{http_code}' -m "$2" "$1" 2>/dev/null
}

# probe2 <url> <timeout> <内层|外层>：不通就隔 RETRY_WAIT 秒再探一次，打印第二次的结果
probe2() {
  local c
  c=$(probe "$1" "$2")
  [ "$c" = "200" ] && { printf '%s' "$c"; return; }
  sleep "$RETRY_WAIT"
  c=$(probe "$1" "$2")
  [ "$c" = "200" ] && log "$3 第一次探测不通，${RETRY_WAIT} 秒后重探恢复（线路抖动，不算失败）"
  printf '%s' "$c"
}

# 记一次重启，返回 24h 内的累计次数
record_restart() {
  local now dir
  now=$(date -u +%s)
  dir=$(dirname "$RESTART_STATE"); mkdir -p "$dir" 2>/dev/null
  echo "$now" >> "$RESTART_STATE"
  # 只保留 24 小时内的记录
  awk -v cut=$((now - 86400)) '$1 >= cut' "$RESTART_STATE" > "${RESTART_STATE}.tmp" 2>/dev/null \
    && mv "${RESTART_STATE}.tmp" "$RESTART_STATE"
  wc -l < "$RESTART_STATE" | tr -d ' '
}

# 内层：隧道端口
RESTARTED=0
CODE=$(probe2 "$NEWAPI_LOCAL_URL" "$LOCAL_TIMEOUT" 内层)

if [ "$CODE" != "200" ]; then
  warn "内层探测失败（HTTP ${CODE:-无响应}），重启 $NEWAPI_TUNNEL_UNIT"
  systemctl restart "$NEWAPI_TUNNEL_UNIT" >>"$LOG" 2>&1
  RESTARTED=1
  sleep 8
  CODE=$(probe "$NEWAPI_LOCAL_URL" "$LOCAL_TIMEOUT")
  if [ "$CODE" = "200" ]; then
    log "重启后内层恢复（HTTP 200）"
  else
    fail "重启后内层仍不通（HTTP ${CODE:-无响应}）"
  fi

  N=$(record_restart)
  if [ "${N:-0}" -ge "$RESTART_ALERT_THRESHOLD" ]; then
    warn "24 小时内已重启 ${N} 次，超过阈值 ${RESTART_ALERT_THRESHOLD}"
    send_mail "[WARN] new-api 隧道 24h 内重启 ${N} 次" \
      "$(printf '最近一次内层 HTTP: %s\n落地机: %s\n\n%s\n' \
         "${CODE:-无响应}" "${NEWAPI_HOST:-未配置}" "$(tail -n 30 "$LOG")")"
  fi
fi

INNER_OK=0
[ "$CODE" = "200" ] && INNER_OK=1

# 外层：公网全链路
PCODE=$(probe2 "$NEWAPI_PUBLIC_URL" "$PUBLIC_TIMEOUT" 外层)
OUTER_OK=0
[ "$PCODE" = "200" ] && OUTER_OK=1

# 结论
if [ "$INNER_OK" = 1 ] && [ "$OUTER_OK" = 1 ]; then
  [ "$RESTARTED" = 1 ] \
    && log "正常（本轮重启过隧道）内层=200 外层=200" \
    || log "正常 内层=200 外层=200"
  hb ""
  exit 0
fi

# 走到这里是重探一次仍不通。只 ping /fail，不另发邮件：Healthchecks 收到失败信号
# 会立刻标 DOWN 并通知，下一轮恢复了再发一封 UP
if [ "$INNER_OK" = 0 ]; then
  fail "内层不通 内层=${CODE:-无响应} 外层=${PCODE:-无响应}"
else
  fail "内层通但外层不通（nginx / 证书 / 域名侧问题）内层=200 外层=${PCODE:-无响应}"
fi
hb /fail
exit 1
