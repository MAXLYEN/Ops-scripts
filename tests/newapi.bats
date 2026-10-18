#!/usr/bin/env bats
# tests/newapi.bats — 真跑 backup/newapi-fullbackup（不是桩）。
# ssh / docker / rclone / curl / sleep 换成假实现：ssh 在本机直接执行远端命令（落地机的数据目录在 $L/node），
# rclone 把远端映射到本地目录。sqlite3、python3、7z、tar 与公共库都是真的。
# 能证明：在线快照拉回、包的内容、加密、上传与校验、线路抖动时的重试与放弃、心跳与告警。
# 证明不了：真实 SSH、真实落地机上的 docker 与 rclone 的行为。

L=/tmp/na            # 假实现的状态与日志
FB=/tmp/nabin        # 假命令
DATA=$L/node/data
PASSF=/root/na-bp

setup() {
  rm -rf "$L" "$FB" /etc/ops-scripts /run/lock/newapi-fullbackup.lock /tmp/newapi-snap-*
  mkdir -p "$DATA/logs" "$L/out" "$L/cloud" "$FB" /run/lock
  sqlite3 "$DATA/one-api.db" "CREATE TABLE options(key text, value text); INSERT INTO options VALUES ('a','1'),('b','2');"
  echo noise > "$DATA/logs/oneapi.log"
  printf 'correct-horse-battery-staple-03\n' > "$PASSF"; chmod 600 "$PASSF"
  mkdir -p /etc/ops-scripts
  printf '%s\n' 'NEWAPI_HOST="198.51.100.8"' 'NEWAPI_SSH_PORT="41452"' "NEWAPI_DATA_DIR=\"$DATA\"" \
    "BACKUP_LOCAL_ROOT=\"$L/out\"" "BACKUP_PASS_FILE=\"$PASSF\"" 'MAIL_TO="ops@example.com"' \
    'NEWAPI_HEARTBEAT_URL="https://hc.example/ping/na"' "NEWAPI_BACKUP_LOG=\"$L/backup.log\"" \
    "ALERT_FALLBACK_FILE=\"$L/alerts.log\"" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
  fakes
  export PATH="$FB:$PATH"
}

fakes() {
  # ssh：跳过选项，远端命令在本机执行。$L/probe-drop、$L/snap-drop 里写 N：
  # 前 N 次连接探测握手超时 / 前 N 次拉快照传到一半断开（退出码 255，同真 ssh）
  cat > "$FB/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> /tmp/na/ssh.log
while [ $# -gt 0 ]; do
  case "$1" in -o|-p|-i|-l) shift 2 ;; -n) exec </dev/null; shift ;; -*) shift ;; *) break ;; esac
done
shift
dec() { local f=/tmp/na/$1 n; [ -s "$f" ] || return 1; n=$(cat "$f"); [ "$n" -gt 0 ] || return 1; echo $((n - 1)) > "$f"; }
if [ "$*" = true ] && dec probe-drop; then echo "Connection timed out during banner exchange" >&2; exit 255; fi
if [[ "$*" == *"bash -s"* ]] && dec snap-drop; then cat >/dev/null; echo "Timeout, server 198.51.100.8 not responding." >&2; exit 255; fi
exec bash -c "$*"
EOF
  # docker：只回答落地机快照要的 inspect / ps
  cat > "$FB/docker" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "inspect --format"|"inspect -f") case "$*" in *Config.Image*) echo calciumion/new-api:v1.0.0-rc.40 ;; *) echo sha256:abc ;; esac ;;
  "image inspect") echo "calciumion/new-api@sha256:$(printf 'a%.0s' $(seq 64))" ;;
  "inspect new-api") echo '[{"Name":"/new-api"}]' ;;
  "ps -a") printf 'new-api\tcalciumion/new-api:v1.0.0-rc.40\tUp 1 day\n' ;;
esac
exit 0
EOF
  # rclone：<远端>:<目录> 映射到 $L/cloud/<远端>/<目录>
  cat > "$FB/rclone" <<'EOF'
#!/bin/bash
C=/tmp/na/cloud
echo "rclone $*" >> /tmp/na/rclone.log
loc() { local r=${1%%:*} p=${1#*:}; p=${p#/}; printf '%s/%s/%s' "$C" "$r" "${p%/}"; }
cmd=$1; shift
case "$cmd" in
  copy) d=$(loc "$2"); mkdir -p "$d"; cp "$1" "$d/" ;;
  check) inc=""; for a; do [ "$prev" = --include ] && inc=$a; prev=$a; done; cmp -s "$1/$inc" "$(loc "$2")/$inc" ;;
  lsf)
    d=$(loc "$1"); shift; pat='*' fmt=""
    while [ $# -gt 0 ]; do case "$1" in --include) pat=$2; shift 2 ;; --format) fmt=$2; shift 2 ;; *) shift ;; esac; done
    for f in "$d"/$pat; do
      [ -f "$f" ] || continue
      if [ "$fmt" = tsp ]; then printf '%s;%s;%s\n' "$(date -u -r "$f" '+%Y-%m-%d %H:%M:%S')" "$(stat -c %s "$f")" "${f##*/}"
      else echo "${f##*/}"; fi
    done ;;
  deletefile) rm -f "$(loc "$1")" ;;
