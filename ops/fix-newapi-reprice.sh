#!/usr/bin/env bash
# ops/fix-newapi-reprice.sh — 按后台当前价格重算 new-api 指定模型的历史消费（logs + users + tokens）
# VERSION: 1.0.0
# 1.0.0: 首版。价格从库里的 billing_setting（表达式计费）/ ModelPrice / ModelRatio 读，不写死；
#        先用每条表达式计费日志自带的表达式重算并与实际扣费比对，对不上就拒绝执行；
#        顺带重算仍按兜底倍率 37.5 计费的记录；可选把令牌已用额度对齐到日志。
#
# 用法: fix-newapi-reprice.sh <库文件> <模型1,模型2,...> [--apply] [--align-tokens] [--map 旧名=参考名,...]
#   不带 --apply 只预演、不写库。
#   --align-tokens  令牌的 used_quota 改成它名下日志的合计，remain_quota 同步调整（日志清理过的库不要用）。
#   --map           兜底记录的模型在后台没有价格时，按哪个模型的价格算。
# 用户额度：只调整「已用额度原本等于其日志合计」的用户；对不上的（如只有渠道测试记录的管理员）原样保留并列出。
# quota_data 不在这里改，改完后跑 fix-newapi-quota-data.sh。

set -o pipefail

DB="${1:-}"; MODELS="${2:-}"
[ -n "$DB" ] && [ -f "$DB" ] && [ -n "$MODELS" ] || {
  echo "用法: $0 <库文件> <模型1,模型2,...> [--apply] [--align-tokens] [--map 旧名=参考名,...]"; exit 1; }
shift 2
APPLY=0 ALIGN=0 MAPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --align-tokens) ALIGN=1 ;;
    --map) MAPS="${2:-}"; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

PY=""
for p in python3 /www/server/panel/pyenv/bin/python3; do
  command -v "$p" >/dev/null 2>&1 && { PY=$p; break; }
done
[ -n "$PY" ] || { echo "缺少 python3（也没找到宝塔自带的 /www/server/panel/pyenv/bin/python3）"; exit 1; }

exec "$PY" - "$DB" "$MODELS" "$APPLY" "$ALIGN" "$MAPS" <<'PY'
import base64, datetime, json, math, re, sqlite3, sys
from collections import defaultdict

DB, MODELS, APPLY, ALIGN, MAPS = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1", sys.argv[5]
TARGETS = [m.strip() for m in MODELS.split(",") if m.strip()]
MAP = dict(kv.split("=", 1) for kv in MAPS.split(",") if "=" in kv)
VERSION = "fix-newapi-reprice 1.0.0"
FALLBACK_RATIO = 37.5
SELF_CHECK_MAX_MISS = 0.02   # 目标模型自检不一致超过 2% 就拒绝

class Unsupported(Exception):
    pass

# ---------- new-api 计费表达式（billingexpr v1）的子集 ----------
TOK = re.compile(r'\s*(?:(?P<num>\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)|(?P<str>"(?:[^"\\]|\\.)*")'
                 r'|(?P<id>[A-Za-z_][A-Za-z0-9_]*)|(?P<op>&&|\|\||>=|<=|==|!=|[-+*/?:(),<>!]))')
VARS = {"p", "c", "cr", "cc"}          # 日志里拿得到的维度；用到图片、音频等维度的表达式不支持
FUNCS = {"tier", "hour", "max", "min"}

def tokenize(s):
    out, i = [], 0
    while i < len(s):
        m = TOK.match(s, i)
        if not m or m.end() == i:
            if s[i:].strip() == "":
                break
            raise Unsupported("无法解析: %r" % s[i:i + 20])
        i = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out

