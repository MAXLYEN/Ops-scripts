#!/usr/bin/env bash
# vpsscore/probe.sh — VPS 质量采集探针（服务端）
# VERSION: 1.1.4
# 1.1.4: 修 ICMP 交叉验证从未生效 —— 真正的原因是数值比较写成了字符串比较。
#        1.1.2 把丢包率格式化到一位小数（ping 会给出 16.6667% 这种值），
#        于是 100 变成 "100.0"，而触发条件写的是 [ "$loss" = "100" ]，
#        字符串不相等，整段交叉验证从 1.1.2 起就再没被调用过。
#        后果：电信那一路每台都记成 100% 丢包，三网均值凭空多 33%，
#        而丢包占线路评分 30 分权重 —— 所有机器的线路分都偏低且趋同。
#        改用 awk 做数值比较，不再依赖字符串形态。
#        同时回退 1.1.3 的端口改动：那一版我拿容器（走代理出网）的测试结果
#        当成了真实机器的结果，得出「53 不通、80/443 通」的反向结论。
#        在实际机器上实测：53 通、80/443 不通。恢复 53 为首选，
#        并保留多端口回退列表以防单一端口哪天关闭。
# 1.1.3: （端口改动，方向错误，已由 1.1.4 回退）
# 1.1.2: 去掉调用 IPQuality 时的 -n。-n 是「跳过依赖检查与安装」，而它的依赖
#        （ip.sh:401）是 jq curl bc netcat dnsutils —— 缺 jq 时 db_maxmind 里
#        `jq . || RESPONSE=""` 会置空，进而 mode_lite=1，脚本降级成 Lite：
#        风险评分、IP 类型、五个数据库整节失效。实测机群 23 台里 19 台缺 jq，
#        所以绝大多数机器拿到的都是残缺数据。改为 -y（自动装依赖、不交互）。
#        同时：解析器识别 Lite（Info.ASN 为空即是，那正是 mode_lite 的触发条件）
#        并直接判失败 —— 半残数据拿去打分只会得出错误结论；
#        失败时 ipq_note 记录 IPQuality 的真实输出，不再由脚本编造原因。
# 1.1.1: 修 IPQuality 解析的语言依赖。中文环境下它返回「解锁」「原生」「机房」
#        「原生IP」，而解析只认英文，于是把七家流媒体全判成未解锁 ——
#        这种错误不报错、不留空，给出的是一个看起来正常的假结论，
#        比崩溃危险得多（实测该机 YouTube 可正常观看，官方报告也显示原生解锁）。
#        改法：调用加 -l en 固定语言，解析再做一层中英兼容兜底。
#        同时：风险评分改为每家单独留存（单一库的离群值不该主导结论，
#        实测有机器 Scamalytics 报 67 而其余都是个位数）；记录哪些库整列
#        无数据（分母静默变小会让「没查到」看起来像「没问题」）；
#        新增 25 端口出站检测；摘要里显示 IP 质量结果。
# 1.1.0: ① 新增 --ipq：调用 IPQuality（IP.Check.Place）做深度 IP 质量检测。
#           原来只查 4 个 DNSBL zone，测不出真正决定「IP 好不好」的东西 ——
#           原生/广播、机房/住宅、六家风险评分、九库代理标记、流媒体原生解锁。
#           默认不跑：它要查十几个第三方 API，24 台并发会被限流，
#           而被限流得出的「IP 质量差」是假结论，比没有数据更糟。
#        ② 缺工具不再静默留空。ping 没装会让丢包全测不出来，而探针只是
#           留了个 null —— 打分时该项被剔除并归一化，反而拉高了排名。
#           现在统一记进 missing_tools 并在摘要里明说。
# 1.0.4: 修 `set -o pipefail` + `grep -q` 的竞态（三处）。grep -q 一匹配上就
#        退出并关闭管道，上游进程吃到 SIGPIPE 退出码 141，pipefail 把整条管道
#        判成失败 —— 于是「匹配成功」变成了「没匹配上」。是否触发取决于上游
#        写完没写完，纯看调度：同一台机器连续采集会随机给出相反结论。
#        实测 300 次里误判 5 次。受影响的判断：
#          · ipv4_on_nic  —— 直绑网卡的机器被随机报成 NAT
#          · ipv6_usable
#          · IP 质量整节 —— 被随机跳过，日志却说「ip-api 查询失败（可能限流）」，
#            排查方向会被带偏
#        改法：先把输出收进变量，再对变量做匹配，不在管道里判断。
#        顺带：丢包率/延迟收敛到 1 位小数（ping 会给出 16.6667% 这种值）。
# 1.0.3: 三处修正，都是「把无数据伪装成有结论」的同一类错误。
#        ① 取不到公网 IP 时 ipv4_on_nic / ipv6_usable 写 null，不再写 false ——
#           原来 curl 一超时就报告「IP 没绑在网卡上」，而事实是这项没测出来。
#           公网 IP 改为最多重试 3 次、换备用端点。
#        ② cdn_connect_ms 扣掉 DNS 解析时间（time_connect - time_namelookup），
#           原来把首次解析的耗时算进了 RTT，26ms 里分不出哪些是 DNS。
#        ③ ping 采样 10 → 30 包。10 包的丢包率分辨率只有 10%，
#           会把「丢 1 个」呈现成「丢包 10%」，两轮采集能得出相反结论。
# 1.0.2: 带宽从「成/败」改成可诊断：同时记录已传字节、耗时、curl 退出码。
#        「跑慢了被 30 秒掐断」和「连接压根没起来」原来都写 null，
#        但前者是有数据的（均速有效），后者才是真没数据。
#        默认负载 100MB → 25MB，慢线路也能跑完。
#        新增 CDN 边缘探测（colo / 建连 RTT）—— 一次轻量请求就能暴露
#        「宣称在 A 地、实际被路由到 B 地」以及异常的 RTT 底噪，
#        这正是 IP 库三处自相矛盾时唯一能自己测出来的硬证据。
# 1.0.1: 修 JSON 产出损坏 —— ping 汇总行末尾的 ", pipe N"（RTT 超过发包间隔就会
#        出现，-i 0.3 意味着 >300ms 的线路必然触发）被 tr -d ' ms' 压成
#        "4.634,pipe2" 原样写进 JSON，整份文件解析不了。顺带四处：
#        ① 所有数值字段过 num() 兜底，非纯数字降级为 null；
#        ② 落盘后自校验 JSON，不合法就报错退出，不再静默说「完成」；
#        ③ 测速失败写 null 而不是 0（0 与「没测出来」在打分时含义完全相反）；
#        ④ ICMP 全丢时补 TCP/53 交叉验证，区分「线路不通」与「ICMP 被过滤」；
#        ⑤ 磁盘顺序读写另存一份数字字段，字符串 "390 MB/s" 没法拿去打分。
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
#   probe.sh --ipq            额外做深度 IP 质量检测（约 +1~2 分钟，查第三方 API）
#   probe.sh --out <目录>     指定输出目录（默认 /var/lib/vpsscore）
#
# ⚠️ 关于可信度：每个指标都带 confidence 字段
#      high   确定性测量，可重复
#      medium 受时段/对端影响，单次结果仅供参考
#      low    依赖第三方判定，口径不透明
#    评分时按可信度加权，别把 medium 当成 high 用。

