#!/usr/bin/env bats
# tests/backup.bats — 备份包公共函数：GFS 分级保留、rootfs 采集与还原清单、MySQL 账号导出
# 在一次性容器里以 root 运行，会在 /tmp、/etc/systemd/system 下建测试文件。

load fake-pg

setup() {
  # shellcheck disable=SC1091
  . /src/lib/common.sh
  WARN_LOG=/tmp/bk-warn.log; : > "$WARN_LOG"
  log()  { :; }
  warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
  T=/tmp/bk-test; rm -rf "$T"; mkdir -p "$T"
  NOW=$(TZ=UTC date -d '2026-09-28 12:30:00' +%s)
}

# names <前缀> <起点距今小时> <终点距今小时> <步长小时>：生成包名（UTC）
names() {
  local h
  for ((h = $2; h >= $3; h -= $4)); do
    TZ=UTC date -d "@$((NOW - h * 3600))" "+${1}_%Y%m%d_%H%M%S.7z"
  done
}

# 用 python 独立校验分级结果，不复用被测代码的算法
check_tiers() {  # check_tiers <全部名单> <删除名单> <all> <daily> <weekly> <max>
  python3 - "$@" "$NOW" <<'PY'
import sys, datetime as dt
allf, delf, a, d, w, m, now = sys.argv[1:8]
a, d, w, m, now = int(a), int(d), int(w), int(m), int(now)
names = [l.strip() for l in open(allf) if l.strip()]
dels = set(l.strip() for l in open(delf) if l.strip())
def ts(n):
    s = n.split('_', 1)[1][:15]
    return dt.datetime.strptime(s, '%Y%m%d_%H%M%S').replace(tzinfo=dt.timezone.utc).timestamp()
arch = sorted((n for n in names if n.endswith('.7z')), key=ts)
newest = arch[-1]
kept = [n for n in arch if n not in dels]
err = []
def age(n): return (now - ts(n)) / 86400
def bucket(n):
    t = dt.datetime.fromtimestamp(ts(n), dt.timezone.utc)
    x = age(n)
    if x < d: return 'd' + t.strftime('%Y%m%d')
    if x < w: return 'w%d-%02d' % t.isocalendar()[:2]
    return 'm' + t.strftime('%Y%m')
for n in arch:
    x = age(n)
    if n == newest and n in dels: err.append('删了最新的 ' + n)
    if x < a and n in dels: err.append('全留档里删了 ' + n)
    if x >= m and n not in dels and n != newest: err.append('超过上限还留着 ' + n)
seen = {}
for n in kept:
    if age(n) < a or n == newest: continue
    b = bucket(n)
    if b in seen: err.append('同一档位留了两份: %s %s' % (seen[b], n))
    seen[b] = n
# 每个有包的档位都至少留一份，且留的是该档位里最早的
first = {}
for n in arch:
    if age(n) < a or age(n) >= m: continue
    first.setdefault(bucket(n), n)
for b, n in first.items():
    if b not in seen and not any(age(k) < a for k in arch if bucket(k) == b):
        err.append('档位 %s 一份都没留' % b)
    elif b in seen and seen[b] != n:
        err.append('档位 %s 留的不是最早的: %s（应为 %s）' % (b, seen[b], n))
# 旁注跟随它的包
for n in names:
    if n.endswith('.sha256') and (n in dels) != (n[:-7] in dels):
        err.append('旁注没有跟随包: ' + n)
print('\n'.join(err[:20]))
sys.exit(1 if err else 0)
PY
}

@test "GFS：每小时一份、400 天（new-api 档位）逐档只留一份，全留档与最新的不删" {
  names newapi $((400 * 24 + 30)) 0 1 > "$T/all"
  bk_gfs_select "$NOW" 2 30 90 400 < "$T/all" > "$T/del"
  run check_tiers "$T/all" "$T/del" 2 30 90 400
  echo "$output"; [ "$status" -eq 0 ]
  # 大致数量：2 天×24 + 28 天 + 约 9 周 + 约 10 月
  kept=$(( $(wc -l < "$T/all") - $(wc -l < "$T/del") ))
  [ "$kept" -ge 90 ] && [ "$kept" -le 100 ]
}

@test "GFS：每 6 小时一份（vw/xboard 档位），带 .sha256 旁注" {
  { names srvbak $((500 * 24)) 0 6; names srvbak $((500 * 24)) 0 6 | sed 's/$/.sha256/'; } > "$T/all"
  bk_gfs_select "$NOW" 7 30 90 400 < "$T/all" > "$T/del"
  run check_tiers "$T/all" "$T/del" 7 30 90 400
  echo "$output"; [ "$status" -eq 0 ]
}

@test "GFS：清理结果再清理一次不再删任何东西；逐日滚动 60 天，每天清理后分档规则都成立" {
  names xboard $((200 * 24)) 0 6 > "$T/all"
  bk_gfs_select "$NOW" 7 30 90 180 < "$T/all" > "$T/del"
  grep -vxF -f "$T/del" "$T/all" > "$T/kept"
  run bk_gfs_select "$NOW" 7 30 90 180 < "$T/kept"
  [ -z "$output" ]
  # 每天新增 4 份再清理。删的只会是跨档后同档已有更早一份的：全留边界最多 3、
  # 日→周 2（边界当天剩下的半天 + 当天那份）、周→月 1、超上限 1
  for _ in $(seq 60); do
    NOW=$((NOW + 86400))
    for h in 18 12 6 0; do TZ=UTC date -d "@$((NOW - h * 3600))" '+xboard_%Y%m%d_%H%M%S.7z'; done >> "$T/kept"
    bk_gfs_select "$NOW" 7 30 90 180 < "$T/kept" > "$T/del2"
    [ "$(wc -l < "$T/del2")" -le 7 ]
    run check_tiers "$T/kept" "$T/del2" 7 30 90 180
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -vxF -f "$T/del2" "$T/kept" > "$T/k2" || true; mv "$T/k2" "$T/kept"
  done
}

@test "GFS：只剩很旧的包时，最新的一份永远留着" {
  names srvbak $((900 * 24)) $((800 * 24)) 24 > "$T/all"
  bk_gfs_select "$NOW" 7 30 90 400 < "$T/all" > "$T/del"
  [ "$(wc -l < "$T/all")" -eq $(( $(wc -l < "$T/del") + 1 )) ]
  ! grep -qxF "$(tail -1 "$T/all")" "$T/del"
}

