#!/usr/bin/env bash
# vpsscore/probe.sh — VPS 质量采集探针（服务端）
# VERSION: 1.0.0
#
# 在被评估的机器上运行，把硬件 / 线路 / IP 三类指标采成一份 JSON。
# 评分和横向对比交给 vpsscore/score.sh —— 采集与判断分开，理由：
#   · 采集要在每台机器上跑，判断要把所有机器放在一起看
#   · 阈值会随你的机群变化而调整，不该写死在采集端
#
# 刻意不依赖 lib/common.sh 与 env.conf：被评估的往往是刚开的裸机。
#
# 用法:
#   probe.sh                  跑标准采集（约 2~4 分钟）
#   probe.sh --quick          跳过带宽与磁盘测试（约 30 秒）
#   probe.sh --with-ecs       额外跑一遍 ecs.sh 并留存原始输出用于交叉验证
#   probe.sh --out <目录>     指定输出目录（默认 /var/lib/vpsscore）
#
# ⚠️ 关于可信度：每个指标都带 confidence 字段
#      high   确定性测量，可重复
#      medium 受时段/对端影响，单次结果仅供参考
#      low    依赖第三方判定，口径不透明
#    评分时按可信度加权，别把 medium 当成 high 用。

set -o pipefail
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }

QUICK=0; WITH_ECS=0; OUTDIR=/var/lib/vpsscore
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --with-ecs) WITH_ECS=1 ;;
    --out) shift; OUTDIR="${1:?--out 后面要跟目录}" ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

TS=$(date -u +%Y%m%d%H%M%S)
HOST=$(hostname)
mkdir -p "$OUTDIR"
JSON="$OUTDIR/${HOST}_${TS}.json"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── 中国三网骨干测试点（besttrace 常用）──────────────────────
# 可用 VPSSCORE_PING_TARGETS 覆盖，格式: "标签=IP 标签=IP"
PING_TARGETS="${VPSSCORE_PING_TARGETS:-电信=219.141.136.10 联通=202.106.50.1 移动=221.179.155.161}"
# 带宽测试端点（Cloudflare，全球任播，无需注册）
SPEED_URL="${VPSSCORE_SPEED_URL:-https://speed.cloudflare.com/__down?bytes=104857600}"

say()  { printf '  %s\n' "$*" >&2; }
step() { printf '\n▸ %s\n' "$*" >&2; }

# JSON 拼装：值已按类型处理，字符串调用方自己加引号
J=""
add() { J="${J}${J:+,}\"$1\":$2"; }
str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
nul() { printf 'null'; }

echo "════ VPS 质量采集 · $HOST · $(date -u '+%F %T') UTC ════" >&2

# ==================== 1. 身份与虚拟化 ====================
step "1/6 基础信息"
. /etc/os-release 2>/dev/null
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
say "系统 ${PRETTY_NAME:-?} | 内核 $(uname -r) | 虚拟化 $VIRT"
add host        "$(str "$HOST")"
add probed_at   "$(str "$(date -u +%FT%TZ)")"
add probe_ver   "$(str '1.0.0')"
add os          "$(str "${PRETTY_NAME:-unknown}")"
add kernel      "$(str "$(uname -r)")"
add virt        "$(str "$VIRT")"
# LXC/OpenVZ 超售比 KVM 严重得多，评分时这是个硬扣分项
case "$VIRT" in
  lxc|openvz|lxc-libvirt) add virt_class "$(str 'container')" ;;
  kvm|qemu|vmware|xen|microsoft) add virt_class "$(str 'full')" ;;
  none) add virt_class "$(str 'bare-metal')" ;;
  *) add virt_class "$(str 'unknown')" ;;
esac

# ==================== 2. 硬件 ====================
step "2/6 硬件"
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
CPU_CORES=$(nproc)
CPU_MHZ=$(grep -m1 'cpu MHz' /proc/cpuinfo | sed 's/.*: //' | cut -d. -f1)
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
DISK_GB=$(df -BG --output=size / | tail -1 | tr -dc 0-9)
say "CPU ${CPU_MODEL} × ${CPU_CORES} | 内存 ${MEM_MB}MB | 磁盘 ${DISK_GB}G"
add cpu_model "$(str "$CPU_MODEL")"
add cpu_cores "$CPU_CORES"
add cpu_mhz   "${CPU_MHZ:-null}"
add mem_mb    "$MEM_MB"
add swap_mb   "$SWAP_MB"
add disk_gb   "${DISK_GB:-null}"

