#!/usr/bin/env bats
# tests/live-migrate.bats — 真跑 migrate/live-migrate 与备份脚本的 --local-only。
# 「旧机」是这台容器：crontab 是真的，vw-fullbackup 真跑出加密包；docker / mysql / rclone / ufw 换成记录调用的假实现。
# 「新机」也在这台容器里，由假 ssh 扮演：代理的只读动作（probe / prep / sha）和改防火墙的动作（allow-me、peer-*）真跑，
# probe 的结果再按 $NH/facts 改写成新机的样子；会动服务、库、定时任务的动作（restore / check / verify / standby / tunnel）
# 只记进 $RCALLS，按 $NH/rc.<动作>、$NH/out.<动作> 回话 —— 在同一台机器上真跑会动到「旧机」自己。传文件的命令真跑。
# 能证明：预检拒绝、演练不动本机、切换暂停备份任务并停容器、回滚复原、包现做现传且 sha 一致、放行名单的增删、DNS 复核。
# 证明不了：两台真机器之间的 SSH（两步验证、放行名单生效）、MySQL、Docker、宝塔、nginx、DNS。

load helpers

setup_file() { mock_build; http_start; }
teardown_file() { http_stop; }

L=/tmp/lm                 # 旧机的服务目录
NH=/tmp/newhost           # 假 ssh 的控制文件
RCALLS=/tmp/remote.calls
PASSF=/root/bp
NEW=127.0.0.2
ST=/var/lib/ops-scripts/live-migrate.state

setup() {
  reset_host
  rm -rf "$L" "$NH" "$RCALLS" /tmp/ssh.log /tmp/docker.log /tmp/fakedocker /tmp/ufw.log /tmp/ufw.numbered \
         /tmp/rclone.log /tmp/out /root/live-migrate /root/live-migrate-in /root/ops-backups /etc/ufw \
         /etc/ssh/sshd_config /root/.vps-hosts.txt /root/.my.cnf
  mkdir -p "$L/opt/vaultwarden/data" "$L/vhost" "$L/cert/a.example.com" "$L/vwbak" "$NH" /tmp/fakedocker
  grep -q 'ifconfig.me' /etc/hosts || echo '127.0.0.1 ifconfig.me' >> /etc/hosts   # 查出口 IP 不出网
  printf 'correct-horse-battery-staple-01\n' > "$PASSF"; chmod 600 "$PASSF"
  printf '[client]\n' > /root/.my.cnf; chmod 600 /root/.my.cnf
  env_conf
  echo v2099.01.01 > /etc/ops-scripts/ref
  cp "$SRC/lib/common.sh" /usr/local/lib/ops-common.sh
  install -m 755 "$SRC/backup/vw-fullbackup.sh" /usr/local/bin/vw-fullbackup.sh
  fakes
  # Vaultwarden：数据、配置、库
  echo KEY > "$L/opt/vaultwarden/data/rsa_key.pem"
  echo 'DATABASE_URL=mysql://vw:pw@host.docker.internal:3306/vaultwarden' > "$L/opt/vaultwarden/vaultwarden.env"
  printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:1.32.0\n' > "$L/opt/vaultwarden/compose.yaml"
  printf 'server {\n    server_name a.example.com;\n}\n' > "$L/vhost/a.example.com.conf"
  echo CERT > "$L/cert/a.example.com/fullchain.pem"
  echo running > /tmp/fakedocker/vaultwarden; echo running > /tmp/fakedocker/komari
  printf '%s\n' \
    '0 */6 * * * /usr/bin/flock -n /var/lock/vw-fullbackup-cron.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1' \
    '5 * * * * /usr/bin/flock -n /var/lock/newapi-fullbackup-cron.lock /usr/local/bin/newapi-fullbackup.sh >> /var/log/newapi-fullbackup-cron.log 2>&1' \
    '*/5 * * * * /usr/local/bin/newapi-linkcheck.sh --cron >> /var/log/newapi-fullbackup.log 2>&1' | crontab -
  crontab -l > /tmp/cron.before
  # 新机：做完 init/、空机器；其余（系统、MySQL 版本、固定版本、密码……）与旧机相同
  printf '%s\n' init=yes running=0 dbs= dr_state= > "$NH/facts"
  export LIVE_MIGRATE_DOH="http://127.0.0.1:$PORT/doh"
}