set -o pipefail
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }

QUICK=0; WITH_ECS=0; DO_IPQ=0; OUTDIR=/var/lib/vpsscore
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --with-ecs) WITH_ECS=1 ;;
    --ipq) DO_IPQ=1 ;;
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
# 25MB：100MB 在 20Mbps 以下的线路跑不完 30 秒，会被掐成「失败」
SPEED_URL="${VPSSCORE_SPEED_URL:-https://speed.cloudflare.com/__down?bytes=26214400}"
# CDN 边缘探测端点（极轻量，返回 colo/loc 等）
TRACE_URL="${VPSSCORE_TRACE_URL:-https://speed.cloudflare.com/cdn-cgi/trace}"

say()  { printf '  %s\n' "$*" >&2; }

# 缺了工具就有指标测不出来，而「测不出来」在打分时会被剔除并归一化 ——
# 结果是缺工具的机器反而排得更靠前。必须如实记下来。
MISSING_TOOLS=""
have() {
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  case " $MISSING_TOOLS " in *" $1 "*) ;; *) MISSING_TOOLS="$MISSING_TOOLS $1" ;; esac
  return 1
}
step() { printf '\n▸ %s\n' "$*" >&2; }

# JSON 拼装：值已按类型处理，字符串调用方自己加引号
J=""
add() { J="${J}${J:+,}\"$1\":$2"; }
str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
nul() { printf 'null'; }
# 写进 JSON 前的最后一道闸：非纯数字一律降级成 null。
# 采集脚本产出不可解析的 JSON，比某个字段缺失严重得多 —— 整个文件都废了。
num() { case "${1:-}" in ''|*[!0-9.]*|*.*.*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# dd 输出形如 "390 MB/s"，字符串没法拿去打分，转成数字另存一份
to_mbs() { awk -v s="$1" 'BEGIN{n=s+0; if(s~/GB\/s/)n*=1024; else if(s~/kB\/s/)n/=1024;
                                if(n<=0){print ""; exit} printf "%.1f", n}'; }

# TCP 连通性探测（不依赖 nc）。
# 用途：ICMP 100% 丢包时区分「线路真的不通」和「只是被过滤了 ICMP」——
# 香港机被电信骨干丢 ICMP 很常见，据此判死刑会误杀。
tcp_ms() {  # $1=ip $2=port；输出毫秒，失败返回非 0
  local t0 t1
  t0=$(date +%s%N)
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null || return 1
  t1=$(date +%s%N)
  echo $(( (t1-t0)/1000000 ))
}

# 端口顺序按实际机器实测：三个测试点的 TCP/53 通，80/443 不通。
# 仍保留回退列表 —— 只写死一个端口的话，哪天它关了交叉验证会再次静默失效。
TCP_PROBE_PORTS="${VPSSCORE_TCP_PORTS:-53 80 443}"
# 输出「毫秒 端口」两个值，不要靠全局变量回传 —— 调用方写成
# ms=$(tcp_probe ip) 时函数跑在子 shell 里，赋的全局变量传不回来
tcp_probe() {  # $1=ip；输出 "<毫秒> <端口>"，全部失败返回非 0
  local ip=$1 port ms
  for port in $TCP_PROBE_PORTS; do
    if ms=$(tcp_ms "$ip" "$port"); then printf '%s %s' "$ms" "$port"; return 0; fi
  done
  return 1
}

echo "════ VPS 质量采集 · $HOST · $(date -u '+%F %T') UTC ════" >&2

# ==================== 1. 身份与虚拟化 ====================
step "1/6 基础信息"
. /etc/os-release 2>/dev/null
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
say "系统 ${PRETTY_NAME:-?} | 内核 $(uname -r) | 虚拟化 $VIRT"
add host        "$(str "$HOST")"
add probed_at   "$(str "$(date -u +%FT%TZ)")"
add probe_ver   "$(str '1.1.4')"
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
  # 同时存一份数字版：字符串 "390 MB/s" 没法直接拿去打分
  add disk_seq_write_mbs "$(num "$(to_mbs "${DISK_W:-}")")"
  add disk_seq_read_mbs  "$(num "$(to_mbs "${DISK_R:-}")")"
  # 4K 随机要 fio，没装就如实标注缺失，不用顺序读写去糊弄
  if have fio; then
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
# 单点单次取公网 IP 太脆：一次超时就会让下面的判断全部失真。
# 换两个端点、各试一轮。
pubip() {  # $1=4 或 6
  local v=$1 u r
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    r=$(curl -s "-$v" --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')
    case "$r" in
      ''|*[!0-9a-fA-F.:]*) continue ;;
      *) printf '%s' "$r"; return 0 ;;
    esac
  done
  return 1
}
PUB4=$(pubip 4) || PUB4=""
PUB6=$(pubip 6) || PUB6=""
NIC4=$(ip -4 -br addr | grep -v '^lo' | awk '{print $3}' | tr '\n' ' ')

