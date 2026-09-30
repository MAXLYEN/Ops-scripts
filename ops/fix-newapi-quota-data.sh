#!/usr/bin/env bash
# ops/fix-newapi-quota-data.sh — 按已修正的日志重算 new-api 配额统计
# VERSION: 1.1.0
# 1.1.0: new-api rc.38 的 quota_data 按 小时+用户+用户名+模型+分组+令牌+渠道+节点名 聚合，节点名在日志里没有，
#        同一「小时+用户+模型+渠道+令牌」可能拆成多行（容器重建后节点名会变）。原来逐行与日志比次数，拆行就误判「维度对不上」。
#        改为按组合汇总后比次数；差额加到该组合额度最大的一行，保留原有拆分；有日志却没有看板行、或改完出现负数都拒绝。
# 1.0.1: 整理注释并补充目录文档，执行逻辑未变。

set -o pipefail

DB="$1"; APPLY=0
[ "$2" = "--apply" ] && APPLY=1
[ -n "$DB" ] && [ -f "$DB" ] || { echo "用法: $0 <库文件> [--apply]"; exit 1; }
command -v sqlite3 >/dev/null || { echo "缺少 sqlite3"; exit 1; }

# 日志按「小时+用户+模型+渠道+令牌」聚合；看板表按同样的组合汇总（组合内可能有多行）
CTE="WITH agg AS (
  SELECT (created_at/3600)*3600 AS hr, user_id, model_name, channel_id, token_id,
         COUNT(*) AS cnt, SUM(quota) AS q, SUM(prompt_tokens+completion_tokens) AS tk
  FROM logs WHERE type=2
  GROUP BY 1,2,3,4,5
),
qd AS (
  SELECT created_at AS hr, user_id, model_name, channel_id, token_id,
         SUM(count) AS cnt, SUM(quota) AS q, SUM(token_used) AS tk, COUNT(*) AS nrows
  FROM quota_data
  GROUP BY 1,2,3,4,5
)"
JOIN="a.hr=q.hr AND a.user_id=q.user_id AND a.model_name=q.model_name AND a.channel_id=q.channel_id AND a.token_id=q.token_id"

echo "===== 改动前 ====="
sqlite3 -header -column "$DB" "
SELECT ROUND((SELECT SUM(quota) FROM quota_data)/500000.0,2) AS 看板美元,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志美元,
       (SELECT SUM(count) FROM quota_data) AS 看板次数,
       (SELECT COUNT(*) FROM logs WHERE type=2) AS 日志条数;"

