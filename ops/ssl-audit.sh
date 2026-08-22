#!/usr/bin/env bash
# ops/ssl-audit.sh — 证书三方对账
# VERSION: 2.1.0
# 2.1.0 变更：
#   · 第 5 节的域名来源改用 resolve_domains() —— 原来直接 for dom in $DOMAINS，
#     配置漂移时既会对废域名误报，也会静默漏掉没列进配置的真站点
#   · 通配符证书覆盖的域名跳过 HTTP-01 目录检查。通配符签发只能走 DNS-01，
#     对它检查 .well-known 目录必然误报
# 2.0.1: 结论按实际检测结果分支（原来无条件打印"不会续期"）；
#        站点根目录改为从 vhost 配置里查，兼容多域名共用一个站点的情况
#
# 证书文件正常 != 会自动续期。这两件事由不同的东西驱动：
#   nginx 直接读文件 -> 所以站点当下是好的
#   续期任务读面板记录 -> 记录丢了就不会续，到期那天全站一起挂
#
# 迁移后这是最典型的"静默失效"，本脚本把三方摆到一起看。
#
# 依赖 lib/common.sh >= 1.1.0（resolve_domains）

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env PANEL_CERT_DIR WWWROOT

section "1. 证书文件与到期日"
NOW=$(date -u +%s)
for d in "$PANEL_CERT_DIR"/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -f "$d/fullchain.pem" ]; then
    exp=$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)
    end=$(date -u -d "$exp" +%s 2>/dev/null)
    days=$(( (end - NOW) / 86400 ))
    curve=$(openssl x509 -noout -text -in "$d/fullchain.pem" 2>/dev/null \
            | grep -m1 'NIST CURVE' | sed 's/.*: //')
    bits=$(openssl x509 -noout -text -in "$d/fullchain.pem" 2>/dev/null \
           | grep -m1 -oE '\([0-9]+ bit\)')
    san=$(openssl x509 -noout -ext subjectAltName -in "$d/fullchain.pem" 2>/dev/null \
          | tail -1 | sed 's/DNS://g' | tr -d ' ')
    printf '  %-26s 还有 %5s 天  %-16s %s\n' "$n" "$days" "${curve:-$bits}" "$san"
    [ "$days" -lt 21 ] && warn "$n 只剩 $days 天"
  else
    printf '  %-26s (无 fullchain.pem)\n' "$n"
  fi
done

section "2. 站点配置引用的证书"
if [ -d "${PANEL_VHOST_DIR:-}" ]; then
  grep -l 'ssl_certificate' "$PANEL_VHOST_DIR"/*.conf 2>/dev/null | while read -r f; do
    printf '  %-32s -> %s\n' "$(basename "$f")" \
      "$(grep -m1 'ssl_certificate ' "$f" | awk '{print $2}' | tr -d ';')"
  done
fi

section "3. 面板的续期记录"
# 面板可能把数据摊在多个 sqlite 模块库里，不一定在主库。逐个找。
RECORDS=0
if command -v sqlite3 >/dev/null 2>&1 && [ -d "${PANEL_DB_DIR:-}" ]; then
  for f in "$PANEL_DB_DIR"/*.db; do
    [ -f "$f" ] || continue
    for t in $(sqlite3 "$f" ".tables" 2>/dev/null | tr -s ' ' '\n' | grep -iE 'ssl|cert'); do
      n=$(sqlite3 "$f" "SELECT COUNT(*) FROM \"$t\"" 2>/dev/null)
      printf '  %-28s 表 %-14s %s 行\n' "$(basename "$f")" "$t" "${n:-?}"
      [ "${n:-0}" -gt 0 ] && RECORDS=$((RECORDS + n))
    done
  done
else
  echo "  (未配置 PANEL_DB_DIR 或缺 sqlite3)"
fi

section "4. 续期任务"
# 注意：面板的 cron 脚本目录常常**不在** PANEL_ROOT 下面，
# 配置里要按实际路径填，否则这一节会静默为空。
TASKS=0
if [ -n "${PANEL_CRON_DIR:-}" ] && [ -d "$PANEL_CRON_DIR" ]; then
  while read -r f; do
    [ -n "$f" ] || continue
    if grep -qiE 'acme|ssl|cert|renew' "$f" 2>/dev/null; then
      sched=$(crontab -l 2>/dev/null | grep -m1 -F "$(basename "$f")" | awk '{print $1,$2,$3,$4,$5}')
      echo "  续期任务: $f"
      echo "    计划: $sched   (按当前时区 $(timedatectl show -p Timezone --value 2>/dev/null) 解释)"
      if [ -f "$f.log" ]; then
        echo "    最近日志: $(tail -3 "$f.log" 2>/dev/null | tr '\n' ' ' | head -c 160)"
      else
        echo "    [注意] 没有日志文件，可能一次都没跑过"
      fi
      TASKS=$((TASKS + 1))
    fi
  done < <(crontab -l 2>/dev/null | grep -oE "${PANEL_CRON_DIR}/[a-f0-9]{32}" | sort -u)
  [ "$TASKS" -eq 0 ] && echo "  (在 $PANEL_CRON_DIR 下没找到证书相关任务)"
else
  echo "  (PANEL_CRON_DIR 未配置或不存在: ${PANEL_CRON_DIR:-未设置})"
fi

section "5. HTTP-01 验证目录"
# 续期走 HTTP-01 时需要往站点根目录写 .well-known/acme-challenge/
# 多个域名可能共用一个站点（副域名只出现在证书 SAN 和 server_name 里），
# 所以先按域名同名目录找，找不到再回到 vhost 配置里查真实 root。
resolve_domains
echo "  域名来源: $OPS_DOMAINS_MODE（${#OPS_DOMAINS[@]} 个）"

# 所有证书的 SAN 汇总一次，用于判断某域名是不是只被通配符覆盖
CERT_SANS=$(for d in "$PANEL_CERT_DIR"/*/; do
  [ -f "$d/fullchain.pem" ] || continue
  openssl x509 -noout -ext subjectAltName -in "$d/fullchain.pem" 2>/dev/null \
    | tail -1 | tr ',' '\n' | sed -e 's/.*DNS://' -e 's/[[:space:]]//g'
