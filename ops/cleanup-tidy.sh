#!/usr/bin/env bash
# ops/cleanup-tidy.sh — 清理历史输出、旧版备份与中间产物
# VERSION: 1.1.2
# 1.1.2: 第 7 节改为只列出容器数据目录里的 .bak 旧副本（原先想按份数删，却总被保护名单拦下，从未生效）。
# 默认预演，--apply 才执行清理。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
KEEP="${KEEP:-2}"
TOTAL=0
BYTES=0
KEPT=""      # 无需清理的类别，折叠到末尾一行带过
SECBUF=""    # 当前小节的内容；为空则连标题都不打印

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

bytes_of() { du -sb "$1" 2>/dev/null | cut -f1; }
emit()     { SECBUF="$SECBUF$*\n"; }

# 小节标题只在真有内容时才打印，避免七个空标题淹没唯一有用的那条
sec() {
  if [ -n "$SECBUF" ]; then
    section "$1"
    printf '%b' "$SECBUF"
  fi
  SECBUF=""
}

# 记一项待删：累计数量与体积，APPLY 时才真删
take() {
  local f=$1
  [ -n "$f" ] || return 0
  if is_protected "$f"; then emit "$(printf '    [跳过·受保护] %s' "$f")"; return 0; fi
  emit "$(printf '    %-10s %s' "$(human "$f")" "$f")"
  local b; b=$(bytes_of "$f"); BYTES=$((BYTES + ${b:-0}))
  TOTAL=$((TOTAL + 1))
  [ "$APPLY" -eq 1 ] && rm -rf "$f"
  return 0
}

# sweep <说明> <保留份数> <glob...>
# 按修改时间排序，保留最新 N 个，其余列出/删除
sweep() {
  local label=$1 keep=$2; shift 2
  local items; items=$(ls -dt "$@" 2>/dev/null)
  [ -n "$items" ] || return 0
  local n; n=$(printf '%s\n' "$items" | wc -l)
  local extras; extras=$(printf '%s\n' "$items" | tail -n +$((keep + 1)))
  # 份数没超标就不是「待清理」，折叠起来
  if [ -z "$extras" ]; then
    KEPT="$KEPT    $label：$n 份，均在保留范围内\n"
    return 0
  fi
  emit "$(printf '  %s（共 %s，保留最新 %s，清理 %s）' \
          "$label" "$n" "$keep" "$(printf '%s\n' "$extras" | wc -l)")"
  # 用 here-doc 而不是管道：管道里的 while 是子 shell，
  # TOTAL/BYTES 加完就丢了（原来 TOTAL 算不准就是这个原因的近亲）
  while IFS= read -r f; do take "$f"; done <<EOF
$extras
EOF
}

[ "$APPLY" -eq 1 ] && log "模式：执行删除" || log "模式：预演（加 --apply 才真删）"
log "每类保留最新 $KEEP 份"