# CPU 单核跑分：用 openssl speed，因为它到处都有、不用装东西、结果可重复。
# 取 sha256 在 8192 字节块上的吞吐（KB/s），单位统一成 MB/s。
if command -v openssl >/dev/null 2>&1; then
  CPU_SCORE=$(openssl speed -seconds 2 sha256 2>/dev/null \
    | awk '/^sha256/{gsub(/k/,"",$NF); printf "%.0f", $NF/1024}')
  say "CPU 单核 sha256 ${CPU_SCORE:-?} MB/s"
  add cpu_sha256_mbs "${CPU_SCORE:-null}"
  add cpu_bench_confidence "$(str 'high')"
else
  add cpu_sha256_mbs "$(nul)"; add cpu_bench_confidence "$(str 'none')"
fi

# steal time：虚拟化超售的直接证据。采样 10 秒看增量。
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
sleep 10
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat
TOT=$(( (u2-u1)+(n2-n1)+(s2-s1)+(i2-i1)+(w2-w1)+(irq2-irq1)+(sirq2-sirq1)+(st2-st1) ))
STEAL_PCT=$(awk -v s="$((st2-st1))" -v t="$TOT" 'BEGIN{printf "%.2f", (t>0)?s*100/t:0}')
say "steal time ${STEAL_PCT}%（10 秒采样；>2% 说明宿主机超售）"
add steal_pct "$STEAL_PCT"
add steal_confidence "$(str 'medium')"   # 10 秒只是快照，长期趋势要看监控

# 磁盘
if [ "$QUICK" -eq 0 ]; then
  DD_FILE=/var/tmp/.vpsscore_dd
  DISK_W=$(dd if=/dev/zero of="$DD_FILE" bs=1M count=512 conv=fdatasync 2>&1 \
    | awk '/copied|bytes/{print $(NF-1)" "$NF}' | tail -1)
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  DISK_R=$(dd if="$DD_FILE" of=/dev/null bs=1M iflag=direct 2>&1 \
    | awk '/copied|bytes/{print $(NF-1)" "$NF}' | tail -1)
  rm -f "$DD_FILE"
  say "磁盘 顺序写 ${DISK_W:-?} / 顺序读 ${DISK_R:-?}"
  add disk_seq_write "$(str "${DISK_W:-unknown}")"
  add disk_seq_read  "$(str "${DISK_R:-unknown}")"
  # 4K 随机要 fio，没装就如实标注缺失，不用顺序读写去糊弄
  if command -v fio >/dev/null 2>&1; then
    FIO=$(fio --name=r --rw=randread --bs=4k --size=64M --numjobs=1 --runtime=8 \
              --time_based --direct=1 --group_reporting --minimal 2>/dev/null | cut -d';' -f8)
    add disk_4k_read_iops "${FIO:-null}"
  else
    add disk_4k_read_iops "$(nul)"
    say "未装 fio，跳过 4K 随机（apt install fio 后可测）"
  fi
  add disk_confidence "$(str 'high')"
else
  add disk_seq_write "$(nul)"; add disk_seq_read "$(nul)"
  add disk_4k_read_iops "$(nul)"; add disk_confidence "$(str 'skipped')"
fi

