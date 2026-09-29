#!/usr/bin/env bash
# lib/common.sh — 提供配置加载、日志、数据库与站点扫描等公共函数
# VERSION: 1.2.3
# 1.2.3: bk_images 可只列指定容器（可整段送到远端执行）；新增 vps_host_port；LITELLM_BACKUP_DIR 算备份落盘目录。
# 1.2.2: 备份包收 SSH 两步验证：/etc/pam.d/sshd 与 /root/.google_authenticator（缺了新机上 SSH 密码登录会失败；密钥登录不需要验证码）。
# 1.2.1: 备份采集 /usr/local/bin 时跳过与系统命令同名的文件（放回会遮住真命令）。

set -o pipefail

OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
# shellcheck disable=SC2034  # 供调用方查询公共库版本
OPS_COMMON_VERSION="1.2.3"

# ── 输出 ────────────────────────────────────────────────────
# 时间戳在调用时计算，不用启动时冻结的变量 —— 否则长任务的日志
# 时间戳会全部停在启动那一刻，排查时严重误导。
_ts() { date -u '+%F %T'; }
log()  { printf '[%s] %s\n'        "$(_ts)" "$*"; }
ok()   { printf '[%s] [OK]   %s\n' "$(_ts)" "$*"; }
warn() { printf '[%s] [警告] %s\n' "$(_ts)" "$*" >&2; OPS_WARNINGS=$((OPS_WARNINGS+1)); }
die()  { printf '[%s] [致命] %s\n' "$(_ts)" "$*" >&2; exit 1; }
OPS_WARNINGS=0

section() { printf '\n===== %s =====\n' "$*"; }

# 汇总退出：有告警时以非零码退出，便于 cron 判断
finish() {
  printf '\n'
  if [ "$OPS_WARNINGS" -eq 0 ]; then
    log "完成（0 告警）"
  else
    log "完成（${OPS_WARNINGS} 条告警）"
    return 1
  fi
}

# ── 配置加载 ────────────────────────────────────────────────
load_env() {
  [ -f "$OPS_ENV_FILE" ] || die "缺少配置文件 $OPS_ENV_FILE（从 config/env.example.conf 复制）"
  local perm; perm=$(stat -c %a "$OPS_ENV_FILE" 2>/dev/null)
  [ "$perm" = 600 ] || warn "$OPS_ENV_FILE 权限是 $perm，应为 600"
  # shellcheck disable=SC1090
  . "$OPS_ENV_FILE"
}

# 必填项检查：require_env VAR1 VAR2 ...
# 缺失就退出，绝不回落到默认值 —— 用错的值静默执行比报错危险得多。
require_env() {
  local miss=""
  for v in "$@"; do
    [ -n "${!v:-}" ] || miss="$miss $v"
  done
  [ -z "$miss" ] || die "配置项未填:$miss（见 $OPS_ENV_FILE）"
}

require_cmd() {
  local miss=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
  [ -z "$miss" ] || die "缺少命令:$miss"
}

require_root() { [ "$(id -u)" -eq 0 ] || die "需要 root"; }

# ── 交互确认 ────────────────────────────────────────────────
# 危险操作用它。设 OPS_YES=1 可跳过（供自动化调用）。
confirm() {
  [ "${OPS_YES:-0}" = 1 ] && return 0
  printf '  %s (yes/no) ' "${1:-确认继续？}"
  local a; read -r a </dev/tty
  [ "$a" = yes ] || { log "已取消"; exit 0; }
}

# ── 幂等文件安装 ────────────────────────────────────────────
# install_file <源> <目标> [权限]
# 已存在且内容相同 → 跳过；不同 → 备份旧版后替换；不存在 → 新建
install_file() {
  local src=$1 dst=$2 mode=${3:-644}
  [ -f "$src" ] || die "源文件不存在: $src"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    log "[=] $dst 内容相同，跳过"
  elif [ -f "$dst" ]; then
    cp -a "$dst" "$dst.bak.$(date -u +%Y%m%d%H%M%S)"
    install -m "$mode" "$src" "$dst"
    log "[~] $dst 已备份旧版并替换"
  else
    install -m "$mode" "$src" "$dst"
    log "[+] $dst 新建"
  fi
}

# 备份单个文件到指定目录，返回备份路径
backup_file() {
  local f=$1 dir=${2:-/root/ops-backups}
  [ -e "$f" ] || return 0
  mkdir -p "$dir"
  local b; b="$dir/$(basename "$f").$(date -u +%Y%m%d%H%M%S)"
  cp -a "$f" "$b" && printf '%s\n' "$b"
}

