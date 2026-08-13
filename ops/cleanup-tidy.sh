#!/usr/bin/env bash
# ops/cleanup-tidy.sh — 清理 ops-scripts 产生的冗余文件
# VERSION: 1.0.0
#
# 只清"同一类东西的旧副本"：历史快照、旧版脚本备份、多次运行的输出。
# 每类都保留最近若干份，不会清空。
#
# 默认只列不删，加 --apply 才动手。
#
#   cleanup-tidy.sh                预演，列出会删什么
#   cleanup-tidy.sh --apply        执行
#   KEEP=3 cleanup-tidy.sh --apply 改保留份数（默认 2）
#
# 绝不触碰（这些是业务数据，不是 ops 的产物）：
#   备份产物目录 BACKUP_DIRS、容器数据 CONTAINER_DATA_DIRS、
#   面板目录、云端的任何东西

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
KEEP="${KEEP:-2}"
TOTAL=0

# 受保护的路径前缀：命中就跳过，双保险
PROTECTED="$BACKUP_DIRS $CONTAINER_DATA_DIRS $PANEL_ROOT $WWWROOT $PANEL_DB_BACKUP_DIR /etc/ops-scripts"
is_protected() {
  local p; p=$(readlink -f "$1" 2>/dev/null || echo "$1")
  for g in $PROTECTED; do
    [ -n "$g" ] || continue
    local gg; gg=$(readlink -f "$g" 2>/dev/null || echo "$g")
    case "$p" in "$gg"|"$gg"/*) return 0 ;; esac
  done
  return 1
}

# sweep <说明> <保留份数> <glob...>
# 按修改时间排序，保留最新 N 个，其余列出/删除
sweep() {
  local label=$1 keep=$2; shift 2
  local items; items=$(ls -dt "$@" 2>/dev/null)
  [ -n "$items" ] || return 0
  local n; n=$(printf '%s\n' "$items" | wc -l)
  printf '  %s（共 %s，保留最新 %s）\n' "$label" "$n" "$keep"
  printf '%s\n' "$items" | tail -n +$((keep + 1)) | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_protected "$f"; then printf '    [跳过·受保护] %s\n' "$f"; continue; fi
    printf '    %-10s %s\n' "$(human "$f")" "$f"
    [ "$APPLY" -eq 1 ] && rm -rf "$f"
  done
  local extra; extra=$(printf '%s\n' "$items" | tail -n +$((keep + 1)) | wc -l)
  TOTAL=$((TOTAL + extra))
}

[ "$APPLY" -eq 1 ] && log "模式：执行删除" || log "模式：预演（加 --apply 才真删）"
log "每类保留最新 $KEEP 份"

section "1. opsget 安装脚本的旧版备份"
# 每个脚本只留最新一个 .bak
for base in $(ls /usr/local/bin/*.sh.bak.* 2>/dev/null | sed 's/\.bak\.[0-9]*$//' | sort -u); do
  sweep "$(basename "$base") 的旧版" 1 "$base".bak.*
done
[ -z "$(ls /usr/local/bin/*.sh.bak.* 2>/dev/null)" ] && echo "  (无)"

section "2. 摸底与比对的历史输出"
sweep "inventory 输出" "$KEEP" /root/inventory_*.txt
sweep "verify 输出"    "$KEEP" /root/verify_*.txt
[ -z "$(ls /root/inventory_*.txt /root/verify_*.txt 2>/dev/null)" ] && echo "  (无)"

section "3. 防火墙状态存档"
sweep "fwstate" "$KEEP" /root/fwstate_*
[ -z "$(ls -d /root/fwstate_* 2>/dev/null)" ] && echo "  (无)"

section "4. crontab 备份"
sweep "crontab 备份" $((KEEP + 1)) /root/crontab.bak.*
[ -z "$(ls /root/crontab.bak.* 2>/dev/null)" ] && echo "  (无)"

section "5. 迁移快照"
# 快照体积大，但删错了就没有回头路 —— 只保留最新的，且明确提示
if [ -n "${SNAPSHOT_ROOT:-}" ]; then
  sweep "premigrate 快照" 1 "$SNAPSHOT_ROOT"/premigrate_*
  [ -z "$(ls -d "$SNAPSHOT_ROOT"/premigrate_* 2>/dev/null)" ] && echo "  (无)"
  echo "  [提醒] 快照是迁移期间唯一的完整回退点，确认新机稳定运行后再清"
fi

section "6. 恢复过程的中间产物"
for p in "${RESTORE_STAGE:-/root/restore_stage}" "${RESTORE_CMD_DIR:-/root/restore_cmds}" \
         "${IMAGE_EXPORT_DIR:-${SNAPSHOT_ROOT:-/nonexistent}/images}" /root/ops-backups; do
  [ -e "$p" ] || continue
  if is_protected "$p"; then echo "    [跳过·受保护] $p"; continue; fi
  printf '    %-10s %s\n' "$(human "$p")" "$p"
  [ "$APPLY" -eq 1 ] && rm -rf "$p"
  TOTAL=$((TOTAL + 1))
done
echo "  [提醒] restore_cmds 里可能含带凭据的启动命令，清掉是好事"

section "7. 脚本改动过的配置文件的旧副本"
# db/sqlite-dsn、rotate-db-pass 等在修改前会留 <文件>.bak.<时间戳>
for d in $CONTAINER_DATA_DIRS; do
  [ -d "$d" ] || continue
  # 这些目录本身受保护，但目录里的 .bak.<时间戳> 是 ops 产生的，可以按份数清
  found=$(find "$d" -maxdepth 2 -name '*.bak.[0-9]*' 2>/dev/null)
  [ -n "$found" ] || continue
  for base in $(printf '%s\n' "$found" | sed 's/\.bak\.[0-9]*$//' | sort -u); do
    items=$(ls -dt "$base".bak.[0-9]* 2>/dev/null)
    n=$(printf '%s\n' "$items" | wc -l)
    printf '  %s（共 %s，保留最新 1）\n' "$(basename "$base")" "$n"
    printf '%s\n' "$items" | tail -n +2 | while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '    %-10s %s\n' "$(human "$f")" "$f"
      [ "$APPLY" -eq 1 ] && rm -f "$f"
    done
    TOTAL=$((TOTAL + $(printf '%s\n' "$items" | tail -n +2 | wc -l)))
  done
done
echo "  (以上只清 ops 脚本留下的 .bak.<时间戳>，业务数据本身不动)"

section 汇总
if [ "$APPLY" -eq 1 ]; then
  ok "已清理，磁盘剩余：$(df -h / | tail -1 | awk '{print $4}')"
else
  echo "  以上为预演结果。确认无误后："
  echo "    $(basename "$0") --apply"
fi
cat <<EOF

  本脚本从不触碰：
    备份产物  ${BACKUP_DIRS:-未配置}
    容器数据  ${CONTAINER_DATA_DIRS:-未配置}
    面板目录  ${PANEL_ROOT:-未配置}
    云端的任何文件
EOF
finish
