#!/usr/bin/env bats
# tests/litellm.bats — 真跑 backup/litellm-fullbackup、ops/litellm-drill 与 ops/verify-backup-pass（不是桩）。
# ssh / docker / rclone / curl / sleep 换成假实现：ssh 在本机直接执行远端命令，docker 模拟 LiteLLM 的三个容器，
# rclone 把远端映射到本地目录。7z、tar、sha256sum、flock 与公共库都是真的。
# 能证明：远端导出与校验的调用、包的内容（导出、.env、锁 digest 的 compose、镜像清单、RESTORE.md）、加密、
# 上传与校验、GFS 清理、失败时不出包不清理、锁、心跳；演练的拦截、恢复顺序与清理。
# 证明不了：真实 pg_dump / pg_restore 与 LiteLLM、SSH、rclone、Docker 的行为。

L=/tmp/ll            # 假实现的状态与日志
FB=/tmp/llbin        # 假命令
W=$L/node/opt/litellm
PASSF=/root/ll-bp
DIG1=$(printf '1%.0s' $(seq 64)) DIG2=$(printf '2%.0s' $(seq 64)) DIG3=$(printf '3%.0s' $(seq 64))

setup() {
  rm -rf "$L" "$FB" /etc/ops-scripts /opt/litellm-drill /root/.vps-hosts.txt /run/lock/litellm-fullbackup.lock \
         /var/lib/ops-scripts/litellm-drill-* /usr/local/bin/*-fullbackup.sh
  mkdir -p "$W/pgdata" "$W/logs" "$L/out" "$L/cloud" "$FB" /run/lock
  printf '%s\n' 'LITELLM_MASTER_KEY=sk-master-0123456789abcdef' 'LITELLM_SALT_KEY=salt-0123456789abcdef0123' \
    'POSTGRES_PASSWORD=pg-pass-0123' 'DATABASE_URL=postgresql://litellm:pg-pass-0123@postgres:5432/litellm' > "$W/.env"
  chmod 600 "$W/.env"
  printf 'general_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n' > "$W/config.yaml"
  cat > "$W/docker-compose.yml" <<'EOF'
services:
  litellm:
    image: ghcr.io/berriai/litellm:1.99.1
    container_name: litellm
    ports:
      - "127.0.0.1:4000:4000"
    env_file: .env
  postgres:
    image: postgres:17
    container_name: litellm-postgres
    volumes:
      - ./pgdata:/var/lib/postgresql/data
  redis:
    image: redis:7
    container_name: litellm-redis
    command: ["redis-server", "--save", "", "--appendonly", "no"]
EOF
  echo 17 > "$W/pgdata/PG_VERSION"; echo noise > "$W/logs/proxy.txt"; echo noise > "$W/litellm.log"
  printf 'litellm\nlitellm-postgres\nlitellm-redis\n' > "$L/containers"
  printf 'correct-horse-battery-staple-02\n' > "$PASSF"; chmod 600 "$PASSF"
  env_conf
  fakes
  export PATH="$FB:$PATH"
}

env_conf() {  # env_conf [额外行...]
  mkdir -p /etc/ops-scripts
  printf '%s\n' 'LITELLM_HOST="198.51.100.7"' "LITELLM_WORKDIR=\"$W\"" "LITELLM_BACKUP_DIR=\"$L/out\"" \
    "BACKUP_PASS_FILE=\"$PASSF\"" 'RCLONE_REMOTES="onedrive gdrive"' 'MAIL_TO="ops@example.com"' \
    'LITELLM_HEARTBEAT_URL="https://hc.example/ping/ll"' "LITELLM_BACKUP_LOG=\"$L/backup.log\"" \
    "ALERT_FALLBACK_FILE=\"$L/alerts.log\"" 'NEWAPI_HOST="198.51.100.8"' "$@" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
}

fakes() {
  # ssh：跳过选项，远端命令在本机执行（-n 时 stdin 接 /dev/null）
  cat > "$FB/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> /tmp/ll/ssh.log
while [ $# -gt 0 ]; do
  case "$1" in -o|-p|-i|-l) shift 2 ;; -n) exec </dev/null; shift ;; -*) shift ;; *) break ;; esac
done
shift
exec bash -c "$*"
EOF
  # docker：$L/containers 是现有容器；事件记进 $L/events
  cat > "$FB/docker" <<EOF
#!/bin/bash
L=$L
DIG1=$DIG1 DIG2=$DIG2 DIG3=$DIG3
EOF
  cat >> "$FB/docker" <<'EOF'
echo "docker $*" >> $L/docker.log
has() { grep -qx "$1" $L/containers 2>/dev/null; }
img() { case $1 in litellm) echo ghcr.io/berriai/litellm:1.99.1 ;; litellm-postgres) echo postgres:17 ;; litellm-redis) echo redis:7 ;; esac; }
dig() { case $1 in litellm) echo ghcr.io/berriai/litellm@sha256:$DIG1 ;; litellm-postgres) echo postgres@sha256:$DIG2 ;; litellm-redis) echo redis@sha256:$DIG3 ;; esac; }
case "$1" in
  inspect)
    shift; fmt=""
    if [ "$1" = -f ] || [ "$1" = --format ]; then fmt=$2; shift 2; fi
    has "$1" || exit 1
    case "$fmt" in
      *State.Running*) echo true ;;
      *Config.Image*)  img "$1" ;;
      *'{{.Image}}'*)  echo "sha256:id-$1" ;;
      '')              printf '[{"Name":"/%s"}]\n' "$1" ;;
    esac ;;
  image)
    c=${!#}; c=${c#sha256:id-}
    [ -e $L/nodigest-$c ] && { echo; exit 0; }
    dig "$c" ;;
  exec)
    shift; [ "$1" = -i ] && shift; c=$1; shift
    has "$c" || { echo "Error: No such container: $c" >&2; exit 1; }
    case "$1" in
      pg_dump) [ -e $L/dump-empty ] || printf 'PGDMP\001fake custom-format dump of litellm\n' ;;
      pg_restore)
        in=$(cat)
        if [[ " $* " == *" --list "* ]]; then
          if [ -e $L/toc-bad ] || [[ "$in" != PGDMP* ]]; then
            echo "pg_restore: error: input file does not appear to be a valid archive" >&2; exit 1
          fi
          printf ';\n; Archive created at 2026-09-28 12:00:00 UTC\n;\n'
          printf '215; 1259 16386 TABLE public LiteLLM_ProxyModelTable litellm\n'
          printf '3390; 0 16386 TABLE DATA public LiteLLM_ProxyModelTable litellm\n'
          printf '3391; 0 16390 TABLE DATA public LiteLLM_VerificationToken litellm\n'
        else
          printf '%s\n' "$in" > $L/restored.dump; echo "RESTORE $*" >> $L/events
        fi ;;
      psql) echo 3 ;;
      pg_isready) exit 0 ;;
    esac ;;
  ps) cat $L/containers 2>/dev/null ;;
  version) echo 27.3.1 ;;
  compose)
    shift
    case "$1" in
      version) echo "Docker Compose version v2.29.0" ;;
      up)
        echo "COMPOSE $* env=$(stat -c %a .env 2>/dev/null || echo 无) image=$(grep -m1 berriai docker-compose.yml | tr -d ' ')" >> $L/events
        if [[ " $* " == *" postgres "* ]]; then echo litellm-postgres >> $L/containers
        else printf 'litellm\nlitellm-postgres\nlitellm-redis\n' >> $L/containers; fi
        sort -u -o $L/containers $L/containers ;;
      down) echo "COMPOSE $* in $PWD" >> $L/events; : > $L/containers ;;
      pull) echo "COMPOSE pull in $PWD" >> $L/events ;;
    esac ;;
  logs) cat $L/litellm-logs 2>/dev/null ;;
esac
exit 0
EOF
  # rclone：<远端>:<目录> 映射到 $L/cloud/<远端>/<目录>；$L/rclone-fail-<远端> 存在时上传失败
  cat > "$FB/rclone" <<'EOF'
#!/bin/bash
C=/tmp/ll/cloud
echo "rclone $*" >> /tmp/ll/rclone.log
loc() { local r=${1%%:*} p=${1#*:}; p=${p#/}; printf '%s/%s/%s' "$C" "$r" "${p%/}"; }
cmd=$1; shift
case "$cmd" in
  copy)
    if [[ "$2" == *:* ]]; then
      [ -e "/tmp/ll/rclone-fail-${2%%:*}" ] && exit 1
      d=$(loc "$2"); mkdir -p "$d"; cp "$1" "$d/"
    else
      s=$(loc "$1"); [ -f "$s" ] || exit 1; mkdir -p "$2"; cp "$s" "$2/"
    fi ;;
  check) cmp -s "$1/$4" "$(loc "$2")/$4" ;;
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
  # curl：-w 时回 200；/v1/models 回三个模型；都记下参数
  cat > "$FB/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> /tmp/ll/curl.log
for a; do [ "$a" = -w ] && { printf 200; exit 0; }; done
for a; do case "$a" in */v1/models) cat >/dev/null; printf '{"data":[{"id":"relay/a"},{"id":"relay/b"},{"id":"direct/c"}]}'; exit 0 ;; esac; done
exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "$FB/sleep"
  chmod 755 "$FB"/*
}

backup() { run bash /src/backup/litellm-fullbackup.sh; }
pkg() { ls "$L"/out/litellm_*.7z 2>/dev/null | tail -1; }
unpack() { rm -rf "$L/x"; 7z x -p"$(head -1 "$PASSF")" -o"$L/x" "$1" </dev/null >/dev/null; }
none() {  # none <正则> <文本>：文本里不能有匹配的行
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2; return 1
}

# ── 备份 ────────────────────────────────────────────────────
@test "备份：包里有导出、.env、锁 digest 的 compose、镜像清单与还原说明；pgdata 与日志不进包；两个网盘都传了" {
  backup
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"结束：正常"* ]]
  grep -qx "docker exec litellm-postgres pg_dump -U litellm -Fc litellm" "$L/docker.log"
  grep -qx "docker exec -i litellm-postgres pg_restore --list" "$L/docker.log"
  P=$(pkg); [ -n "$P" ] && [ -f "$P.sha256" ]
  [ "$(stat -c %a "$P")" = 600 ]
  unpack "$P"
  [ "$(head -c 5 "$L/x/db/litellm.dump")" = PGDMP ]
  grep -q 'TABLE DATA public LiteLLM_ProxyModelTable' "$L/x/db/litellm.toc"
  cmp "$W/.env" "$L/x/workdir/.env"
  [ -f "$L/x/workdir/config.yaml" ] && [ -f "$L/x/workdir/docker-compose.yml" ]
  [ ! -e "$L/x/workdir/pgdata" ] && [ ! -e "$L/x/workdir/logs" ] && [ ! -e "$L/x/workdir/litellm.log" ]
  grep -qP "^litellm\tghcr.io/berriai/litellm:1.99.1\tghcr.io/berriai/litellm@sha256:$DIG1$" "$L/x/images.tsv"
  grep -qP "^litellm-postgres\tpostgres:17\tpostgres@sha256:$DIG2$" "$L/x/images.tsv"
  grep -qP "^litellm-redis\tredis:7\tredis@sha256:$DIG3$" "$L/x/images.tsv"
  C="$L/x/system/docker-compose.pinned.yml"
  grep -qx "    image: ghcr.io/berriai/litellm@sha256:$DIG1" "$C"
  grep -qx "    image: postgres@sha256:$DIG2" "$C"
  grep -qx "    image: redis@sha256:$DIG3" "$C"
  [ -f "$L/x/system/inspect-litellm-postgres.json" ]
  # 盐值只以指纹出现在清单、还原说明和日志里
  fp=$(printf 'salt-0123456789abcdef0123' | sha256sum | cut -c1-12)
  grep -q "LITELLM_SALT_KEY 指纹(sha256 前 12 位): $fp" "$L/x/manifest.txt"
  R="$L/x/RESTORE.md"
  grep -q "$fp" "$R"
  grep -q "LITELLM_SALT_KEY 必须是原来那一个" "$R"
  grep -q "docker compose up -d postgres" "$R"
  grep -q "pg_restore -U litellm -d litellm --clean --if-exists" "$R"
  grep -q "mkdir -p $W" "$R"
  grep -q "127.0.0.1:4000/health/liveliness" "$R"
  none '\{\{' "$(cat "$R")"
  none 'salt-0123456789abcdef0123|sk-master' "$(cat "$L/backup.log")"
  # 两个网盘都有包和旁注；本地暂存区不留
  for r in onedrive gdrive; do
    cmp "$P" "$L/cloud/$r/Backup-LiteLLM/$(basename "$P")"
    [ -f "$L/cloud/$r/Backup-LiteLLM/$(basename "$P").sha256" ]
  done
  [ -z "$(ls -A "$L/out" | grep staging)" ]
  # 心跳：先 /start，最后报成功
  [ "$(head -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/ll/start" ]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/ll" ]
}

@test "备份：SSH 端口取 LITELLM_SSH_PORT，没有就取 ~/.vps-hosts.txt（整段匹配，不被相似 IP 骗）" {
  printf '%s\n' 'root@198.51.100.70:2200' '# root@198.51.100.7:9999' 'root@198.51.100.7:2222' > /root/.vps-hosts.txt
  backup
  [ "$status" -eq 0 ]
  grep -q -- '-p 2222 root@198.51.100.7' "$L/ssh.log"
  none '-p (2200|9999|22) ' "$(cat "$L/ssh.log")"
  rm -f "$L/ssh.log" "$L"/out/litellm_*; env_conf 'LITELLM_SSH_PORT=2345'
  backup
  [ "$status" -eq 0 ]
  grep -q -- '-p 2345 root@198.51.100.7' "$L/ssh.log"
}

@test "备份：pg_restore --list 读不开导出就失败：不出包、心跳 /fail、告警落盘" {
  touch "$L/toc-bad"
  backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"pg_restore --list 读不了这份导出"* ]]
  [ -z "$(pkg)" ]
  [ -z "$(ls "$L/cloud")" ]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/ll/fail" ]
  grep -q '\[FAIL\] LiteLLM backup' "$L/alerts.log"
  [ -z "$(ls -A "$L/out")" ]
}

@test "备份：导出为空、.env 没有盐值、postgres 没在跑，都失败且不出包" {
  touch "$L/dump-empty"
  backup; [ "$status" -eq 1 ]; [[ "$output" == *"pg_dump 输出为空"* ]]; [ -z "$(pkg)" ]
  rm -f "$L/dump-empty"
  sed -i '/^LITELLM_SALT_KEY=/d' "$W/.env"
  backup; [ "$status" -eq 1 ]; [[ "$output" == *"里没有 LITELLM_SALT_KEY"* ]]; [ -z "$(pkg)" ]
  echo 'LITELLM_SALT_KEY=salt-0123456789abcdef0123' >> "$W/.env"
  sed -i '/^litellm-postgres$/d' "$L/containers"
  backup; [ "$status" -eq 1 ]; [[ "$output" == *"litellm-postgres 没在运行"* ]]; [ -z "$(pkg)" ]
}

@test "备份：分级保留按 bk_gfs_select 清理本地与两个网盘；有一个网盘失败就一个都不删" {
  local now h n
  now=$(date +%s)
  # 60 天、每 6 小时一份；错开半小时，年龄不落在整天的档位边界上
  for ((h = 60 * 24; h >= 6; h -= 6)); do
    n=$(TZ=UTC date -d "@$((now - h * 3600 - 1800))" '+litellm_%Y%m%d_%H%M%S.7z')
    for d in "$L/out" "$L/cloud/onedrive/Backup-LiteLLM" "$L/cloud/gdrive/Backup-LiteLLM"; do mkdir -p "$d"; : > "$d/$n"; done
  done
  ls "$L/out" > "$L/old"
  touch "$L/rclone-fail-gdrive"
  backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"跳过清理"* ]]
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/ll/fail" ]
  for n in $(cat "$L/old"); do
    [ -e "$L/out/$n" ] || { echo "本地删了 $n"; false; }
    [ -e "$L/cloud/onedrive/Backup-LiteLLM/$n" ] || { echo "onedrive 删了 $n"; false; }
  done
  rm -f "$L/rclone-fail-gdrive" "$L/curl.log"
  # 清理前用公共库独立算一遍应删的名单（本地上限 180 天、云端 400 天，60 天的数据两边一样）。
  # 这次新出的包最新、在全留档里，不影响其余包的分档
  ls "$L/out" > "$L/all"
  del=$(bash -c '. /src/lib/common.sh; bk_gfs_select "$(date +%s)" 7 30 90 180' < "$L/all")
  [ "$(wc -l <<<"$del")" -gt 100 ]
  backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"结束：正常"* ]]
  for n in $del; do
    [ ! -e "$L/out/$n" ] || { echo "本地没删 $n"; false; }
    [ ! -e "$L/cloud/onedrive/Backup-LiteLLM/$n" ] || { echo "onedrive 没删 $n"; false; }
    [ ! -e "$L/cloud/gdrive/Backup-LiteLLM/$n" ] || { echo "gdrive 没删 $n"; false; }
  done
  for n in $(grep -vxF -f <(printf '%s\n' "$del") "$L/all"); do
    [ -e "$L/out/$n" ] || { echo "本地多删了 $n"; false; }
    [ -e "$L/cloud/onedrive/Backup-LiteLLM/$n" ] || { echo "onedrive 多删了 $n"; false; }
  done
  # 新包在（两次可能在同一秒内跑完、同名，所以至少一份）
  [ "$(ls "$L"/out/litellm_*.7z.sha256 | wc -l)" -ge 1 ]
}

@test "备份：上一轮还在跑（锁被占）时直接跳过，不报心跳" {
  # 假 sleep 会立刻返回，持锁要用真的
  flock /run/lock/litellm-fullbackup.lock /bin/sleep 30 &
  local holder=$!
  /bin/sleep 0.3
  backup
  kill "$holder" 2>/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"上一轮备份还在运行，本次跳过"* ]]
  [ ! -e "$L/curl.log" ] && [ -z "$(pkg)" ]
}

@test "备份：镜像没有 RepoDigest 时告警，compose 里那个镜像保持原标签" {
  touch "$L/nodigest-litellm-redis"
  backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"容器 litellm-redis 的镜像 redis:7 没有 RepoDigest"* ]]
  unpack "$(pkg)"
  grep -qx '    image: redis:7' "$L/x/system/docker-compose.pinned.yml"
  grep -qx "    image: ghcr.io/berriai/litellm@sha256:$DIG1" "$L/x/system/docker-compose.pinned.yml"
  [ "$(tail -1 "$L/curl.log")" = "curl -fsS -m 10 --retry 2 https://hc.example/ping/ll/fail" ]
}

@test "备份：缺必填配置时失败并说出缺哪个" {
  sed -i '/^LITELLM_BACKUP_DIR=/d' /etc/ops-scripts/env.conf
  backup
  [ "$status" -eq 1 ]
  [[ "$output" == *"env.conf 缺少必填项 LITELLM_BACKUP_DIR"* ]]
  [ ! -e "$L/ssh.log" ]
}

# ── 云端校验 ────────────────────────────────────────────────
@test "校验：装了 litellm-fullbackup、RCLONE_PATHS 没列 Backup-LiteLLM 时自动并入并能解开" {
  backup; [ "$status" -eq 0 ]
  printf '#!/bin/sh\n' > /usr/local/bin/litellm-fullbackup.sh; chmod 755 /usr/local/bin/litellm-fullbackup.sh
  env_conf "BACKUP_PASS_FILES=\"$PASSF\"" 'RCLONE_PATHS="Backup-Server"'
  run bash /src/ops/verify-backup-pass.sh
  echo "$output"
  [[ "$output" == *"litellm-fullbackup 的云端目录 Backup-LiteLLM 不在 RCLONE_PATHS 里"* ]]
  [[ "$output" == *"✓ onedrive:/Backup-LiteLLM litellm_"*"可解开"* ]]
  [[ "$output" == *"✓ gdrive:/Backup-LiteLLM litellm_"*"可解开"* ]]
  # 已经列了的不重复校验
  env_conf "BACKUP_PASS_FILES=\"$PASSF\"" 'RCLONE_PATHS="Backup-Server /Backup-LiteLLM/"'
  run bash /src/ops/verify-backup-pass.sh
  [[ "$output" == *"litellm-fullbackup → Backup-LiteLLM"* ]]
  [ "$(grep -c '^===== onedrive:/Backup-LiteLLM' <<<"$output")" -eq 1 ]
}

# ── 演练 ────────────────────────────────────────────────────
drill() { run bash /src/ops/litellm-drill.sh "$@"; }
spare() {  # 备用机的样子：清单里有它的端口，没有 litellm 容器，也没有生产的工作目录
  printf '%s\n' 'root@203.0.113.50:2222' >> /root/.vps-hosts.txt
  : > "$L/containers"
  mv "$W" "$L/node-gone"
}

@test "演练：拒绝生产 LiteLLM 节点、落地机与本机，且不连 SSH" {
  printf '%s\n' 'root@198.51.100.7:22' 'root@198.51.100.8:22' 'root@127.0.0.1:22' > /root/.vps-hosts.txt
  drill restore 198.51.100.7
  [ "$status" -ne 0 ]; [[ "$output" == *"生产 LiteLLM 节点 LITELLM_HOST"* ]]
  drill teardown 198.51.100.8
  [ "$status" -ne 0 ]; [[ "$output" == *"生产落地机 NEWAPI_HOST"* ]]
  drill restore 127.0.0.1
  [ "$status" -ne 0 ]; [[ "$output" == *"目标是本机"* ]]
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$ip" ]; then drill restore "$ip"; [ "$status" -ne 0 ]; [[ "$output" == *"目标是本机"* ]]; fi
  drill restore '203.0.113.50;rm'
  [ "$status" -ne 0 ]; [[ "$output" == *"目标地址不合法"* ]]
  [ ! -e "$L/ssh.log" ]
}

@test "演练：按 RESTORE.md 的顺序恢复（先 .env、只起 postgres、pg_restore --clean --if-exists、按 digest 起全部），master key 不上命令行" {
  backup; [ "$status" -eq 0 ]; P=$(pkg)
  spare; rm -f "$L/events" "$L/ssh.log" "$L/curl.log"
  drill restore 203.0.113.50 "$P"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"恢复完成"* ]]
  E=$(cat "$L/events"); echo "$E"
  [ "$(sed -n 1p <<<"$E")" = "COMPOSE pull in /opt/litellm-drill" ]
  [ "$(sed -n 2p <<<"$E")" = "COMPOSE up -d postgres env=600 image=image:ghcr.io/berriai/litellm@sha256:$DIG1" ]
  [ "$(sed -n 3p <<<"$E")" = "RESTORE pg_restore -U litellm -d litellm --clean --if-exists" ]
  [ "$(sed -n 4p <<<"$E")" = "COMPOSE up -d env=600 image=image:ghcr.io/berriai/litellm@sha256:$DIG1" ]
  unpack "$P"; cmp "$L/x/db/litellm.dump" "$L/restored.dump"
  cmp "$L/x/workdir/.env" /opt/litellm-drill/.env
  [ -e /opt/litellm-drill/.litellm-drill ] && [ ! -e /opt/litellm-drill/.restore ]
  grep -q "^RESTORED_FROM=$(basename "$P")$" /var/lib/ops-scripts/litellm-drill-203.0.113.50.state
  grep -q -- '-p 2222 root@203.0.113.50' "$L/ssh.log"
  # verify：与线上比行数（假 docker 两边都是 3），列模型；日志里有解密错误要告警
  drill verify 203.0.113.50
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"行数全部一致"* ]]
  [[ "$output" == *"带 master key 列模型：3 个"* ]]
  [[ "$output" == *"日志里没有解密错误"* ]]
  echo 'ERROR: Unable to decrypt value - invalid LITELLM_SALT_KEY' > "$L/litellm-logs"
  drill verify 203.0.113.50
  [[ "$output" == *"盐值可能不对"* ]]
  none 'sk-master' "$(cat "$L/ssh.log" "$L/curl.log")"
}

@test "演练：目标机已有 litellm 容器、生产或上次的目录时拒绝，什么都不动" {
  backup; [ "$status" -eq 0 ]; P=$(pkg)
  spare; echo litellm > "$L/containers"; rm -f "$L/events"
  drill restore 203.0.113.50 "$P"
  [ "$status" -ne 0 ]; [[ "$output" == *"不像干净的备用机"*"容器 litellm"* ]]
  : > "$L/containers"; mkdir -p /opt/litellm-drill
  drill restore 203.0.113.50 "$P"
  [ "$status" -ne 0 ]; [[ "$output" == *"目录 /opt/litellm-drill"* ]]
  [ ! -e "$L/events" ] && [ ! -e /var/lib/ops-scripts/litellm-drill-203.0.113.50.state ]
}

@test "演练 teardown：没有演练标记的目录不删；有标记的删掉容器与目录，状态清掉" {
  backup; [ "$status" -eq 0 ]; P=$(pkg)
  spare
  mkdir -p /opt/litellm-drill; echo keep > /opt/litellm-drill/x
  OPS_YES=1 drill teardown 203.0.113.50
  [ "$status" -ne 0 ]; [[ "$output" == *"没有演练标记"* ]]
  [ -f /opt/litellm-drill/x ]
  rm -rf /opt/litellm-drill
  drill restore 203.0.113.50 "$P"; [ "$status" -eq 0 ]
  OPS_YES=1 drill teardown 203.0.113.50
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'COMPOSE down -v --remove-orphans in /opt/litellm-drill' "$L/events"
  [ ! -e /opt/litellm-drill ] && [ ! -s "$L/containers" ]
  [ ! -e /var/lib/ops-scripts/litellm-drill-203.0.113.50.state ]
  grep -q "docker rmi ghcr.io/berriai/litellm@sha256:$DIG1" "$L/docker.log"
}
