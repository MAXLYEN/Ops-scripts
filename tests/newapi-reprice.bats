#!/usr/bin/env bats
# tests/newapi-reprice.bats — 真跑 ops/fix-newapi-reprice、ops/fix-newapi-quota-data 与一个按 new-api rc.38 表结构造的 SQLite 库。
# 期望值都是手算的（见每条日志旁的注释），不复用脚本里的公式。
# 能证明：表达式计费与倍率计费的重算、p 扣除缓存命中、按日志时间分忙时 / 闲时、兜底记录与 --map、
#         用户只改原本对得上的、令牌加差额或对齐日志、自检对不上就拒绝、重复执行不再变化、预演不写库；
#         quota_data 同一组合拆成多行（节点名不同）时按组合汇总核对、差额落到最大的一行，真对不上或会出负数时拒绝。
# 证明不了：真实 new-api 读到改过的库之后的显示与行为（要在生产上用 --dry-run 演练、改完到面板核对）；
#         apply-newapi-quota-fix 的 SSH、停容器、传回（只在生产上验证）。

S=/src/ops/fix-newapi-reprice.sh
QD=/src/ops/fix-newapi-quota-data.sh
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
# 渠道：已用 = 非测试日志合计（渠道测试不计入）。8 的非测试日志 4412+2600+2600=9612，多记 44000（像 9-24、9-30 都没改渠道表）；
# 2、4 本来就对得上；5 只有测试日志，已用 0；12、13 已删除，没有行
c.execute("CREATE TABLE channels(id integer primary key, name text, used_quota int)")
c.execute("INSERT INTO channels VALUES(2,'openai',5000),(4,'glm',218),(5,'doubao',0),(8,'bailian',53612)")
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

# ── quota_data（看板聚合表） ─────────────────────────────────
# qd_seed：换成 rc.38 的完整 quota_data 表，按「小时+用户+模型+渠道+令牌」从日志聚合出一行一组合；
# 再给 deepseek 那一小时补一条日志（id 11），让该组合拆成两行（节点名 n1 / n2），像容器重建后那样。
qd_seed() {
  python3 - "$DB" <<'PY'
import calendar, json, sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
T = lambda s: calendar.timegm(time.strptime(s, "%Y-%m-%d %H:%M"))
# 11：北京 10:10 忙时，(1000+100×2.285714)×0.175=215.0 → 215；新价 1000×1.335331+100×4.005994=1735.93 → 868
o = {"model_ratio": 0.175, "completion_ratio": 2.285714, "cache_ratio": 0.028571, "model_price": -1,
     "cache_tokens": 0, "group_ratio": 1, "user_group_ratio": -1}
c.execute("INSERT INTO logs VALUES(11,2,?,2,'','deepseek-v4-pro-0813',215,1000,100,8,1,?)",
          (T("2026-09-29 02:10"), json.dumps(o, separators=(",", ":"))))
c.execute("UPDATE users SET used_quota = used_quota + 215 WHERE id=2")
c.execute("UPDATE tokens SET used_quota = used_quota + 215 WHERE id=1")
c.executescript('''
DROP TABLE quota_data;
CREATE TABLE quota_data(id integer primary key, user_id int, username text, model_name text, created_at int,
  use_group text, token_id int, channel_id int, node_name text, token_used int, count int, quota int);
INSERT INTO quota_data(user_id, username, model_name, created_at, use_group, token_id, channel_id, node_name, token_used, count, quota)
  SELECT user_id, 'u', model_name, (created_at/3600)*3600, 'default', token_id, channel_id, 'n1',
         SUM(prompt_tokens+completion_tokens), COUNT(*), SUM(quota)
  FROM logs WHERE type=2 AND id <> 11 GROUP BY 1,3,4,6,7,8 ORDER BY MIN(id);
''')
# id 11 单独进一行 n2：同一组合拆成两行
c.execute("INSERT INTO quota_data(user_id, username, model_name, created_at, use_group, token_id, channel_id, node_name, token_used, count, quota) "
          "VALUES(2,'u','deepseek-v4-pro-0813',?,'default',1,8,'n2',1100,1,215)", ((T("2026-09-29 02:10") // 3600) * 3600,))
c.commit()
PY
}
MAPARG="--map deepseek-v4-1-flash-260910=deepseek-v4.1-flash"

@test "quota_data：同一组合拆成两行时按组合核对，差额落到额度大的那行，改完与日志一致" {
  qd_seed
  bash "$S" "$DB" "$MODELS" --apply --align-tokens $MAPARG
  run bash "$QD" "$DB"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"拆成多行的组合: 1"* ]]
  [[ "$output" == *"试运行结束，未写库"* ]]
  run bash "$QD" "$DB" --apply
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"两表差额: 0"*"仍有差额的组合: 0"* ]]
  # 组合原合计 2600+215=2815，新合计 14689+868=15557，差额 12742 落到 n1（原 2600，较大）
  [ "$(q "SELECT group_concat(node_name||':'||quota||':'||count, ',') FROM (SELECT * FROM quota_data WHERE model_name='deepseek-v4-pro-0813' AND channel_id=8 AND created_at=(SELECT (created_at/3600)*3600 FROM logs WHERE id=3) ORDER BY node_name)")" = "n1:15342:1,n2:215:1" ]
  [ "$(q "SELECT (SELECT SUM(quota) FROM quota_data) - (SELECT SUM(quota) FROM logs WHERE type=2)")" = 0 ]
  # 用户 2 的日志多了 11 号（+868），仍与日志一致
  [ "$(q "SELECT used_quota FROM users WHERE id=2")" = "$(q "SELECT SUM(quota) FROM logs WHERE type=2 AND user_id=2")" ]
}

