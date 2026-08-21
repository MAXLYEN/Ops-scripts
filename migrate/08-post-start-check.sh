#!/usr/bin/env bash
# 08-post-start-check.sh — 容器启动后的端到端验收
# VERSION: 2.1.0
# 2.1.0: 第 3 节的域名来源改用 resolve_domains()。原来直接遍历 DOMAINS ——
#        配置漏了哪个站点，那个站点就不会被探测，而输出仍然全绿。
#        切换前的最后一道验收出这种假绿，代价太大。
#
# 第 3 节最有价值：用 --resolve 绕过 DNS 直接走本机 nginx，等于在切换前
# 完整跑通了外部访问路径（nginx 配置 → 证书 → 反代 → 容器）。全绿就意味着
# 除了 DNS 之外都通了。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
resolve_domains
mysql_ready

section "1. 容器状态"
if docker_ready; then
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  bad=$(docker ps -a --filter 'status=exited' --filter 'status=dead' --format '{{.Names}}')
  [ -n "$bad" ] && warn "非运行状态的容器: $(echo "$bad" | tr '\n' ' ')"
  unhealthy=$(docker ps --filter 'health=unhealthy' --format '{{.Names}}')
  [ -n "$unhealthy" ] && warn "unhealthy: $(echo "$unhealthy" | tr '\n' ' ')"
else
  warn "docker 不可用"
fi

section "2. 数据库实际连接来源"
# 这是授权是否正确的最硬判据 —— 显示的是 MySQL 真正接到的来源地址。
my -e "SELECT user,
              LEFT(host, LOCATE(':',CONCAT(host,':'))-1) AS src,
              db, COUNT(*) AS conns
         FROM information_schema.processlist
        WHERE user <> 'root'
        GROUP BY user, src, db"
echo "  （空表说明此刻没有活跃连接，不一定是故障 —— 看第 5 节的日志扫描）"

section "3. 经本机 nginx 访问各域名（绕过 DNS）"
echo "  域名来源: $OPS_DOMAINS_MODE（${#OPS_DOMAINS[@]} 个）"
for d in "${OPS_DOMAINS[@]}"; do
  code=$(probe_domain_local "$d")
  case "$code" in
    200|301|302|303|307|308) mark="[OK]  " ;;
    401|403)                 mark="[鉴权]" ;;
    000)                     mark="[失败]"; OPS_WARNINGS=$((OPS_WARNINGS+1)) ;;
    *)                       mark="[注意]" ;;
  esac
  printf '  %s %-30s %s\n' "$mark" "$d" "$code"
done

section "4. 证书"
if [ -d "${PANEL_CERT_DIR:-}" ]; then
  now=$(date -u +%s)
  for dir in "$PANEL_CERT_DIR"/*/; do
    [ -f "$dir/fullchain.pem" ] || continue
    n=$(basename "$dir")
    end=$(date -u -d "$(openssl x509 -enddate -noout -in "$dir/fullchain.pem" | cut -d= -f2)" +%s 2>/dev/null)
    if [ -n "$end" ]; then
      days=$(( (end - now) / 86400 ))
      [ "$days" -lt 21 ] && warn "$n 还有 ${days} 天到期" \
                         || printf '  [OK]   %-26s 还有 %s 天\n' "$n" "$days"
    fi
  done
fi
# 证书文件正常不代表续期会发生 —— 面板的续期记录是另一套存储
echo "  [提醒] 另需人工确认面板的证书管理页面有记录，否则不会自动续期"

section "5. 日志报错扫描"
if docker_ready; then
  for c in $(docker ps --format '{{.Names}}'); do
    echo "--- $c ---"
    hits=$(docker logs --tail 200 "$c" 2>&1 \
           | grep -iE "can't connect|connection refused|access denied|fatal|panic|SQLSTATE|i/o timeout" \
           | head -5)
    if [ -n "$hits" ]; then
      echo "$hits" | sed 's/^/    /'; OPS_WARNINGS=$((OPS_WARNINGS+1))
    else
      echo "    (无匹配报错)"
    fi
  done
fi

section "6. 防火墙与端口"
ufw status numbered 2>/dev/null | sed 's/^/  /' || echo "  (ufw 未启用)"
echo "  --- 对外监听 ---"
ss -lntH 2>/dev/null | awk '{print $4}' | grep -v '^127\.' | grep -v '^\[::1\]' | sort -u | sed 's/^/    /'
echo "  [提醒] Docker 会自行插 iptables 规则绕过 ufw，0.0.0.0 绑定的容器端口"
echo "         即使 ufw 没放行也是对全网敞开的"

finish