# 取不到公网 IP 时这两项是「没测出来」，不是「否」。写 false 等于凭空
# 给出一个结论 —— 打分时会当成 NAT 机器扣分，而它可能是直绑的。
# 注意：不要写成 `ip ... | grep -q`。grep -q 匹配到就退出、关闭管道，
# ip 吃到 SIGPIPE 退出 141，pipefail 会把整条管道判成失败 —— 匹配成功反被
# 当作没匹配。先落变量再比对，顺带按地址字段精确匹配而非子串。
NIC_ADDRS=$(ip -4 -br addr 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
V6_DEFAULT=$(ip -6 route show default 2>/dev/null)
if [ -n "$PUB4" ]; then
  case " $(printf '%s ' $NIC_ADDRS)" in
    *" $PUB4 "*) DIRECT4=true ;;
    *)           DIRECT4=false ;;
  esac
else
  DIRECT4=null
fi
if [ -n "$PUB6" ]; then
  if [ -n "$V6_DEFAULT" ]; then HAS_V6=true; else HAS_V6=false; fi
else
  HAS_V6=null
fi
say "IPv4 ${PUB4:-取不到}（直绑网卡: $DIRECT4） | IPv6 ${PUB6:-无}（可用: $HAS_V6）"
add ipv4 "$(str "${PUB4:-}")"
add ipv6 "$(str "${PUB6:-}")"
add ipv4_on_nic "$DIRECT4"
add ipv6_usable "$HAS_V6"
add nic_addrs "$(str "$NIC4")"