@test "GFS：不认识的文件名不动；日期非法时整体放弃、什么都不删" {
  printf '%s\n' notes.txt srvbak_latest.7z srvbak_20200101_000000.7z.part > "$T/all"
  names srvbak $((900 * 24)) $((800 * 24)) 24 >> "$T/all"
  bk_gfs_select "$NOW" 7 30 90 400 < "$T/all" > "$T/del"
  ! grep -qE 'notes|latest|part' "$T/del"
  printf '%s\n' srvbak_20251399_000000.7z >> "$T/all"
  run bk_gfs_select "$NOW" 7 30 90 400 < "$T/all"
  [ "$status" -ne 0 ]; [ -z "$output" ]
}

@test "GFS：档位不合法时拒绝清理" {
  run bk_gfs_ok 0 30 90 400;  [ "$status" -ne 0 ]
  run bk_gfs_ok 7 5 90 400;   [ "$status" -ne 0 ]
  run bk_gfs_ok 7 30 20 400;  [ "$status" -ne 0 ]
  run bk_gfs_ok 7 30 90 abc;  [ "$status" -ne 0 ]
  run bk_gfs_ok 7 30 90 400;  [ "$status" -eq 0 ]
  mkdir "$T/out"; names srvbak 2000 0 6 | while read -r n; do : > "$T/out/$n"; done
  before=$(ls "$T/out" | wc -l)
  bk_prune_local "$T/out" srvbak 7 5 90 400 || true
  [ "$(ls "$T/out" | wc -l)" -eq "$before" ]
  grep -q '不合法' "$WARN_LOG"
}

@test "本地清理：按选择结果删除，旁注一起删，其他文件不动" {
  mkdir "$T/out"
  names srvbak $((60 * 24)) 0 6 | while read -r n; do : > "$T/out/$n"; : > "$T/out/$n.sha256"; done
  : > "$T/out/keepme.txt"
  ls "$T/out" > "$T/all"
  bk_gfs_select "$(date +%s)" 7 30 90 400 < "$T/all" > "$T/expect"
  [ -s "$T/expect" ]
  bk_prune_local "$T/out" srvbak 7 30 90 400
  for n in $(cat "$T/expect"); do [ ! -e "$T/out/$n" ]; done
  [ -e "$T/out/keepme.txt" ]
  [ "$(ls "$T/out" | wc -l)" -eq $(( $(wc -l < "$T/all") - $(wc -l < "$T/expect") )) ]
}

# ── rootfs 与还原清单 ──────────────────────────────────────

@test "bk_dir：权限属主照抄，父目录不变成 700，日志和解密密码不进包" {
  mkdir -p "$T/src/etc/app/sub"
  echo conf > "$T/src/etc/app/a.conf"; chmod 640 "$T/src/etc/app/a.conf"; chown 0:100 "$T/src/etc/app/a.conf"
  echo log  > "$T/src/etc/app/x.log"
  echo pass > "$T/src/etc/app/sub/backup.pass"
  chmod 750 "$T/src/etc/app"; chmod 755 "$T/src" "$T/src/etc"
  BACKUP_PASS_FILE="$T/src/etc/app/sub/backup.pass"
  (umask 077; bk_init "$T/pkg")
  bk_init "$T/pkg"
  (umask 077; bk_dir "$T/src/etc/app")
  R="$T/pkg/rootfs$T/src"
  [ "$(stat -c %a "$R/etc/app/a.conf")" = 640 ]
  [ "$(stat -c %u:%g "$R/etc/app/a.conf")" = 0:100 ]
  [ "$(stat -c %a "$R/etc")" = 755 ]
  [ "$(stat -c %a "$R/etc/app")" = 750 ]
  [ ! -e "$R/etc/app/x.log" ]
  [ ! -e "$R/etc/app/sub/backup.pass" ]
  grep -q "backup.pass" "$T/pkg/system/rootfs-skipped.txt"
  grep -qP "^$T/src/etc/app\t750\troot:root\tdir$" "$T/pkg/restore-manifest.tsv"
}

@test "bk_file：解密密码拒收；sqlite 走在线备份且完整" {
  bk_init "$T/pkg"
  echo secret > "$T/pass"; BACKUP_PASS_FILE="$T/pass"; bk_init "$T/pkg"
  bk_file "$T/pass"
  [ ! -e "$T/pkg/rootfs$T/pass" ]
  ! grep -q "$T/pass" "$T/pkg/restore-manifest.tsv"
  sqlite3 "$T/k.db" 'PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES (1),(2),(3);'
  bk_file "$T/k.db" sqlite
  [ "$(sqlite3 "$T/pkg/rootfs$T/k.db" 'SELECT COUNT(*) FROM t')" = 3 ]
  grep -qP "^$T/k.db\t\d+\troot:root\tsqlite$" "$T/pkg/restore-manifest.tsv"
}

@test "bk_link：已按旧布局收的内容硬链接进 rootfs，不多占空间" {
  bk_init "$T/pkg"
  mkdir -p "$T/pkg/vaultwarden/data" /tmp/bk-live/data
  head -c 100000 /dev/urandom > "$T/pkg/vaultwarden/data/att.bin"
  bk_link /tmp/bk-live/data vaultwarden/data
  [ "$(stat -c %i "$T/pkg/vaultwarden/data/att.bin")" = "$(stat -c %i "$T/pkg/rootfs/tmp/bk-live/data/att.bin")" ]
  grep -qP "^/tmp/bk-live/data\t\d+\t[^\t]+\tdir$" "$T/pkg/restore-manifest.tsv"
  sz=$(tar -C "$T/pkg" -cf - . | wc -c)
  [ "$sz" -lt 150000 ]
  rm -rf /tmp/bk-live
}

@test "/usr/local/bin：与系统命令同名的不收（会遮住真命令），自装脚本照收" {
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/sleep
  printf '#!/bin/sh\necho hi\n' > /usr/local/bin/bk-own-tool
  bk_init "$T/pkg"
  bk_usr_local_bin
  [ ! -e "$T/pkg/rootfs/usr/local/bin/sleep" ]
  grep -qP '^/usr/local/bin/sleep\t与 /(usr/)?bin/sleep 同名' "$T/pkg/system/rootfs-skipped.txt"
  [ -f "$T/pkg/rootfs/usr/local/bin/bk-own-tool" ]
  grep -qP '^/usr/local/bin/bk-own-tool\t\d+\troot:root\tfile$' "$T/pkg/restore-manifest.tsv"
  rm -f /usr/local/bin/sleep /usr/local/bin/bk-own-tool
}