done | grep -v '^$' | sort -u)

# 有精确 SAN -> 不是通配符覆盖；只有 *.父域 匹配 -> 是
wildcard_only() {
  printf '%s\n' "$CERT_SANS" | grep -qxF "$1" && return 1
  printf '%s\n' "$CERT_SANS" | grep -qxF "*.${1#*.}"
}

for dom in "${OPS_DOMAINS[@]}"; do
  if wildcard_only "$dom"; then
    printf '  [跳过] %-30s 通配符证书，续期走 DNS-01，不需要验证目录\n' "$dom"
    continue
  fi
  p="$WWWROOT/$dom"
  if [ -d "$p" ]; then
    printf '  [OK]   %-30s %s\n' "$dom" "$p"
    continue
  fi
  root=""
  if [ -d "${PANEL_VHOST_DIR:-}" ]; then
    vf=$(grep -lE "server_name[^;]*[[:space:]]${dom//./\\.}[[:space:];]" "$PANEL_VHOST_DIR"/*.conf 2>/dev/null | head -1)
    [ -n "$vf" ] && root=$(grep -m1 -E '^[[:space:]]*root[[:space:]]' "$vf" | awk '{print $2}' | tr -d ';')
  fi
  if [ -n "$root" ] && [ -d "$root" ]; then
    printf '  [OK]   %-30s %s (与主域名共用站点)\n' "$dom" "$root"
  else
    printf '  [注意] %-30s 找不到站点根目录\n' "$dom"
    warn "$dom 没有可写的验证目录，HTTP-01 续期会失败"
  fi
done

section 结论
if [ "$RECORDS" -gt 0 ] && [ "$TASKS" -gt 0 ]; then
  ok "证书文件、面板记录、续期任务三方齐全 —— 自动续期具备条件"
  echo "  仍建议手动触发一次续期任务，确认它认得这些记录。"
elif [ "$RECORDS" -gt 0 ] && [ "$TASKS" -eq 0 ]; then
  warn "有记录但没找到续期任务"
  cat <<'EOF'
  两种可能：
    1. PANEL_CRON_DIR 配错了（面板的 cron 目录常常不在面板根目录下）
       用 crontab -l 看任务的实际路径，改配置后重跑
    2. 续期任务确实没建 —— 去面板的计划任务里加回来
EOF
else
  warn "面板里没有证书记录 —— 这就是「证书在但不会续」的状态"
  cat <<'EOF'
  处理方式：在面板里逐站重新申请。不建议从旧机导记录，
  导入后往往出现记录与实际状态对不上、点部署报错，反而更难排查。

  重新申请时注意：
    · 多域名证书别漏域名（看第 1 节的 SAN 列）
    · 算法优先 EC256：强度约等于 RSA3072，握手开销远低于 RSA2048
    · Let's Encrypt 每周对同一组域名有重复签发次数限制，别反复试
EOF
fi
finish
