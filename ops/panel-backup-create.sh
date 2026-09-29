#!/usr/bin/env bash
# ops/panel-backup-create.sh — 照面板上次的设置生成整机备份，加密上传，本机与云端各留最近几份
# VERSION: 1.0.0
# 1.0.0: 首版。复制面板「设置 → 备份还原」里最近一次备份的任务配置（备份内容一致），换新时间戳写回 backup_task.json，前台运行面板自带的 backup_manager.py backup_data 并等它结束；出了包再调用 panel-backup-upload 加密上传、清理云端，本机只留最近 PANEL_BACKUP_KEEP 份（包、工作目录、任务记录一起删）；失败时告警（邮件 → webhook → 落盘）、心跳 /fail，本机旧包不动。
# ENV-REQUIRED: RCLONE_REMOTES BACKUP_PASS_FILES
# 用法：panel-backup-create.sh [--no-upload]
# 面板里至少手动建过一次备份，脚本照那次勾选的内容备份。定时任务由 ops/install-backup-cron 安装（每周日 UTC 19:30）。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env RCLONE_REMOTES BACKUP_PASS_FILES
require_cmd python3 flock gzip

UPLOAD=1
case "${1:-}" in
  --no-upload) UPLOAD=0 ;;
  '') ;;
  *) die "未知参数: $1" ;;
esac

DIR="${PANEL_BACKUP_DIR:-/www/backup/backup_restore}"
TASKS="$DIR/backup_task.json"
KEEP="${PANEL_BACKUP_KEEP:-3}"
PANEL="${PANEL_ROOT:-/www/server/panel}"
MGR="$PANEL/mod/project/backup_restore/backup_manager.py"
BTPY=/usr/bin/btpython; [ -x "$BTPY" ] || BTPY="$PANEL/pyenv/bin/python3"
ALERT_FALLBACK_FILE="${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
LOCK=/run/lock/panel-backup-create.lock
case "$KEEP" in ''|*[!0-9]*|0) die "PANEL_BACKUP_KEEP 要是正整数: $KEEP" ;; esac