# 每个脚本只留最新一个 .bak
for base in $(ls /usr/local/bin/*.sh.bak.* 2>/dev/null | sed 's/\.bak\.[0-9]*$//' | sort -u); do
  sweep "$(basename "$base") 的旧版" 1 "$base".bak.*
done
sec "1. opsget 安装脚本的旧版备份"

sweep "inventory 输出" "$KEEP" /root/inventory_*.txt
sweep "verify 输出"    "$KEEP" /root/verify_*.txt
sec "2. 摸底与比对的历史输出"

sweep "fwstate" "$KEEP" /root/fwstate_*
sec "3. 防火墙状态存档"

sweep "crontab 备份" $((KEEP + 1)) /root/crontab.bak.*
sec "4. crontab 备份"

# 快照体积大，但删错了就没有回头路 —— 只保留最新的，且明确提示
if [ -n "${SNAPSHOT_ROOT:-}" ]; then
  sweep "premigrate 快照" 1 "$SNAPSHOT_ROOT"/premigrate_*
  [ -n "$SECBUF" ] && emit "  [提醒] 快照是迁移期间唯一的完整回退点，确认新机稳定运行后再清"
fi
sec "5. 迁移快照"

for p in "${RESTORE_STAGE:-/root/restore_stage}" "${RESTORE_CMD_DIR:-/root/restore_cmds}" \
         "${IMAGE_EXPORT_DIR:-${SNAPSHOT_ROOT:-/nonexistent}/images}" /root/ops-backups; do
  [ -e "$p" ] || continue
  take "$p"
done
[ -n "$SECBUF" ] && emit "  [提醒] restore_cmds 里可能含带凭据的启动命令，清掉是好事"
sec "6. 恢复过程的中间产物"

# db/sqlite-dsn、rotate-db-pass 等在修改前会留 <文件>.bak.<时间戳>。
# 只列出、不删：它们在受保护的容器数据目录里，而且往往是数据库改动前的唯一副本，
# 同名模式也可能撞上应用自己的文件 —— 该不该删要人看过再定。
for d in $CONTAINER_DATA_DIRS; do
  [ -d "$d" ] || continue
  found=$(find "$d" -maxdepth 2 -name '*.bak.[0-9]*' 2>/dev/null | sort)
  [ -n "$found" ] || continue
  while IFS= read -r f; do
    emit "$(printf '    %-10s %s' "$(human "$f")" "$f")"
  done <<EOF
$found
EOF
done
[ -n "$SECBUF" ] && emit "  (只列出不删除：在受保护目录里，确认不再需要后手动 rm)"
sec "7. 容器数据目录里的旧副本（仅列出）"

# collect.sh 每跑一次就在每台机器新增一份 JSON 加一份 route.txt，
# 汇总目录还会按台累积 —— 不管的话几轮下来就是几百个文件
sweep "本机采集 JSON"  "$KEEP" /var/lib/vpsscore/*.json
sweep "本机回程路由"   "$KEEP" /var/lib/vpsscore/*.route.txt
# 汇总目录按 IP 分组各留 KEEP 份：直接按时间排会把某几台的历史全删光，
# 而横向对比恰恰需要每台都有数据
BASELINE="${VPSSCORE_BASELINE:-$HOME/vpsscore-baseline}"
if [ -d "$BASELINE" ] && command -v python3 >/dev/null 2>&1; then
  olds=$(python3 - "$BASELINE" "$KEEP" <<'PYEOF'
import json, os, sys, glob, collections
d, keep = sys.argv[1], int(sys.argv[2])
g = collections.defaultdict(list)
for f in glob.glob(os.path.join(d, "*.json")):
    if os.path.basename(f) == "latest.json":
        continue
    try:
        j = json.load(open(f, encoding="utf-8"))
    except Exception:
        print(f)          # 坏文件直接列为可清理
        continue
    g[j.get("ipv4") or j.get("host") or f].append((j.get("probed_at") or "", f))
for v in g.values():
    v.sort(reverse=True)
    for _, f in v[keep:]:
        print(f)
PYEOF
)
  if [ -n "$olds" ]; then
    emit "$(printf '  汇总目录旧采集（每台保留最新 %s 份，清理 %s）' \
            "$KEEP" "$(printf '%s\n' "$olds" | wc -l)")"
    while IFS= read -r f; do take "$f"; done <<EOF
$olds
EOF
  else
    KEPT="$KEPT    汇总目录采集：每台均在保留范围内\n"
  fi
fi
sec "8. vpsscore 采集产物"

section 汇总
[ -n "$KEPT" ] && { echo "  无需清理："; printf '%b' "$KEPT"; }

# 预演最该回答的问题是「能腾出多少」—— 原来这个数算了却从没打印
HUMAN_BYTES=$(awk -v b="$BYTES" 'BEGIN{
  split("B KB MB GB TB", u, " "); i=1
  while (b >= 1024 && i < 5) { b /= 1024; i++ }
  printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i] }')

if [ "$TOTAL" -eq 0 ]; then
  echo
  ok "没有可清理的项目 —— 各类份数都在保留范围内，不用跑 --apply"
elif [ "$APPLY" -eq 1 ]; then
  echo
  ok "已清理 $TOTAL 项，释放约 $HUMAN_BYTES；磁盘剩余：$(df -h / | tail -1 | awk '{print $4}')"
else
  echo
  echo "  可清理 $TOTAL 项，约 $HUMAN_BYTES"
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
