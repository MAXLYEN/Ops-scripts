#!/usr/bin/env bash
# migrate/restore-from-backup.sh — 原机已不在时，用每日加密备份包把新机恢复成原样
# VERSION: 1.0.1
# 1.0.1: LiteLLM 包（litellm_*）明确拒绝，指向 ops/litellm-drill 与包里的 RESTORE.md。
# 1.0.0: 首版。vw / xboard 包（现有布局与 rootfs + restore-manifest.tsv 新布局）：取包、解密、校验，按包还原配置、库与账号、数据、compose 项目（镜像按清单锁版本）、systemd 单元、nginx、定时任务并启动；可重跑；--drill 演练与 teardown 清理。
# ENV-REQUIRED: BACKUP_PASS_FILE|VW_PASS_FILE DB_CLIENT_HOST MYSQL_DEFAULTS_FILE PANEL_VHOST_DIR PANEL_CERT_DIR
# 在 init/ 做完、配好 env.conf / 备份密码文件 / rclone 的新机上运行。原机还在时走 03 冷快照 → 07。
# 用法：
#   restore-from-backup.sh check    [vw|xboard|all|包路径...]    解开、校验，列出恢复会做什么；不动本机
#   restore-from-backup.sh restore  [vw|xboard|all|包路径...] [--force] [--drill] [--no-start] [--image 名称=镜像]
#   restore-from-backup.sh status
#   restore-from-backup.sh teardown                               只清理 --drill 恢复出来的内容
# 不给目标等于 all：从 RCLONE_REMOTES 下的 VW_REMOTE_PATH / XBOARD_REMOTE_PATH 各取最新的包。
# --force     本机已有数据或在跑的服务时仍然恢复：原有目录移到 .bak.<时间>，原有库先导出再删
# --drill     临时机上演练：本机有任何数据就拒绝，不装定时任务、不启用 systemd 单元，之后可 teardown
# --no-start  只还原文件、库与定时任务，不拉镜像、不起容器、不重载 nginx（打印这些命令）
# --image     给清单里锁不住版本的容器指定镜像（tag 带版本号或 @sha256 digest），可多次

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
# 暂存目录单独收紧到 700；放进系统的文件保留包里的权限，新建的父目录要让 nginx 等服务读得到
umask 022

usage() { sed -n '/^# 用法：/,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1; }

ACTION=${1:-}; [ -n "$ACTION" ] || usage; shift
TARGETS=() IMAGES=() DRILL=0 FORCE=0 NOSTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --drill) DRILL=1 ;;
    --force) FORCE=1 ;;
    --no-start) NOSTART=1 ;;
    --image) [ -n "${2:-}" ] || die "--image 后面要跟 名称=镜像"; IMAGES+=("$2"); shift ;;
    --image=*) IMAGES+=("${1#--image=}") ;;
    -h|--help) usage ;;
    -*) die "未知选项: $1" ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(all)
[ "$DRILL" = 1 ] && [ "$FORCE" = 1 ] && die "--drill 不能和 --force 一起用：演练从不覆盖已有数据"

DR_ROOT=${DR_ROOT:-/root/dr_restore}
STATE_DIR=/var/lib/ops-scripts
ST=$STATE_DIR/dr-restore.state
TS=$(date -u +%Y%m%d%H%M%S)
BIN=/usr/local/bin
SELF=$(readlink -f "$0")
BACKUP_PASS_FILE=${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}
# 面板装的 MySQL 常不在 PATH 里
command -v mysql >/dev/null 2>&1 || { [ -x /www/server/mysql/bin/mysql ] && PATH="/www/server/mysql/bin:$PATH"; }

MANUAL=()   # 最后列出的手动步骤：「事项|为什么不能自动」
manual() { MANUAL+=("$1|$2"); }

# 只在某种用法下才需要的键：不写进 ENV-REQUIRED，否则只恢复 xboard 也会被要求填 Vaultwarden 的目录、
# 给了本地包也会被要求填云端路径。缺了照样直接退出，不回落到默认值
need_for() {  # need_for <用途> <键...>
  local what=$1 k miss=""; shift
  for k in "$@"; do [ -n "${!k:-}" ] || miss="$miss $k"; done
  [ -z "$miss" ] || die "${what}需要配置:$miss（本机 env.conf 和包里原机的 env.conf 都没有）"
}

# ── 状态文件：记下这台机器上恢复过什么，重跑时据此跳过、teardown 据此清理 ──
# 一行一条，制表符分隔：MODE / PKG / PLACED 目标 包sha / CREATED 路径 / MOVED 原路径 备份 /
# DBCREATED 库 / DBSTART 库 sha / DBDONE 库 sha / USER 账号 host / UNIT 名 / UFW 网段 / ENVBAK 备份 / DOCKER_INSTALLED
st_add() { mkdir -p "$STATE_DIR"; local IFS=$'\t'; printf '%s\n' "$*" >> "$ST"; }
st_rows() { [ -f "$ST" ] && awk -F'\t' -v t="$1" '$1 == t' "$ST"; }
st_mode() { st_rows MODE | tail -1 | cut -f2; }
SHAS=" "   # 本次这批包的 sha（空格包围），判断「是不是我们自己放的」只认这批
by_set() {  # by_set <类型> <目标>：状态里有没有这批包之一记下的这一条
  st_rows "$1" | awk -F'\t' -v d="$2" -v s="$SHAS" '$2 == d && index(s, " " $3 " ") { f = 1 } END { exit !f }'
}