@test "systemd：启用的记 systemd-unit，未启用的记 file，mask 的另记，软链接不收" {
  S=/etc/systemd/system; mkdir -p $S/multi-user.target.wants $S/foo-tunnel.service.d
  printf '[Service]\nExecStart=/bin/true\n' > $S/foo-tunnel.service
  printf '[Service]\nRestart=always\n' > $S/foo-tunnel.service.d/override.conf
  printf '[Service]\nExecStart=/bin/true\n' > $S/bar-idle.service
  ln -sf $S/foo-tunnel.service $S/multi-user.target.wants/foo-tunnel.service
  ln -sf /dev/null $S/baz-masked.service
  ln -sf /lib/systemd/system/cron.service $S/alias.service
  bk_init "$T/pkg"
  bk_systemd_units
  M="$T/pkg/restore-manifest.tsv"
  grep -qP "^$S/foo-tunnel.service\t644\troot:root\tsystemd-unit$" "$M"
  grep -qP "^$S/foo-tunnel.service.d\t\d+\troot:root\tdir$" "$M"
  grep -qP "^$S/bar-idle.service\t644\troot:root\tfile$" "$M"
  ! grep -q "baz-masked\|alias.service" "$M"
  grep -qx baz-masked.service "$T/pkg/system/ref/systemd-masked.txt"
  rm -rf $S/foo-tunnel.service* $S/bar-idle.service $S/baz-masked.service $S/alias.service $S/multi-user.target.wants/foo-tunnel.service
}

@test "MySQL 账号：CREATE USER IF NOT EXISTS + ALTER USER 带哈希，GRANT 以分号结尾，不含系统账号" {
  mkdir -p "$T/bin"
  cat > "$T/bin/mysql" <<'EOF'
#!/bin/bash
q="${*: -1}"
case "$q" in
  *print_identified_with_as_hex*SHOW\ CREATE*) echo "CREATE USER \`app\`@\`172.%\` IDENTIFIED WITH 'caching_sha2_password' AS 0x2441 REQUIRE NONE" ;;
  *@@SESSION.print_identified_with_as_hex*) echo 0 ;;
  "SELECT 1") echo 1 ;;
  *mysql.user*) printf "'app'@'172.%%'\n" ;;
  "SHOW GRANTS FOR 'app'@'172.%'") printf 'GRANT USAGE ON *.* TO `app`@`172.%%`\nGRANT ALL PRIVILEGES ON `app`.* TO `app`@`172.%%`\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/bin/mysql"; echo '[client]' > "$T/my.cnf"
  BK_MYSQL="$T/bin/mysql" MYSQL_DEFAULTS_FILE="$T/my.cnf"
  bk_init "$T/pkg"
  bk_mysql_ready
  bk_mysql_users db/mysql-users.sql
  F="$T/pkg/db/mysql-users.sql"
  cat "$F"
  grep -qxF "CREATE USER IF NOT EXISTS \`app\`@\`172.%\` IDENTIFIED WITH 'caching_sha2_password' AS 0x2441 REQUIRE NONE;" "$F"
  grep -qxF "ALTER USER \`app\`@\`172.%\` IDENTIFIED WITH 'caching_sha2_password' AS 0x2441 REQUIRE NONE;" "$F"
  grep -qxF 'GRANT ALL PRIVILEGES ON `app`.* TO `app`@`172.%`;' "$F"
  [ "$(tail -1 "$F")" = 'FLUSH PRIVILEGES;' ]
  # 只有这四类语句，每条以分号结尾
  ! grep -vE '^(CREATE USER|ALTER USER|GRANT|FLUSH PRIVILEGES).*;$' "$F"
  grep -qP "^db/mysql-users.sql\t-\t-\tmysql-user$" "$T/pkg/restore-manifest.tsv"
}

@test "整套采集在 set -u 下能跑完（xboard-fullbackup 用 set -u，未绑定变量会让备份整个中止）" {
  mkdir -p /opt/bk-u /etc/ops-scripts; echo 'services: {}' > /opt/bk-u/compose.yaml
  mkdir -p "$T/bin"
  printf '#!/bin/bash\ncase "$1 $2" in "ps -a") echo c1 ;; esac\ncase "$*" in *working_dir*) echo /opt/bk-u ;; *config_files*) echo /opt/bk-u/compose.yaml ;; esac\nexit 0\n' > "$T/bin/docker"
  chmod +x "$T/bin/docker"
  run env PATH="$T/bin:$PATH" bash -c '
    set -u
    . /src/lib/common.sh
    log() { :; }; warn() { :; }
    unset BACKUP_PASS_FILE MYSQL_DEFAULTS_FILE PANEL_ROOT WWWROOT
    bk_init '"$T"'/pkg
    bk_opt /opt/bk-u
    bk_system
    bk_compose_projects
    bk_images '"$T"'/pkg/images.tsv
    echo DONE'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *DONE* ]]
  rm -rf /opt/bk-u
}

@test "bk_images：给了容器名只列这些，不存在的记 -；不给就列全部" {
  mkdir -p "$T/bin"
  cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
case "$*" in
  "ps -a --format {{.Names}}") printf 'a\nb\nc\n' ;;
  "inspect -f {{.Config.Image}} a") echo img-a ;;
  "inspect -f {{.Image}} a") echo id-a ;;
  "inspect -f {{.Config.Image}} b") echo img-b ;;
  "inspect -f {{.Image}} b") echo id-b ;;
  "image inspect -f "*" id-a") echo repo/a@sha256:aa ;;
  "image inspect "*) echo ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/bin/docker"; PATH="$T/bin:$PATH"
  bk_images "$T/i.tsv" a gone
  [ "$(grep -vc '^#' "$T/i.tsv")" = 2 ]
  grep -qP '^a\timg-a\trepo/a@sha256:aa$' "$T/i.tsv"
  grep -qP '^gone\t-\t-$' "$T/i.tsv"
  grep -q 'gone' "$WARN_LOG"
  bk_images "$T/all.tsv"
  [ "$(grep -vc '^#' "$T/all.tsv")" = 3 ]
  grep -qP '^b\timg-b\t-$' "$T/all.tsv"
}

@test "vps_host_port：主机整段匹配，注释与相似 IP 不算" {
  printf '%s\n' 'root@10.0.0.10:2200' '#root@10.0.0.1:9' 'x root@10.0.0.1:2222 y' 'admin@host.example:22' 'root@10.0.0.3' > "$T/.vps-hosts.txt"
  HOME=$T
  [ "$(vps_host_port 10.0.0.1)" = 2222 ]
  [ "$(vps_host_port host.example)" = 22 ]
  [ -z "$(vps_host_port 10.0.0.2)" ]
  [ -z "$(vps_host_port 10.0.0.3)" ]
  [ -z "$(vps_host_port 10.0.0)" ]
}

