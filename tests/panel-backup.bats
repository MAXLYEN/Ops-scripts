#!/usr/bin/env bats
# tests/panel-backup.bats — 真跑 ops/panel-backup-create 与它调用的 ops/panel-backup-upload（不是桩）。
# 面板自带的 Python（backup_manager.py backup_data）、rclone、curl、sleep 换成假实现：假面板照 backup_task.json 里
# 对应时间戳的任务出一个 tar.gz 与工作目录并回写结果；rclone 把远端映射到本地目录。7z、gzip、flock 与公共库都是真的。
# 能证明：照最近一次任务复制配置、新时间戳不重、前台调用、结果判定、本机与云端各留几份、加密上传、失败告警与心跳。
# 证明不了：真实宝塔面板的备份程序（字段含义、耗时、失败方式）与网盘的行为。

load helpers

none() {  # none <正则> <文本>：文本里不能有匹配的行
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2
  return 1
}

L=/tmp/pb             # 假实现的状态与日志
FB=/tmp/pbbin         # 假命令
BR=$L/br              # 面板备份目录（PANEL_BACKUP_DIR）
P=$L/panel            # 面板根目录（PANEL_ROOT）
PASSF=/root/pb-bp

setup() {
  rm -rf "$L" "$FB" /etc/ops-scripts /usr/local/lib/ops-common.sh /run/lock/panel-backup-create.lock \
         /var/lib/ops-scripts/panel-backup-uploaded.list
  mkdir -p "$BR" "$FB" "$P/mod/project/backup_restore" "$P/pyenv/bin" "$L/cloud"
  : > "$P/mod/project/backup_restore/backup_manager.py"
  printf 'correct-horse-battery-staple-03\n' > "$PASSF"; chmod 600 "$PASSF"
  mkdir -p /etc/ops-scripts
  printf '%s\n' 'RCLONE_REMOTES="onedrive gdrive"' "BACKUP_PASS_FILES=\"$PASSF\"" "PANEL_BACKUP_DIR=\"$BR\"" \
    "PANEL_ROOT=\"$P\"" 'PANEL_BACKUP_KEEP="3"' 'PANEL_BACKUP_HEARTBEAT_URL="https://hc.example/ping/pb"' \
    "ALERT_FALLBACK_FILE=\"$L/alerts.log\"" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
  fakes
  echo '[]' > "$BR/backup_task.json"
  task 1790642642 '备份-2026-09-28-1743'          # 面板里手动建过的那一次
  export PATH="$FB:$PATH" PB_BASE="$BR"
}

teardown() { rm -rf "$L" "$FB"; }

# task <时间戳> [名字]：像面板那样记一条已完成的任务，并放上它的包与工作目录
task() {
  python3 - "$BR/backup_task.json" "$1" "${2:-备份-$1}" <<'PY'
import json, sys
path, ts, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
t = json.load(open(path))
t.append({'backup_name': name, 'timestamp': ts, 'create_time': 'x', 'backup_time': 'x', 'storage_type': 'local',
          'auto_exit': 0, 'backup_status': 2, 'restore_status': 0, 'backup_path': '/x/%d_backup' % ts,
          'backup_file': '/x/%d.tar.gz' % ts, 'backup_file_sha256': '', 'backup_file_size': '',
          'backup_count': {'success': 13, 'failed': 0}, 'total_time': 1, 'done_time': 'x',
          'database_id': '["ALL"]', 'site_id': [], 'backup_data': ['site', 'database', 'ssh']})
json.dump(t, open(path, 'w'))
PY
  mkdir -p "$BR/${1}_backup"; echo old > "$BR/${1}_backup/backup.json"
  echo old | gzip > "$BR/20260101-0000_${1}_backup.tar.gz"
}