# ── 小工具 ──────────────────────────────────────────────────
ensure_cmds() {  # ensure_cmds <命令:包>...：缺的用 apt 装上
  local cp need=""
  for cp in "$@"; do command -v "${cp%%:*}" >/dev/null 2>&1 || need="$need ${cp#*:}"; done
  [ -n "$need" ] || return 0
  log "安装缺的依赖:$need"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update -qq >/dev/null 2>&1
  # shellcheck disable=SC2086
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq $need >/dev/null || die "安装失败:$need"
}
env_val() {  # env_val <.env 文件> <键>：取值并去掉两侧引号
  local v; v=$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- | tr -d '\r')
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  printf '%s' "$v"
}
conf_val() { ( . "$1" >/dev/null 2>&1; printf '%s' "${!2:-}" ); }   # 读 shell 格式配置里的值（子 shell）
is_pinned() {  # 镜像引用是否锁定：@sha256 digest，或 tag 里带数字（latest / new / alpine 都不算）
  local last=${1##*/}
  [[ $1 == *@sha256:* ]] && return 0
  [[ $last == *:* ]] && [[ ${last#*:} =~ [0-9] ]]
}
sql_str() { local s=${1//\\/\\\\}; s=${s//\'/\\\'}; printf "'%s'" "$s"; }
dump_tables() { if [[ $1 == *.gz ]]; then zcat "$1"; else cat "$1"; fi | grep -c '^CREATE TABLE'; }
db_tables() { myq "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$1'"; }
acct_exists() { [ "$(myq "SELECT COUNT(*) FROM mysql.user WHERE User='$1' AND Host='$2'")" -gt 0 ]; }
nginx_bin() { command -v nginx 2>/dev/null || { [ -x /www/server/nginx/sbin/nginx ] && echo /www/server/nginx/sbin/nginx; }; }
mysql_ok() { [ -f "${MYSQL_DEFAULTS_FILE:-}" ] && command -v mysql >/dev/null 2>&1 && my -e 'SELECT 1' >/dev/null 2>&1; }
safe_rm() {  # 只删我们建出来的路径；浅层系统目录一律拒绝
  case "$1" in
    ''|/|/bin|/boot|/etc|/home|/lib|/opt|/root|/sbin|/srv|/tmp|/usr|/usr/local|/usr/local/bin|/var|/var/lib) warn "拒绝删除 $1"; return 1 ;;
    /*) rm -rf -- "$1" ;;
    *) warn "拒绝删除非绝对路径 $1"; return 1 ;;
  esac
}

# ── 取包、解开、校验 ────────────────────────────────────────
P_FILE=() P_SHA=() P_DIR=() P_X=() P_KIND=() P_LAYOUT=() P_TIME=()
FETCHED=""
fetch_latest() {  # fetch_latest <vw|xboard>：从各远端挑最新的一个下载，路径放 FETCHED
  local kind=$1 key pat dir r n best="" from=""
  case $kind in
    vw)     key=VW_REMOTE_PATH;     pat='srvbak_*.7z' ;;
    xboard) key=XBOARD_REMOTE_PATH; pat='xboard_*.7z' ;;
  esac
  dir=${!key:-}
  [ -n "${RCLONE_REMOTES:-}" ] && [ -n "$dir" ] \
    || die "没给包路径。要从云端取 $kind 包，得在 env.conf 填 RCLONE_REMOTES 和 $key；或者先把包下载到本机，把路径传进来"
  ensure_cmds rclone:rclone
  for r in $RCLONE_REMOTES; do
    n=$(rclone lsf "$r:$dir" --include "$pat" 2>/dev/null | sort | tail -1)
    if [ -z "$n" ]; then warn "$r:$dir 里没有 $pat（或连不上）"; continue; fi
    log "$r:$dir 最新：$n"
    [[ $n > $best ]] && { best=$n; from=$r; }
  done
  [ -n "$best" ] || die "所有远端都没取到 $kind 包"
  mkdir -p "$DR_ROOT/download"; chmod 700 "$DR_ROOT"
  if [ ! -s "$DR_ROOT/download/$best" ]; then
    log "下载 $from:$dir/$best"
    rclone copy "$from:$dir/$best" "$DR_ROOT/download/" || die "下载失败"
  fi
  FETCHED="$DR_ROOT/download/$best"
}

open_pkg() {  # open_pkg <包路径> <解开到的父目录>
  local f i=${#P_FILE[@]} sha dir x layout kind
  f=$(readlink -f "$1") && [ -f "$f" ] || die "包不存在: $1"
  section "包 $(basename "$f")"
  case "$(basename "$f")" in
    newapi_*)  die "new-api 包用 ops/newapi-drill 恢复与演练（本脚本只认 vw / xboard 包）" ;;
    litellm_*) die "LiteLLM 包不归本脚本（只认 vw / xboard 包）：正式恢复照包里的 RESTORE.md 在 LiteLLM 节点上做，备用机演练用 ops/litellm-drill" ;;
  esac
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  case "$SHAS" in *" $sha "*) log "和前面的包是同一个，跳过"; return 0 ;; esac
  if [ -f "$f.sha256" ]; then
    [ "$(cut -d' ' -f1 < "$f.sha256")" = "$sha" ] || die "sha256 与 $f.sha256 不符：包被改过或没传完整"
    ok "sha256 与旁挂的 .sha256 一致"
  else
    log "没有旁挂的 .sha256（云端只存 .7z），完整性靠下面 7z 的 CRC 校验"
  fi
  dir="$2/pkg-${sha:0:12}"
  if [ -f "$dir/.opened" ]; then
    x=$(cat "$dir/.opened"); ok "已解开过：$dir"
  else
    rm -rf "$dir"; mkdir -p "$dir"; chmod 700 "$2" "$dir"
    # </dev/null：文件名也加密的包在密码不对时会交互式等输入
    7z t -p"$PASS" "$f" </dev/null >/dev/null 2>&1 || die "解不开：密码（$BACKUP_PASS_FILE）不对，或包已损坏"
    ok "解密与 CRC 校验通过"
    7z x -y -p"$PASS" -o"$dir/raw" "$f" </dev/null >/dev/null 2>&1 || die "解包失败"
    x="$dir/raw"
    if [ -f "$x/payload.tar.gz" ]; then
      mkdir -p "$dir/x"
      tar --same-owner -xzf "$x/payload.tar.gz" -C "$dir/x" || die "payload.tar.gz 解不开"
      x="$dir/x"
    fi
    printf '%s\n' "$x" > "$dir/.opened"
  fi
  if [ -f "$x/restore-manifest.tsv" ]; then layout=v2
  elif [ -d "$x/vaultwarden" ] || [ -d "$x/system" ]; then layout=vw
  elif [ -f "$x/app/.env" ]; then layout=xboard
  else die "认不出的包布局（没有 restore-manifest.tsv、vaultwarden/、app/.env）：$x"; fi
  case "$(basename "$f")" in srvbak_*) kind=vw ;; xboard_*) kind=xboard ;; *) kind=$layout ;; esac
  P_FILE[i]=$f P_SHA[i]=$sha P_DIR[i]=$dir P_X[i]=$x P_KIND[i]=$kind P_LAYOUT[i]=$layout
  P_TIME[i]=$(basename "$f" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
  SHAS="$SHAS$sha "
  log "类型 $kind，布局 $layout，备份时间 ${P_TIME[i]:-未知}"
  verify_pkg "$x"
}

verify_pkg() {  # verify_pkg <内容目录>
  local x=$1 sums bad d n tail
  # vw 的 manifest.txt 带一节内容校验和；manifest.txt 自己是边写边算的，不在可校验之列。
  # 行格式用 grep 判断：Debian 默认的 mawk 不认 {64} 这种区间写法
  sums=$(awk '/^---- 内容校验和 ----/ { f = 1; next } f' "$x/manifest.txt" 2>/dev/null \
         | grep -E '^[0-9a-f]{64}  ' | grep -v '  \./manifest\.txt$')
  [ -f "$x/SHA256SUMS" ] && sums=$(grep -vE '  (\./)?(SHA256SUMS|manifest\.txt)$' "$x/SHA256SUMS")
  if [ -n "$sums" ]; then
    if bad=$(cd "$x" && sha256sum -c --quiet - <<<"$sums" 2>&1); then
      ok "内容校验和 $(wc -l <<<"$sums") 项全部一致"
    else
      printf '%s\n' "$bad" | sed 's/^/  /'; die "内容与清单里的校验和不符"
    fi
  else
    log "包里没有内容校验和清单（xboard 包就是这样），只有 7z 的 CRC"
  fi
  # 新布局只校验清单里标了 mysql-db 的（db/ 下还有账号 SQL 等）；旧布局 db/ 下的 .sql 都是 dump
  while IFS= read -r d; do
    [ -f "$d" ] || continue
    n=$(dump_tables "$d")
    [ "${n:-0}" -gt 0 ] || die "$(basename "$d") 里没有任何表，不要用这个包"
    tail=$(if [[ $d == *.gz ]]; then zcat "$d"; else cat "$d"; fi | tail -n 3)
    case "$tail" in
      *"Dump completed"*) ok "$(basename "$d")：$n 张表，结尾完整" ;;
      *) warn "$(basename "$d") 结尾没有 Dump completed，可能被截断" ;;
    esac
  done < <(if [ -f "$x/restore-manifest.tsv" ]; then
             awk -F'\t' -v x="$x" '$4 == "mysql-db" { print x "/" $1 }' "$x/restore-manifest.tsv"
           else
             printf '%s\n' "$x"/db/*.sql "$x"/db/*.sql.gz
           fi)
}

open_targets() {  # open_targets <解开到的父目录>
  local t i
  for t in "${TARGETS[@]}"; do
    case "$t" in
      all)       fetch_latest vw; open_pkg "$FETCHED" "$1"; fetch_latest xboard; open_pkg "$FETCHED" "$1" ;;
      vw|xboard) fetch_latest "$t"; open_pkg "$FETCHED" "$1" ;;
      *)         open_pkg "$t" "$1" ;;
    esac
  done
  # 按备份时间从旧到新处理：两个包都带的文件（站点配置、证书），较新的那个说了算
  ORDER=()
  while read -r i; do ORDER+=("$i"); done < <(for i in "${!P_FILE[@]}"; do printf '%s %s\n' "${P_TIME[i]:-0}" "$i"; done | sort | awk '{ print $2 }')
}

# ── 原机 env.conf：本机没填的键用它补上，本机已填的一律不动 ──
ENV_MERGED="" ENV_FILLED=()
env_merge() {
  local i src line k
  ENV_MERGED="$DR_ROOT/env.merged.$TS"; mkdir -p "$DR_ROOT"; cp "$OPS_ENV_FILE" "$ENV_MERGED"
  for i in "${ORDER[@]}"; do
    for src in "${P_X[i]}/system/env.conf" "${P_X[i]}/deploy/env.conf" "${P_X[i]}/rootfs$OPS_ENV_FILE"; do
      [ -f "$src" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)= ]] || continue
        k=${BASH_REMATCH[1]}
        [ -z "$(conf_val "$ENV_MERGED" "$k")" ] || continue
        [ -n "$(conf_val "$src" "$k")" ] || continue
        if grep -qE "^[[:space:]]*$k=" "$ENV_MERGED"; then
          L=$line K=$k awk '!d && $0 ~ "^[[:space:]]*" ENVIRON["K"] "=" { print ENVIRON["L"]; d = 1; next } { print }' \
            "$ENV_MERGED" > "$ENV_MERGED.t" && mv "$ENV_MERGED.t" "$ENV_MERGED"
        else
          printf '%s\n' "$line" >> "$ENV_MERGED"
        fi
        ENV_FILLED+=("$k")
      done < "$src"
    done
  done
  # shellcheck disable=SC1090
  . "$ENV_MERGED"
  BACKUP_PASS_FILE=${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}
  if [ ${#ENV_FILLED[@]} -gt 0 ]; then
    log "本机 env.conf 没填、用原机配置补上的键：${ENV_FILLED[*]}"
  else
    log "env.conf 不需要从原机补键"
  fi
}

check_client_host() {
  case "$DB_CLIENT_HOST" in
    %) die "DB_CLIENT_HOST 是 %：数据库账号会对全网开放。填容器网段通配，如 172.%" ;;
    localhost|127.0.0.1|::1) die "DB_CLIENT_HOST 是 $DB_CLIENT_HOST：容器从网桥连宿主机，用它会连不上。填容器网段通配，如 172.%" ;;
  esac
  [[ $DB_CLIENT_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && die "DB_CLIENT_HOST 是具体 IP $DB_CLIENT_HOST：容器重建就换地址。填容器网段通配，如 172.%"
  return 0
}

# ── 恢复条目：两种布局都翻译成同一张表 ──────────────────────
# 类型 file / dir / sqlite / systemd-unit 放到绝对路径；mysql-db 目标是库名；mysql-user 源是 SQL；
# compose-project 目标是项目目录；crontab / rclone 源是文件
IT_PKG=() IT_KIND=() IT_DST=() IT_SRC=() IT_MODE=() IT_OWN=() IT_ACC=()
CUR=0
item() {  # item <类型> <目标> <源> [权限] [属主]
  local n=${#IT_KIND[@]}
  IT_PKG[n]=$CUR IT_KIND[n]=$1 IT_DST[n]=$2 IT_SRC[n]=$3 IT_MODE[n]=${4:--} IT_OWN[n]=${5:--}
}
tree_items() {  # tree_items <源目录> <目标目录> [权限]：逐个文件登记，目标目录里别的文件不受影响
  local f
  [ -d "$1" ] || return 0
  while IFS= read -r -d '' f; do item file "$2/${f#"$1"/}" "$f" "${3:--}"; done \
    < <(find "$1" \( -type f -o -type l \) -print0 | sort -z)
}

# 账号：容器客户端用 DB_CLIENT_HOST；本机的备份脚本经 127.0.0.1 连库，也要一条回环账号
user_sql() {  # user_sql <账号> <密码> <库> <授权记录文件> <回环连接?0/1>
  local u=$1 p=$2 db=$3 h hosts=$DB_CLIENT_HOST orig
  orig=$(head -1 "$4" 2>/dev/null | sed -n 's/.*@//p')
  case "$orig" in localhost|127.0.0.1|::1) hosts="$hosts $orig" ;; esac
  [ "$5" = 1 ] && [[ " $hosts " != *" 127.0.0.1 "* ]] && hosts="$hosts 127.0.0.1"
  for h in $hosts; do
    printf 'CREATE USER %s@%s IDENTIFIED BY %s;\n' "$(sql_str "$u")" "$(sql_str "$h")" "$(sql_str "$p")"
    printf 'GRANT ALL PRIVILEGES ON `%s`.* TO %s@%s;\n' "$db" "$(sql_str "$u")" "$(sql_str "$h")"
  done
}

items_vw() {
  local x=$1 d f url user pass host db sub
  need_for "恢复 Vaultwarden " SVC_VW_DIR
  [ -d "$x/vaultwarden/data" ] && item dir "$SVC_VW_DIR/data" "$x/vaultwarden/data"
  [ -f "$x/vaultwarden/data/rsa_key.pem" ] || warn "包里没有 rsa_key.pem：恢复后所有设备都要重新登录"
  for f in vaultwarden.env compose.yaml; do
    [ -f "$x/vaultwarden/$f" ] && item file "$SVC_VW_DIR/$f" "$x/vaultwarden/$f"
  done
  [ -f "$x/vaultwarden/compose.yaml" ] && item compose-project "$SVC_VW_DIR" -
  for d in "$x"/db/*.sql.gz; do [ -f "$d" ] && item mysql-db "$(basename "$d" .sql.gz)" "$d"; done
  url=$(env_val "$x/vaultwarden/vaultwarden.env" DATABASE_URL)
  if [ -n "$url" ]; then
    user=$(sed -E 's#^mysql://([^:]+):.*#\1#' <<<"$url")
    pass=$(sed -E 's#^mysql://[^:]+:([^@]*)@.*#\1#' <<<"$url")
    host=$(sed -E 's#^mysql://[^@]+@([^:/]+).*#\1#' <<<"$url")
    db=$(sed -E 's#.*/([^/?]+)$#\1#' <<<"$url")
    # 备份脚本把 host.docker.internal 换成 127.0.0.1 从本机连
    [ "$host" = host.docker.internal ] && host=127.0.0.1
    user_sql "$user" "$pass" "$db" "$x/db/$db-grants.txt" "$([[ $host == 127.* || $host == localhost ]] && echo 1 || echo 0)" \
      > "${P_DIR[CUR]}/users-vw.sql"
    item mysql-user - "${P_DIR[CUR]}/users-vw.sql"
  else
    warn "vaultwarden.env 里没有 DATABASE_URL，不建数据库账号"
  fi
  if [ -f "$x/komari/komari.db" ]; then
    if [ -n "${SVC_KOMARI_DATA:-}" ]; then
      item sqlite "$SVC_KOMARI_DATA/komari.db" "$x/komari/komari.db"
      for d in plugin plugin-data; do [ -d "$x/komari/$d" ] && item dir "$SVC_KOMARI_DATA/$d" "$x/komari/$d"; done
      if [ -f "$x/komari/compose.yaml" ]; then
        item file "$(dirname "$SVC_KOMARI_DATA")/compose.yaml" "$x/komari/compose.yaml"
        item compose-project "$(dirname "$SVC_KOMARI_DATA")" -
      fi
      [ -s "$x/komari/theme-list.txt" ] && manual "Komari 主题在面板里重新下载：$(tr '\n' ' ' < "$x/komari/theme-list.txt")" "主题可重新下载，备份按设计不收"
    else
      warn "包里有 komari.db，但 SVC_KOMARI_DATA 本机和原机都没填，跳过 Komari"
    fi
    [ -f "$x/komari/auto-discovery.json" ] && [ -n "${SVC_KOMARI_EXTRA:-}" ] \
      && item file "$SVC_KOMARI_EXTRA/auto-discovery.json" "$x/komari/auto-discovery.json"
  fi
  if [ -n "$(ls -A "$x/subconverter" 2>/dev/null)" ]; then
    if [ -n "${SVC_SUBCONV_DIR:-}" ]; then
      item dir "$SVC_SUBCONV_DIR" "$x/subconverter"
      sub=$(ls "$x"/subconverter/{compose,docker-compose}.y*ml 2>/dev/null | head -1)
      if [ -n "$sub" ]; then item compose-project "$SVC_SUBCONV_DIR" -
      else manual "SubConverter 没有 compose 文件，按 system/docker/run-commands.sh 里的参数起容器" "原机上它不是 compose 管理的，包里只有运行参数"; fi
    else
      warn "包里有 SubConverter，但 SVC_SUBCONV_DIR 本机和原机都没填，跳过"
    fi
  fi
  for f in "$x"/system/nginx/*.conf; do [ -f "$f" ] && item file "$PANEL_VHOST_DIR/$(basename "$f")" "$f"; done
  tree_items "$x/system/cert" "$PANEL_CERT_DIR"
  [ -f "$x/system/crontab.txt" ] && item crontab - "$x/system/crontab.txt"
  [ -f "$x/system/rclone.conf" ] && item file /root/.config/rclone/rclone.conf "$x/system/rclone.conf" 0600
  return 0
}

items_xboard() {
  local x=$1 envf=$1/app/.env db user pass dump tree site f loop
  need_for "恢复 Xboard " SVC_XBOARD_DIR
  grep -q '^APP_KEY=.\+' "$envf" || die "app/.env 里没有 APP_KEY：库里的加密字段会解不开，这个包不能用"
  db=$(env_val "$envf" DB_DATABASE); user=$(env_val "$envf" DB_USERNAME); pass=$(env_val "$envf" DB_PASSWORD)
  [ -n "$db" ] && [ -n "$user" ] || die "app/.env 里读不到 DB_DATABASE / DB_USERNAME"
  dump="$x/db/$db.sql"
  if [ ! -f "$dump" ]; then
    dump=$(ls "$x"/db/*.sql 2>/dev/null | head -1)
    [ -n "$dump" ] || die "包里没有数据库 dump"
    warn "dump 文件名是 $(basename "$dump")，应用连的库是 $db：导入到 $db"
  fi
  item mysql-db "$db" "$dump"
  [ "${XBOARD_DB_NAME:-$db}" = "$db" ] || warn "env.conf 的 XBOARD_DB_NAME=$XBOARD_DB_NAME 与应用用的库 $db 不一致，备份脚本会导错库"
  loop=0
  case "$(env_val "$envf" DB_HOST)" in 127.*|localhost) loop=1 ;; esac
  case "${XBOARD_DB_HOST:-127.0.0.1}" in 127.*|localhost) loop=1 ;; esac
  user_sql "$user" "$pass" "$db" "$x/db/$db-grants.txt" "$loop" > "${P_DIR[CUR]}/users-xboard.sql"
  item mysql-user - "${P_DIR[CUR]}/users-xboard.sql"
  # 照包里 RESTORE.md：先拉 compose 分支当骨架，再盖上包里的文件。check 不联网，只看包里的
  tree="${P_DIR[CUR]}/xboard-tree"
  if [ ! -f "$tree.ready" ]; then
    rm -rf "$tree"
    if [ "$ACTION" = restore ] && { ensure_cmds git:git; git clone -q -b compose --depth 1 https://github.com/cedar2025/Xboard "$tree" 2>/dev/null; }; then
      log "Xboard compose 分支骨架：$(git -C "$tree" rev-parse --short HEAD 2>/dev/null)"
    else
      [ "$ACTION" = restore ] && warn "拉不到 Xboard compose 分支：只放包里的文件，compose 挂载的其它目录会由 docker 建成空目录"
      mkdir -p "$tree"
    fi
    cp -a "$x/app/." "$tree/" && touch "$tree.ready"
  fi
  item dir "$SVC_XBOARD_DIR" "$tree"
  item compose-project "$SVC_XBOARD_DIR" -
  for f in "$x"/nginx/vhost/*.conf; do [ -f "$f" ] && item file "$PANEL_VHOST_DIR/$(basename "$f")" "$f"; done
  tree_items "$x/nginx/cert" "$PANEL_CERT_DIR"
  site=${XBOARD_ASSETS_SITE:-$(sed -n 's|^[[:space:]]*cp -a nginx/assets-site .*/\([^/[:space:]]\{1,\}\)[[:space:]]*$|\1|p' "$x/RESTORE.md" | head -1)}
  if [ -d "$x/nginx/assets-site" ]; then
    if [ -n "$site" ] && [ -n "${WWWROOT:-}" ]; then item dir "$WWWROOT/$site" "$x/nginx/assets-site"
    else warn "包里有静态资源站，但不知道放哪（XBOARD_ASSETS_SITE / WWWROOT），跳过"; fi
  fi
  for f in "$x"/deploy/* "$x"/deploy/.[!.]*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      env.conf) ;;
      xboard-toolkit.conf) item file /etc/xboard-toolkit.conf "$f" ;;
      nodes.txt) item file /root/deploy/nodes.txt "$f" 0600 ;;
      *) if [ -d "$f" ]; then tree_items "$f" "/root/deploy/$(basename "$f")"; else item file "/root/deploy/$(basename "$f")" "$f"; fi ;;
    esac
  done
  # 备份脚本从这个文件读库密码；原机上它不在包里，内容就是 .env 的 DB_PASSWORD
  if [ -n "${XBOARD_DB_PASS_FILE:-}" ]; then
    printf '%s\n' "$pass" > "${P_DIR[CUR]}/xboard-db-pass"
    item file "$XBOARD_DB_PASS_FILE" "${P_DIR[CUR]}/xboard-db-pass" 0600 root:root
  fi
  return 0
}

items_v2() {  # rootfs/ + restore-manifest.tsv（列：path mode owner kind）
  local x=$1 path mode owner kind db
  while IFS=$'\t' read -r path mode owner kind _ || [ -n "$path" ]; do
    case "$path" in ''|'#'*) continue ;; esac
    case "$kind" in
      file|dir|sqlite|systemd-unit)
        [[ $path == /* ]] || die "restore-manifest.tsv：$kind 要写绝对路径：$path"
        [ -e "$x/rootfs$path" ] || [ -L "$x/rootfs$path" ] || die "restore-manifest.tsv 列了 $path，rootfs 里却没有"
        item "$kind" "$path" "$x/rootfs$path" "${mode:--}" "${owner:--}" ;;
      mysql-db)
        [ -f "$x/$path" ] || die "restore-manifest.tsv 列了 $path，包里却没有"
        db=$(basename "$path"); db=${db%.gz}; db=${db%.sql}
        item mysql-db "$db" "$x/$path" ;;
      mysql-user) [ -f "$x/$path" ] || die "包里没有 $path"; item mysql-user - "$x/$path" ;;
      compose-project) item compose-project "$path" - ;;
      crontab) [ -f "$x/$path" ] && item crontab - "$x/$path" ;;
      *) warn "restore-manifest.tsv：不认识的类型 $kind（$path），跳过" ;;
    esac
  done < "$x/restore-manifest.tsv"
  # 备份按设计没收的（解密密码除外，那本来就是引导时自己放好的）
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    case "$kind" in *解密密码*) continue ;; esac
    manual "备份没收 $path，按原因决定要不要另行处理" "${kind:-备份没收}"
  done < <(cat "$x/system/rootfs-skipped.txt" 2>/dev/null)
  return 0
}

build_items() {
  local i
  for i in "${ORDER[@]}"; do
    CUR=$i
    case "${P_LAYOUT[i]}" in
      v2) items_v2 "${P_X[i]}" ;;
      vw) items_vw "${P_X[i]}" ;;
      xboard) items_xboard "${P_X[i]}" ;;
    esac
  done
}

# ── 镜像锁版本 ──────────────────────────────────────────────
# 候选来源依次：--image、备份清单（images.tsv 的 RepoDigest 或 manifest 容器列表里带版本的）、
# compose 原值（已锁定时）、vaultwarden 的版本号。都锁不住就标 UNPINNED，启动时拒绝，绝不拉 latest
IMGS="" OVR="" PROJ=""
PIN_PY=$(cat <<'PY'
import os, re, sys
path, imgs, ovr, vwver, projdir = sys.argv[1:6]
def load(f):
    d = {}
    if os.path.exists(f):
        for l in open(f, encoding='utf-8'):
            p = l.rstrip('\n').split('\t')
            if len(p) >= 2 and p[0] and p[1]:
                d[p[0]] = p[1]
    return d
known, over = load(imgs), load(ovr)
def tag(ref):
    last = ref.split('@', 1)[0].rsplit('/', 1)[-1]
    return last.split(':', 1)[1] if ':' in last else ''
def pinned(ref):
    return '@sha256:' in ref or bool(re.search(r'\d', tag(ref)))
def repo(ref):
    r = ref.split('@', 1)[0]
    return r.rsplit(':', 1)[0] if ':' in r.rsplit('/', 1)[-1] else r
lines = open(path, encoding='utf-8').read().split('\n')
# 项目名取真实的项目目录（这里的 path 是暂存副本），容器名形如 <项目>-<服务>-1
proj = os.path.basename(projdir.rstrip('/')).lower()
svcs, in_s, ind, cur = [], False, None, None
for i, l in enumerate(lines):
    s = l.strip()
    if not s or s.startswith('#'):
        continue
    if re.match(r'^services:\s*$', l):
        in_s = True
        continue
    if not l[0].isspace():
        in_s, cur = False, None
        continue
    if not in_s:
        continue
    n = len(l) - len(l.lstrip())
    m = re.match(r'^\s+([A-Za-z0-9._-]+):\s*$', l)
    if m and (ind is None or n == ind):
        ind, cur = n, [m.group(1), None, None, None]
        svcs.append(cur)
        continue
    if cur and n > ind:
        m = re.match(r'^\s+image:\s*["\']?([^"\'\s#]+)', l)
        if m:
            cur[1], cur[2] = i, m.group(1)
        m = re.match(r'^\s+container_name:\s*["\']?([^"\'\s#]+)', l)
        if m:
            cur[3] = m.group(1)
changed = False
for name, idx, img, cont in svcs:
    if idx is None:
        continue
    names = [k for k in (cont, name, proj + '-' + name + '-1', proj + '_' + name + '_1') if k]
    new, src = None, '-'
    for k in names:
        if k in over:
            new, src = over[k], '--image'
            break
    if not new:
        for k in names:
            if k in known and pinned(known[k]):
                new, src = known[k], '备份清单'
                break
    if not new and pinned(img):
        new, src = img, 'compose 原值'
    if not new and vwver and repo(img).endswith('vaultwarden/server'):
        new = repo(img) + ':' + vwver + ('-alpine' if 'alpine' in tag(img) else '')
        src = '清单里的 Vaultwarden 版本号'
    if new and new != img:
        lines[idx] = re.match(r'^(\s*)', lines[idx]).group(1) + 'image: ' + new
        changed = True
    print('\t'.join([name, cont or name, new or img, 'ok' if new else 'UNPINNED', src, img]))
if changed:
    open(path, 'w', encoding='utf-8').write('\n'.join(lines))
PY
)

collect_images() {
  local i x m name ref s
  IMGS="$DR_ROOT/images.$TS.tsv" OVR="$DR_ROOT/overrides.$TS.tsv" PROJ="$DR_ROOT/projects.$TS.tsv"
  : > "$IMGS"; : > "$OVR"; : > "$PROJ"
  for i in "${ORDER[@]}"; do
    x=${P_X[i]}
    # images.tsv：容器名、配置的镜像、RepoDigest —— 有 digest 就用 digest，:latest 也能锁住
    [ -f "$x/images.tsv" ] && awk -F'\t' '!/^#/ && $1 != "" { print $1 "\t" ($3 != "" && $3 != "-" ? $3 : $2) }' "$x/images.tsv" >> "$IMGS"
    for m in "$x/manifest.txt" "$x/MANIFEST.txt"; do
      [ -f "$m" ] && awk '/^---- 容器 ----/ { f = 1; next } f && /^$/ { exit } f' "$m" | cut -f1,2 >> "$IMGS"
    done
    [ -n "${VWVER:-}" ] || VWVER=$(sed -nE 's/^Vaultwarden v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$x/manifest.txt" 2>/dev/null | head -1)
  done
  for s in "${IMAGES[@]}"; do
    name=${s%%=*}; ref=${s#*=}
    [ -n "$name" ] && [ "$ref" != "$s" ] || die "--image 格式是 名称=镜像：$s"
    is_pinned "$ref" || die "--image $s 没锁版本：要带版本号的 tag 或 @sha256 digest"
    printf '%s\t%s\n' "$name" "$ref" >> "$OVR"
  done
}

pin_file() {  # pin_file <compose 文件（暂存副本）> <项目目录>
  local out
  out=$(python3 -c "$PIN_PY" "$1" "$IMGS" "$OVR" "${VWVER:-}" "$2") || die "解析 $1 失败"
  [ -n "$out" ] && sed "s|^|$2\t|" <<<"$out" >> "$PROJ"
}

# 每个 compose 项目找到提供 compose 文件的条目，复制一份锁好版本再放，包里的原件不动。
# 有单独的 compose 文件条目就只复制它；没有才把整个目录复制一份（Xboard 目录很大，能不复制就不复制）
pin_projects() {
  local p j d dst src rel c done_
  for p in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[p]}" = compose-project ] || continue
    d=${IT_DST[p]} done_=0
    for j in "${!IT_KIND[@]}"; do
      dst=${IT_DST[j]} src=${IT_SRC[j]}
      [ "${IT_KIND[j]}" = file ] && [ "$(dirname "$dst")" = "$d" ] && [[ $(basename "$dst") =~ ^(docker-)?compose\.ya?ml$ ]] || continue
      mkdir -p "${P_DIR[IT_PKG[j]]}/pin/$j"; cp -a "$src" "${P_DIR[IT_PKG[j]]}/pin/$j/"
      IT_SRC[j]="${P_DIR[IT_PKG[j]]}/pin/$j/$(basename "$src")"
      pin_file "${IT_SRC[j]}" "$d"; done_=1
    done
    if [ "$done_" = 0 ]; then
      for j in "${!IT_KIND[@]}"; do
        dst=${IT_DST[j]} src=${IT_SRC[j]}
        [ "${IT_KIND[j]}" = dir ] && { [ "$d" = "$dst" ] || [[ $d == "$dst"/* ]]; } || continue
        rel=${d#"$dst"}
        c=$(ls "$src$rel"/compose.y*ml "$src$rel"/docker-compose.y*ml 2>/dev/null | head -1)
        [ -n "$c" ] || continue
        rm -rf "${P_DIR[IT_PKG[j]]}/pin/$j"; mkdir -p "${P_DIR[IT_PKG[j]]}/pin/$j"
        cp -a "$src" "${P_DIR[IT_PKG[j]]}/pin/$j/tree"
        IT_SRC[j]="${P_DIR[IT_PKG[j]]}/pin/$j/tree"
        pin_file "${IT_SRC[j]}$rel/$(basename "$c")" "$d"; done_=1
        break
      done
    fi
    [ "$done_" = 1 ] || warn "compose 项目 $d：包里找不到它的 compose 文件"
  done
}
proj_unpinned() { awk -F'\t' -v d="$1" '$1 == d && $5 == "UNPINNED" { print $2 }' "$PROJ" | tr '\n' ' '; }

# ── 路径分类：决定「本机已有且内容不同」时怎么办 ───────────
#   data  业务数据（compose 项目目录里的、SQLite）：算冲突，--force 才覆盖
#   keep  工具箱自身、正在跑的这个脚本、引导时配好的凭据：保留本机的，原机的另存 .from-backup
#   skip  不放：env.conf 另行合并；演练不放 /etc/cron.d
#   sys   系统配置（/etc、SSH、面板、证书、站点……）：原有的留 .bak.<时间> 后替换，不拦。
#         新机做完 init/ 这些本来就有，拦下它们等于永远要 --force
path_class() {  # path_class <序号>
  local p=${IT_DST[$1]} q d etc
  etc=$(dirname "$OPS_ENV_FILE")
  case "$p" in "$OPS_ENV_FILE"|"$etc") echo skip; return ;; esac
  if [ "$DRILL" = 1 ]; then case "$p" in /etc/cron.d|/etc/cron.d/*) echo skip; return ;; esac; fi
  [ "${IT_KIND[$1]}" = sqlite ] && { echo data; return; }
  for d in "${PROJ_DIRS[@]}"; do [[ $p == "$d" || $p == "$d"/* ]] && { echo data; return; }; done
  for q in "$etc"/ /root/.config/rclone/ ; do [[ $p == "$q"* || $p == "${q%/}" ]] && { echo keep; return; }; done
  for q in "${MYSQL_DEFAULTS_FILE:-}" "${BACKUP_PASS_FILE:-}" "${VW_PASS_FILE:-}" ${BACKUP_PASS_FILES:-} \
           "$BIN/opsget" "$BIN/opsbox" /usr/local/lib/ops-common.sh "$SELF"; do
    [ -n "$q" ] && [ "$p" = "$q" ] && { echo keep; return; }
  done
  echo sys
}

# ── 计划：逐条判定放置 / 跳过 / 冲突 ────────────────────────
# PLACE 放置   SAME 已相同   OURS 本批包上次已恢复过（之后服务可能改了它，不覆盖）   REDO 上次没导完的库
# CONFLICT 本机已有的业务数据或在跑的服务   REPLACE 系统配置：原有的留 .bak 再换   KEEP 保留本机的
# SKIP 不放   DUP 被更新的包覆盖
PL_ACT=() PL_NOTE=() PROJ_DIRS=()
declare -A SEEN=()
plan() {
  local n k dst src t acc sql c tag u h o dbs=""
  for n in "${!IT_KIND[@]}"; do
    case "${IT_KIND[n]}" in
      mysql-db) dbs="$dbs,${IT_DST[n]}" ;;
      compose-project) PROJ_DIRS+=("${IT_DST[n]}") ;;
    esac
  done
  for n in "${!IT_KIND[@]}"; do
    k=${IT_KIND[n]} dst=${IT_DST[n]} src=${IT_SRC[n]}
    PL_ACT[n]=PLACE PL_NOTE[n]=""
    case "$k" in file|dir|sqlite|systemd-unit) c=$(path_class "$n") ;; *) c="" ;; esac
    # 两个包都带的同一路径 / 同一个库（vw 与 xboard 都收系统配置和全部业务库）：较新的包说了算
    case "$k" in
      file|dir|sqlite|systemd-unit) t="path:$dst" ;;
      mysql-db) t="db:$dst" ;;
      *) t="" ;;
    esac
    if [ -n "$t" ]; then
      [ -n "${SEEN[$t]:-}" ] && PL_ACT[${SEEN[$t]}]=DUP PL_NOTE[${SEEN[$t]}]="${P_TIME[IT_PKG[n]]} 的包里也有，用它的"
      SEEN[$t]=$n
    fi
    if [ "$c" = skip ]; then
      PL_ACT[n]=SKIP
      case "$dst" in "$OPS_ENV_FILE"|"$(dirname "$OPS_ENV_FILE")") PL_NOTE[n]="env.conf 按键合并，不整个放回" ;; *) PL_NOTE[n]="演练不放" ;; esac
      continue
    fi
    case "$k" in
      file|sqlite|systemd-unit)
        if [ -e "$dst" ] || [ -L "$dst" ]; then
          if cmp -s "$src" "$dst"; then PL_ACT[n]=SAME
          elif by_set PLACED "$dst"; then PL_ACT[n]=OURS
          elif [ "$c" = keep ]; then PL_ACT[n]=KEEP
          elif [ "$c" = sys ]; then PL_ACT[n]=REPLACE
          else PL_ACT[n]=CONFLICT PL_NOTE[n]="已存在且内容不同"; fi
        fi ;;
      dir)
        if [ -d "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then PL_ACT[n]=SAME
        elif [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
          if by_set PLACED "$dst"; then PL_ACT[n]=OURS
          elif [ "$c" = keep ]; then PL_ACT[n]=KEEP
          elif [ "$c" = sys ]; then PL_ACT[n]=REPLACE
          else PL_ACT[n]=CONFLICT PL_NOTE[n]="目录已存在且非空"; fi
        elif [ -e "$dst" ] && [ ! -d "$dst" ]; then
          if [ "$c" = sys ]; then PL_ACT[n]=REPLACE; else PL_ACT[n]=CONFLICT PL_NOTE[n]="已存在同名文件"; fi
        fi ;;
      mysql-db)
        [[ $dst =~ ^[A-Za-z0-9_]+$ ]] || die "库名不合规：$dst"
        if [ "$MYSQL_OK" = 1 ]; then
          t=$(db_tables "$dst")
          if [ "${t:-0}" -gt 0 ]; then
            if by_set DBDONE "$dst"; then PL_ACT[n]=OURS
            elif by_set DBSTART "$dst"; then PL_ACT[n]=REDO
            else PL_ACT[n]=CONFLICT PL_NOTE[n]="库已存在，有 $t 张表"; fi
          fi
        else
          PL_ACT[n]=UNKNOWN PL_NOTE[n]="MySQL 不可用，没法判断"
        fi ;;
      mysql-user)
        sql="${P_DIR[IT_PKG[n]]}/users.$n.sql"
        acc=$(python3 -c "$USER_PY" "$src" "$DB_CLIENT_HOST" "${dbs#,}" "$sql") || die "账号 SQL 不合规：$src"
        while IFS=$'\t' read -r tag u h o; do
          case "$tag" in
            SKIP) log "不恢复账号 $u@'$h'：$o" ;;
            ROOT) log "原机的 $u@'$h' 在包里：正式恢复时最后再改（演练不动本机 root）" ;;
          esac
        done <<<"$acc"
        acc=$(awk -F'\t' '$1 == "ACC" { print $2 "\t" $3 "\t" $4 }' <<<"$acc")
        IT_SRC[n]=$sql IT_ACC[n]=$acc
        PL_NOTE[n]=$(awk -F'\t' '{ printf "%s@%s ", $1, $2 }' <<<"$acc")
        while IFS=$'\t' read -r u h o; do
          [ -n "$u" ] || continue
          [ "$h" = "$o" ] || log "账号 $u@'$o' 改为 $u@'$h'（DB_CLIENT_HOST）"
          [[ $u =~ ^[A-Za-z0-9_.-]+$ && $h =~ ^[A-Za-z0-9_.%:/-]+$ ]] || die "账号名不合规：$u@$h"
          if [ "$MYSQL_OK" = 1 ] && acct_exists "$u" "$h" && ! st_rows USER | awk -F'\t' -v u="$u" -v h="$h" '$2 == u && $3 == h { f = 1 } END { exit !f }'; then
            PL_ACT[n]=CONFLICT PL_NOTE[n]="${PL_NOTE[n]}（$u@$h 本机已有）"
          fi
        done <<<"$acc" ;;
      compose-project)
        if [ -d "$dst" ] && command -v docker >/dev/null 2>&1 \
           && [ -n "$(cd "$dst" && docker compose ps -q --status running 2>/dev/null)" ]; then
          if by_set PLACED "$dst"; then PL_ACT[n]=OURS
          else PL_ACT[n]=CONFLICT PL_NOTE[n]="有容器在跑"; fi
        fi
        t=$(proj_unpinned "$dst"); [ -n "$t" ] && PL_NOTE[n]="${PL_NOTE[n]:+${PL_NOTE[n]}；}镜像锁不住版本：$t" ;;
    esac
  done
}

# 输出每行一条：ACC 账号 新host 原host / SKIP 账号 host 原因 / ROOT 账号 host。
# root@回环 的语句另写到 <out>.root，由调用方决定要不要执行（放在最后，且要有原机的 root 凭据文件）
USER_PY=$(cat <<'PY'
import re, sys
src, client, dbs, out = sys.argv[1:5]
dbs = set(d for d in dbs.split(',') if d)
SYS = {'mysql.sys', 'mysql.session', 'mysql.infoschema', 'debian-sys-maint', 'mariadb.sys', 'mysql'}
LOOP = ('localhost', '127.0.0.1', '::1')
ACC = re.compile(r"""([`'"])([^`'"]*)\1@([`'"])([^`'"]*)\3""")
OK = re.compile(r'^(CREATE USER|ALTER USER|GRANT|FLUSH PRIVILEGES|SET DEFAULT ROLE)\b', re.I)
text = open(src, encoding='utf-8').read()
stmts = [s.strip() for s in re.split(r';[ \t]*(?:\r?\n|$)', text)]
stmts = [s for s in stmts if s and not s.startswith('--') and not s.startswith('#')]
def maphost(h):
    # 回环与主机名照旧（本机进程、host 网络的容器、备份脚本在用）；
    # % 与具体 IP（旧容器地址、旧机地址）、网段通配换成本机的 DB_CLIENT_HOST
    if h in ('localhost', '127.0.0.1', '::1'):
        return h
    if h == '%' or '%' in h or '/' in h or re.fullmatch(r'[0-9.]+', h):
        return client
    return h
granted = set()
for s in stmts:
    if not OK.match(s):
        sys.exit('不允许的语句（只接受 CREATE USER / ALTER USER / GRANT）：' + s[:80])
    m = re.match(r'GRANT\s.+?\sON\s+(?:TABLE\s+)?[`\'"]?([^`\'".\s]+)[`\'"]?\.', s, re.I | re.S)
    if m and m.group(1).replace('\\_', '_') in dbs:
        for a in ACC.finditer(s[m.end():]):
            granted.add(a.group(2))
# 只在本机登录的账号（管理、备份用，如 bkroot@localhost，MYSQL_DEFAULTS_FILE 可能就用它）即使只有全局权限也恢复
local_only = {}
for s in stmts:
    for a in ACC.finditer(s):
        local_only[a.group(2)] = local_only.get(a.group(2), True) and a.group(4) in LOOP
keep, accts, created, roots, skipped = [], [], set(), [], {}
for s in stmts:
    found = [(a.group(2), a.group(4)) for a in ACC.finditer(s)]
    if not found:
        continue
    # MariaDB 默认的 GRANT PROXY ON ''@'%' TO root@localhost：''@'%' 只是代理对象，不是要建的账号
    if re.match(r'GRANT\s+PROXY\s', s, re.I):
        found = [(u, h) for u, h in found if u != ''] or found
    if all(u == 'root' for u, _ in found):
        if all(h in LOOP for _, h in found):
            roots.append(s)
        else:
            for u, h in found:
                skipped[(u, h)] = 'root 只从本机登录，不恢复远程 root'
        continue
    # 系统账号、对恢复的库没有授权的账号一律不碰（面板、MySQL 自己的账号）
    bad = [(u, h) for u, h in found if u in SYS or u == 'root' or (u not in granted and not local_only.get(u))]
    if bad:
        for u, h in bad:
            skipped[(u, h)] = '系统账号' if u in SYS or u == 'root' else '对恢复的库没有授权'
        continue
    def sub(a):
        h = maphost(a.group(4))
        if (a.group(2), h) not in [x[:2] for x in accts]:
            accts.append((a.group(2), h, a.group(4)))
        return "'%s'@'%s'" % (a.group(2), h)
    s2 = ACC.sub(sub, s)
    if re.match(r'CREATE USER', s2, re.I):
        key = tuple(ACC.findall(s2)[0][1::2])
        if key in created:
            continue          # 两个原 host 映射到同一个新 host，只建一次
        created.add(key)
    keep.append(s2)
with open(out, 'w', encoding='utf-8') as f:
    for u, h, _ in accts:
        f.write("DROP USER IF EXISTS '%s'@'%s';\n" % (u, h))
    for s in keep:
        f.write(s + ';\n')
with open(out + '.root', 'w', encoding='utf-8') as f:
    for s in roots:
        f.write(s + ';\n')
for a in accts:
    print('\t'.join(('ACC',) + a))
for (u, h), why in skipped.items():
    print('\t'.join(('SKIP', u or "''", h or "''", why)))
for h in sorted(set(a.group(4) for s in roots for a in ACC.finditer(s) if a.group(2) == 'root')):
    print('\t'.join(('ROOT', 'root', h)))
PY
)

show_plan() {
  local n a lab c_conf=0
  section "恢复计划"
  for n in "${!IT_KIND[@]}"; do
    a=${PL_ACT[n]}
    case "$a" in
      PLACE) lab="放置" ;; SAME) lab="相同·跳过" ;; OURS) lab="已恢复·跳过" ;; REDO) lab="重导" ;;
      KEEP) lab="保留本机" ;; DUP) lab="被新包覆盖" ;; UNKNOWN) lab="未知" ;;
      REPLACE) lab="替换·留bak" ;; SKIP) lab="不放" ;;
      CONFLICT) lab="冲突"; c_conf=$((c_conf + 1)) ;;
    esac
    printf '  %-12s %-16s %s%s\n' "$lab" "${IT_KIND[n]}" "${IT_DST[n]}" "${PL_NOTE[n]:+  ${PL_NOTE[n]}}"
  done
  if [ -s "$PROJ" ]; then
    section "镜像版本"
    awk -F'\t' '{ printf "  %s  %s 的 %s：%s（来源：%s；原值 %s）\n", ($5 == "ok" ? "锁定  " : "锁不住"), $1, $2, $4, $6, $7 }' "$PROJ"
  fi
  CONFLICTS=$c_conf
}

# ── 执行 ────────────────────────────────────────────────────
mkparent() {  # mkparent <目录>：建出目录，新建的最上层记进状态（teardown 删它）
  local d=$1 top=""
  while [ ! -e "$d" ]; do top=$d; d=$(dirname "$d"); done
  [ -n "$top" ] || return 0
  mkdir -p "$1" && st_add CREATED "$top"
}

touched_under() {  # 这次有没有放下 <前缀> 开头的路径
  local n
  for n in "${!IT_KIND[@]}"; do
    case "${PL_ACT[n]}" in PLACE|CONFLICT|REPLACE) [[ ${IT_DST[n]} == "$1"* ]] && return 0 ;; esac
  done
  return 1
}

PLACED_NOW=()
inside_placed() {  # 目标在这次刚整棵放下的目录里（清单里父目录在前、子路径在后）
  local d
  for d in "${PLACED_NOW[@]}"; do [[ $1 == "$d"/* ]] && return 0; done
  return 1
}

place() {  # place <序号>
  local n=$1 k=${IT_KIND[$1]} dst=${IT_DST[$1]} src=${IT_SRC[$1]} existed=0 empty=0 c b
  { [ -e "$dst" ] || [ -L "$dst" ]; } && existed=1
  if inside_placed "$dst"; then
    existed=1                                     # 父目录刚放下，子路径只替换它自己，不再留 .bak
    [ "$k" = dir ] && rm -rf "$dst"
  elif [ "$existed" = 1 ] && { [ "${PL_ACT[n]}" = CONFLICT ] || [ "${PL_ACT[n]}" = REPLACE ]; }; then
    # CONFLICT 只有 --force 走到这里；REPLACE 是系统配置
    b="$dst.bak.$TS"; c=1
    while [ -e "$b" ] || [ -L "$b" ]; do c=$((c + 1)); b="$dst.bak.$TS.$c"; done
    mv -T "$dst" "$b" || die "移不开 $dst"
    st_add MOVED "$dst" "$b"; log "[备份] $dst -> $b"; existed=0
  fi
  if [ "$k" = dir ]; then
    [ "$existed" = 1 ] && [ -z "$(ls -A "$dst")" ] && empty=1
    mkparent "$dst"
    cp -a "$src/." "$dst/" || die "放置失败：$dst"
    # 原本就有的空目录：里面放进去的东西逐个记下，teardown 才删得干净
    [ "$empty" = 1 ] && for c in "$dst"/* "$dst"/.[!.]*; do [ -e "$c" ] && st_add CREATED "$c"; done
  else
    mkparent "$(dirname "$dst")"
    cp -a "$src" "$dst" || die "放置失败：$dst"
  fi
  [ "${IT_MODE[n]}" = - ] || chmod "${IT_MODE[n]}" "$dst"
  [ "${IT_OWN[n]}" = - ] || chown "${IT_OWN[n]}" "$dst" || warn "改属主失败：$dst -> ${IT_OWN[n]}"
  [ "$existed" = 1 ] || st_add CREATED "$dst"
  st_add PLACED "$dst" "${P_SHA[IT_PKG[n]]}"
  [ "$k" = dir ] && PLACED_NOW+=("$dst")
  case "$dst" in /root/.ssh|/root/.ssh/authorized_keys) merge_keys ;; esac
  ok "$dst"
}

# 原机的 /root/.ssh 放回后，把恢复前本机能登录的公钥并回去：
# 引导这台新机用的钥匙不一定在原机的 authorized_keys 里，直接替换会把自己锁在外面
AK_BEFORE=""
merge_keys() {
  local ak=/root/.ssh/authorized_keys l added=0
  [ -s "$AK_BEFORE" ] || return 0
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  touch "$ak" && chmod 600 "$ak"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    grep -qxF -- "$l" "$ak" || { printf '%s\n' "$l" >> "$ak"; added=$((added + 1)); }
  done < "$AK_BEFORE"
  [ "$added" = 0 ] || ok "authorized_keys 并回了恢复前本机的 $added 把公钥"
}

keep_local() {  # keep_local <序号>：本机的保留，原机的另存 .from-backup 备查
  local n=$1 dst=${IT_DST[$1]}
  rm -rf "$dst.from-backup"
  cp -a "${IT_SRC[n]}" "$dst.from-backup" && st_add CREATED "$dst.from-backup"
  log "保留本机的 $dst；原机的另存为 $dst.from-backup"
}

# 面板的配置与数据库要在面板停着时替换，放完再启动（整体放回面板这条路还没在真机验证过）
PANEL_STOPPED=0
panel_stop_if_touched() {
  local n
  [ -n "${PANEL_ROOT:-}" ] && [ -x /etc/init.d/bt ] || return 0
  for n in "${!IT_KIND[@]}"; do
    case "${PL_ACT[n]}" in PLACE|REPLACE|CONFLICT) ;; *) continue ;; esac
    case "${IT_DST[n]}" in "$PANEL_ROOT"/config*|"$PANEL_ROOT"/data*|"$PANEL_ROOT"/ssl*)
      log "停止面板再替换它的配置与数据"
      /etc/init.d/bt stop >/dev/null 2>&1 || warn "面板停不下来"
      PANEL_STOPPED=1; return 0 ;;
    esac
  done
}

apply_db() {  # apply_db <序号>
  local n=$1 db=${IT_DST[$1]} dump=${IT_SRC[$1]} sha=${P_SHA[IT_PKG[$1]]} before t want cs=utf8mb4 co=utf8mb4_unicode_ci row
  # 原机各库的字符集与排序规则（新包的 db/databases.tsv：库名 字符集 排序规则）
  row=$(awk -F'\t' -v d="$db" '$1 == d { print $2 "\t" $3; exit }' "$(dirname "$dump")/databases.tsv" 2>/dev/null)
  if [[ ${row%%$'\t'*} =~ ^[A-Za-z0-9_]+$ && ${row#*$'\t'} =~ ^[A-Za-z0-9_]+$ ]]; then cs=${row%%$'\t'*} co=${row#*$'\t'}; fi
  case "${PL_ACT[n]}" in
    CONFLICT)
      before="$DR_ROOT/before-$db-$TS.sql.gz"
      mydump --single-transaction --routines --triggers --events "$db" | gzip > "$before" || die "导出原有库 $db 失败，不删它"
      st_add MOVED "mysql:$db" "$before"; log "[备份] 原有库 $db -> $before"
      my -e "DROP DATABASE \`$db\`" || die "删不掉原有库 $db" ;;
    REDO)
      log "库 $db 是上次没导完的，删掉重导"
      my -e "DROP DATABASE \`$db\`" || die "删不掉 $db" ;;
  esac
  if ! db_exists "$db"; then
    st_rows MOVED | cut -f2 | grep -qx "mysql:$db" || st_add DBCREATED "$db"
    my -e "CREATE DATABASE \`$db\` DEFAULT CHARACTER SET $cs COLLATE $co" || die "建库 $db 失败"
  fi
  st_add DBSTART "$db" "$sha"
  log "导入 $db ..."
  if [[ $dump == *.gz ]]; then zcat "$dump"; else cat "$dump"; fi | my "$db" \
    || die "导入 $db 失败（重跑本脚本会删掉这次导了一半的库重来）"
  t=$(db_tables "$db"); want=$(dump_tables "$dump")
  if [ "${t:-0}" -ge "$want" ]; then ok "库 $db：$t 张表"; else warn "库 $db 只有 $t 张表，dump 里有 $want 张"; fi
  st_add DBDONE "$db" "$sha"
}

apply_users() {  # apply_users <序号>：先 DROP USER IF EXISTS 再建，重跑结果一样
  local n=$1 u h o
  my < "${IT_SRC[n]}" || die "建账号失败（${IT_SRC[n]}）"
  while IFS=$'\t' read -r u h o; do
    [ -n "$u" ] || continue
    st_add USER "$u" "$h"
    if [ "$o" = "$h" ]; then ok "账号 $u@'$h'"; else ok "账号 $u@'$h'（原机是 '$o'）"; fi
  done <<<"${IT_ACC[n]}"
}

# root 最后改：面板存着原机的 root 密码（面板数据整体放回了），root 跟原机一致面板才管得了库。演练不动 root。
# 原机的 MYSQL_DEFAULTS_FILE（可能用 root，也可能用 bkroot 这类本机管理账号）先拿来试连，连得上才换成它
apply_root() {
  local n sql="" cnf=""
  [ "$DRILL" = 1 ] && return 0
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = mysql-user ] && [ "${PL_ACT[n]}" != DUP ] && [ -s "${IT_SRC[n]}.root" ] && sql="${IT_SRC[n]}.root"
    [ "${IT_KIND[n]}" = file ] && [ "${IT_DST[n]}" = "$MYSQL_DEFAULTS_FILE" ] && [ "${PL_ACT[n]}" != DUP ] && cnf=${IT_SRC[n]}
  done
  if [ -n "$sql" ]; then
    if [ -z "$cnf" ]; then
      manual "MySQL root 保持新机的设置" "包里有原机的 root 账号，但没有原机的 $MYSQL_DEFAULTS_FILE：改了可能再没有凭据能连库"
    elif my < "$sql"; then
      ok "root@localhost 已按原机设置"
    else
      warn "把 root 改成原机的设置失败（新旧 MySQL / MariaDB 的认证写法不同？），保留新机的 root"
    fi
  fi
  [ -n "$cnf" ] && ! cmp -s "$cnf" "$MYSQL_DEFAULTS_FILE" || return 0
  if mysql --defaults-file="$cnf" -e 'SELECT 1' >/dev/null 2>&1; then
    cp -a "$MYSQL_DEFAULTS_FILE" "$MYSQL_DEFAULTS_FILE.bak.$TS"
    cp -a "$cnf" "$MYSQL_DEFAULTS_FILE" && chmod 600 "$MYSQL_DEFAULTS_FILE"
    ok "$MYSQL_DEFAULTS_FILE 换成原机的（试连通过；新机原来的在 .bak.$TS）"
  else
    warn "原机的 $MYSQL_DEFAULTS_FILE 在这台机器上连不上，保留新机的"
    manual "核对 $MYSQL_DEFAULTS_FILE：原机的另存为 .from-backup，连不上本机 MySQL" \
           "它用的账号或密码没随包恢复成功；面板若存着原机的 root 密码，要在面板里改成现在的"
  fi
}

stop_touched_projects() {  # 要改动的数据在一个正在跑的项目里：先停项目，再换文件（SQLite 尤其不能边跑边换）
  local p n d touched
  command -v docker >/dev/null 2>&1 || return 0
  for p in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[p]}" = compose-project ] || continue
    d=${IT_DST[p]}; [ -d "$d" ] || continue
    touched=0
    for n in "${!IT_KIND[@]}"; do
      case "${PL_ACT[n]}:${IT_KIND[n]}" in
        PLACE:file|PLACE:dir|PLACE:sqlite|CONFLICT:file|CONFLICT:dir|CONFLICT:sqlite)
          [[ ${IT_DST[n]} == "$d" || ${IT_DST[n]} == "$d"/* ]] && touched=1 ;;
      esac
    done
    [ "$touched" = 1 ] || continue
    if [ -n "$(cd "$d" && docker compose ps -q --status running 2>/dev/null)" ]; then
      log "停止 $d 的容器再替换数据"
      (cd "$d" && docker compose stop) || die "停不下 $d 的容器"
    fi
  done
}

sqlite_checks() {
  local n r
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = sqlite ] || continue
    case "${PL_ACT[n]}" in PLACE|CONFLICT|SAME|OURS) ;; *) continue ;; esac
    r=$(sqlite3 "${IT_DST[n]}" 'PRAGMA integrity_check;' 2>&1 | head -1)
    if [ "$r" = ok ]; then ok "${IT_DST[n]}：integrity_check ok"
    else warn "${IT_DST[n]}：integrity_check 不通过（$r）"; fi
  done
}

ufw_db_rule() {  # 容器访问宿主机 3306：漏了这条是延迟发作的全站 503（见包里 RESTORE.md）
  [ -n "${DOCKER_CIDR:-}" ] || { warn "DOCKER_CIDR 没填，不放行容器访问 3306"; return 0; }
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active' || return 0
  ufw status | grep -qE "3306.*${DOCKER_CIDR//./\\.}" && return 0
  ufw allow from "$DOCKER_CIDR" to any port 3306 proto tcp >/dev/null && st_add UFW "$DOCKER_CIDR" \
    && ok "ufw 已放行 $DOCKER_CIDR -> 3306"
}

install_script() {  # install_script <脚本名>：本机没装就经 opsget 装上（只装不跑）
  local p
  [ -x "$BIN/$1.sh" ] && return 0
  command -v opsget >/dev/null 2>&1 || return 1
  p=$(opsget -l 2>/dev/null | grep -oE '^[a-z]+/[A-Za-z0-9_-]+' | awk -F/ -v n="$1" '$2 == n' | head -1)
  [ -n "$p" ] && opsget -i "$p" >/dev/null 2>&1 && [ -x "$BIN/$1.sh" ]
}

# 原机 crontab：调用本地脚本的行照搬（脚本没装就先装），面板的计划任务列进手动步骤；
# 备份任务最后交给 install-backup-cron 按统一时间表重排
restore_cron() {
  local n f line cur new s skip kinds="" p bak
  cur=$(mktemp); new=$(mktemp)
  crontab -l > "$cur" 2>/dev/null || : > "$cur"
  mkdir -p /root/ops-backups; bak="/root/ops-backups/crontab.$TS"; cp "$cur" "$bak"
  cp "$cur" "$new"
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = crontab ] || continue
    f=${IT_SRC[n]}
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
      if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        if ! grep -qE "^[[:space:]]*${BASH_REMATCH[1]}=" "$new"; then
          { printf '%s\n' "$line"; cat "$new"; } > "$new.t" && mv "$new.t" "$new"
        fi
        continue
      fi
      if [[ $line == */www/server/* ]]; then
        # 新包把面板计划任务的脚本体（PANEL_CRON_DIR）一起放回了；脚本在，这行就照装
        s=$(grep -oE '/www/server/[^[:space:]>;|&]+' <<<"$line" | head -1)
        if [ ! -e "$s" ]; then
          manual "面板计划任务：$line" "它调用的 $s 不在本机（旧版备份包不收面板计划任务的脚本），要在面板里重建（opsget ops/panel-cron-inspect 可查原命令）"
          continue
        fi
        grep -qxF -- "$line" "$new" || printf '%s\n' "$line" >> "$new"
        continue
      fi
      if [[ $line == *opsget* ]]; then
        warn "原机 crontab 里有调用 opsget 的行，不照搬（cron 只调用本地脚本）：$line"; continue
      fi
      skip=0
      for s in $(grep -oE "$BIN/[A-Za-z0-9_.-]+\.sh" <<<"$line" | sort -u); do
        install_script "$(basename "$s" .sh)" || { skip=1; manual "定时任务没恢复：$line" "它调用的 $s 本机没有，仓库 MANIFEST 里也找不到"; }
      done
      [ "$skip" = 0 ] || continue
      grep -qxF -- "$line" "$new" && continue
      for s in $(grep -oE "$BIN/[A-Za-z0-9_.-]+\.sh" <<<"$line" | sort -u); do
        grep -vF -- "$s" "$new" > "$new.t"; mv "$new.t" "$new"
      done
      printf '%s\n' "$line" >> "$new"
    done < "$f"
  done
  if ! cmp -s "$cur" "$new"; then
    crontab "$new" || die "写入 crontab 失败（原内容在 $bak）"
    ok "原机的定时任务已并入（改前的 crontab 在 $bak）"
  fi
  rm -f "$cur" "$new"
  for n in "${!P_KIND[@]}"; do kinds="$kinds ${P_KIND[n]}"; done
  for s in vw-fullbackup xboard-fullbackup; do
    [[ $kinds == *" ${s%%-*}"* ]] || continue
    install_script "$s" || manual "装不上 $s" "opsget 不可用或拉不到仓库"
  done
  if install_script install-backup-cron; then
    "$BIN/install-backup-cron.sh" --apply || warn "定时任务安装器报错"
  else
    manual "备份定时任务没排上：opsget ops/install-backup-cron --apply" "装不上 install-backup-cron（opsget 不可用或拉不到仓库）"
  fi
  # 备份脚本的依赖（7z、rclone、sqlite3、msmtp）
  p=""; for s in ${BACKUP_DEPS:-p7zip-full rclone sqlite3 msmtp msmtp-mta}; do dpkg -s "$s" >/dev/null 2>&1 || p="$p $s"; done
  if [ -n "$p" ]; then
    log "安装备份依赖:$p"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq $p >/dev/null || warn "备份依赖没装全:$p"
  fi
  [ -f /etc/msmtprc ] || manual "告警邮件：/etc/msmtprc 不在本机" "旧版备份包不收它；照原机配置补上后用 opsget ops/mail-doctor --send 验证"
}

apply_all() {
  local n
  [ -n "$(st_mode)" ] || st_add MODE "$([ "$DRILL" = 1 ] && echo drill || echo real)"
  for n in "${!P_FILE[@]}"; do st_add PKG "${P_KIND[n]}" "${P_SHA[n]}" "${P_FILE[n]}" "$TS"; done
  section "写入配置"
  if [ ${#ENV_FILLED[@]} -gt 0 ]; then
    cp -a "$OPS_ENV_FILE" "$OPS_ENV_FILE.bak.$TS" && st_add ENVBAK "$OPS_ENV_FILE.bak.$TS"
    cp "$ENV_MERGED" "$OPS_ENV_FILE" && chmod 600 "$OPS_ENV_FILE" && ok "env.conf 补了 ${#ENV_FILLED[@]} 个键（原文件 $OPS_ENV_FILE.bak.$TS）"
  else
    log "env.conf 不用改"
  fi
  stop_touched_projects
  section "数据库"
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = mysql-db ] || continue
    case "${PL_ACT[n]}" in PLACE|REDO|CONFLICT) apply_db "$n" ;; *) log "库 ${IT_DST[n]}：已恢复过，跳过" ;; esac
  done
  for n in "${!IT_KIND[@]}"; do [ "${IT_KIND[n]}" = mysql-user ] && apply_users "$n"; done
  apply_root
  printf '%s\n' "${IT_KIND[@]}" | grep -qx mysql-db && ufw_db_rule
  section "文件与数据目录"
  AK_BEFORE="$DR_ROOT/authorized_keys.before.$TS"
  cp /root/.ssh/authorized_keys "$AK_BEFORE" 2>/dev/null || : > "$AK_BEFORE"
  panel_stop_if_touched
  for n in "${!IT_KIND[@]}"; do
    case "${IT_KIND[n]}" in
      file|dir|sqlite|systemd-unit)
        case "${PL_ACT[n]}" in
          PLACE|CONFLICT|REPLACE) place "$n" ;;
          KEEP) [ "${IT_DST[n]}" = "$MYSQL_DEFAULTS_FILE" ] && cmp -s "${IT_SRC[n]}" "${IT_DST[n]}" || keep_local "$n" ;;
        esac ;;
    esac
  done
  sqlite_checks
  if [ "$PANEL_STOPPED" = 1 ]; then
    /etc/init.d/bt start >/dev/null 2>&1 && ok "面板已重新启动" || warn "面板没起来：/etc/init.d/bt start"
  fi
  # compose 项目记为本批包恢复的：重跑时它的容器在跑不算「别人的服务」，teardown 也据此停容器
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = compose-project ] && st_add PLACED "${IT_DST[n]}" "${P_SHA[IT_PKG[n]]}"
  done
  touched_under /etc/systemd && { systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload 失败"; }
  touched_under /etc/sysctl && { sysctl --system >/dev/null 2>&1 && ok "内核参数已按原机生效" || warn "sysctl --system 失败"; }
  if touched_under /etc/ssh || touched_under /etc/ufw || touched_under /etc/default/ufw || touched_under /etc/fail2ban; then
    manual "重启机器（或 systemctl restart ssh; ufw reload; systemctl restart fail2ban），让原机的 SSH、防火墙、封禁配置生效" \
           "原机的 SSH 端口与放行规则可能和现在不同，自动重载会把正在用的 SSH 会话关在外面；先核对端口再重载"
  fi
  touched_under /etc/ssh/ssh_host_ && manual "客户端的 known_hosts 里删掉本机新 IP 的旧记录" \
    "主机密钥换成了原机的（DNS 切过来后客户端看到的指纹不变），但引导期间用新 IP 连过的客户端会报主机密钥变更"
  [ "$PANEL_STOPPED" = 1 ] && manual "登录面板核对站点、计划任务、证书续期记录" "面板配置与数据库整体放回的路径还没在真机验证过"
  if [ "$DRILL" = 1 ]; then
    log "演练：不装定时任务（会从这台机器往生产网盘传包、并按保留期删云端旧包）"
  else
    section "定时任务"
    restore_cron
  fi
}

# ── 启动 ────────────────────────────────────────────────────
ensure_docker() {
  docker info >/dev/null 2>&1 && return 0
  if ! command -v docker >/dev/null 2>&1; then
    log "安装 docker（官方 apt 源）"
    . /etc/os-release
    ensure_cmds curl:curl gpg:gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc || die "取不到 docker 源的公钥"
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null || die "docker 安装失败"
    st_add DOCKER_INSTALLED
  fi
  systemctl enable --now docker >/dev/null 2>&1
  docker info >/dev/null 2>&1 || die "docker 起不来"
}

post_start() {  # post_start <项目目录>：包里 RESTORE.md 要求的启动后步骤
  local d=$1 svc img
  while IFS=$'\t' read -r svc img; do
    case "$img" in
      *vaultwarden/server*)
        case "$(cd "$d" && docker compose exec -T "$svc" printenv ADMIN_TOKEN 2>/dev/null | head -c 12)" in
          '$argon2id$v='*|'') ok "Vaultwarden ADMIN_TOKEN 格式正常（或未设）" ;;
          *) warn "Vaultwarden ADMIN_TOKEN 不是 \$argon2id\$ 哈希：vaultwarden.env 里的 \$ 可能被转义错了" ;;
        esac ;;
      *cedar2025/xboard*)
        # 顺序照 Xboard 的 RESTORE.md：Redis 属主修复 → config:cache。绝不跑 xboard:install（会重置 APP_KEY、清库）
        sleep 15
        if [ "$(cd "$d" && docker compose exec -T "$svc" redis-cli -s /data/redis.sock ping 2>/dev/null | tr -d '\r')" != PONG ]; then
          log "Xboard 的 Redis 没响应，修属主"
          (cd "$d" && docker compose exec -T -u root "$svc" chown -R redis:redis /data && docker compose restart) >/dev/null \
            || warn "Xboard Redis 属主修复失败"
          sleep 10
        fi
        (cd "$d" && docker compose exec -T "$svc" php artisan config:cache) >/dev/null && ok "Xboard config:cache" \
          || warn "Xboard config:cache 失败" ;;
    esac
  done < <(awk -F'\t' -v d="$d" '$1 == d { print $2 "\t" $4 }' "$PROJ")
}

nginx_step() {
  local ng n f inc out rc miss="" confs=()
  for n in "${!IT_KIND[@]}"; do
    [[ ${IT_DST[n]} == "$PANEL_VHOST_DIR"/*.conf ]] && confs+=("${IT_DST[n]}")
  done
  [ ${#confs[@]} -gt 0 ] || return 0
  section "nginx"
  # 面板站点的 conf 会 include 伪静态、反代等文件；当前备份包只收了 conf 本身
  for f in "${confs[@]}"; do
    while read -r inc; do
      [[ $inc == *'*'* ]] && continue
      [ -e "$inc" ] || miss="$miss $inc"
    done < <(sed -nE 's/^[[:space:]]*include[[:space:]]+([^;[:space:]]+);.*/\1/p' "$f" 2>/dev/null)
  done
  [ -n "$miss" ] && manual "nginx 引用的这些文件不在本机，也不在包里:$miss" "当前备份包只收 vhost 目录顶层的 *.conf；伪静态、反代配置要照原机补（备份脚本正在补收）"
  ng=$(nginx_bin)
  if [ -z "$ng" ]; then
    manual "装 nginx（或宝塔面板）后执行 nginx -t && nginx -s reload" "本机没有 nginx，站点配置已放好"
    return 0
  fi
  if [ "$NOSTART" = 1 ]; then printf '    %s -t && %s -s reload\n' "$ng" "$ng"; return 0; fi
  out=$("$ng" -t 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  if [ "$rc" -eq 0 ]; then
    { "$ng" -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || "$ng"; } && ok "nginx 已重载"
  else
    warn "nginx -t 不通过，没有重载（见上）"
    manual "修好 nginx 配置后 nginx -t && nginx -s reload" "nginx -t 报错，重载会让本机所有站点一起失效"
  fi
}

start_all() {
  local n d un
  section "启动"
  if [ "$NOSTART" = 1 ]; then log "--no-start：以下命令没有执行"; else ensure_docker; fi
  if [ "$NOSTART" = 0 ] && touched_under /etc/docker/daemon.json; then
    systemctl restart docker && ok "docker 已按原机的 daemon.json 重启" || warn "docker 重启失败"
  fi
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = compose-project ] || continue
    d=${IT_DST[n]}
    [ -d "$d" ] || { warn "$d 不存在，跳过"; continue; }
    un=$(proj_unpinned "$d")
    if [ -n "$un" ]; then
      warn "$d：$un镜像锁不住版本，不启动（绝不拉 latest）"
      manual "给 $d 的 $un指定镜像版本后启动：restore … --image 名称=镜像@sha256:…，或改 compose 后 docker compose up -d" \
             "备份清单里只有 latest 这类浮动标签；拉最新版可能触发数据库结构迁移，把按旧版恢复的库改掉"
      continue
    fi
    if [ "$NOSTART" = 1 ]; then printf '    cd %s && docker compose pull && docker compose up -d\n' "$d"; continue; fi
    log "$d：拉取锁定版本的镜像并启动"
    (cd "$d" && docker compose pull -q && docker compose up -d) || { warn "$d 启动失败"; continue; }
    post_start "$d"
  done
  for n in "${!IT_KIND[@]}"; do
    [ "${IT_KIND[n]}" = systemd-unit ] || continue
    un=$(basename "${IT_DST[n]}")
    if [ "$DRILL" = 1 ]; then log "演练：$un 只放文件，不启用（隧道等单元会连到生产机）"; continue; fi
    if [ "$NOSTART" = 1 ]; then printf '    systemctl enable --now %s\n' "$un"; continue; fi
    systemctl enable --now "$un" >/dev/null 2>&1 && st_add UNIT "$un" && ok "$un 已启用" || warn "$un 启用失败"
  done
  nginx_step
  [ "$NOSTART" = 1 ] && return 0
  if command -v docker >/dev/null 2>&1; then
    echo; docker ps -a --format '  {{.Names}}\t{{.Image}}\t{{.Status}}'
  fi
}

probe_sites() {
  local f dom c
  [ "$NOSTART" = 1 ] && return 0
  section "本机预演访问（--resolve 到 127.0.0.1，不经 DNS）"
  for dom in $(for f in "$PANEL_VHOST_DIR"/*.conf; do [ -f "$f" ] && sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;]+);.*/\1/p' "$f"; done \
               | tr ' ' '\n' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | sort -u); do
    c=$(probe_domain_local "$dom"); printf '  %-40s %s\n' "$dom" "${c:-无响应}"
  done
}

summary() {
  local m ip i
  section "还要手动做的事"
  if [ "$DRILL" = 1 ]; then
    manual "演练结束后清理：restore-from-backup.sh teardown" "演练机上的恢复内容要删掉，避免留着生产数据的副本"
  else
    ip=$(curl -fsS -m 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{ print $1 }')
    manual "把各站点域名的 DNS 解析改到本机 ${ip:-（公网 IP）}；NAT 机器填公网出口" \
           "切换是把真实流量交给这台机器的最后一步，保留人工确认；不做 Cloudflare 自动切换：演练机上误跑一次就会劫持生产流量"
    manual "宝塔面板里「添加站点」认领这些 nginx 配置" "面板的站点记录在面板自己的库里，备份包只有 nginx 配置文件"
    manual "DNS 生效后在面板里逐站重新申请证书（EC256）" "证书文件已放好能用，但面板的续期记录不在包里，不重签到期那天全站一起挂"
    manual "确认无误后删掉 $DR_ROOT" "里面是解开的明文包：数据库 dump、密钥、证书私钥"
  fi
  if printf '%s\n' "${IT_DST[@]}" | grep -q '/komari\.db$'; then
    manual "Komari 的监控历史从零开始" "指标库体积大，按设计不进云端包；被控端的 agent token 在 komari.db 里，不用重装"
    for i in "${ORDER[@]}"; do
      [ -s "${P_X[i]}/komari/theme-list.txt" ] && manual "Komari 主题在面板里重新下载：$(tr '\n' ' ' < "${P_X[i]}/komari/theme-list.txt")" "主题可重新下载，备份按设计不收"
    done
  fi
  grep -q 'cedar2025/xboard' "$PROJ" 2>/dev/null \
    && manual "Xboard 节点：面板域名不变会自己重连；域名变了要逐台 xt node --panel https://新域名 ..." "节点在各自机器上，本机够不着"
  for m in "${MANUAL[@]}"; do
    printf '  • %s\n      原因：%s\n' "${m%%|*}" "${m#*|}"
  done
  section "接着验证"
  cat <<EOF
  1. opsget migrate/08-post-start-check     容器、库的连接来源、nginx、证书、反代端到端（切 DNS 前预演）
  2. opsget ops/preflight-backup            备份脚本的依赖与前置检查
  3. opsget ops/verify-backup-pass          云端的包能用本机密码打开
EOF
  [ "$DRILL" = 1 ] || echo "  4. 手动跑一次 /usr/local/bin/vw-fullbackup.sh 与 xboard-fullbackup.sh —— DNS 还没切，失败不影响任何人"
}

# ── 动作 ────────────────────────────────────────────────────
read_pass() {
  [ -n "$BACKUP_PASS_FILE" ] || die "配置项未填: BACKUP_PASS_FILE"
  [ -r "$BACKUP_PASS_FILE" ] || die "读不到备份密码文件 $BACKUP_PASS_FILE"
  PASS=$(head -n1 "$BACKUP_PASS_FILE" | tr -d '\r')
  [ -n "$PASS" ] || die "备份密码文件是空的"
}

prepare() {  # prepare <解开到的父目录>
  ensure_cmds 7z:p7zip-full python3:python3 sqlite3:sqlite3
  read_pass
  open_targets "$1"
  [ ${#P_FILE[@]} -gt 0 ] || die "没有可用的包"
  env_merge
  check_client_host
  MYSQL_OK=0; mysql_ok && MYSQL_OK=1
  collect_images
  build_items
  pin_projects
  plan
  show_plan
}

do_check() {
  # 下载、解开、中间文件全在临时目录，结束即删：检查不在本机留任何东西
  DR_ROOT=$(mktemp -d)
  trap 'rm -rf "$DR_ROOT"' EXIT
  prepare "$DR_ROOT"
  section "本机条件"
  if [ "$MYSQL_OK" = 1 ]; then ok "MySQL 可用（$(mysql --version 2>/dev/null | awk '{ print $3, $5 }')）"
  else warn "MySQL 不可用（$MYSQL_DEFAULTS_FILE）：恢复前先装好，版本照包里 manifest"; fi
  grep -h '^MySQL:' "${P_X[@]/%//manifest.txt}" 2>/dev/null | sed 's/^/  原机 /'
  [ -n "$(nginx_bin)" ] && ok "nginx：$(nginx_bin)" || warn "没有 nginx：站点配置会放好，但没法重载"
  docker info >/dev/null 2>&1 && ok "docker 可用" || log "docker 不可用：恢复时会从官方 apt 源安装"
  echo
  if [ "$CONFLICTS" -gt 0 ]; then
    warn "有 $CONFLICTS 处冲突：这台机器上已经有数据或在跑的服务。restore 会拒绝，除非加 --force（原有的先备份再覆盖）"
  else
    ok "没有冲突，可以 restore"
  fi
  log "包都解在临时目录，检查完已删除；本机没有任何改动"
  finish
}

do_restore() {
  local m; m=$(st_mode)
  [ "$m" = drill ] && [ "$DRILL" = 0 ] && die "这台机器做过演练恢复，先 teardown 再正式恢复"
  [ "$m" = real ] && [ "$DRILL" = 1 ] && die "这台机器做过正式恢复，不能在上面演练"
  mysql_ready
  mkdir -p "$DR_ROOT"; chmod 700 "$DR_ROOT"
  prepare "$DR_ROOT"
  if [ "$CONFLICTS" -gt 0 ]; then
    [ "$DRILL" = 1 ] && die "演练只在干净的机器上做：这台机器上已经有上面标「冲突」的数据或服务"
    [ "$FORCE" = 1 ] || die "这台机器上已经有数据或在跑的服务（上面标「冲突」的 $CONFLICTS 处）。确认是要覆盖的机器，加 --force：原有目录移到 .bak.$TS，原有库先导出到 $DR_ROOT 再删"
    confirm "覆盖以上 $CONFLICTS 处冲突（原有的先备份）？"
  fi
  apply_all
  start_all
  probe_sites
  summary
  finish
}

do_status() {
  [ -f "$ST" ] || { echo "这台机器没有用备份包恢复过（没有 $ST）"; return 0; }
  echo "模式：$(st_mode)"
  st_rows PKG | awk -F'\t' '{ printf "  包   %-7s %s（%s）\n", $2, $4, $5 }'
  st_rows DBDONE | awk -F'\t' '{ printf "  库   %s\n", $2 }' | sort -u
  st_rows USER | awk -F'\t' '{ printf "  账号 %s@%s\n", $2, $3 }' | sort -u
  echo "  放置 $(st_rows PLACED | cut -f2 | sort -u | wc -l) 个路径，移走 $(st_rows MOVED | wc -l) 个原有路径"
  st_rows MOVED | awk -F'\t' '{ printf "    %s -> %s\n", $2, $3 }'
  [ -d "$DR_ROOT" ] && echo "  暂存 $DR_ROOT（$(du -sh "$DR_ROOT" 2>/dev/null | cut -f1)，含明文）"
}

do_teardown() {
  local p u h ng
  [ -f "$ST" ] || die "没有恢复记录（$ST），没有可清理的"
  [ "$(st_mode)" = drill ] || die "这台机器是正式恢复（不是 --drill），teardown 会删掉在用的数据，拒绝"
  confirm "删除演练恢复出来的全部内容（容器、库、账号、文件、暂存）？"
  section "容器"
  if command -v docker >/dev/null 2>&1; then
    while read -r p; do
      [ -d "$p" ] && ls "$p"/compose.y*ml "$p"/docker-compose.y*ml >/dev/null 2>&1 || continue
      (cd "$p" && docker compose down -v --rmi all >/dev/null 2>&1) && ok "$p 已停并删除容器与镜像"
    done < <(st_rows PLACED | cut -f2 | sort -u)
  fi
  section "数据库"
  if mysql_ok; then
    while read -r p; do my -e "DROP DATABASE IF EXISTS \`$p\`" && ok "删库 $p"; done < <(st_rows DBCREATED | cut -f2 | sort -u)
    while IFS=$'\t' read -r _ u h; do my -e "DROP USER IF EXISTS '$u'@'$h'" && ok "删账号 $u@$h"; done < <(st_rows USER | sort -u)
  else
    warn "MySQL 不可用，库和账号没删：$(st_rows DBCREATED | cut -f2 | sort -u | tr '\n' ' ')"
  fi
  while read -r p; do
    command -v ufw >/dev/null 2>&1 && ufw delete allow from "$p" to any port 3306 proto tcp >/dev/null 2>&1 && ok "ufw 删掉 $p -> 3306"
  done < <(st_rows UFW | cut -f2)
  section "文件"
  while read -r p; do [ -e "$p" ] || [ -L "$p" ] || continue; safe_rm "$p" && ok "删除 $p"; done \
    < <(st_rows CREATED | cut -f2 | awk '!s[$0]++' | tac)
  # 演练时替换掉的系统配置（sshd、ufw、面板……）：把 .bak 放回原处
  while IFS=$'\t' read -r _ p b; do
    case "$p" in mysql:*) continue ;; esac
    [ -e "$b" ] || [ -L "$b" ] || continue
    { [ -e "$p" ] || [ -L "$p" ]; } && { safe_rm "$p" || continue; }
    mv "$b" "$p" && ok "还原 $p"
  done < <(st_rows MOVED | tac)
  if [ -n "${PANEL_ROOT:-}" ] && [ -x /etc/init.d/bt ] && st_rows MOVED | cut -f2 | grep -q "^$PANEL_ROOT/"; then
    /etc/init.d/bt restart >/dev/null 2>&1 && ok "面板已按还原后的配置重启"
  fi
  while read -r p; do cp -a "$p" "$OPS_ENV_FILE" && ok "env.conf 还原为恢复前的版本"; done < <(st_rows ENVBAK | cut -f2 | head -1)
  ng=$(nginx_bin)
  [ -n "$ng" ] && "$ng" -t >/dev/null 2>&1 && "$ng" -s reload >/dev/null 2>&1 && ok "nginx 已重载"
  if st_rows DOCKER_INSTALLED | grep -q .; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
    rm -rf /var/lib/docker /var/lib/containerd /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    ok "docker 是演练时装的，已卸载"
  fi
  rm -rf "$DR_ROOT"; rm -f "$ST"
  ok "演练已清理，暂存 $DR_ROOT 与状态文件已删除"
  finish
}

case "$ACTION" in
  check)    do_check ;;
  restore)  do_restore ;;
  status)   do_status ;;
  teardown) do_teardown ;;
  *)        usage ;;
esac
