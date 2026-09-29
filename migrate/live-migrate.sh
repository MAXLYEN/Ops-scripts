#!/usr/bin/env bash
# migrate/live-migrate.sh — 原机还在时的一键迁移（在旧机上运行）：预检 → 演练 → 停写切换 → DNS
# VERSION: 1.0.0
# 1.0.0: 首版。预检两台机器；演练时本机照常服务，用备份脚本 --local-only 现做加密包经 SSH 直传新机，restore-from-backup --no-cron 恢复、check 比对、08 验收、经 --resolve 逐站对比后停掉新机的容器；切换时暂停本机备份定时任务、停容器、再做一次包、restore --force 并启动；DNS 保持人工，确认后经公共 DNS 复核；DNS 切换前随时可回滚。SSH 只用密钥、复用一条连接；恢复后新机临时放行本机 IP，落地机等机器的放行名单同步加上新机。
# ENV-REQUIRED: BACKUP_PASS_FILE|VW_PASS_FILE MYSQL_DEFAULTS_FILE PANEL_VHOST_DIR
# 用法：
#   live-migrate.sh <新机IPv4> [--ssh-port N] [阶段] [--no-start] [--verify-dns]
#   live-migrate.sh status
#   live-migrate.sh rollback
# 不写阶段 = 预检 → 演练 → 切换 → DNS，每段开始前确认（OPS_YES=1 跳过确认；「DNS 已经改好」永远要在终端里亲手确认）
#   --check          只预检、列出计划，两台机器都不动
#   --rehearse-only  预检 + 演练就停下：本机照常服务，新机恢复、验证后停掉容器
#   --cutover        跳过演练直接切换（这台新机要已经演练过）；切换中断后也用它接着做
#   --dns            只做 DNS：列出要改的记录，确认改好后经公共 DNS 复核
# --no-start    演练只放文件、导库，不在新机上起容器（站点对比与 08 验收跳过）
# --verify-dns  不再询问，直接按「已经改好」复核 DNS
# rollback      DNS 切换前：新机停容器并暂停它的备份任务，本机恢复备份定时任务、启动切换时停掉的容器
# 新机要求：Debian 12、做完 init/、装好 docker、同一大版本的 MySQL、nginx（或宝塔）、opsget 固定在同一版本、没有业务数据；
# 本机能用密钥登录新机的 root（ops/setup-key-login）。新机没有 env.conf 或备份密码文件时从本机复制过去。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env MYSQL_DEFAULTS_FILE PANEL_VHOST_DIR
BACKUP_PASS_FILE=${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}
[ -n "$BACKUP_PASS_FILE" ] || die "配置项未填: BACKUP_PASS_FILE（或旧键 VW_PASS_FILE）"

usage() { sed -n '/^# 用法：/,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1; }

ACTION=migrate IP="" PORT=22 MODE="" NOSTART=0 VERIFY_DNS=0
case "${1:-}" in
  status|rollback) ACTION=$1; shift ;;
  ''|-h|--help) usage ;;
esac
set_mode() { [ -z "$MODE" ] || die "--check / --rehearse-only / --cutover / --dns 只能选一个"; MODE=$1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-port) PORT=${2:-}; shift ;;
    --ssh-port=*) PORT=${1#*=} ;;
    --check) set_mode check ;;
    --rehearse-only) set_mode rehearse ;;
    --cutover) set_mode cutover ;;
    --dns) set_mode dns ;;
    --no-start) NOSTART=1 ;;
    --verify-dns) VERIFY_DNS=1 ;;
    -h|--help) usage ;;
    -*) die "未知选项: $1" ;;
    *) [ -z "$IP" ] || die "多余的参数: $1"; IP=$1 ;;
  esac
  shift
done
MODE=${MODE:-full}

WORK=/root/live-migrate                        # 本机：包、日志、known_hosts、回滚脚本（700）
STATE_DIR=/var/lib/ops-scripts
ST=$STATE_DIR/live-migrate.state
RIN=/root/live-migrate-in                      # 新机：收包的目录
BIN=/usr/local/bin
TS=$(date -u +%Y%m%d%H%M%S)
# 新机上 restore-from-backup 与 08 要的键（它们头部的 ENV-REQUIRED）：新机缺了就用本机的值补上
NEED=("BACKUP_PASS_FILE|VW_PASS_FILE" DB_CLIENT_HOST MYSQL_DEFAULTS_FILE PANEL_VHOST_DIR PANEL_CERT_DIR)
# 公共 DNS 复核用的 DoH（JSON 接口），空格分隔
DOH=${LIVE_MIGRATE_DOH:-https://cloudflare-dns.com/dns-query https://dns.google/resolve}

# ── 状态：一行一条，制表符分隔（最后一条 PHASE 是当前阶段）──────
# ID / TARGET ip port / PHASE / REHEARSAL 时间 包目录 / CUTOVER 时间 包目录 / STOPPED 容器 / SITE 域名 旧机状态码
st_add()  { mkdir -p "$STATE_DIR"; local IFS=$'\t'; printf '%s\n' "$*" >> "$ST"; }
st_rows() { [ -f "$ST" ] && awk -F'\t' -v k="$1" '$1 == k' "$ST"; }
st_get()  { st_rows "$1" | tail -1 | cut -f2-; }
phase()   { st_get PHASE; }
phase_label() {
  case "${1:-$(phase)}" in
    started) echo "已开始（预检通过）" ;;
    rehearsed) echo "已演练" ;;
    cutover-started) echo "切换中：本机已停写" ;;
    cutover-done) echo "已切换，等 DNS" ;;
    dns-done) echo "DNS 已切换，迁移完成" ;;
    rolled-back) echo "已回滚" ;;
    '') echo "未开始" ;;
    *) echo "$1" ;;
  esac
}

# ── 代理：同一份函数在本机直接跑，经 ssh 以 bash -s 在新机（和落地机等）跑，回滚脚本里也原样嵌一份 ──
# 不依赖公共库：对面不一定装了，装了也不一定同一版本
lm_agent() {
  local act=${1:-} r=()
  shift
  # shellcheck disable=SC1091
  [ -r /etc/ops-scripts/env.conf ] && . /etc/ops-scripts/env.conf >/dev/null 2>&1
  command -v mysql >/dev/null 2>&1 || { [ -x /www/server/mysql/bin/mysql ] && PATH="/www/server/mysql/bin:$PATH"; }
  case "$act" in
    probe) lm_probe "$@" ;;
    prep)  mkdir -p /var/lib/ops-scripts && printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%FT%TZ)" > /var/lib/ops-scripts/live-migrate.target ;;
    sha)   sha256sum "$@" | cut -c1-64 ;;
    running) command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null ;;
    stop|start) lm_svc "$act" "$@" ;;
    standby)  # 新机退回待命：停掉全部容器，暂停备份定时任务（演练结束、回滚时用）
      command -v docker >/dev/null 2>&1 && mapfile -t r < <(docker ps --format '{{.Names}}' 2>/dev/null)
      lm_svc stop "${r[@]}"; lm_cron pause ;;
    pause-cron)  lm_cron pause ;;
    resume-cron) lm_cron resume ;;
    restore)  # restore <操作者 IP 或 -> <restore-from-backup 参数...>
      # 恢复脚本核对「当前 SSH 会话的来源 IP」在不在原机的放行名单里；经本机转过来时那是本机的 IP，
      # 要核对的其实是操作者自己的（本机的由 allow-me 临时放行）
      if [ "$1" = - ]; then unset SSH_CONNECTION; else export SSH_CONNECTION="$1 0 0 0"; fi
      shift
      OPS_YES=1 opsget migrate/restore-from-backup restore "$@" ;;
    check)  opsget migrate/restore-from-backup check "$@" ;;
    verify) opsget migrate/08-post-start-check ;;
    tunnel) lm_tunnel "$@" ;;
    allow-me)   lm_allow_me "$@" ;;
    unallow-me) lm_ufw_del "live-migrate $1" ;;
    peer-allow|peer-drop) lm_peer "${act#peer-}" "$@" ;;
    *) echo "未知动作: $act" >&2; return 2 ;;
  esac
}

