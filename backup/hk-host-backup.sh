#!/usr/bin/env bash
# backup/hk-host-backup.sh — 前置机整机备份：系统配置、面板、nginx 与证书、ufw、全部 MySQL 账号与业务库（Xboard 等）、
#                            Xboard 目录、Komari、SubConverter、站点；加密上传。每天一次
# VERSION: 1.0.0
# 1.0.0: 首版。由 vw-fullbackup 与 xboard-fullbackup 合并去重：系统部分只在这一个包里，Vaultwarden 归 vault-backup。
#        日志与历史数据只收表结构（公共库 bk_history_default、komari.db 的 logs / task_results）。不再带旧布局的副本（app/、nginx/、system/），恢复只认 rootfs。
#        包名 hk-host_YYYYMMDD_HHMMSS.7z（UTC），本机 <BACKUP_LOCAL_ROOT>/hk-host，网盘 <BACKUP_CLOUD_ROOT>/hk-host，配 .sha256。
# ENV-REQUIRED: RCLONE_REMOTES BACKUP_PASS_FILE|VW_PASS_FILE MYSQL_DEFAULTS_FILE
# 用法：hk-host-backup.sh [--local-only <目录>]
# 恢复前置机用本包加 vault 包：migrate/restore-from-backup.sh restore

set -uo pipefail
LOCAL_ONLY=""
case "${1:-}" in
    --local-only) LOCAL_ONLY=${2:-}; [ -n "$LOCAL_ONLY" ] || { echo "[FATAL] --local-only 后面要跟目录"; exit 1; } ;;
    "") ;;
    *) echo "[FATAL] 未知参数: $1（只认 --local-only <目录>）"; exit 1 ;;
esac
# 暂存区里是明文（库导出、证书私钥、凭据文件），之后新建的目录一律 700、文件 600
umask 077

LIB_OK=0
# shellcheck disable=SC1091
{ . /usr/local/lib/ops-common.sh || . "$(dirname "$0")/../lib/common.sh"; } 2>/dev/null && LIB_OK=1

ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

PKG=hk-host
LOG_FILE="${HKHOST_LOG_FILE:-/var/log/hk-host-backup.log}"
HB_URL="${HKHOST_HEARTBEAT_URL:-${XBOARD_HEARTBEAT_URL:-}}"   # Healthchecks 改名不换地址，旧键照用
BACKUP_PASS_FILE="${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}"
MAIL_TO="${MAIL_TO:-}"
WARNINGS=0

