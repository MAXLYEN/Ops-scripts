#!/usr/bin/env bash
# 09-restore-backup-stack.sh — 重建备份体系
# VERSION: 2.0.0
#
# 在迁入机运行。装依赖、归位配置与脚本、验证云端可达与密码可用。
# **不自动安装 cron** —— 等切换并观察正常后再用 ops/restore-cron 恢复。
#
# 用法: 09-restore-backup-stack.sh [暂存目录]
#       默认取 RESTORE_STAGE（07 解出来的那个）

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

STAGE=${1:-${RESTORE_STAGE:-/root/restore_stage}}
[ -d "$STAGE" ] || die "暂存目录不存在: $STAGE（先跑 07-restore-containers）"

section "1. 安装依赖"
DEPS="${BACKUP_DEPS:-rclone p7zip-full rsync msmtp msmtp-mta sqlite3}"
NEED=""
for p in $DEPS; do dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"; done
if [ -n "$NEED" ]; then
  log "待装:$NEED"
  log "（若含 msmtp-mta，它会自动替换掉系统自带的 MTA，这是预期行为）"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update -qq 2>/dev/null
  # shellcheck disable=SC2086
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq $NEED || die "安装失败"
else
  ok "依赖齐全"
fi
# 注意：探测版本别用 --version，有些命令（如 7z）不认这个参数会误判为未安装
for c in rclone rsync msmtp sqlite3 7z; do
  printf '  %-10s %s\n' "$c" "$(command -v "$c" >/dev/null 2>&1 && echo 已装 || echo 缺失)"
done
log "提示：包管理器的 rclone 版本可能远旧于原机。它是静态二进制，"
log "      直接从原机 scp 到 /usr/local/bin/rclone 可保持一致（PATH 里优先）"

section "2. 归位配置文件"
put() {  # put <暂存内路径> <目标> <权限>
  local src="$STAGE$1" dst=$2 mode=$3
  if [ ! -e "$src" ]; then warn "快照里没有 $1"; return; fi
  mkdir -p "$(dirname "$dst")"
  [ -e "$dst" ] && cp -a "$dst" "$dst.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$src" "$dst" && chmod "$mode" "$dst" && ok "$dst ($mode)" || warn "失败 $dst"
}
[ -e "$STAGE/etc/msmtprc" ] && put /etc/msmtprc /etc/msmtprc 600
for f in $BACKUP_PASS_FILES "$MYSQL_DEFAULTS_FILE"; do
  [ -n "$f" ] && put "$f" "$f" 600
done
if [ -d "$STAGE/root/.config/rclone" ]; then
  mkdir -p /root/.config
  [ -e /root/.config/rclone ] && mv /root/.config/rclone "/root/.config/rclone.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$STAGE/root/.config/rclone" /root/.config/rclone
  chmod 700 /root/.config/rclone; chmod 600 /root/.config/rclone/* 2>/dev/null
  ok "/root/.config/rclone"
else
  warn "快照里没有 rclone 配置"
fi

section "3. 归位备份脚本"
for s in $BACKUP_SCRIPTS; do
  src="$STAGE/usr/local/bin/$s"
  [ -f "$src" ] && put "/usr/local/bin/$s" "/usr/local/bin/$s" 755 || warn "快照里没有 $s"
done

section "4. 建目录"
for d in $BACKUP_DIRS; do mkdir -p "$d" && ok "$d"; done

section "5. 验证 rclone"
# 云盘的 OAuth token 换机后还能不能用，是整个备份体系里最不确定的一环
if command -v rclone >/dev/null 2>&1; then
  log "已配置远端: $(rclone listremotes 2>&1 | tr '\n' ' ')"
  for r in $RCLONE_REMOTES; do
    if rclone lsd "$r:" --max-depth 1 >/dev/null 2>&1; then
      ok "$r: 可访问"
      for p in $RCLONE_PATHS; do
        rclone lsd "$r:" 2>/dev/null | grep -q "$p" && printf '        %s\n' "$p"
      done
    else
      warn "$r: 无法访问（token 可能需要重新授权）"
    fi
  done
else
  warn "rclone 未安装"
fi

section "6. 邮件通道"
if [ -f /etc/msmtprc ]; then
  echo "  账号: $(grep -E '^account ' /etc/msmtprc | awk '{print $2}' | tr '\n' ' ')"
  echo "  发信: $(grep -E '^from ' /etc/msmtprc | awk '{print $2}' | head -1)"
  echo "  （实际发信测试建议等切换完成后再做，避免混淆判断）"
else
  warn "没有 /etc/msmtprc"
fi

section "7. 待恢复的 cron（本脚本不自动安装）"
SNAP=$(ls -dt "${SNAPSHOT_ROOT}"/premigrate_* 2>/dev/null | head -1)
if [ -n "$SNAP" ] && [ -f "$SNAP/crontab.txt" ]; then
  pat=$(echo "$BACKUP_SCRIPTS" | tr ' ' '|')
  grep -E "$pat" "$SNAP/crontab.txt" | sed 's/^/  /'
  echo
  echo "  用 ops/restore-cron 恢复，建议切换并观察正常后再执行"
else
  warn "找不到快照里的 crontab.txt"
fi

section 下一步
cat <<EOF
  1. 用 ops/preflight-backup 做备份脚本的前置检查
  2. 手动跑一次完整备份 —— DNS 还没切，现在失败不影响任何人
  3. 用 ops/verify-backup-pass 确认云端已有的包能用当前密码打开
EOF
finish
