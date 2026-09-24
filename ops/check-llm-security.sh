#!/usr/bin/env bash
# ops/check-llm-security.sh — 只读盘点 LiteLLM 与 new-api 的访问控制
# VERSION: 1.0.3
# 1.0.3: vhost 列表改用 glob，不再 ls | xargs。
# ENV-REQUIRED: LITELLM_SITE NEWAPI_SITE ALLOW_EXTRA_IPS

set -o pipefail

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
VHOST=/www/server/panel/vhost/nginx
EXT="$VHOST/extension"

hr(){ printf '\n===== %s =====\n' "$*"; }

hr "0. env.conf 中本次要用的键"
if [ -r "$ENV_FILE" ]; then
  for k in LITELLM_SITE NEWAPI_SITE ALLOW_EXTRA_IPS; do
    eval "v=\${$k:-}"
    printf '  %-16s = %s\n' "$k" "${v:-（未设置）}"
  done
else
  echo "  $ENV_FILE 不存在或不可读"
fi

hr "1. 宝塔 nginx 站点与 extension 目录"
for f in "$VHOST"/*.conf; do [ -e "$f" ] || continue; echo "  vhost: $(basename "$f")"; done
ls -1 "$EXT" 2>/dev/null | sed 's/^/  ext : /' || echo "  （无 extension 目录）"

hr "2. extension 下的配置文件"
if [ -d "$EXT" ]; then
  find "$EXT" -maxdepth 2 -name '*.conf' \
    -printf '  %p  %s bytes  %TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort
  # 文件名不含 allow/deny 的封禁文件（如 blocklist.conf）同样要看内容
  find "$EXT" -maxdepth 2 -type f \
    \( -name '*allow*' -o -name '*deny*' -o -name '*block*' \) 2>/dev/null | while read -r f; do
    echo; echo "  --- 内容：$f ---"; sed 's/^/    /' "$f"
  done
fi

hr "3. vhost 是否在 server 级引入 extension"
grep -nE 'include .*extension' "$VHOST"/*.conf 2>/dev/null | sed 's/^/  /' || echo "  未找到 include"

hr "4. fail2ban 文件清单"
ls -l /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ /etc/fail2ban/filter.d/nginx-*.conf 2>&1 | sed 's/^/  /'

hr "5. jail.local 的 ignoreip"
grep -nE '^[[:space:]]*ignoreip' /etc/fail2ban/jail.local 2>/dev/null | sed 's/^/  /' || echo "  没有 ignoreip 行"

hr "6. fail2ban 运行状态"
fail2ban-client status 2>&1 | sed 's/^/  /'
for J in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
  echo "  --- jail: $J ---"
  fail2ban-client status "$J" 2>/dev/null | grep -E 'File list|Currently failed|Currently banned|Banned IP' | sed 's/^/    /'
done

hr "7. sshd 实际生效参数"
for k in maxretry findtime bantime; do
  printf '  %-10s %s\n' "$k" "$(fail2ban-client get sshd $k 2>/dev/null)"
done
printf '  %-10s %s\n' "maxtime" "$(fail2ban-client get sshd bantime.maxtime 2>/dev/null)"
printf '  %-10s %s\n' "actions" "$(fail2ban-client get sshd actions 2>/dev/null | tr '\n' ' ')"

hr "8. 相关脚本安装情况"
ls -l /usr/local/bin/sync-llm-allowlist.sh 2>&1 | sed 's/^/  /'
grep -iE 'allowlist|litellm' /var/lib/ops-scripts/installed.list 2>/dev/null | sed 's/^/  /' || echo "  安装台账里无相关记录"

hr "9. 机群清单"
H="${HOME}/.vps-hosts.txt"
if [ -r "$H" ]; then
  N=$(grep -cvE '^[[:space:]]*(#|$)' "$H")
  echo "  $H 有效行数：$N"
  grep -vE '^[[:space:]]*(#|$)' "$H" | sed -E 's/^[^@]*@//; s/:[0-9]+[[:space:]]*$//' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | sed 's/^/    /'
else
  echo "  读不到 $H"
fi

hr "10. 站点可达性与日志"
for S in "${LITELLM_SITE:-}" "${NEWAPI_SITE:-}"; do
  [ -z "$S" ] && continue
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://${S}/" 2>/dev/null)
  printf '  %-28s HTTP %s\n' "$S" "${C:-无响应}"
  ls -l "/www/wwwlogs/${S}.log" 2>&1 | sed 's/^/    /'
done

hr "11. ufw 当前状态"
ufw status 2>&1 | head -20 | sed 's/^/  /'

echo
echo "===== 盘点结束，本脚本未修改任何文件 ====="
