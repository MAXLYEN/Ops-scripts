#!/usr/bin/env bash
# ops/ssl-audit.sh — 证书三方对账
# VERSION: 2.0.0
#
# 证书文件正常 ≠ 会自动续期。这两件事由不同的东西驱动：
#   nginx 直接读文件 → 所以站点当下是好的
#   续期任务读面板记录 → 记录丢了就不会续，到期那天全站一起挂
#
# 迁移后这是最典型的"静默失效"，本脚本把三方摆到一起看。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env PANEL_CERT_DIR

section "1. 证书文件与到期日"
NOW=$(date -u +%s)
for d in "$PANEL_CERT_DIR"/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -f "$d/fullchain.pem" ]; then
    exp=$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)
    end=$(date -u -d "$exp" +%s 2>/dev/null)
    days=$(( (end - NOW) / 86400 ))
    alg=$(openssl x509 -noout -text -in "$d/fullchain.pem" 2>/dev/null \
          | grep -A1 'Public Key Algorithm' | tr -d ' \n' | sed 's/.*Algorithm://;s/PublicKey.*//' | head -c 40)
    san=$(openssl x509 -noout -ext subjectAltName -in "$d/fullchain.pem" 2>/dev/null \
          | tail -1 | sed 's/DNS://g' | tr -d ' ')
    printf '  %-26s 还有 %4s 天  %-22s %s\n' "$n" "$days" "${alg:-?}" "$san"
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
FOUND=0
if command -v sqlite3 >/dev/null 2>&1 && [ -d "${PANEL_DB_DIR:-}" ]; then
  for f in "$PANEL_DB_DIR"/*.db; do
    [ -f "$f" ] || continue
    for t in $(sqlite3 "$f" ".tables" 2>/dev/null | tr -s ' ' '\n' | grep -iE 'ssl|cert'); do
      n=$(sqlite3 "$f" "SELECT COUNT(*) FROM \"$t\"" 2>/dev/null)
      printf '  %-28s 表 %-14s %s 行\n' "$(basename "$f")" "$t" "${n:-?}"
      [ "${n:-0}" -gt 0 ] && FOUND=1
    done
  done
fi
[ "$FOUND" -eq 1 ] || warn "面板里找不到任何非空的证书记录 —— 自动续期很可能不会发生"

section "4. 续期任务"
if [ -d "${PANEL_CRON_DIR:-}" ]; then
  crontab -l 2>/dev/null | grep -oE "${PANEL_CRON_DIR}/[a-f0-9]{32}" | sort -u | while read -r f; do
    if grep -qiE 'acme|ssl|cert|renew' "$f" 2>/dev/null; then
      sched=$(crontab -l 2>/dev/null | grep -m1 -F "$(basename "$f")" | awk '{print $1,$2,$3,$4,$5}')
      echo "  续期任务: $f   计划: $sched"
      [ -f "$f.log" ] && echo "    最近日志: $(tail -3 "$f.log" 2>/dev/null | tr '\n' ' ' | head -c 160)"
    fi
  done
fi

section "5. HTTP-01 验证目录"
# 续期走 HTTP-01 时需要往站点根目录写 .well-known/acme-challenge/
for dom in $DOMAINS; do
  p="$WWWROOT/$dom"
  [ -d "$p" ] && printf '  [OK]   %-30s %s\n' "$dom" "$p" \
              || printf '  [注意] %-30s %s 不存在\n' "$dom" "$p"
done

section 结论
cat <<EOF
  第 1 节有内容、第 3 节全是 0 行 —— 这就是"证书在但不会续"的状态。
  处理方式：在面板里逐站重新申请。不建议从旧机导记录，
  导入后往往出现记录与实际状态对不上、点部署报错，反而更难排查。

  重新申请时注意：
    · 多域名证书别漏域名（看第 1 节的 SAN 列）
    · 算法优先 EC256：强度约等于 RSA3072，握手开销远低于 RSA2048
    · Let's Encrypt 每周对同一组域名有重复签发次数限制，别反复试
EOF
finish
