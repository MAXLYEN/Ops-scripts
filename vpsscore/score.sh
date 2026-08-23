#!/usr/bin/env bash
# vpsscore/score.sh — 对 probe.sh 采集的 JSON 打分与横向对比
# VERSION: 1.3.0
# 1.3.0: IP 榜新增「归属地一致性」并调整权重。实测一台 IPQuality 判「原生IP」、
#        本表给 92.6 分排 HK 第二的机器，实际用起来很差 —— 七个库对它的归属国
#        给出 HK/SG/CN/US 四种判定，各服务把它判到不同区域，行为不可预测。
#        原生/广播只是单一数据源的一家之言（该机 ping0 与 iplark 均判广播），
#        而多库地区分歧是可交叉验证的硬信号，故 ip_native 权重 25 → 15，
#        新增 ip_geo 20。
#        同时在 IP 榜下方标明：这是初筛，不是结论 —— 实际可用性仍以使用体感为准。
# 1.2.1: 跟进 probe.sh 1.1.3 的字段改名 tcp53_ms → tcp_ms，并兼容旧数据。
#        交叉验证的端口从 53 改成 80/443（53 实测全部不通，见 probe 变更说明）。
# 1.2.0: 角色重构为 line / ip / web，并按地区分组对比。
#        · relay 与 land 合并成 line —— 两者的权重差别只在延迟，
#          分成两个榜看到的是同一批机器换个顺序，没有新增判断力。
#        · 新增 ip 榜，用 probe.sh --ipq 采到的深度数据：原生/广播、
#          原生解锁比例、风险评分、黑名单命中。原来 IP 质量只有
#          dnsbl_hits 一个指标，测不出真正决定「IP 好不好」的东西。
#        · web 榜只收 4C4G 以上的机器 —— 低配机在建站榜垫底是必然的，
#          把它们列进去只是让榜单变长，掩盖真正该比较的那几台。
#        · 同地区才放一起比：国内直连 400ms 对美西机正常、对香港机是灾难，
#          混在一张榜上比延迟得出的顺序没有意义。
#        风险评分取中位数而非最大值：实测有机器 Scamalytics 单独报 67 而
#        其余五家都是个位数，取最大值会让一家库的口径主导整个排名。
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
    "line": ("线路质量", {
        "bw": 30, "loss": 30, "rtt": 20, "steal": 10, "virt": 5, "cpu": 5}),
    "ip": ("IP 质量", {
        "ip_media": 25, "ip_geo": 20, "ip_risk": 20, "ip_native": 15,
        "ip_blacklist": 12, "ip_flags": 5, "ip_residential": 3}),
    "web": ("建站（4C4G+）", {
        "cpu": 20, "mem": 15, "disk_4k": 20, "disk_seq": 15,
        "bw": 10, "loss": 10, "steal": 5, "virt": 5}),
}

# web 榜的准入门槛。低配机在建站榜垫底是必然的，列进去只会让榜变长，
# 把真正该比较的那几台淹没掉。
WEB_MIN_CORES = 4
WEB_MIN_MEM_MB = 3500          # 门槛按标称 4G；实际可用常在 3.7-3.9G，故取 3500
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
            # 1.1.3 起字段名是 tcp_ms；旧数据里叫 tcp53_ms，一并兼容
            tcp = v.get("tcp_ms")
            if tcp is None:
                tcp = v.get("tcp53_ms")
            if tcp is not None:
                rtts.append(float(tcp))
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
    m.update(ip_metrics(d))
    return m