@test "没配 MYSQL_DEFAULTS_FILE：告警并跳过，不中断" {
  unset MYSQL_DEFAULTS_FILE
  bk_init "$T/pkg"
  run bk_mysql_ready
  [ "$status" -ne 0 ]
  grep -q 'MYSQL_DEFAULTS_FILE' "$WARN_LOG"
}

@test "连不上 MySQL：隔一会儿重试，恢复了照常；一直连不上就告警，带客户端路径和报错原文" {
  LOG_FILE=$T/log; log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
  sleep() { echo "sleep $*" >> "$T/sleep"; }
  # 前 $T/fails 次报 MariaDB 客户端找错 socket 的错
  mkdir -p "$T/bin"
  cat > "$T/bin/mysql" <<EOF
#!/bin/bash
n=\$(cat "$T/fails" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$T/fails"
  echo "ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)" >&2; exit 1; fi
echo 1
EOF
  chmod +x "$T/bin/mysql"; echo '[client]' > "$T/my.cnf"
  BK_MYSQL="$T/bin/mysql" MYSQL_DEFAULTS_FILE="$T/my.cnf" BK_MYSQL_RETRY_WAIT=7
  echo 2 > "$T/fails"
  bk_mysql_ready
  grep -q "连不上 MySQL（第 1/3 次）：ERROR 2002 .*mysqld.sock' (2)，7 秒后重试" "$LOG_FILE"
  grep -q '第 2/3 次' "$LOG_FILE"
  [ "$(grep -c 'sleep 7' "$T/sleep")" -eq 2 ]
  [ ! -s "$WARN_LOG" ]
  echo 9 > "$T/fails"; : > "$T/sleep"
  run bk_mysql_ready
  [ "$status" -ne 0 ]
  grep -q "连不上 MySQL（试了 3 次，客户端 $T/bin/mysql）：ERROR 2002" "$WARN_LOG"
  [ "$(grep -c . "$T/sleep")" -eq 2 ]                        # 最后一次失败后不再等
}

@test "bk_mysql_bin：有宝塔自带的客户端就用它，不用 PATH 里的；没有才用 PATH 里的" {
  mkdir -p "$T/bt" "$T/path"
  printf '#!/bin/sh\n' > "$T/bt/mysql"; printf '#!/bin/sh\n' > "$T/path/mysql"; printf '#!/bin/sh\n' > "$T/path/mysqldump"
  chmod +x "$T/bt/mysql" "$T/path/mysql" "$T/path/mysqldump"
  PATH="$T/path:$PATH" BK_MYSQL_BIN_DIR="$T/bt"
  [ "$(bk_mysql_bin mysql)" = "$T/bt/mysql" ]
  [ "$(bk_mysql_bin mysqldump)" = "$T/path/mysqldump" ]
}

@test "SSH 两步验证：/etc/pam.d/sshd 与 /root/.google_authenticator 进包，权限照原样" {
  mkdir -p /etc/pam.d
  printf 'auth required pam_google_authenticator.so\n' > /etc/pam.d/sshd
  printf 'SECRET\n12345678\n' > /root/.google_authenticator; chmod 400 /root/.google_authenticator
  bk_init "$T/pkg"
  run bk_system            # 容器里没有 ip 命令，bk_system_ref 的参考信息那一步会失败，不影响收包
  grep -q pam_google_authenticator "$T/pkg/rootfs/etc/pam.d/sshd"
  [ "$(stat -c %a "$T/pkg/rootfs/root/.google_authenticator")" = 400 ]
  grep -qP '^/root/\.google_authenticator\t400\troot:root\tfile$' "$T/pkg/restore-manifest.tsv"
  grep -qP '^/etc/pam\.d/sshd\t644\troot:root\tfile$' "$T/pkg/restore-manifest.tsv"
  rm -f /root/.google_authenticator /etc/pam.d/sshd
}

@test "is_yes：去首尾空白（含回车、全角空格）、处理退格、全角转半角、不分大小写；空、y、yess 都不算" {
  local a
  for a in yes " yes " YES "Yes"$'\r' "　yes　" "ｙｅｓ" "ＹＥＳ" "yesx"$'\x7f' $'\t'yes; do
    is_yes "$a" || { echo "应当算 yes: [$a]"; return 1; }
  done
  for a in "" y n no yess "y es" "yes please"; do
    if is_yes "$a"; then echo "不该算 yes: [$a]"; return 1; fi
  done
}

@test "finish：收尾时把告警原文再列一遍（滚出屏幕也查得到）；只计数没留原文的另起一行说明" {
  run bash -c '. /src/lib/common.sh; warn "MySQL 不可用"; ok 中间; warn "拒绝删除 /opt"; finish'
  [ "$status" -eq 1 ]
  [[ "$output" == *"完成（2 条告警）"* ]]
  local tail_; tail_=${output#*完成（2 条告警）}
  [[ "$tail_" == *"  - MySQL 不可用"* ]]
  [[ "$tail_" == *"  - 拒绝删除 /opt"* ]]
  [[ "$tail_" != *"另有"* ]]
  run bash -c '. /src/lib/common.sh; warn 甲; OPS_WARNINGS=$((OPS_WARNINGS+1)); finish'
  [ "$status" -eq 1 ]
  [[ "${output#*完成（2 条告警）}" == *"  - 甲"*"另有 1 条只计了数"* ]]
  run bash -c '. /src/lib/common.sh; ok 好; finish'
  [ "$status" -eq 0 ]
  [[ "$output" == *"完成（0 告警）" ]]
}

@test "init/ 各脚本自带的 is_yes 与 lib/common.sh 的一模一样（它们不依赖公共库，只能各放一份）" {
  fn() { sed -n '/^is_yes() {/,/^}/p' "$1"; }
  [ -n "$(fn /src/lib/common.sh)" ]
  for f in init/00-precheck.sh init/run.sh init/03-ssh-firewall.sh; do
    diff <(fn /src/lib/common.sh) <(fn "/src/$f") || { echo "$f 的 is_yes 与公共库不一致"; return 1; }
  done
}

@test "面板项目类站点：<上级>/*_project 小的整目录进包（反向代理项目的记录），超过 5MB 的记进 rootfs-skipped" {
  S="$T/server"; mkdir -p "$S/proxy_project/sites/a.example.com" "$S/python_project/venv" "$S/panel"
  echo '{"proxy_pass":"http://127.0.0.1:10086"}' > "$S/proxy_project/sites/a.example.com/a.example.com.json"
  head -c 6000000 /dev/urandom > "$S/python_project/venv/big"
  bk_init "$T/pkg"
  bk_panel_projects "$S"
  [ -f "$T/pkg/rootfs$S/proxy_project/sites/a.example.com/a.example.com.json" ]
  [ ! -e "$T/pkg/rootfs$S/python_project" ]
  grep -q "^$S/python_project"$'\t'"超过 5MB" "$T/pkg/system/rootfs-skipped.txt"
  grep -qP "^\Q$S/proxy_project\E\t\d+\t\S+\tdir$" "$T/pkg/restore-manifest.tsv"
}

@test "面板 data：监控历史只留表结构，漏洞库、国家库、入侵检测日志不收，站点记录与入侵检测配置照收" {
  P="$T/panel"; mkdir -p "$P/data/db" "$P/data/warning" "$P/data/firewall" "$P/data/hids_data/log/high"
  head -c 4096 /dev/zero > "$P/data/hids_data/log/2026-10-09.json"
  head -c 4096 /dev/zero > "$P/data/hids_data/log/high/high_log.json"
  echo '{"open":true}' > "$P/data/hids_data/config.json"
  sqlite3 "$P/data/system.db" "CREATE TABLE cpuio(id INTEGER, pro REAL); INSERT INTO cpuio VALUES (1, 0.5), (2, 0.7);"
  chmod 600 "$P/data/system.db"
  sqlite3 "$P/data/db/site.db" "CREATE TABLE sites(name TEXT); INSERT INTO sites VALUES ('a.example.com');"
  head -c 4096 /dev/zero > "$P/data/warning/vul_debian12.json"
  head -c 4096 /dev/zero > "$P/data/firewall/GeoLite2-Country.json"
  echo keep > "$P/data/firewall/rules.json"
  bk_init "$T/pkg"
  bk_panel_data "$P/data"
  R="$T/pkg/rootfs$P/data"
  [ "$(sqlite3 "$R/system.db" 'SELECT COUNT(*) FROM cpuio')" = 0 ]          # 表在，数据不在
  [ "$(stat -c %a "$R/system.db")" = 600 ]
  [ "$(sqlite3 "$R/db/site.db" 'SELECT name FROM sites')" = a.example.com ]
  [ ! -e "$R/warning" ]
  [ ! -e "$R/firewall/GeoLite2-Country.json" ]
  [ -f "$R/firewall/rules.json" ]
  grep -q "system.db"$'\t'"面板监控历史，只收表结构" "$T/pkg/system/rootfs-skipped.txt"
  grep -q "/warning"$'\t' "$T/pkg/system/rootfs-skipped.txt"
  [ ! -e "$R/hids_data/log" ]
  [ -f "$R/hids_data/config.json" ]
  grep -q "^$P/data/hids_data/log"$'\t'"宝塔入侵检测（HIDS）事件日志" "$T/pkg/system/rootfs-skipped.txt"
  grep -qP "^\Q$P/data\E\t\d+\t\S+\tdir$" "$T/pkg/restore-manifest.tsv"
}

# ── 历史数据不进包：表结构留、数据不留 ──────────────────────
none() {  # none <正则> <文本>：文本里不能有匹配的行（bats 里写在中间的 `! 命令` 不会让用例失败）
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2
  return 1
}

# 假 mysql：列库、列表；假 mysqldump：记下参数，按参数输出 CREATE TABLE（--no-data 时只有结构）
fake_mysql_hist() {
  cat > "$T/mysql" <<'SH'
#!/bin/bash
q="${*: -1}"
case "$q" in
  *SCHEMATA*) printf 'vaultwarden\tutf8mb4\tutf8mb4_general_ci\nxboard\tutf8mb4\tutf8mb4_unicode_ci\nshop\tutf8mb4\tutf8mb4_general_ci\n' ;;
  *"TABLE_SCHEMA='xboard'"*) printf '%s\n' v2_user v2_order v2_commission_log v2_log v2_stat_user v2_server_machine_load_history failed_jobs migrations ;;
  *"TABLE_SCHEMA='vaultwarden'"*) printf '%s\n' users ciphers event ;;
  *"TABLE_SCHEMA='shop'"*) printf '%s\n' orders event ;;
