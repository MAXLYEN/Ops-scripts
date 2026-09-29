#!/usr/bin/env bats
# tests/backup.bats — 备份包公共函数：GFS 分级保留、rootfs 采集与还原清单、MySQL 账号导出
# 在一次性容器里以 root 运行，会在 /tmp、/etc/systemd/system 下建测试文件。

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

@test "面板 data：监控历史只留表结构，漏洞库与国家库不收，站点记录照收" {
  P="$T/panel"; mkdir -p "$P/data/db" "$P/data/warning" "$P/data/firewall"
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
  grep -qP "^\Q$P/data\E\t\d+\t\S+\tdir$" "$T/pkg/restore-manifest.tsv"
}