# ── 校验和 ──────────────────────────────────────────────────
# sha256sum * > SHA256SUMS 会自引用：shell 先把 SHA256SUMS 截断成
# 0 字节，而通配符已把它算进参数列表，于是记下的是空文件的哈希。
# 下面两个函数绕开这个坑。
sha_write() {
  local dir=${1:-.}
  ( cd "$dir" || exit 1
    local f; local -a files=()
    for f in *; do [ -f "$f" ] && [ "$f" != SHA256SUMS ] && files+=("$f"); done
    # 一个文件都没有时 sha256sum 会转去读 stdin 卡住
    [ ${#files[@]} -gt 0 ] || { : > SHA256SUMS; exit 0; }
    sha256sum -- "${files[@]}" > SHA256SUMS )
}
sha_check() {
  local dir=${1:-.}
  [ -f "$dir/SHA256SUMS" ] || die "$dir 下没有 SHA256SUMS"
  ( cd "$dir" && grep -v ' SHA256SUMS$' SHA256SUMS | sha256sum -c - )
}

# ── MySQL ───────────────────────────────────────────────────
# 凭据永不出现在命令行，一律走 defaults-file。
mysql_ready() {
  require_env MYSQL_DEFAULTS_FILE
  [ -f "$MYSQL_DEFAULTS_FILE" ] || die "缺少 $MYSQL_DEFAULTS_FILE"
  mysql --defaults-file="$MYSQL_DEFAULTS_FILE" -e "SELECT 1" >/dev/null 2>&1 \
    || die "MySQL 凭据不可用: $MYSQL_DEFAULTS_FILE"
}
my()     { mysql --defaults-file="$MYSQL_DEFAULTS_FILE" "$@"; }
myq()    { mysql --defaults-file="$MYSQL_DEFAULTS_FILE" -N -B -e "$1"; }
mydump() { mysqldump --defaults-file="$MYSQL_DEFAULTS_FILE" "$@"; }

# 表存在性
db_exists() { [ "$(myq "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1'")" -gt 0 ]; }

# ── Docker ──────────────────────────────────────────────────
docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# ufw 重载可能打乱 dockerd 自插的链，检查并按需重启
docker_chain_ok() {
  iptables -S DOCKER 2>/dev/null | grep -q -- '-j ACCEPT'
}

# ── HTTP 探测 ───────────────────────────────────────────────
# 经本机 nginx 访问域名，绕过 DNS。切换前的最佳预演。
probe_domain_local() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null; }

# ── 域名清单 ────────────────────────────────────────────────
# vhost 里所有 server_name 的原始 token（未过滤）
_vhost_server_name_tokens() {
  [ -d "${PANEL_VHOST_DIR:-}" ] || return 0
  grep -h -E '^[[:space:]]*server_name' "$PANEL_VHOST_DIR"/*.conf 2>/dev/null \
    | sed -e 's/;.*//' -e 's/^[[:space:]]*server_name[[:space:]]*//' \
    | tr ' ' '\n' | grep -vE '^[[:space:]]*$' | sort -u
}

# 能不能拿来做域名探测 / 申请证书。
# 排除：catch-all（_）、默认站、localhost、IP 字面量、含通配符或非法字符的。
# 这些在 server_name 里都合法，但 --resolve 探测、wwwroot 目录、ACME 申请
# 对它们都没有意义 —— 混进域名列表只会产生假告警。
_is_probe_domain() {
  case "$1" in
    _|0.default|localhost) return 1 ;;
    *[!A-Za-z0-9._-]*)     return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && return 1
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$'
}

# 从 vhost 的 server_name 扫出真实域名集合（已排序去重、已过滤）
scan_vhost_domains() {
  local t
  while read -r t; do
    [ -n "$t" ] || continue
    _is_probe_domain "$t" && printf '%s\n' "$t"
  done < <(_vhost_server_name_tokens)
}

# 被过滤掉的那些（catch-all 与默认站不算，它们是纯噪音）
scan_vhost_nondomains() {
  local t
  while read -r t; do
    [ -n "$t" ] || continue
    case "$t" in _|0.default) continue ;; esac
    _is_probe_domain "$t" || printf '%s\n' "$t"
  done < <(_vhost_server_name_tokens)
}

# resolve_domains —— 决定本次要遍历哪些域名
#   DOMAINS 留空 → 自动扫 vhost（推荐）
#   DOMAINS 有值 → 用配置值，但与 vhost 实际情况双向比对后告警
# 结果：数组 OPS_DOMAINS，来源 OPS_DOMAINS_MODE
#
# 为什么两个方向都要报：多出来的废域名只是噪音，漏掉的才致命 ——
# 漏掉的站点压根不进循环，输出还是全绿，看起来像"检查过了"。
# shellcheck disable=SC2034  # OPS_DOMAINS_MODE 是输出变量，由 ssl-audit、08-post-start-check 读取
resolve_domains() {
  local scanned skipped cfg stale fresh
  scanned=$(scan_vhost_domains)
  skipped=$(scan_vhost_nondomains | tr '\n' ' ')

  # 跳过项用 log 不用 warn：IP 出现在 server_name 里是正常配置，
  # 计进告警会让"0 告警"永远达不到，久了整个告警计数就没人看了。
  [ -n "${skipped// /}" ] && log "非域名的 server_name 已跳过: ${skipped% }"

  if [ -z "${DOMAINS:-}" ]; then
    OPS_DOMAINS_MODE=auto
    [ -n "$scanned" ] || die "DOMAINS 留空，且没能从 ${PANEL_VHOST_DIR:-未配置} 扫到任何域名"
    mapfile -t OPS_DOMAINS <<< "$scanned"
    return 0
  fi

  OPS_DOMAINS_MODE=explicit
  read -r -a OPS_DOMAINS <<< "$DOMAINS"
  [ -n "$scanned" ] || { warn "无法扫描 vhost，跳过域名清单比对"; return 0; }

  cfg=$(printf '%s\n' "${OPS_DOMAINS[@]}" | grep -v '^$' | sort -u)
  stale=$(comm -23 <(printf '%s\n' "$cfg") <(printf '%s\n' "$scanned") | tr '\n' ' ')
  fresh=$(comm -13 <(printf '%s\n' "$cfg") <(printf '%s\n' "$scanned") | tr '\n' ' ')
  [ -n "${stale// /}" ] && warn "DOMAINS 里有但 vhost 里没有: ${stale% } —— 站点已删就从配置移除"
  [ -n "${fresh// /}" ] && warn "vhost 里有但 DOMAINS 没列: ${fresh% } —— 这些站点不会被检查"
  return 0
}

