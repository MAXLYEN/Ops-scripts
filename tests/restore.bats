#!/usr/bin/env bats
# tests/restore.bats — 真跑 migrate/restore-from-backup 与 ops/install-backup-cron（不是桩）。
# 包按 backup/ 脚本的布局现场打出来、真的 7z 加密；MySQL 换成记录语句的假实现，
# docker / nginx / systemd 不在容器里，恢复一律带 --no-start。
# 能证明：解包校验、两种布局的翻译、冲突拦截、幂等重跑、账号 host、镜像锁版本、env 合并、
# crontab 合并与统一时间表、演练清理。证明不了：真实 MySQL 导入、容器启动、nginx、宝塔、systemd。

load helpers

setup_file() { mock_build; http_start; }
teardown_file() { http_stop; }

R=/tmp/dr                         # 恢复的目标都在这下面
PASSF=/root/bp
FDB=/tmp/fakedb
export DR_ROOT=$R/stage

setup() {
  reset_host
  rm -rf "$R" "$FDB" /tmp/pkgsrc /tmp/pkgs /root/ops-backups /root/.ssh /root/.ssh.bak.* /root/.my.cnf* /root/deploy \
         /usr/local/sbin/ops-drill-egress /etc/systemd/system/ops-drill-egress.service /tmp/ipt.rules \
         /tmp/docker.calls /tmp/docker.down-fails /tmp/nginx.calls
  mkdir -p /tmp/pkgs "$R/vhost"
  printf 'correct-horse-battery-staple-01\n' > "$PASSF"; chmod 600 "$PASSF"
  touch /root/.my.cnf
  env_conf \
    "BACKUP_PASS_FILE=$PASSF" "DB_CLIENT_HOST='172.%'" "DOCKER_CIDR=172.16.0.0/12" \
    "MYSQL_DEFAULTS_FILE=/root/.my.cnf" "PANEL_VHOST_DIR=$R/vhost" "PANEL_CERT_DIR=$R/cert" \
    "SVC_VW_DIR=$R/opt/vaultwarden" 'SVC_KOMARI_DATA=""' "BACKUP_DEPS='p7zip-full sqlite3'"
  fake_mysql
  # xboard 骨架要从 GitHub 拉；测试里不联网，让它确定地失败
  printf '#!/bin/sh\nexit 1\n' > /usr/local/bin/git; chmod 755 /usr/local/bin/git
}

env_conf() {
  mkdir -p /etc/ops-scripts
  printf '%s\n' "$@" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
}

# 假 MySQL：库是 $FDB/db/<库>/（tables 记表数），账号是 $FDB/user/<账号>@<host>，语句都记进 $FDB/log
fake_mysql() {
  cat > /usr/local/bin/mysql <<'SH'
#!/usr/bin/env bash
D=/tmp/fakedb; mkdir -p "$D/db" "$D/user"
q="" db="" prev=""
for a in "$@"; do
  if [ "$prev" = -e ]; then q=$a
  else case "$a" in -e|-N|-B|--defaults-file=*) ;; *) db=$a ;; esac; fi
  prev=$a
done
if [ -z "$q" ]; then
  in=$(cat)
  if [ -n "$db" ]; then
    echo "$(grep -c '^CREATE TABLE' <<<"$in")" > "$D/db/$db/tables"; echo "IMPORT $db" >> "$D/log"; exit 0
  fi
  q=$in