class Parser:
    def __init__(self, s):
        self.t, self.i, self.used = tokenize(s), 0, set()
    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)
    def take(self, val=None):
        k, v = self.peek()
        if k is None or (val is not None and v != val):
            raise Unsupported("期望 %s，实际 %s" % (val, v))
        self.i += 1
        return k, v
    def parse(self):
        node = self.ternary()
        if self.i != len(self.t):
            raise Unsupported("多余内容: %s" % (self.peek(),))
        return node
    def ternary(self):
        cond = self.orx()
        if self.peek()[1] == "?":
            self.take("?"); a = self.ternary(); self.take(":"); b = self.ternary()
            return ("?", cond, a, b)
        return cond
    def orx(self):
        n = self.andx()
        while self.peek()[1] == "||":
            self.take(); n = ("||", n, self.andx())
        return n
    def andx(self):
        n = self.cmp()
        while self.peek()[1] == "&&":
            self.take(); n = ("&&", n, self.cmp())
        return n
    def cmp(self):
        n = self.add()
        if self.peek()[1] in (">=", "<=", ">", "<", "==", "!="):
            op = self.take()[1]; n = (op, n, self.add())
        return n
    def add(self):
        n = self.mul()
        while self.peek()[1] in ("+", "-"):
            op = self.take()[1]; n = (op, n, self.mul())
        return n
    def mul(self):
        n = self.unary()
        while self.peek()[1] in ("*", "/"):
            op = self.take()[1]; n = (op, n, self.unary())
        return n
    def unary(self):
        if self.peek()[1] == "-":
            self.take(); return ("neg", self.unary())
        if self.peek()[1] == "!":
            self.take(); return ("not", self.unary())
        return self.primary()
    def primary(self):
        k, v = self.take()
        if k == "num":
            return ("num", float(v))
        if k == "str":
            return ("str", json.loads(v))
        if k == "op" and v == "(":
            n = self.ternary(); self.take(")"); return n
        if k == "id":
            if self.peek()[1] == "(":
                if v not in FUNCS:
                    raise Unsupported("不支持的函数 %s()" % v)
                self.take("(")
                args = []
                if self.peek()[1] != ")":
                    args.append(self.ternary())
                    while self.peek()[1] == ",":
                        self.take(); args.append(self.ternary())
                self.take(")")
                return ("call", v, args)
            if v in ("true", "false"):
                return ("num", 1.0 if v == "true" else 0.0)
            if v not in VARS:
                raise Unsupported("不支持的变量 %s" % v)
            self.used.add(v)
            return ("var", v)
        raise Unsupported("意外的记号 %s" % v)

TZ_FIXED = {"Asia/Shanghai": 8, "Asia/Hong_Kong": 8, "Asia/Taipei": 8, "Asia/Tokyo": 9, "UTC": 0, "Etc/UTC": 0}
def hour_in(tz, ts):
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.fromtimestamp(ts, ZoneInfo(tz)).hour
    except Exception:
        if tz in TZ_FIXED:
            return datetime.datetime.fromtimestamp(ts + TZ_FIXED[tz] * 3600, datetime.timezone.utc).hour
        raise Unsupported("无法换算时区 %s" % tz)

def ev(n, env):
    op = n[0]
    if op == "num": return n[1]
    if op == "str": return n[1]
    if op == "var": return env[n[1]]
    if op == "neg": return -ev(n[1], env)
    if op == "not": return 0.0 if ev(n[1], env) else 1.0
    if op == "?": return ev(n[2], env) if ev(n[1], env) else ev(n[3], env)
    if op == "&&": return 1.0 if (ev(n[1], env) and ev(n[2], env)) else 0.0
    if op == "||": return 1.0 if (ev(n[1], env) or ev(n[2], env)) else 0.0
    if op == "call":
        f, args = n[1], n[2]
        if f == "tier":
            if len(args) != 2: raise Unsupported("tier() 需要 2 个参数")
            env["_tier"] = ev(args[0], env)
            return ev(args[1], env)
        if f == "hour":
            return float(hour_in(ev(args[0], env), env["_ts"]))
        vals = [ev(a, env) for a in args]
        return max(vals) if f == "max" else min(vals)
    a, b = ev(n[1], env), ev(n[2], env)
    return {"+": lambda: a + b, "-": lambda: a - b, "*": lambda: a * b, "/": lambda: a / b,
            ">=": lambda: float(a >= b), "<=": lambda: float(a <= b), ">": lambda: float(a > b),
            "<": lambda: float(a < b), "==": lambda: float(a == b), "!=": lambda: float(a != b)}[op]()

def qround(x):   # new-api common.QuotaRound：四舍五入，远离零
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))

