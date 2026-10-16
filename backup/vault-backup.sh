#!/usr/bin/env bash
# backup/vault-backup.sh — 只备份 Vaultwarden（库、数据目录、配置），加密上传；每小时一次
# VERSION: 1.0.1
# 1.0.1: mysql / mysqldump 优先用宝塔自带、与服务端同版本的客户端（公共库 bk_mysql_bin），不用 PATH 里可能被换成的 MariaDB 客户端。
# 1.0.0: 首版。由 vw-fullbackup 拆出：系统部分、Komari、SubConverter 归 hk-host-backup，本包只收 Vaultwarden 自己的东西（库只导 event 的结构）。
#        包名 vault_YYYYMMDD_HHMMSS.7z（UTC），本机 <BACKUP_LOCAL_ROOT>/vault，网盘 <BACKUP_CLOUD_ROOT>/vault，配 .sha256；分级保留见公共库 bk_tiers。
# ENV-REQUIRED: SVC_VW_DIR RCLONE_REMOTES BACKUP_PASS_FILE|VW_PASS_FILE
# 用法：vault-backup.sh [--local-only <目录>]
# 恢复前置机用 hk-host 包加本包：migrate/restore-from-backup.sh restore（不给包名就从网盘各取最新的一个）

set -uo pipefail
# --local-only：一键迁移（migrate/live-migrate）在旧机上现做包、经 SSH 直传新机。
# 不上传、不清理、不报心跳、不发告警：这份包不是例行备份
LOCAL_ONLY=""
case "${1:-}" in
    --local-only) LOCAL_ONLY=${2:-}; [ -n "$LOCAL_ONLY" ] || { echo "[FATAL] --local-only 后面要跟目录"; exit 1; } ;;
    "") ;;
    *) echo "[FATAL] 未知参数: $1（只认 --local-only <目录>）"; exit 1 ;;
esac
# 暂存区里是明文（库导出、rsa_key.pem），之后新建的目录一律 700、文件 600
umask 077

LIB_OK=0
# shellcheck disable=SC1091
{ . /usr/local/lib/ops-common.sh || . "$(dirname "$0")/../lib/common.sh"; } 2>/dev/null && LIB_OK=1

ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

PKG=vault
LOG_FILE="${VAULT_LOG_FILE:-/var/log/vault-backup.log}"
HB_URL="${VAULT_HEARTBEAT_URL:-${VW_HEARTBEAT_URL:-}}"   # Healthchecks 改名不换地址，旧键照用
BACKUP_PASS_FILE="${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}"
MAIL_TO="${MAIL_TO:-}"
WARNINGS=0

log()  { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '[%s] [WARN] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die()  { printf '[%s] [FATAL] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; hb /fail; notify "[FAIL] $*"; exit 1; }

# 告警：邮件三次 → webhook → 落盘，能通一条就算送达
notify() {
    local msg=$1 i sent=0
    [ -z "$LOCAL_ONLY" ] || return 0
    if [ -n "$MAIL_TO" ] && command -v msmtp >/dev/null 2>&1; then
        for i in 1 2 3; do
            printf 'To: %s\nSubject: [%s] %s 备份告警\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\n时间: %s UTC\n日志: %s\n\n%s\n' \
                "$MAIL_TO" "$(hostname)" "$PKG" "$msg" "$(date -u '+%F %T')" "$LOG_FILE" "$(tail -n 40 "$LOG_FILE" 2>/dev/null)" \
                | msmtp -t >/dev/null 2>&1 && { sent=1; break; }
            [ "$i" -lt 3 ] && sleep 20
        done
    fi
    if [ "$sent" -eq 0 ] && [ -n "${ALERT_WEBHOOK:-}" ]; then
        curl -fsS -m 10 -X POST --data-urlencode "text=[$(hostname)] $PKG: $msg" "$ALERT_WEBHOOK" >/dev/null 2>&1 && sent=1
    fi
    [ "$sent" -eq 1 ] || printf '[%s] [未送达] %s: %s\n' "$(date -u '+%F %T')" "$PKG" "$msg" \
        >> "${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
}
hb() {  # 心跳：/start 开始，空 成功，/fail 失败
    [ -z "$LOCAL_ONLY" ] && [ -n "$HB_URL" ] || return 0
    curl -fsS -m 10 --retry 3 "${HB_URL}${1:-}" >/dev/null 2>&1 || printf '[%s] [WARN] 心跳上报失败%s\n' "$(date -u '+%F %T')" "${1:-}" >> "$LOG_FILE"
}