# ── 云端地址 ────────────────────────────────────────────────
# 与 opsget 同一套 ref 判定：环境变量 OPS_REF > /etc/ops-scripts/ref > main。
# 脚本直接从 /usr/local/bin 运行时没有 opsget 导出的 OPS_REF，也要读固定文件，
# 否则固定了版本的机器会拿本机脚本和 main 比，全部误报「与云端不一致」。
ops_base() {
  local ref=${OPS_REF:-}
  [ -n "$ref" ] || ref=$(head -n1 /etc/ops-scripts/ref 2>/dev/null)
  printf '%s/%s' "${OPS_REPO:-https://raw.githubusercontent.com/MAXLYEN/ops-scripts}" "${ref:-main}"
}

# ── 备份包：rootfs 与还原清单 ───────────────────────────────
# backup/ 下的脚本用它们把系统状态收进包，约定见 backup/README.md「包结构」：
#   rootfs/<绝对路径>       原样可放回新机的文件与目录
#   restore-manifest.tsv    每行 path mode owner kind，还原脚本按它自动放回
# 这些函数调用的 log / warn 是备份脚本自己的版本（后定义的覆盖这里的），
# 告警因此计进各脚本的告警计数。全部兼容 set -u。
#
# 只进 rootfs 的是「原样放回就对」的东西。fstab、网卡配置这类带本机磁盘 UUID
# 或 IP 的只作参考，放 system/ref/，不进清单。

bk_init() {  # bk_init <包根目录>
  BK_ROOT=$1
  BK_MANIFEST="$BK_ROOT/restore-manifest.tsv"
  BK_SKIPPED="$BK_ROOT/system/rootfs-skipped.txt"
  mkdir -p "$BK_ROOT/rootfs" "$BK_ROOT/system/ref"
  printf '# restore-manifest v1：path mode owner kind（见 backup/README.md「包结构」）\n' > "$BK_MANIFEST"
  : > "$BK_SKIPPED"
  # 解密密码绝不进包：拿到包的人同时拿到钥匙，加密就白做了。
  # BACKUP_PASS_FILES 按模板是加密密码列表，但若与数据库凭据是同一个键值则以凭据为准。
  BK_SECRETS=()
  local f
  for f in ${BACKUP_PASS_FILE:-} ${VW_PASS_FILE:-} ${BACKUP_PASS_FILES:-}; do
    [ -n "$f" ] || continue
    case " ${BACKUP_PASS_FILE:-} ${VW_PASS_FILE:-} " in
      *" $f "*) ;;
      *) [ "$f" = "${MYSQL_DEFAULTS_FILE:-}" ] || [ "$f" = "${XBOARD_DB_PASS_FILE:-}" ] && continue ;;
    esac
    BK_SECRETS+=("$f")
    [ -e "$f" ] && BK_SECRETS+=("$(realpath "$f")")
  done
  # 备份自己的落盘目录不收，否则包里套包、越滚越大
  BK_OUTDIRS=()
  for f in ${VW_BACKUP_DIR:-} ${XBOARD_BACKUP_DIR:-} ${NEWAPI_BAK_DIR:-} ${LITELLM_BACKUP_DIR:-} ${BACKUP_DIRS:-} \
           ${SNAPSHOT_ROOT:-} ${PANEL_DB_BACKUP_DIR:-} ${PANEL_BACKUP_DIR:-} \
           ${RESTORE_STAGE:-} ${IMAGE_EXPORT_DIR:-}; do
    [ -n "$f" ] || continue
    BK_OUTDIRS+=("${f%/}")
    [ -e "$f" ] && BK_OUTDIRS+=("$(realpath "$f")")
  done
}

bk_skip() { printf '%s\t%s\n' "$1" "$2" >> "$BK_SKIPPED"; }  # bk_skip <路径> <原因>

# bk_opt <路径> —— 可有可无的系统项：不存在就算了，存在按目录或文件收
bk_opt() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if [ -d "$1" ]; then bk_dir "$1"; else bk_file "$1"; fi
}

bk_is_secret() {
  local s r; r=$(realpath -m "$1")
  for s in "${BK_SECRETS[@]+"${BK_SECRETS[@]}"}"; do [ "$1" = "$s" ] || [ "$r" = "$s" ] && return 0; done
  return 1
}

bk_owner() {  # 用户名:组名；新机上可能没有同名账号，名字解析不了就给数字
  local o; o=$(stat -Lc '%U:%G' "$1" 2>/dev/null)
  case "$o" in *UNKNOWN*|'') stat -Lc '%u:%g' "$1" ;; *) printf '%s' "$o" ;; esac
}

# bk_row <path> <mode> <owner> <kind> —— 同一 path 同一 kind 只记一次
bk_row() {
  case "$1$2$3$4" in *$'\t'*|*$'\n'*) warn "路径含制表符或换行，无法写进还原清单: $1"; return 1 ;; esac
  awk -F'\t' -v p="$1" -v k="$4" '$1==p && $4==k {f=1} END {exit !f}' "$BK_MANIFEST" && return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$BK_MANIFEST"
}
bk_has_row() { awk -F'\t' -v p="$1" -v k="${2:-}" '$1==p && (k=="" || $4==k) {f=1} END {exit !f}' "$BK_MANIFEST"; }

