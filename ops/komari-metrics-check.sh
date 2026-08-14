#!/usr/bin/env bash
# ops/komari-metrics-check.sh — 指标库的保留期与增速体检
# VERSION: 2.0.0
# 2.0.0 变更：不再交互式输入用户名密码（会出现在 shell 历史与终端里），
#            改用 --defaults-file 读凭据；库名与预期保留期从 env.conf 取
#
# 回答四个问题：
#   A. 各指标的保留期设置对不对
#   B. 各分辨率档位实际存了多久的数据
#   C. 清理/汇总任务是不是在跑
#   D. 体积多大、日均涨多少、稳态会是多少
#
# ⚠️ 建库后的头一个保留期内，数据只涨不清是正常的 —— 还没有数据够格被清理。
#    别在这个阶段误判成保留策略失效。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
mysql_ready

DB="${METRICS_DB_NAME:-metrics}"
WANT="${METRICS_RETENTION_DAYS:-30}"
db_exists "$DB" || die "库不存在: $DB（在 env.conf 里设 METRICS_DB_NAME）"

section "A. 各指标的保留期设置（期望全为 $WANT）"
my -e "SELECT name AS 指标, type AS 类型, IFNULL(retention_days,'NULL') AS 保留天数
         FROM \`$DB\`.metric_definitions ORDER BY retention_days, name"
BAD=$(myq "SELECT COUNT(*) FROM \`$DB\`.metric_definitions
            WHERE retention_days IS NULL OR retention_days <> $WANT")
[ "${BAD:-0}" -eq 0 ] && ok "全部为 $WANT 天" || warn "有 $BAD 项不是 $WANT 天"

section "B. 分辨率档位与各档数据跨度"
my -e "SELECT CONCAT(r.resolution_milli/1000,'s') AS 档位,
              FORMAT(COUNT(*),0) AS 行数,
              FROM_UNIXTIME(MIN(m.bucket_milli)/1000) AS 最早,
              FROM_UNIXTIME(MAX(m.bucket_milli)/1000) AS 最新,
              ROUND((MAX(m.bucket_milli)-MIN(m.bucket_milli))/86400000,1) AS 跨度天
         FROM \`$DB\`.metric_rollups m
         JOIN \`$DB\`.metric_resolutions r ON r.id=m.resolution_id
        GROUP BY r.id ORDER BY r.resolution_milli"
echo "  判据：跨度稳定停在保留期那条线上不再往前推 = 清理在工作"

section "C. 清理/汇总任务状态"
my -e "SELECT state_key AS 任务, phase AS 阶段,
              FROM_UNIXTIME(updated_at_milli/1000) AS 更新于
         FROM \`$DB\`.metric_store_state"
echo "  空表不一定是故障 —— 有些版本只在实际清理时才写这张表"
echo "  更直接的判据是容器日志里的 'Metric retention cleanup deleted N rows'"

section "D. 体积与增速"
my -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) AS 总体积MB
         FROM information_schema.tables WHERE table_schema='$DB'"
my -e "SELECT ROUND(COUNT(*)/GREATEST((MAX(bucket_milli)-MIN(bucket_milli))/86400000,1),0) AS 行每天,
              ROUND(COUNT(*)/GREATEST((MAX(bucket_milli)-MIN(bucket_milli))/86400000,1)*$WANT/10000,1) AS 稳态万行
         FROM \`$DB\`.metric_rollups"

section 提示
cat <<EOF
  · 这个库**不进云端备份包**（时序数据，稳态可达 GB 级），
    完整备份由面板的数据库备份任务在本地保留
  · 迁移时若要保留历史，只能整库直传：
      mysqldump --defaults-file=... --no-tablespaces --single-transaction --quick $DB | gzip
  · 嫌大就把保留期调小；不迁历史也不影响 agent —— token 存在 SQLite 里
EOF
finish
