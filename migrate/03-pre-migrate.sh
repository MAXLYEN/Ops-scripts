#!/usr/bin/env bash
# 03-pre-migrate.sh — 迁移前冷快照
# VERSION: 2.0.1
# 2.0.1: 头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
#
# 在迁出机运行。停服 → 全量导出（不排除任何表）→ 打包关键路径。
#
# 为什么不用日常备份脚本：日常备份为"日常"设计，通常排除了大表以控制包体，
# 而迁移恰恰要把大表带走。
#
# 执行后服务处于停止状态，恢复方式见脚本末尾提示。
# ENV-REQUIRED: CONTAINER_DATA_DIRS DB_NAMES SNAPSHOT_ROOT

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env SNAPSHOT_ROOT DB_NAMES CONTAINER_DATA_DIRS
require_cmd tar gzip mysqldump docker
mysql_ready

TS=$(date -u +%Y%m%d%H%M%S)
DEST="$SNAPSHOT_ROOT/premigrate_$TS"
mkdir -p "$DEST" || die "无法创建 $DEST"

section "0. 确认"
echo "  即将停止所有容器、暂停备份任务、导出全部数据库。"
echo "  快照目标: $DEST"
confirm "服务会中断，继续？"

section "1. 记录现状"
docker ps -a --format '{{.Names}}' > "$DEST/containers.list"
while read -r n; do
  [ -n "$n" ] && docker inspect "$n" > "$DEST/inspect_${n}.json" 2>/dev/null
done < "$DEST/containers.list"
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' > "$DEST/images.list"
docker network ls > "$DEST/networks.list"
crontab -l > "$DEST/crontab.txt" 2>/dev/null
ufw status numbered > "$DEST/ufw.txt" 2>/dev/null
my -e "SHOW DATABASES" > "$DEST/databases.list"
[ -d "$PANEL_VHOST_DIR" ] && ls -1 "$PANEL_VHOST_DIR" > "$DEST/vhosts.list"
[ -d "$PANEL_CERT_DIR" ]  && ls -1 "$PANEL_CERT_DIR"  > "$DEST/certs.list"
ok "现状已记录"

section "2. 暂停备份任务"
# 加前缀而不是删除 —— 迁移后这些行会跟着 crontab 一起过去，
# 验收完去掉前缀即可，不用重新抄。
if [ -n "${BACKUP_SCRIPTS:-}" ]; then
  pat=$(echo "$BACKUP_SCRIPTS" | tr ' ' '|')
  if crontab -l 2>/dev/null | grep -qE "$pat"; then
    crontab -l | sed -E "s|^([^#].*($pat).*)$|#MIGRATE-PAUSED \1|" | crontab -
    ok "已暂停（恢复：去掉 #MIGRATE-PAUSED 前缀）"
  else
    log "crontab 里没有匹配的备份任务"
  fi
else
  log "未配置 BACKUP_SCRIPTS，跳过"
fi

section "3. 停容器"
RUNNING=$(docker ps -q)
if [ -n "$RUNNING" ]; then
  # shellcheck disable=SC2086
  docker stop $RUNNING >/dev/null || die "停容器失败"
  docker ps -a --format '  {{.Names}} {{.Status}}'
else
  log "没有运行中的容器"
fi
sleep 3

section "4. 全量导出数据库（不排除任何表）"
for db in $DB_NAMES; do
  db_exists "$db" || { warn "库不存在，跳过: $db"; continue; }
  log "导出 $db"
  mydump --no-tablespaces --single-transaction --quick \
         --routines --triggers --events --default-character-set=utf8mb4 \
         "$db" | gzip -6 > "$DEST/${db}.sql.gz"
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] || die "$db 导出失败"
  ok "$db  $(human "$DEST/${db}.sql.gz")"
  # 精确行数留档，迁移后逐表比对用
  for t in $(myq "SHOW TABLES FROM \`$db\`"); do
    printf '%s\t%s\n' "$t" "$(myq "SELECT COUNT(*) FROM \`$db\`.\`$t\`")"
  done > "$DEST/${db}.rowcount.txt"
done

section "5. 数据库账号授权"
# 面板类工具在迁移时可能按自己的记录重建账号，把 host 改掉。
# 有这份记录才能改回来。
: > "$DEST/grants.txt"
myq "SELECT CONCAT(\"'\",user,\"'@'\",host,\"'\") FROM mysql.user
     WHERE user NOT IN ('mysql.sys','mysql.session') ORDER BY user,host" \
  > /tmp/.ops_users.$$
while IFS= read -r u; do
  [ -z "$u" ] && continue
  printf -- '-- %s\n' "$u" >> "$DEST/grants.txt"
  myq "SHOW GRANTS FOR $u" 2>/dev/null | sed 's/$/;/' >> "$DEST/grants.txt"
  printf '\n' >> "$DEST/grants.txt"
done < /tmp/.ops_users.$$
rm -f /tmp/.ops_users.$$
ok "账号数 $(grep -c '^-- ' "$DEST/grants.txt")，其中含 ${DB_CLIENT_HOST} 的授权 $(grep -cF "$DB_CLIENT_HOST" "$DEST/grants.txt")"

section "6. 打包文件"
PATHS=""
for p in $CONTAINER_DATA_DIRS $EXTRA_SNAPSHOT_PATHS $BACKUP_PASS_FILES \
         "$MYSQL_DEFAULTS_FILE" "$PANEL_ROOT/vhost"; do
  [ -n "$p" ] && [ -e "$p" ] && PATHS="$PATHS $p"
done
[ -n "$PATHS" ] || die "没有任何可打包的路径，检查配置"
# shellcheck disable=SC2086
tar -czf "$DEST/files.tar.gz" --warning=no-file-changed $PATHS 2>>"$DEST/tar.log"
rc=$?; [ $rc -le 1 ] || die "打包失败 (rc=$rc)"
ok "files.tar.gz  $(human "$DEST/files.tar.gz")"

if [ -n "${PANEL_ROOT:-}" ] && [ -d "$PANEL_ROOT" ]; then
  tar -czf "$DEST/panel-extra.tar.gz" --warning=no-file-changed \
      "$WWWROOT" "$PANEL_ROOT/data" "$PANEL_ROOT/config" 2>/dev/null
  ok "panel-extra.tar.gz  $(human "$DEST/panel-extra.tar.gz")"
fi

section "7. 校验和"
sha_write "$DEST"
sha_check "$DEST" >/dev/null && ok "自校验通过" || warn "自校验未通过"

section 完成
echo "  快照: $DEST  ($(human "$DEST"))"
ls -lh "$DEST" | sed 's/^/  /'
cat <<EOF

  下一步：
    1. 把快照拉一份到本地   scp -P <端口> -r $DEST root@<你的机器>:./
    2. 迁移前确认带外控制台能进
    3. 恢复服务（若临时取消迁移）：
         docker start \$(docker ps -aq)
         crontab -l | sed 's/^#MIGRATE-PAUSED //' | crontab -
EOF
finish
