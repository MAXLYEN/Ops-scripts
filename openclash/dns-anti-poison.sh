#!/bin/sh
# dns-anti-poison.sh — 为 OpenClash 注入国内直连、境外代理的 DoH 分流配置
# VERSION: 1.0.0
# 用法: sh dns-anti-poison.sh [--check|--uninstall|--dry-run]
# 配置: OPS_OVERWRITE 指定目标文件；OPS_DNS_CN、OPS_DNS_FQ、OPS_DNS_DIRECT
#       分别指定国内 DoH、境外 DoH 和需直连解析的域名，列表用逗号分隔。
# 安装/更新会备份原文件，并把配置块放在目标文件第一个 exit 0 之前。

set -e

OVERWRITE="${OPS_OVERWRITE:-/etc/openclash/custom/openclash_custom_overwrite.sh}"
MARK_BEGIN="# OPS-DNS"
MARK_END="# OPS-DNS-END"

OPS_DNS_CN="${OPS_DNS_CN:-https://doh.pub/dns-query,https://dns.alidns.com/dns-query}"
OPS_DNS_FQ="${OPS_DNS_FQ:-https://cloudflare-dns.com/dns-query,https://dns.google/dns-query}"
OPS_DNS_DIRECT="${OPS_DNS_DIRECT:-}"

MODE=install
case "$1" in
  --check)     MODE=check ;;
  --uninstall) MODE=uninstall ;;
  --dry-run)   MODE=dryrun ;;
  "")          MODE=install ;;
  *)           echo "未知参数: $1"; echo "用法: $0 [--check|--uninstall|--dry-run]"; exit 1 ;;
esac

log() { echo "[dns-anti-poison] $*"; }
die() { echo "[dns-anti-poison] !! $*" >&2; exit 1; }

[ -f "$OVERWRITE" ] || die "找不到 $OVERWRITE
  若 OpenClash 装在别处，用 OPS_OVERWRITE=<路径> 指定"

# 将逗号分隔的地址转成 ruby_edit 使用的数组元素列表。
to_ruby_list() {
  echo "$1" | tr ',' '\n' | sed "s/^[[:space:]]*//; s/[[:space:]]*$//" \
    | grep -v '^$' | sed "s/^/'/; s/$/'/" | paste -sd, -
}

CN_LIST=$(to_ruby_list "$OPS_DNS_CN")
FQ_LIST=$(to_ruby_list "$OPS_DNS_FQ")
[ -n "$CN_LIST" ] || die "OPS_DNS_CN 为空"
[ -n "$FQ_LIST" ] || die "OPS_DNS_FQ 为空"

DIRECT_ENTRIES=""
if [ -n "$OPS_DNS_DIRECT" ]; then
  for d in $(echo "$OPS_DNS_DIRECT" | tr ',' ' '); do
    d=$(echo "$d" | sed "s/^[[:space:]]*//; s/[[:space:]]*$//")
    [ -n "$d" ] || continue
    DIRECT_ENTRIES="${DIRECT_ENTRIES}'+.${d}'=>[${CN_LIST}], "
  done
fi

if [ "$MODE" = check ]; then
  log "目标文件: $OVERWRITE"
  if grep -q "^${MARK_BEGIN}\$" "$OVERWRITE"; then
    log "状态: 已安装"
    B=$(grep -n "^${MARK_BEGIN}\$" "$OVERWRITE" | cut -d: -f1)
    E=$(grep -n "^exit 0\$" "$OVERWRITE" | head -1 | cut -d: -f1)
    if [ -n "$E" ] && [ "$B" -gt "$E" ]; then
      log "!! 块在第 $B 行，但 'exit 0' 在第 $E 行 —— 块位于死区，不会执行"
      log "   重新运行本脚本（不带参数）可自动修正位置"
    else
      log "位置: 第 $B 行，在 exit 0 之前，正常"
    fi
    echo "--- 当前块内容 ---"
    sed -n "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/p" "$OVERWRITE"
  else
    log "状态: 未安装"
  fi
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  grep -q "^${MARK_BEGIN}\$" "$OVERWRITE" || { log "未安装，无需移除"; exit 0; }
  cp "$OVERWRITE" "${OVERWRITE}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$OVERWRITE"
  log "已移除 OPS-DNS 块（原文件已备份）"
  log "执行 /etc/init.d/openclash restart 生效"
  exit 0
