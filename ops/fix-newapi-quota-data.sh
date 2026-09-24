#!/usr/bin/env bash
# ops/fix-newapi-quota-data.sh — 按已修正的日志重算 new-api 配额统计
# VERSION: 1.0.1
# 1.0.1: 整理注释并补充目录文档，执行逻辑未变。

set -o pipefail

DB="$1"; APPLY=0
[ "$2" = "--apply" ] && APPLY=1
[ -n "$DB" ] && [ -f "$DB" ] || { echo "用法: $0 <库文件> [--apply]"; exit 1; }
command -v sqlite3 >/dev/null || { echo "缺少 sqlite3"; exit 1; }

AGG="WITH agg AS (
  SELECT (created_at/3600)*3600 AS hr, user_id, model_name, channel_id, token_id,
         COUNT(*) AS cnt, SUM(quota) AS q,
         SUM(prompt_tokens+completion_tokens) AS tk
  FROM logs WHERE type=2
  GROUP BY 1,2,3,4,5
)"

echo "===== 改动前 ====="
sqlite3 -header -column "$DB" "
SELECT ROUND((SELECT SUM(quota) FROM quota_data)/500000.0,2) AS 看板美元,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志美元,
       (SELECT SUM(count) FROM quota_data) AS 看板次数,
       (SELECT COUNT(*) FROM logs WHERE type=2) AS 日志条数;"

echo
echo "===== 一致性预检 ====="
PRE=$(sqlite3 "$DB" "$AGG
SELECT (SELECT COUNT(*) FROM quota_data q LEFT JOIN agg a
          ON a.hr=q.created_at AND a.user_id=q.user_id AND a.model_name=q.model_name
         AND a.channel_id=q.channel_id AND a.token_id=q.token_id
        WHERE a.hr IS NULL) || '|' ||
       (SELECT COUNT(*) FROM quota_data q JOIN agg a
          ON a.hr=q.created_at AND a.user_id=q.user_id AND a.model_name=q.model_name
         AND a.channel_id=q.channel_id AND a.token_id=q.token_id
        WHERE a.cnt <> q.count);")
MISS=${PRE%%|*}; CNTDIFF=${PRE##*|}
echo "  匹配不上的行: ${MISS}    次数不一致的行: ${CNTDIFF}"
[ "$MISS" = 0 ] && [ "$CNTDIFF" = 0 ] || { echo "  [!!] 维度对不上，中止"; exit 1; }

echo
echo "===== 待更新明细 ====="
sqlite3 -header -column "$DB" "$AGG
SELECT q.model_name AS 模型, COUNT(*) AS 行数,
       SUM(q.quota) AS 原配额, SUM(a.q) AS 新配额,
       ROUND(SUM(q.quota - a.q)/500000.0,2) AS 差额美元
FROM quota_data q JOIN agg a
  ON a.hr=q.created_at AND a.user_id=q.user_id AND a.model_name=q.model_name
 AND a.channel_id=q.channel_id AND a.token_id=q.token_id
WHERE a.q <> q.quota OR a.tk <> q.token_used
GROUP BY q.model_name ORDER BY SUM(q.quota - a.q) DESC;"

if [ "$APPLY" != 1 ]; then
  echo
  echo "  试运行结束，未写库。确认无误后加 --apply 执行。"
  exit 0
fi

echo
echo "===== 执行写入 ====="
sqlite3 "$DB" <<SQLEOF
BEGIN;
CREATE TEMP TABLE agg_t AS
$AGG
SELECT * FROM agg;

UPDATE quota_data SET
  quota = (SELECT q FROM agg_t WHERE agg_t.hr=quota_data.created_at
             AND agg_t.user_id=quota_data.user_id AND agg_t.model_name=quota_data.model_name
             AND agg_t.channel_id=quota_data.channel_id AND agg_t.token_id=quota_data.token_id),
  token_used = (SELECT tk FROM agg_t WHERE agg_t.hr=quota_data.created_at
             AND agg_t.user_id=quota_data.user_id AND agg_t.model_name=quota_data.model_name
             AND agg_t.channel_id=quota_data.channel_id AND agg_t.token_id=quota_data.token_id)
WHERE EXISTS (SELECT 1 FROM agg_t WHERE agg_t.hr=quota_data.created_at
             AND agg_t.user_id=quota_data.user_id AND agg_t.model_name=quota_data.model_name
             AND agg_t.channel_id=quota_data.channel_id AND agg_t.token_id=quota_data.token_id);
COMMIT;
SQLEOF
[ $? = 0 ] || { echo "  [!!] 写入失败，事务已回滚"; exit 1; }

echo
echo "===== 改动后 ====="
sqlite3 -header -column "$DB" "
SELECT ROUND((SELECT SUM(quota) FROM quota_data)/500000.0,2) AS 看板美元,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志美元;"
D=$(sqlite3 "$DB" "SELECT (SELECT SUM(quota) FROM quota_data) - (SELECT SUM(quota) FROM logs WHERE type=2);")
echo "  两表差额: ${D}  （必须为 0）"
sqlite3 "$DB" "PRAGMA integrity_check;" | sed 's/^/  完整性: /'
