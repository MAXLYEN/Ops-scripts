#!/usr/bin/env bash
# ops/cleanup-purge.sh — 按安装台账移除 ops-scripts 及其产物
# VERSION: 1.0.5
# 1.0.5: 同一路径只列一次（ops-common.sh 原先会重复显示）。
# 默认预演，--apply 才执行移除并要求确认。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
LEDGER=/var/lib/ops-scripts/installed.list
TOTAL=0
# 开头就算好：/etc/ops-scripts/ref 会随下面的清理一起删掉，结尾的重装提示要用删之前的值
BASE=$(ops_base)

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

# 备份脚本也是经 opsget 装的、在台账里。删掉它们 cron 仍会照常调用，
# 找不到脚本就什么都不执行，连失败告警都发不出 —— 备份就此静默停摆。
# 默认保留 crontab 在用的与 BACKUP_SCRIPTS 列出的，PURGE_CRON_SCRIPTS=1 才删。
IN_USE=" $(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -oE '/usr/local/bin/[A-Za-z0-9._-]+' | sort -u | tr '\n' ' ')"
for s in ${BACKUP_SCRIPTS:-}; do IN_USE="$IN_USE/usr/local/bin/$s "; done
# 留下的脚本还要读 env.conf、加载 ops-common.sh：只留脚本不留它们，照样跑不起来
for s in $IN_USE; do
  [ -f "$s" ] || continue
  IN_USE="$IN_USE/etc/ops-scripts /usr/local/lib/ops-common.sh "
  break
done
is_in_use() {
  [ "${PURGE_CRON_SCRIPTS:-0}" = 1 ] && return 1
  case "$IN_USE" in *" $1 "*) return 0 ;; esac
  return 1
}

TARGETS=$(mktemp); trap 'rm -f "$TARGETS"' EXIT
SEEN=" "
add() {
  for p in "$@"; do
    [ -e "$p" ] || continue
    # 台账里的路径可能又被单独 add 一次（如 ops-common.sh），只处理第一次
    case "$SEEN" in *" $p "*) continue ;; esac
    SEEN="$SEEN$p "
    if is_protected "$p"; then echo "  [跳过·受保护] $p"; continue; fi
    if is_in_use "$p"; then echo "  [跳过·crontab/备份在用] $p"; continue; fi
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
        "$BASE/MANIFEST" 2>/dev/null)
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
# glob 没匹配时保持字面值，add() 的 [ -e ] 会跳过它
add /usr/local/bin/*.sh.bak.*

section "3. 运行产物"
add /root/inventory_*.txt /root/verify_*.txt /root/fwstate_* /root/crontab.bak.*
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
  crontab 正在调用的脚本与 BACKUP_SCRIPTS（上面标了「在用」的；PURGE_CRON_SCRIPTS=1 才删）
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
    curl -fsSL $BASE/bin/opsget \\
      -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget
    opsget -c   # 重新生成配置
EOF
finish
