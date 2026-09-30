#!/usr/bin/env bats
# tests/newapi-reprice.bats — 真跑 ops/fix-newapi-reprice 与一个按 new-api rc.38 表结构造的 SQLite 库。
# 期望值都是手算的（见每条日志旁的注释），不复用脚本里的公式。
# 能证明：表达式计费与倍率计费的重算、p 扣除缓存命中、按日志时间分忙时 / 闲时、兜底记录与 --map、
#         用户只改原本对得上的、令牌加差额或对齐日志、自检对不上就拒绝、重复执行不再变化、预演不写库。
# 证明不了：真实 new-api 读到改过的库之后的显示与行为（要在生产上用 --dry-run 看明细、改完到面板核对）。

S=/src/ops/fix-newapi-reprice.sh
D=/tmp/reprice
DB=$D/one-api.db
MODELS=qwen3.8-flash,glm-5.3,deepseek-v4-pro-0813

setup() {
  rm -rf "$D"; mkdir -p "$D"
  python3 - "$DB" <<'PY'
import base64, calendar, json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript('''
CREATE TABLE options("key" text primary key, value text);
CREATE TABLE users(id integer primary key, username text, password text, quota int, used_quota int);
CREATE TABLE tokens(id integer primary key, user_id int, "key" text, name text, used_quota int, remain_quota int, unlimited_quota int);
CREATE TABLE logs(id integer primary key, user_id int, created_at int, type int, content text, model_name text,
                  quota int, prompt_tokens int, completion_tokens int, channel_id int, token_id int, other text);
CREATE TABLE quota_data(id integer primary key, user_id int, model_name text, created_at int, token_used int, count int, quota int);
''')
NEW = {
 "deepseek-v4-pro-0813": 'hour("Asia/Shanghai") >= 8 && hour("Asia/Shanghai") < 22 ? tier("忙时", p * 1.335331 + c * 4.005994 + cr * 0.133533) : tier("闲时", p * 0.667666 + c * 2.002997 + cr * 0.066767)',
 "glm-5.3": 'tier("base", p * 1.186961 + c * 4.154364 + cr * 0.29674)',
 "qwen3.8-flash": 'tier("base", p * 0.118696 + c * 0.400599 + cr * 0.014837)',
 "glm-5.3-flashx": 'tier("standard", p * 0.37 + cr * 0.075 + cc * 0 + c * 1.25)',
 "doubao-seed-2-1-pro": 'tier("standard", p * 0.8 + c * 2.0 + cr * 0.16)',
}
OLD_GLM = 'tier("standard", p * 1.17647 + c * 4.11765 + cr * 0.29412)'
OLD_QWEN = 'tier("standard", p * 0.15 + c * 0.5 + cr * 0.02)'
mode = {k: "tiered_expr" for k in NEW}
mode["deepseek-v4.1-flash"] = "ratio"
opts = {"billing_setting.billing_mode": mode, "billing_setting.billing_expr": NEW,
        "ModelRatio": {"deepseek-v4-pro-0813": 0.175, "deepseek-v4.1-flash": 0.075, "gpt-6-sol": 2.5},
        "CompletionRatio": {"deepseek-v4-pro-0813": 2.285714, "deepseek-v4.1-flash": 4, "gpt-6-sol": 6},
        "CacheRatio": {"deepseek-v4-pro-0813": 0.028571, "deepseek-v4.1-flash": 0.02, "gpt-6-sol": 1}}
c.executemany("INSERT INTO options VALUES(?,?)", [(k, json.dumps(v, ensure_ascii=False)) for k, v in opts.items()])
c.execute("INSERT INTO options VALUES('SMTPToken','x')")
b64 = lambda s: base64.b64encode(s.encode()).decode()
def expr_other(s, tier, cache=0):
    return {"billing_mode": "tiered_expr", "expr_b64": b64(s), "matched_tier": tier, "billing_unit": "token",
            "cache_tokens": cache, "model_ratio": 0, "completion_ratio": 0, "cache_ratio": 0,
            "model_price": 0, "group_ratio": 1, "user_group_ratio": -1, "admin_info": {"use_channel": ["8"]}}
def ratio_other(mr, cr_, kr, cache=0):
    return {"model_ratio": mr, "completion_ratio": cr_, "cache_ratio": kr, "model_price": -1,
            "cache_tokens": cache, "group_ratio": 1, "user_group_ratio": -1}
T = lambda s: calendar.timegm(__import__("time").strptime(s, "%Y-%m-%d %H:%M"))
rows = [
 # id 用户 时间(UTC)          内容     模型                       原额度 输入    输出  渠道 令牌 other
 # A 旧 glm：p=10000-8000；2000×1.17647+8000×0.29412+1000×4.11765=8823.55 → ÷2=4411.8 → 4412
 (1, 2, "2026-09-27 03:00", "", "glm-5.3", 4412, 10000, 1000, 8, 1, expr_other(OLD_GLM, "standard", 8000)),
 # B 旧 qwen：1000×0.15+100×0.5=200 → 100
 (2, 2, "2026-09-27 03:10", "", "qwen3.8-flash", 100, 1000, 100, 13, 1, expr_other(OLD_QWEN, "standard")),
 # C deepseek 倍率：(10000+90000×0.028571+1000×2.285714)×0.175=2600.0 → 2600；北京 10 点 = 忙时
 (3, 2, "2026-09-29 02:00", "", "deepseek-v4-pro-0813", 2600, 100000, 1000, 8, 1, ratio_other(0.175, 2.285714, 0.028571, 90000)),
 # D 同上，北京 23 点 = 闲时
 (4, 2, "2026-09-29 15:00", "", "deepseek-v4-pro-0813", 2600, 100000, 1000, 8, 1, ratio_other(0.175, 2.285714, 0.028571, 90000)),
 # E 管理员渠道测试，旧 glm：13×1.17647+16×4.11765=81.18 → 41
 (5, 1, "2026-09-27 03:20", "模型测试", "glm-5.3", 41, 13, 16, 8, 0, expr_other(OLD_GLM, "standard")),
 # F 兜底 37.5（用户 2 / 令牌 1）
 (6, 2, "2026-09-27 04:19", "", "doubao-seed-2-1-pro", 52275, 1356, 38, 12, 1, ratio_other(37.5, 1, 1)),
 # G 兜底 37.5（管理员测试），后台没价格，要 --map 到 deepseek-v4.1-flash
 (7, 1, "2026-09-28 07:03", "模型测试", "deepseek-v4-1-flash-260910", 1763, 31, 16, 5, 0, ratio_other(37.5, 1, 1)),
 # H 不相干的模型，不动
 (8, 2, "2026-09-27 05:00", "", "gpt-6-sol", 5000, 1500, 200, 2, 1, ratio_other(2.5, 6, 1)),
 # I 不相干的表达式模型，只参与自检：800×0.37+200×0.075+100×1.25=436 → 218
 (9, 2, "2026-09-27 05:10", "", "glm-5.3-flashx", 218, 1000, 100, 4, 1, expr_other(NEW["glm-5.3-flashx"], "standard", 200)),
]
for r in rows:
    c.execute("INSERT INTO logs VALUES(?,?,?,2,?,?,?,?,?,?,?,?)",
              (r[0], r[1], T(r[2]), r[3], r[4], r[5], r[6], r[7], r[8], r[9], json.dumps(r[10], ensure_ascii=False, separators=(",", ":"))))
c.execute("INSERT INTO logs VALUES(10,2,0,1,'充值','',0,0,0,0,0,'')")
# 用户 2：已用 = 名下日志合计 4412+100+2600+2600+52275+5000+218 = 67205；用户 1 只有测试，已用 0
c.execute("INSERT INTO users VALUES(1,'admin','h',0,0),(2,'api','h',100000,67205)")
# 令牌 1：日志合计 67205，已用多记了 44308（像 9-24 那次漏改）
c.execute("INSERT INTO tokens VALUES(1,2,'sk-x','main',111513,500000,0)")
c.commit()
PY
}