for v in SVC_VW_DIR RCLONE_REMOTES BACKUP_PASS_FILE; do [ -n "${!v:-}" ] || die "配置项未填: $v（见 $ENV_FILE）"; done
[ "$LIB_OK" -eq 1 ] && declare -F bk_local_dir >/dev/null \
    || die "公共库缺失或版本过旧（需要 1.3.0 起），先运行 opsget -u"

VW_DIR="${SVC_VW_DIR%/}"
OUT_DIR="${LOCAL_ONLY:-$(bk_local_dir "$PKG")}"
[ -n "$LOCAL_ONLY" ] && BACKUP_DIRS="${BACKUP_DIRS:-} $LOCAL_ONLY"
TS="$(bk_stamp)"
NAME="${PKG}_${TS}"
ARCHIVE="$OUT_DIR/$NAME.7z"
STAGE="$OUT_DIR/.staging_$TS"
MYSQL_BIN="$(bk_mysql_bin mysql)"
MYSQLDUMP_BIN="$(bk_mysql_bin mysqldump)"

# 防重入：每小时一次，上一轮还在上传时两轮会同时清理同一批包
mkdir -p /run/lock
exec 9>"/run/lock/$PKG-backup.lock" || die "无法创建锁文件"
if [ -n "$LOCAL_ONLY" ]; then flock -w 7200 9 || die "等了 2 小时，上一轮备份还没结束"
else flock -n 9 || { log "上一轮备份还在运行，本次跳过"; exit 0; }; fi

