#!/usr/bin/env bash
# ops/cleanup-purge.sh — 彻底移除 ops-scripts 及其全部产物
# VERSION: 1.0.0
#
# 用于：这台机器不再需要这套脚本（例如迁出机退役前、或换用别的方案）。
#
# 删除范围严格限定在 ops-scripts 自己装的和自己产生的东西。
# **业务数据一概不动** —— 备份产物、容器数据、数据库、面板、云端文件
# 都不在删除范围内，且有受保护路径的二次拦截。
#
#   cleanup-purge.sh              预演，列出会删什么
#   cleanup-purge.sh --apply      执行（需要输入 yes 二次确认）
#   KEEP_ENV=1 cleanup-purge.sh --apply   保留 /etc/ops-scripts/env.conf

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
LEDGER=/var/lib/ops-scripts/installed.list
TOTAL=0

PROTECTED="$BACKUP_DIRS $CONTAINER_DATA_DIRS $PANEL_ROOT $WWWROOT $PANEL_DB_BACKUP_DIR $MYSQL_DEFAULTS_FILE $BACKUP_PASS_FILES /root/.config/rclone /etc/msmtprc"
is_protected() {
  local p; p=$(readlink -f "$1" 2>/dev/null || echo "$1")
  for g in $PROTECTED; do
    [ -n "$g" ] || continue
    local gg; gg=$(readlink -f "$g" 2>/dev/null || echo "$g")
    case "$p" in "$gg"|"$gg"/*) return 0 ;; esac
  done
  return 1
}

TARGETS=$(mktemp); trap 'rm -f "$TARGETS"' EXIT
add() {
  for p in "$@"; do
    [ -e "$p" ] || continue
    if is_protected "$p"; then echo "  [跳过·受保护] $p"; continue; fi
    printf '%s\n' "$p" >> "$TARGETS"
  done
}

section "1. 已安装的脚本（按台账）"
if [ -f "$LEDGER" ]; then
  while IFS= read -r f; do add "$f"; done < "$LEDGER"
  echo "  台账 $LEDGER 记录 $(wc -l < "$LEDGER") 条"
else
  echo "  没有台账（opsget 1.1.0 之前安装的），回落到按 MANIFEST 推断文件名"
  # 只删名字能对上 MANIFEST 的，避免误伤同目录下你自己的脚本
  MAN=$(curl -fsSL --max-time 30 \
        "${OPS_REPO:-https://raw.githubusercontent.com/MAXLYEN/ops-scripts}/${OPS_REF:-main}/MANIFEST" 2>/dev/null)
  if [ -n "$MAN" ]; then
    echo "$MAN" | grep -oE '^[a-z]+/[a-z0-9-]+' | while read -r p; do
      add "/usr/local/bin/$(basename "$p").sh"
    done
  else
    warn "拉不到 MANIFEST，只能删 opsget 与 common.sh，其余请手工确认"
  fi
fi
add /usr/local/bin/opsget /usr/local/lib/ops-common.sh
add /var/lib/ops-scripts

section "2. 脚本的旧版备份"
add $(ls /usr/local/bin/*.sh.bak.* 2>/dev/null)

section "3. 运行产物"
add $(ls -d /root/inventory_*.txt /root/verify_*.txt /root/fwstate_* /root/crontab.bak.* 2>/dev/null)
add "${RESTORE_STAGE:-/root/restore_stage}" "${RESTORE_CMD_DIR:-/root/restore_cmds}" /root/ops-backups
[ -n "${IMAGE_EXPORT_DIR:-}" ] && add "$IMAGE_EXPORT_DIR"
[ -n "${SNAPSHOT_ROOT:-}" ] && add "$SNAPSHOT_ROOT/images"

section "4. 迁移快照"
if [ -n "${SNAPSHOT_ROOT:-}" ]; then
  SNAPS=$(ls -d "$SNAPSHOT_ROOT"/premigrate_* 2>/dev/null)
  if [ -n "$SNAPS" ]; then
    echo "$SNAPS" | while IFS= read -r s; do printf '  %-10s %s\n' "$(human "$s")" "$s"; done
    warn "快照是迁移期间唯一的完整回退点 —— 确认新机已稳定运行足够久再删"
    add $SNAPS
  else
    echo "  (无)"
  fi
fi

section "5. 配置"
if [ "${KEEP_ENV:-0}" = 1 ]; then
  echo "  保留 /etc/ops-scripts/env.conf（KEEP_ENV=1）"
else
  echo "  /etc/ops-scripts/（含 env.conf，里面是你的拓扑配置）"
  add /etc/ops-scripts
fi

section "待删清单"
if [ ! -s "$TARGETS" ]; then
  ok "没有可删的东西，这台机器上没有 ops-scripts 的痕迹"
  exit 0
fi
sort -u "$TARGETS" -o "$TARGETS"
while IFS= read -r p; do printf '  %-10s %s\n' "$(human "$p")" "$p"; done < "$TARGETS"
TOTAL=$(wc -l < "$TARGETS")
echo
echo "  共 $TOTAL 项"

section "不在删除范围内（确认一下）"
cat <<EOF
  备份产物    ${BACKUP_DIRS:-未配置}
  容器数据    ${CONTAINER_DATA_DIRS:-未配置}
  凭据文件    ${BACKUP_PASS_FILES:-未配置} ${MYSQL_DEFAULTS_FILE:-}
  面板目录    ${PANEL_ROOT:-未配置}
  你自己的备份脚本  ${BACKUP_SCRIPTS:-未配置}
  云端的任何文件
EOF

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "  以上为预演。确认后执行:  $(basename "$0") --apply"
  exit 0
fi

section 执行
confirm "将永久删除上述 $TOTAL 项，不可恢复。确认？"
while IFS= read -r p; do
  rm -rf "$p" && printf '  [删] %s\n' "$p" || warn "删除失败 $p"
done < "$TARGETS"

section 完成
ok "已移除，磁盘剩余：$(df -h / | tail -1 | awk '{print $4}')"
cat <<EOF

  想重新装回来：
    curl -fsSL ${OPS_REPO:-https://raw.githubusercontent.com/MAXLYEN/ops-scripts}/${OPS_REF:-main}/bin/opsget \\
      -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget
    opsget -c   # 重新生成配置
EOF
finish