fi
printf '%s\n' "$q" >> "$D/log"
case "$q" in
  "SELECT 1") echo 1 ;;
  *information_schema.TABLES*) n=$(sed -n "s/.*TABLE_SCHEMA='\([^']*\)'.*/\1/p" <<<"$q"); cat "$D/db/$n/tables" 2>/dev/null || echo 0 ;;
  *information_schema.SCHEMATA*) n=$(sed -n "s/.*SCHEMA_NAME='\([^']*\)'.*/\1/p" <<<"$q"); [ -d "$D/db/$n" ] && echo 1 || echo 0 ;;
  *"FROM mysql.user"*) u=$(sed -n "s/.*User='\([^']*\)' AND Host='\([^']*\)'.*/\1@\2/p" <<<"$q"); [ -e "$D/user/$u" ] && echo 1 || echo 0 ;;
  *) while read -r l; do
       case "$l" in
         "CREATE DATABASE"*) n=$(cut -d'`' -f2 <<<"$l"); mkdir -p "$D/db/$n"; echo 0 > "$D/db/$n/tables" ;;
         "DROP DATABASE"*) rm -rf "$D/db/$(cut -d'`' -f2 <<<"$l")" ;;
         "DROP USER"*) rm -f "$D/user/$(sed -n "s/.*'\([^']*\)'@'\([^']*\)'.*/\1@\2/p" <<<"$l")" ;;
         "CREATE USER"*) touch "$D/user/$(sed -n "s/CREATE USER \(IF NOT EXISTS \)\{0,1\}'\([^']*\)'@'\([^']*\)'.*/\2@\3/p" <<<"$l")" ;;
       esac
     done <<<"$q" ;;
esac
SH
  printf '#!/bin/sh\necho "-- dump of $*"\n' > /usr/local/bin/mysqldump
  chmod 755 /usr/local/bin/mysql /usr/local/bin/mysqldump
}

seal() {  # seal <内容目录> <包文件> [tar]：照备份脚本打包加密；tar = vw 那样先打 payload.tar.gz
  local src=$1 out=$2 pack=/tmp/pkgsrc/pack
  rm -rf "$pack"; mkdir -p "$pack"
  if [ "${3:-}" = tar ]; then
    tar czf "$pack/payload.tar.gz" -C "$src" .
    cp "$src/manifest.txt" "$src/RESTORE.md" "$pack/" 2>/dev/null
  else
    cp -a "$src/." "$pack/"
  fi
  (cd "$pack" && 7z a -t7z -mhe=on -p"$(head -1 "$PASSF")" "$out" ./* ./.[!.]* >/dev/null 2>&1) || true
  [ -s "$out" ]
}

make_vw() {  # make_vw [时间戳]：照 vw-fullbackup 的布局打一个包，路径放 $VW
  local ts=${1:-20260927_033000} s=/tmp/pkgsrc/vw
  rm -rf "$s"; mkdir -p "$s"/{db,vaultwarden/data,komari,system/nginx,system/cert/a.example.com}
  printf -- '-- MySQL dump\nCREATE TABLE `users` (id int);\nCREATE TABLE `ciphers` (id int);\n-- Dump completed on 2026-09-27\n' \
    | gzip > "$s/db/vaultwarden.sql.gz"
  echo 'vaultwarden@172.%' > "$s/db/vaultwarden-grants.txt"
  echo KEY > "$s/vaultwarden/data/rsa_key.pem"
  echo "DATABASE_URL=mysql://vaultwarden:s3cr#e't@host.docker.internal:3306/vaultwarden" > "$s/vaultwarden/vaultwarden.env"
  printf 'services:\n  vaultwarden:\n    image: vaultwarden/server:latest\n    container_name: vaultwarden\n' > "$s/vaultwarden/compose.yaml"
  sqlite3 "$s/komari/komari.db" "CREATE TABLE configs(value text); INSERT INTO configs VALUES ('x');"
  printf 'services:\n  komari:\n    image: ghcr.io/komari-monitor/komari:latest\n    container_name: komari\n' > "$s/komari/compose.yaml"
  echo 'server { server_name a.example.com; }' > "$s/system/nginx/a.example.com.conf"
  echo CERT > "$s/system/cert/a.example.com/fullchain.pem"
  printf '%s\n' 'PATH=/usr/bin:/bin' \
    '30 3 * * * flock -w 3600 /var/lock/fb.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/x.log 2>&1' \
    '0 4 * * * /www/server/cron/abc123 >> /www/server/cron/abc123.log 2>&1' > "$s/system/crontab.txt"
  printf '%s\n' 'SVC_VW_DIR="/elsewhere"' "SVC_KOMARI_DATA=\"$R/opt/komari/data\"" 'MAIL_TO="ops@example.com"' > "$s/system/env.conf"
  echo '# 还原步骤' > "$s/RESTORE.md"
  { echo "备份时间   : 2026-09-27 03:30:00 UTC"; echo; echo "---- 容器 ----"
    printf 'vaultwarden\tvaultwarden/server:latest\tUp 3 days\nkomari\tghcr.io/komari-monitor/komari:latest\tUp 3 days\n'
    echo; echo "---- 版本 ----"; echo "Vaultwarden 1.32.0"; echo
    echo "---- 内容校验和 ----"; (cd "$s" && find . -type f -exec sha256sum {} \; | sort -k2)
  } > "$s/manifest.txt"
  VW=/tmp/pkgs/srvbak_$ts.7z
  seal "$s" "$VW" tar
}

make_v2() {  # make_v2 [时间戳] [附加内容]：新布局，照 backup/README.md「包结构」（payload.tar.gz 里是 rootfs/ + restore-manifest.tsv），路径放 $V2
  local s=/tmp/pkgsrc/v2 h ts=${1:-20260928_000000}
  rm -rf "$s"; mkdir -p "$s/rootfs$R/opt/app/data" "$s/rootfs$R/etc/sys" "$s/db" "$s/system" \
    "$s/rootfs/etc/ops-scripts" "$s/rootfs/root/.ssh" "$s/rootfs/usr/local/bin" "$s/rootfs/root"
  printf 'services:\n  app:\n    image: nginx:latest\n' > "$s/rootfs$R/opt/app/compose.yaml"
  sqlite3 "$s/rootfs$R/opt/app/data/app.db" 'CREATE TABLE t(x);'
  echo 'secret=1' > "$s/rootfs$R/etc/app.conf"
  echo 'from-original' > "$s/rootfs$R/etc/sys/sysfile.conf"
  printf '%s\n' 'SVC_VW_DIR="/elsewhere"' 'NEW_KEY_FROM_ORIGINAL="yes"' > "$s/rootfs/etc/ops-scripts/env.conf"
  echo v2026.01.01 > "$s/rootfs/etc/ops-scripts/ref"
  echo 'ssh-ed25519 AAAA-original-key' > "$s/rootfs/root/.ssh/authorized_keys"
  [ -n "${2:-}" ] && echo "$2" >> "$s/rootfs/root/.ssh/authorized_keys"
  echo '#!/bin/sh # 原机的旧 opsget' > "$s/rootfs/usr/local/bin/opsget"
  printf '[client]\npassword="original-root"\n' > "$s/rootfs/root/.my.cnf"
  printf -- 'CREATE TABLE `t1` (id int);\n-- Dump completed\n' | gzip > "$s/db/appdb.sql.gz"
  printf 'appdb\tlatin1\tlatin1_swedish_ci\n' > "$s/db/databases.tsv"
  cat > "$s/db/mysql-users.sql" <<'SQL'
CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED WITH 'caching_sha2_password' AS 0x2441243030350A;
ALTER USER 'app'@'%' IDENTIFIED WITH 'caching_sha2_password' AS 0x2441243030350A;
GRANT ALL PRIVILEGES ON `appdb`.* TO `app`@`%`;
CREATE USER IF NOT EXISTS 'app'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*ABC';
ALTER USER 'app'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*ABC';
GRANT SELECT ON `appdb`.* TO `app`@`localhost`;
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*ROOT';
ALTER USER 'root'@'localhost' IDENTIFIED WITH 'mysql_native_password' AS '*ROOT';
GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'x';
GRANT ALL PRIVILEGES ON *.* TO `root`@`%`;
CREATE USER IF NOT EXISTS 'other'@'%' IDENTIFIED BY 'y';
GRANT ALL PRIVILEGES ON `otherdb`.* TO `other`@`%`;
CREATE USER IF NOT EXISTS `bkroot`@`localhost` IDENTIFIED BY PASSWORD '*BK';
GRANT ALL PRIVILEGES ON *.* TO `bkroot`@`localhost` IDENTIFIED BY PASSWORD '*BK' WITH GRANT OPTION;
GRANT PROXY ON ''@'%' TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  h=$(printf 'a%.0s' $(seq 64))
  printf '# container\timage\trepo_digest\napp-app-1\tnginx:latest\tnginx@sha256:%s\n' "$h" > "$s/images.tsv"
  printf '%s\n' '# restore-manifest v1：path mode owner kind' \
    "/etc/ops-scripts	700	root:root	dir" \
    "/root/.ssh	700	root:root	dir" \
    "/usr/local/bin/opsget	755	root:root	file" \
    "/root/.my.cnf	600	root:root	file" \
    "$R/etc/app.conf	600	nobody:nogroup	file" \
    "$R/etc/sys	755	root:root	dir" \
    "$R/opt/app	755	root:root	dir" \
    "$R/opt/app/compose.yaml	644	root:root	file" \
    "$R/opt/app/data/app.db	640	nobody:nogroup	sqlite" \
    "db/mysql-users.sql	-	-	mysql-user" \
    "db/appdb.sql.gz	-	-	mysql-db" \
    "$R/opt/app	-	-	compose-project" > "$s/restore-manifest.tsv"
  # V2_EXTRA_SQL：追加到账号 SQL；V2_VHOST=1：像生产机那样把整个站点目录（PANEL_VHOST_DIR）作为一个 dir 条目
  [ -n "${V2_EXTRA_SQL:-}" ] && printf '%s\n' "$V2_EXTRA_SQL" >> "$s/db/mysql-users.sql"
  if [ -n "${V2_VHOST:-}" ]; then
    mkdir -p "$s/rootfs$R/vhost"
    echo 'server { server_name v.example.com; }' > "$s/rootfs$R/vhost/v.example.com.conf"
    printf '%s\t755\troot:root\tdir\n' "$R/vhost" >> "$s/restore-manifest.tsv"
  fi
  printf '/root/bp\t备份解密密码，按约定不进包\n/usr/local/bin/rclone\t超过 5MB 的二进制，换机时重新安装\n' > "$s/system/rootfs-skipped.txt"
  echo '备份时间 : 2026-09-28' > "$s/manifest.txt"; echo '# 还原' > "$s/RESTORE.md"
  V2=/tmp/pkgs/srvbak_$ts.7z
  seal "$s" "$V2" tar
}

restore() { run bash "$SRC/migrate/restore-from-backup.sh" "$@"; }
# none <正则> <文本>：文本里不能有匹配的行（bats 里写在中间的 `! 命令` 不会让用例失败）
none() {
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s
%s
' "$1" "$2" >&2
  return 1
}

# ── 取包与校验 ──────────────────────────────────────────────
@test "check：解开、校验、列出计划，本机什么都不留" {
  make_vw
  restore check "$VW"
  has "解密与 CRC 校验通过"
  has "内容校验和"
  has "项全部一致"
  has "vaultwarden.sql.gz：2 张表，结尾完整"
  has "放置"
  has "没有冲突，可以 restore"
  [ ! -e "$R/opt" ] && [ ! -e "$DR_ROOT" ] && [ ! -e /var/lib/ops-scripts/dr-restore.state ]
  [ -z "$(ls "$R/vhost")" ]
}

@test "check：内容和清单里的校验和对不上就停" {
  make_vw
  s=/tmp/pkgsrc/vw
  echo tampered >> "$s/vaultwarden/vaultwarden.env"
  rm -f "$VW"; seal "$s" "$VW" tar
  restore check "$VW"
  [ "$status" -ne 0 ]
  has "校验和不符"
}

@test "check：密码不对就停，不往下走" {
  make_vw
  echo 'wrong-password-wrong-password' > "$PASSF"
  restore check "$VW"
  [ "$status" -ne 0 ]
  has "解不开"
}

# ── 正式恢复 ────────────────────────────────────────────────
@test "restore：放回数据、建库导入、账号用 DB_CLIENT_HOST 加回环、env.conf 只补空键" {
  make_vw
  restore restore "$VW" --no-start
  [ -f "$R/opt/vaultwarden/data/rsa_key.pem" ]
  [ -f "$R/opt/komari/data/komari.db" ]
  [ -f "$R/vhost/a.example.com.conf" ]
  [ -f "$R/cert/a.example.com/fullchain.pem" ]
  has "integrity_check ok"
  grep -qx 'IMPORT vaultwarden' "$FDB/log"
  [ "$(cat "$FDB/db/vaultwarden/tables")" = 2 ]
  [ -e "$FDB/user/vaultwarden@172.%" ]
  [ -e "$FDB/user/vaultwarden@127.0.0.1" ]      # 备份脚本从本机经 127.0.0.1 连库
  none '@%$' "$(ls "$FDB/user")"
  grep -q "IDENTIFIED BY 's3cr#e\\\\'t'" "$FDB/log"   # 密码里的 # 和 ' 原样带过去
  # env.conf：本机填过的不动，本机空着的用原机的
  grep -q "^SVC_VW_DIR=$R/opt/vaultwarden" /etc/ops-scripts/env.conf
  grep -q "^SVC_KOMARI_DATA=\"$R/opt/komari/data\"" /etc/ops-scripts/env.conf
  grep -q '^MAIL_TO="ops@example.com"' /etc/ops-scripts/env.conf
  ls /etc/ops-scripts/env.conf.bak.* >/dev/null
}

@test "restore：镜像按清单锁版本，锁不住的标出来并列进手动步骤" {
  make_vw
  restore restore "$VW" --no-start
  grep -q 'image: vaultwarden/server:1.32.0' "$R/opt/vaultwarden/compose.yaml"
  grep -q 'image: ghcr.io/komari-monitor/komari:latest' "$R/opt/komari/compose.yaml"
  has "锁不住"
  has "komari 镜像锁不住版本，不启动"
  has "绝不拉 latest"
  lacks "cd $R/opt/komari && docker compose"
  has "cd $R/opt/vaultwarden && docker compose pull && docker compose up -d"
}

@test "restore：--image 给锁不住的容器指定版本；没版本号的 --image 直接拒绝" {
  make_vw
  restore restore "$VW" --no-start --image komari=ghcr.io/komari-monitor/komari:latest
  [ "$status" -ne 0 ]
  has "没锁版本"
  [ ! -e "$R/opt" ]
  restore restore "$VW" --no-start --image komari=ghcr.io/komari-monitor/komari:1.0.5
  grep -q 'image: ghcr.io/komari-monitor/komari:1.0.5' "$R/opt/komari/compose.yaml"
}

@test "restore：原机定时任务并入，面板任务列为手动，备份按统一时间表重排并沿用原来的锁" {
  make_vw
  restore restore "$VW" --no-start
  [ -x /usr/local/bin/vw-fullbackup.sh ]
  crontab -l | grep -qx '0 \*/6 \* \* \* /usr/bin/flock -n /var/lock/fb.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1'
  none '^30 3' "$(crontab -l)"
  none '/www/server/cron' "$(crontab -l)"
  crontab -l | grep -qx 'PATH=/usr/bin:/bin'
  has "面板计划任务：0 4 * * * /www/server/cron/abc123"
  has "宝塔面板里「添加站点」"
  has "逐站重新申请证书"
  has "DNS 解析改到本机"
}

@test "restore --no-cron：照常恢复，但不装定时任务，列进手动步骤" {
  make_vw
  restore restore "$VW" --no-start --no-cron
  [ -f "$R/opt/vaultwarden/data/rsa_key.pem" ]
  grep -qx 'IMPORT vaultwarden' "$FDB/log"
  [ -z "$(crontab -l 2>/dev/null)" ]
  [ ! -e /usr/local/bin/vw-fullbackup.sh ]
  has "--no-cron：不装定时任务"
  has "不带 --no-cron 再跑一次恢复"
  grep -qx 'MODE	real' /var/lib/ops-scripts/dr-restore.state
  lacks "手动跑一次 /usr/local/bin/vw-fullbackup.sh"
}

@test "restore：重跑不冲突、不重导、crontab 不重复" {
  make_vw
  restore restore "$VW" --no-start
  echo "runtime" > "$R/opt/vaultwarden/data/icon.png"     # 服务跑起来之后改了数据目录
  crontab -l > /tmp/cron1
  restore restore "$VW" --no-start
  lacks "冲突"
  has "已恢复·跳过"
  [ "$(grep -c '^IMPORT vaultwarden' "$FDB/log")" = 1 ]
  [ -f "$R/opt/vaultwarden/data/icon.png" ]
  crontab -l | diff /tmp/cron1 -
}

@test "restore：导了一半中断的库，重跑时删掉重导" {
  make_vw
  restore restore "$VW" --no-start
  sed -i '/^DBDONE/d' /var/lib/ops-scripts/dr-restore.state    # 模拟导入到一半被打断
  restore restore "$VW" --no-start
  has "上次没导完的，删掉重导"
  [ "$(grep -c '^IMPORT vaultwarden' "$FDB/log")" = 2 ]
}

@test "restore：本机已有数据就拒绝，什么都不动；--force 才覆盖并把原有的留成 .bak" {
  make_vw
  mkdir -p "$R/opt/vaultwarden/data"; echo live > "$R/opt/vaultwarden/data/live.txt"
  mkdir -p "$FDB/db/vaultwarden"; echo 5 > "$FDB/db/vaultwarden/tables"
  restore restore "$VW" --no-start
  [ "$status" -ne 0 ]
  has "冲突"
  has "--force"
  [ ! -e "$R/vhost/a.example.com.conf" ]
  none '^IMPORT' "$(cat "$FDB/log" 2>/dev/null)"
  OPS_YES=1 restore restore "$VW" --no-start --force
  [ -f "$R/opt/vaultwarden/data/rsa_key.pem" ]
  ls "$R"/opt/vaultwarden/data.bak.*/live.txt >/dev/null
  ls "$DR_ROOT"/before-vaultwarden-*.sql.gz >/dev/null
  grep -qx 'IMPORT vaultwarden' "$FDB/log"
}

# ── 演练 ────────────────────────────────────────────────────
@test "演练：本机有数据就拒绝，--force 也不行" {
  make_vw
  mkdir -p "$R/opt/vaultwarden/data"; echo live > "$R/opt/vaultwarden/data/live.txt"
  restore restore "$VW" --no-start --drill
  [ "$status" -ne 0 ]
  has "演练只在干净的机器上做"
  restore restore "$VW" --no-start --drill --force
  [ "$status" -ne 0 ]
  [ ! -e "$R/vhost/a.example.com.conf" ]
}

@test "演练 + teardown：不装定时任务；清理只删恢复出来的，env.conf 还原" {
  make_vw
  echo 'default' > "$R/vhost/0.default.conf"
  cp /etc/ops-scripts/env.conf /tmp/env.before
  restore restore "$VW" --no-start --drill
  [ -f "$R/opt/vaultwarden/data/rsa_key.pem" ]
  [ -z "$(crontab -l 2>/dev/null)" ]
  has "演练：不装定时任务"
  restore teardown
  OPS_YES=1 restore teardown
  [ ! -e "$R/opt" ] && [ ! -e "$R/cert" ] && [ ! -e "$R/vhost/a.example.com.conf" ]
  [ -f "$R/vhost/0.default.conf" ]
  [ ! -d "$FDB/db/vaultwarden" ]
  [ -z "$(ls "$FDB/user")" ]
  cmp /tmp/env.before /etc/ops-scripts/env.conf
  [ ! -e /var/lib/ops-scripts/dr-restore.state ] && [ ! -e "$DR_ROOT" ]
}

# 假 iptables / ip6tables：规则按「命令 链 参数」一行记进 /tmp/ipt.rules；-D 删掉一条，没有就失败（跟真的一样）
fake_iptables() {
  cat > /usr/local/bin/iptables <<'SH'
#!/usr/bin/env bash
f=/tmp/ipt.rules; touch "$f"; me=$(basename "$0")
[ "$1" = -w ] && shift
op=$1; shift
case "$op" in
  -N) exit 0 ;;
  -I) printf '%s %s\n' "$me" "$*" >> "$f" ;;
  -D) l="$me $*"; grep -qxF -- "$l" "$f" || exit 1
      awk -v l="$l" '!d && $0 == l { d = 1; next } { print }' "$f" > "$f.t" && mv "$f.t" "$f" ;;