# 在 rootfs 里建出 <绝对路径> 的各级父目录，权限与属主照抄本机。
# 不照抄的话父目录会是 umask 077 下的 700，还原时整棵放回会把 /etc 变成 700。
bk_mkparents() {
  local p d=""; p=$(dirname "$1")
  local IFS=/ c
  for c in ${p#/}; do
    d="$d/$c"
    [ -d "$BK_ROOT/rootfs$d" ] && continue
    mkdir "$BK_ROOT/rootfs$d" || return 1
    if [ -d "$d" ]; then
      chmod "$(stat -Lc %a "$d")" "$BK_ROOT/rootfs$d"
      chown "$(stat -Lc %u:%g "$d")" "$BK_ROOT/rootfs$d"
    fi
  done
}

# bk_file <绝对路径> [kind] —— 单个文件进 rootfs。kind：file（默认）/ sqlite / systemd-unit
# 路径不存在返回 1，由调用方决定要不要告警。
bk_file() {
  local p=$1 kind=${2:-file} dst
  [ -e "$p" ] || return 1
  bk_is_secret "$p" && { bk_skip "$p" "备份解密密码，按约定不进包"; return 0; }
  [ -f "$p" ] || { warn "不是普通文件，没收进包: $p"; return 1; }
  dst="$BK_ROOT/rootfs$p"
  bk_mkparents "$p" || { warn "rootfs 目录建不出来: $p"; return 1; }
  if [ "$kind" = sqlite ]; then
    # 直接 cp 会丢 WAL 里的近期数据，也可能拷到写了一半的页
    case "$dst" in *\'*) warn "路径含单引号，sqlite 无法在线备份: $p"; return 1 ;; esac
    command -v sqlite3 >/dev/null 2>&1 || { warn "没有 sqlite3，无法在线备份: $p"; return 1; }
    sqlite3 "$p" ".backup '$dst'" || { warn "sqlite 在线备份失败: $p"; return 1; }
    chmod "$(stat -Lc %a "$p")" "$dst"; chown "$(stat -Lc %u:%g "$p")" "$dst"
  else
    cp -pL "$p" "$dst" || { warn "复制失败: $p"; return 1; }
  fi
  bk_row "$p" "$(stat -Lc %a "$p")" "$(bk_owner "$p")" "$kind"
}

# bk_dir <绝对路径> [排除...] —— 整棵目录进 rootfs（还原时整棵替换）。
# 排除项以 / 开头的按完整路径排除，其余按文件名模式（find -name）。
# 总是排除日志、解密密码、备份落盘目录；目录里的 SQLite 库改用在线备份覆盖一遍。
bk_dir() {
  local p=${1%/}; shift
  [ -e "$p" ] || return 1
  [ -L "$p" ] && { bk_skip "$p" "顶层是软链接，未跟随"; return 0; }
  [ -d "$p" ] || { warn "不是目录，没收进包: $p"; return 1; }
  bk_is_secret "$p" && { bk_skip "$p" "备份解密密码，按约定不进包"; return 0; }
  bk_mkparents "$p/x" || { warn "rootfs 目录建不出来: $p"; return 1; }
  local -a prune=(-name '*.log' -o -name '*.log.[0-9]*')
  local x
  for x in "$@"; do
    case "$x" in /*) prune+=(-o -path "${x%/}") ;; *) prune+=(-o -name "$x") ;; esac
  done
  for x in "${BK_SECRETS[@]+"${BK_SECRETS[@]}"}" "${BK_OUTDIRS[@]+"${BK_OUTDIRS[@]}"}"; do
    case "$x" in "$p"/*) prune+=(-o -path "$x") ;; esac
  done
  # 被排除的解密密码记一笔，便于核对「为什么还原后少了它」
  for x in "${BK_SECRETS[@]+"${BK_SECRETS[@]}"}"; do
    case "$x" in "$p"/*) [ -e "$x" ] && bk_skip "$x" "备份解密密码，按约定不进包" ;; esac
  done
  local rc
  find "$p" \( "${prune[@]}" \) -prune -o \( -type f -o -type d -o -type l \) -print0 \
    | sed -z 's#^/##' \
    | tar -C / --null --no-recursion --warning=no-file-changed -T - -cf - \
    | tar -C "$BK_ROOT/rootfs" -xpf -
  rc=("${PIPESTATUS[@]}")
  # tar 读的时候文件在变，退出码是 1，内容仍可用
  [ "${rc[2]}" -le 1 ] && [ "${rc[3]}" -eq 0 ] || { warn "目录复制异常: $p（find/tar 退出码 ${rc[*]}）"; return 1; }
  if command -v sqlite3 >/dev/null 2>&1; then
    local f
    while IFS= read -r -d '' f; do
      head -c 16 "$f" 2>/dev/null | grep -q '^SQLite format 3' || continue
      case "$f" in *\'*) continue ;; esac
      sqlite3 "$f" ".backup '$BK_ROOT/rootfs$f.bk-tmp'" 2>/dev/null \
        && cat "$BK_ROOT/rootfs$f.bk-tmp" > "$BK_ROOT/rootfs$f"
      rm -f "$BK_ROOT/rootfs$f.bk-tmp"
    done < <(find "$p" \( "${prune[@]}" \) -prune -o -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
  fi
  bk_row "$p" "$(stat -c %a "$p")" "$(bk_owner "$p")" dir
}

# bk_link <绝对路径> <包内相对路径> [kind] —— 脚本已按旧布局收进包的内容，
# 硬链接进 rootfs 再记一行：包里不多占空间（tar 对硬链接只存一份），旧布局也照旧可用。
bk_link() {
  local p=${1%/} rel=$2 kind=${3:-} src="$BK_ROOT/$2" dst ref
  [ -e "$src" ] || return 1
  dst="$BK_ROOT/rootfs$p"
  [ -e "$dst" ] && return 0
  bk_mkparents "$p" || { warn "rootfs 目录建不出来: $p"; return 1; }
  if [ -d "$src" ]; then cp -al "$src" "$dst"; else ln "$src" "$dst"; fi || { warn "硬链接失败: $rel → $p"; return 1; }
  if [ -z "$kind" ]; then
    if [ -d "$src" ]; then kind="dir"; else kind="file"; fi
  fi
  ref=$p; [ -e "$ref" ] || ref=$src
  bk_row "$p" "$(stat -Lc %a "$ref")" "$(bk_owner "$ref")" "$kind"
}

# /usr/local/bin 逐个文件收：rclone 这类几十 MB 的静态二进制不进包（记进
# rootfs-skipped.txt，换机时重装），脚本全收。不用 dir：整棵替换会把没收的二进制删掉。
# 与系统目录同名的也不收：/usr/local/bin 在 PATH 里排在前面，放回新机会遮住
# 真的命令（例如调试时放的 docker 桩）。记进 rootfs-skipped.txt，确实要的手动放回。
bk_usr_local_bin() {
  local f d n max=$((5 * 1024 * 1024))
  for f in /usr/local/bin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    n=${f##*/}
    for d in /usr/bin /bin /usr/sbin /sbin; do
      [ -e "$d/$n" ] && { bk_skip "$f" "与 $d/$n 同名，放回会遮住系统命令"; continue 2; }
    done
    if [ "$(stat -c %s "$f")" -gt "$max" ]; then
      bk_skip "$f" "超过 5MB 的二进制（$(du -h "$f" | cut -f1)），换机时重新安装"
      continue
    fi
    bk_file "$f"
  done
}