esac
SH
  cat > "$T/mysqldump" <<'SH'
#!/bin/bash
echo "$*" >> /tmp/bk-test/dump.log
db=""; nodata=0; tabs=()
for a; do case "$a" in --no-data) nodata=1 ;; -*) ;; *) if [ -z "$db" ]; then db=$a; else tabs+=("$a"); fi ;; esac; done
for t in "${tabs[@]}"; do printf 'CREATE TABLE `%s` (id int);\n' "$t"; done
[ "${#tabs[@]}" -gt 0 ] || printf 'CREATE TABLE `%s_main` (id int);\nINSERT INTO `%s_main` VALUES (1);\n' "$db" "$db"
echo '-- Dump completed'
SH
  chmod 755 "$T/mysql" "$T/mysqldump"
  BK_MYSQL="$T/mysql" BK_MYSQLDUMP="$T/mysqldump"
  MYSQL_DEFAULTS_FILE="$T/my.cnf"; : > "$MYSQL_DEFAULTS_FILE"
}

@test "历史表：只导结构不导数据（Xboard 日志与统计、vaultwarden 的 event），订单与佣金照导；别的库同名表不受影响；记进 rootfs-skipped" {
  fake_mysql_hist
  XBOARD_DB_NAME=xboard
  bk_init "$T/pkg"
  bk_mysql_dbs
  d="$T/dump.log"
  # 每个库一次完整导出（排除历史表的数据）
  grep -E '(^| )xboard$' "$d" | grep -q -- '--ignore-table=xboard.v2_log'
  grep -E '(^| )xboard$' "$d" | grep -q -- '--ignore-table=xboard.v2_stat_user'
  grep -E '(^| )xboard$' "$d" | grep -q -- '--ignore-table=xboard.v2_server_machine_load_history'
  grep -E '(^| )xboard$' "$d" | grep -q -- '--ignore-table=xboard.failed_jobs'
  none 'ignore-table=xboard.v2_(order|user|commission_log)|ignore-table=xboard.migrations' "$(cat "$d")"
  # 不存在的历史表（v2_mail_log 等）不报错、不出现
  none 'v2_mail_log' "$(cat "$d")"
  # 再补一次只有结构的导出
  grep -- '--no-data' "$d" | grep -q ' xboard v2_log v2_stat_user v2_server_machine_load_history failed_jobs$'
  grep -E '(^| )vaultwarden$' "$d" | grep -q -- '--ignore-table=vaultwarden.event'
  grep -- '--no-data' "$d" | grep -q ' vaultwarden event$'
  # 别的库里叫 event 的表是业务数据，照导
  none 'shop\.event|--no-data.* shop ' "$(cat "$d")"
  zcat "$T/pkg/db/xboard.sql.gz" | grep -q 'CREATE TABLE `v2_log`'
  zcat "$T/pkg/db/xboard.sql.gz" | grep -q 'INSERT INTO `xboard_main`'
  grep -q "^mysql:xboard.v2_log"$'\t'"历史数据" "$T/pkg/system/rootfs-skipped.txt"
  grep -q "^mysql:vaultwarden.event"$'\t' "$T/pkg/system/rootfs-skipped.txt"
}