teardown() { rm -rf "$D"; }

q() { sqlite3 "$DB" "$1"; }
state() { q "SELECT group_concat(id||':'||quota) FROM (SELECT id, quota FROM logs ORDER BY id); SELECT group_concat(id||':'||used_quota||':'||quota) FROM users; SELECT used_quota||':'||remain_quota FROM tokens;"; }

@test "预演：自检通过、列出明细，库文件一个字节都不改" {
  before=$(sha256sum "$DB")
  run bash "$S" "$DB" "$MODELS" --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"不一致 0 条"* ]]
  [[ "$output" == *"预演结束，未写库"* ]]
  [[ "$output" == *"忙时"* && "$output" == *"闲时"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "执行：日志按新价重算，用户与令牌跟上，兜底记录按参考模型算" {
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  # A 新 glm：2000×1.186961+8000×0.29674+1000×4.154364=8902.2 → 4451
  # B 新 qwen：1000×0.118696+100×0.400599=158.76 → 79
  # C 忙时：10000×1.335331+90000×0.133533+1000×4.005994=29377.27 → 14689
  # D 闲时：10000×0.667666+90000×0.066767+1000×2.002997=14688.69 → 7344
  # E 新 glm：13×1.186961+16×4.154364=81.90 → 41
  # F doubao 表达式：1356×0.8+38×2=1160.8 → 580
  # G 参考 deepseek-v4.1-flash 倍率：(31+16×4)×0.075=7.125 → 7
  [ "$(q "SELECT group_concat(id||':'||quota) FROM (SELECT id, quota FROM logs ORDER BY id)")" = \
    "1:4451,2:79,3:14689,4:7344,5:41,6:580,7:7,8:5000,9:218,10:0" ]
  # 用户 2 差额 +39-21+12089+4744-51695 = -34844；用户 1 原本就对不上，不动
  [ "$(q "SELECT group_concat(id||':'||used_quota||':'||quota) FROM users")" = "1:0:0,2:32361:134844" ]
  # 令牌对齐到日志合计 32361，剩余加回 111513-32361
  [ "$(q "SELECT used_quota||':'||remain_quota FROM tokens")" = "32361:579152" ]
  [ "$(q "SELECT json_extract(other,'\$.matched_tier')||'|'||json_extract(other,'\$.billing_mode')||'|'||json_extract(other,'\$.model_ratio')||'|'||json_extract(other,'\$.admin_info.reprice.old_quota') FROM logs WHERE id IN (3,4) ORDER BY id")" = \
    "$(printf '忙时|tiered_expr|0|2600\n闲时|tiered_expr|0|2600')" ]
  [ "$(q "SELECT json_extract(other,'\$.model_ratio')||'|'||json_extract(other,'\$.admin_info.reprice.price_from') FROM logs WHERE id=7")" = "0.075|deepseek-v4.1-flash" ]
  [ "$(q "SELECT json_extract(other,'\$.admin_info.use_channel[0]') FROM logs WHERE id=1")" = "8" ]
  [ "$(q "SELECT COUNT(*) FROM logs WHERE other LIKE '%\"model_ratio\":37.5%'")" = 0 ]
  [ "$(q 'PRAGMA integrity_check')" = ok ]
}

@test "重复执行：数值不再变化，原额度记录保留第一次的值" {
  bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  first=$(state)
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(state)" = "$first" ]
  [[ "$output" == *"差额 +0"* ]]
  [ "$(q "SELECT json_extract(other,'\$.admin_info.reprice.old_quota') FROM logs WHERE id=3")" = 2600 ]
}

@test "不对齐令牌：令牌只加差额，并提示原来就对不上" {
  run bash "$S" "$DB" "$MODELS" --apply --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(q "SELECT used_quota||':'||remain_quota FROM tokens")" = "76669:534844" ]
  [[ "$output" == *"--align-tokens 可一并对齐"* ]]
}

@test "兜底记录的模型没有价格又没给 --map：拒绝，库不动" {
  before=$(sha256sum "$DB")
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"deepseek-v4-1-flash-260910"*"--map"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "自检对不上（公式与这版 new-api 不符）：拒绝，库不动" {
  q "UPDATE logs SET quota = quota + 7 WHERE id IN (1,5)"
  before=$(sha256sum "$DB")
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"对不上"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "目标模型的当前表达式用到日志里没有的维度：拒绝" {
  q "UPDATE options SET value = json_set(value, '\$.\"qwen3.8-flash\"', 'tier(\"base\", img * 1.0)') WHERE \"key\"='billing_setting.billing_expr'"
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"qwen3.8-flash"*"表达式不支持"* ]]
}
