#!/usr/bin/env bash
# ops/apply-newapi-quota-fix.sh — 停止 new-api 后修正消费统计并校验回传
# VERSION: 1.3.0
# 1.3.0: 新增 --reprice <模型列表>：按后台当前价格重算这些模型的历史消费（fix-newapi-reprice.sh，含兜底记录、用户、令牌），
#        可带 --align-tokens、--map；新增 --dry-run：用在线备份拉一份副本预演，不停容器、不改任何东西。
#        汇总机本机装了 newapi-fullbackup.sh 时，改库前先用 cron 的同一把锁跑一次备份。
# 1.2.2: 拉库前先把 WAL 合并进主库并确认为空；删除 WAL 前再次确认，避免丢失已提交数据。
# ENV-REQUIRED: NEWAPI_HOST NEWAPI_SSH_PORT NEWAPI_DATA_DIR NEWAPI_CONTAINER NEWAPI_PUBLIC_URL
#
# 用法: apply-newapi-quota-fix.sh [--dry-run]                      修兜底倍率 37.5（原有行为）
#       apply-newapi-quota-fix.sh --reprice <模型1,模型2> [--align-tokens] [--map 旧名=参考名,...] [--dry-run]

set -o pipefail

MODE=fallback DRY=0 MODELS="" ALIGN="" MAPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reprice) MODE=reprice; MODELS="${2:-}"; shift ;;
    --align-tokens) ALIGN=--align-tokens ;;
    --map) MAPS="${2:-}"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）"; exit 1 ;;
  esac
  shift
done
[ "$MODE" = reprice ] && [ -z "$MODELS" ] && { echo "--reprice 后面要跟模型列表"; exit 1; }

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
for k in NEWAPI_HOST NEWAPI_SSH_PORT NEWAPI_DATA_DIR NEWAPI_CONTAINER NEWAPI_PUBLIC_URL; do
  eval "v=\${$k:-}"
  [ -z "$v" ] && { echo "env.conf 缺少必填项 $k"; exit 1; }
done
JP_HOST="root@${NEWAPI_HOST}"
JP_PORT="${NEWAPI_SSH_PORT}"
JP_DIR="${NEWAPI_DATA_DIR}"
CT="${NEWAPI_CONTAINER}"
FIXER="/usr/local/bin/fix-newapi-fallback-quota.sh"
FIXER2="/usr/local/bin/fix-newapi-quota-data.sh"
FIXER3="/usr/local/bin/fix-newapi-reprice.sh"
TS=$(date +%Y%m%d%H%M%S)
W="/root/newapi-quota-fix/${TS}"

log(){ printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
die(){ printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

# fix <库> [--apply]：按模式调用修正脚本
fix() {
  if [ "$MODE" = reprice ]; then
    # shellcheck disable=SC2086  # ALIGN 为空时不传
    "$FIXER3" "$1" "$MODELS" ${2:-} $ALIGN ${MAPS:+--map "$MAPS"}
  else
    # shellcheck disable=SC2086
    "$FIXER" "$1" ${2:-}
  fi
}

if [ "$MODE" = reprice ]; then
  [ -x "$FIXER3" ] || die "找不到 $FIXER3（先 opsget -i ops/fix-newapi-reprice）"
else
  [ -x "$FIXER" ] || die "找不到 $FIXER"
fi
[ -x "$FIXER2" ] || die "找不到 $FIXER2"
command -v sqlite3 >/dev/null || die "本机缺少 sqlite3"
mkdir -p "$W" || die "建不了 $W"
log "工作目录：$W"

SSH="ssh -p ${JP_PORT} ${JP_HOST}"

# 预演：落地机上用 SQLite 在线备份出一致的副本，拉回来只跑试运行；不停容器、不动落地机上的库
if [ "$DRY" = 1 ]; then
  log "预演：在线备份一份副本（容器照常运行）"
  TMPDB="/tmp/newapi-preview-${TS}.db"
  $SSH "python3 -c 'import sqlite3,sys; s=sqlite3.connect(\"file:\"+sys.argv[1]+\"?mode=ro\",uri=True,timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()' '${JP_DIR}/one-api.db' '${TMPDB}'" \
    || die "落地机在线备份失败（落地机缺 python3？）"
  scp -q -P "$JP_PORT" "${JP_HOST}:${TMPDB}" "${W}/preview.db"; RC=$?
  $SSH "rm -f '${TMPDB}'"
  [ "$RC" = 0 ] || die "拉取副本失败"
  log "  副本 $(du -h "${W}/preview.db" | cut -f1)，开始试运行"
  echo
  fix "${W}/preview.db" || die "试运行未通过（见上面的 [!!]），没有改动任何东西"
  echo
  log "预演结束：没有停容器，也没有改落地机上的库。副本留在 ${W}/preview.db"
  exit 0
fi

# 1. 备份
log "1/5 改库前先备份一次"
if [ -x /usr/local/bin/newapi-fullbackup.sh ]; then
  flock -w 900 /var/lock/newapi-fullbackup-cron.lock /usr/local/bin/newapi-fullbackup.sh \
    || die "备份失败，未做任何改动"
elif $SSH 'ls -x /usr/local/bin/newapi-fullbackup.sh >/dev/null 2>&1'; then
  $SSH '/usr/local/bin/newapi-fullbackup.sh' || die "落地机备份失败，未做任何改动"
else
  log "  [i] 两边都没有 newapi-fullbackup.sh，跳过（下面仍会留改动前副本和 .bak）"
fi

# 2. 停容器并拉库
log "2/5 停 new-api 并拉回库文件"
$SSH "docker stop ${CT}" >/dev/null || die "停容器失败"
$SSH "ls -l ${JP_DIR}/one-api.db*" | sed 's/^/  /'
# 只拉 one-api.db 的前提是 WAL 里没有数据：进程被 SIGKILL 或没关库就退出时，
# 最近已提交的事务还留在 -wal 里，只拷主文件会丢掉它们，而第 4 步还要删 -wal。
# 先在落地机上 checkpoint(TRUNCATE) 并确认 WAL 为空，否则中止。
CK=$($SSH "python3 - '${JP_DIR}/one-api.db'" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db)
busy = c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]
c.close()
w = db + "-wal"
print(busy, os.path.getsize(w) if os.path.exists(w) else 0)
PY
)
[ "$CK" = "0 0" ] || {
  $SSH "docker start ${CT}"
  die "WAL 未能合并干净（busy/剩余字节: ${CK:-无输出，落地机缺 python3？}），库可能仍被占用，已中止并重启容器"
}
log "  WAL 已合并进主库"
scp -P "$JP_PORT" "${JP_HOST}:${JP_DIR}/one-api.db" "${W}/one-api.db" || {
  $SSH "docker start ${CT}"; die "拉取失败，容器已重启"
}
cp -a "${W}/one-api.db" "${W}/one-api.db.before"
log "  拉回 $(du -h "${W}/one-api.db" | cut -f1)，改动前副本已留存"