@test "历史表：BACKUP_HISTORY_TABLES 可以改写默认清单；写成空就全部照导" {
  fake_mysql_hist
  XBOARD_DB_NAME=xboard BACKUP_HISTORY_TABLES="xboard.v2_log shop.event"
  bk_init "$T/pkg"
  bk_mysql_dbs
  grep -E '(^| )shop$' "$T/dump.log" | grep -q -- '--ignore-table=shop.event'
  none 'ignore-table=xboard.v2_stat_user' "$(cat "$T/dump.log")"
  : > "$T/dump.log"; BACKUP_HISTORY_TABLES=""
  bk_init "$T/pkg2"
  bk_mysql_dbs
  none 'ignore-table|--no-data' "$(cat "$T/dump.log")"
}

@test "SQLite 历史表：副本上清空数据、表结构与其他表照留；不存在的表跳过" {
  sqlite3 "$T/k.db" "CREATE TABLE clients(id); INSERT INTO clients VALUES (1),(2);
                     CREATE TABLE logs(id, msg); INSERT INTO logs VALUES (1,'x'),(2,'y');
                     CREATE TABLE task_results(id); INSERT INTO task_results VALUES (1);"
  bk_init "$T/pkg"
  bk_sqlite_strip "$T/k.db" komari.db logs task_results no_such_table
  [ "$(sqlite3 "$T/k.db" 'SELECT count(*) FROM clients')" = 2 ]
  [ "$(sqlite3 "$T/k.db" 'SELECT count(*) FROM logs')" = 0 ]
  [ "$(sqlite3 "$T/k.db" 'SELECT count(*) FROM task_results')" = 0 ]
  [ "$(sqlite3 "$T/k.db" "PRAGMA integrity_check")" = ok ]
  grep -q "^sqlite:komari.db.logs"$'\t'"历史数据" "$T/pkg/system/rootfs-skipped.txt"
  none 'no_such_table' "$(cat "$T/pkg/system/rootfs-skipped.txt")"
}

# ── 2026-10 起的包：名字、目录、档位、上传与清理 ─────────────
fake_rclone_dirs() {  # rclone：<远端>:<目录> 映射到 $T/cloud/<远端>/<目录>；$T/fail-<远端> 存在时上传失败
  cat > "$T/rclone" <<'SH'
#!/bin/bash
C=/tmp/bk-test/cloud
loc() { local r=${1%%:*} p=${1#*:}; p=${p#/}; printf '%s/%s/%s' "$C" "$r" "${p%/}"; }
cmd=$1; shift
case "$cmd" in
  copy) [ -e "/tmp/bk-test/fail-${2%%:*}" ] && exit 1; d=$(loc "$2"); mkdir -p "$d"; cp "$1" "$d/" ;;
  check) src=$1 dst=$(loc "$2"); shift 2; inc=()
         while [ $# -gt 0 ]; do [ "$1" = --include ] && { inc+=("$2"); shift; }; shift; done
         for f in "${inc[@]}"; do cmp -s "$src/$f" "$dst/$f" || exit 1; done ;;
  lsf) d=$(loc "$1"); shift; pat='*'; while [ $# -gt 0 ]; do [ "$1" = --include ] && { pat=$2; shift; }; shift; done
       for f in "$d"/$pat; do [ -f "$f" ] && echo "${f##*/}"; done ;;
  deletefile) rm -f "$(loc "$1")" ;;
esac
SH
  chmod 755 "$T/rclone"; PATH="$T:$PATH"
}

@test "包名与目录：时间戳一律 UTC（系统时区是别的也一样）；本机 <BACKUP_LOCAL_ROOT>/<包名>，网盘 <BACKUP_CLOUD_ROOT>/<包名>" {
  [ "$(TZ=Asia/Shanghai bash -c '. /src/lib/common.sh; bk_stamp')" = "$(date -u +%Y%m%d_%H%M%S)" ] \
    || [ "$(TZ=Asia/Shanghai bash -c '. /src/lib/common.sh; bk_stamp')" = "$(date -u +%Y%m%d_%H%M%S)" ]   # 跨秒重试一次
  [ "$(bk_local_dir vault)" = /box/backup/vault ] && [ "$(bk_cloud_dir hk-host)" = Backups/hk-host ]
  BACKUP_LOCAL_ROOT=/data/bk BACKUP_CLOUD_ROOT=Bk
  [ "$(bk_local_dir newapi)" = /data/bk/newapi ] && [ "$(bk_cloud_dir litellm)" = Bk/litellm ]
}

@test "档位：vault / newapi 全留 3 天，hk-host 每天一份起，litellm 每周一份起；<包名>_KEEP_TIERS 可改" {
  [ "$(bk_tiers vault)" = "3 30 90" ] && [ "$(bk_tiers newapi)" = "3 30 90" ]
  [ "$(bk_tiers hk-host)" = "1 30 90" ] && [ "$(bk_tiers litellm)" = "1 1 90" ]
  HK_HOST_KEEP_TIERS="2 60 120"
  [ "$(bk_tiers hk-host)" = "2 60 120" ]
  # 每天一次的 hk-host：30 天内每天一份；每周一次的 litellm：90 天内每周一份（按 ISO 周、UTC）
  local n del
  n=$(for d in $(seq 1 40); do TZ=UTC date -d "@$((NOW - d * 86400 - 3600))" '+hk-host_%Y%m%d_%H%M%S.7z'; done)
  del=$(bk_gfs_select "$NOW" 1 30 90 180 <<<"$n")
  [ "$(grep -c . <<<"$del")" -ge 5 ] && [ "$(grep -c . <<<"$del")" -le 9 ]   # 30 天后每周一份
  n=$(for w in $(seq 1 20); do TZ=UTC date -d "@$((NOW - w * 7 * 86400))" '+litellm_%Y%m%d_%H%M%S.7z'; done)
  del=$(bk_gfs_select "$NOW" 1 1 90 400 <<<"$n")
  [ "$(grep -c . <<<"$del")" -ge 3 ] && [ "$(grep -c . <<<"$del")" -le 6 ]   # 90 天后每月一份
}

