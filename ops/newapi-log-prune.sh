#!/usr/bin/env bash
# ops/newapi-log-prune.sh — 清理超过保留期的 new-api 消费日志
# VERSION: 1.0.2
# 1.0.2: 整理注释并补充目录文档，执行逻辑未变。
# ENV-REQUIRED: NEWAPI_PUBLIC_URL NEWAPI_ROOT_PAT NEWAPI_LOG_KEEP_DAYS
# 按配置保留期清理；低于 30 天将中止。

set -o pipefail

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

DRY=0
[ "$1" = "--dry-run" ] && DRY=1

log(){ printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn(){ printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die(){ printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

for k in NEWAPI_PUBLIC_URL NEWAPI_ROOT_PAT NEWAPI_LOG_KEEP_DAYS; do
  eval "v=\${$k:-}"
  [ -z "$v" ] && die "env.conf 缺少必填项 $k"
done
command -v curl >/dev/null || die "缺少 curl"
command -v python3 >/dev/null || die "缺少 python3"

case "$NEWAPI_LOG_KEEP_DAYS" in
  ''|*[!0-9]*) die "NEWAPI_LOG_KEEP_DAYS 必须是整数，当前值：$NEWAPI_LOG_KEEP_DAYS" ;;
esac
[ "$NEWAPI_LOG_KEEP_DAYS" -ge 30 ] || die "保留天数 ${NEWAPI_LOG_KEEP_DAYS} 小于下限 30，疑似误配，已中止"

BASE="${NEWAPI_PUBLIC_URL%/}"
PAT="$NEWAPI_ROOT_PAT"
MASK="${PAT:0:4}…${PAT: -4}[len=${#PAT}]"
TS=$(( $(date +%s) - NEWAPI_LOG_KEEP_DAYS * 86400 ))

log "目标站点：${BASE}"
log "凭据：${MASK}"
log "保留 ${NEWAPI_LOG_KEEP_DAYS} 天，删除早于 $(date -d @${TS} '+%F %T') 的日志（时间戳 ${TS}）"

if [ "$DRY" = 1 ]; then
  echo "  --dry-run，未发起请求。"
  exit 0
fi

RESP=$(curl -s -m 30 -X POST \
  -H "Authorization: Bearer ${PAT}" \
  "${BASE}/api/system-task/log-cleanup?target_timestamp=${TS}")
[ -n "$RESP" ] || die "接口无响应"

TASK=$(printf '%s' "$RESP" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception as e: print("PARSE_ERR|"+str(e)); raise SystemExit
if d.get("success") and d.get("data"):
    print("OK|%s|%s" % (d["data"].get("task_id",""), d["data"].get("status","")))
else:
    print("API_ERR|%s|%s" % (d.get("code",""), d.get("message","")))
' 2>/dev/null)

case "$TASK" in
  OK\|*) ;;
  *) die "发起失败：${TASK#*|}（凭据需为 root 用户的访问令牌）" ;;
esac
TASK_ID=$(printf '%s' "$TASK" | cut -d'|' -f2)
log "任务已建：${TASK_ID}"

log "轮询任务状态（最多 300 秒）"
FINAL=""
for i in $(seq 1 60); do
  sleep 5
  S=$(curl -s -m 20 -H "Authorization: Bearer ${PAT}" "${BASE}/api/system-task/${TASK_ID}" \
      | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("|||"); raise SystemExit
t=(d.get("data") or {})
st=(t.get("state") or {})
print("%s|%s|%s|%s" % (t.get("status",""), st.get("processed",0), st.get("total",0), t.get("error","")))
' 2>/dev/null)
  STATUS=$(printf '%s' "$S" | cut -d'|' -f1)
  PROC=$(printf '%s' "$S" | cut -d'|' -f2)
  TOTAL=$(printf '%s' "$S" | cut -d'|' -f3)
  ERR=$(printf '%s' "$S" | cut -d'|' -f4)
  printf '  [%3ds] status=%-10s processed=%-8s total=%s\n' "$((i*5))" "${STATUS:-?}" "${PROC:-?}" "${TOTAL:-?}"
  case "$STATUS" in
    completed|succeeded|success|finished|done) FINAL="$STATUS"; break ;;
    failed|error)  die "任务失败：${ERR}" ;;
  esac
done

[ -n "$FINAL" ] || { warn "300 秒内未完成，任务仍在后台运行，稍后到面板查看 ${TASK_ID}"; exit 0; }

echo
echo "===== 结果 ====="
echo "  任务 ${TASK_ID}  ${FINAL}"
echo "  已处理 ${PROC} 条"