env_conf() {  # env_conf [追加的 键=值...]
  mkdir -p /etc/ops-scripts
  printf '%s\n' "BACKUP_PASS_FILE=$PASSF" MYSQL_DEFAULTS_FILE=/root/.my.cnf \
    "PANEL_VHOST_DIR=$L/vhost" "PANEL_CERT_DIR=$L/cert" "DB_CLIENT_HOST='172.%'" DOCKER_CIDR=172.16.0.0/12 \
    "SVC_VW_DIR=$L/opt/vaultwarden" "VW_BACKUP_DIR=$L/vwbak" VW_REMOTE_PATH=vw RCLONE_REMOTES=r1 \
    "VW_LOG_FILE=$L/vw.log" "VW_HEARTBEAT_URL=http://127.0.0.1:$PORT/hb-vw" "$@" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
}

fakes() {
  # ssh：见文件头
  cat > /usr/local/bin/ssh <<'SH'
#!/usr/bin/env bash
NH=/tmp/newhost
t="" cmd=() ctl="" master=0
while [ $# -gt 0 ]; do
  case "$1" in
    -O) ctl=$2; shift 2; continue ;;
    -p|-o|-i|-l|-F|-S|-J|-E|-c|-m) shift 2; continue ;;
    -N) master=1; shift; continue ;;
    -*) shift; continue ;;
  esac
  if [ -z "$t" ]; then t=$1; else cmd+=("$1"); fi
  shift
done
host=${t#*@}
case "$ctl" in check) exit 255 ;; ?*) exit 0 ;; esac
[ -e "$NH/down.$host" ] && { echo "$t: Permission denied (publickey)." >&2; exit 255; }
[ "$master" = 1 ] && exit 0
c="${cmd[*]}"
printf '%s %s\n' "$host" "$c" >> /tmp/ssh.log
export SSH_CONNECTION="127.0.0.1 50000 $host 22"
case "$c" in
  'bash -s -- '*)
    eval "set -- ${c#bash -s -- }"
    act=$1
    case "$act" in
      probe) bash -s -- "$@" | awk -F= 'NR == FNR { o[$1] = $0; next } ($1 in o) { print o[$1]; delete o[$1]; next } { print } END { for (k in o) print o[k] }' "$NH/facts" - ;;
      prep|sha|allow-me|unallow-me|peer-allow|peer-drop) bash -s -- "$@" ;;
      *) cat >/dev/null
         echo "$host $*" >> /tmp/remote.calls
         # 恢复那一刻「旧机」的样子：定时任务停没停、容器停没停
         [ "$act" = restore ] && { crontab -l; cat /tmp/fakedocker/vaultwarden; } > "$NH/at-restore.$(grep -c ' restore ' /tmp/remote.calls)"
         [ -f "$NH/out.$act" ] && cat "$NH/out.$act"
         exit "$(cat "$NH/rc.$act" 2>/dev/null || echo 0)" ;;
    esac ;;
  *) bash -c "$c" ;;
esac
SH
  # docker：容器状态在 /tmp/fakedocker/<名字>
  cat > /usr/local/bin/docker <<'SH'
#!/usr/bin/env bash
D=/tmp/fakedocker; mkdir -p "$D"
echo "$*" >> /tmp/docker.log
case "$1" in
  info) exit 0 ;;
  ps) all=0; for a in "$@"; do [ "$a" = -a ] && all=1; done
      for f in "$D"/*; do
        [ -f "$f" ] || continue
        if [ "$all" = 1 ] || [ "$(cat "$f")" = running ]; then echo "${f##*/}"; fi
      done ;;
  stop|start) v=$1; shift
      for n in "$@"; do
        [ -f "$D/$n" ] || exit 1
        if [ "$v" = stop ]; then echo exited > "$D/$n"; else echo running > "$D/$n"; fi
      done ;;
esac
exit 0
SH
  cat > /usr/local/bin/mysql <<'SH'
