#!/usr/bin/env bash
# vpsscore/score.sh — 对 probe.sh 采集的 JSON 打分与横向对比
# VERSION: 1.1.0
# 1.1.0: 榜单显示 IP 而非主机名 —— 商家给的 hostname（C202603031886344 之类）
#        认不出是哪台机器，而排名的用处正是「决定哪台留哪台退」。
#        IP 取自探针已采集的 ipv4 字段，不用重新采集。
#        同一主机多份采集的去重键也改用 IP：重装系统会换 hostname，
#        按 hostname 去重会把同一台机器算成两台。
#

# 读一批 probe.sh 产出的 JSON，按角色权重给出绝对分（0-100）和同批相对排名。
#
# 两条贯穿全脚本的原则：
#   · 「没测出来」不等于「差」。缺失项从加权中剔除并把权重归一化，
#     同时把覆盖率标出来 —— 一台只测到硬件的机器不该因为没测网络就得低分，
#     但你必须看得见它的分只代表了 40% 的指标。
#     覆盖率低于 50% 时干脆不给数字：一个「覆盖率 20% / 95.2 分」被截图之后，
#     旁边那行警告不会跟着走，而 95.2 看起来就是 95.2。
#   · confidence 分级参与判断：failed/none/skipped 视为缺失，low 打七折权重。
#     探针已经如实标注了每项的可信度，打分器不能在最后一步把它丢掉。
#
# 刻意不依赖 lib/common.sh 与 env.conf：常在本地或跳板机上跑，不一定装了全套。
#
# 用法:
#   score.sh <目录>              对目录下所有 *.json 打分（每主机取最新一份）
#   score.sh <a.json> <b.json>…  指定文件
#   score.sh -r relay <目录>     只看某个角色
#   score.sh -j <目录>           输出 JSON，便于接别的工具
#   score.sh -h
#
# 角色: relay=中转/代理  web=建站  land=落地机（直连质量优先）

set -o pipefail

usage() {
  cat <<'USAGE'
score.sh — VPS 质量打分与横向对比

  score.sh <目录>                对目录下所有 *.json 打分
  score.sh <a.json> <b.json>…    指定文件
  score.sh -r <角色> <路径…>     只输出某个角色的排名
  score.sh -j <路径…>            输出 JSON
  score.sh -h

角色:
  relay  中转/代理节点   看重带宽、丢包、steal
  web    建站            看重 CPU、磁盘 4K、内存
  land   落地机          看重直连延迟与丢包

同一主机有多份采集时取 probed_at 最新的一份。
缺失指标不计入加权（权重归一化），覆盖率单独列出。
USAGE
}

ROLE=""; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -r|--role) ROLE="$2"; shift 2 ;;
    -j|--json) AS_JSON=1; shift ;;
    --) shift; break ;;
    -*) echo "未知参数: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] || { usage; echo; echo "[致命] 没有指定输入" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[致命] 需要 python3" >&2; exit 1; }

