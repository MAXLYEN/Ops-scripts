#!/usr/bin/env bash
# ops/install-backup-cron.sh — 按统一时间表安装备份定时任务（幂等，可反复运行）
# VERSION: 1.0.0
# 1.0.0: 首版。vw / xboard 每 6 小时（:00 / :20），newapi 每小时（:05）；外层 flock 锁用 /var/lock/<名>-cron.lock（不与脚本自己的 /run/lock/<名>.lock 同一把），输出进各自的 -cron.log，补 PATH。
# 用法：install-backup-cron.sh [--apply]    不带参数只预演：显示改后的 crontab 与差异，不写入
# 只给本机已装在 /usr/local/bin 的备份脚本排任务；cron 永远调用本地脚本，不调用 opsget。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
require_cmd crontab flock

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
BIN=${OPS_BIN_DIR:-/usr/local/bin}
DEFAULT_PATH='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# 名称|分 时 日 月 周。分钟错开，两个 6 小时任务不会同时上云
SCHEDULE="vw-fullbackup|0 */6 * * *
xboard-fullbackup|20 */6 * * *
newapi-fullbackup|5 * * * *"

CUR=$(mktemp); NEW=$(mktemp); trap 'rm -f "$CUR" "$NEW"' EXIT
crontab -l > "$CUR" 2>/dev/null || : > "$CUR"

# 这一行是不是在调用这个备份脚本（本地路径、裸名，或不该出现的 opsget backup/<名>）。
# 名字后面只能跟 .sh / 空白 / 行尾 / 重定向，vw-fullbackup-cron.log 这类日志路径不算
calls_script() {  # calls_script <名称> <行>
  grep -qE "(^|[[:space:]/])$1(\.sh)?([[:space:];|&>]|$)" <<<"$2"
}

# 沿用现有行的锁文件：换时间表的那一刻若有备份正在跑，新旧行仍互斥（opsbox 的「立即备份」也读这把锁）
lock_of() {  # lock_of <行>
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /(^|\/)flock$/) {
           for (j = i + 1; j <= NF; j++) {
             if ($j ~ /^-/) { if ($j ~ /^(-w|-E|--wait|--timeout|--conflict-exit-code)$/) j++; continue }
             print $j; exit } } }' <<<"$1"
}

cp "$CUR" "$NEW"
ADDED=""
while IFS='|' read -r name when; do
  if [ ! -x "$BIN/$name.sh" ]; then
    log "$name：本机没装（$BIN/$name.sh），跳过"
    continue
  fi
  lock=""
  : > "$NEW.t"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [[:space:]]*'#'*|'#'*) printf '%s\n' "$line" >> "$NEW.t"; continue ;;
    esac
    if calls_script "$name" "$line"; then
      [ -n "$lock" ] || lock=$(lock_of "$line")
      continue                                   # 旧行一律拿掉，下面按时间表写一行新的
    fi
    printf '%s\n' "$line" >> "$NEW.t"
  done < "$NEW"
  mv "$NEW.t" "$NEW"
  # 备份脚本自己会锁 /run/lock/<名>.lock（/var/lock 就是 /run/lock）。cron 外层要是也拿这把，
  # 脚本一启动就撞上自己的父进程，直接退出 —— 备份永远不跑。外层一律用另一把
  case "$lock" in "/run/lock/$name.lock"|"/var/lock/$name.lock"|"/run/$name.lock") lock="" ;; esac
  lock=${lock:-/var/lock/$name-cron.lock}
  printf '%s /usr/bin/flock -n %s %s/%s.sh >> /var/log/%s-cron.log 2>&1\n' \
    "$when" "$lock" "$BIN" "$name" "$name" >> "$NEW"
  ADDED="$ADDED $name"
done <<<"$SCHEDULE"

[ -n "$ADDED" ] || { warn "本机一个备份脚本都没装（opsget -i backup/<名字>），没有可排的任务"; finish; exit $?; }

# cron 环境几乎没有 PATH：脚本里的 7z、rclone、mysqldump 找不到时，手动跑正常、定时跑失败
if ! grep -qE '^[[:space:]]*PATH=' "$NEW"; then
  { printf '%s\n' "$DEFAULT_PATH"; cat "$NEW"; } > "$NEW.t" && mv "$NEW.t" "$NEW"
fi

section "改后的 crontab"
sed 's/^/  /' "$NEW"
section "差异"
if cmp -s "$CUR" "$NEW"; then
  ok "与当前 crontab 相同，无需改动"
  finish; exit $?
fi
diff -u --label 当前 --label 改后 "$CUR" "$NEW" | sed 's/^/  /'

if [ "$APPLY" -ne 1 ]; then
  echo
  log "预演结束，未写入。确认后加 --apply 执行"
  finish; exit $?
fi

mkdir -p /root/ops-backups
BAK="/root/ops-backups/crontab.$(date -u +%Y%m%d%H%M%S)"
cp "$CUR" "$BAK" && chmod 600 "$BAK"
crontab "$NEW" || die "写入 crontab 失败（原内容在 $BAK）"
ok "已写入。原 crontab 备份在 $BAK"
log "已排任务:$ADDED"
log "外部心跳监控的周期要跟着改：vw / xboard 6 小时，newapi 1 小时（各加宽限）。上一次还没跑完时本次直接跳过、不报心跳"
finish