esac
SH
  chmod 755 /usr/local/bin/iptables; ln -sf iptables /usr/local/bin/ip6tables
}

@test "演练：起容器前拦下容器主动外连（开机自启、排在 docker 前），重跑不叠加；teardown 撤掉；正式恢复不加" {
  fake_iptables
  make_vw
  restore restore "$VW" --no-start --drill
  has "容器主动外连已拦下"
  has "发信测试这类要连外网的功能会失败"
  [ "$(grep -c '^iptables DOCKER-USER -i docker0 ! -o docker0 -m conntrack --ctstate NEW .*-j REJECT$' /tmp/ipt.rules)" = 1 ]
  [ "$(grep -c '^iptables DOCKER-USER -i br-+ ! -o br-+ -m conntrack --ctstate NEW .*-j REJECT$' /tmp/ipt.rules)" = 1 ]
  [ "$(grep -c '^ip6tables DOCKER-USER' /tmp/ipt.rules)" = 2 ]
  grep -qx 'Before=docker.service' /etc/systemd/system/ops-drill-egress.service
  grep -qx 'WantedBy=multi-user.target docker.service' /etc/systemd/system/ops-drill-egress.service
  grep -qx 'ExecStart=/usr/local/sbin/ops-drill-egress start' /etc/systemd/system/ops-drill-egress.service
  restore restore "$VW" --no-start --drill
  [ "$(wc -l < /tmp/ipt.rules)" = 4 ]
  OPS_YES=1 restore teardown
  has "撤掉演练时加的容器外连限制"
  [ ! -s /tmp/ipt.rules ]
  [ ! -e /usr/local/sbin/ops-drill-egress ] && [ ! -e /etc/systemd/system/ops-drill-egress.service ]
  make_vw
  restore restore "$VW" --no-start
  [ ! -s /tmp/ipt.rules ] && [ ! -e /etc/systemd/system/ops-drill-egress.service ]
  none "外连" "$output"
}