def group_ratio(o):
    u = o.get("user_group_ratio")
    if isinstance(u, (int, float)) and u >= 0:
        return float(u)
    g = o.get("group_ratio")
    return float(g) if isinstance(g, (int, float)) else 1.0

class ExprPricer:
    kind = "expr"
    def __init__(self, s):
        p = Parser(s)
        self.ast, self.used, self.expr = p.parse(), p.used, s
    def quota(self, pt, ct, o, ts, qpu):
        cr = float(o.get("cache_tokens") or 0)
        cc = float(o.get("cache_creation_tokens") or 0)
        p = float(pt or 0)
        if "cr" in self.used: p -= cr
        if "cc" in self.used: p -= cc
        env = {"p": max(p, 0.0), "c": max(float(ct or 0), 0.0), "cr": cr, "cc": cc, "_ts": ts, "_tier": ""}
        cost = ev(self.ast, env)
        return qround(cost / 1e6 * qpu * group_ratio(o)), str(env["_tier"])

class RatioPricer:
    kind = "ratio"
    def __init__(self, mr, comp, cache, create=None):
        self.mr, self.comp, self.cache, self.create = mr, comp, cache, create
    def quota(self, pt, ct, o, ts, qpu):
        cr = float(o.get("cache_tokens") or 0)
        cc = float(o.get("cache_creation_tokens") or 0)
        if cc and self.create is None:
            raise Unsupported("有缓存写入 token 但没有缓存写入倍率")
        base = (float(pt or 0) - cr - cc) + cr * self.cache + cc * (self.create or 0) + float(ct or 0) * self.comp
        return qround(base * self.mr * group_ratio(o) * qpu / 500000.0), ""

class FixedPricer:
    kind = "fixed"
    def __init__(self, price):
        self.price = price
    def quota(self, pt, ct, o, ts, qpu):
        return qround(self.price * qpu * group_ratio(o)), ""

# ---------- 读库 ----------
con = sqlite3.connect(DB)
con.isolation_level = None   # 事务自己管：BEGIN … COMMIT / ROLLBACK
con.row_factory = sqlite3.Row
opts = {r["key"]: r["value"] for r in con.execute('SELECT "key", value FROM options')}
def jopt(k):
    try:
        v = json.loads(opts.get(k) or "{}")
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}
BMODE, BEXPR = jopt("billing_setting.billing_mode"), jopt("billing_setting.billing_expr")
MRATIO, CRATIO, KRATIO = jopt("ModelRatio"), jopt("CompletionRatio"), jopt("CacheRatio")
CREATE, MPRICE = jopt("CreateCacheRatio"), jopt("ModelPrice")
try:
    QPU = float(opts.get("QuotaPerUnit") or 500000)
except ValueError:
    QPU = 500000.0

def current_pricer(model):
    """与 new-api 相同的优先级：表达式计费 → 按次价格 → 倍率。拿不到返回 (None, 原因)。"""
    if BMODE.get(model) == "tiered_expr":
        if model not in BEXPR:
            return None, "billing_mode 是 tiered_expr 但没有表达式"
        try:
            return ExprPricer(BEXPR[model]), ""
        except Unsupported as e:
            return None, "表达式不支持：%s" % e
    if isinstance(MPRICE.get(model), (int, float)) and MPRICE[model] >= 0:
        return FixedPricer(float(MPRICE[model])), ""
    if model in MRATIO:
        if model not in CRATIO or model not in KRATIO:
            return None, "有模型倍率但缺补全倍率或缓存倍率"
        return RatioPricer(float(MRATIO[model]), float(CRATIO[model]), float(KRATIO[model]),
                           float(CREATE[model]) if model in CREATE else None), ""
    return None, "后台没有价格"

def usd(q):
    return q / QPU

logs = []
for r in con.execute("SELECT id, user_id, token_id, channel_id, model_name, prompt_tokens, completion_tokens, "
                     "quota, other, created_at FROM logs WHERE type=2 ORDER BY id"):
    try:
        o = json.loads(r["other"]) if r["other"] else {}
    except Exception:
        o = {}
    if not isinstance(o, dict):
        o = {}
    logs.append((r, o))