fi

BLOCK=$(cat <<OPSEOF
${MARK_BEGIN}
# 反 DNS 投毒：国内域名走国内 DoH 直连，境外域名走境外 DoH 且经代理解析
# 由 dns-anti-poison.sh 生成，勿手工编辑；重新运行该脚本即可更新
ruby_edit "\$CONFIG_FILE" "['dns']['respect-rules']" "true"
ruby_edit "\$CONFIG_FILE" "['dns']['nameserver']" "[${CN_LIST}]"
ruby_edit "\$CONFIG_FILE" "['dns']['proxy-server-nameserver']" "[${CN_LIST}]"
ruby_edit "\$CONFIG_FILE" "['dns']['nameserver-policy']" "{'geosite:private,cn'=>[${CN_LIST}], ${DIRECT_ENTRIES}'geosite:geolocation-!cn'=>[${FQ_LIST}]}"
LOG_OUT "OPS: DNS 分流策略已注入"
${MARK_END}
OPSEOF
)

if [ "$MODE" = dryrun ]; then
  log "以下内容将被插入到 $OVERWRITE 的 'exit 0' 之前："
  echo "-----------------------------------------------------------"
  echo "$BLOCK"
  echo "-----------------------------------------------------------"
  exit 0
fi

# 内容或位置不符时先备份，再替换原配置块。
if grep -q "^${MARK_BEGIN}\$" "$OVERWRITE"; then
  CUR=$(sed -n "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/p" "$OVERWRITE")
  CUR_LINE=$(grep -n "^${MARK_BEGIN}\$" "$OVERWRITE" | cut -d: -f1)
  EXIT_LINE=$(grep -n "^exit 0\$" "$OVERWRITE" | head -1 | cut -d: -f1)
  POS_OK=yes
  [ -n "$EXIT_LINE" ] && [ "$CUR_LINE" -gt "$EXIT_LINE" ] && POS_OK=no

  if [ "$CUR" = "$BLOCK" ] && [ "$POS_OK" = yes ]; then
    log "块已存在、内容一致、位置正确 —— 无需改动"
    exit 0
  fi
  [ "$POS_OK" = no ] && log "检测到旧块位于 'exit 0' 之后（死区），将重新定位"
  cp "$OVERWRITE" "${OVERWRITE}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$OVERWRITE"
  log "已移除旧块（原文件已备份）"
else
  cp "$OVERWRITE" "${OVERWRITE}.bak.$(date +%Y%m%d%H%M%S)"
  log "首次安装（原文件已备份）"
fi

# 插到第一个 exit 0 前，避免配置块落在不会执行的区域。
TMP=$(mktemp)
if grep -q "^exit 0\$" "$OVERWRITE"; then
  awk -v blk="$BLOCK" '
    /^exit 0$/ && !done { print blk; print ""; done=1 }
    { print }
  ' "$OVERWRITE" > "$TMP"
else
  cp "$OVERWRITE" "$TMP"
  { echo ""; echo "$BLOCK"; } >> "$TMP"
fi
mv "$TMP" "$OVERWRITE"
chmod +x "$OVERWRITE"

if ! sh -n "$OVERWRITE" 2>/dev/null; then
  die "写入后语法检查失败！请用备份文件回滚：
  cp ${OVERWRITE}.bak.<最新时间戳> $OVERWRITE"
fi

B=$(grep -n "^${MARK_BEGIN}\$" "$OVERWRITE" | cut -d: -f1)
E=$(grep -n "^exit 0\$" "$OVERWRITE" | head -1 | cut -d: -f1)
log "已写入：块在第 $B 行${E:+，exit 0 在第 $E 行}"
[ -n "$E" ] && [ "$B" -gt "$E" ] && die "块仍在死区，请手工检查文件结构"

log "语法检查通过"
echo
log "下一步："
echo "  /etc/init.d/openclash restart"
echo "  # 等约 40 秒后验证："
echo "  grep -i 'OPS:' /tmp/openclash.log | tail        # 应见「DNS 分流策略已注入」"
echo "  nslookup <某境外域名> 127.0.0.1                  # 应为 fake-ip"
echo "  tail -n 30 /tmp/openclash.log | grep <某境外域名> # 看规则命中是否合理"
echo
log "回滚：sh $0 --uninstall && /etc/init.d/openclash restart"