# 假 docker：调用记成「所在目录|参数」；compose down 在 /tmp/docker.down-fails 存在时失败。
# 有了它（和假 nginx）才能不带 --no-start 走真正的启动、重载与 teardown 路径
fake_docker() {
  cat > /usr/local/bin/docker <<'SH'
#!/usr/bin/env bash
echo "$PWD|$*" >> /tmp/docker.calls
case "$*" in
  "compose down"*) [ -e /tmp/docker.down-fails ] && exit 1 ;;
esac
exit 0
SH
  chmod 755 /usr/local/bin/docker
}
fake_nginx() {  # 假 nginx：调用记进 /tmp/nginx.calls，-t 总是通过
  printf '#!/bin/sh\necho "nginx $*" >> /tmp/nginx.calls\nexit 0\n' > /usr/local/bin/nginx
  chmod 755 /usr/local/bin/nginx
}

@test "新布局整棵放回站点目录：检查并重载 nginx（不带 --no-start，docker 与 nginx 是桩）" {
  fake_docker; fake_nginx
  V2_VHOST=1 make_v2; v2_local
  restore restore "$V2"
  [ -f "$R/vhost/v.example.com.conf" ]
  grep -qx 'nginx -t' /tmp/nginx.calls
  grep -qx 'nginx -s reload' /tmp/nginx.calls
  has "nginx 已重载"
  grep -qx "$R/opt/app|compose up -d" /tmp/docker.calls
}