print("库: %s    模型: %s    模式: %s%s" % (DB, ", ".join(TARGETS), "执行" if APPLY else "预演",
                                        "，对齐令牌" if ALIGN else ""))
print("消费日志 %d 条，QuotaPerUnit %.0f" % (len(logs), QPU))

# ---------- 1. 公式自检：每条表达式计费日志用它自己的表达式重算 ----------
print("\n===== 1. 公式自检（用日志自带的表达式/倍率重算，与实际扣费比对） =====")
cache_expr = {}
stat = defaultdict(lambda: [0, 0, 0])   # 模型 -> [比对条数, 一致, 跳过]
miss = []
for r, o in logs:
    m = r["model_name"]
    pr = None
    if o.get("billing_mode") == "tiered_expr" and o.get("expr_b64"):
        try:
            s = base64.b64decode(o["expr_b64"]).decode("utf-8")
            if s not in cache_expr:
                try:
                    cache_expr[s] = ExprPricer(s)
                except Unsupported:
                    cache_expr[s] = None
            pr = cache_expr[s]
        except Exception:
            pr = None
    elif m in TARGETS and isinstance(o.get("model_ratio"), (int, float)) and o.get("model_ratio") not in (0, FALLBACK_RATIO):
        try:
            pr = RatioPricer(float(o["model_ratio"]), float(o.get("completion_ratio", 1)),
                             float(o.get("cache_ratio", 1)), o.get("cache_creation_ratio"))
        except (TypeError, ValueError):
            pr = None
    else:
        continue
    st = stat[m]
    if pr is None:
        st[2] += 1; continue
    try:
        q, _ = pr.quota(r["prompt_tokens"], r["completion_tokens"], o, r["created_at"], QPU)
    except Unsupported:
        st[2] += 1; continue
    st[0] += 1
    if q == r["quota"]:
        st[1] += 1
    elif len(miss) < 15:
        miss.append((r["id"], m, r["prompt_tokens"], r["completion_tokens"], o.get("cache_tokens"), r["quota"], q))
tot = [sum(v[i] for v in stat.values()) for i in range(3)]
print("  比对 %d 条，一致 %d 条，不一致 %d 条，跳过 %d 条（表达式用到日志里没有的维度）" %
      (tot[0], tot[1], tot[0] - tot[1], tot[2]))
for m in TARGETS:
    v = stat.get(m, [0, 0, 0])
    print("  %-28s 比对 %d  一致 %d  不一致 %d  跳过 %d" % (m, v[0], v[1], v[0] - v[1], v[2]))
for x in miss:
    print("  [不一致] id=%s %s 输入 %s 输出 %s 缓存 %s 实际 %s 重算 %s" % x)
bad = [m for m in TARGETS if stat.get(m, [0])[0] and (stat[m][0] - stat[m][1]) / stat[m][0] > SELF_CHECK_MAX_MISS]
if tot[0] == 0:
    print("  [!!] 没有可比对的日志，无法确认公式，中止"); sys.exit(1)
if bad or (tot[0] - tot[1]) / tot[0] > SELF_CHECK_MAX_MISS:
    print("  [!!] 重算与实际扣费对不上（%s），公式与这版 new-api 不符，中止" % (", ".join(bad) or "整体"))
    sys.exit(1)

# ---------- 2. 定价 ----------
print("\n===== 2. 后台当前价格 =====")
pricers = {}
for m in TARGETS:
    pr, why = current_pricer(m)
    if pr is None:
        print("  [!!] %s：%s，中止" % (m, why)); sys.exit(1)
    pricers[m] = (pr, m)
    print("  %-28s %s" % (m, pr.expr if pr.kind == "expr" else vars(pr)))

fb = [(r, o) for r, o in logs if o.get("model_ratio") == FALLBACK_RATIO and r["model_name"] not in TARGETS]
for r, o in fb:
    m = r["model_name"]
    if m in pricers:
        continue
    ref = MAP.get(m, m)
    pr, why = current_pricer(ref)
    if pr is None:
        print("  [!!] 兜底记录的模型 %s%s：%s。用 --map %s=<参考模型> 指定按谁的价格算，中止" %
              (m, "（参考 %s）" % ref if ref != m else "", why, m))
        sys.exit(1)
    pricers[m] = (pr, ref)
    print("  %-28s 兜底记录，按 %s 的价格：%s" % (m, ref, pr.expr if pr.kind == "expr" else vars(pr)))