# 启用了就记 systemd-unit（还原时 enable --now），没启用的只作 file 放回。
# 判断看 *.wants / *.requires 里的链接，不依赖 systemctl（容器里也能判断）。
bk_unit_enabled() {
  local l
  for l in /etc/systemd/system/*.wants/"$1" /etc/systemd/system/*.requires/"$1"; do
    [ -L "$l" ] && return 0
  done
  return 1
}

bk_systemd_units() {
  local f n l
  for f in /etc/systemd/system/*; do
    n=${f##*/}
    case "$n" in
      *.wants|*.requires) continue ;;
      *.d) [ ! -L "$f" ] && bk_opt "$f"; continue ;;
      *.service|*.timer|*.socket|*.path|*.mount|*.target) ;;
      *) continue ;;
    esac
    if [ -L "$f" ]; then
      # 指向 /dev/null 是被 mask 的单元，其余软链接是 enable / 别名的产物
      [ "$(readlink "$f")" = /dev/null ] && printf '%s\n' "$n" >> "$BK_ROOT/system/ref/systemd-masked.txt"
      continue
    fi
    [ -f "$f" ] || continue
    case "$n" in
      *@.*)  # 模板单元：启用的是实例名，自动 enable 不了，记下实例供人工处理
        bk_file "$f"
        for l in /etc/systemd/system/*.wants/"${n%%@*}"@*; do
          [ -L "$l" ] && printf '%s\n' "${l##*/}" >> "$BK_ROOT/system/ref/systemd-template-instances.txt"
        done ;;
      *) if bk_unit_enabled "$n"; then bk_file "$f" systemd-unit; else bk_file "$f"; fi ;;
    esac
  done
  for f in /etc/systemd/journald.conf.d /etc/systemd/timesyncd.conf.d /etc/systemd/system.conf.d; do
    bk_opt "$f"
  done
  return 0
}

# nginx 主配置目录：面板装的 nginx 不在 /etc/nginx，按编译参数找
bk_nginx_conf_dir() {
  local c=""
  command -v nginx >/dev/null 2>&1 \
    && c=$(nginx -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | head -1 | cut -d= -f2)
  [ -n "$c" ] || for c in /www/server/nginx/conf/nginx.conf /etc/nginx/nginx.conf; do [ -f "$c" ] && break; done
  [ -f "$c" ] && dirname "$c"
}

# bk_system —— 两台机器通用的系统项。各服务的数据由各脚本自己收。
bk_system() {
  local p
  # 工具箱配置（env.conf、版本固定 ref）、告警邮件、网盘凭据、数据库凭据
  bk_opt /etc/ops-scripts
  bk_opt /etc/msmtprc
  bk_opt /root/.config/rclone
  [ -n "${MYSQL_DEFAULTS_FILE:-}" ] && { bk_file "$MYSQL_DEFAULTS_FILE" || warn "MYSQL_DEFAULTS_FILE 指向的 $MYSQL_DEFAULTS_FILE 不存在"; }
  [ -n "${XBOARD_DB_PASS_FILE:-}" ] && bk_opt "$XBOARD_DB_PASS_FILE"
  bk_opt /usr/local/lib/ops-common.sh
  bk_usr_local_bin
  # SSH：服务端配置、主机密钥（新机沿用原指纹，客户端不会报主机变更）、root 的密钥与主机清单
  bk_opt /etc/ssh/sshd_config
  bk_opt /etc/ssh/sshd_config.d
  for p in /etc/ssh/ssh_host_*; do [ -f "$p" ] && bk_file "$p"; done
  bk_opt /root/.ssh
  # SSH 两步验证（Google Authenticator）：PAM 配置与 root 的 TOTP 密钥（含应急码）。
  # 两步验证只管密码登录（密钥登录不要验证码），缺了这两样，新机重启 SSH 后密码登录就过不去；
  # 密钥原样放回，手机上原来的验证器条目继续可用，不用重新绑定。
  bk_opt /etc/pam.d/sshd
  bk_opt /root/.google_authenticator
  bk_opt /root/.vps-hosts.txt
  bk_opt /root/.ssh_base.txt
  # 防火墙、入侵封禁、内核参数与 init/ 写过的系统文件
  bk_opt /etc/ufw
  bk_opt /etc/default/ufw
  bk_opt /etc/fail2ban
  bk_opt /etc/sysctl.conf
  bk_opt /etc/sysctl.d
  bk_opt /etc/modules-load.d
  bk_opt /etc/udev/rules.d
  bk_opt /etc/gai.conf
  bk_opt /etc/security/limits.d
  bk_opt /etc/docker/daemon.json
  bk_opt /etc/cron.d
  bk_opt /etc/logrotate.d
  bk_opt /etc/my.cnf
  # 证书续期状态（acme.sh / certbot；面板自己的续期记录在下面的面板目录里）
  bk_opt /root/.acme.sh
  bk_opt /etc/letsencrypt
  # nginx：主配置目录 + 面板的整个 vhost（含 proxy/、rewrite/、extension/、
  # well-known/ —— 站点配置 include 它们，缺一个 nginx -t 就过不了）
  if p=$(bk_nginx_conf_dir); then bk_opt "$p"; fi
  if [ -n "${PANEL_ROOT:-}" ] && [ -d "$PANEL_ROOT" ]; then
    bk_opt "$PANEL_ROOT/vhost"
    bk_opt "$PANEL_ROOT/config"
    bk_opt "$PANEL_ROOT/data"
    bk_opt "$PANEL_ROOT/ssl"
  fi
  # 面板计划任务的脚本体：crontab 里调用的是这里的文件
  [ -n "${PANEL_CRON_DIR:-}" ] && bk_opt "$PANEL_CRON_DIR"
  [ -n "${WWWROOT:-}" ] && bk_opt "$WWWROOT"
  bk_systemd_units
  # crontab
  if crontab -l > "$BK_ROOT/system/crontab.txt" 2>/dev/null; then
    bk_row system/crontab.txt - - crontab
  else
    rm -f "$BK_ROOT/system/crontab.txt"; log "  i root 没有 crontab"
  fi
  # 配置里额外列出的路径：EXTRA_SNAPSHOT_PATHS 可缺，CRITICAL_FILES 缺了告警
  for p in ${EXTRA_SNAPSHOT_PATHS:-}; do
    case "$p" in /usr/local/bin|/usr/local/bin/) continue ;; esac  # 已按单个文件收过
    bk_opt "$p"
  done
  for p in ${CRITICAL_FILES:-}; do
    if [ -e "$p" ]; then bk_opt "$p"; else warn "CRITICAL_FILES 里的 $p 不存在"; fi
  done
  bk_system_ref
}