# 3. 修正
if [ "$MODE" = reprice ]; then log "3/5 按当前价格重算（logs + users + tokens）"; else log "3/5 执行修正（logs + users）"; fi
fix "${W}/one-api.db" --apply || {
  $SSH "docker start ${CT}"; die "修正失败，落地机上的库未被改动，容器已重启"
}

log "3b/5 执行修正（quota_data 看板聚合表）"
"$FIXER2" "${W}/one-api.db" --apply || {
  $SSH "docker start ${CT}"; die "看板表修正失败，落地机上的库未被改动，容器已重启"
}

# 4. 校验后传回
log "4/5 校验并传回"
R=$(sqlite3 "${W}/one-api.db" 'PRAGMA integrity_check;')
[ "$R" = "ok" ] || { $SSH "docker start ${CT}"; die "完整性校验失败：$R，未传回"; }
LEFT=$(sqlite3 "${W}/one-api.db" "SELECT COUNT(*) FROM logs WHERE type=2 AND other LIKE '%\"model_ratio\":37.5%';")
[ "$LEFT" = 0 ] || { $SSH "docker start ${CT}"; die "仍有 ${LEFT} 条兜底记录，未传回"; }
DIFF=$(sqlite3 "${W}/one-api.db" "SELECT (SELECT SUM(quota) FROM quota_data) - (SELECT SUM(quota) FROM logs WHERE type=2);")
[ "$DIFF" = 0 ] || { $SSH "docker start ${CT}"; die "quota_data 与 logs 总额差 ${DIFF}，未传回"; }
if [ -n "$ALIGN" ]; then
  TD=$(sqlite3 "${W}/one-api.db" "SELECT COUNT(*) FROM tokens t WHERE t.used_quota <> (SELECT COALESCE(SUM(quota),0) FROM logs l WHERE l.type=2 AND l.token_id=t.id);")
  [ "$TD" = 0 ] || { $SSH "docker start ${CT}"; die "${TD} 个令牌的已用额度与日志合计不等，未传回"; }
fi

# 删 -wal 前再确认一次为空：第 2 步之后若有别的进程写过库，这里会拦下
$SSH "[ ! -s ${JP_DIR}/one-api.db-wal ] && cp -a ${JP_DIR}/one-api.db ${JP_DIR}/one-api.db.bak-${TS} && rm -f ${JP_DIR}/one-api.db-wal ${JP_DIR}/one-api.db-shm" \
  || { $SSH "docker start ${CT}"; die "落地机 WAL 非空或备份/清理失败，未传回"; }
scp -P "$JP_PORT" "${W}/one-api.db" "${JP_HOST}:${JP_DIR}/one-api.db" \
  || { $SSH "docker start ${CT}"; die "传回失败，落地机上旧库仍在 one-api.db.bak-${TS}"; }

# 5. 启动并验证
log "5/5 启动容器"
$SSH "docker start ${CT}" >/dev/null || die "启动失败"
sleep 8
$SSH "docker ps --filter name=${CT} --format '  {{.Names}}  {{.Status}}'"
$SSH "docker logs ${CT} --since 2m 2>&1 | grep -iE 'error|panic|fail' | head -5" | sed 's/^/  /'

echo
echo "===== 自检 ====="
C=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "${NEWAPI_PUBLIC_URL}" 2>/dev/null)
echo "  ${NEWAPI_PUBLIC_URL}  HTTP ${C}"
echo "  本机副本：${W}/one-api.db（改动后）、${W}/one-api.db.before（改动前）"
echo "  落地机旧库：${JP_DIR}/one-api.db.bak-${TS}"
echo
echo "  请到面板核对：用户卡片、令牌额度与「模型调用分析」的总额应一致"