# ---------- 3. 逐条重算 ----------
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
changes = []   # (id, user, token, old, new, new_other)
seg = defaultdict(lambda: [0, 0, 0])   # (模型, 渠道, 档位) -> [条数, 原, 新]
for r, o in logs:
    m = r["model_name"]
    if m in TARGETS or (o.get("model_ratio") == FALLBACK_RATIO and m in pricers):
        pr, ref = pricers[m]
        new, tier = pr.quota(r["prompt_tokens"], r["completion_tokens"], o, r["created_at"], QPU)
        o2 = dict(o)
        if pr.kind == "expr":
            o2.update({"billing_mode": "tiered_expr", "billing_unit": "token",
                       "expr_b64": base64.b64encode(pr.expr.encode("utf-8")).decode(),
                       "matched_tier": tier, "model_ratio": 0, "completion_ratio": 0,
                       "cache_ratio": 0, "model_price": 0})
        else:
            for k in ("billing_mode", "billing_unit", "expr_b64", "matched_tier"):
                o2.pop(k, None)
            if pr.kind == "ratio":
                o2.update({"model_ratio": pr.mr, "completion_ratio": pr.comp, "cache_ratio": pr.cache, "model_price": -1})
            else:
                o2.update({"model_ratio": 0, "model_price": pr.price})
        adm = dict(o2.get("admin_info") or {})
        prev = adm.get("reprice") or {}
        adm["reprice"] = {"by": VERSION, "at": now, "price_from": ref,
                          "old_quota": prev.get("old_quota", r["quota"])}
        o2["admin_info"] = adm
        changes.append((r["id"], r["user_id"], r["token_id"], r["quota"], new,
                        json.dumps(o2, ensure_ascii=False, separators=(",", ":"))))
        s = seg[(m, r["channel_id"], tier)]
        s[0] += 1; s[1] += r["quota"]; s[2] += new

print("\n===== 3. 重算明细（按模型 / 渠道 / 档位） =====")
print("  %-28s %4s %-8s %6s %12s %12s %12s" % ("模型", "渠道", "档位", "条数", "原配额", "新配额", "差额美元"))
for k in sorted(seg, key=lambda k: (str(k[0]), k[1] or 0, k[2])):
    s = seg[k]
    print("  %-28s %4s %-8s %6d %12d %12d %+12.4f" % (k[0], k[1], k[2] or "-", s[0], s[1], s[2], usd(s[2] - s[1])))
d_all = sum(c[4] - c[3] for c in changes)
print("  合计 %d 条，差额 %+d（%+.4f 美元）" % (len(changes), d_all, usd(d_all)))

# ---------- 4. 用户与令牌 ----------
delta_u, delta_t = defaultdict(int), defaultdict(int)
for _, u, t, old, new, _ in changes:
    delta_u[u] += new - old
    delta_t[t] += new - old
logsum_u = dict(con.execute("SELECT user_id, COALESCE(SUM(quota),0) FROM logs WHERE type=2 GROUP BY user_id").fetchall())
logsum_t = dict(con.execute("SELECT token_id, COALESCE(SUM(quota),0) FROM logs WHERE type=2 GROUP BY token_id").fetchall())

print("\n===== 4. 用户 =====")
user_upd = []
for u in con.execute("SELECT id, username, quota, used_quota FROM users ORDER BY id").fetchall():
    ls = logsum_u.get(u["id"], 0); d = delta_u.get(u["id"], 0)
    if u["used_quota"] == ls:
        user_upd.append((u["id"], u["used_quota"] + d, u["quota"] - d))
        print("  用户 %s：已用 %d → %d，余额 %d → %d（差 %+.4f 美元）" %
              (u["id"], u["used_quota"], u["used_quota"] + d, u["quota"], u["quota"] - d, usd(d)))
    else:
        print("  用户 %s：已用 %d 与日志合计 %d 本来就不相等（差 %+d），不改%s" %
              (u["id"], u["used_quota"], ls, u["used_quota"] - ls, "；其日志差额 %+d 只改日志" % d if d else ""))