# 只作参考、不自动放回的现场信息
bk_system_ref() {
  local r="$BK_ROOT/system/ref" f
  for f in /etc/fstab /etc/hostname /etc/hosts /etc/os-release /etc/apt/sources.list; do
    [ -f "$f" ] && cp -pL "$f" "$r/" 2>/dev/null
  done
  [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$r/" 2>/dev/null
  command -v apt-mark >/dev/null 2>&1 && apt-mark showmanual > "$r/apt-manual.txt" 2>/dev/null
  command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files --state=enabled --no-legend > "$r/systemd-enabled.txt" 2>/dev/null
  ip -br addr > "$r/ip-addr.txt" 2>/dev/null
  return 0
}

# bk_images <输出文件> [容器...] —— 每个容器一行：容器名、配置的镜像、RepoDigest。
# :latest / :new 这类标签重拉会拿到别的版本，还原时按 digest 拉才是原来那个。
# 不给容器名就列本机全部容器；给了只列这些，不存在的镜像与 digest 都记 -。
# 只依赖 docker 与 warn：远端没有公共库时，可以 declare -f bk_images 连同一个 warn 送过去执行。
bk_images() {
  local out=$1 c img id dig; shift
  printf '# container\timage\trepo_digest\n' > "$out"
  command -v docker >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2046  # 容器名不含空白，按词拆开正是要的
  [ $# -gt 0 ] || set -- $(docker ps -a --format '{{.Names}}' 2>/dev/null)
  for c in "$@"; do
    # 失败的赋值一律接 ||：调用方开着 set -e 时，一个不存在的容器不该让整个函数中止
    img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null) || img=""
    if [ -z "$img" ]; then
      warn "容器 $c 不存在，镜像没有记下"
      printf '%s\t-\t-\n' "$c" >> "$out"
      continue
    fi
    id=$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null) || id=""
    dig=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$id" 2>/dev/null) || dig=""
    [ -n "$dig" ] || warn "容器 $c 的镜像 $img 没有 RepoDigest（本地构建？），还原时无法按 digest 锁定"
    printf '%s\t%s\t%s\n' "$c" "${img:--}" "${dig:--}" >> "$out"
  done
}

# bk_compose_projects —— 按容器标签找出 compose 项目：compose 文件与 .env 进 rootfs，
# 数据已被收进包（清单里有该目录或其下的路径）的才记 compose-project（还原时自动启动）。
# 数据没收的不自动启动，并告警：空数据起一个有状态服务比不起更糟。
# 确实无状态、不需要备份的容器，写进 BACKUP_IGNORE_CONTAINERS。
bk_compose_projects() {
  command -v docker >/dev/null 2>&1 || return 0
  local c dir files f covered ign=" ${BACKUP_IGNORE_CONTAINERS:-} " seen=" "
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    case "$ign" in *" $c "*) continue ;; esac
    dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null)
    if [ -z "$dir" ] || [ "$dir" = "<no value>" ]; then
      warn "容器 $c 不是 compose 起的，还原时无法自动启动（启动参数见 system/docker/ 或 ops/containerize-and-pin 转成 compose）"
      continue
    fi
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null)
    # 先判断数据有没有进包，再收 compose 文件 —— 否则刚收的 compose 文件自己就算「已覆盖」
    covered=0
    awk -F'\t' -v d="$dir" '$1==d || index($1, d"/")==1 {f=1} END {exit !f}' "$BK_MANIFEST" && covered=1
    for f in ${files//,/ } "$dir/.env"; do
      [ -f "$f" ] && ! bk_has_row "$f" && bk_file "$f"
    done
    if [ "$covered" -eq 1 ]; then
      bk_row "$dir" - - compose-project
    else
      warn "compose 项目 $dir（容器 $c）的数据没有备份，还原时不会自动启动；需要的话把数据目录加进 EXTRA_SNAPSHOT_PATHS"
    fi
  done
}