@test "上传：包和 .sha256 都传到每个网盘并校验；有网盘失败就返回失败个数" {
  fake_rclone_dirs
  RCLONE_REMOTES="onedrive gdrive" BK_UPLOAD_SETTLE=0
  mkdir -p "$T/out"; echo pkg > "$T/out/vault_20261010_011500.7z"
  (cd "$T/out" && sha256sum vault_20261010_011500.7z > vault_20261010_011500.7z.sha256)
  bk_upload "$T/out/vault_20261010_011500.7z" Backups/vault
  for r in onedrive gdrive; do
    cmp "$T/out/vault_20261010_011500.7z" "$T/cloud/$r/Backups/vault/vault_20261010_011500.7z"
    [ -f "$T/cloud/$r/Backups/vault/vault_20261010_011500.7z.sha256" ]
  done
  touch "$T/fail-gdrive"
  run bk_upload "$T/out/vault_20261010_011500.7z" Backups/vault
  [ "$status" -eq 1 ]
  grep -q 'gdrive:Backups/vault 上传失败' "$WARN_LOG"
}

@test "清理：bk_prune_all 按包的档位清本机与每个网盘，本机上限 180 天、网盘 400 天" {
  fake_rclone_dirs
  RCLONE_REMOTES="onedrive" BACKUP_LOCAL_ROOT="$T/local"
  local d n
  NOW=$(date +%s)   # 清理按真实的当前时间算
  mkdir -p "$T/local/hk-host" "$T/cloud/onedrive/Backups/hk-host"
  for d in $(seq 1 300); do
    n=$(TZ=UTC date -d "@$((NOW - d * 86400))" '+hk-host_%Y%m%d_200000.7z')
    : > "$T/local/hk-host/$n"; : > "$T/cloud/onedrive/Backups/hk-host/$n"
  done
  bk_prune_all hk-host
  # 本机：180 天以前一个不留；网盘：300 天的还在（每月一份）
  [ -z "$(ls "$T/local/hk-host" | awk -v c="$(TZ=UTC date -d "@$(( $(date +%s) - 181 * 86400 ))" +%Y%m%d)" -F_ '$2 < c')" ]
  [ -n "$(ls "$T/cloud/onedrive/Backups/hk-host" | awk -v c="$(TZ=UTC date -d "@$(( $(date +%s) - 181 * 86400 ))" +%Y%m%d)" -F_ '$2 < c')" ]
  # 30 天内每天一份全在
  [ "$(ls "$T/local/hk-host" | awk -v c="$(TZ=UTC date -d "@$(( $(date +%s) - 29 * 86400 ))" +%Y%m%d)" -F_ '$2 >= c' | wc -l)" -ge 28 ]
}