# ==================== 4. 线路质量 ====================
step "4/6 线路质量"
if ! have ping; then
  say "⚠ 未装 ping —— 三网丢包与延迟整节无法测量（apt install iputils-ping）"
fi
PING_JSON=""
for kv in $PING_TARGETS; do
  label="${kv%%=*}"; ip="${kv##*=}"
  # 30 包：10 包的丢包率分辨率只有 10%，丢 1 个就报 10%，
  # 噪声会被当成结论（实测同一条线两轮能得出 0% 和 10% 两种答案）
  out=$(ping -c 30 -i 0.3 -W 2 "$ip" 2>/dev/null | tail -3)
  loss=$(printf '%s' "$out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
  # ping 在丢包数除不尽时会给出 16.6667% 这种值，收敛到 1 位小数
  [ -n "$loss" ] && loss=$(awk -v x="$loss" 'BEGIN{printf "%.1f", x}')
  # RTT 汇总行在丢包/高延迟时末尾会多一截 ", pipe N"（RTT > 发包间隔就会出现，
  # 这里 -i 0.3 意味着 >300ms 的线路必然触发）。先按「= 之后、第一个空格之前」
  # 截出纯数字段，再拆 —— 原来用 tr -d ' ms' 会把它压成 "4.634,pipe2"，
  # 那个值原样进 JSON，整份文件就解析不了了。
  stats=$(printf '%s' "$out" | sed -n 's|.*= \([0-9./]*\).*|\1|p' | head -1)
  rtt=""; jit=""
  if [ -n "$stats" ]; then
    IFS=/ read -r _rmin rtt _rmax jit <<EOF
$stats
EOF
  fi
  # ICMP 全丢时交叉验证：TCP 通得了就是被过滤，不是线路死了
  icmp_only=false; tcpms=""; tcpport=""
  # 数值比较，不要用字符串：loss 经过格式化后是 "100.0"，
  # 写成 [ "$loss" = "100" ] 会永远不成立（1.1.2~1.1.3 就是这么失效的）
  if [ -z "$loss" ] || awk -v x="$loss" 'BEGIN{exit !(x >= 100)}'; then
    if _r=$(tcp_probe "$ip"); then
      icmp_only=true
      tcpms=${_r%% *}; tcpport=${_r##* }
    fi
  fi
  if [ "$icmp_only" = true ]; then
    say "$label ($ip) ICMP 全丢，但 TCP/${tcpport} 通（${tcpms}ms）—— 是 ICMP 被过滤，非线路不通"
  else
    say "$label ($ip) 延迟 ${rtt:-?}ms 抖动 ${jit:-?}ms 丢包 ${loss:-?}%"
  fi
  PING_JSON="${PING_JSON}${PING_JSON:+,}$(str "$label"):{\"ip\":$(str "$ip"),\"rtt_ms\":$(num "$rtt"),\"jitter_ms\":$(num "$jit"),\"loss_pct\":$(num "$loss"),\"icmp_filtered\":$icmp_only,\"tcp_ms\":$(num "$tcpms"),\"tcp_port\":$(num "$tcpport")}"
done
add ping "{$PING_JSON}"
add ping_samples "30"
add ping_confidence "$(str 'medium')"   # 单次 30 包，受时段影响

# 带宽：受测速点与时段影响极大，单次结果只能当参考
if [ "$QUICK" -eq 0 ]; then
  BW_RAW=$(curl -s -o /dev/null -w '%{speed_download} %{size_download} %{time_total}' \
           --max-time 30 "$SPEED_URL" 2>/dev/null)
  BW_RC=$?
  read -r _sp _sz _tt <<EOF
${BW_RAW:-0 0 0}
EOF
  BW_MBPS=$(awk -v b="${_sp:-0}" 'BEGIN{v=b*8/1000000; if(v<0.05){print ""; exit} printf "%.1f", v}')
  # 超时(28)不等于失败：已传够多字节时均速依然有效，只是把置信度降一级。
  # 原来两种情况都写 null —— 但「跑慢了被掐」是有数据的，「连不上」才是真没有。
  if [ -n "$BW_MBPS" ] && [ "${_sz:-0}" -ge 1048576 ] 2>/dev/null; then
    if [ "$BW_RC" -eq 28 ]; then
      say "下行带宽 ${BW_MBPS} Mbps（30 秒内未传完，取已传部分均速）"
      add bandwidth_confidence "$(str 'low')"
    else
      say "下行带宽 ${BW_MBPS} Mbps（单点单次，仅供参考）"
      add bandwidth_confidence "$(str 'medium')"
    fi
    add down_mbps "$(num "$BW_MBPS")"
  else
    say "下行带宽测试失败（curl 退出码 $BW_RC，已传 ${_sz:-0} 字节），该项留空"
    add down_mbps "$(nul)"
    add bandwidth_confidence "$(str 'failed')"
  fi
  # 原始量一并留下：只看一个 Mbps 分不出「慢」和「没测成」
  add down_bytes "$(num "${_sz:-}")"
  add down_secs  "$(num "${_tt:-}")"
  add down_curl_exit "$BW_RC"
else
  add down_mbps "$(nul)"; add bandwidth_confidence "$(str 'skipped')"
  add down_bytes "$(nul)"; add down_secs "$(nul)"; add down_curl_exit "$(nul)"
fi

# CDN 边缘：一次轻量请求换两个硬指标 —— 就近 colo 和建连 RTT。
# 用途是交叉验证 IP 库：IP 库说在 A 地、Cloudflare 却把你路由到 B 地，
# 且建连 RTT 高得离谱时，可信的是后者（它是实测，IP 库是登记信息）。
TR=$(curl -s --max-time 10 -w '\n__T %{time_connect} %{time_namelookup}' "$TRACE_URL" 2>/dev/null)
CDN_COLO=$(printf '%s' "$TR" | sed -n 's/^colo=//p' | head -1)
CDN_LOC=$(printf '%s'  "$TR" | sed -n 's/^loc=//p'  | head -1)
# 扣掉 DNS 解析：time_connect 从发起算起，含首次解析耗时。
# 不扣的话，一次慢 DNS 会被记成「线路 RTT 高」，方向完全错。
CDN_MS=$(printf '%s' "$TR" | awk '/^__T/{v=($2-$3)*1000; if(v<0)v=0; printf "%.0f", v}')
CDN_DNS_MS=$(printf '%s' "$TR" | awk '/^__T/{printf "%.0f", $3*1000}')
if [ -n "$CDN_COLO" ]; then
  say "CDN 边缘 ${CDN_COLO}（${CDN_LOC:-?}）建连 ${CDN_MS:-?}ms（DNS ${CDN_DNS_MS:-?}ms 已扣除）"
  # 建连约等于一个 RTT。同城 colo 该是个位数毫秒；三位数说明路径极长或极拥塞
  if [ -n "$CDN_MS" ] && [ "$CDN_MS" -gt 200 ] 2>/dev/null; then
    say "  ⚠ 到最近边缘就要 ${CDN_MS}ms —— 这不是正常线路的底噪，本机位置存疑"
  fi
  add cdn_colo "$(str "$CDN_COLO")"
  add cdn_loc  "$(str "${CDN_LOC:-}")"
  add cdn_connect_ms "$(num "${CDN_MS:-}")"
  add cdn_dns_ms "$(num "${CDN_DNS_MS:-}")"
else
  add cdn_colo "$(nul)"; add cdn_loc "$(nul)"
  add cdn_connect_ms "$(nul)"; add cdn_dns_ms "$(nul)"
  say "CDN 边缘探测失败"
fi

# 回程路由：国内 VPS 圈最看重的指标，但需要 mtr/traceroute
if have mtr; then
  T=$(echo "$PING_TARGETS" | awk '{print $1}'); T="${T##*=}"
  mtr -r -c 5 -n "$T" > "$TMP/mtr.txt" 2>/dev/null
  add route_probe "$(str 'mtr')"
  say "回程路由已采样（原始输出随 JSON 一并保存）"
elif have traceroute; then
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
  GEO=$(curl -s --max-time 10 "http://ip-api.com/json/${PUB4}?fields=status,country,countryCode,regionName,isp,org,as,mobile,proxy,hosting" 2>/dev/null)
  # 同样避开 pipefail + grep -q 的竞态：这里踩中的话，IP 质量整节会被
  # 随机跳过，而日志只说「查询失败（可能限流）」，排查方向会被带偏
  case "$GEO" in
    *'"status":"success"'*) GEO_OK=1 ;;
    *) GEO_OK=0 ;;
  esac
  if [ "$GEO_OK" -eq 1 ]; then
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
    # 与 CDN 实测的落地位置对账。IP 库是登记信息，CDN 路由是实测 ——
    # 两者不一致时，不替你下结论，但必须把矛盾记进 JSON，否则打分时
    # 会拿一个「香港」的标签去算延迟预期，而机器实际在别处。
    if [ -n "${CDN_LOC:-}" ] && [ -n "$(g countryCode)" ] \
       && [ "$CDN_LOC" != "$(g countryCode)" ]; then
      say "⚠ IP 库称 $(g country)（$(g countryCode)），CDN 实际落地 ${CDN_LOC} —— 两者不一致"
      add geo_mismatch "true"
    else
      add geo_mismatch "false"
    fi
  else
    add geo_confidence "$(str 'failed')"
    say "ip-api 查询失败（可能限流）"
  fi

  # DNSBL：注意 Spamhaus 已拒绝公共解析器查询，会返回 127.255.255.x
  # ——那是「查询被拒」不是「被列入」，必须区分，否则误判成脏 IP
  if have dig; then
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
# ── 深度 IP 质量（可选，--ipq）───────────────────────────────
# 借 IPQuality（github.com/xykt/IPQuality）而不是自己重造：它整合了十来个
# 商业风险库和流媒体探测，这些数据源自己接一遍既不现实也维护不动。
# 只取其 JSON 输出里可量化的部分，原始报告不留（含完整 IP，且体积大）。
if [ "$DO_IPQ" -eq 1 ]; then
  step "IP 质量深度检测（IPQuality，查第三方 API，约 1-2 分钟）"
  IPQ_SH=$(mktemp); IPQ_OUT="$TMP/ipq.json"
  # IPQuality 自己的依赖见 ip.sh:401，缺 jq 会静默降级成 Lite 而不是报错
  IPQ_MISS=""
  for c in curl python3 jq bc dig; do have "$c" || IPQ_MISS="$IPQ_MISS $c"; done
  command -v nc >/dev/null 2>&1 || IPQ_MISS="$IPQ_MISS netcat"
  if [ -n "$IPQ_MISS" ]; then
    say "缺依赖:$IPQ_MISS —— IPQuality 会降级成 Lite，跳过（-y 会尝试自动安装）"
    add ipq_ok "false"; add ipq_note "$(str "缺依赖:$IPQ_MISS")"
  elif ! curl -fsSL --max-time 60 https://IP.Check.Place -o "$IPQ_SH" 2>/dev/null || [ ! -s "$IPQ_SH" ]; then
    say "IPQuality 脚本拉取失败，跳过"
    add ipq_ok "false"; add ipq_note "$(str '脚本拉取失败')"
  else
    # -4 只测 IPv4；-n 跳过它自己的依赖安装（我们已经装好）；
    # -p 隐私模式，不生成在线报告（否则每台机器的完整 IP 会被上传生成分享页）
    # -l en 固定英文：值随语言变会让字符串匹配静默失效（见 1.1.1 变更说明）
    # -y 而非 -n：-n 跳过依赖检查，缺 jq 时会静默降级 Lite（见 1.1.2 变更说明）
    bash "$IPQ_SH" -4 -y -p -l en -o "$IPQ_OUT" >"$TMP/ipq.log" 2>&1
    if [ -s "$IPQ_OUT" ] && python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$IPQ_OUT" 2>/dev/null; then
      IPQ_FIELDS=$(python3 - "$IPQ_OUT" <<'IPQPY'
import json, sys, collections

d = json.load(open(sys.argv[1], encoding="utf-8"))
out = {}


def norm(v):
    return str(v).strip().lower() if v is not None else ""


# IPQuality 的值会跟着报告语言变（中文环境返回「原生IP」「机房」「解锁」）。
# 调用时已加 -l en，这里再做一层中英兼容兜底 —— 只认单一语言的代价是：
# 匹配不上不会报错，而是静默得出「全部未解锁」这种看起来正常的假结论。
YES = ("yes", "true", "unlocked", "解锁", "支持", "是")
NATIVE = ("native", "原生")
DC = ("data center", "datacenter", "hosting", "server", "机房", "数据中心")
RES = ("isp", "residential", "home", "line isp", "家宽", "住宅", "民宅")

# Lite 模式判定：ip.sh 在 db_maxmind 拿不到数据时置 mode_lite=1，
# 随后跳过 scamalytics/abuseipdb/ip2location/ipdata/ipqs 五个库，
# 风险评分与 IP 类型整节失效。这种半残数据用来打分只会得出错误结论，
# 直接判失败，不要它。
info = d.get("Info") or {}
_asn = str(info.get("ASN") or "").strip().lower()
if not _asn or _asn in ("null", "not assigned"):
    json.dump({"ipq_ok": False,
               "ipq_note": "IPQuality 降级为 Lite 模式（maxmind 数据源不可达，"
                           "风险评分与 IP 类型不可用），已丢弃"},
              sys.stdout, ensure_ascii=False)
    sys.exit(0)

t = norm(info.get("Type"))
out["ipq_type_raw"] = info.get("Type")
out["ipq_native"] = (("geo-consistent" in t) or ("原生" in t) or ("native" in t)) if t else None

usage = [v for v in ((d.get("Type") or {}).get("Usage") or {}).values()
         if v and norm(v) != "null"]
out["ipq_usage"] = collections.Counter(usage).most_common(1)[0][0] if usage else None
if usage:
    res = sum(1 for u in usage if any(k in norm(u) for k in RES))
    dc = sum(1 for u in usage if any(k in norm(u) for k in DC))
    out["ipq_residential_ratio"] = round(res / len(usage), 2)
    out["ipq_is_datacenter"] = dc > len(usage) / 2
else:
    out["ipq_residential_ratio"] = None
    out["ipq_is_datacenter"] = None


def pct(v):
    """各库口径不一，统一成 0-100（越大越差）。"""
    if v is None:
        return None
    s = str(v).strip()
    if not s or s.lower() == "null":
        return None
    try:
        return float(s[:-1]) if s.endswith("%") else float(s)
    except ValueError:
        return None


# 每家单独留一份。这台机器 Scamalytics 给 67、其余都是个位数 ——
# 只看 max 会判「高风险」，只看 avg 会判「低风险」，两个都不足以下结论，
# 必须看得见是哪一家在报警，才能判断该不该信。
scores = {k: pct(v) for k, v in (d.get("Score") or {}).items()}
detail = {k: v for k, v in scores.items() if v is not None}
vals = list(detail.values())
out["ipq_risk_detail"] = detail or None
out["ipq_risk_max"] = round(max(vals), 1) if vals else None
out["ipq_risk_avg"] = round(sum(vals) / len(vals), 1) if vals else None
out["ipq_risk_sources"] = len(vals)

factor = d.get("Factor") or {}
flag_n = flag_d = 0
for key in ("Proxy", "VPN", "Tor", "Abuser", "Robot"):
    for v in (factor.get(key) or {}).values():
        if v is None:
            continue
        flag_d += 1
        flag_n += 1 if v is True else 0
out["ipq_flags_hit"] = flag_n if flag_d else None
out["ipq_flags_total"] = flag_d or None
out["ipq_flag_ratio"] = round(flag_n / flag_d, 3) if flag_d else None

# 哪些库整列无数据。分母静默变小会让「没查到」看起来像「没问题」，
# 记下来才能判断这次检测的覆盖面够不够。
all_src, alive = set(), set()
for key in ("Proxy", "VPN", "Tor", "Abuser", "Robot", "Server"):
    for src, v in (factor.get(key) or {}).items():
        all_src.add(src)
        if v is not None:
            alive.add(src)
out["ipq_sources_total"] = len(all_src) or None
out["ipq_sources_dead"] = sorted(all_src - alive) or None

srv = [v for v in (factor.get("Server") or {}).values() if v is not None]
if out["ipq_is_datacenter"] is None and srv:
    out["ipq_is_datacenter"] = sum(1 for v in srv if v) > len(srv) / 2

# 解锁分原生与 DNS：DNS 解锁随时会被封，价值远低于原生
media = d.get("Media") or {}
unlocked = native = 0
mdetail = {}
for name, m in media.items():
    st = norm((m or {}).get("Status"))
    ok = any(k in st for k in YES)
    nat = ok and any(k in norm((m or {}).get("Type")) for k in NATIVE)
    unlocked += ok
    native += nat
    mdetail[name] = "native" if nat else ("dns" if ok else "no")
out["ipq_media_total"] = len(media) or None
out["ipq_media_unlocked"] = unlocked if media else None
out["ipq_media_native"] = native if media else None
out["ipq_media"] = mdetail or None

mail = d.get("Mail") or {}
# 25 端口出站被阻断则这台发不了邮件，建站与告警场景要用到
p25 = mail.get("Port25")
out["ipq_port25"] = bool(p25) if p25 is not None else None

bl = mail.get("DNSBlacklist") or {}
out["ipq_bl_total"] = bl.get("Total")
out["ipq_bl_marked"] = bl.get("Marked")
out["ipq_bl_listed"] = bl.get("Blacklisted")

out["ipq_ok"] = True
json.dump(out, sys.stdout, ensure_ascii=False)
IPQPY
)
      if [ -n "$IPQ_FIELDS" ] && printf '%s' "$IPQ_FIELDS" | grep -q '"ipq_ok": *false'; then
        J="${J}${J:+,}$(printf '%s' "$IPQ_FIELDS" | sed 's/^{//; s/}$//')"
        say "$(printf '%s' "$IPQ_FIELDS" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ipq_note",""))')"
      elif [ -n "$IPQ_FIELDS" ]; then
        # 解析结果是一个 JSON 对象，去掉外层大括号并入主 JSON
        J="${J}${J:+,}$(printf '%s' "$IPQ_FIELDS" | sed 's/^{//; s/}$//')"
        printf '%s' "$IPQ_FIELDS" | python3 -c '