fakes() {
  # 面板的 Python：只认 backup_manager.py backup_data <时间戳>；$L/bt-fail 时不出包，$L/bt-partial 时报 1 项失败
  cat > "$P/pyenv/bin/python3" <<'PY'
#!/usr/bin/env python3
import datetime, json, os, sys, tarfile
L, base = '/tmp/pb', os.environ['PB_BASE']
mgr, method, ts = sys.argv[1:4]
open(L + '/bt.calls', 'a').write('%s %s\n' % (method, ts))
path = base + '/backup_task.json'
tasks = json.load(open(path))
t = [x for x in tasks if str(x['timestamp']) == ts]
if not t:
    print('备份配置文件不存在'); sys.exit(0)
if os.path.exists(L + '/bt-fail'):
    open(base + '/backup.log', 'a').write('模拟：打包失败\n'); sys.exit(0)
d = '%s/%s_backup' % (base, ts)
os.makedirs(d + '/site', exist_ok=True)
open(d + '/backup.json', 'w').write('{}')
name = '%s/%s_%s_backup.tar.gz' % (base, datetime.datetime.fromtimestamp(int(ts)).strftime('%Y%m%d-%H%M'), ts)
with tarfile.open(name, 'w:gz') as tf:
    tf.add(d, arcname=ts + '_backup')
failed = 1 if os.path.exists(L + '/bt-partial') else 0
t[0].update(backup_status=2, backup_file=name, backup_count={'success': 13 - failed, 'failed': failed})
json.dump(tasks, open(path, 'w'))
open(base + '/backup.log', 'a').write('备份完成\n')
PY
  chmod 755 "$P/pyenv/bin/python3"
  # rclone：<远端>:<目录> 映射到 $L/cloud/<远端>/<目录>
  cat > "$FB/rclone" <<'EOF'
#!/bin/bash
C=/tmp/pb/cloud
loc() { local r=${1%%:*} p=${1#*:}; p=${p#/}; printf '%s/%s/%s' "$C" "$r" "${p%/}"; }
cmd=$1; shift
case "$cmd" in
  copy) d=$(loc "$2"); mkdir -p "$d"; cp "$1" "$d/" ;;
  check) cmp -s "$1/$4" "$(loc "$2")/$4" ;;
  deletefile) rm -f "$(loc "$1")" ;;