# ==================== 3. 网络形态 ====================
step "3/6 网络形态"
PUB4=$(curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null)
PUB6=$(curl -s -6 --max-time 10 https://api64.ipify.org 2>/dev/null)
NIC4=$(ip -4 -br addr | grep -v '^lo' | awk '{print $3}' | tr '\n' ' ')
DIRECT4=false
[ -n "$PUB4" ] && ip -4 -br addr | grep -qF "$PUB4" && DIRECT4=true
HAS_V6=false
[ -n "$PUB6" ] && ip -6 route show default 2>/dev/null | grep -q . && HAS_V6=true
say "IPv4 ${PUB4:-无}（直绑网卡: $DIRECT4） | IPv6 ${PUB6:-无}（可用: $HAS_V6）"
add ipv4 "$(str "${PUB4:-}")"
add ipv6 "$(str "${PUB6:-}")"
add ipv4_on_nic "$DIRECT4"
add ipv6_usable "$HAS_V6"
add nic_addrs "$(str "$NIC4")"

# ==================== 4. 线路质量 ====================
step "4/6 线路质量"
PING_JSON=""
for kv in $PING_TARGETS; do
  label="${kv%%=*}"; ip="${kv##*=}"
  out=$(ping -c 10 -i 0.3 -W 2 "$ip" 2>/dev/null | tail -3)
  loss=$(printf '%s' "$out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
  rtt=$(printf '%s'  "$out" | awk -F'/' '/rtt|round-trip/{print $5}')
  jit=$(printf '%s'  "$out" | awk -F'/' '/rtt|round-trip/{print $7}' | tr -d ' ms')
  say "$label ($ip) 延迟 ${rtt:-?}ms 抖动 ${jit:-?}ms 丢包 ${loss:-?}%"
  PING_JSON="${PING_JSON}${PING_JSON:+,}$(str "$label"):{\"ip\":$(str "$ip"),\"rtt_ms\":${rtt:-null},\"jitter_ms\":${jit:-null},\"loss_pct\":${loss:-null}}"
done
add ping "{$PING_JSON}"
add ping_confidence "$(str 'medium')"   # 单次 10 包，受时段影响

# 带宽：受测速点与时段影响极大，单次结果只能当参考
if [ "$QUICK" -eq 0 ]; then
  BW=$(curl -s -o /dev/null -w '%{speed_download}' --max-time 30 "$SPEED_URL" 2>/dev/null)
  BW_MBPS=$(awk -v b="${BW:-0}" 'BEGIN{printf "%.1f", b*8/1000000}')
  say "下行带宽 ${BW_MBPS} Mbps（单点单次，仅供参考）"
  add down_mbps "$BW_MBPS"
  add bandwidth_confidence "$(str 'medium')"
else
  add down_mbps "$(nul)"; add bandwidth_confidence "$(str 'skipped')"
fi

# 回程路由：国内 VPS 圈最看重的指标，但需要 mtr/traceroute
if command -v mtr >/dev/null 2>&1; then
  T=$(echo "$PING_TARGETS" | awk '{print $1}'); T="${T##*=}"
  mtr -r -c 5 -n "$T" > "$TMP/mtr.txt" 2>/dev/null
  add route_probe "$(str 'mtr')"
  say "回程路由已采样（原始输出随 JSON 一并保存）"
elif command -v traceroute >/dev/null 2>&1; then
  T=$(echo "$PING_TARGETS" | awk '{print $1}'); T="${T##*=}"
  traceroute -n -m 20 -w 2 "$T" > "$TMP/mtr.txt" 2>/dev/null
  add route_probe "$(str 'traceroute')"
else
  add route_probe "$(nul)"
  say "未装 mtr/traceroute，跳过回程路由（apt install mtr-tiny）"
fi

# ==================== 5. IP 质量 ====================
step "5/6 IP 质量"
if [ -n "$PUB4" ]; then
  GEO=$(curl -s --max-time 10 "http://ip-api.com/json/${PUB4}?fields=status,country,regionName,isp,org,as,mobile,proxy,hosting" 2>/dev/null)
  if printf '%s' "$GEO" | grep -q '"status":"success"'; then
    g() { printf '%s' "$GEO" | grep -oE "\"$1\":\"[^\"]*\"" | cut -d'"' -f4; }
    b() { printf '%s' "$GEO" | grep -oE "\"$1\":(true|false)" | cut -d: -f2; }
    say "$(g country) / $(g isp) / $(g as)"
    add geo_country "$(str "$(g country)")"
    add geo_isp     "$(str "$(g isp)")"
    add geo_asn     "$(str "$(g as)")"
    add ip_hosting  "$(b hosting)"
    add ip_proxy    "$(b proxy)"
    # 第三方判定，口径不透明，只能当参考
    add geo_confidence "$(str 'low')"
  else
    add geo_confidence "$(str 'failed')"
    say "ip-api 查询失败（可能限流）"
  fi

  # DNSBL：注意 Spamhaus 已拒绝公共解析器查询，会返回 127.255.255.x
  # ——那是「查询被拒」不是「被列入」，必须区分，否则误判成脏 IP
  if command -v dig >/dev/null 2>&1; then
    REV=$(printf '%s' "$PUB4" | awk -F. '{print $4"."$3"."$2"."$1}')
    BL_JSON=""; BL_HIT=0
    for z in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org dnsbl.sorbs.net; do
      r=$(dig +short +time=3 +tries=1 "${REV}.${z}" A 2>/dev/null | head -1)
      case "$r" in
        "")               v='"clean"' ;;
        127.255.255.*)    v='"query-refused"' ;;   # 公共解析器被拒，非命中
        127.*)            v="\"listed:$r\""; BL_HIT=$((BL_HIT+1)) ;;
        *)                v='"unknown"' ;;
      esac
      BL_JSON="${BL_JSON}${BL_JSON:+,}$(str "$z"):$v"
    done
    say "黑名单命中 $BL_HIT 项（query-refused 不算命中）"
    add dnsbl "{$BL_JSON}"
    add dnsbl_hits "$BL_HIT"
    add dnsbl_confidence "$(str 'medium')"
  else
    add dnsbl_confidence "$(str 'none')"
    say "未装 dig，跳过黑名单（apt install dnsutils）"
  fi
