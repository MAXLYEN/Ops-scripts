#!/usr/bin/env bash
# sync-llm-allowlist.sh
# VERSION: 2.0.2
# ENV-REQUIRED: LITELLM_SITE NEWAPI_SITE ALLOW_EXTRA_IPS
#
# 以 ~/.vps-hosts.txt 为唯一来源，同步 LLM 两站的访问控制：
#   1. LiteLLM 站整站白名单（名单外一律 403，.well-known 由 vhost 内 location 自带 allow all）
#   2. 清理 LiteLLM 站失效的 blocklist（白名单的 deny all 之后它永不生效）
#   3. fail2ban 配置合并为单一 jail.local（含 ignoreip 与 sshd 严格规则）
#   4. new-api 站 401 封禁 jail
# 机群增减后重跑即可。
#
# 2.0.2: 401 过滤规则里补注释，说明为何不能匹配 [日期]（便于日后改动时不踩回去）。
# 2.0.1: ① IP 提取不再用 tr 删空白 —— tr 会把换行一并删掉，整份清单粘成一行且末尾
#           无换行，while read 直接返回非零，循环一次都不执行，机群 IP 静默为 0。
#        ② failregex 不再匹配 [日期]：fail2ban 匹配前会把识别到的时间戳从行里摘除，
#           方括号变空，[^\]]+ 必然失配，结果是 0 matched。
#
# 注意：
# - nginx allow/deny 按声明顺序匹配，allowlist.conf 字母序须排在其他 deny 之前
# - fail2ban 读取顺序 jail.conf -> jail.d/*.conf -> jail.local，后读覆盖先读
# - 封禁动作 ufw，封的是该 IP 访问本机全部端口，故 ignoreip 必须含全部机群 IP
# - sshd 参数改动后回读校验，不符自动回滚
set -o pipefail

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