log()  { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '[%s] [WARN] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die()  { printf '[%s] [FATAL] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG_FILE"; hb /fail; notify "[FAIL] $*"; exit 1; }

notify() {  # 邮件三次 → webhook → 落盘
    local msg=$1 i sent=0
    [ -z "$LOCAL_ONLY" ] || return 0
    if [ -n "$MAIL_TO" ] && command -v msmtp >/dev/null 2>&1; then
        for i in 1 2 3; do
            printf 'To: %s\nSubject: [%s] %s 备份告警\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\n时间: %s UTC\n日志: %s\n\n%s\n' \
                "$MAIL_TO" "$(hostname)" "$PKG" "$msg" "$(date -u '+%F %T')" "$LOG_FILE" "$(tail -n 60 "$LOG_FILE" 2>/dev/null)" \
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
hb() {
    [ -z "$LOCAL_ONLY" ] && [ -n "$HB_URL" ] || return 0
    curl -fsS -m 10 --retry 3 "${HB_URL}${1:-}" >/dev/null 2>&1 || printf '[%s] [WARN] 心跳上报失败%s\n' "$(date -u '+%F %T')" "${1:-}" >> "$LOG_FILE"
}

for v in RCLONE_REMOTES BACKUP_PASS_FILE MYSQL_DEFAULTS_FILE; do [ -n "${!v:-}" ] || die "配置项未填: $v（见 $ENV_FILE）"; done
[ "$LIB_OK" -eq 1 ] && declare -F bk_local_dir >/dev/null \
    || die "公共库缺失或版本过旧（需要 1.3.0 起），先运行 opsget -u"

OUT_DIR="${LOCAL_ONLY:-$(bk_local_dir "$PKG")}"
[ -n "$LOCAL_ONLY" ] && BACKUP_DIRS="${BACKUP_DIRS:-} $LOCAL_ONLY"
TS="$(bk_stamp)"
NAME="${PKG}_${TS}"
ARCHIVE="$OUT_DIR/$NAME.7z"
STAGE="$OUT_DIR/.staging_$TS"
XBOARD_DIR="${SVC_XBOARD_DIR:+${SVC_XBOARD_DIR%/}}"
VW_DIR="${SVC_VW_DIR:+${SVC_VW_DIR%/}}"
KOMARI_DATA="${SVC_KOMARI_DATA:+${SVC_KOMARI_DATA%/}}"
KOMARI_EXTRA="${SVC_KOMARI_EXTRA:-}"
SUBCONV_DIR="${SVC_SUBCONV_DIR:+${SVC_SUBCONV_DIR%/}}"
# shellcheck disable=SC2034  # 公共库读
BK_MYSQL="$(command -v mysql || echo /www/server/mysql/bin/mysql)"
# shellcheck disable=SC2034
BK_MYSQLDUMP="$(command -v mysqldump || echo /www/server/mysql/bin/mysqldump)"

mkdir -p /run/lock
exec 9>"/run/lock/$PKG-backup.lock" || die "无法创建锁文件"
if [ -n "$LOCAL_ONLY" ]; then flock -w 7200 9 || die "等了 2 小时，上一轮备份还没结束"
else flock -n 9 || { log "上一轮备份还在运行，本次跳过"; exit 0; }; fi

log "========== 开始备份 $NAME =========="
hb /start
for c in tar 7z sha256sum sqlite3; do command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"; done
[ -n "$LOCAL_ONLY" ] || command -v rclone >/dev/null 2>&1 || die "缺少依赖: rclone"
[ -r "$BACKUP_PASS_FILE" ] || die "密码文件不存在或不可读: $BACKUP_PASS_FILE"
PASS="$(head -n1 "$BACKUP_PASS_FILE")"
[ ${#PASS} -ge 16 ] || die "备份密码太短（<16 位），请换成长随机串"
# 整机包：全部账号与业务库靠 root 凭据导出，连不上就没有意义
bk_mysql_ready || die "MYSQL_DEFAULTS_FILE 连不上 MySQL，整机包缺了账号与业务库就不完整"
if [ -n "$XBOARD_DIR" ]; then
    # .env 里的 APP_KEY 丢了，Xboard 库里的加密字段全部解不开
    grep -q '^APP_KEY=.\+' "$XBOARD_DIR/.env" 2>/dev/null || die "$XBOARD_DIR/.env 不存在或没有 APP_KEY"
fi
mkdir -p "$STAGE/komari" || die "无法创建暂存目录 $STAGE"
trap 'rm -rf "$STAGE" "$STAGE.pack"' EXIT

bk_init "$STAGE"

# 1. Vaultwarden 不在本包（归 vault 包）：它的库、目录、容器都排除
VW_DB=vaultwarden
if [ -n "$VW_DIR" ]; then
    u=$(grep -m1 '^DATABASE_URL=' "$VW_DIR/vaultwarden.env" 2>/dev/null | cut -d= -f2-)
    [ -n "$u" ] && VW_DB=$(sed -E 's#.*/([^/?]+)$#\1#' <<<"$u")
    VW_CTS=$(docker ps -a --filter "label=com.docker.compose.project.working_dir=$VW_DIR" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    BACKUP_IGNORE_CONTAINERS="${BACKUP_IGNORE_CONTAINERS:-} ${VW_CTS:-vaultwarden}"
    bk_skip "$VW_DIR" "Vaultwarden 在 vault 包里（每小时一次）"
    bk_skip "mysql:$VW_DB" "Vaultwarden 的库在 vault 包里"
fi

# 2. Xboard：整个目录原样放回（含 .env、compose、容器数据、主题、插件），框架日志不收；库在下面随全部业务库导出
if [ -n "$XBOARD_DIR" ]; then
    log "收集 Xboard 目录 $XBOARD_DIR"
    bk_dir "$XBOARD_DIR" "$XBOARD_DIR/storage/logs" || die "Xboard 目录收进 rootfs 失败"
    for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        [ -f "$XBOARD_DIR/$f" ] || continue
        bk_row "$XBOARD_DIR/$f" "$(stat -c %a "$XBOARD_DIR/$f")" "$(bk_owner "$XBOARD_DIR/$f")" file
        bk_row "$XBOARD_DIR" - - compose-project
    done
    bk_skip "$XBOARD_DIR/storage/logs" "Xboard 框架日志"
fi
bk_opt /root/deploy
bk_opt /etc/xboard-toolkit.conf

# 3. Komari：.backup 一致性副本（直接 cp 会丢 WAL 里的近期数据），历史在副本上清空
if [ -n "$KOMARI_DATA" ] && [ -f "$KOMARI_DATA/komari.db" ]; then
    sqlite3 "$KOMARI_DATA/komari.db" ".backup '$STAGE/komari/komari.db'" || die "komari.db 备份失败"
    sqlite3 "$STAGE/komari/komari.db" "PRAGMA integrity_check;" | head -1 | grep -q '^ok$' || die "komari.db 完整性校验未通过"
    bk_sqlite_strip "$STAGE/komari/komari.db" komari.db logs task_results
    bk_link "$KOMARI_DATA/komari.db" komari/komari.db sqlite
    for d in plugin plugin-data; do bk_opt "$KOMARI_DATA/$d"; done
    [ -d "$KOMARI_DATA/theme" ] && bk_skip "$KOMARI_DATA/theme" "Komari 主题，面板里可重新下载：$(ls "$KOMARI_DATA/theme" | tr '\n' ' ')"
    KOMARI_DIR=$(dirname "$KOMARI_DATA")
    for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        [ -f "$KOMARI_DIR/$f" ] && bk_file "$KOMARI_DIR/$f" && bk_row "$KOMARI_DIR" - - compose-project
    done
    log "  ✓ komari.db（$(du -h "$STAGE/komari/komari.db" | cut -f1)）"
elif [ -n "$KOMARI_DATA" ]; then
    warn "没有 $KOMARI_DATA/komari.db"
fi
[ -n "$KOMARI_EXTRA" ] && bk_opt "$KOMARI_EXTRA/auto-discovery.json"

# 4. SubConverter：pref.toml 是全部自定义配置的唯一载体
if [ -n "$SUBCONV_DIR" ]; then
    if [ -d "$SUBCONV_DIR" ]; then
        bk_dir "$SUBCONV_DIR" || warn "SubConverter 目录收进 rootfs 失败"
        for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
            [ -f "$SUBCONV_DIR/$f" ] && bk_row "$SUBCONV_DIR" - - compose-project
        done
    else
        warn "没有 SubConverter 目录 $SUBCONV_DIR"
    fi
fi

# 5. 系统：SSH、ufw、fail2ban、面板（程序配置、站点、证书、项目）、nginx、crontab、systemd 单元、凭据文件……
log "收集系统配置"
bk_system
bk_mysql_users db/mysql-users.sql
# 全部业务库（Xboard 等），历史表只导结构；Vaultwarden 的库在 vault 包，指标库按方案只留本地
bk_mysql_dbs "$VW_DB" "${METRICS_DB_NAME:-metrics}"
bk_compose_projects
CTS=()
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    case " ${VW_CTS:-} " in *" $c "*) ;; *) CTS+=("$c") ;; esac
done
[ "${#CTS[@]}" -eq 0 ] || bk_images "$STAGE/images.tsv" "${CTS[@]}"
[ -f "$STAGE/images.tsv" ] || printf '# container\timage\trepo_digest\n' > "$STAGE/images.tsv"
rm -rf "$STAGE/komari"   # 已硬链接进 rootfs
log "  ✓ rootfs $(du -sh "$STAGE/rootfs" | cut -f1)，还原清单 $(grep -vc '^#' "$BK_MANIFEST") 项，未进包 $(wc -l < "$BK_SKIPPED") 项"

{
    echo "包        : $NAME（hk-host：前置机整机，不含 Vaultwarden）"
    echo "备份时间  : $(date -u '+%F %T') UTC"
    echo "主机      : $(hostname)"
    echo "系统      : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")，内核 $(uname -r)"
    echo
    echo "恢复前置机：restore-from-backup.sh restore（不给包名就从网盘各取最新的 hk-host 与 vault 包）"
    echo
    echo "---- 容器 ----"
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    echo
    echo "---- 业务库 ----"
    (cd "$STAGE" && ls db/ 2>/dev/null)
    echo
    echo "---- 还原清单按类别 ----"
    grep -v '^#' "$BK_MANIFEST" | cut -f4 | sort | uniq -c
    echo "未进包的项与原因见 system/rootfs-skipped.txt（历史表、日志、Vaultwarden、解密密码……）"
    echo
    echo "---- 内容校验和 ----"
    (cd "$STAGE" && find . -type f ! -name manifest.txt ! -path './rootfs/*' -exec sha256sum {} \; | sort -k2)
} > "$STAGE/manifest.txt" 2>&1
cat > "$STAGE/RESTORE.md" <<'EOF'
# hk-host 包：恢复前置机

> 解压：`7z x hk-host_YYYYMMDD_HHMMSS.7z`（输备份密码），再 `tar --same-owner -xzf payload.tar.gz`。
> 完整步骤见仓库 docs/disaster-recovery.md。

## 自动恢复
在装好系统、面板与 docker 的新机上：`restore-from-backup.sh restore <本包> <vault 包>`
（不给包名就从网盘各取最新的一个）。按 `restore-manifest.tsv` 放回配置、建账号、导入库、
按 `images.tsv` 的 digest 拉镜像并启动 compose 项目、启用 systemd 单元、合并 crontab。
没进包的东西和原因见 `system/rootfs-skipped.txt`。

## 要知道的
- 历史数据只有表结构：Xboard 的日志、统计、机器负载曲线，Komari 的事件日志等恢复后从零开始，这是设计如此。
- Xboard：`.env` 里的 APP_KEY 必须和库配套；**不要跑 `xboard:install`**（会重新生成 APP_KEY、清空库）；
  镜像按 digest 拉，不要按标签拉 latest（启动时的 migration 会改掉按旧版结构恢复的库）。
- 面板域名不变的话，Xboard 各节点、Komari 被控端会自己重连。
- 证书文件能用 ≠ 会自动续期：恢复后在面板里确认续期任务还在。
EOF

log "打包加密"
mkdir -p "$STAGE.pack" || die "无法创建 $STAGE.pack"
tar czf "$STAGE.pack/payload.tar.gz" -C "$STAGE" . || die "tar 打包失败"
cp "$STAGE/manifest.txt" "$STAGE/RESTORE.md" "$STAGE.pack/"
rm -f "$ARCHIVE"
7z a -t7z -m0=lzma2 -mx=6 -mhe=on -p"$PASS" "$ARCHIVE" "$STAGE.pack"/* >/dev/null 2>>"$LOG_FILE" || die "7z 加密失败"
7z t -p"$PASS" "$ARCHIVE" >/dev/null 2>&1 </dev/null || die "加密包自检失败，不要信任这个备份"
(cd "$OUT_DIR" && sha256sum "$NAME.7z" > "$NAME.7z.sha256") || die "写不了 .sha256"
log "  ✓ $NAME.7z（$(du -h "$ARCHIVE" | cut -f1)），自检通过"

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