hb() {  # 心跳：开始 /start，成功根路径，失败 /fail
  [ -n "${PANEL_BACKUP_HEARTBEAT_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 2 "${PANEL_BACKUP_HEARTBEAT_URL}$1" >/dev/null 2>&1 || true
}

# 与备份脚本同一套：邮件重试三次 → webhook → 落盘，能通一条就算送达
alert() {  # alert <主题> <正文>
  local i
  if [ -n "${MAIL_TO:-}" ] && command -v msmtp >/dev/null 2>&1; then
    for i in 1 2 3; do
      printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$MAIL_TO" "$1" "$2" | msmtp -t && return 0
      [ "$i" -lt 3 ] && sleep 20
    done
  fi
  if [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -fsS -m 10 -X POST --data-urlencode "text=[$(hostname)] $1" "$ALERT_WEBHOOK" >/dev/null 2>&1 && return 0
  fi
  printf '[%s] [未送达] %s\n%s\n' "$(date -u '+%F %T')" "$1" "$2" >> "$ALERT_FALLBACK_FILE"
}

fail_out() {  # fail_out <原因>：告警、心跳 /fail，然后退出
  alert "[面板整机备份失败] $(hostname)" "$1"$'\n\n'"$(tail -n 30 "$DIR/backup.log" 2>/dev/null)"
  hb /fail
  die "$1"
}

exec 9>"$LOCK"
flock -n 9 || die "上一次还没跑完（$LOCK），本次跳过"
hb /start

[ -f "$MGR" ] || fail_out "找不到面板的备份程序 $MGR（面板改版了？）"
[ -x "$BTPY" ] || fail_out "找不到面板自带的 Python（/usr/bin/btpython 或 $PANEL/pyenv/bin/python3）"
[ -s "$TASKS" ] || fail_out "没有 $TASKS：先在面板「设置 → 备份还原」手动创建一次备份，之后照那次勾选的内容自动备份"
# 面板的备份程序正在跑时会留这个标记；它自己也会拒绝重入，这里提前说清楚
[ -e "$DIR/backup.pl" ] && fail_out "面板里已有备份在进行（$DIR/backup.pl）。确认没在跑的话删掉它再试"

# 上一份包加工作目录约是包的 3 倍，按这个留足空间；没有旧包时至少留 1GB
last=$(ls -t "$DIR"/*_backup.tar.gz 2>/dev/null | head -1)
need=$(( ${last:+$(stat -c %s "$last")} + 0 )); need=$(( need * 3 / 1024 )); [ "$need" -ge 1048576 ] || need=1048576
avail=$(df -Pk "$DIR" | awk 'NR == 2 { print $4 }')
[ "${avail:-0}" -ge "$need" ] || fail_out "$DIR 所在分区只剩 $((avail / 1024))MB，这次备份约需 $((need / 1024))MB"

section "新建备份任务（照面板最近一次的设置）"
# 复制最近一次任务的备份内容（backup_data / database_id / site_id / storage_type），字段照面板 comMod.py 新建任务时写的
out=$(python3 - "$TASKS" "$DIR" <<'PY'
import json, os, sys, time, datetime
path, base = sys.argv[1], sys.argv[2]
tasks = json.load(open(path, encoding='utf-8'))
if not isinstance(tasks, list) or not tasks:
    sys.exit('backup_task.json 里没有任务：先在面板里手动创建一次备份')
stamps = [int(t['timestamp']) for t in tasks if str(t.get('timestamp', '')).isdigit()]
if not stamps:
    sys.exit('backup_task.json 里的任务都没有时间戳，认不出格式')
tpl = max((t for t in tasks if str(t.get('timestamp', '')).isdigit()), key=lambda t: int(t['timestamp']))
ts = max(int(time.time()), max(stamps) + 1)          # 时间戳是任务的主键，不能和已有的重
now = datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')
new = dict(tpl)
new.update(backup_name='自动备份-' + datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d-%H%M'),
           timestamp=ts, create_time=now, backup_time=now, backup_status=0, restore_status=0,
           backup_path='%s/%d_backup' % (base, ts), backup_file='', backup_file_sha256='',
           backup_file_size='', backup_count={'success': None, 'failed': None},
           total_time=None, done_time=None)
tasks.append(new)
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(tasks, f, ensure_ascii=False)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print('%d\t%s\t%s' % (ts, tpl.get('backup_name', ''), ','.join(tpl.get('backup_data') or [])))
PY
) || fail_out "写不了备份任务（$TASKS）"
IFS=$'\t' read -r TS TPL ITEMS <<<"$out"
log "照「$TPL」的设置：${ITEMS:-面板默认的全部内容}"
log "新任务时间戳 $TS"

section "生成备份（面板自带的备份程序，前台运行）"
t0=$(date +%s)
timeout 4h "$BTPY" "$MGR" backup_data "$TS" >/dev/null 2>&1
rc=$?
PKG=$(ls "$DIR"/*_"$TS"_backup.tar.gz 2>/dev/null | head -1)
[ "$rc" -eq 0 ] || fail_out "面板的备份程序退出码 $rc（124 是超过 4 小时被中止）"
[ -n "$PKG" ] && [ -s "$PKG" ] || fail_out "面板的备份程序跑完了，但没有生成 *_${TS}_backup.tar.gz"
gzip -t "$PKG" 2>/dev/null || fail_out "生成的包不完整：$PKG"
cnt=$(python3 - "$TASKS" "$TS" <<'PY'
import json, sys
t = [x for x in json.load(open(sys.argv[1], encoding='utf-8')) if str(x.get('timestamp')) == sys.argv[2]]
c = (t[0].get('backup_count') or {}) if t else {}
print('%s %s' % (c.get('success'), c.get('failed')))
PY
)
ok "$(basename "$PKG")  $(human "$PKG")  用时 $(( ($(date +%s) - t0) / 60 )) 分钟  成功/失败项：${cnt/ //}"
case "${cnt#* }" in
  0|None|'') ;;
  *) warn "面板报告有 ${cnt#* } 项没备份成功，到面板「备份还原 → 日志」里看是哪几项；包照样上传"
     alert "[面板整机备份部分失败] $(hostname)" "有 ${cnt#* } 项没备份成功，包照样上传：$PKG"$'\n\n'"$(tail -n 30 "$DIR/backup.log" 2>/dev/null)" ;;
esac

section "本机只留最近 $KEEP 份"
# 按时间戳排，旧的连同工作目录、任务记录一起删（面板手动建的也算在内）
old=$(python3 - "$TASKS" "$KEEP" <<'PY'
import json, os, sys
path, keep = sys.argv[1], int(sys.argv[2])
tasks = json.load(open(path, encoding='utf-8'))
ok = sorted((t for t in tasks if str(t.get('timestamp', '')).isdigit()), key=lambda t: int(t['timestamp']))
drop = {str(t['timestamp']) for t in ok[:-keep]}
if drop:
    rest = [t for t in tasks if str(t.get('timestamp')) not in drop]
    with open(path + '.tmp', 'w', encoding='utf-8') as f:
        json.dump(rest, f, ensure_ascii=False)
    os.chmod(path + '.tmp', 0o600)
    os.replace(path + '.tmp', path)
print(' '.join(sorted(drop)))
PY
) || { warn "清理本机旧包时读不了 $TASKS，这次不清理"; old=""; }
if [ -z "$old" ]; then
  log "不超过 $KEEP 份，不用清理"
else
  for t in $old; do
    [[ $t =~ ^[0-9]+$ ]] || continue
    rm -f -- "$DIR"/*_"$t"_backup.tar.gz && rm -rf -- "${DIR:?}/${t}_backup" && ok "删掉 $t 的包与工作目录"
  done
fi

if [ "$UPLOAD" = 1 ]; then
  section "加密上传（ops/panel-backup-upload）"
  UP="$(dirname "$(readlink -f "$0")")/panel-backup-upload.sh"
  [ -f "$UP" ] || UP=/usr/local/bin/panel-backup-upload.sh
  [ -f "$UP" ] || fail_out "本机没装 panel-backup-upload（opsget -i ops/panel-backup-upload）"
  bash "$UP" --file "$PKG" --prune "$KEEP" || fail_out "加密上传或云端校验没通过（见上）；包留在本机：$PKG"
else
  log "--no-upload：只在本机生成，不上传"
fi

hb ""
finish