esac
exit 0
EOF
  printf '#!/bin/sh\necho "curl $*" >> /tmp/pb/curl.log\nexit 0\n' > "$FB/curl"
  printf '#!/bin/sh\nexit 0\n' > "$FB/sleep"
  chmod 755 "$FB"/*
}

create() { run bash "$SRC/ops/panel-backup-create.sh" "$@"; }
cloud() { ls "$L/cloud/$1/BTBackup-AllServer" 2>/dev/null; }
newest() { python3 -c "import json;t=json.load(open('$BR/backup_task.json'));print(max(int(x['timestamp']) for x in t))"; }

@test "照面板最近一次的设置建新任务、前台跑面板的备份程序，出包后加密传到两个网盘，心跳 /start 与成功" {
  create
  [ "$status" -eq 0 ]
  ts=$(newest)
  [ "$ts" -gt 1790642642 ]
  grep -qx "backup_data $ts" "$L/bt.calls"
  python3 - "$BR/backup_task.json" "$ts" <<'PY'
import json, sys
t = {str(x['timestamp']): x for x in json.load(open(sys.argv[1]))}[sys.argv[2]]
assert t['backup_name'].startswith('自动备份-'), t['backup_name']
assert t['backup_data'] == ['site', 'database', 'ssh'] and t['database_id'] == '["ALL"]' and t['storage_type'] == 'local'
assert t['backup_path'].endswith('/%s_backup' % sys.argv[2])
PY
  has "照「备份-2026-09-28-1743」的设置"
  has "成功/失败项：13/0"
  for r in onedrive gdrive; do
    f=$(cloud "$r"); [[ $f == *_"$ts"_backup.7z ]]
    7z t -p"$(head -1 "$PASSF")" "$L/cloud/$r/BTBackup-AllServer/$f" </dev/null >/dev/null
  done
  grep -qx 'curl -fsS -m 10 --retry 2 https://hc.example/ping/pb/start' "$L/curl.log"
  grep -qx 'curl -fsS -m 10 --retry 2 https://hc.example/ping/pb' "$L/curl.log"
  none '/fail' "$(cat "$L/curl.log")"
}

@test "本机自动备份只留最近 3 份（包、工作目录、任务记录一起删）；面板手动建的不动；云端每个网盘也只留 3 份" {
  task 1790000000 '备份-2026-09-01-0900'          # 另一条手动建的，比自动备份都旧
  task 1790000001 '自动备份-2026-09-02-0000'; task 1790000002 '自动备份-2026-09-03-0000'; task 1790000003 '自动备份-2026-09-04-0000'
  create
  [ "$status" -eq 0 ]
  [ ! -e "$BR/20260101-0000_1790000001_backup.tar.gz" ] && [ ! -e "$BR/1790000001_backup" ]
  for t in 1790000002 1790000003 1790000000 1790642642; do
    [ -e "$BR/20260101-0000_${t}_backup.tar.gz" ] && [ -d "$BR/${t}_backup" ]
  done
  python3 - "$BR/backup_task.json" <<'PY'
import json, sys
names = [t['backup_name'] for t in json.load(open(sys.argv[1]))]
assert '备份-2026-09-01-0900' in names and '备份-2026-09-28-1743' in names, names
assert '自动备份-2026-09-02-0000' not in names, names
assert sum(n.startswith('自动备份-') for n in names) == 3 and len(names) == 5, names
PY
  has "删掉 1790000001 的包与工作目录"
  none "1790000000" "$(grep '删掉' <<<"$output")"
  create; create; create
  [ "$status" -eq 0 ]
  [ "$(ls "$BR"/*_backup.tar.gz | wc -l)" = 5 ]                       # 2 份手动 + 3 份自动
  [ -e "$BR/20260101-0000_1790000000_backup.tar.gz" ] && [ -e "$BR/20260101-0000_1790642642_backup.tar.gz" ]
  [ "$(cloud onedrive | wc -l)" = 3 ] && [ "$(cloud gdrive | wc -l)" = 3 ]
  [ "$(grep -c . "$L/bt.calls")" = 4 ] && [ "$(sort -u "$L/bt.calls" | wc -l)" = 4 ]   # 每次时间戳都不同
}

@test "只有手动建的备份时一份都不删" {
  task 1790000001; task 1790000002; task 1790000003
  create
  [ "$status" -eq 0 ]
  for t in 1790000001 1790000002 1790000003 1790642642; do [ -e "$BR/20260101-0000_${t}_backup.tar.gz" ]; done
  has "自动备份不超过 3 份，不用清理"
}

@test "面板的备份程序没出包：不上传、不清理旧包，告警落盘、心跳 /fail" {
  task 1790000001; task 1790000002; task 1790000003
  touch "$L/bt-fail"
  create
  [ "$status" -ne 0 ]
  has "没有生成"
  [ -z "$(cloud onedrive)" ] && [ -z "$(cloud gdrive)" ]
  [ -e "$BR/20260101-0000_1790000001_backup.tar.gz" ]
  grep -q '面板整机备份失败' "$L/alerts.log"
  grep -q '模拟：打包失败' "$L/alerts.log"
  grep -qx 'curl -fsS -m 10 --retry 2 https://hc.example/ping/pb/fail' "$L/curl.log"
}

@test "面板报告有失败项：包照样上传，另外告警" {
  touch "$L/bt-partial"
  create
  has "成功/失败项：12/1"
  [ -n "$(cloud onedrive)" ] && [ -n "$(cloud gdrive)" ]
  grep -q '面板整机备份部分失败' "$L/alerts.log"
}

@test "面板里从没建过备份、或已有备份在进行：说明原因退出，不调用面板的备份程序" {
  rm -f "$BR/backup_task.json"
  create
  [ "$status" -ne 0 ]
  has "先在面板「设置 → 备份还原」手动创建一次备份"
  echo '[]' > "$BR/backup_task.json"; task 1790642642
  touch "$BR/backup.pl"
  create
  [ "$status" -ne 0 ]
  has "面板里已有备份在进行"
  [ ! -e "$L/bt.calls" ]
}