lm_probe() {  # lm_probe [必填键...]：这台机器的状况，每行一个 键=值
  local mf pf k a v miss="" d dirs=()
  ( . /etc/os-release 2>/dev/null; printf 'os=%s %s\n' "${ID:-?}" "${VERSION_ID:-?}" )
  printf 'hostname=%s\n' "$(hostname)"
  printf 'init=%s\n' "$([ -e /usr/local/bin/04-verify.sh ] && echo yes || echo no)"
  v=""; command -v opsget >/dev/null 2>&1 && v=$(sed -n 's/^# VERSION: //p' "$(command -v opsget)" | head -1)
  printf 'opsget=%s\nref=%s\n' "$v" "$(head -n1 /etc/ops-scripts/ref 2>/dev/null)"
  printf 'env=%s\n' "$([ -f /etc/ops-scripts/env.conf ] && echo yes || echo no)"
  for k in "$@"; do
    v=""; for a in ${k//|/ }; do [ -n "${!a:-}" ] && v=1; done
    [ -n "$v" ] || miss="$miss ${k%%|*}"
  done
  printf 'env_missing=%s\n' "${miss# }"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker=yes\nrunning=%s\n' "$(docker ps -q 2>/dev/null | wc -l)"
  else
    printf 'docker=no\nrunning=0\n'
  fi
  mf=${MYSQL_DEFAULTS_FILE:-/root/.my.cnf}
  printf 'mysql_cnf=%s\n' "$mf"
  printf 'mysql=%s\n' "$(mysql --defaults-file="$mf" -N -B -e 'SELECT VERSION()' 2>/dev/null | head -1)"
  printf 'dbs=%s\n' "$(mysql --defaults-file="$mf" -N -B -e "SELECT GROUP_CONCAT(SCHEMA_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys')" 2>/dev/null | grep -v '^NULL$' | head -1)"
  v=${METRICS_DB_NAME:-metrics}; [[ $v =~ ^[A-Za-z0-9_]+$ ]] || v=metrics
  printf 'db_kb=%s\n' "$(mysql --defaults-file="$mf" -N -B -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1024), 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys','$v')" 2>/dev/null | head -1)"
  v=$(command -v nginx 2>/dev/null); [ -z "$v" ] && [ -x /www/server/nginx/sbin/nginx ] && v=/www/server/nginx/sbin/nginx
  printf 'nginx=%s\npanel=%s\n' "$v" "$([ -x /etc/init.d/bt ] && echo yes || echo no)"
  printf 'free_kb=%s\n' "$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
  for d in ${SVC_VW_DIR:-} ${SVC_KOMARI_DATA:-} ${SVC_SUBCONV_DIR:-} ${SVC_XBOARD_DIR:-} ${PANEL_ROOT:-} ${WWWROOT:-}; do
    [ -d "$d" ] && dirs+=("$d")
  done
  v=0; [ ${#dirs[@]} -gt 0 ] && v=$(du -skc "${dirs[@]}" 2>/dev/null | tail -1 | cut -f1)
  printf 'data_kb=%s\n' "${v:-0}"
  pf=${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}
  v=""; [ -n "$pf" ] && [ -r "$pf" ] && v=$(head -n1 "$pf" | tr -d '\r' | sha256sum | cut -c1-64)
  printf 'pass_file=%s\npass_sha=%s\n' "$pf" "$v"
  printf 'dr_state=%s\n' "$(awk -F'\t' '$1 == "MODE" { m = $2 } END { print m }' /var/lib/ops-scripts/dr-restore.state 2>/dev/null)"
  printf 'lm_target=%s\n' "$(cut -f1 /var/lib/ops-scripts/live-migrate.target 2>/dev/null | head -1)"
  v=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')
  [ -n "$v" ] || v=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{ print $2; exit }')
  printf 'ssh_port=%s\n' "${v:-22}"
  printf 'ipv6=%s\n' "$(ip -6 -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')"
  printf 'egress=%s\n' "$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null | grep -E '^[0-9.]+$')"
  a="" v=""
  for d in vw-fullbackup xboard-fullbackup; do
    [ -x "/usr/local/bin/$d.sh" ] || continue
    if grep -q -- '--local-only' "/usr/local/bin/$d.sh"; then a="$a $d"; else v="$v $d"; fi
  done
  printf 'local_only=%s\nno_local_only=%s\n' "${a# }" "${v# }"
}

lm_svc() {  # lm_svc stop|start <容器名...>
  local a=$1 n rc=0
  shift
  for n in "$@"; do
    [ -n "$n" ] || continue
    if docker "$a" "$n" >/dev/null 2>&1; then echo "  ✓ $a $n"; else echo "  ✗ $a $n 失败"; rc=1; fi
  done
  return "$rc"
}

lm_cron_re() {  # 调用备份脚本的 cron 行：<名字>-fullbackup，加上 env.conf 的 BACKUP_SCRIPTS
  local n alt='[A-Za-z0-9_-]+-fullbackup'
  for n in ${BACKUP_SCRIPTS:-}; do
    n=${n##*/}; n=${n%.sh}
    [[ $n =~ ^[A-Za-z0-9_.-]+$ ]] && alt="$alt|${n//./[.]}"
  done
  printf '(^|[ \t/])(%s)([.]sh)?([ \t;|&>]|$)' "$alt"
}

lm_cron() {  # lm_cron pause|resume：备份任务的行加上 / 去掉 #MIGRATE-PAUSED 前缀（与 03 同一个标记），别的行不动
  local re cur new bak
  command -v crontab >/dev/null 2>&1 || return 0
  re=$(lm_cron_re)
  cur=$(mktemp); new=$(mktemp)
  if ! crontab -l > "$cur" 2>/dev/null; then echo "  没有 crontab"; rm -f "$cur" "$new"; return 0; fi
  if [ "$1" = pause ]; then
    awk -v re="$re" '/^[ \t]*#/ || !/[^ \t]/ { print; next } $0 ~ re { print "#MIGRATE-PAUSED " $0; next } { print }' "$cur" > "$new"
  else
    awk -v re="$re" 'index($0, "#MIGRATE-PAUSED ") == 1 && substr($0, 17) ~ re { print substr($0, 17); next } { print }' "$cur" > "$new"
  fi
  if cmp -s "$cur" "$new"; then
    echo "  crontab 不用改"
  else
    mkdir -p /root/ops-backups; bak=/root/ops-backups/crontab.$(date -u +%Y%m%d%H%M%S)
    cp "$cur" "$bak" && chmod 600 "$bak"
    if crontab "$new"; then
      diff "$cur" "$new" | sed -n 's/^> /  → /p'
      echo "  （改前的 crontab 在 $bak）"
    else
      echo "  ✗ 写 crontab 失败（原内容在 $bak）"; rm -f "$cur" "$new"; return 1
    fi
  fi
  rm -f "$cur" "$new"
}

lm_tunnel() {  # lm_tunnel <单元> [本地 URL]
  local u=$1 c=""
  case "$u" in *.service) ;; *) u=$u.service ;; esac
  printf 'unit=%s\n' "$(systemctl is-active "$u" 2>/dev/null || true)"
  [ -n "${2:-}" ] && c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$2" 2>/dev/null)
  printf 'http=%s\n' "${c:-000}"
}

lm_ufw_del() {  # lm_ufw_del <注释> [来源 IP] [端口]：按编号删带这个注释（或这个来源 + 端口）的放行规则
  local tag=$1 ip=${2:-} p=${3:-} S="" n
  [ "$(id -u)" = 0 ] || S="sudo -n"
  command -v ufw >/dev/null 2>&1 || return 0
  for n in $($S ufw status numbered 2>/dev/null | sed -nE 's/^\[ *([0-9]+)\] +/\1 /p' \
             | awk -v t="# $tag" -v ip="$ip" -v p="$p" '
                 (t != "# " && index($0, t)) { print $1; next }
                 (ip != "" && $3 == "ALLOW" && $5 == ip && ($2 == p || $2 == p "/tcp")) { print $1 }' | sort -rn); do
    $S ufw --force delete "$n" >/dev/null && echo "  - 删掉放行规则 #$n"
  done
}

lm_allow_me() {  # 新机上临时放行本机（旧机）连 SSH：恢复放回的是原机的放行名单，里面没有原机自己
  local id=$1 me=${SSH_CONNECTION%% *} cur=${SSH_CONNECTION##* } p ports
  command -v ufw >/dev/null 2>&1 || { echo "  新机没有 ufw，不用放行"; return 0; }
  [ -n "$me" ] || { echo "  ✗ 拿不到本机的来源 IP（SSH_CONNECTION）"; return 1; }
  # 现在连的端口，加上放回的 sshd_config 里的端口（重启 SSH 后生效的那个）
  ports=$(printf '%s\n' "$cur" "$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{ print $2 }')" | grep -E '^[0-9]+$' | sort -u)
  for p in $ports; do
    ufw allow from "$me" to any port "$p" proto tcp comment "live-migrate $id" >/dev/null \
      && echo "  ✓ 新机临时放行 $me → SSH 端口 $p（注释 live-migrate $id，迁移完成后删掉）"
  done
}

lm_peer() {  # lm_peer allow|drop <新前置机 IP>：落地机等机器上，照本机（旧前置机）在 SSH 放行名单里的规则给新 IP 放行 / 删掉旧 IP
  local mode=$1 new=$2 me=${SSH_CONNECTION%% *} S="" rules=/etc/ufw/user.rules ports p esc
  [ "$(id -u)" = 0 ] || S="sudo -n"
  if ! command -v ufw >/dev/null 2>&1 || ! $S test -r "$rules"; then echo "result=no-ufw"; return 0; fi
  esc=${me//./\\.}
  ports=$($S grep -E -- "^-A ufw-user-input .*-j ACCEPT" "$rules" | grep -E -- "-s $esc(/32)? " \
          | grep -oE -- '--dport [0-9]+' | awk '{ print $2 }' | sort -u)
  [ -n "$ports" ] || { echo "result=not-listed"; return 0; }
  # sshd_config 里按来源 IP 写的 Match Address 块（给前置机单开的设置）：只提示，不自动改
  $S grep -lE "^[[:space:]]*Match[[:space:]].*Address[[:space:]].*${esc}([,[:space:]/]|$)" \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/sshd_match=/'
  for p in $ports; do
    if [ "$mode" = allow ]; then
      if $S grep -qE -- "--dport $p .*-s ${new//./\\.}(/32)? |-s ${new//./\\.}(/32)? .*--dport $p " "$rules"; then
        echo "have=$p"
      else
        $S ufw allow from "$new" to any port "$p" proto tcp comment "front host (live-migrate)" >/dev/null && echo "added=$p"
      fi
    else
      # 只在新 IP 已经放行了的端口上删旧的：别把前置机整个关在外面
      $S grep -qE -- "-s ${new//./\\.}(/32)? " "$rules" || { echo "keep=$p"; continue; }
      lm_ufw_del "" "$me" "$p" >/dev/null && echo "dropped=$p"
    fi
  done
}

AGENT_FUNCS=(lm_agent lm_probe lm_svc lm_cron_re lm_cron lm_tunnel lm_ufw_del lm_allow_me lm_peer)
agent_src() {
  declare -f "${AGENT_FUNCS[@]}"
  # shellcheck disable=SC2016  # 原样发到对面，由对面的 bash 展开
  printf '%s\n' 'lm_agent "$@"'
}

# ── SSH：本次迁移专用的 known_hosts 与一条复用的主连接 ───────
# 只用密钥（BatchMode，不会问密码）：两步验证只管密码登录，密钥登录不问验证码。
# 几十条命令都走同一条连接，不用每次重新握手
ssh_init() {
  mkdir -p "$WORK/logs" "$WORK/pkgs"; chmod 700 "$WORK" "$WORK/logs" "$WORK/pkgs"
  KH=$WORK/known_hosts
  SSH_BASE=(-p "$PORT" -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6
            -o UserKnownHostsFile="$KH" -o LogLevel=ERROR -o ControlPath="$WORK/cm-%C")
  SSH_OPTS=("${SSH_BASE[@]}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ControlMaster=no)
}
ssh_master() {
  ssh "${SSH_BASE[@]}" -O check "root@$IP" >/dev/null 2>&1 && return 0
  ssh "${SSH_BASE[@]}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    -o ControlMaster=yes -o ControlPersist=4h -fN "root@$IP" 2>"$WORK/ssh.err"
}
ssh_close() { [ ${#SSH_BASE[@]} -gt 0 ] && ssh "${SSH_BASE[@]}" -O exit "root@$IP" >/dev/null 2>&1; return 0; }
rsh()    { ssh "${SSH_OPTS[@]}" "root@$IP" "$@"; }
ragent() { agent_src | rsh "bash -s -- $(printf '%q ' "$@")"; }
stream() {  # stream <日志名> <命令...>：输出缩进显示并存进日志，返回命令的退出码
  local log="$WORK/logs/$1-$TS.log"; shift
  "$@" 2>&1 | tee -a "$log" | sed 's/^/  │ /'
  return "${PIPESTATUS[0]}"
}

# 新机恢复后，新连接看到的是本机的主机密钥（恢复放回了原机的）：提前记进专用 known_hosts，免得报主机密钥变更
kh_add_self() {
  local name f k
  if [ "$PORT" = 22 ]; then name=$IP; else name="[$IP]:$PORT"; fi
  for f in /etc/ssh/ssh_host_*_key.pub; do
    [ -f "$f" ] || continue
    k=$(awk '{ print $1, $2 }' "$f")
    grep -qF "$k" "$KH" 2>/dev/null || printf '%s %s\n' "$name" "$k" >> "$KH"
  done
  return 0
}

upload() {  # upload <本地文件> <新机路径> [append]：新建的文件 600、目录 700
  local src=$1 dst=$2
  [[ $dst =~ ^/[A-Za-z0-9._/-]+$ ]] || die "新机路径不合规：$dst"
  if [ "${3:-}" = append ]; then
    rsh "umask 077; cat >> '$dst'" < "$src"
  else
    rsh "umask 077; mkdir -p '$(dirname "$dst")' && cat > '$dst.lm-part' && mv -f '$dst.lm-part' '$dst'" < "$src"
  fi
}

# ── 小工具 ──────────────────────────────────────────────────
kb() { numfmt --from-unit=1024 --to=iec "${1:-0}" 2>/dev/null || echo "${1:-0}K"; }
dw() { local s=$1 w=${1//[ -~]/}; echo $(( ${#s} + ${#w} )); }   # 显示宽度：中文记 2 列
pad() { local n; n=$(( $2 - $(dw "$1") )); [ "$n" -lt 1 ] && n=1; printf '%s%*s' "$1" "$n" ''; }
row() { printf '  %s%s%s\n' "$(pad "$1" 16)" "$(pad "$2" 30)" "$3"; }
my_series() { printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+'; }
my_flavor() { case "$1" in *MariaDB*|*mariadb*) echo MariaDB ;; *) echo MySQL ;; esac; }
is_err() { case "$1" in 000|5??|'') return 0 ;; esac; return 1; }
site_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$1:443:$2" "https://$1/" 2>/dev/null; }
domains() {  # DOMAINS 填了用它，否则扫 vhost
  if [ -n "${DOMAINS:-}" ]; then printf '%s\n' $DOMAINS; else scan_vhost_domains; fi
}
ask_tty() {  # 只认终端里亲手输入的 yes（OPS_YES 不算）：「DNS 已经改好」这一步永远人工确认
  local a
  printf '  %s (yes/no) ' "$1"
  { read -r a </dev/tty; } 2>/dev/null || { echo; return 1; }
  [ "$a" = yes ]
}
my_ips() {  # 本机的各个 IPv4：配置的公网 IP、出口、网卡上的
  { printf '%s\n' "${OLD_HOST_IP:-}" "${O[egress]:-}"; hostname -I 2>/dev/null | tr ' ' '\n'; } \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u
}

# ── 预检 ────────────────────────────────────────────────────
declare -A O=() N=()
facts() { local -n _f=$1; local l; while IFS= read -r l; do [[ $l == ?*=* ]] && _f[${l%%=*}]=${l#*=}; done; }

init_id() {
  local t
  t=$(st_get TARGET | cut -f1)
  ID="" NEWID=0
  if [ -n "$t" ] && [ "$t" != "$IP" ]; then
    case "$(phase)" in
      cutover-started|cutover-done) die "本机正在往 $t 迁移（$(phase_label)）：要换目标先 live-migrate.sh rollback" ;;
      dns-done) die "本机已经迁到 $t（DNS 已切换），不再是在用的机器" ;;
    esac
    NEWID=1
  elif [ -n "$t" ]; then
    ID=$(st_get ID)
  fi
  [ -n "$ID" ] || { ID="lm-$TS"; NEWID=1; }
}

persist() {  # 确认开始之后才在本机写状态
  if [ "$NEWID" = 1 ]; then
    [ -f "$ST" ] && mv "$ST" "$ST.old.$TS"
    st_add ID "$ID"; NEWID=0
  fi
  [ "$(st_get TARGET)" = "$IP"$'\t'"$PORT" ] || st_add TARGET "$IP" "$PORT"
}

probe_new() {
  local out rc
  if ! ssh_master; then
    sed 's/^/  /' "$WORK/ssh.err" 2>/dev/null
    grep -q 'IDENTIFICATION HAS CHANGED' "$WORK/ssh.err" 2>/dev/null \
      && log "新机的主机密钥和上次记下的不同（重装过？）：确认无误后删掉 $KH 再来"
    die "连不上 root@$IP:$PORT。依次检查：本机到新机的密钥登录（opsget ops/setup-key-login $IP $PORT）；新机的放行名单里有没有本机；新机重启过的话 SSH 端口可能已换成原机的 ${O[ssh_port]:-（见本机 sshd_config）}（--ssh-port）"
  fi
  out=$(ragent probe "${NEED[@]}" 2>"$WORK/ssh.err"); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] || { sed 's/^/  /' "$WORK/ssh.err"; die "在新机上跑检查失败（退出码 $rc）"; }
  facts N <<<"$out"
  kh_add_self
}

preflight() {
  local need oldneed yn R=() copies=3
  section "预检"
  ssh_init
  facts O < <(lm_agent probe "${NEED[@]}")
  probe_new
  ok "密钥登录 root@$IP:$PORT"
  NEW_EGRESS=${N[egress]:-$IP}
  [ "$MODE" = dns ] && return 0              # 已经切换过：只要两边的现状，不再做迁移前的检查

  [ "${N[os]}" = "debian 12" ] || R+=("新机系统是 ${N[os]:-未知}，要 Debian 12")
  [ "${N[init]}" = yes ] || R+=("新机还没做完 init/（没有 /usr/local/bin/04-verify.sh）：opsget init/run 按 00→04 做完")
  if [ -z "${N[opsget]}" ]; then
    R+=("新机没装 opsget：按仓库 README「快速开始」装引导器，再 opsget --pin ${O[ref]:-<tag>} && opsget -u")
  elif [ "${N[ref]}" != "${O[ref]}" ]; then
    R+=("opsget 固定的版本不同：本机 ${O[ref]:-main（未固定）}，新机 ${N[ref]:-main（未固定）}。新机上 opsget --pin ${O[ref]:-<tag>} && opsget -u")
  elif [ -z "${O[ref]}" ]; then
    warn "两台都没固定版本（main）：迁移期间 main 上的新提交会被装上；生产机应先固定（README「固定版本」）"
  fi
  [ "${O[docker]}" = yes ] && [ "${N[docker]}" != yes ] && R+=("新机没有可用的 docker（本机有）：先装好并 systemctl enable --now docker")
  if [ -z "${N[mysql]}" ]; then
    R+=("新机的 MySQL 连不上（用的凭据文件 ${N[mysql_cnf]}）：先装好 MySQL（版本照本机 ${O[mysql]:-?}）并配好凭据文件")
  elif [ -n "${O[mysql]}" ]; then
    if [ "$(my_flavor "${O[mysql]}")" != "$(my_flavor "${N[mysql]}")" ] || [ "${O[mysql]%%.*}" != "${N[mysql]%%.*}" ]; then
      R+=("MySQL 大版本不同：本机 ${O[mysql]}，新机 ${N[mysql]}。装同一大版本（dump 与账号的认证写法跨大版本不保证能导）")
    elif [ "$(my_series "${O[mysql]}")" != "$(my_series "${N[mysql]}")" ]; then
      warn "MySQL 小版本系列不同（本机 ${O[mysql]}，新机 ${N[mysql]}）：认证插件、默认值可能有差别，演练时留意建账号的输出"
    fi
  fi
  [ -n "${O[nginx]}" ] && [ -z "${N[nginx]}" ] && R+=("新机没有 nginx（本机有 ${O[nginx]}）")
  [ "${O[panel]}" = yes ] && [ "${N[panel]}" != yes ] && R+=("新机没装宝塔面板（本机有）：站点配置、证书与面板数据都在面板目录里")
  # 新机上已有本次演练的数据时，剩下要放的只有切换那一份和暂存
  [ "${N[lm_target]}" = "$ID" ] && [ -n "${N[dr_state]}" ] && copies=2
  need=$(( copies * (${O[data_kb]:-0} + ${O[db_kb]:-0}) + 1048576 ))
  [ "${N[free_kb]:-0}" -ge "$need" ] \
    || R+=("新机 / 只剩 $(kb "${N[free_kb]:-0}")，要 $(kb "$need")：本机数据约 $(kb $(( ${O[data_kb]:-0} + ${O[db_kb]:-0} )))，演练与切换各放一份、解开的包还要暂存一份（已演练过的少一份），再留 1G")
  oldneed=$(( ${O[data_kb]:-0} + ${O[db_kb]:-0} + 524288 ))
  [ "${O[free_kb]:-0}" -ge "$oldneed" ] || R+=("本机 / 只剩 $(kb "${O[free_kb]:-0}")，现做加密包至少要 $(kb "$oldneed")")
  [ -n "${O[pass_sha]}" ] || R+=("本机读不到备份密码文件 $BACKUP_PASS_FILE")
  PASS_COPY=0
  if [ -z "${N[pass_sha]}" ]; then
    PASS_COPY=1
  elif [ "${N[pass_sha]}" != "${O[pass_sha]}" ]; then
    R+=("新机的备份密码（${N[pass_file]}）和本机的不一样：包解不开，新机以后做的备份也会用另一个密码加密。换成同一个再来")
  fi
  OURS=0
  if [ "${N[dr_state]}" = drill ]; then
    R+=("新机上有一次没清理的恢复演练：先在新机上 opsget migrate/restore-from-backup teardown")
  elif [ "${N[running]:-0}" -gt 0 ] || [ -n "${N[dbs]}" ] || [ -n "${N[dr_state]}" ]; then
    if [ -n "${N[lm_target]}" ] && [ "${N[lm_target]}" = "$ID" ]; then
      OURS=1
    else
      R+=("新机上已经有数据（在跑的容器 ${N[running]:-0} 个；业务库 ${N[dbs]:-无}；恢复记录 ${N[dr_state]:-无}），不是本次迁移留下的。一键迁移只往空机器上迁")
    fi
  fi
  read -r -a BK_USE <<<"${O[local_only]}"
  [ -z "${O[no_local_only]}" ] || R+=("本机的 ${O[no_local_only]} 太旧，不支持 --local-only：opsget -i backup/<名字> 更新（vw 2.6.0、xboard 2.5.0 起）")
  [ ${#BK_USE[@]} -gt 0 ] || R+=("本机没装 vw-fullbackup / xboard-fullbackup：迁移靠它们现做包")

  echo
  row 项目 "本机（旧机）" 新机
  row 主机 "${O[hostname]}" "${N[hostname]}（$IP:$PORT，出口 $NEW_EGRESS）"
  row 系统 "${O[os]}" "${N[os]}"
  row "init/ 做完" - "${N[init]}"
  row "opsget 版本" "${O[opsget]:-无} @ ${O[ref]:-main}" "${N[opsget]:-无} @ ${N[ref]:-main}"
  row docker "${O[docker]}" "${N[docker]}"
  row MySQL "${O[mysql]:-连不上}" "${N[mysql]:-连不上}"
  row nginx "${O[nginx]:-无}" "${N[nginx]:-无}"
  row 宝塔面板 "${O[panel]}" "${N[panel]}"
  row "/ 可用" "$(kb "${O[free_kb]:-0}")" "$(kb "${N[free_kb]:-0}")（需要 $(kb "$need")）"
  row 要迁的数据 "目录 $(kb "${O[data_kb]:-0}") + 库 $(kb "${O[db_kb]:-0}")" -
  row "SSH 端口" "${O[ssh_port]}（恢复后新机也用它）" "${PORT}"
  if [ "$PASS_COPY" = 1 ]; then yn="新机没有，演练开始时复制过去"
  elif [ "${N[pass_sha]}" = "${O[pass_sha]}" ]; then yn="一致"; else yn="不一致"; fi
  row 备份密码 "$BACKUP_PASS_FILE" "$yn"
  if [ "$OURS" = 1 ]; then yn="本次迁移上次恢复出来的（重跑时覆盖）"
  elif [ "${N[running]:-0}" -gt 0 ] || [ -n "${N[dbs]}" ] || [ -n "${N[dr_state]}" ]; then yn="有"; else yn="没有"; fi
  row 新机已有数据 - "$yn"
  row 出包脚本 "${BK_USE[*]:-无}" -
  if [ "${N[env]}" != yes ]; then row env.conf - "新机没有，演练开始时复制本机的"
  elif [ -n "${N[env_missing]}" ]; then row env.conf - "缺 ${N[env_missing]}，演练开始时用本机的值补上"; fi

  if [ ${#R[@]} -gt 0 ]; then
    echo
    printf '  ✗ %s\n' "${R[@]}"
    die "预检没通过（${#R[@]} 项）。两台机器都没有改动"
  fi
  ok "预检通过"
}

show_plan() {
  local s
  section "迁移计划"
  cat <<EOF
  ${O[hostname]}（本机） → ${N[hostname]}（$IP）

  1. 演练（本机照常服务，不停任何东西）
     本机用 ${BK_USE[*]} 现做加密包到 $WORK/pkgs（--local-only：不上传、不清理），经 SSH 直传新机 $RIN；
     新机 restore-from-backup --no-cron$([ "$NOSTART" = 1 ] && echo ' --no-start')（起服务但不装定时任务，免得新机往网盘传包）→ check 逐项比对 →
     08 验收 → 本机经 --resolve 分别访问两台、逐站对比 → 新机停掉容器，只留数据
  2. 切换（再确认一次；从这里起服务中断，直到 DNS 切过去）
     写回滚脚本 → 暂停本机的备份定时任务（#MIGRATE-PAUSED，与 03 同一个标记）→ 停本机全部容器 →
     再做一次包 → 传到新机 → restore --force 并启动（这次装定时任务，新机接手备份）→ 08 验收、逐站对比、隧道
  3. DNS（人工）：列出要改的记录，你在 DNS 服务商那里改好后回来确认，再经公共 DNS 复核
  回滚：DNS 切换前任何时候 live-migrate.sh rollback（或 bash $WORK/rollback.sh）

  SSH 放行名单：
  - 新机恢复的是本机的名单（里面没有本机自己）：每次恢复后在新机上临时放行本机 IP，迁移完成后删掉
  - 落地机等只放行本机的机器：演练开始时照本机的规则给新机出口 $NEW_EGRESS 放行，迁移完成后删掉本机的
  - 新机的 SSH、防火墙在迁移完成前都不要重载、不要重启新机（恢复的手动步骤里有这一条，等 DNS 复核通过再做）

  不在迁移范围（与从备份包恢复相同）：Komari 的监控历史（指标库 ${METRICS_DB_NAME:-metrics} 不进包）；
  落地机上的 new-api（它不搬，隧道换成从新机连过去）；宝塔面板里的站点记录要认领、证书续期要核对
EOF
  s=""
  [ "${N[env]}" != yes ] && s="$s 复制 env.conf；"
  [ "${N[env]}" = yes ] && [ -n "${N[env_missing]}" ] && s="$s env.conf 补 ${N[env_missing]}；"
  [ "$PASS_COPY" = 1 ] && s="$s 放备份密码文件；"
  [ -n "$s" ] && printf '\n  新机上会先做：%s\n' "${s% ；}"
  return 0
}

# ── 演练与切换的步骤 ────────────────────────────────────────
bootstrap_new() {
  local k f v ok_keys=""
  section "新机准备"
  ragent prep "$ID" "$(hostname)" || die "新机上写不了 /var/lib/ops-scripts"
  if [ "${N[env]}" != yes ]; then
    f=$(mktemp); cp "$OPS_ENV_FILE" "$f"
    # 凭据文件的路径两台可以不同：新机连得上 MySQL 用的是哪个就写哪个
    [ "${N[mysql_cnf]}" != "$MYSQL_DEFAULTS_FILE" ] && printf "MYSQL_DEFAULTS_FILE='%s'\n" "${N[mysql_cnf]}" >> "$f"
    upload "$f" /etc/ops-scripts/env.conf || die "env.conf 传不到新机"
    rm -f "$f"
    ok "新机没有 env.conf：复制了本机的（服务路径两台一样；之后恢复只补空键）"
  elif [ -n "${N[env_missing]}" ]; then
    f=$(mktemp)
    for k in ${N[env_missing]}; do
      [ "$k" = BACKUP_PASS_FILE ] && { printf "BACKUP_PASS_FILE='%s'\n" "$BACKUP_PASS_FILE" >> "$f"; ok_keys="$ok_keys $k"; continue; }
      v=${!k:-}; [ -n "$v" ] || continue
      printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}" >> "$f"; ok_keys="$ok_keys $k"
    done
    upload "$f" /etc/ops-scripts/env.conf append || die "补 env.conf 失败"
    rm -f "$f"
    ok "新机 env.conf 补上了本机的:$ok_keys"
  fi
  if [ "$PASS_COPY" = 1 ]; then
    upload "$BACKUP_PASS_FILE" "${N[pass_file]:-$BACKUP_PASS_FILE}" || die "备份密码文件传不到新机"
    ok "备份密码文件复制到新机 ${N[pass_file]:-$BACKUP_PASS_FILE}（600）"
  fi
}

PEERS=()
peer_list() {  # 落地机、LiteLLM 节点与主机清单里的其他机器：user@host port
  local l h p u seen
  seen=" $IP $NEW_EGRESS $(my_ips | tr '\n' ' ') "
  PEERS=()
  add() { case "$seen" in *" $2 "*) return ;; esac; seen="$seen$2 "; PEERS+=("$1@$2 ${3:-22}"); }
  [ -n "${NEWAPI_HOST:-}" ] && add root "$NEWAPI_HOST" "${NEWAPI_SSH_PORT:-22}"
  while IFS= read -r l; do
    l=${l%%#*}; l=${l//[[:space:]]/}; [ -n "$l" ] || continue
    u=root; [[ $l == *@* ]] && { u=${l%%@*}; l=${l#*@}; }
    h=${l%%:*}; p=22; [[ $l == *:* ]] && p=${l##*:}
    [[ $h =~ ^[A-Za-z0-9.-]+$ && $p =~ ^[0-9]+$ ]] && add "$u" "$h" "$p"
  done < <(cat "$HOME/.vps-hosts.txt" 2>/dev/null)
  if [ -n "${LITELLM_HOST:-}" ]; then
    p=$(awk -F: -v h="$LITELLM_HOST" '$0 ~ h { print $NF }' "$HOME/.vps-hosts.txt" 2>/dev/null | head -1)
    add root "$LITELLM_HOST" "${p:-22}"
  fi
  unset -f add
}

peers() {  # peers allow|drop：其他机器的 SSH 放行名单里，本机（旧前置机）换成新机
  local mode=$1 x t p out n=0
  peer_list
  [ ${#PEERS[@]} -gt 0 ] || { log "没有落地机 / 主机清单，不用改别的机器的放行名单"; return 0; }
  for x in "${PEERS[@]}"; do
    t=${x% *} p=${x##* }
    if ! out=$(agent_src | ssh -p "$p" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "$t" \
                 "bash -s -- $(printf '%q ' "peer-$mode" "$NEW_EGRESS")" 2>&1); then
      warn "$t:$p 连不上：$(tail -1 <<<"$out")"
      [ "$mode" = allow ] && log "  自己上去执行：ufw allow from $NEW_EGRESS to any port <SSH端口> proto tcp"
      continue
    fi
    case "$out" in
      *result=no-ufw*)      log "$t：没有 ufw 规则文件，不用改" ;;
      *result=not-listed*)  log "$t：放行名单里没有本机（不按 IP 限制或走别的规则），不用改" ;;
      *)
        for p in $(sed -n 's/^added=//p' <<<"$out"); do ok "$t：放行新机 $NEW_EGRESS → SSH 端口 $p"; n=$((n + 1)); done
        for p in $(sed -n 's/^have=//p' <<<"$out"); do log "$t：新机 $NEW_EGRESS → $p 已经放行过"; done
        for p in $(sed -n 's/^dropped=//p' <<<"$out"); do ok "$t：删掉本机（旧前置机）→ SSH 端口 $p 的放行"; n=$((n + 1)); done
        for p in $(sed -n 's/^keep=//p' <<<"$out"); do warn "$t：新机还没放行，端口 $p 上本机的规则先留着"; done
        sed -n 's/^sshd_match=//p' <<<"$out" | while read -r p; do
          warn "$t 的 $p 里有 Match Address 写着本机的 IP：新机 $NEW_EGRESS 也要加进去（没有自动改）"
        done ;;
    esac
  done
  return 0
}

build_pkgs() {  # build_pkgs rehearsal|cutover：本机装好的备份脚本只在本地出包，放 PKGDIR
  local s pre rc f log
  PKGDIR="$WORK/pkgs/$1-$TS"
  mkdir -p "$PKGDIR" && chmod 700 "$PKGDIR"
  for s in "${BK_USE[@]}"; do
    case "$s" in vw-fullbackup) pre=srvbak ;; xboard-fullbackup) pre=xboard ;; *) continue ;; esac
    log="$WORK/logs/$1-$s-$TS.log"
    log "$BIN/$s.sh --local-only $PKGDIR"
    "$BIN/$s.sh" --local-only "$PKGDIR" > "$log" 2>&1; rc=$?
    f=$(ls -t "$PKGDIR/${pre}"_*.7z 2>/dev/null | head -1)
    if [ -z "$f" ]; then
      tail -n 15 "$log" | sed 's/^/  │ /'
      die "$s 没有生成包（退出码 $rc，完整输出在 $log）"
    fi
    grep -E '\[(WARN|FATAL)\]' "$log" | sed 's/^/  │ /'
    if [ "$rc" -eq 0 ]; then ok "$(basename "$f")（$(human "$f")）"
    else warn "$s 退出码 $rc（上面是它的告警），包已生成：$(basename "$f")"; fi
  done
}

send_pkgs() {  # send_pkgs <本地目录> <新机目录>：传 .7z 与 .sha256，新机上再算一遍 sha256
  local f n want got
  RPKGS=()
  for f in "$1"/*.7z; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    log "传 $n（$(human "$f")）→ $IP:$2/"
    upload "$f" "$2/$n" || die "传输失败：$n"
    [ -f "$f.sha256" ] && { upload "$f.sha256" "$2/$n.sha256" || die "传输失败：$n.sha256"; }
    want=$(sha256sum "$f" | cut -c1-64)
    got=$(ragent sha "$2/$n")
    [ "$got" = "$want" ] || die "$n 传到新机后 sha256 不一致（本机 $want，新机 ${got:-读不到}）"
    ok "$n：新机上的 sha256 一致"
    RPKGS+=("$2/$n")
  done
  [ ${#RPKGS[@]} -gt 0 ] || die "$1 里没有包"
}

new_restore() {  # new_restore rehearsal|cutover <restore 参数...>
  local tag=$1 rc op=${SSH_CONNECTION%% *}
  shift
  stream "$tag-restore" ragent restore "${op:--}" "$@"; rc=$?
  return "$rc"
}

allow_me() {
  log "新机临时放行本机连 SSH（恢复放回的放行名单里没有本机）"
  ragent allow-me "$ID" | sed 's/^/  /'
}

compare_sites() {  # compare_sites rehearsal|cutover：本机经 --resolve 分别访问旧机、新机，逐站对比
  local d oc nc mark
  SITE_BAD=0
  mapfile -t DOMS < <(domains)
  [ ${#DOMS[@]} -gt 0 ] || { warn "$PANEL_VHOST_DIR 里没有扫到域名（DOMAINS 也没填），跳过逐站对比"; return 0; }
  printf '  %s%s%s\n' "$(pad 域名 40)" "$(pad 旧机 8)" 新机
  for d in "${DOMS[@]}"; do
    if [ "$1" = rehearsal ]; then
      oc=$(site_code "$d" 127.0.0.1); st_add SITE "$d" "$oc"
    else
      oc=$(st_rows SITE | awk -F'\t' -v d="$d" '$2 == d { c = $3 } END { print c }')
    fi
    oc=${oc:--}
    if [ "$NOSTART" = 1 ] && [ "$1" = rehearsal ]; then
      printf '  %s%s%s\n' "$(pad "$d" 40)" "$(pad "$oc" 8)" "（--no-start，不比）"; continue
    fi
    nc=$(site_code "$d" "$IP")
    if [ "$nc" = "$oc" ]; then mark="一致"
    elif is_err "$nc" && ! is_err "$oc"; then mark="✗ 新机不通"; SITE_BAD=$((SITE_BAD + 1))
    else mark="不同"; fi
    printf '  %s%s%s  %s\n' "$(pad "$d" 40)" "$(pad "$oc" 8)" "$nc" "$mark"
  done
}

verify_new() {  # verify_new rehearsal|cutover：累计 PROBLEMS
  local rc chk diffs out u h
  PROBLEMS=0
  if [ "$1" = rehearsal ]; then
    log "新机 check：恢复之后与包逐项比对（恢复计划里还标着放置、冲突的就是没对上的）"
    chk="$WORK/logs/rehearsal-check-$TS.log"
    ragent check "${RPKGS[@]}" > "$chk" 2>&1
    diffs=$(grep -E '^  (放置|冲突|重导|替换·留bak|未知) ' "$chk")
    if [ -n "$diffs" ]; then
      warn "恢复后仍与包不一致的 $(wc -l <<<"$diffs") 项（完整输出 $chk）："
      sed 's/^  /    /' <<<"$diffs"
      PROBLEMS=$((PROBLEMS + $(wc -l <<<"$diffs")))
    else
      ok "恢复结果与包一致"
    fi
  fi
  if [ "$NOSTART" = 1 ] && [ "$1" = rehearsal ]; then
    log "--no-start：新机没起服务，08 验收与逐站对比跳过"
    compare_sites "$1"
    return 0
  fi
  log "新机 08 验收"
  stream "$1-verify" ragent verify; rc=$?
  [ "$rc" -eq 0 ] || { warn "08 验收有告警或失败（退出码 $rc）"; PROBLEMS=$((PROBLEMS + 1)); }
  log "本机经 --resolve 访问两台机器"
  compare_sites "$1"
  PROBLEMS=$((PROBLEMS + SITE_BAD))
  if [ -n "${NEWAPI_TUNNEL_UNIT:-}" ]; then
    out=$(ragent tunnel "$NEWAPI_TUNNEL_UNIT" "${NEWAPI_LOCAL_URL:-}" 2>/dev/null)
    u=$(sed -n 's/^unit=//p' <<<"$out"); h=$(sed -n 's/^http=//p' <<<"$out")
    if [ "$u" = active ] && ! is_err "${h:-000}"; then
      ok "新机到落地机的隧道 $NEWAPI_TUNNEL_UNIT：active，${NEWAPI_LOCAL_URL:-本地端} 返回 $h"
    else
      warn "新机到落地机的隧道不通（$NEWAPI_TUNNEL_UNIT：${u:-未知}，${NEWAPI_LOCAL_URL:-本地端}：${h:-000}）：落地机的放行名单、sshd 的 Match Address 里有没有新机 $NEW_EGRESS"
      PROBLEMS=$((PROBLEMS + 1))
    fi
  fi
}

write_rollback() {
  local f=$WORK/rollback.sh
  {
    printf '#!/usr/bin/env bash\n'
    printf '# live-migrate 回滚脚本（DNS 切换前用）：%s 从 %s 迁往 %s（%s）\n' "$(date -u '+%F %T UTC')" "$(hostname)" "$IP" "$ID"
    printf '# 新机停容器、暂停它的备份定时任务；本机恢复备份定时任务、启动切换时停掉的容器。\n'
    printf '# DNS 已经切到新机、新机接过写入之后别用它：会丢新机上的数据（见 migrate/README.md「DNS 切换之后要切回」）。\n'
    printf '# 只用密钥登录新机；新机连不上时第 1 步跳过，本机照样回滚。\n\n'
    declare -f "${AGENT_FUNCS[@]}"
    echo
    # shellcheck disable=SC2016  # 写进回滚脚本的代码，到那时再展开
    printf 'AGENT=$(declare -f %s; echo %q)\n' "${AGENT_FUNCS[*]}" 'lm_agent "$@"'
    printf 'SSH=(ssh %s -o StrictHostKeyChecking=yes -o BatchMode=yes -o ControlMaster=no root@%s)\n' "$(printf '%q ' "${SSH_BASE[@]}")" "$IP"
    printf 'RUN=(%s)\n\n' "$(printf '%q ' "${RUN[@]}")"
    cat <<'EOF'
echo "1/3 新机：停容器、暂停备份定时任务"
if ! printf '%s\n' "$AGENT" | "${SSH[@]}" 'bash -s -- standby'; then
  echo "  ✗ 新机连不上或执行失败。DNS 还没切，新机没有接流量；回滚照样继续，之后上新机 docker stop 全部容器、暂停备份定时任务"
fi
echo "2/3 本机：恢复备份定时任务"
lm_agent resume-cron
echo "3/3 本机：启动切换时停掉的容器"
lm_agent start "${RUN[@]}"
echo "回滚完成：DNS 没动过，流量一直在本机"
EOF
  } > "$f"
  chmod 700 "$f"
}

rehearse() {
  local rc args
  section "演练 1/5：本机现做加密包（照常服务；不上传、不清理）"
  build_pkgs rehearsal
  section "演练 2/5：传到新机"
  send_pkgs "$PKGDIR" "$RIN/rehearsal-$TS"
  section "演练 3/5：新机恢复（不装定时任务）"
  args=("${RPKGS[@]}" --no-cron)
  [ "$OURS" = 1 ] && args+=(--force)
  [ "$NOSTART" = 1 ] && args+=(--no-start)
  [ "$OURS" = 1 ] && log "新机上是本次迁移上次恢复出来的数据：带 --force 覆盖（原有的留 .bak）"
  new_restore rehearsal "${args[@]}"; rc=$?
  allow_me
  [ "$rc" -eq 0 ] || die "新机恢复失败（退出码 $rc，输出在 $WORK/logs/rehearsal-restore-$TS.log）。本机没有任何改动；修好后重跑演练"
  section "演练 4/5：核对"
  verify_new rehearsal
  section "演练 5/5：新机停容器（只留数据，等切换）"
  ragent standby | sed 's/^/  /'
  st_add REHEARSAL "$TS" "$PKGDIR"
  st_add PHASE rehearsed
  section "演练结果"
  if [ "$PROBLEMS" -eq 0 ]; then ok "没有发现差异"; else warn "发现 $PROBLEMS 处差异（见上）"; fi
  cat <<EOF
  - 新机恢复输出最后「还要手动做的事」里的重启 SSH、重载防火墙、重启机器，等迁移完成（DNS 复核通过）再做：
    重启后新机的 SSH 会换成本机的端口 ${O[ssh_port]}、按本机的放行名单放行（已临时加上本机）。真重启了，下次运行带 --ssh-port ${O[ssh_port]}
  - 本机没有任何改动，服务照常
EOF
}

cutover() {
  local rc n
  section "切换 1/6：回滚脚本"
  if [ "$(phase)" = cutover-started ] && [ -x "$WORK/rollback.sh" ]; then
    log "接着上次中断的切换：沿用已有的 $WORK/rollback.sh（里面是第一次切换前在跑的容器）"
  else
    mapfile -t RUN < <(lm_agent running)
    write_rollback
    for n in "${RUN[@]}"; do st_add STOPPED "$n"; done
    ok "$WORK/rollback.sh（DNS 切换前随时可用：live-migrate.sh rollback）"
    printf '  会停的容器：%s\n' "${RUN[*]:-（没有在跑的）}"
  fi
  st_add PHASE cutover-started
  section "切换 2/6：暂停本机的备份定时任务"
  ( lm_agent pause-cron )
  section "切换 3/6：停本机容器（停写）"
  mapfile -t RUN_NOW < <(lm_agent running)
  if [ ${#RUN_NOW[@]} -gt 0 ]; then ( lm_agent stop "${RUN_NOW[@]}" ); else log "没有在跑的容器"; fi
  [ -z "$(docker ps -q 2>/dev/null)" ] || warn "还有容器在跑：$(docker ps --format '{{.Names}}' | tr '\n' ' ')"
  section "切换 4/6：最终的包，传到新机"
  peers allow
  build_pkgs cutover
  send_pkgs "$PKGDIR" "$RIN/cutover-$TS"
  section "切换 5/6：新机恢复并启动（这次装定时任务）"
  new_restore cutover "${RPKGS[@]}" --force; rc=$?
  allow_me
  [ "$rc" -eq 0 ] || die "新机恢复失败（退出码 $rc，输出在 $WORK/logs/cutover-restore-$TS.log）。本机已停写：修好后 live-migrate.sh $IP --ssh-port $PORT --cutover 接着做，或 live-migrate.sh rollback 回到切换前"
  st_add CUTOVER "$TS" "$PKGDIR"
  section "切换 6/6：验证"
  verify_new cutover
  st_add PHASE cutover-done
  rm -rf "$WORK"/pkgs/rehearsal-*
  rsh "rm -rf $RIN/rehearsal-*" 2>/dev/null
  section "切换结果"
  if [ "$PROBLEMS" -eq 0 ]; then ok "新机已接手，验证没有发现问题"
  else warn "新机已接手，但验证发现 $PROBLEMS 处问题（见上）：先解决，或 live-migrate.sh rollback"; fi
  cat <<EOF
  - 本机：容器已停、备份定时任务已暂停。DNS 切过去之前访问会失败，尽快改 DNS
  - 还能回滚：live-migrate.sh rollback（或 bash $WORK/rollback.sh），DNS 改好之前都可以
EOF
}

# ── DNS ─────────────────────────────────────────────────────
doh() {  # doh <域名> <A|AAAA>：公共 DNS 的答案（空格分隔）；一个 DoH 都连不上返回 1
  local u out ans="" got=1
  for u in $DOH; do
    out=$(curl -fsS -m 8 -H 'accept: application/dns-json' "$u?name=$1&type=$2" 2>/dev/null) || continue
    got=0
    ans="$ans $(grep -oE '"data": *"[^"]*"' <<<"$out" | sed -E 's/.*"([^"]*)"$/\1/' | tr '\n' ' ')"
  done
  [ "$got" = 0 ] || return 1
  if [ "$2" = A ]; then printf '%s\n' $ans | grep -E '^[0-9]+(\.[0-9]+){3}$'
  else printf '%s\n' $ans | grep ':'; fi | sort -u | tr '\n' ' ' | sed 's/ $//'
}

do_dns() {
  local d a4 a6 bad=0 olds verdict c
  mapfile -t DOMS < <(domains)
  olds=" $(my_ips | tr '\n' ' ') "
  section "DNS：要在 DNS 服务商那里改的记录"
  [ ${#DOMS[@]} -gt 0 ] || { warn "没有扫到域名（$PANEL_VHOST_DIR，DOMAINS 也没填）"; return 0; }
  printf '  %s%s%s改成\n' "$(pad 域名 40)" "$(pad 类型 6)" "$(pad "现在（公共 DNS）" 34)"
  for d in "${DOMS[@]}"; do
    a4=$(doh "$d" A) || a4="（查不到：本机连不上 DoH）"
    printf '  %s%s%s%s\n' "$(pad "$d" 40)" "$(pad A 6)" "$(pad "${a4:-（没有记录）}" 34)" "$IP"
    a6=$(doh "$d" AAAA) && [ -n "$a6" ] \
      && printf '  %s%s%s%s\n' "$(pad "$d" 40)" "$(pad AAAA 6)" "$(pad "$a6" 34)" "${N[ipv6]:-删除（新机没有公网 IPv6）}"
  done
  cat <<EOF

  - 「现在」一栏不是本机 IP（比如 Cloudflare 的地址）说明开了代理：在 Cloudflare 里把源站改成 $IP，代理状态保持原样
  - 只改上面这些站点记录；MX、TXT 等与本机无关的不动。面板之外的主机名（比如 SSH 用的）自己核对
EOF
  if [ "$VERIFY_DNS" != 1 ]; then
    echo
    if ! ask_tty "DNS 改好了吗？输入 yes 开始经公共 DNS 复核"; then
      log "改好后运行：live-migrate.sh $IP --ssh-port $PORT --dns"
      return 0
    fi
  fi
  section "经公共 DNS 复核"
  for d in "${DOMS[@]}"; do
    if ! a4=$(doh "$d" A); then verdict="查不到（本机连不上 DoH）"; bad=$((bad + 1))
    elif [[ " $a4 " == *" $IP "* ]]; then verdict="新机 ✓（经新机 $(site_code "$d" "$IP")）"
    elif [ -z "$a4" ]; then verdict="没有记录"; bad=$((bad + 1))
    else
      c=""; for c in $a4; do [[ $olds == *" $c "* ]] && break; c=""; done
      if [ -n "$c" ]; then verdict="还是旧机（没改或还没生效）"; bad=$((bad + 1))
      else
        c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$d/" 2>/dev/null)
        if is_err "$c"; then verdict="其他地址（代理？），公网访问 $c"; bad=$((bad + 1))
        else verdict="其他地址（代理？），公网访问 $c ✓"; fi
      fi
    fi
    printf '  %s%s  %s\n' "$(pad "$d" 40)" "$(pad "${a4:--}" 30)" "$verdict"
  done
  if [ "$bad" -gt 0 ]; then
    warn "$bad 个站点还没切过来：TTL 没到就再等等，之后 live-migrate.sh $IP --ssh-port $PORT --dns --verify-dns 再复核"
    return 0
  fi
  st_add PHASE dns-done
  ok "DNS 已全部切到新机"
  section "收尾"
  log "新机：删掉临时放行本机的规则"
  ragent unallow-me "$ID" | sed 's/^/  /'
  if confirm "落地机等机器的放行名单里删掉本机（旧前置机）？之后本机就连不上它们了"; then
    peers drop
  fi
  cat <<EOF

  迁移完成。接下来：
  - 新机：按恢复输出最后「还要手动做的事」处理，包括重启 SSH / 防火墙（保持一个会话、另开窗口测试能登录再关旧的）、
    宝塔面板认领站点并核对证书续期；opsget ops/preflight-backup、手动跑一次备份、opsget ops/verify-backup-pass；
    确认无误后删掉新机的 /root/dr_restore（解开的明文包）
  - 本机：容器保持停止、备份定时任务保持暂停，别再恢复（它会把停服那一刻的旧数据当成最新的包传上网盘）。
    观察几天没问题后退役：opsget ops/decommission-archive。最终的包在 $WORK/pkgs（加密的）
  - 要切回旧机：新机已经接了写入，不能直接回滚，见 migrate/README.md「DNS 切换之后要切回」
EOF
}

# ── 动作 ────────────────────────────────────────────────────
do_status() {
  local p
  [ -f "$ST" ] || { echo "本机没有迁移记录（没有 $ST）"; return 0; }
  p=$(phase)
  echo "迁移 $(st_get ID) → $(st_get TARGET | tr '\t' ':')"
  echo "阶段：$(phase_label "$p")"
  st_rows REHEARSAL | awk -F'\t' '{ printf "  演练 %s（包 %s）\n", $2, $3 }'
  st_rows CUTOVER | awk -F'\t' '{ printf "  切换 %s（包 %s）\n", $2, $3 }'
  [ -n "$(st_rows STOPPED)" ] && echo "  切换时停掉的容器：$(st_rows STOPPED | cut -f2 | tr '\n' ' ')"
  case "$p" in
    cutover-started|cutover-done) echo "  回滚：live-migrate.sh rollback（或 bash $WORK/rollback.sh）" ;;
    dns-done) echo "  DNS 已切换，不能直接回滚（见 migrate/README.md「DNS 切换之后要切回」）" ;;
  esac
}

do_rollback() {
  [ -f "$ST" ] || die "本机没有迁移记录（没有 $ST），没有可回滚的"
  case "$(phase)" in
    dns-done) die "DNS 已经切到新机，新机接过写入了：直接回滚会丢那之后的数据。切回的办法见 migrate/README.md「DNS 切换之后要切回」" ;;
    cutover-started|cutover-done) ;;
    rolled-back) log "已经回滚过；再执行一遍也没关系" ;;
    *) log "还没切换过：本机没停过服务、没暂停过定时任务，不用回滚"; return 0 ;;
  esac
  [ -f "$WORK/rollback.sh" ] || die "没有 $WORK/rollback.sh"
  section "回滚（DNS 切换前）"
  echo "  新机停容器、暂停备份定时任务；本机恢复备份定时任务、启动：$(st_rows STOPPED | cut -f2 | tr '\n' ' ')"
  confirm "执行回滚？"
  bash "$WORK/rollback.sh" || warn "回滚脚本有步骤失败（见上）"
  st_add PHASE rolled-back
  [ -z "$(docker ps -q 2>/dev/null)" ] && [ -n "$(st_rows STOPPED)" ] && warn "本机还是没有在跑的容器"
  log "新机 IP 还在落地机等机器的放行名单里：放弃这次迁移的话自己删掉"
}

do_migrate() {
  [[ $IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "新机要写 IPv4 地址：${IP:-（没写）}"
  [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "SSH 端口不对：$PORT"
  my_ips | grep -qxF "$IP" && die "$IP 是本机自己"
  init_id
  trap ssh_close EXIT
  preflight
  if [ "$MODE" = dns ]; then
    case "$(phase)" in cutover-done|dns-done) ;; *) die "还没切换过（$(phase_label)），没有 DNS 要改" ;; esac
    do_dns
    return
  fi
  show_plan
  if [ "$MODE" = check ]; then echo; log "只预检：两台机器都没有改动"; return; fi
  case "$(phase)" in
    dns-done) die "迁移已经完成（DNS 已切换）" ;;
    cutover-done) die "已经切换过：改 DNS 用 --dns，回滚用 live-migrate.sh rollback" ;;
  esac
  if [ "$MODE" = cutover ]; then
    [ "$(st_get ID)" = "$ID" ] && [ -n "$(st_rows REHEARSAL)" ] \
      || die "这台新机还没演练过：先跑演练（去掉 --cutover）"
  else
    [ "$(phase)" = cutover-started ] && die "上次切换中断了（本机已停写）：--cutover 接着做，或 live-migrate.sh rollback"
    echo
    confirm "开始演练？本机照常服务；新机上会恢复出本机的数据并短暂起服务验证"
    persist
    st_add PHASE started
    bootstrap_new
    section "落地机等机器的 SSH 放行名单：加上新机"
    peers allow
    rehearse
    if [ "$MODE" = rehearse ]; then
      echo; log "演练完成。切换：live-migrate.sh $IP --ssh-port $PORT --cutover"
      return
    fi
    if [ "$PROBLEMS" -gt 0 ] && [ "${OPS_YES:-0}" = 1 ]; then
      warn "演练有差异，自动模式（OPS_YES=1）不切换。核对后：live-migrate.sh $IP --ssh-port $PORT --cutover"
      return
    fi
  fi
  echo
  [ "${PROBLEMS:-0}" -gt 0 ] && echo "  ⚠ 演练发现 $PROBLEMS 处差异（见上），确认它们不影响再切换"
  echo "  切换会暂停本机的备份定时任务、停掉本机全部容器，服务中断到 DNS 切过去为止。"
  echo "  不想现在切就回答 no，之后用 live-migrate.sh $IP --ssh-port $PORT --cutover"
  confirm "现在切换？"
  persist
  cutover
  do_dns
}

case "$ACTION" in
  status)   do_status ;;
  rollback) do_rollback ;;
  migrate)  do_migrate ;;
esac
finish