#!/usr/bin/env bash
q="" prev=""
for a in "$@"; do [ "$prev" = -e ] && q=$a; prev=$a; done
case "$q" in
  "SELECT 1") echo 1 ;;
  "SELECT VERSION()") echo 8.0.36 ;;
  *GROUP_CONCAT*) echo NULL ;;
  *data_length*) echo 0 ;;
  *) exit 1 ;;
esac
SH
  { printf '#!/bin/sh\necho "-- MySQL dump"\n'
    printf 'for i in $(seq 40); do echo "-- padding line $i ....................................."; done\n'
    printf 'echo "CREATE TABLE \\`t\\` (id int);"\necho "-- Dump completed on 2026-09-28"\n'; } > /usr/local/bin/mysqldump
  printf '#!/bin/sh\necho "$*" >> /tmp/rclone.log\n' > /usr/local/bin/rclone
  printf '#!/bin/sh\necho "$*" >> /tmp/ufw.log\n[ "$1 $2" = "status numbered" ] && cat /tmp/ufw.numbered 2>/dev/null\nexit 0\n' > /usr/local/bin/ufw
  chmod 755 /usr/local/bin/ssh /usr/local/bin/docker /usr/local/bin/mysql /usr/local/bin/mysqldump /usr/local/bin/rclone /usr/local/bin/ufw
}