FILES=""
for a in "$@"; do
  if [ -d "$a" ]; then
    for f in "$a"/*.json; do
      [ -e "$f" ] || continue
      case "$(basename "$f")" in latest.json) continue ;; esac
      FILES="$FILES $f"
    done
  elif [ -f "$a" ]; then
    FILES="$FILES $a"
  else
    echo "[警告] 跳过不存在的路径: $a" >&2
  fi
done
[ -n "$FILES" ] || { echo "[致命] 没有找到任何 JSON" >&2; exit 1; }

ROLE="$ROLE" AS_JSON="$AS_JSON" python3 - $FILES <<'PY'
import json, os, signal, sys

# 输出常被 `| head` / `| less` 截断，默认的 SIGPIPE 处理会抛
# BrokenPipeError 堆栈，看着像脚本崩了。恢复成默认行为：安静退出。
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

ROLE = os.environ.get("ROLE") or ""
AS_JSON = os.environ.get("AS_JSON") == "1"

ROLES = {
    "relay": ("中转/代理", {
        "bw": 30, "loss": 25, "rtt": 10, "cpu": 5, "disk_seq": 5,
        "disk_4k": 0, "mem": 5, "steal": 10, "virt": 5, "ipq": 5}),
    "web": ("建站", {
        "bw": 10, "loss": 10, "rtt": 5, "cpu": 20, "disk_seq": 15,
        "disk_4k": 15, "mem": 15, "steal": 5, "virt": 5, "ipq": 0}),
    "land": ("落地机", {
        "bw": 20, "loss": 25, "rtt": 25, "cpu": 5, "disk_seq": 5,
        "disk_4k": 0, "mem": 5, "steal": 5, "virt": 5, "ipq": 5}),
}
if ROLE and ROLE not in ROLES:
    sys.exit(f"[致命] 未知角色: {ROLE}（可选: {', '.join(ROLES)}）")

# confidence -> 权重系数。failed/none/skipped 当缺失处理，不是当 0 分。
CONF = {"high": 1.0, "medium": 1.0, "low": 0.7,
        "failed": None, "none": None, "skipped": None}

# 覆盖率低于此值不输出分数 —— 见文件头第二条原则
MIN_COVERAGE = 0.5


def conf_factor(d, key):
    c = d.get(key)
    if c is None:
        return 1.0
    return CONF.get(c, 1.0)


def clamp(v, lo=0.0, hi=100.0):
    return max(lo, min(hi, v))


def band(v, points):
    """分段线性映射到 0-100。points 为 [(输入, 得分)…]，输入需递增。"""
    if v is None:
        return None
    lo_x, lo_y = points[0]
    if v <= lo_x:
        return float(lo_y)
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        if v <= x2:
            if x2 == x1:
                return float(y2)
            return float(y1 + (y2 - y1) * (v - x1) / (x2 - x1))
    return float(points[-1][1])


def ping_stats(d):
    """三网 ping 汇总。icmp_filtered 的目标不计入丢包 —— ICMP 被过滤
    不是线路不通，把它算成 100% 丢包会得出完全相反的结论。"""
    losses, rtts = [], []
    for v in (d.get("ping") or {}).values():
        if v.get("icmp_filtered"):
            # TCP 通就用 TCP 时延顶替，丢包这项对该目标弃权
            if v.get("tcp53_ms") is not None:
                rtts.append(float(v["tcp53_ms"]))
            continue
        if v.get("loss_pct") is not None:
            losses.append(float(v["loss_pct"]))
        if v.get("rtt_ms") is not None:
            rtts.append(float(v["rtt_ms"]))
    return (sum(losses) / len(losses) if losses else None,
            sum(rtts) / len(rtts) if rtts else None)


def metrics(d):
    """每项返回 (得分 0-100, 权重系数)；得分 None = 该项缺失。"""
    m = {}
    avg_loss, avg_rtt = ping_stats(d)

    # 带宽：50Mbps 起步，1Gbps 满分
    m["bw"] = (band(d.get("down_mbps"), [(0, 0), (50, 40), (200, 70), (500, 88), (1000, 100)]),
               conf_factor(d, "bandwidth_confidence"))
    # 丢包：0% 满分，1% 已明显，5% 及格线以下，10%+ 基本不可用
    m["loss"] = (band(avg_loss, [(0, 100), (1, 85), (3, 65), (5, 45), (10, 15), (20, 0)]),
                 conf_factor(d, "ping_confidence"))
    # 延迟：国内直连视角，50ms 内极好，200ms 可用，400ms+ 勉强
    m["rtt"] = (band(avg_rtt, [(30, 100), (80, 85), (150, 70), (250, 45), (400, 20), (600, 0)]),
                conf_factor(d, "ping_confidence"))
    m["cpu"] = (band(d.get("cpu_sha256_mbs"), [(0, 0), (200, 40), (400, 65), (800, 85), (1500, 100)]),
                conf_factor(d, "cpu_bench_confidence"))
    m["disk_seq"] = (band(d.get("disk_seq_write_mbs"), [(0, 0), (100, 45), (300, 70), (600, 88), (1200, 100)]),
                     conf_factor(d, "disk_confidence"))
    m["disk_4k"] = (band(d.get("disk_4k_read_iops"), [(0, 0), (2000, 40), (10000, 70), (40000, 90), (100000, 100)]),
                    conf_factor(d, "disk_confidence"))
    mem = d.get("mem_mb")
    m["mem"] = (band(mem, [(512, 20), (1024, 45), (2048, 65), (4096, 85), (8192, 100)]), 1.0)
    # steal：>2% 就说明宿主机超售
    m["steal"] = (band(d.get("steal_pct"), [(0, 100), (1, 85), (2, 65), (5, 35), (10, 0)]),
                  conf_factor(d, "steal_confidence"))
    vc = d.get("virt_class")
    m["virt"] = ({"bare-metal": 100, "full": 90, "container": 55}.get(vc), 1.0)
    hits = d.get("dnsbl_hits")
    m["ipq"] = (None if hits is None else clamp(100 - 25 * float(hits)),
                conf_factor(d, "dnsbl_confidence"))
    return m


def score_role(d, weights):
    m = metrics(d)
    total_w = used_w = acc = 0.0
    missing = []
    for k, w in weights.items():
        if w == 0:
            continue
        total_w += w
        val, cf = m.get(k, (None, 1.0))
        if val is None or cf is None:
            missing.append(k)
            continue
        ew = w * cf
        used_w += ew
        acc += val * ew
    if used_w == 0:
        return None, 0.0, missing
    # 归一化：缺失项不拉低分数，但覆盖率会如实反映出来
    return acc / used_w, total_w and (used_w / total_w) or 0.0, missing


def display_name(d, path):
    """榜单上怎么称呼这台机器。

    优先 IP：商家给的 hostname 认不出是谁，而这份排名的用处正是
    「决定哪台留、哪台退」—— 认不出来就没法决定。
    """
    ip = (d.get("ipv4") or "").strip()
    if ip:
        return ip
    h = (d.get("host") or "").strip()
    return h or os.path.basename(path)


def dedup_key(d, path):
    # 用 IP 而非 hostname 去重：重装系统会换 hostname，
    # 按 hostname 会把同一台机器算成两台，排名里出现两条
    ip = (d.get("ipv4") or "").strip()
    return ip or (d.get("host") or "").strip() or os.path.basename(path)


def newest_per_host(paths):
    best = {}
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception as e:
            print(f"[警告] 跳过无法解析的文件 {p}: {e}", file=sys.stderr)
            continue
        k = dedup_key(d, p)
        if k not in best or (d.get("probed_at") or "") > (best[k][1].get("probed_at") or ""):
            best[k] = (p, d)
    return best


hosts = newest_per_host(sys.argv[1:])
if not hosts:
    sys.exit("[致命] 没有可用的 JSON（全部解析失败？）")

roles = {ROLE: ROLES[ROLE]} if ROLE else ROLES
LABEL = {"bw": "带宽", "loss": "丢包", "rtt": "延迟", "cpu": "CPU",
         "disk_seq": "磁盘顺序", "disk_4k": "磁盘4K", "mem": "内存",
         "steal": "steal", "virt": "虚拟化", "ipq": "IP质量"}

result = {}
for rk, (rname, w) in roles.items():
    rows = []
    for k, (p, d) in hosts.items():
        s, cov, miss = score_role(d, w)
        rows.append({"host": display_name(d, p), "hostname": d.get("host"),
                     "score": s, "coverage": cov,
                     "missing": miss, "file": p, "probed_at": d.get("probed_at")})
    # 低覆盖率的排到后面：它们的高分是「没测到的都不算」换来的，
    # 让它们占榜首会误导
    rows.sort(key=lambda r: (r["score"] is None,
                             r["coverage"] < MIN_COVERAGE,
                             -(r["score"] or 0)))
    result[rk] = {"role_name": rname, "rows": rows}

if AS_JSON:
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0)

n = len(hosts)
print(f"\n════ VPS 评分 · {n} 台 ════")
if n == 1:
    print("  只有一台机器，相对排名无意义；下面是绝对分。")
    print("  横向对比需要在多台机器上都跑 probe.sh 后把 JSON 收到一处。")

for rk, blk in result.items():
    print(f"\n▸ {blk['role_name']}（{rk}）")
    print(f"  {'IP':<20}{'绝对分':>7}{'覆盖率':>8}   缺失项")
    for i, r in enumerate(blk["rows"], 1):
        miss = "、".join(LABEL.get(k, k) for k in r["missing"]) or "无"
        rank = f"{i}." if n > 1 else " "
        if r["score"] is None:
            print(f"  {rank:>3} {r['host']:<16}{'—':>7}{'0%':>8}   全部缺失")
        elif r["coverage"] < MIN_COVERAGE:
            print(f"  {rank:>3} {r['host']:<16}{'数据不足':>6}{r['coverage']*100:>7.0f}%   {miss}")
        else:
            print(f"  {rank:>3} {r['host']:<16}{r['score']:>6.1f}{r['coverage']*100:>7.0f}%   {miss}")
    # 覆盖率不足时，分数的可比性本身就存疑，必须说出来
    thin = [r for r in blk["rows"]
            if r["score"] is not None and MIN_COVERAGE <= r["coverage"] < 0.8]
    none_ = [r for r in blk["rows"]
             if r["score"] is not None and r["coverage"] < MIN_COVERAGE]
    if thin:
        print(f"  ⚠ {'、'.join(r['host'] for r in thin)} 覆盖率偏低，"
              f"该分数只代表已测到的部分，与其它机器不完全可比")
    if none_:
        print(f"  ⚠ {'、'.join(r['host'] for r in none_)} 覆盖率不足 "
              f"{MIN_COVERAGE*100:.0f}%，不给分 —— 补测缺失项后再比")

print("\n  绝对分：0-100，按角色权重加权，缺失项剔除后归一化")
print("  覆盖率：参与计分的权重占该角色总权重的比例")
if n > 1:
    print("  同批排名见各角色下的序号")
print()
PY