log "========== 开始备份 $NAME =========="
hb /start
for c in tar 7z sha256sum; do command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"; done
[ -n "$LOCAL_ONLY" ] || command -v rclone >/dev/null 2>&1 || die "缺少依赖: rclone"
[ -r "$BACKUP_PASS_FILE" ] || die "密码文件不存在或不可读: $BACKUP_PASS_FILE"
PASS="$(head -n1 "$BACKUP_PASS_FILE")"
[ ${#PASS} -ge 16 ] || die "备份密码太短（<16 位），请换成长随机串"
[ -d "$VW_DIR/data" ] || die "没有 $VW_DIR/data"
mkdir -p "$STAGE/db" "$STAGE/vaultwarden" || die "无法创建暂存目录 $STAGE"
DBCNF=""
trap 'rm -rf "$STAGE" "$STAGE.pack"; [ -z "$DBCNF" ] || rm -f "$DBCNF"' EXIT

# 1. 数据库（连接串取自 vaultwarden.env，不另存密码）
VW_HIST=()
DBURL="$(grep -m1 '^DATABASE_URL=' "$VW_DIR/vaultwarden.env" 2>/dev/null | cut -d= -f2-)"
DBNAME=""
if [ -n "$DBURL" ]; then
    [ -x "$MYSQLDUMP_BIN" ] || die "找不到 mysqldump: $MYSQLDUMP_BIN"
    DBUSER="$(sed -E 's#^mysql://([^:]+):.*#\1#' <<<"$DBURL")"
    DBPASS="$(sed -E 's#^mysql://[^:]+:([^@]*)@.*#\1#' <<<"$DBURL")"
    DBHOST="$(sed -E 's#^mysql://[^@]+@([^:/]+).*#\1#' <<<"$DBURL")"
    DBNAME="$(sed -E 's#.*/([^/?]+)$#\1#' <<<"$DBURL")"
    [ "$DBHOST" = "host.docker.internal" ] && DBHOST="127.0.0.1"
    # 密码写进临时 option 文件，不上命令行。必须 --defaults-file（--defaults-extra-file 之后还会读
    # ~/.my.cnf，面板机上那里的 root 密码会把这里的覆盖掉）；先 !include 全局配置，password 放最后
    DBCNF="$(mktemp)" || die "mktemp 失败"
    esc=${DBPASS//\\/\\\\}; esc=${esc//\"/\\\"}
    { for f in /etc/my.cnf /etc/mysql/my.cnf; do [ -r "$f" ] && printf '!include %s\n' "$f"; done
      printf '[client]\npassword="%s"\n' "$esc"; } > "$DBCNF"
    my() { "$MYSQL_BIN" --defaults-file="$DBCNF" -h"$DBHOST" -u"$DBUSER" "$@"; }
    dump() { "$MYSQLDUMP_BIN" --defaults-file="$DBCNF" -h"$DBHOST" -u"$DBUSER" "$@"; }
    log "导出数据库 ${DBNAME}@${DBHOST}"
    # 历史表（event，清单在公共库 bk_history_default）只导结构
    mapfile -t VW_HIST < <(bk_history_pick "$DBNAME" \
        "$(my -N -B -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$DBNAME'" 2>/dev/null)")
    IGN=(); for t in "${VW_HIST[@]}"; do IGN+=("--ignore-table=$DBNAME.$t"); done
    if { dump --no-tablespaces --single-transaction --routines --default-character-set=utf8mb4 "${IGN[@]}" "$DBNAME" 2>>"$LOG_FILE" \
         && { [ "${#VW_HIST[@]}" -eq 0 ] \
              || dump --no-tablespaces --no-data --default-character-set=utf8mb4 "$DBNAME" "${VW_HIST[@]}" 2>>"$LOG_FILE"; }; } \
         | gzip > "$STAGE/db/$DBNAME.sql.gz"; then
        # 先读完整个流再判断（zcat | grep -q 会提前关管道，pipefail 下好 dump 反被判坏）
        n=$(zcat "$STAGE/db/$DBNAME.sql.gz" | grep -c '^CREATE TABLE')
        [ "${n:-0}" -gt 0 ] || die "数据库导出里没有任何表，不要信任这个 dump"
        case "$(zcat "$STAGE/db/$DBNAME.sql.gz" | tail -n 3)" in
            *"-- Dump completed"*) ;; *) warn "$DBNAME dump 末尾没有 'Dump completed' 标记，可能被截断" ;;
        esac
        log "  ✓ $DBNAME（$(du -h "$STAGE/db/$DBNAME.sql.gz" | cut -f1)，$n 张表${VW_HIST[0]:+；只导结构：${VW_HIST[*]}}）"
        my -N -B -e "SELECT CURRENT_USER(); SHOW GRANTS;" > "$STAGE/db/$DBNAME-grants.txt" 2>/dev/null \
            || warn "无法记录 $DBNAME 的授权信息"
    else
        die "mysqldump 失败"
    fi
else
    warn "vaultwarden.env 里没有 DATABASE_URL，跳过数据库导出（SQLite 部署的库在 data/ 里，照收）"
fi

# 2. 数据目录与配置。图标缓存、日志、临时文件可重建，不收
log "收集 Vaultwarden 数据"
tar cf - -C "$VW_DIR" --exclude='icon_cache' --exclude='*.log' --exclude='tmp' data 2>>"$LOG_FILE" \
    | tar xf - -C "$STAGE/vaultwarden" || die "Vaultwarden data 复制失败"
[ -f "$STAGE/vaultwarden/data/rsa_key.pem" ] || warn "rsa_key.pem 缺失！恢复后所有设备会被强制登出"
for f in vaultwarden.env compose.yaml; do
    [ -f "$VW_DIR/$f" ] && cp -a "$VW_DIR/$f" "$STAGE/vaultwarden/" || warn "缺少 $VW_DIR/$f"
done

# 3. 还原清单：恢复脚本按它放回（与 hk-host 包一起恢复时，账号由 hk-host 包建）
bk_init "$STAGE"
# shellcheck disable=SC2034  # 公共库读
BK_MYSQL="$MYSQL_BIN"
[ -n "$DBNAME" ] && bk_row "db/$DBNAME.sql.gz" - - mysql-db
for t in "${VW_HIST[@]}"; do bk_skip "mysql:$DBNAME.$t" "历史数据，只收表结构；恢复后从零开始记"; done
bk_link "$VW_DIR/data" vaultwarden/data
bk_link "$VW_DIR/vaultwarden.env" vaultwarden/vaultwarden.env
bk_link "$VW_DIR/compose.yaml" vaultwarden/compose.yaml && bk_row "$VW_DIR" - - compose-project
# 只记这个 compose 项目自己的容器
mapfile -t CTS < <(docker ps -a --filter "label=com.docker.compose.project.working_dir=$VW_DIR" --format '{{.Names}}' 2>/dev/null)
[ "${#CTS[@]}" -gt 0 ] || CTS=(vaultwarden)
bk_images "$STAGE/images.tsv" "${CTS[@]}"

{
    echo "包        : $NAME（vault：只有 Vaultwarden）"
    echo "备份时间  : $(date -u '+%F %T') UTC"
    echo "主机      : $(hostname)"
    echo "版本      : $(docker exec vaultwarden /vaultwarden --version 2>/dev/null || echo 未知)"
    echo "数据库    : ${DBNAME:-无}${VW_HIST[0]:+（只导结构：${VW_HIST[*]}）}"
    echo
    echo "恢复前置机要用 hk-host 包加本包（系统、MySQL 账号、nginx 与证书都在 hk-host 包里）："
    echo "  restore-from-backup.sh restore            # 从网盘各取最新的 hk-host 与 vault 包"
    echo "只回滚 Vaultwarden 的数据（机器还在）：restore-from-backup.sh restore <本包> --force"
    echo
    echo "---- 还原清单按类别 ----"
    grep -v '^#' "$BK_MANIFEST" | cut -f4 | sort | uniq -c
    echo
    echo "---- 内容校验和 ----"
    (cd "$STAGE" && find . -type f ! -name manifest.txt -exec sha256sum {} \; | sort -k2)
} > "$STAGE/manifest.txt" 2>&1
cat > "$STAGE/RESTORE.md" <<'EOF'
# vault 包：恢复 Vaultwarden

> 解压：`7z x vault_YYYYMMDD_HHMMSS.7z`（输备份密码），再 `tar xzf payload.tar.gz`。

## 自动恢复（推荐）
- 整台前置机：`restore-from-backup.sh restore <hk-host 包> <本包>`，或不给包名从网盘各取最新的。
  MySQL 账号、nginx、证书、面板都在 hk-host 包里；本包只有 Vaultwarden 自己。
- 机器还在、只回滚密码库：`restore-from-backup.sh restore <本包> --force`（原有的先留 .bak 再覆盖）。

## 手动恢复
1. 库：`zcat db/<库名>.sql.gz | mysql -uroot -p <库名>`（库和账号先建好，授权见 `db/<库名>-grants.txt`）。
   `event` 表只有结构，恢复后是空的，这是设计如此。
2. 数据：`cp -a rootfs/<SVC_VW_DIR>/. <SVC_VW_DIR>/`，然后在该目录 `docker compose up -d`。
   镜像按 `images.tsv` 里的 digest 拉，不要按标签拉 latest。
3. `rsa_key.pem` 在 data 里，老设备不会被强制登出。`data/config.json` 存在时会覆盖 env 里的 DOMAIN。
EOF

# 4. 打包：先 tar（保留属主），再 7z 加密（文件名一并加密）
log "打包加密"
mkdir -p "$STAGE.pack" || die "无法创建 $STAGE.pack"
tar czf "$STAGE.pack/payload.tar.gz" -C "$STAGE" . || die "tar 打包失败"
cp "$STAGE/manifest.txt" "$STAGE/RESTORE.md" "$STAGE.pack/"
rm -f "$ARCHIVE"
7z a -t7z -m0=lzma2 -mx=6 -mhe=on -p"$PASS" "$ARCHIVE" "$STAGE.pack"/* >/dev/null 2>>"$LOG_FILE" || die "7z 加密失败"
7z t -p"$PASS" "$ARCHIVE" >/dev/null 2>&1 </dev/null || die "加密包自检失败，不要信任这个备份"
(cd "$OUT_DIR" && sha256sum "$NAME.7z" > "$NAME.7z.sha256") || die "写不了 .sha256"
log "  ✓ $NAME.7z（$(du -h "$ARCHIVE" | cut -f1)），自检通过"

# 5. 上传与分级保留。有网盘失败就一个都不删：旧包可能是那个网盘上唯一完好的
if [ -n "$LOCAL_ONLY" ]; then
    log "只在本地生成（--local-only）：$ARCHIVE；不上传、不清理"
    log "========== 完成（$WARNINGS 条告警）=========="
    exit 0
fi
if bk_upload "$ARCHIVE" "$(bk_cloud_dir "$PKG")"; then
    bk_prune_all "$PKG"
else
    log "本次有网盘没传成功，跳过清理"
fi

if [ "$WARNINGS" -gt 0 ]; then
    hb /fail
    notify "备份完成但有 $WARNINGS 条告警，见 $LOG_FILE"
    log "========== 完成（$WARNINGS 条告警）=========="
    exit 1
fi
hb
log "========== 完成（0 告警）=========="
exit 0
