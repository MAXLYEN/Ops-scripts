#!/usr/bin/env bash
# ops/restore-cron.sh — 从快照恢复自有 cron
# VERSION: 2.0.0
#
# 面板的计划任务会跟着迁移走，但**直接写在 root crontab 里的原始条目不会**。
# 这个脚本把它们从快照的 crontab.txt 抄回来，并补上迁移后常缺的 PATH。
#
# 建议在切换完成、服务观察正常之后再跑 —— 观察期里备份一个还没验完的状态没意义。
#
# 用法: restore-cron.sh [快照目录]

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env SNAPSHOT_ROOT BACKUP_SCRIPTS

SNAP=${1:-$(ls -dt "$SNAPSHOT_ROOT"/premigrate_* 2>/dev/null | head -1)}
[ -n "$SNAP" ] && [ -f "$SNAP/crontab.txt" ] || die "找不到快照里的 crontab.txt（传参或检查 SNAPSHOT_ROOT）"
SRC="$SNAP/crontab.txt"
TS=$(date -u +%Y%m%d%H%M%S)
CUR=$(mktemp); NEW=$(mktemp)
trap 'rm -f "$CUR" "$NEW"' EXIT

crontab -l > "$CUR" 2>/dev/null || : > "$CUR"
cp "$CUR" "/root/crontab.bak.$TS"
ok "当前 crontab 已备份到 /root/crontab.bak.$TS"

section "改前"
sed 's/^/  /' "$CUR"
cp "$CUR" "$NEW"

section "补 PATH"
# cron 环境极简。若系统装了把无重定向输出当邮件发的 MTA，缺 PATH 会让
# 脚本失败并把错误发给收不到的 root@主机名 —— 静默失效的经典形态。
if grep -qE '^\s*PATH=' "$NEW"; then
  log "PATH 已存在，跳过"
else
  P=$(grep -E '^\s*PATH=' "$SRC" | head -1)
  P="${P:-PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
  printf '%s\n%s\n' "$P" "$(cat "$NEW")" > "$NEW.t" && mv "$NEW.t" "$NEW"
  ok "已补 $P"
fi

section "恢复备份任务"
pat=$(echo "$BACKUP_SCRIPTS" | tr ' ' '|')
grep -E "$pat" "$SRC" | sed 's/^#MIGRATE-PAUSED //' | while IFS= read -r line; do
  [ -z "$line" ] && continue
  s=$(echo "$line" | grep -oE '/[^ ]+\.(sh|py)')
  if grep -qF "$s" "$NEW"; then
    log "[=] 已存在，跳过 $s"
  else
    printf '%s\n' "$line" >> "$NEW"
    ok "已添加 $s"
  fi
done

section "安装前检查脚本是否就位"
MISS=0
for s in $(grep -oE '/usr/local/bin/[a-zA-Z0-9._-]+\.(sh|py)' "$NEW" | sort -u); do
  [ -x "$s" ] || { warn "$s 不存在或不可执行"; MISS=1; }
done
[ $MISS -eq 0 ] || die "有脚本缺失，未写入 crontab"

crontab "$NEW" || die "写入失败，还原: crontab /root/crontab.bak.$TS"

section "改后"
crontab -l | sed 's/^/  /'

section 提醒
cat <<EOF
  · 迁出机上的同名任务要保持暂停（#MIGRATE-PAUSED 前缀），
    否则两台机器会抢同一个云端目录，保留策略互相误删
  · 面板 UI 里改任何计划任务都会重写整个 crontab，
    可能抹掉 flock 包装和 PATH —— 改完立刻 crontab -l 复查
  · 当前时区: $(timedatectl show -p Timezone --value 2>/dev/null)，
    cron 表达式按这个时区解释
EOF
finish