# ── 备份包：MySQL ───────────────────────────────────────────
# 用 root 凭据（MYSQL_DEFAULTS_FILE）。必须 --defaults-file：面板机上 --defaults-extra-file
# 之后还会读 ~/.my.cnf，那里的 [client] 会把指定的凭据覆盖掉。
_bk_my() { "${BK_MYSQL:-mysql}" --defaults-file="$MYSQL_DEFAULTS_FILE" "$@"; }

bk_mysql_ready() {
  [ -n "${MYSQL_DEFAULTS_FILE:-}" ] && [ -r "$MYSQL_DEFAULTS_FILE" ] \
    || { warn "未配置可读的 MYSQL_DEFAULTS_FILE，全部账号与其余业务库没有进包"; return 1; }
  _bk_my -N -B -e 'SELECT 1' >/dev/null 2>&1 \
    || { warn "MYSQL_DEFAULTS_FILE（$MYSQL_DEFAULTS_FILE）连不上 MySQL，全部账号与其余业务库没有进包"; return 1; }
}

# bk_mysql_users <包内相对路径> —— 全部账号的 CREATE USER + ALTER USER + GRANT。
# 带密码哈希（AS '<hash>'），还原时不用输任何密码；先 IF NOT EXISTS 建、再 ALTER
# 把密码和属性对齐，账号已存在时也能重复执行。只跳过数据库自带的系统账号
# （含 MariaDB 的 'mysql'@'localhost'）。root 照收：面板、/root/.my.cnf 里存的是原密码，
# 新机 root 与它们一致才不会各说各话。
bk_mysql_users() {
  local out="$BK_ROOT/$1" u cu hex="" n=0
  mkdir -p "$(dirname "$out")"; : > "$out"
  # MySQL 8 的 caching_sha2 哈希含二进制字节，原样输出会被截断或转义坏，改成十六进制
  _bk_my -N -B -e 'SELECT @@SESSION.print_identified_with_as_hex' >/dev/null 2>&1 \
    && hex='SET SESSION print_identified_with_as_hex=ON; '
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    cu=$(_bk_my -N -B --raw -e "${hex}SHOW CREATE USER $u" 2>/dev/null) \
      || { warn "SHOW CREATE USER $u 失败"; continue; }
    case "$cu" in "CREATE USER "*) ;; *) warn "SHOW CREATE USER $u 输出异常"; continue ;; esac
    printf 'CREATE USER IF NOT EXISTS %s;\nALTER USER %s;\n' "${cu#CREATE USER }" "${cu#CREATE USER }" >> "$out"
    _bk_my -N -B --raw -e "SHOW GRANTS FOR $u" 2>/dev/null | sed 's/$/;/' >> "$out" \
      || warn "SHOW GRANTS FOR $u 失败"
    n=$((n + 1))
  done < <(_bk_my -N -B -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
            WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint')
              AND NOT (user = 'mysql' AND host = 'localhost')
              AND user <> '' ORDER BY user, host" 2>/dev/null)
  [ "$n" -gt 0 ] || { warn "没有导出任何 MySQL 账号"; rm -f "$out"; return 1; }
  printf 'FLUSH PRIVILEGES;\n' >> "$out"
  bk_row "$1" - - mysql-user
  log "  ✓ MySQL 账号 ${n} 个（含密码哈希）"
}