def median(vals):
    v = sorted(vals)
    n = len(v)
    if not n:
        return None
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def ip_metrics(d):
    """IP 质量各项。数据来自 probe.sh --ipq；没跑过就整组缺失。"""
    m = {}
    ok = d.get("ipq_ok")
    if not ok:
        # 没有 --ipq 数据时全部留空，由归一化剔除 ——
        # 不能拿 dnsbl_hits 凑数，那是完全不同量级的指标
        for k in ("ip_native", "ip_media", "ip_risk", "ip_geo",
                  "ip_blacklist", "ip_flags", "ip_residential"):
            m[k] = (None, 1.0)
        return m

    nat = d.get("ipq_native")
    m["ip_native"] = (None if nat is None else (100.0 if nat else 35.0), 1.0)

    # 归属地一致性：各库判定越分散，服务把它判到哪个区域就越不可预测。
    # 全一致 100 分，一半一致约 33 分 —— 曲线做得陡，因为分歧本身
    # 就意味着「有的服务能用有的不能用」，而不是线性变差。
    gc = d.get("ipq_geo_consensus")
    if gc is None:
        m["ip_geo"] = (None, 1.0)
    else:
        src = d.get("ipq_geo_sources") or 0
        m["ip_geo"] = (band(float(gc), [(0.3, 0), (0.5, 25), (0.7, 55), (0.85, 80), (1.0, 100)]),
                       1.0 if src >= 5 else 0.7)

    tot = d.get("ipq_media_total") or 0
    if tot:
        # 原生解锁才算数，DNS 解锁随时会被封，折半计
        native = d.get("ipq_media_native") or 0
        dns = (d.get("ipq_media_unlocked") or 0) - native
        m["ip_media"] = (clamp(100.0 * (native + 0.5 * dns) / tot), 1.0)
    else:
        m["ip_media"] = (None, 1.0)

    # 中位数而非最大值：单一库的离群值不该主导排名（见 1.2.0 变更说明）
    rd = d.get("ipq_risk_detail") or {}
    vals = [float(v) for v in rd.values() if v is not None]
    if vals:
        med = median(vals)
        m["ip_risk"] = (band(med, [(0, 100), (5, 85), (15, 60), (30, 35), (60, 10), (100, 0)]),
                        1.0 if len(vals) >= 3 else 0.7)
    else:
        m["ip_risk"] = (None, 1.0)

    listed = d.get("ipq_bl_listed")
    marked = d.get("ipq_bl_marked")
    if listed is None:
        m["ip_blacklist"] = (None, 1.0)
    else:
        # 命中（Blacklisted）比被标记（Marked）严重得多，权重差一个量级
        v = 100.0 - 20.0 * float(listed) - 1.0 * float(marked or 0)
        m["ip_blacklist"] = (clamp(v), 1.0)

    fr = d.get("ipq_flag_ratio")
    m["ip_flags"] = (None if fr is None else clamp(100.0 - 300.0 * float(fr)), 1.0)

    rr = d.get("ipq_residential_ratio")
    m["ip_residential"] = (None if rr is None else clamp(40.0 + 60.0 * float(rr)), 1.0)
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
         "steal": "steal", "virt": "虚拟化",
         "ip_native": "原生IP", "ip_media": "流媒体", "ip_risk": "风险评分",
         "ip_geo": "归属地一致性",
         "ip_blacklist": "黑名单", "ip_flags": "风险标记", "ip_residential": "住宅属性"}

# 组内少于这个数量时，「第几名」没有参考价值，只报绝对分
MIN_GROUP = 3


def region_of(d):
    """分组用的地区。以 CDN 实测落地优先，IP 库次之 ——
    实测的是流量实际走到哪，IP 库是登记信息，两者冲突时前者更可信。"""
    loc = (d.get("cdn_loc") or "").strip()
    if loc:
        return loc
    c = (d.get("geo_country") or "").strip()
    return c or "未知"


def web_eligible(d):
    cores = d.get("cpu_cores")
    mem = d.get("mem_mb")
    if cores is None or mem is None:
        return None            # 数据不全，不判定
    return cores >= WEB_MIN_CORES and mem >= WEB_MIN_MEM_MB