esac
EOF
  printf '#!/bin/sh\necho "curl $*" >> /tmp/na/curl.log\n' > "$FB/curl"
  printf '#!/bin/sh\necho "$*" >> /tmp/na/sleep.log\n' > "$FB/sleep"
  chmod 755 "$FB"/*
}

backup() { run bash /src/backup/newapi-fullbackup.sh; }
pkg() { ls "$L"/out/newapi/newapi_*.7z 2>/dev/null | tail -1; }
none() {  # none <正则> <文本>：文本里不能有匹配的行
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2
  return 1
}

@test "备份：在线快照拉回、加密出包、两个网盘都传了并校验，心跳成功" {
  backup
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"结束：正常"* ]]
  [[ "$output" == *"SQLite integrity_check: ok"* ]]
  P=$(pkg); [ -n "$P" ]
  [ -f "$P.sha256" ]
  rm -rf "$L/x"; 7z x -p"$(head -1 "$PASSF")" -o"$L/x" "$P" </dev/null >/dev/null
  [ "$(sqlite3 "$L/x/one-api.db" 'SELECT count(*) FROM options')" = 2 ]
  [ ! -e "$L/x/data-rest/logs" ]
  [ -f "$L/cloud/onedrive/Backups/newapi/$(basename "$P")" ]
  [ -f "$L/cloud/gdrive/Backups/newapi/$(basename "$P")" ]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/na" ]
  [ -z "$(ls -d /tmp/newapi-snap-* 2>/dev/null)" ]
}

@test "备份：线路抖动（握手超时、传到一半断开）隔一会儿重试，成功了照常出包、不告警；落地机上中断留下的旧暂存被清掉" {
  echo 2 > "$L/probe-drop"; echo 1 > "$L/snap-drop"
  mkdir -p /tmp/newapi-snap-stale /tmp/newapi-snap-fresh; touch -d '3 hours ago' /tmp/newapi-snap-stale
  backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"结束：正常"* ]]
  [ "$(grep -c '连接中断或超时' "$L/backup.log")" = 3 ]
  grep -q 'Timeout, server 198.51.100.8 not responding' "$L/backup.log"
  [ "$(grep -cx 180 "$L/sleep.log")" = 3 ]
  [ -n "$(pkg)" ]
  [ ! -e "$L/alerts.log" ]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/na" ]
  [ ! -e /tmp/newapi-snap-stale ]
  [ -d /tmp/newapi-snap-fresh ]
  rm -rf /tmp/newapi-snap-fresh
}

@test "备份：重试用完仍连不上就失败并说明试了几次：不出包、心跳 /fail、告警落盘" {
  echo 9 > "$L/probe-drop"
  backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"试了 3 次"* ]]
  [ "$(grep -c ' true$' "$L/ssh.log")" = 3 ]
  [ -z "$(pkg)" ]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/na/fail" ]
  grep -q '\[FAIL\] new-api backup' "$L/alerts.log"
  echo 0 > "$L/probe-drop"; echo 9 > "$L/snap-drop"; rm -f "$L/alerts.log"
  backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"快照生成或传输失败（试了 3 次"* ]]
  [ -z "$(pkg)" ]
}

@test "备份：落地机上的命令自己报错（找不到 one-api.db）不是线路问题：立即失败、不重试" {
  rm -f "$DATA/one-api.db"
  backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"快照生成或传输失败"* ]]
  [ "$(grep -c 'bash -s' "$L/ssh.log")" = 1 ]
  [ ! -e "$L/sleep.log" ] || none '^180$' "$(cat "$L/sleep.log")"
  [ -z "$(pkg)" ]
}

@test "备份：quota_data 在副本上清空（表结构留着）、logs 表照留；程序日志 logs/ 不进包；生产库不动" {
  sqlite3 "$DATA/one-api.db" "CREATE TABLE quota_data(id, quota); INSERT INTO quota_data VALUES (1, 10), (2, 20);
                              CREATE TABLE logs(id, content); INSERT INTO logs VALUES (1, 'call');"
  backup
  [ "$status" -eq 0 ]
  P=$(pkg); rm -rf "$L/x"; 7z x -p"$(head -1 "$PASSF")" -o"$L/x" "$P" </dev/null >/dev/null
  [ "$(sqlite3 "$L/x/one-api.db" 'SELECT count(*) FROM quota_data')" = 0 ]
  [ "$(sqlite3 "$L/x/one-api.db" 'SELECT count(*) FROM logs')" = 1 ]
  [ "$(sqlite3 "$L/x/one-api.db" 'SELECT count(*) FROM options')" = 2 ]
  [ ! -e "$L/x/data-rest/logs" ]
  [ "$(sqlite3 "$DATA/one-api.db" 'SELECT count(*) FROM quota_data')" = 2 ]
  grep -q '只收表结构的历史表: quota_data' "$L/x/manifest.txt"
}