HOSTS_FILE="${HOME}/.vps-hosts.txt"
VHOST_DIR=/www/server/panel/vhost/nginx
JAIL_LOCAL=/etc/fail2ban/jail.local
OLD_JAIL_D=/etc/fail2ban/jail.d/99-sshd.conf
FILTER_F=/etc/fail2ban/filter.d/nginx-llm-401.conf
BAK_DIR="/root/llm-security-bak/$(date +%Y%m%d%H%M%S)"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die()  { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

for k in LITELLM_SITE NEWAPI_SITE ALLOW_EXTRA_IPS; do
  eval "v=\${$k:-}"
  [ -z "$v" ] && die "env.conf 缺少必填项 $k"
done
[ -r "$HOSTS_FILE" ]  || die "读不到 $HOSTS_FILE"
[ -r "$JAIL_LOCAL" ]  || die "读不到 $JAIL_LOCAL"

NGX_DIR="${VHOST_DIR}/extension/${LITELLM_SITE}"
NGX_F="${NGX_DIR}/allowlist.conf"
NGX_BLOCK="${NGX_DIR}/blocklist.conf"
NEWAPI_LOG="/www/wwwlogs/${NEWAPI_SITE}.log"
LITELLM_VHOST="${VHOST_DIR}/${LITELLM_SITE}.conf"

[ -f "$LITELLM_VHOST" ] || die "读不到 vhost $LITELLM_VHOST"
[ -r "$NEWAPI_LOG" ]    || die "读不到 $NEWAPI_LOG（401 jail 需要它，先确认站点日志路径）"

mkdir -p "$BAK_DIR" || die "建不了备份目录 $BAK_DIR"
log "本次备份目录：$BAK_DIR"

is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

put_file() {  # $1=临时文件 $2=目标 $3=权限；返回 0=有变化 1=无变化
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "  [=] $2 未变化"; return 1; fi
  [ -f "$2" ] && cp -a "$2" "${BAK_DIR}/$(basename "$2")"
  install -m "$3" "$1" "$2"; echo "  [+] $2 已写入"; return 0
}

# ---------- 汇总放行 IP ----------
log "汇总放行名单"
TMP=$(mktemp)
grep -vE '^[[:space:]]*(#|$)' "$HOSTS_FILE" \
  | sed -E 's/^[^@]*@//; s/:[0-9]+[[:space:]]*$//; s/[[:space:]]//g' \
  | while IFS= read -r h || [ -n "$h" ]; do
      [ -z "$h" ] && continue
      if is_ipv4 "$h"; then echo "$h"; else warn "跳过非 IPv4 条目：$h" >&2; fi
    done >> "$TMP"
N_FLEET=$(sort -u "$TMP" | wc -l)
for a in $(hostname -I 2>/dev/null); do is_ipv4 "$a" && echo "$a"; done >> "$TMP"
for a in $ALLOW_EXTRA_IPS; do
  if is_ipv4 "$a"; then echo "$a"; else warn "ALLOW_EXTRA_IPS 中非法地址：$a"; fi
done >> "$TMP"
echo "127.0.0.1" >> "$TMP"
IPS=$(sort -u "$TMP" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
rm -f "$TMP"
echo "  机群 ${N_FLEET} 台，合计放行 $(printf '%s\n' "$IPS" | grep -c .) 个地址："
printf '%s\n' "$IPS" | sed 's/^/    /'

# ---------- 1. LiteLLM 白名单 ----------
echo; log "1/4 ${LITELLM_SITE} 整站白名单"
grep -qE "include .*extension/${LITELLM_SITE}/\*\.conf" "$LITELLM_VHOST" \
  || die "vhost 未在 server 级 include extension，白名单不会生效"
grep -q 'location /.well-known' "$LITELLM_VHOST" \
  || die "vhost 内没有 .well-known 的独立 location，整站 deny 会挡掉证书续期，已中止"

mkdir -p "$NGX_DIR"
T=$(mktemp)
{
  echo "# litellm allowlist —— 由 sync-llm-allowlist.sh 生成，勿手改"
  echo "# 生成时间(UTC): $(date -u '+%F %T')"
  echo "# 作用域：server 级，整站只放行以下来源"
  echo "# 被锁在外时走 SSH 隧道进面板"
  printf '%s\n' "$IPS" | sed 's/^/allow /; s/$/;/'
  echo "deny all;"
} > "$T"
NGX_CHANGED=0
put_file "$T" "$NGX_F" 644 && NGX_CHANGED=1
rm -f "$T"

# ---------- 2. 清理失效 blocklist ----------
echo; log "2/4 清理 ${LITELLM_SITE} 的失效 blocklist"
if [ -f "$NGX_BLOCK" ]; then
  cp -a "$NGX_BLOCK" "${BAK_DIR}/blocklist.conf.${LITELLM_SITE}"
  rm -f "$NGX_BLOCK"
  echo "  [-] 已移除（白名单的 deny all 之后它永不生效），备份在 $BAK_DIR"
  NGX_CHANGED=1
else
  echo "  [=] 不存在，跳过"
fi

if [ "$NGX_CHANGED" = 1 ]; then
  if nginx -t >/dev/null 2>&1; then
    nginx -s reload && echo "  [+] nginx reload 完成"
  else
    warn "nginx -t 失败，回滚"
    [ -f "${BAK_DIR}/allowlist.conf" ] && cp -a "${BAK_DIR}/allowlist.conf" "$NGX_F" || rm -f "$NGX_F"
    [ -f "${BAK_DIR}/blocklist.conf.${LITELLM_SITE}" ] && cp -a "${BAK_DIR}/blocklist.conf.${LITELLM_SITE}" "$NGX_BLOCK"
    nginx -t; die "已回滚，未 reload"
  fi
fi

# ---------- 3. fail2ban 合并为单一 jail.local ----------
echo; log "3/4 fail2ban 配置合并（jail.local 单一来源）"
cp -a "$JAIL_LOCAL" "${BAK_DIR}/jail.local"
[ -f "$OLD_JAIL_D" ] && cp -a "$OLD_JAIL_D" "${BAK_DIR}/99-sshd.conf"

T=$(mktemp)
cat > "$T" <<F2BEOF
# fail2ban 主配置 —— 由 sync-llm-allowlist.sh 生成，勿手改
# 生成时间(UTC): $(date -u '+%F %T')
# 本文件是唯一来源：原 jail.d/99-sshd.conf 已合并至此并移除
# ignoreip 含全部机群 IP —— 封禁动作为 ufw，会封该 IP 访问本机所有端口，
# 节点被误封会导致 xboard-node / komari-agent 静默掉线

[DEFAULT]
bantime            = 7d
bantime.increment  = true
bantime.factor     = 2
bantime.maxtime    = 60d
findtime           = 1h
maxretry           = 3
logencoding        = auto
backend            = auto
banaction          = ufw
banaction_allports = ufw
action             = %(action_)s
ignoreip           = 127.0.0.1/8 ::1 $(printf '%s\n' "$IPS" | grep -v '^127\.0\.0\.1$' | tr '\n' ' ' | sed 's/ $//')

[sshd]
enabled  = true
mode     = normal
port     = 59967
logpath  = %(sshd_log)s
maxretry = 3
findtime = 1h
bantime  = 7d

# 持续用无效 Key 试探的 IP：10 分钟 20 次 401 即封
[nginx-llm-401]
enabled  = true
port     = http,https
filter   = nginx-llm-401
logpath  = ${NEWAPI_LOG}
backend  = auto
maxretry = 20
findtime = 10m
bantime  = 1h
F2BEOF
put_file "$T" "$JAIL_LOCAL" 644
rm -f "$T"

if [ -f "$OLD_JAIL_D" ]; then
  rm -f "$OLD_JAIL_D"
  echo "  [-] 已移除 $OLD_JAIL_D（内容已并入 jail.local）"
fi

echo; log "4/4 401 过滤规则"
T=$(mktemp)
cat > "$T" <<'EOF'
# nginx-llm-401 —— 由 sync-llm-allowlist.sh 生成，勿手改
# 匹配 nginx combined 日志中状态码 401 的请求
# 不要写 \[日期\]：fail2ban 匹配前会摘掉时间戳，方括号会变空
[Definition]
failregex = ^<HOST> \S+ \S+ .*"[^"]*" 401 \d+
ignoreregex =
EOF
put_file "$T" "$FILTER_F" 644
rm -f "$T"

echo "  日志里的 401 样本（确认格式）："
grep ' 401 ' "$NEWAPI_LOG" | tail -2 | cut -c1-120 | sed 's/^/    /' || echo "    （当前日志无 401 记录）"
echo "  过滤规则试跑："
fail2ban-regex "$NEWAPI_LOG" "$FILTER_F" 2>/dev/null | grep -E '^Lines:|Failregex:' | sed 's/^/    /'

# ---------- 生效与回读校验 ----------
echo; log "重载 fail2ban 并回读校验"
if ! fail2ban-client reload >/dev/null 2>&1; then
  warn "reload 失败，回滚 fail2ban 配置"
  cp -a "${BAK_DIR}/jail.local" "$JAIL_LOCAL"
  [ -f "${BAK_DIR}/99-sshd.conf" ] && cp -a "${BAK_DIR}/99-sshd.conf" "$OLD_JAIL_D"
  rm -f "$FILTER_F"
  fail2ban-client reload >/dev/null 2>&1
  die "已回滚，查 journalctl -u fail2ban -n 30"
fi
sleep 3

OK=1
check() {  # $1=键 $2=期望值
  A=$(fail2ban-client get sshd "$1" 2>/dev/null)
  if [ "$A" = "$2" ]; then printf '  [OK] sshd %-9s = %s\n' "$1" "$A"
  else printf '  [!!] sshd %-9s = %s（期望 %s）\n' "$1" "$A" "$2"; OK=0; fi
}
check maxretry 3
check findtime 3600
check bantime  604800
if fail2ban-client status nginx-llm-401 >/dev/null 2>&1; then
  echo "  [OK] nginx-llm-401 jail 已启用"
else
  echo "  [!!] nginx-llm-401 jail 未启用"; OK=0
fi

if [ "$OK" != 1 ]; then
  warn "回读校验不通过，回滚 fail2ban 配置（nginx 改动保留）"
  cp -a "${BAK_DIR}/jail.local" "$JAIL_LOCAL"
  [ -f "${BAK_DIR}/99-sshd.conf" ] && cp -a "${BAK_DIR}/99-sshd.conf" "$OLD_JAIL_D"
  rm -f "$FILTER_F"
  fail2ban-client reload >/dev/null 2>&1
  die "已回滚 fail2ban，备份在 $BAK_DIR"
fi

# ---------- 自检 ----------
echo; echo "===== 自检 ====="
fail2ban-client status 2>/dev/null | sed 's/^/  /'
echo
for S in "$LITELLM_SITE" "$NEWAPI_SITE"; do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://${S}/" 2>/dev/null)
  printf '  %-28s HTTP %s  （本机在白名单内，应非 403）\n' "$S" "${C:-无响应}"
done

ROOT=$(awk '/^[[:space:]]*root[[:space:]]/ {print $2; exit}' "$LITELLM_VHOST" | tr -d ';')
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  WK="${ROOT}/.well-known/acme-challenge"
  mkdir -p "$WK"
  P="probe-$(date +%s)"; echo ok > "${WK}/${P}"
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://${LITELLM_SITE}/.well-known/acme-challenge/${P}" 2>/dev/null)
  rm -f "${WK}/${P}"
  printf '  证书续期路径 HTTP %s  （必须 200，否则证书到期续不上）\n' "${C:-无响应}"
else
  warn "vhost 里没读到 root，跳过证书路径探测：请手工确认"
fi
echo
echo "  备份目录：$BAK_DIR"