# bk_mysql_dbs <跳过的库...> —— 除系统库和跳过的库外，每个库一个 db/<库名>.sql.gz。
# 单库 dump，不含 CREATE DATABASE / USE，还原时按文件名建库。字符集记在 db/databases.tsv。
bk_mysql_dbs() {
  local skip=" information_schema performance_schema mysql sys $* ${BACKUP_SKIP_DBS:-} " db f t
  mkdir -p "$BK_ROOT/db"
  _bk_my -N -B -e "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
                   FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME" \
    > "$BK_ROOT/db/databases.tsv" 2>/dev/null     || { warn "列不出 MySQL 的库，其余业务库没有进包"; return 1; }
  while IFS=$'\t' read -r db _ _; do
    case "$skip" in *" $db "*) continue ;; esac
    case "$db" in */*|.*|'') warn "库名不适合做文件名，跳过: $db"; continue ;; esac
    f="db/$db.sql.gz"
    if "${BK_MYSQLDUMP:-mysqldump}" --defaults-file="$MYSQL_DEFAULTS_FILE" --single-transaction --quick \
         --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4 \
         "$db" 2>/dev/null | gzip > "$BK_ROOT/$f"; then
      # 读完整个流再判断，别让 grep -q 提前关管道
      t=$(zcat "$BK_ROOT/$f" | grep -c '^CREATE TABLE')
      bk_row "$f" - - mysql-db
      log "  ✓ 库 $db（$(du -h "$BK_ROOT/$f" | cut -f1)，${t} 张表）"
    else
      rm -f "$BK_ROOT/$f"; warn "库 $db 导出失败"
    fi
  done < "$BK_ROOT/db/databases.tsv"
}

# ── 备份包：分级保留（GFS）──────────────────────────────────
# 按文件名里的时间戳（<前缀>_YYYYMMDD_HHMMSS.7z，按 UTC 解释）分档：
#   < all 天      全留
#   < daily 天    每天留最早的一份
#   < weekly 天   每 ISO 周留最早的一份
#   < max 天      每月留最早的一份
#   ≥ max 天      删
# 留「最早」而不是「最新」：每档留下的正好是上一档留下的，档位边界移动时
# 不会今天留 A 明天换成 B，不产生多余的删除。最新的一份无论多旧都留。
# 同名的 .sha256 旁注跟随它的包一起留或删。不认识的文件名一律不动。
#
# bk_gfs_select <now 秒> <all> <daily> <weekly> <max>，stdin 为文件名，stdout 为要删的文件名
bk_gfs_select() {
  local now=$1 all=$2 daily=$3 weekly=$4 max=$5 n d t
  local -a names=() stamps=()
  while IFS= read -r n; do
    [[ "$n" =~ ^[A-Za-z0-9-]+_([0-9]{8})_([0-9]{6})\.7z(\.sha256)?$ ]] || continue
    d=${BASH_REMATCH[1]} t=${BASH_REMATCH[2]}
    names+=("$n")
    stamps+=("${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}")
  done
  [ ${#names[@]} -gt 0 ] || return 0
  local conv
  # 一次 date 换算全部时间戳；有非法日期时 date 会少输出行，对不齐就整体放弃，绝不错位删除
  conv=$(printf '%s\n' "${stamps[@]}" | TZ=UTC date -f - '+%s %Y%m%d %G%V %Y%m' 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$conv" | wc -l)" -eq ${#names[@]} ] || return 1
  paste -d' ' <(printf '%s\n' "$conv") <(printf '%s\n' "${names[@]}") \
    | sort -k1,1n -k5,5 \
    | awk -v now="$now" -v all="$all" -v daily="$daily" -v weekly="$weekly" -v max="$max" '
      { e[NR]=$1; day[NR]=$2; wk[NR]=$3; mon[NR]=$4; name[NR]=$5
        b=$5; sub(/\.sha256$/, "", b); base[NR]=b
        if ($5 !~ /\.sha256$/ && $1 >= newest_e) { newest_e=$1; newest=b } }
      END {
        if (newest == "") exit      # 只有旁注没有包：什么都不删
        for (i=1; i<=NR; i++) {
          b=base[i]
          if (!(b in keep)) {
            age=(now - e[i]) / 86400
            if (b == newest || age < all) keep[b]=1
            else if (age >= max) keep[b]=0
            else {
              k = age < daily ? "d" day[i] : (age < weekly ? "w" wk[i] : "m" mon[i])
              if (k in used) keep[b]=0; else { used[k]=1; keep[b]=1 }
            }
          }
          if (!keep[b]) print name[i]
        }
      }'
}

# 档位检查：都是整数，all ≥ 1，逐档不减。配置写错时不清理，比按错的档位删掉备份安全。
bk_gfs_ok() {
  local v
  for v in "$@"; do [[ "$v" =~ ^[0-9]+$ ]] || return 1; done
  [ "$1" -ge 1 ] && [ "$2" -ge "$1" ] && [ "$3" -ge "$2" ] && [ "$4" -ge 1 ]
}

# bk_prune_local <目录> <前缀> <all> <daily> <weekly> <max>
bk_prune_local() {
  local dir=$1 pre=$2; shift 2
  bk_gfs_ok "$@" || { warn "保留档位配置不合法（$*），本次不清理本地"; return 1; }
  local del f n=0
  del=$(find "$dir" -maxdepth 1 -type f -name "${pre}_*" -printf '%f\n' \
        | bk_gfs_select "$(date +%s)" "$@") || { warn "本地包名解析失败，本次不清理"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f -- "${dir:?}/$f" && n=$((n + 1)) && log "  - 本地删除 $f"
  done <<< "$del"
  log "  ✓ 本地按分级保留清理 ${n} 个文件（全留 $1 天 / 每天至 $2 天 / 每周至 $3 天 / 每月至 $4 天）"
}

# bk_prune_remote <rclone 远端路径> <前缀> <all> <daily> <weekly> <max>
# 列不出来就不删；逐个 deletefile，不用带过滤器的 delete，名单之外的东西碰不到。
bk_prune_remote() {
  local rem=${1%/} pre=$2; shift 2
  bk_gfs_ok "$@" || { warn "保留档位配置不合法（$*），本次不清理 ${rem}"; return 1; }
  local list del f n=0 bad=0
  list=$(rclone lsf "$rem/" --files-only --include "${pre}_*" 2>/dev/null) \
    || { warn "${rem} 列不出文件，本次不清理"; return 1; }
  del=$(printf '%s\n' "$list" | bk_gfs_select "$(date +%s)" "$@") \
    || { warn "${rem} 的包名解析失败，本次不清理"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if rclone deletefile "$rem/$f" 2>/dev/null; then n=$((n + 1)); else bad=$((bad + 1)); fi
  done <<< "$del"
  [ "$bad" -eq 0 ] || warn "${rem} 有 ${bad} 个过期文件删除失败"
  log "  ✓ ${rem} 按分级保留清理 ${n} 个文件（每月一份保留至 $4 天）"
}

# ── 主机清单 ────────────────────────────────────────────────
# vps_host_port <主机> —— ~/.vps-hosts.txt（每行 user@host:端口，# 起注释）里这台主机的端口。
# 主机整段比较，不像正则那样让 1.2.3.4 也命中 11.2.3.45。找不到时输出为空
vps_host_port() {
  awk -v h="$1" '{ sub(/#.*/, "")
    for (i = 1; i <= NF; i++) { s = $i; sub(/^[^@]*@/, "", s)
      if (split(s, a, ":") == 2 && a[1] == h && a[2] ~ /^[0-9]+$/) { print a[2]; exit } } }' \
    "${HOME}/.vps-hosts.txt" 2>/dev/null
}

# ── 其它 ────────────────────────────────────────────────────
human() { du -sh "$1" 2>/dev/null | cut -f1; }

# 从空格分隔的配置值展开成数组：eval "$(as_array DOMAINS arr)"
as_array() { printf 'read -r -a %s <<< "${%s}"' "$2" "$1"; }