import json,sys
d=json.load(sys.stdin)
p=lambda s: print("  "+s, file=sys.stderr)
p("%s / %s" % ("原生IP" if d.get("ipq_native") else "非原生",
               d.get("ipq_usage") or "?"))
rd=d.get("ipq_risk_detail") or {}
p("风险 max %s / avg %s  %s" % (d.get("ipq_risk_max"), d.get("ipq_risk_avg"),
  " ".join("%s=%g" % (k,v) for k,v in sorted(rd.items(), key=lambda x:-x[1]))))
p("风险标记 %s/%s 库次" % (d.get("ipq_flags_hit"), d.get("ipq_flags_total")))
dead=d.get("ipq_sources_dead")
if dead: p("⚠ 无数据的库: %s（分母已相应缩小）" % ", ".join(dead))
m=d.get("ipq_media") or {}
p("流媒体 原生 %s / 解锁 %s / 共 %s  未解锁: %s" % (
  d.get("ipq_media_native"), d.get("ipq_media_unlocked"), d.get("ipq_media_total"),
  ", ".join(k for k,v in m.items() if v=="no") or "无"))
p("黑名单 %s 库中命中 %s（标记 %s） | 25 端口出站 %s" % (
  d.get("ipq_bl_total"), d.get("ipq_bl_listed"), d.get("ipq_bl_marked"),
  "通" if d.get("ipq_port25") else "阻断"))'
      else
        say "解析失败"; add ipq_ok "false"; add ipq_note "$(str '解析失败')"
      fi
    else
      # 记 IPQuality 自己说了什么，不要由这里编一个原因 ——
      # 编出来的原因会把排查方向直接带偏
      IPQ_ERR=$(tail -3 "$TMP/ipq.log" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-200)
      say "IPQuality 未产出有效 JSON: ${IPQ_ERR:-（无输出）}"
      add ipq_ok "false"; add ipq_note "$(str "无有效输出: ${IPQ_ERR:-无}")"
    fi
  fi
  rm -f "$IPQ_SH"
else
  add ipq_ok "$(nul)"
  add ipq_note "$(str '未启用，加 --ipq 开启')"
fi

# 「是否被墙」在本机测不出来 —— 需要国内探测点，属客户端探针的范畴
MISSING_TOOLS=$(echo $MISSING_TOOLS)
if [ -n "$MISSING_TOOLS" ]; then
  say "⚠ 缺少工具: $MISSING_TOOLS —— 相关指标为 null，打分时会剔除"
fi
add missing_tools "$(str "$MISSING_TOOLS")"
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
# 自校验：产出不可解析的 JSON 是这个脚本最糟的失败方式 —— 下游 score.sh 拿到
# 一堆坏文件，而人只会看到「完成」。宁可这里就红着脸报错。
if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON" 2>/tmp/.vpsjson.err; then
    echo "[致命] 生成的 JSON 不合法，文件保留供排查: $JSON" >&2
    sed 's/^/       /' /tmp/.vpsjson.err >&2
    rm -f /tmp/.vpsjson.err
    exit 1
  fi
  rm -f /tmp/.vpsjson.err
fi
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
