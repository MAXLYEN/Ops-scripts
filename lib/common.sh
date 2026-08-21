#!/usr/bin/env bash
# lib/common.sh — ops-scripts 公共函数库
# VERSION: 1.1.0
# 1.1.0: 新增 scan_vhost_domains / resolve_domains —— 手维护的域名清单会双向漂移
#        （多出废域名 = 噪音，漏掉真站点 = 静默不检查），统一在这里处理
#
# 用法：每个脚本开头
#   . "$(dirname "$0")/../lib/common.sh"   # 本地布局
#   . /usr/local/lib/ops-common.sh          # opsget 安装后的位置

set -o pipefail

OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
OPS_COMMON_VERSION="1.1.0"

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
  local b="$dir/$(basename "$f").$(date -u +%Y%m%d%H%M%S)"
  cp -a "$f" "$b" && printf '%s\n' "$b"
}

# ── 校验和 ──────────────────────────────────────────────────
# sha256sum * > SHA256SUMS 会自引用：shell 先把 SHA256SUMS 截断成
# 0 字节，而通配符已把它算进参数列表，于是记下的是空文件的哈希。
# 下面两个函数绕开这个坑。
sha_write() {
  local dir=${1:-.}
  ( cd "$dir" && sha256sum $(ls -1 | grep -v '^SHA256SUMS$') > SHA256SUMS )
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
# 从 vhost 的 server_name 扫出真实域名集合（已排序去重）
scan_vhost_domains() {
  [ -d "${PANEL_VHOST_DIR:-}" ] || return 0
  grep -h -E '^[[:space:]]*server_name' "$PANEL_VHOST_DIR"/*.conf 2>/dev/null \
    | sed -e 's/;.*//' -e 's/^[[:space:]]*server_name[[:space:]]*//' \
    | tr ' ' '\n' | grep -vE '^$|^_$|^0\.default$' | sort -u
}

# resolve_domains —— 决定本次要遍历哪些域名
#   DOMAINS 留空 → 自动扫 vhost（推荐）
#   DOMAINS 有值 → 用配置值，但与 vhost 实际情况双向比对后告警
# 结果：数组 OPS_DOMAINS，来源 OPS_DOMAINS_MODE
#
# 为什么两个方向都要报：多出来的废域名只是噪音，漏掉的才致命 ——
# 漏掉的站点压根不进循环，输出还是全绿，看起来像"检查过了"。
resolve_domains() {
  local scanned cfg stale fresh
  scanned=$(scan_vhost_domains)

  if [ -z "${DOMAINS:-}" ]; then
    OPS_DOMAINS_MODE=auto
    [ -n "$scanned" ] || die "DOMAINS 留空，且没能从 ${PANEL_VHOST_DIR:-未配置} 扫到任何 server_name"
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

# ── 其它 ────────────────────────────────────────────────────
human() { du -sh "$1" 2>/dev/null | cut -f1; }

# 从空格分隔的配置值展开成数组：eval "$(as_array DOMAINS arr)"
as_array() { printf 'read -r -a %s <<< "${%s}"' "$2" "$1"; }