fi
# 「是否被墙」在本机测不出来 —— 需要国内探测点，属客户端探针的范畴
add gfw_status "$(nul)"
add gfw_note "$(str '需从国内探测点测试，服务端无法判定')"

# ==================== 6. 稳定性（占位）====================
step "6/6 稳定性"
say "单次采集看不出稳定性 —— 该项由长期监控提供，此处留空"
add uptime_days "$(awk '{printf "%.1f", $1/86400}' /proc/uptime)"
add stability_score "$(nul)"
add stability_note "$(str '需接入监控采集 7 天以上')"

# ==================== ecs.sh 交叉验证 ====================
if [ "$WITH_ECS" -eq 1 ]; then
  step "附加：ecs.sh 交叉验证"
  ECS=$(command -v ecs.sh || echo /root/ecs.sh)
  if [ -x "$ECS" ] || [ -f "$ECS" ]; then
    say "运行 $ECS（可能需要几分钟）…"
    bash "$ECS" > "$TMP/ecs.log" 2>&1 </dev/null
    cp "$TMP/ecs.log" "${JSON%.json}.ecs.log"
    add ecs_log "$(str "${JSON%.json}.ecs.log")"
    say "原始输出已保存，供人工比对（不自动解析：格式随版本变，解析错比不解析更糟）"
  else
    say "找不到 ecs.sh，跳过"
    add ecs_log "$(nul)"
  fi
fi

# ==================== 落盘 ====================
printf '{%s}\n' "$J" > "$JSON"
[ -s "$TMP/mtr.txt" ] && cp "$TMP/mtr.txt" "${JSON%.json}.route.txt"
ln -sf "$(basename "$JSON")" "$OUTDIR/latest.json"

echo >&2
echo "════ 完成 ════" >&2
echo "  $JSON" >&2
[ -f "${JSON%.json}.route.txt" ] && echo "  ${JSON%.json}.route.txt" >&2
[ -f "${JSON%.json}.ecs.log" ]   && echo "  ${JSON%.json}.ecs.log" >&2
echo >&2
echo "  在每台要对比的机器上都跑一遍，然后把 JSON 收集到一处："  >&2
echo "    scp -P <端口> root@<机器>:$OUTDIR/*.json ./baseline/" >&2
echo "  再用 vpsscore/score.sh 打分与横向对比。" >&2

# 顺手打印一份人类可读的摘要
command -v python3 >/dev/null 2>&1 && python3 - "$JSON" <<'PY' >&2 || true
import json,sys
d=json.load(open(sys.argv[1]))
print("\n──── 摘要 ────")
for k in ("virt","virt_class","cpu_model","cpu_cores","cpu_sha256_mbs","steal_pct",
          "mem_mb","disk_gb","disk_seq_write","down_mbps","geo_country","geo_asn",
          "dnsbl_hits","ipv4_on_nic","ipv6_usable"):
    if k in d and d[k] is not None:
        print(f"  {k:<18} {d[k]}")
if "ping" in d:
    for lbl,v in d["ping"].items():
        print(f"  ping/{lbl:<12} {v.get('rtt_ms')}ms  丢包 {v.get('loss_pct')}%")
PY