# ── PostgreSQL（宝塔）────────────────────────────────────────
pg_setup() {  # 假 PostgreSQL：openwebui 带 pgvector 两张表，lobehub 空库，postgres 库不导
  fake_pg "$T/pgbin" "$T/pgst"
  PG_BIN_DIR="$T/pgbin" PG_DATA_DIR="$T/pgdata" BK_PG_RETRY_WAIT=0
  printf '%s\t%s\tUTF8\tC.UTF-8\tC.UTF-8\n' openwebui openwebui lobehub lobehub postgres postgres > "$T/pgst/databases.tsv"
  printf '%s\n' 'SET default_transaction_read_only = off;' 'CREATE ROLE lobehub;' \
    "ALTER ROLE lobehub WITH LOGIN PASSWORD 'SCRAM-SHA-256\$4096:lb';" 'CREATE ROLE openwebui;' \
    "ALTER ROLE openwebui WITH LOGIN PASSWORD 'SCRAM-SHA-256\$4096:ow';" 'CREATE ROLE postgres;' \
    'ALTER ROLE postgres WITH SUPERUSER;' > "$T/pgst/globals.sql"
  pg_dump_body > "$T/pgst/src/openwebui"
  mkdir -p "$T/pgdata"
  for f in pg_hba.conf postgresql.auto.conf postgresql.conf; do echo "# $f" > "$T/pgdata/$f"; done
  chmod 600 "$T/pgdata"/*
}

@test "PostgreSQL：角色与密码哈希、每个库 pg_dump -Fc（postgres 库不导）、配置记 pg-conf，postgresql.conf 只作参考" {
  LOG_FILE=$T/log; log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
  pg_setup
  bk_init "$T/pkg"
  bk_pg
  cat "$LOG_FILE"
  [ ! -s "$WARN_LOG" ]
  grep -q "ALTER ROLE openwebui WITH LOGIN PASSWORD 'SCRAM-SHA-256" "$T/pkg/db/pg-globals.sql"
  [ "$(head -c 5 "$T/pkg/db/pg/openwebui.dump")" = PGDMP ]
  [ -f "$T/pkg/db/pg/lobehub.dump" ]
  [ ! -e "$T/pkg/db/pg/postgres.dump" ]
  grep -qP '^db/pg-globals\.sql\t-\t-\tpg-globals$' "$T/pkg/restore-manifest.tsv"
  grep -qP '^db/pg/openwebui\.dump\t-\t-\tpg-db$' "$T/pkg/restore-manifest.tsv"
  grep -qP "^$T/pgdata/pg_hba\.conf\t600\t[^\t]+\tpg-conf$" "$T/pkg/restore-manifest.tsv"
  grep -qP "^$T/pgdata/postgresql\.auto\.conf\t600\t[^\t]+\tpg-conf$" "$T/pkg/restore-manifest.tsv"
  [ -z "$(grep -F 'postgresql.conf' "$T/pkg/restore-manifest.tsv")" ]
  [ -f "$T/pkg/system/ref/pgsql/postgresql.conf" ]
  [ "$(cat "$T/pkg/system/ref/pgsql/server_version")" = 17.11 ]
  grep -q '角色 3 个' "$LOG_FILE"
  grep -q 'PostgreSQL 库 openwebui（属主 openwebui，.*2 张表，扩展 vector）' "$LOG_FILE"
  grep -q 'PostgreSQL 库 lobehub（属主 lobehub，.*0 张表）' "$LOG_FILE"
  # 以超级用户经 socket 连，导出用自定义格式
  grep -q -- "pg_dump -h /tmp -p 5432 -U postgres -Fc -d openwebui" "$T/pgst/log"
  grep -q -- "pg_dumpall -h /tmp -p 5432 -U postgres --globals-only" "$T/pgst/log"
}

@test "PostgreSQL：没配 PG_BIN_DIR 就跳过；连不上隔一会儿重试，一直连不上就告警带报错原文；一个库导不出告警、其余照导" {
  LOG_FILE=$T/log; log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
  sleep() { echo "sleep $*" >> "$T/sleep"; }
  bk_init "$T/pkg"
  unset PG_BIN_DIR
  bk_pg
  grep -q '没配 PG_BIN_DIR，跳过 PostgreSQL' "$LOG_FILE"
  [ ! -s "$WARN_LOG" ]
  [ ! -e "$T/pkg/db/pg" ]
  pg_setup
  echo 1 > "$T/pgst/down"                        # 第一次连不上，重试成功
  bk_pg
  grep -q '连不上 PostgreSQL（第 1/3 次）：psql: error: connection to server on socket' "$LOG_FILE"
  [ ! -s "$WARN_LOG" ]
  [ -f "$T/pkg/db/pg/openwebui.dump" ]
  : > "$T/pgst/down"                              # 一直连不上
  run bk_pg
  [ "$status" -ne 0 ]
  grep -q 'PostgreSQL（/tmp:5432，用户 postgres）连不上（试了 3 次）：psql: error: connection' "$WARN_LOG"
  rm -f "$T/pgst/down"; : > "$WARN_LOG"; rm -rf "$T/pkg"; bk_init "$T/pkg"
  touch "$T/pgst/dump-fail-openwebui"
  bk_pg
  grep -q 'PostgreSQL 库 openwebui 导出失败' "$WARN_LOG"
  [ ! -e "$T/pkg/db/pg/openwebui.dump" ]
  [ -f "$T/pkg/db/pg/lobehub.dump" ]
  [ -z "$(grep -F 'openwebui.dump' "$T/pkg/restore-manifest.tsv")" ]
}

@test "PG_OS_USER：切到这个系统用户执行（先 cd /），输出仍由 root 写进包" {
  pg_setup
  id postgres >/dev/null 2>&1 || useradd -r -M -d /nonexistent postgres
  chmod 755 "$T" "$T/pgbin"; touch "$T/pgst/log"; chmod -R a+rwX "$T/pgst"   # 假实现以 postgres 身份写状态
  PG_OS_USER=postgres
  bk_init "$T/pkg"
  bk_pg
  [ ! -s "$WARN_LOG" ]
  [ "$(stat -c %U "$T/pkg/db/pg/openwebui.dump")" = root ]
  [ "$(head -c 5 "$T/pkg/db/pg/openwebui.dump")" = PGDMP ]
}

@test "compose 的 env_file：三种写法都认，相对路径按项目目录算；bk_compose_projects 把它们收进包" {
  mkdir -p "$T/app"
  cat > "$T/app/compose.yaml" <<'YML'
services:
  web:
    image: x
    env_file: db.env
  api:
    image: y
    env_file: [ ./a.env, "/etc/shared.env" ]   # 注释
  worker:
    env_file:
      - ./redis.env
      - path: ./opt.env
        required: false
    ports:
      - "3080:8080"
YML
  run bk_compose_env_files "$T/app" "$T/app/compose.yaml"
  [ "$output" = "$T/app/db.env
$T/app/a.env
/etc/shared.env
$T/app/redis.env
$T/app/opt.env" ]
  # 收进包：compose 文件、.env、env_file 引用的（不存在的跳过）
  for f in .env db.env redis.env; do echo "K=$f" > "$T/app/$f"; done; chmod 600 "$T/app/db.env"
  mkdir -p "$T/bin"
  printf '#!/bin/bash\ncase "$1 $2" in "ps -a") echo app-web-1 ;; esac\ncase "$*" in *working_dir*) echo %s ;; *config_files*) echo %s/compose.yaml ;; esac\nexit 0\n' "$T/app" "$T/app" > "$T/bin/docker"
  chmod +x "$T/bin/docker"
  PATH="$T/bin:$PATH"
  bk_init "$T/pkg"
  bk_compose_projects
  for f in compose.yaml .env db.env redis.env; do [ -f "$T/pkg/rootfs$T/app/$f" ]; done
  grep -qP "^$T/app/db\.env\t600\t" "$T/pkg/restore-manifest.tsv"
  grep -q "compose 项目 $T/app（容器 app-web-1）的数据没有备份" "$WARN_LOG"   # 只收了配置，数据目录没收照样告警
}

@test "EXTRA_SNAPSHOT_EXCLUDES：EXTRA_SNAPSHOT_PATHS 里的目录排除缓存与旧副本（可带通配），记进未进包清单" {
  mkdir -p /opt/bk-ex/data/cache /opt/bk-ex/data/uploads /opt/bk-ex/data.sqlite-20261017T165832Z
  echo big > /opt/bk-ex/data/cache/model.bin; echo f > /opt/bk-ex/data/uploads/a.pdf
  echo old > /opt/bk-ex/data.sqlite-20261017T165832Z/webui.db; echo 'K=1' > /opt/bk-ex/db.env
  EXTRA_SNAPSHOT_PATHS="/opt/bk-ex/" EXTRA_SNAPSHOT_EXCLUDES="/opt/bk-ex/data/cache /opt/bk-ex/data.sqlite-* /other/x"
  bk_init "$T/pkg"
  run bk_system
  [ -f "$T/pkg/rootfs/opt/bk-ex/data/uploads/a.pdf" ]
  [ -f "$T/pkg/rootfs/opt/bk-ex/db.env" ]
  [ ! -e "$T/pkg/rootfs/opt/bk-ex/data/cache" ]
  [ ! -e "$T/pkg/rootfs/opt/bk-ex/data.sqlite-20261017T165832Z" ]
  grep -qP '^/opt/bk-ex\t755\troot:root\tdir$' "$T/pkg/restore-manifest.tsv"
  grep -q '/opt/bk-ex/data/cache.*EXTRA_SNAPSHOT_EXCLUDES' "$T/pkg/system/rootfs-skipped.txt"
  [ -z "$(grep -F '/other/x' "$T/pkg/system/rootfs-skipped.txt")" ]
  rm -rf /opt/bk-ex
}

@test "logind 的 drop-in（RemoveIPC=no）进包" {
  mkdir -p /etc/systemd/logind.conf.d
  printf '[Login]\nRemoveIPC=no\n' > /etc/systemd/logind.conf.d/10-postgres-removeipc.conf
  bk_init "$T/pkg"
  run bk_system
  grep -q 'RemoveIPC=no' "$T/pkg/rootfs/etc/systemd/logind.conf.d/10-postgres-removeipc.conf"
  rm -rf /etc/systemd/logind.conf.d
}