lm() { run bash "$SRC/migrate/live-migrate.sh" "$@"; }
fact() { printf '%s\n' "$@" >> "$NH/facts"; }          # 后写的覆盖先写的
acts() { cut -d' ' -f2 "$RCALLS" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
phase() { awk -F'\t' '$1 == "PHASE" { p = $2 } END { print p }' "$ST"; }
lm_id() { awk -F'\t' '$1 == "ID" { print $2 }' "$ST"; }
running() { cat /tmp/fakedocker/vaultwarden /tmp/fakedocker/komari | tr '\n' ' ' | sed 's/ $//'; }
none() {  # none <正则> <文本>
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2; return 1
}

# ── 备份脚本的 --local-only ─────────────────────────────────
@test "vw --local-only：包只落在给定目录，不上传、不清理、不报心跳" {
  mkdir -p /tmp/out; touch /tmp/out/srvbak_20200101_000000.7z     # 很旧的包：正常模式下会被分级保留删掉
  : > /tmp/http.log.mark; wc -l < /tmp/http.log > /tmp/http.log.mark
  run /usr/local/bin/vw-fullbackup.sh --local-only /tmp/out
  [ "$status" -eq 0 ]
  has "不上传、不清理"
  f=$(ls /tmp/out/srvbak_2*.7z | grep -v 20200101)
  [ -f "$f.sha256" ]
  7z t -p"$(head -1 "$PASSF")" "$f" </dev/null >/dev/null
  [ -f /tmp/out/srvbak_20200101_000000.7z ]
  [ -z "$(ls "$L"/vwbak/*.7z 2>/dev/null)" ]
  [ ! -s /tmp/rclone.log ]
  none 'hb-vw' "$(tail -n +"$(( $(cat /tmp/http.log.mark) + 1 ))" /tmp/http.log)"
}

@test "vw --local-only：参数写错就停，不出包" {
  run /usr/local/bin/vw-fullbackup.sh --local-only
  [ "$status" -ne 0 ]
  run /usr/local/bin/vw-fullbackup.sh --upload-later
  [ "$status" -ne 0 ]
  has "未知参数"
  [ -z "$(ls "$L"/vwbak/*.7z 2>/dev/null)" ]
}

@test "xboard --local-only：包只落在给定目录，不上传、不清理、不报心跳" {
  install -m 755 "$SRC/backup/xboard-fullbackup.sh" /usr/local/bin/xboard-fullbackup.sh
  mkdir -p "$L/opt/xboard/storage" "$L/www" "$L/xbbak" /tmp/out
  printf '%s\n' 'APP_KEY=base64:abc' 'DB_DATABASE=xboard' > "$L/opt/xboard/.env"
  printf 'services:\n  xboard:\n    image: ghcr.io/cedar2025/xboard:1.0\n' > "$L/opt/xboard/compose.yaml"
  echo 'xb pass' > "$L/xbpass"
  touch /tmp/out/xboard_20200101_000000.7z
  env_conf "SVC_XBOARD_DIR=$L/opt/xboard" XBOARD_DB_NAME=xboard XBOARD_DB_USER=xboard "XBOARD_DB_PASS_FILE=$L/xbpass" \
    "XBOARD_BACKUP_DIR=$L/xbbak" XBOARD_REMOTE_PATH=xb "WWWROOT=$L/www" "XBOARD_HEARTBEAT_URL=http://127.0.0.1:$PORT/hb-xb"
  wc -l < /tmp/http.log > /tmp/http.log.mark
  run /usr/local/bin/xboard-fullbackup.sh --local-only /tmp/out
  has "不上传、不清理"
  f=$(ls /tmp/out/xboard_2*.7z | grep -v 20200101)
  [ -f "$f.sha256" ]
  7z t -p"$(head -1 "$PASSF")" "$f" </dev/null >/dev/null
  [ -f /tmp/out/xboard_20200101_000000.7z ]
  [ -z "$(ls "$L"/xbbak/*.7z 2>/dev/null)" ]
  [ ! -s /tmp/rclone.log ]
  lacks "分级保留"
  none 'hb-xb' "$(tail -n +"$(( $(cat /tmp/http.log.mark) + 1 ))" /tmp/http.log)"
}

# ── 预检 ────────────────────────────────────────────────────
@test "预检：密钥登录不通就停，指向 setup-key-login，两台都不动" {
  touch "$NH/down.$NEW"
  lm "$NEW" --ssh-port 2222
  [ "$status" -ne 0 ]
  has "opsget ops/setup-key-login $NEW 2222"
  [ ! -e "$ST" ] && [ ! -s "$RCALLS" ]
  crontab -l | diff /tmp/cron.before -
}

@test "预检：新机不合要求逐项拒绝，两台都不动" {
  local kv
  for kv in "os=debian 11|要 Debian 12" "init=no|还没做完 init/" "mysql=5.7.44|MySQL 大版本不同" \
            "mysql=|MySQL 连不上" "ref=v2001.01.01|固定的版本不同" "free_kb=10|只剩" \
            "dbs=appdb|新机上已经有数据" "running=2|新机上已经有数据" "docker=no|没有可用的 docker" \
            "pass_sha=deadbeef|备份密码" "dr_state=drill|teardown" "opsget=|没装 opsget"; do
    printf '%s\n' init=yes running=0 dbs= dr_state= "${kv%%|*}" > "$NH/facts"
    lm "$NEW" --check
    [ "$status" -ne 0 ] || { echo "没拒绝：${kv%%|*}" >&2; return 1; }
    has "${kv#*|}"
    has "预检没通过"
  done
  [ ! -e "$ST" ] && [ ! -s "$RCALLS" ]
  none 'stop' "$(cat /tmp/docker.log 2>/dev/null)"
  crontab -l | diff /tmp/cron.before -
}

@test "预检：本机的备份脚本太旧（不支持 --local-only）就拒绝" {
  printf '#!/bin/sh\n# VERSION: 2.5.0\nexit 0\n' > /usr/local/bin/vw-fullbackup.sh
  lm "$NEW" --check
  [ "$status" -ne 0 ]
  has "vw-fullbackup 太旧"
}

@test "预检：新机上别的迁移留下的数据拒绝；本次迁移自己演练出来的接受，并带 --force 重跑" {
  mkdir -p /var/lib/ops-scripts; printf 'lm-someone-else\told\tx\n' > /var/lib/ops-scripts/live-migrate.target
  fact dbs=appdb dr_state=real
  lm "$NEW" --check
  [ "$status" -ne 0 ]
  has "不是本次迁移留下的"
  rm -f /var/lib/ops-scripts/live-migrate.target
  printf '%s\n' init=yes running=0 dbs= dr_state= > "$NH/facts"
  OPS_YES=1 lm "$NEW" --rehearse-only
  [ "$status" -eq 0 ]
  fact dbs=appdb dr_state=real                     # 上面这次演练恢复出来的
  OPS_YES=1 lm "$NEW" --rehearse-only
  [ "$status" -eq 0 ]
  has "本次迁移上次恢复出来的"
  grep -q "^$NEW restore - .* --no-cron --no-egress --force$" "$RCALLS"
}

@test "--check：只列计划，两台都不动" {
  lm "$NEW" --check
  [ "$status" -eq 0 ]
  has "预检通过"
  has "迁移计划"
  has "只预检：两台机器都没有改动"
  [ ! -e "$ST" ] && [ ! -s "$RCALLS" ] && [ ! -e /var/lib/ops-scripts/live-migrate.target ]
  crontab -l | diff /tmp/cron.before -
}

@test "不确认就不开始：没有 OPS_YES 也没有终端时，演练前就取消" {
  lm "$NEW" --rehearse-only
  [ "$status" -eq 0 ]
  has "已取消"
  [ ! -s "$RCALLS" ] && [ -z "$(ls /root/live-migrate/pkgs 2>/dev/null)" ]
}

@test "--cutover：没演练过就拒绝，本机不动" {
  OPS_YES=1 lm "$NEW" --cutover
  [ "$status" -ne 0 ]
  has "还没演练过"
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
}

# ── 演练 ────────────────────────────────────────────────────
@test "演练：本机照常服务（不停容器、不动定时任务、不上传）；新机恢复不装定时任务、核对后停下" {
  OPS_YES=1 lm "$NEW" --rehearse-only
  [ "$status" -eq 0 ]
  [ "$(running)" = "running running" ]
  none '^stop' "$(cat /tmp/docker.log)"
  crontab -l | diff /tmp/cron.before -
  [ ! -s /tmp/rclone.log ]
  [ "$(acts)" = "restore check verify standby" ]
  grep -qE "^$NEW restore - /root/live-migrate-in/rehearsal-[0-9]+/srvbak_[0-9_]+\.7z --no-cron --no-egress$" "$RCALLS"
  # 包现做现传：新机上的与本机的逐字节一致，旁挂的 .sha256 也传了
  f=$(ls /root/live-migrate/pkgs/rehearsal-*/srvbak_*.7z)
  g=$(ls /root/live-migrate-in/rehearsal-*/srvbak_*.7z)
  cmp "$f" "$g" && [ -f "$g.sha256" ]
  has "新机上的 sha256 一致"
  # 恢复后新机临时放行本机连 SSH
  grep -q "^allow from 127.0.0.1 to any port 22 proto tcp comment live-migrate $(lm_id)$" /tmp/ufw.log
  has "a.example.com"
  [ "$(phase)" = rehearsed ]
  [ "$(cut -f1 /var/lib/ops-scripts/live-migrate.target)" = "$(lm_id)" ]
}

@test "演练：新机恢复失败就停，本机照样不动" {
  echo 3 > "$NH/rc.restore"
  OPS_YES=1 lm "$NEW" --rehearse-only
  [ "$status" -ne 0 ]
  has "新机恢复失败"
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
  [ "$(phase)" = started ]
}

@test "演练有差异时，自动模式（OPS_YES=1）不往下切换" {
  printf '===== 恢复计划 =====\n  放置         file             /etc/x.conf\n' > "$NH/out.check"
  OPS_YES=1 lm "$NEW"
  has "恢复后仍与包不一致的 1 项"
  has "自动模式（OPS_YES=1）不切换"
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
  [ "$(phase)" = rehearsed ]
}

# ── 切换与回滚 ──────────────────────────────────────────────
@test "切换：先写回滚脚本，暂停备份定时任务（只动备份行）、停容器，再出包，新机 restore --force；DNS 不自动确认" {
  OPS_YES=1 lm "$NEW"
  [ "$status" -eq 0 ]
  [ "$(acts)" = "restore check verify standby restore verify" ]
  grep -qE "^$NEW restore - /root/live-migrate-in/cutover-[0-9]+/srvbak_[0-9_]+\.7z --force$" "$RCALLS"
  # 演练那次恢复时本机照常；切换那次恢复时本机已停写、备份任务已暂停
  grep -qx running "$NH/at-restore.1" && none '#MIGRATE-PAUSED' "$(cat "$NH/at-restore.1")"
  grep -qx exited "$NH/at-restore.2" && grep -q '^#MIGRATE-PAUSED .*vw-fullbackup.sh' "$NH/at-restore.2"
  # 只暂停调用备份脚本的行；日志文件名里带 fullbackup 的别的任务不动
  crontab -l | grep -qx '#MIGRATE-PAUSED 0 \*/6 \* \* \* /usr/bin/flock -n /var/lock/vw-fullbackup-cron.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1'
  crontab -l | grep -q '^#MIGRATE-PAUSED 5 \* \* \* \* .*newapi-fullbackup.sh'
  crontab -l | grep -qx '\*/5 \* \* \* \* /usr/local/bin/newapi-linkcheck.sh --cron >> /var/log/newapi-fullbackup.log 2>&1'
  [ "$(running)" = "exited exited" ]
  [ -x /root/live-migrate/rollback.sh ] && grep -q '^RUN=(.*vaultwarden' /root/live-migrate/rollback.sh
  # 切换后演练的包两边都清掉，最终的包留着
  [ -z "$(ls -d /root/live-migrate/pkgs/rehearsal-* /root/live-migrate-in/rehearsal-* 2>/dev/null)" ]
  ls /root/live-migrate/pkgs/cutover-*/srvbak_*.7z /root/live-migrate-in/cutover-*/srvbak_*.7z >/dev/null
  has "DNS：要在 DNS 服务商那里改的记录"
  has "改好后运行：live-migrate.sh $NEW"
  [ "$(phase)" = cutover-done ]
  [ ! -s /tmp/rclone.log ]
}

@test "回滚：新机停下，本机恢复备份定时任务、启动切换时停掉的容器；不确认不执行" {
  OPS_YES=1 lm "$NEW"
  [ "$(running)" = "exited exited" ]
  lm rollback
  has "已取消"
  [ "$(running)" = "exited exited" ]
  OPS_YES=1 lm rollback
  [ "$status" -eq 0 ]
  has "回滚完成"
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
  [ "$(tail -2 "$RCALLS" | tr '\n' '|')" = "$NEW egress on|$NEW standby|" ]
  [ "$(phase)" = rolled-back ]
  lm status
  has "已回滚"
}

@test "外连限制：演练恢复带 --no-egress，切换那次不带（新机接手要能发邮件）；回滚时新机先加回限制再停容器" {
  OPS_YES=1 lm "$NEW"
  [ "$status" -eq 0 ]
  has "容器不许主动连外网"
  [ "$(grep -c ' restore ' "$RCALLS")" = 2 ]
  grep ' restore ' "$RCALLS" | sed -n 1p | grep -q -- ' --no-cron --no-egress$'
  none '--no-egress' "$(grep ' restore ' "$RCALLS" | sed -n 2p)"
  none "^$NEW egress" "$(cat "$RCALLS")"
  : > "$RCALLS"
  OPS_YES=1 lm rollback
  [ "$status" -eq 0 ]
  [ "$(cat "$RCALLS")" = "$NEW egress on"$'\n'"$NEW standby" ]
}

@test "回滚：新机加不回外连限制时照样停容器、本机照样复原，并说明要补做" {
  OPS_YES=1 lm "$NEW"
  echo 1 > "$NH/rc.egress"
  OPS_YES=1 lm rollback
  [ "$status" -eq 0 ]
  has "新机的容器外连限制没加上"
  has "opsget migrate/restore-from-backup egress on"
  [ "$(tail -1 "$RCALLS")" = "$NEW standby" ]
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
}

@test "切换中断（新机恢复失败）：停下并指向回滚；回滚后本机复原，--cutover 可以接着做" {
  OPS_YES=1 lm "$NEW" --rehearse-only
  echo 1 > "$NH/rc.restore"
  OPS_YES=1 lm "$NEW" --cutover
  [ "$status" -ne 0 ]
  has "live-migrate.sh rollback"
  [ "$(phase)" = cutover-started ]
  [ "$(running)" = "exited exited" ]
  # 接着做：沿用第一次的回滚脚本（里面记着切换前在跑的容器）
  rm -f "$NH/rc.restore"
  OPS_YES=1 lm "$NEW" --cutover
  [ "$status" -eq 0 ]
  has "沿用已有的"
  grep -q '^RUN=(.*vaultwarden' /root/live-migrate/rollback.sh
  OPS_YES=1 lm rollback
  [ "$(running)" = "running running" ]
  crontab -l | diff /tmp/cron.before -
}

# ── 放行名单与 DNS ──────────────────────────────────────────
@test "放行名单：落地机等照本机的规则加上新机；DNS 复核通过后删掉新机上的临时放行和别的机器上的本机；之后拒绝回滚" {
  env_conf NEWAPI_HOST=127.0.0.4 NEWAPI_SSH_PORT=2200
  echo 'root@127.0.0.3:2222' > /root/.vps-hosts.txt
  mkdir -p /etc/ufw
  echo '-A ufw-user-input -p tcp --dport 2222 -s 127.0.0.1 -j ACCEPT' > /etc/ufw/user.rules
  OPS_YES=1 lm "$NEW"
  [ "$status" -eq 0 ]
  # 演练开始时加一次，切换时（旧机还在别的机器的名单里）再核对一次
  [ "$(grep -c "^127.0.0.3 bash -s -- peer-allow $NEW" /tmp/ssh.log)" = 2 ]
  [ "$(grep -c "^127.0.0.4 bash -s -- peer-allow $NEW" /tmp/ssh.log)" = 2 ]
  grep -qx "allow from $NEW to any port 2222 proto tcp comment front host (live-migrate)" /tmp/ufw.log
  has "放行新机 $NEW → SSH 端口 2222"
  # DNS 改好了：公共 DNS 返回新机；这时各处的规则都在
  printf '{"Status":0,"Answer":[{"name":"a.example.com.","type":1,"TTL":300,"data":"%s"}]}\n' "$NEW" > "$MOCK/doh"
  echo "-A ufw-user-input -p tcp --dport 2222 -s $NEW -j ACCEPT" >> /etc/ufw/user.rules
  printf '%s\n' 'Status: active' '' \
    '[ 1] 2222/tcp                   ALLOW IN    127.0.0.1' \
    "[ 2] 22/tcp                     ALLOW IN    127.0.0.1                  # live-migrate $(lm_id)" \
    "[ 3] 2222/tcp                   ALLOW IN    $NEW                  # front host (live-migrate)" > /tmp/ufw.numbered
  : > /tmp/ufw.log
  OPS_YES=1 lm "$NEW" --dns --verify-dns
  [ "$status" -eq 0 ]
  has "新机 ✓"
  has "DNS 已全部切到新机"
  [ "$(phase)" = dns-done ]
  grep -qx -- '--force delete 2' /tmp/ufw.log             # 新机：临时放行本机的那条
  [ "$(grep -cx -- '--force delete 1' /tmp/ufw.log)" = 2 ] # 两台别的机器：本机（旧前置机）那条
  none '--force delete 3' "$(cat /tmp/ufw.log)"
  OPS_YES=1 lm rollback
  [ "$status" -ne 0 ]
  has "DNS 已经切到新机"
}

@test "DNS：公共 DNS 还是旧机就不算完成，留着回滚的余地" {
  OPS_YES=1 lm "$NEW"
  printf '{"Status":0,"Answer":[{"name":"a.example.com.","type":1,"TTL":300,"data":"%s"}]}\n' "$(hostname -I | awk '{ print $1 }')" > "$MOCK/doh"
  OPS_YES=1 lm "$NEW" --dns --verify-dns
  has "还是旧机"
  has "还没切过来"
  [ "$(phase)" = cutover-done ]
}

@test "新机没有 env.conf 和备份密码文件时，演练开始前从本机复制过去" {
  fact env=no pass_sha=
  OPS_YES=1 lm "$NEW" --rehearse-only
  [ "$status" -eq 0 ]
  grep -q "^$NEW umask 077; mkdir -p '/etc/ops-scripts' && cat > '/etc/ops-scripts/env.conf.lm-part'" /tmp/ssh.log
  grep -q "^$NEW umask 077; mkdir -p '/root' && cat > '$PASSF.lm-part'" /tmp/ssh.log
  has "复制了本机的"
  has "备份密码文件复制到新机"
}