print("\n===== 5. 令牌 =====")
token_upd = []
for t in con.execute("SELECT id, name, used_quota, remain_quota, unlimited_quota FROM tokens ORDER BY id").fetchall():
    d = delta_t.get(t["id"], 0)
    ls_new = logsum_t.get(t["id"], 0) + d
    new_used = ls_new if ALIGN else t["used_quota"] + d
    shift = new_used - t["used_quota"]
    new_remain = t["remain_quota"] - shift if not t["unlimited_quota"] else t["remain_quota"]
    token_upd.append((t["id"], new_used, new_remain))
    print("  令牌 %s「%s」：已用 %d → %d，剩余 %d → %d（其中重算 %+.4f 美元%s）" %
          (t["id"], t["name"], t["used_quota"], new_used, t["remain_quota"], new_remain, usd(d),
           "，对齐日志 %+.4f 美元" % usd(shift - d) if ALIGN else ""))
    if not ALIGN and t["used_quota"] != logsum_t.get(t["id"], 0):
        print("    注意：原已用额度与日志合计差 %+d（%+.4f 美元），加 --align-tokens 可一并对齐" %
              (t["used_quota"] - logsum_t.get(t["id"], 0), usd(t["used_quota"] - logsum_t.get(t["id"], 0))))

if not APPLY:
    print("\n  预演结束，未写库。确认无误后加 --apply 执行。")
    sys.exit(0)

# ---------- 执行 ----------
print("\n===== 执行写入 =====")
try:
    con.execute("BEGIN")
    con.executemany("UPDATE logs SET quota=?, other=? WHERE id=?", [(c[4], c[5], c[0]) for c in changes])
    con.executemany("UPDATE users SET used_quota=?, quota=? WHERE id=?", [(a, b, i) for i, a, b in user_upd])
    con.executemany("UPDATE tokens SET used_quota=?, remain_quota=? WHERE id=?", [(a, b, i) for i, a, b in token_upd])
    # 写后校验：与预期不符就整体回滚
    ids = [c[0] for c in changes]
    exp = {c[0]: c[4] for c in changes}
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        for rid, q in con.execute("SELECT id, quota FROM logs WHERE id IN (%s)" % ",".join("?" * len(chunk)), chunk):
            if q != exp[rid]:
                raise RuntimeError("日志 %s 写入后 quota=%s，预期 %s" % (rid, q, exp[rid]))
    ls_u = dict(con.execute("SELECT user_id, COALESCE(SUM(quota),0) FROM logs WHERE type=2 GROUP BY user_id").fetchall())
    for uid, used, _ in user_upd:
        if used != ls_u.get(uid, 0):
            raise RuntimeError("用户 %s 已用 %s 与日志合计 %s 不等" % (uid, used, ls_u.get(uid, 0)))
    if ALIGN:
        ls_t = dict(con.execute("SELECT token_id, COALESCE(SUM(quota),0) FROM logs WHERE type=2 GROUP BY token_id").fetchall())
        for tid, used, _ in token_upd:
            if used != ls_t.get(tid, 0):
                raise RuntimeError("令牌 %s 已用 %s 与日志合计 %s 不等" % (tid, used, ls_t.get(tid, 0)))
    left = sum(1 for r in con.execute("SELECT other FROM logs WHERE type=2 AND other LIKE '%37.5%'")
               if (json.loads(r[0] or "{}") or {}).get("model_ratio") == FALLBACK_RATIO)
    if left:
        raise RuntimeError("仍有 %d 条兜底记录" % left)
    con.execute("COMMIT")
except Exception as e:
    if con.in_transaction:
        con.execute("ROLLBACK")
    print("  [!!] 写入失败，事务已回滚：%s" % e)
    sys.exit(1)
ic = con.execute("PRAGMA integrity_check").fetchone()[0]
print("  已改日志 %d 条、用户 %d 个、令牌 %d 个；完整性: %s" % (len(changes), len(user_upd), len(token_upd), ic))
sys.exit(0 if ic == "ok" else 1)
PY