result = {}
skipped_web = []
for rk, (rname, w) in roles.items():
    rows = []
    for k, (p, d) in hosts.items():
        if rk == "web":
            elig = web_eligible(d)
            if elig is False:
                skipped_web.append((display_name(d, p), d.get("cpu_cores"), d.get("mem_mb")))
                continue
        s, cov, miss = score_role(d, w)
        rows.append({"host": display_name(d, p), "hostname": d.get("host"),
                     "region": region_of(d),
                     "cores": d.get("cpu_cores"), "mem_mb": d.get("mem_mb"),
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

def fmt_row(rank, r):
    miss = "、".join(LABEL.get(k, k) for k in r["missing"]) or "无"
    if r["score"] is None:
        return f"  {rank:>3} {r['host']:<16}{'—':>7}{'0%':>8}   全部缺失"
    if r["coverage"] < MIN_COVERAGE:
        return f"  {rank:>3} {r['host']:<16}{'数据不足':>6}{r['coverage']*100:>7.0f}%   {miss}"
    return f"  {rank:>3} {r['host']:<16}{r['score']:>6.1f}{r['coverage']*100:>7.0f}%   {miss}"


def warn_coverage(rows, indent="  "):
    thin = [r for r in rows
            if r["score"] is not None and MIN_COVERAGE <= r["coverage"] < 0.8]
    none_ = [r for r in rows
             if r["score"] is not None and r["coverage"] < MIN_COVERAGE]
    if thin:
        print(f"{indent}⚠ {'、'.join(r['host'] for r in thin)} 覆盖率偏低，"
              f"该分数只代表已测到的部分，与其它机器不完全可比")
    if none_:
        print(f"{indent}⚠ {'、'.join(r['host'] for r in none_)} 覆盖率不足 "
              f"{MIN_COVERAGE*100:.0f}%，不给分 —— 补测缺失项后再比")


for rk, blk in result.items():
    rows = blk["rows"]
    print(f"\n▸ {blk['role_name']}（{rk}）")
    if not rows:
        print("  没有符合条件的机器")
        continue

    # 按地区分组：国内直连 400ms 对美西机正常、对香港机是灾难，
    # 混在一张榜上比出的顺序没有意义
    groups = {}
    for r in rows:
        groups.setdefault(r["region"], []).append(r)

    big = {g: v for g, v in groups.items() if len(v) >= MIN_GROUP}
    small = [r for g, v in groups.items() if len(v) < MIN_GROUP for r in v]

    for g in sorted(big, key=lambda x: -len(big[x])):
        print(f"\n  ── {g}（{len(big[g])} 台）")
        print(f"  {'IP':<20}{'绝对分':>7}{'覆盖率':>8}   缺失项")
        for i, r in enumerate(big[g], 1):
            print(fmt_row(f"{i}.", r))
        warn_coverage(big[g], "  ")

    if small:
        # 同地区不足 MIN_GROUP 台时排名无参考价值，只报绝对分
        print(f"\n  ── 其它地区（各地不足 {MIN_GROUP} 台，仅列绝对分，不排名）")
        print(f"  {'IP':<20}{'绝对分':>7}{'覆盖率':>8}   地区")
        for r in sorted(small, key=lambda x: (x["score"] is None, -(x["score"] or 0))):
            sc = "—" if r["score"] is None else (
                "数据不足" if r["coverage"] < MIN_COVERAGE else f"{r['score']:.1f}")
            print(f"      {r['host']:<16}{sc:>7}{r['coverage']*100:>7.0f}%   {r['region']}")
        warn_coverage(small, "  ")

    if rk == "web" and skipped_web:
        uniq = {h: (c, m) for h, c, m in skipped_web}
        # 门槛写标称值（4G），不要用 MIN_MEM_MB//1024 —— 3500 会算成 3G，
        # 让人以为门槛比实际低
        print(f"\n  未列入（低于 {WEB_MIN_CORES}C4G）：{len(uniq)} 台")
        shown = sorted(uniq.items(),
                       key=lambda x: (-(x[1][0] or 0), -(x[1][1] or 0)))[:8]
        print("  " + "、".join(f"{h}({c}C/{(m or 0) / 1024:.1f}G)" for h, (c, m) in shown)
              + ("…" if len(uniq) > 8 else ""))

if not ROLE or ROLE == "ip":
    print("\n  ⓘ IP 榜是初筛，不是结论。它反映的是各风险库怎么看这个 IP，")
    print("    而实际可用性还取决于你的具体用途和使用体感 —— 后者更准。")
    print("    分数接近时（相差 10 分以内），以实际使用表现为准。")

print("\n  绝对分：0-100，按角色权重加权，缺失项剔除后归一化")
print("  覆盖率：参与计分的权重占该角色总权重的比例")
if n > 1:
    print("  同批排名见各角色下的序号")
print()
PY