@test "Komari 指标库不进包：恢复时建空库、恢复它的账号；teardown 一并删掉；没有这个账号就不建库" {
  make_v2; v2_local
  restore restore "$V2" --no-start --drill
  [ ! -d "$FDB/db/metrics" ]
  OPS_YES=1 restore teardown
  V2_EXTRA_SQL="CREATE USER IF NOT EXISTS 'metrics'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*MET';
GRANT ALL PRIVILEGES ON \`metrics\`.* TO \`metrics\`@\`%\`;" make_v2; v2_local
  restore restore "$V2" --no-start --drill
  [ -d "$FDB/db/metrics" ] && [ -e "$FDB/user/metrics@172.%" ]
  has "建空的指标库 metrics"
  none "不恢复账号 metrics" "$output"
  OPS_YES=1 restore teardown
  [ ! -d "$FDB/db/metrics" ] && [ ! -e "$FDB/user/metrics@172.%" ]
}

@test "演练 teardown：真的停掉只有 compose.yaml 的项目；停不下就中止，外连限制、库、文件都不动，修好后重跑能清完" {
  fake_docker; fake_iptables
  make_v2; v2_local
  restore restore "$V2" --drill
  has "容器主动外连已拦下"
  grep -qx "$R/opt/app|compose up -d" /tmp/docker.calls
  touch /tmp/docker.down-fails
  OPS_YES=1 restore teardown
  [ "$status" -ne 0 ]
  has "容器停不下来"
  [ -s /tmp/ipt.rules ] && [ -d "$FDB/db/appdb" ] && [ -d "$R/opt/app" ] && [ -e /var/lib/ops-scripts/dr-restore.state ]
  rm -f /tmp/docker.down-fails
  OPS_YES=1 restore teardown
  has "$R/opt/app 已停并删除容器与镜像"
  [ ! -s /tmp/ipt.rules ] && [ ! -d "$FDB/db/appdb" ] && [ ! -e "$R/opt/app" ]
}

@test "演练：加不上外连限制时，--no-start 列进手动步骤、不算告警" {
  make_vw
  restore restore "$VW" --no-start --drill
  has "起容器之前先让 /usr/local/sbin/ops-drill-egress start 成功"
  none "外连限制没加上" "$output"
}

@test "teardown：正式恢复过的机器拒绝清理" {
  make_vw
  restore restore "$VW" --no-start
  OPS_YES=1 restore teardown
  [ "$status" -ne 0 ]
  has "拒绝"
  [ -f "$R/opt/vaultwarden/data/rsa_key.pem" ]
}

@test "正式恢复与演练不能在同一台机器上混用" {
  make_vw
  restore restore "$VW" --no-start --drill
  restore restore "$VW" --no-start
  [ "$status" -ne 0 ]
  has "先 teardown"
}

make_xboard() {  # make_xboard [.env 的 APP_KEY 行]：照 xboard-fullbackup 的布局打一个包（不套 payload），路径放 $XB
  local s=/tmp/pkgsrc/xb
  rm -rf "$s"; mkdir -p "$s"/{db,app/.docker/.data,app/plugins,nginx/vhost,nginx/cert/b.example.com,nginx/assets-site,deploy}
  printf -- 'CREATE TABLE `v2_user` (id int);\n-- Dump completed\n' > "$s/db/xboard.sql"
  echo 'xboard@127.0.0.1' > "$s/db/xboard-grants.txt"
  printf '%s\n' "${1:-APP_KEY=base64:abc}" 'DB_HOST=127.0.0.1' 'DB_DATABASE=xboard' 'DB_USERNAME=xboard' 'DB_PASSWORD="xb pass"' > "$s/app/.env"
  printf 'services:\n  xboard:\n    image: ghcr.io/cedar2025/xboard:new\n' > "$s/app/compose.yaml"
  echo 'server { server_name b.example.com; }' > "$s/nginx/vhost/b.example.com.conf"
  echo CERT > "$s/nginx/cert/b.example.com/fullchain.pem"
  echo logo > "$s/nginx/assets-site/logo.png"
  echo 'node1 1.2.3.4' > "$s/deploy/nodes.txt"
  printf '%s\n' "SVC_XBOARD_DIR=\"$R/opt/xboard\"" "XBOARD_DB_PASS_FILE=\"$R/etc/xboard-db-pass\"" "WWWROOT=\"$R/wwwroot\"" > "$s/deploy/env.conf"
  echo 'Xboard 备份包' > "$s/MANIFEST.txt"
  printf '# Xboard 恢复步骤\n\n    cp -a nginx/assets-site %s/wwwroot/assets.example.com\n' "$R" > "$s/RESTORE.md"
  XB=/tmp/pkgs/xboard_20260927_040000.7z
  seal "$s" "$XB"
}

@test "xboard 包与 vw 包一起恢复：库账号、应用目录、静态站、部署元数据、库密码文件、定时任务" {
  rm -rf /root/deploy
  make_vw; make_xboard
  restore restore "$VW" "$XB" --no-start
  grep -q '^APP_KEY=base64:abc' "$R/opt/xboard/.env"
  [ -f "$R/opt/xboard/compose.yaml" ]
  has "拉不到 Xboard compose 分支"
  grep -qx 'IMPORT xboard' "$FDB/log"
  [ -e "$FDB/user/xboard@172.%" ] && [ -e "$FDB/user/xboard@127.0.0.1" ]
  [ -f "$R/vhost/b.example.com.conf" ] && [ -f "$R/cert/b.example.com/fullchain.pem" ]
  [ -f "$R/wwwroot/assets.example.com/logo.png" ]
  [ "$(stat -c %a /root/deploy/nodes.txt)" = 600 ]
  [ "$(cat "$R/etc/xboard-db-pass")" = "xb pass" ] && [ "$(stat -c %a "$R/etc/xboard-db-pass")" = 600 ]
  has "xboard 镜像锁不住版本，不启动"
  crontab -l | grep -q '^20 \*/6 \* \* \* /usr/bin/flock -n /var/lock/xboard-fullbackup-cron.lock /usr/local/bin/xboard-fullbackup.sh'
  crontab -l | grep -q '^0 \*/6 .*vw-fullbackup.sh'
  rm -rf /root/deploy
}

@test "xboard 包：.env 里没有 APP_KEY 就拒绝，什么都不动" {
  make_xboard 'APP_KEY='
  restore restore "$XB" --no-start
  [ "$status" -ne 0 ]
  has "没有 APP_KEY"
  [ ! -e "$R/opt" ]
  none '^IMPORT' "$(cat "$FDB/log" 2>/dev/null)"
}

# ── 新布局：rootfs + restore-manifest.tsv ───────────────────
v2_local() {  # 新机的样子：引导用的公钥、配好的 .my.cnf、init/ 写过的系统文件
  mkdir -p /root/.ssh "$R/etc/sys"
  echo 'ssh-ed25519 AAAA-bootstrap-key' > /root/.ssh/authorized_keys
  printf '[client]\npassword="new-root"\n' > /root/.my.cnf
  echo 'written-by-init' > "$R/etc/sys/sysfile.conf"
}

@test "新布局：权限属主照清单，库字符集照原机，账号 host 只改 %、回环保留，系统与无关账号不碰，digest 锁版本" {
  make_v2; v2_local
  restore restore "$V2" --no-start
  [ "$(stat -c '%a %U' "$R/etc/app.conf")" = "600 nobody" ]
  [ "$(stat -c '%a %U' "$R/opt/app/data/app.db")" = "640 nobody" ]
  grep -q 'CHARACTER SET latin1 COLLATE latin1_swedish_ci' "$FDB/log"
  [ -e "$FDB/user/app@172.%" ] && [ -e "$FDB/user/app@localhost" ]
  none '^(other)@' "$(ls "$FDB/user")"
  none "'root'@'%'" "$(cat "$FDB/log")"
  none "DROP USER IF EXISTS 'root'" "$(cat "$FDB/log")"
  grep -q "DROP USER IF EXISTS 'app'@'172.%'" "$FDB/log"
  grep -q 'image: nginx@sha256:aaaa' "$R/opt/app/compose.yaml"
  has "不恢复账号 other@'%'：对恢复的库没有授权"
  has "备份没收 /usr/local/bin/rclone"
  lacks "备份没收 /root/bp"
}

@test "新布局：系统配置留 .bak 后替换、不算冲突；工具箱与凭据保留本机的；env.conf 只按键合并" {
  make_v2; v2_local
  echo '#!/bin/sh # 新机的 opsget' > /tmp/opsget.new; cp /usr/local/bin/opsget /tmp/opsget.local
  restore restore "$V2" --no-start
  lacks "冲突"
  [ "$(cat "$R/etc/sys/sysfile.conf")" = from-original ]
  [ "$(cat "$R"/etc/sys.bak.*/sysfile.conf)" = written-by-init ]
  cmp /usr/local/bin/opsget /tmp/opsget.local                  # 正在用的工具箱不被原机的旧版换掉
  grep -q '原机的旧 opsget' /usr/local/bin/opsget.from-backup
  [ "$(cat /etc/ops-scripts/ref 2>/dev/null)" != v2026.01.01 ]  # 版本固定保留本机的
  grep -q '^NEW_KEY_FROM_ORIGINAL="yes"' /etc/ops-scripts/env.conf
  grep -q "^SVC_VW_DIR=$R/opt/vaultwarden" /etc/ops-scripts/env.conf
}

@test "新布局：/root/.ssh 换成原机的，恢复前能登录的公钥并回去" {
  make_v2; v2_local
  restore restore "$V2" --no-start
  grep -q 'AAAA-original-key' /root/.ssh/authorized_keys
  grep -q 'AAAA-bootstrap-key' /root/.ssh/authorized_keys
  [ "$(stat -c %a /root/.ssh)" = 700 ]
}

@test "新布局：正式恢复最后把 root 改成原机的并换用原机的 .my.cnf；演练不动 root" {
  make_v2; v2_local
  restore restore "$V2" --no-start --drill
  none "'root'@'localhost'" "$(cat "$FDB/log")"
  grep -q 'new-root' /root/.my.cnf
  OPS_YES=1 restore teardown
  rm -rf "$FDB"; v2_local
  restore restore "$V2" --no-start
  grep -q "ALTER USER 'root'@'localhost'" "$FDB/log"
  grep -q 'original-root' /root/.my.cnf
  grep -q 'new-root' /root/.my.cnf.bak.*
  has "root@localhost 已按原机设置"
  has "换成原机的（试连通过"
}

@test "新布局演练 + teardown：替换过的系统配置和 .ssh 都还原" {
  make_v2; v2_local
  restore restore "$V2" --no-start --drill
  [ "$(cat "$R/etc/sys/sysfile.conf")" = from-original ]
  OPS_YES=1 restore teardown
  [ "$(cat "$R/etc/sys/sysfile.conf")" = written-by-init ]
  [ "$(cat /root/.ssh/authorized_keys)" = 'ssh-ed25519 AAAA-bootstrap-key' ]
  [ ! -e "$R/opt" ] && [ ! -e /usr/local/bin/opsget.from-backup ]
  [ -z "$(ls -d "$R"/etc/sys.bak.* 2>/dev/null)" ]
}

@test "新布局：两个包带同一个目录和库，只按较新的包放一次，.bak 只有一份且没嵌套" {
  make_v2 20260928_000000; local older=$V2
  make_v2 20260928_060000 'ssh-ed25519 AAAA-newer-key'
  v2_local
  restore restore "$older" "$V2" --no-start
  has "20260928_060000 的包里也有，用它的"
  [ "$(ls -d /root/.ssh.bak.* | wc -l)" = 1 ]
  [ ! -e /root/.ssh.bak.*/.ssh ]
  grep -q 'AAAA-bootstrap-key' /root/.ssh.bak.*/authorized_keys
  grep -q 'AAAA-newer-key' /root/.ssh/authorized_keys
  [ "$(grep -c '^IMPORT appdb' "$FDB/log")" = 1 ]
}

@test "两个包带同一个 compose 项目与同一批账号：锁版本、启动、建账号都只做一遍，手动步骤不重复" {
  fake_docker; fake_nginx
  make_v2 20260928_000000; local older=$V2
  make_v2 20260928_060000
  v2_local
  restore restore "$older" "$V2"
  [ "$(grep -c "^$R/opt/app|compose up -d$" /tmp/docker.calls)" = 1 ]
  [ "$(sed -n '/===== 镜像版本/,/^===== 写入配置/p' <<<"$output" | grep -c "$R/opt/app 的 app")" = 1 ]
  none 'are the same file' "$output"
  none '已恢复过，跳过' "$output"
  [ "$(grep -c "账号 app@'172.%'" <<<"$output")" = 1 ]
  [ "$(grep -c '备份没收 /usr/local/bin/rclone' <<<"$output")" = 1 ]
  has "20260928_060000 的包里也有这批账号，用它的"
}

@test "新布局：本机登录的管理账号（只有全局权限）也恢复；MariaDB 的 root 代理授权不当成跳过项" {
  make_v2; v2_local
  restore restore "$V2" --no-start
  [ -e "$FDB/user/bkroot@localhost" ]
  lacks "不恢复账号 ''"
  lacks "不恢复账号 root@'localhost'"
  none "PROXY" "$(grep -v '^GRANT PROXY' "$FDB/log" | grep PROXY)"
}

@test "new-api 包明确拒绝，指向 newapi-drill" {
  printf x > /tmp/pkgs/newapi_20260928_000000.7z
  restore check /tmp/pkgs/newapi_20260928_000000.7z
  [ "$status" -ne 0 ]
  has "ops/newapi-drill"
}

@test "LiteLLM 包明确拒绝，指向 litellm-drill 与包里的 RESTORE.md" {
  printf x > /tmp/pkgs/litellm_20260928_000000.7z
  restore check /tmp/pkgs/litellm_20260928_000000.7z
  [ "$status" -ne 0 ]
  has "ops/litellm-drill"
  has "RESTORE.md"
}

# ── 定时任务安装器 ──────────────────────────────────────────
cron_install() { run bash "$SRC/ops/install-backup-cron.sh" "$@"; }

@test "安装器：预演不写入；--apply 补 PATH、按时间表写入、沿用原锁；再跑不重复" {
  local_stub vw-fullbackup; local_stub newapi-fullbackup
  printf '%s\n' '30 3 * * * flock -w 3600 /var/lock/fullbackup.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1' \
    '15 2 * * * /usr/local/bin/other.sh >/dev/null 2>&1' | crontab -
  crontab -l > /tmp/c0
  cron_install
  has "预演结束，未写入"
  crontab -l | diff /tmp/c0 -
  cron_install --apply
  crontab -l | head -1 | grep -q '^PATH='
  crontab -l | grep -qx '0 \*/6 \* \* \* /usr/bin/flock -n /var/lock/fullbackup.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1'
  crontab -l | grep -qx '5 \* \* \* \* /usr/bin/flock -n /var/lock/newapi-fullbackup-cron.lock /usr/local/bin/newapi-fullbackup.sh >> /var/log/newapi-fullbackup-cron.log 2>&1'
  crontab -l | grep -q '/usr/local/bin/other.sh'
  none 'xboard-fullbackup' "$(crontab -l)"
  [ "$(crontab -l | grep -c 'vw-fullbackup.sh')" = 1 ]
  ls /root/ops-backups/crontab.* >/dev/null
  crontab -l > /tmp/c1
  cron_install --apply
  has "无需改动"
  crontab -l | diff /tmp/c1 -
}

@test "安装器：opsget 写法的旧行也换掉，日志路径里的同名不误伤" {
  local_stub vw-fullbackup
  printf '%s\n' '0 1 * * * opsget backup/vw-fullbackup' '0 9 * * * tail -5 /var/log/vw-fullbackup.log > /tmp/x' | crontab -
  cron_install --apply
  none opsget "$(crontab -l)"
  crontab -l | grep -q 'tail -5 /var/log/vw-fullbackup.log'
  [ "$(crontab -l | grep -c '/usr/local/bin/vw-fullbackup.sh')" = 1 ]
}

@test "安装器：外层锁不用脚本自己的 /run/lock/<名>.lock（同一把锁会让备份一启动就退出）" {
  local_stub vw-fullbackup; local_stub xboard-fullbackup
  printf '%s\n' '0 3 * * * /usr/bin/flock -n /run/lock/vw-fullbackup.lock /usr/local/bin/vw-fullbackup.sh' \
    '0 4 * * * flock -n /var/lock/xboard-fullbackup.lock /usr/local/bin/xboard-fullbackup.sh' | crontab -
  cron_install --apply
  none 'flock -n /(run|var)/lock/(vw|xboard)-fullbackup\.lock' "$(crontab -l)"
  crontab -l | grep -q 'flock -n /var/lock/vw-fullbackup-cron.lock /usr/local/bin/vw-fullbackup.sh'
  crontab -l | grep -q 'flock -n /var/lock/xboard-fullbackup-cron.lock /usr/local/bin/xboard-fullbackup.sh'
  has "心跳监控的周期"
}

@test "安装器：litellm-fullbackup 每 6 小时 :40，旧行换掉，再跑不重复" {
  local_stub litellm-fullbackup
  echo '0 2 * * * /usr/local/bin/litellm-fullbackup.sh >> /tmp/x.log 2>&1' | crontab -
  cron_install --apply
  crontab -l | grep -qx '40 \*/6 \* \* \* /usr/bin/flock -n /var/lock/litellm-fullbackup-cron.lock /usr/local/bin/litellm-fullbackup.sh >> /var/log/litellm-fullbackup-cron.log 2>&1'
  [ "$(crontab -l | grep -c 'litellm-fullbackup.sh')" = 1 ]
  none '^0 2 ' "$(crontab -l)"
  has "vw / xboard / litellm 6 小时"
  crontab -l > /tmp/c1
  cron_install --apply
  has "无需改动"
  crontab -l | diff /tmp/c1 -
}

@test "安装器：panel-backup-create 每周日 UTC 19:30，锁与日志各用各的" {
  local_stub panel-backup-create
  cron_install --apply
  crontab -l | grep -qx '30 19 \* \* 0 /usr/bin/flock -n /var/lock/panel-backup-create-cron.lock /usr/local/bin/panel-backup-create.sh >> /var/log/panel-backup-create-cron.log 2>&1'
  has "面板整机备份每周"
}

@test "安装器：一个备份脚本都没装时说清楚，不动 crontab" {
  echo '15 2 * * * /usr/local/bin/other.sh' | crontab -
  cron_install --apply
  has "一个备份脚本都没装"
  [ "$(crontab -l)" = '15 2 * * * /usr/local/bin/other.sh' ]
}

# ── SSH 两步验证 ─────────────────────────────────────────────
make_v2_2fa() {  # 在 make_v2 的新布局包里加上 Google 两步验证的 PAM 配置与 TOTP 密钥
  make_v2
  local s=/tmp/pkgsrc/v2
  mkdir -p "$s/rootfs/etc/pam.d"
  printf '%s\n' '@include common-auth' 'auth required pam_google_authenticator.so nullok' > "$s/rootfs/etc/pam.d/sshd"
  printf 'TOTPSECRET\n" TOTP_AUTH\n12345678\n' > "$s/rootfs/root/.google_authenticator"
  chmod 400 "$s/rootfs/root/.google_authenticator"
  printf '%s\t%s\t%s\t%s\n' /etc/pam.d/sshd 644 root:root file /root/.google_authenticator 400 root:root file \
    >> "$s/restore-manifest.tsv"
  rm -f "$V2"; seal "$s" "$V2" tar
}
fake_apt() {  # apt-get 只记录调用，不联网
  printf '#!/bin/sh\necho "$*" >> /tmp/apt.log\n' > /usr/local/bin/apt-get
  chmod 755 /usr/local/bin/apt-get; : > /tmp/apt.log
}

@test "SSH 两步验证：PAM 配置与 TOTP 密钥照原机放回，自动装 PAM 模块，提醒先用新窗口测试登录" {
  rm -f /etc/pam.d/sshd /root/.google_authenticator
  make_v2_2fa; v2_local; fake_apt
  restore restore "$V2" --no-start
  [ "$status" -eq 0 ]
  grep -q pam_google_authenticator /etc/pam.d/sshd
  [ "$(stat -c '%a %U' /root/.google_authenticator)" = "400 root" ]
  grep -q 'install .*libpam-google-authenticator' /tmp/apt.log
  has "另开一个窗口用原来的密钥测试登录"
  lacks "/root/.google_authenticator 不在本机"
  rm -f /etc/pam.d/sshd /root/.google_authenticator
}

@test "SSH：放回的配置过不了 sshd -t 时告警，要求修好之前不要重启 SSH" {
  rm -f /etc/pam.d/sshd /root/.google_authenticator
  make_v2_2fa; v2_local; fake_apt
  printf '#!/bin/sh\nexit 1\n' > /usr/local/bin/sshd; chmod 755 /usr/local/bin/sshd
  restore restore "$V2" --no-start
  has "sshd -t 没通过"
  has "修好 sshd 配置"
  rm -f /etc/pam.d/sshd /root/.google_authenticator
}

@test "SSH：原机没开两步验证时不装 PAM 模块，也不出相关提示" {
  rm -f /etc/pam.d/sshd /root/.google_authenticator
  make_v2; v2_local; fake_apt
  restore restore "$V2" --no-start
  none 'libpam-google-authenticator' "$(cat /tmp/apt.log)"
  lacks "验证码"
}

# ── SSH 来源 IP 放行名单 ─────────────────────────────────────
make_v2_ufw() {  # 在 make_v2 的包里加上原机的 sshd 端口与只放行两个 IP 的 ufw 规则
  make_v2
  local s=/tmp/pkgsrc/v2
  mkdir -p "$s/rootfs/etc/ssh" "$s/rootfs/etc/ufw"
  printf 'Port 2222\nPubkeyAuthentication yes\n' > "$s/rootfs/etc/ssh/sshd_config"
  printf '%s\n' '*filter' ':ufw-user-input - [0:0]' \
    '-A ufw-user-input -p tcp --dport 2222 -s 198.51.100.7 -j ACCEPT' \
    '-A ufw-user-input -p tcp --dport 2222 -s 203.0.113.9 -j ACCEPT' \
    '-A ufw-user-input -p tcp --dport 443 -j ACCEPT' 'COMMIT' > "$s/rootfs/etc/ufw/user.rules"
  printf '%s\t%s\t%s\t%s\n' /etc/ssh/sshd_config 644 root:root file /etc/ufw 755 root:root dir \
    >> "$s/restore-manifest.tsv"
  rm -f "$V2"; seal "$s" "$V2" tar
}
ufw_cleanup() { rm -rf /etc/ufw /etc/ufw.bak.* /etc/ssh/sshd_config.bak.*; }

@test "SSH 放行名单：当前会话的 IP 不在原机名单里时，给出带端口的放行命令" {
  ufw_cleanup; make_v2_ufw; v2_local
  SSH_CONNECTION="192.0.2.50 51000 10.0.0.2 2222" restore restore "$V2" --no-start
  has "原机的 SSH 放行名单里没有你现在的 IP（192.0.2.50）"   # 告警，所以退出码非零
  has "ufw allow from 192.0.2.50 to any port 2222 proto tcp"
  ufw_cleanup
}

@test "SSH 放行名单：当前会话的 IP 在名单里时不打扰" {
  ufw_cleanup; make_v2_ufw; v2_local
  SSH_CONNECTION="203.0.113.9 51000 10.0.0.2 2222" restore restore "$V2" --no-start
  has "SSH 放行名单里有你现在的 IP（203.0.113.9）"
  lacks "ufw allow from 203.0.113.9"
  ufw_cleanup
}

@test "安装器：旧行命令前的环境变量（MAIL_TO=...）照留到新行" {
  local_stub xboard-fullbackup
  printf '%s\n' '50 3 * * * MAIL_TO=ops-xboard@example.com flock -w 3600 /var/lock/xb.lock /usr/local/bin/xboard-fullbackup.sh >> /var/log/xboard-fullbackup-cron.log 2>&1' | crontab -
  cron_install --apply
  crontab -l | grep -qx '20 \*/6 \* \* \* MAIL_TO=ops-xboard@example.com /usr/bin/flock -n /var/lock/xb.lock /usr/local/bin/xboard-fullbackup.sh >> /var/log/xboard-fullbackup-cron.log 2>&1'
  has "沿用旧行的环境变量 MAIL_TO=ops-xboard@example.com"
  crontab -l > /tmp/c1; cron_install --apply; has "无需改动"; crontab -l | diff /tmp/c1 -
}

@test "安装器：几个备份脚本共用的外层锁不沿用，各用各的（-n 下共用会互相挤掉）" {
  local_stub vw-fullbackup; local_stub xboard-fullbackup; local_stub newapi-fullbackup
  printf '%s\n' \
    '30 3 * * * flock -w 3600 /var/lock/fullbackup.lock /usr/local/bin/vw-fullbackup.sh >> /var/log/vw-fullbackup-cron.log 2>&1' \
    '50 3 * * * flock -w 3600 /var/lock/fullbackup.lock /usr/local/bin/xboard-fullbackup.sh >> /var/log/xboard-fullbackup-cron.log 2>&1' \
    '10 4 * * * flock -w 3600 /var/lock/fullbackup.lock /usr/local/bin/newapi-fullbackup.sh >> /var/log/newapi-fullbackup-cron.log 2>&1' | crontab -
  cron_install --apply
  none 'fullbackup\.lock' "$(crontab -l)"
  crontab -l | grep -q -- '-n /var/lock/vw-fullbackup-cron.lock /usr/local/bin/vw-fullbackup.sh'
  crontab -l | grep -q -- '-n /var/lock/xboard-fullbackup-cron.lock /usr/local/bin/xboard-fullbackup.sh'
  crontab -l | grep -q -- '-n /var/lock/newapi-fullbackup-cron.lock /usr/local/bin/newapi-fullbackup.sh'
  has "原来和其他备份脚本共用外层锁 /var/lock/fullbackup.lock"
  crontab -l > /tmp/c1; cron_install --apply; has "无需改动"; crontab -l | diff /tmp/c1 -
}
