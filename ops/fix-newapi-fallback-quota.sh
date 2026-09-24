#!/usr/bin/env bash
# ops/fix-newapi-fallback-quota.sh — 修正 new-api 兜底倍率造成的虚高消费
# VERSION: 1.0.1
# 1.0.1: 整理注释并补充目录文档，执行逻辑未变。

set -o pipefail

DB="$1"; APPLY=0
[ "$2" = "--apply" ] && APPLY=1
[ -n "$DB" ] && [ -f "$DB" ] || { echo "用法: $0 <库文件> [--apply]"; exit 1; }
command -v sqlite3 >/dev/null || { echo "缺少 sqlite3"; exit 1; }

MAP="VALUES ('qwen3.8-max-0902','qwen3.8-max'),
            ('deepseek-v4-pro','deepseek-v4-pro'),
            ('doubao-seed-2-1-pro-260915','doubao-seed-2-1-pro-260915'),
            ('kimi-k2.8-preview','kimi-k3'),
            ('MiniMax-H3','MiniMax-M3')"

CTE="WITH map(m, ref) AS ( $MAP ),
rate AS (
  SELECT model_name AS m,
         CAST(SUM(quota) AS REAL)/NULLIF(SUM(prompt_tokens+completion_tokens),0) AS r
  FROM logs WHERE type=2 AND other NOT LIKE '%\"model_ratio\":37.5%'
  GROUP BY model_name
),
fb AS (
  SELECT id, user_id, model_name, prompt_tokens+completion_tokens AS tk, quota
  FROM logs WHERE type=2 AND other LIKE '%\"model_ratio\":37.5%'
),
calc AS (
  SELECT fb.id, fb.user_id, fb.model_name, fb.quota AS old_q,
         CAST(fb.tk*rate.r AS INTEGER) AS new_q, rate.r AS r
  FROM fb JOIN map ON map.m=fb.model_name JOIN rate ON rate.m=map.ref
)"

echo "===== 改动前 ====="
sqlite3 -header -column "$DB" "
SELECT (SELECT COUNT(*) FROM logs WHERE type=2) AS 消费条数,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志合计美元;"
sqlite3 -header -column "$DB" "SELECT id, username, quota AS 余额配额, used_quota AS 已用配额 FROM users;"

echo
echo "===== 待修正明细 ====="
sqlite3 -header -column "$DB" "$CTE
SELECT user_id AS 用户, model_name AS 模型, COUNT(*) AS 条数,
       SUM(old_q) AS 原配额, SUM(new_q) AS 新配额, SUM(old_q-new_q) AS 应退
FROM calc GROUP BY user_id, model_name ORDER BY SUM(old_q-new_q) DESC;"

UNMATCHED=$(sqlite3 "$DB" "$CTE
SELECT (SELECT COUNT(*) FROM fb) - (SELECT COUNT(*) FROM calc);")
echo "  未匹配到参考单价的条数: ${UNMATCHED}"
[ "$UNMATCHED" != 0 ] && { echo "  [!!] 有记录无法重算，中止（先补映射表）"; exit 1; }

echo
echo "===== users 将变成 ====="
sqlite3 -header -column "$DB" "$CTE
SELECT u.id, u.username,
       u.used_quota AS 原已用, u.used_quota - COALESCE(d.refund,0) AS 新已用,
       u.quota AS 原余额,     u.quota + COALESCE(d.refund,0) AS 新余额
FROM users u
LEFT JOIN (SELECT user_id, SUM(old_q-new_q) AS refund FROM calc GROUP BY user_id) d
  ON d.user_id = u.id
WHERE u.used_quota > 0;"

if [ "$APPLY" != 1 ]; then
  echo
  echo "  试运行结束，未写库。确认无误后加 --apply 执行。"
  exit 0
fi

echo
echo "===== 执行写入 ====="
sqlite3 "$DB" <<SQLEOF
BEGIN;
CREATE TEMP TABLE calc_t AS
$CTE
SELECT * FROM calc;

UPDATE users SET
  used_quota = used_quota - (SELECT SUM(old_q-new_q) FROM calc_t WHERE calc_t.user_id = users.id),
  quota      = quota      + (SELECT SUM(old_q-new_q) FROM calc_t WHERE calc_t.user_id = users.id)
WHERE used_quota > 0
  AND EXISTS (SELECT 1 FROM calc_t WHERE calc_t.user_id = users.id);

UPDATE logs SET
  quota = (SELECT new_q FROM calc_t WHERE calc_t.id = logs.id),
  other = REPLACE(other, '"model_ratio":37.5',
          '"model_ratio":' || (SELECT ROUND(r,6) FROM calc_t WHERE calc_t.id = logs.id))
WHERE id IN (SELECT id FROM calc_t);
COMMIT;
SQLEOF
RC=$?
[ "$RC" = 0 ] || { echo "  [!!] 写入失败，事务已回滚"; exit 1; }

echo
echo "===== 改动后 ====="
sqlite3 -header -column "$DB" "
SELECT (SELECT COUNT(*) FROM logs WHERE type=2) AS 消费条数,
       ROUND((SELECT SUM(quota) FROM logs WHERE type=2)/500000.0,2) AS 日志合计美元,
       (SELECT COUNT(*) FROM logs WHERE type=2 AND other LIKE '%\"model_ratio\":37.5%') AS 残留兜底条数;"
sqlite3 -header -column "$DB" "SELECT id, username, quota AS 余额配额, used_quota AS 已用配额 FROM users;"
sqlite3 "$DB" "PRAGMA integrity_check;" | sed 's/^/  完整性: /'