echo
echo "===== 一致性预检（按组合汇总） ====="
PRE=$(sqlite3 "$DB" "$CTE
SELECT (SELECT COUNT(*) FROM qd q LEFT JOIN agg a ON $JOIN WHERE a.hr IS NULL) || '|' ||
       (SELECT COUNT(*) FROM agg a LEFT JOIN qd q ON $JOIN WHERE q.hr IS NULL) || '|' ||
       (SELECT COUNT(*) FROM qd q JOIN agg a ON $JOIN WHERE a.cnt <> q.cnt) || '|' ||
       (SELECT COUNT(*) FROM qd WHERE nrows > 1);")
IFS='|' read -r QONLY AONLY CNTDIFF SPLIT <<<"$PRE"
echo "  看板有、日志没有的组合: ${QONLY}    日志有、看板没有的组合: ${AONLY}    次数不一致的组合: ${CNTDIFF}    拆成多行的组合: ${SPLIT}"
if [ "$QONLY" != 0 ] || [ "$AONLY" != 0 ] || [ "$CNTDIFF" != 0 ]; then
  sqlite3 -header -column "$DB" "$CTE
  SELECT '看板有日志无' AS 类别, q.hr AS 小时, q.user_id AS 用户, q.model_name AS 模型, q.channel_id AS 渠道, q.token_id AS 令牌, q.cnt AS 看板次数, NULL AS 日志次数
    FROM qd q LEFT JOIN agg a ON $JOIN WHERE a.hr IS NULL
  UNION ALL
  SELECT '日志有看板无', a.hr, a.user_id, a.model_name, a.channel_id, a.token_id, NULL, a.cnt
    FROM agg a LEFT JOIN qd q ON $JOIN WHERE q.hr IS NULL
  UNION ALL
  SELECT '次数不一致', q.hr, q.user_id, q.model_name, q.channel_id, q.token_id, q.cnt, a.cnt
    FROM qd q JOIN agg a ON $JOIN WHERE a.cnt <> q.cnt
  LIMIT 20;"
  echo "  [!!] 看板表与日志对不上（不是拆行造成的），中止"
  exit 1
fi

echo
echo "===== 待更新明细 ====="
sqlite3 -header -column "$DB" "$CTE
SELECT q.model_name AS 模型, COUNT(*) AS 组合数,
       SUM(q.q) AS 原配额, SUM(a.q) AS 新配额,
       ROUND(SUM(a.q - q.q)/500000.0,4) AS 差额美元
FROM qd q JOIN agg a ON $JOIN
WHERE a.q <> q.q OR a.tk <> q.tk
GROUP BY q.model_name ORDER BY SUM(a.q - q.q) DESC;"

# 每个有差额的组合挑一行承担差额：额度最大的一行，相同时取 id 最小的
PICK="CREATE TEMP TABLE pick AS
$CTE
SELECT a.q - q.q AS dq, a.tk - q.tk AS dtk,
       (SELECT x.id FROM quota_data x
         WHERE x.created_at=q.hr AND x.user_id=q.user_id AND x.model_name=q.model_name
           AND x.channel_id=q.channel_id AND x.token_id=q.token_id
         ORDER BY x.quota DESC, x.id LIMIT 1) AS rid
FROM qd q JOIN agg a ON $JOIN
WHERE a.q <> q.q OR a.tk <> q.tk;"

NEG=$(sqlite3 "$DB" "$PICK
SELECT COUNT(*) FROM pick p JOIN quota_data x ON x.id=p.rid WHERE x.quota + p.dq < 0 OR x.token_used + p.dtk < 0;")
[ "$NEG" = 0 ] || { echo "  [!!] 有 ${NEG} 个组合改完会出现负数（差额比承担行还大），中止"; exit 1; }

if [ "$APPLY" != 1 ]; then
  echo
  echo "  试运行结束，未写库。确认无误后加 --apply 执行。"
  exit 0
fi

echo
echo "===== 执行写入 ====="
sqlite3 "$DB" <<SQLEOF
BEGIN;
$PICK
UPDATE quota_data SET
  quota      = quota      + (SELECT dq  FROM pick WHERE pick.rid = quota_data.id),
  token_used = token_used + (SELECT dtk FROM pick WHERE pick.rid = quota_data.id)
WHERE id IN (SELECT rid FROM pick);
COMMIT;
SQLEOF
[ $? = 0 ] || { echo "  [!!] 写入失败，事务已回滚"; exit 1; }

echo
echo "===== 改动后 ====="
sqlite3 -header -column "$DB" "
SELECT ROUND((SELECT SUM(quota) FROM quota_data)/500000.0,2) AS 看板美元,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志美元;"
D=$(sqlite3 "$DB" "SELECT (SELECT SUM(quota) FROM quota_data) - (SELECT SUM(quota) FROM logs WHERE type=2);")
K=$(sqlite3 "$DB" "$CTE SELECT COUNT(*) FROM qd q JOIN agg a ON $JOIN WHERE a.q <> q.q OR a.tk <> q.tk;")
echo "  两表差额: ${D}  （必须为 0）    仍有差额的组合: ${K}  （必须为 0）"
sqlite3 "$DB" "PRAGMA integrity_check;" | sed 's/^/  完整性: /'
[ "$D" = 0 ] && [ "$K" = 0 ] || exit 1