@test "quota_data：组合的次数真对不上时拒绝，并列出是哪个组合" {
  qd_seed
  q "UPDATE quota_data SET count = count + 1 WHERE node_name='n2'"
  before=$(sha256sum "$DB")
  run bash "$QD" "$DB" --apply
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"次数不一致的组合: 1"* && "$output" == *"deepseek-v4-pro-0813"* && "$output" == *"中止"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "quota_data：日志有而看板没有的组合拒绝（不凭空造行）" {
  qd_seed
  q "DELETE FROM quota_data WHERE model_name='gpt-6-sol'"
  bash "$S" "$DB" "$MODELS" --apply --align-tokens $MAPARG    # 有差额要写，才能看出是不是在写之前就拦下
  before=$(sha256sum "$DB")
  run bash "$QD" "$DB" --apply
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"日志有、看板没有的组合: 1"* && "$output" == *"中止"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "quota_data：差额比承担行还大、改完会出负数时拒绝" {
  qd_seed
  # doubao 兜底那一组合拆成 30000 + 22275 两行（次数 1 + 0），重算后合计 580，差额 -51695 落到 30000 那行会变负
  q "UPDATE quota_data SET quota=30000 WHERE model_name='doubao-seed-2-1-pro'"
  q "INSERT INTO quota_data(user_id, username, model_name, created_at, use_group, token_id, channel_id, node_name, token_used, count, quota) SELECT user_id, username, model_name, created_at, use_group, token_id, channel_id, 'n2', 0, 0, 22275 FROM quota_data WHERE model_name='doubao-seed-2-1-pro'"
  bash "$S" "$DB" "$MODELS" --apply --align-tokens $MAPARG
  before=$(sha256sum "$DB")
  run bash "$QD" "$DB" --apply
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"出现负数"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

# ── 渠道（channels.used_quota，后台渠道列表的「已使用」） ─────────
chans() { q "SELECT group_concat(id||':'||used_quota) FROM (SELECT id, used_quota FROM channels ORDER BY id)"; }

@test "渠道：重算时按非测试日志的差额调整，测试日志不计入，已删除的渠道只列出" {
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  # 8：非测试日志 A +39、C +12089、D +4744（E 是测试，不计）→ 53612+16872；5 只有测试日志 G，不变
  [ "$(chans)" = "2:5000,4:218,5:0,8:70484" ]
  [[ "$output" == *"渠道 13 已删除"* && "$output" == *"渠道 12 已删除"* ]]
  [[ "$output" == *"--align-channels 可对齐"* ]]
}

@test "渠道：--align-channels 对齐到非测试日志合计" {
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --align-channels --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  # 8：4451+14689+7344
  [ "$(chans)" = "2:5000,4:218,5:0,8:26484" ]
  [[ "$output" == *"对齐日志"* && "$output" == *"渠道 1 个"* ]]
  [[ "$output" != *"可对齐"* ]]
}

@test "只对齐渠道（模型写 -）：日志、用户、令牌一个都不动；再跑一次没有要改的" {
  before=$(state)
  run bash "$S" "$DB" - --apply --align-channels
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(state)" = "$before" ]
  [ "$(chans)" = "2:5000,4:218,5:0,8:9612" ]
  [[ "$output" == *"渠道 8「bailian」：已用 53612 → 9612"* ]]
  run bash "$S" "$DB" - --apply --align-channels
  [ "$status" -eq 0 ]
  [[ "$output" == *"渠道都已对齐，没有要改的"* ]]
}

@test "只对齐渠道：没有一个渠道符合「已用 = 非测试日志合计」时拒绝，库不动" {
  q "UPDATE channels SET used_quota = used_quota + 1 WHERE id IN (2,4)"
  before=$(sha256sum "$DB")
  run bash "$S" "$DB" - --apply --align-channels
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"规则与这版 new-api 不符"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "模型写 - 却不带 --align-channels：说明用法，库不动" {
  before=$(sha256sum "$DB")
  run bash "$S" "$DB" - --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"要带 --align-channels"* ]]
  [ "$(sha256sum "$DB")" = "$before" ]
}

@test "库里没有 channels 表：重算照常，只是跳过渠道；要对齐渠道则拒绝" {
  q "DROP TABLE channels"
  run bash "$S" "$DB" "$MODELS" --apply --align-tokens --map deepseek-v4-1-flash-260910=deepseek-v4.1-flash
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(q "SELECT quota FROM logs WHERE id=3")" = 14689 ]
  run bash "$S" "$DB" - --apply --align-channels
  [ "$status" -ne 0 ]
  [[ "$output" == *"没有 channels 表"* ]]
}
