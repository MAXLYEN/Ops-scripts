#!/usr/bin/env bash
# apply-newapi-quota-fix.sh
# VERSION: 1.1.0
# 1.1.0: 第 3 步补上 quota_data 的重算 —— logs 与 users 改了之后，看板读的是
#        按小时预聚合的 quota_data，不跟着改就会一直显示旧的虚高金额。
#
# 在落地机上停 new-api、把 SQLite 库拉回本机修正兜底计价、再传回并启动。
# 修正逻辑见 fix-newapi-fallback-quota.sh 与 fix-newapi-quota-data.sh。
#
# 注意：
# - 库拉回本机改：落地机没有 sqlite3，且本地留改动前后各一份便于回退
# - 停容器后必须删除 -wal/-shm 再拷，否则传回的库与残留 WAL 不匹配
# - 传回前校验 integrity_check 与两表总额一致，不通过则中止，不动落地机上的库
set -o pipefail

JP_HOST="root@103.100.158.215"
JP_PORT="41452"
JP_DIR="/opt/new-api/data"
FIXER="/usr/local/bin/fix-newapi-fallback-quota.sh"
FIXER2="/usr/local/bin/fix-newapi-quota-data.sh"
TS=$(date +%Y%m%d%H%M%S)
W="/root/newapi-quota-fix/${TS}"

log(){ printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
die(){ printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

[ -x "$FIXER" ] || die "找不到 $FIXER"
[ -x "$FIXER2" ] || die "找不到 $FIXER2"
command -v sqlite3 >/dev/null || die "本机缺少 sqlite3"
mkdir -p "$W" || die "建不了 $W"
log "工作目录：$W"

SSH="ssh -p ${JP_PORT} ${JP_HOST}"

# ---------- 1. 备份 ----------
log "1/5 落地机上跑一次完整备份"
$SSH 'ls -x /usr/local/bin/newapi-fullbackup.sh >/dev/null 2>&1' \
  && $SSH '/usr/local/bin/newapi-fullbackup.sh' \
  || log "  [i] 落地机上没有该脚本，备份由汇总机侧的 cron 负责，跳过"

# ---------- 2. 停容器并拉库 ----------
log "2/5 停 new-api 并拉回库文件"
$SSH "docker stop new-api" >/dev/null || die "停容器失败"
$SSH "ls -l ${JP_DIR}/one-api.db*" | sed 's/^/  /'
scp -P "$JP_PORT" "${JP_HOST}:${JP_DIR}/one-api.db" "${W}/one-api.db" || {
  $SSH "docker start new-api"; die "拉取失败，容器已重启"
}
cp -a "${W}/one-api.db" "${W}/one-api.db.before"
log "  拉回 $(du -h "${W}/one-api.db" | cut -f1)，改动前副本已留存"

# ---------- 3. 修正 ----------
log "3/5 执行修正（logs + users）"
"$FIXER" "${W}/one-api.db" --apply || {
  $SSH "docker start new-api"; die "修正失败，落地机上的库未被改动，容器已重启"
}

log "3b/5 执行修正（quota_data 看板聚合表）"
"$FIXER2" "${W}/one-api.db" --apply || {
  $SSH "docker start new-api"; die "看板表修正失败，落地机上的库未被改动，容器已重启"
}

# ---------- 4. 校验后传回 ----------
log "4/5 校验并传回"
R=$(sqlite3 "${W}/one-api.db" 'PRAGMA integrity_check;')
[ "$R" = "ok" ] || { $SSH "docker start new-api"; die "完整性校验失败：$R，未传回"; }
LEFT=$(sqlite3 "${W}/one-api.db" "SELECT COUNT(*) FROM logs WHERE type=2 AND other LIKE '%\"model_ratio\":37.5%';")
[ "$LEFT" = 0 ] || { $SSH "docker start new-api"; die "仍有 ${LEFT} 条兜底记录，未传回"; }
DIFF=$(sqlite3 "${W}/one-api.db" "SELECT (SELECT SUM(quota) FROM quota_data) - (SELECT SUM(quota) FROM logs WHERE type=2);")
[ "$DIFF" = 0 ] || { $SSH "docker start new-api"; die "quota_data 与 logs 总额差 ${DIFF}，未传回"; }

$SSH "cp -a ${JP_DIR}/one-api.db ${JP_DIR}/one-api.db.bak-${TS} && rm -f ${JP_DIR}/one-api.db-wal ${JP_DIR}/one-api.db-shm" \
  || { $SSH "docker start new-api"; die "落地机备份/清理 WAL 失败"; }
scp -P "$JP_PORT" "${W}/one-api.db" "${JP_HOST}:${JP_DIR}/one-api.db" \
  || { $SSH "docker start new-api"; die "传回失败，落地机上旧库仍在 one-api.db.bak-${TS}"; }

# ---------- 5. 启动并验证 ----------
log "5/5 启动容器"
$SSH "docker start new-api" >/dev/null || die "启动失败"
sleep 8
$SSH "docker ps --filter name=new-api --format '  {{.Names}}  {{.Status}}'"
$SSH "docker logs new-api --since 2m 2>&1 | grep -iE 'error|panic|fail' | head -5" | sed 's/^/  /'

echo
echo "===== 自检 ====="
C=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "https://k3vq.210723.xyz/" 2>/dev/null)
echo "  k3vq.210723.xyz  HTTP ${C}"
echo "  本机副本：${W}/one-api.db（改动后）、${W}/one-api.db.before（改动前）"
echo "  落地机旧库：${JP_DIR}/one-api.db.bak-${TS}"
echo
echo "  请到面板核对：用户卡片与「模型调用分析」的总额应一致"
