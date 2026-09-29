#!/bin/bash
# backup/vw-fullbackup.sh — 备份 Vaultwarden、Komari、SubConverter 与系统配置
# VERSION: 2.6.0
# 2.6.0: 新增 --local-only <目录>：包只写到该目录，不上传、不清理、不报心跳、不发告警；上一轮还在跑就等它结束（一键迁移现做包用）。
# 2.5.0: 新增 rootfs/ 与 restore-manifest.tsv（系统配置、全部 MySQL 账号与业务库、镜像 digest），改为 GFS 分级保留，防重入锁。
# ENV-REQUIRED: VW_BACKUP_DIR BACKUP_PASS_FILE|VW_PASS_FILE VW_REMOTE_PATH RCLONE_REMOTES SVC_VW_DIR PANEL_VHOST_DIR PANEL_CERT_DIR DB_CLIENT_HOST DOCKER_CIDR
# 定时任务调用已安装的本地脚本，密码从配置文件指定的文件读取。
# 用法：vw-fullbackup.sh [--local-only <目录>]

set -o pipefail
# --local-only：一键迁移（migrate/live-migrate）在旧机上现做包、经 SSH 直传新机。
# 不上传、不清理：这份包不是例行备份，不该挤掉网盘上的旧包；不报心跳：心跳的意思是「例行备份已上云」
LOCAL_ONLY=""
case "${1:-}" in
    --local-only) LOCAL_ONLY=${2:-}; [ -n "$LOCAL_ONLY" ] || { echo "[FATAL] --local-only 后面要跟目录"; exit 1; } ;;
    "") ;;
    *) echo "[FATAL] 未知参数: $1（只认 --local-only <目录>）"; exit 1 ;;
esac
# 暂存区里是明文：数据库 dump、容器 inspect（含环境变量里的密钥）、证书私钥、
# 打包好的 payload.tar.gz。默认 umask 022 下它们是 644、目录 755，备份窗口内
# 本机任何用户（例如面板上以 www 运行的站点）都能读到。之后新建的目录一律 700、
# 文件 600；成品 7z 也随之变为 600，不影响 root 执行的上传与还原。
umask 077

# 公共库：rootfs 采集、还原清单、分级保留。opsget -i 安装本脚本时会同步到同一版本。
# 先加载，下面本脚本自己的 log / warn / die 会覆盖库里的同名函数。
LIB_OK=0
# shellcheck disable=SC1091
{ . /usr/local/lib/ops-common.sh || . "$(dirname "$0")/../lib/common.sh"; } 2>/dev/null && LIB_OK=1

# 配置（全部来自 env.conf，本文件不含任何域名/路径硬编码）
ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

# 缺配置直接退出，绝不回落到某个"看起来合理"的默认值 —— 用错的值静默跑完比报错危险
req() { local m=""; for v in "$@"; do [ -n "${!v:-}" ] || m="$m $v"; done
        [ -z "$m" ] || { echo "[FATAL] 配置项未填:$m（见 $ENV_FILE）"; exit 1; }; }
req VW_BACKUP_DIR VW_REMOTE_PATH RCLONE_REMOTES \
    SVC_VW_DIR PANEL_VHOST_DIR PANEL_CERT_DIR DB_CLIENT_HOST DOCKER_CIDR

STAGE_ROOT="$VW_BACKUP_DIR"
OUT_DIR="$STAGE_ROOT"
# 本地模式的包放到指定目录；这个目录也不进包（bk_init 把 BACKUP_DIRS 当成落盘目录排除）
[ -n "$LOCAL_ONLY" ] && { OUT_DIR="$LOCAL_ONLY"; BACKUP_DIRS="${BACKUP_DIRS:-} $LOCAL_ONLY"; }
LOG_FILE="${VW_LOG_FILE:-/var/log/vw-fullbackup.log}"
# 新键优先、旧键回落 —— 现有机器的 env.conf 一个字不用动
BACKUP_PASS_FILE="${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}"
req BACKUP_PASS_FILE
PASS_FILE="$BACKUP_PASS_FILE"
# 分级保留：全留 / 每天一份 / 每周一份 / 每月一份直到上限（本地与云端上限不同）
KEEP_ALL_DAYS="${BACKUP_KEEP_ALL_DAYS:-7}"
KEEP_DAILY_DAYS="${BACKUP_KEEP_DAILY_DAYS:-30}"
KEEP_WEEKLY_DAYS="${BACKUP_KEEP_WEEKLY_DAYS:-90}"
KEEP_LOCAL_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-180}"
KEEP_CLOUD_DAYS="${BACKUP_KEEP_CLOUD_DAYS:-400}"
# 远端由「远端名列表 × 目录名」组合，换云盘或改目录只动 env.conf
REMOTES=(); for r in $RCLONE_REMOTES; do REMOTES+=("${r}:${VW_REMOTE_PATH}"); done
[ -n "$LOCAL_ONLY" ] && REMOTES=()
MAIL_TO="${MAIL_TO:-}"

VW_DIR="$SVC_VW_DIR"
KOMARI_DATA="${SVC_KOMARI_DATA:-}"
KOMARI_EXTRA="${SVC_KOMARI_EXTRA:-}"
SUBCONV_DIR="${SVC_SUBCONV_DIR:-}"
BT_VHOST="$PANEL_VHOST_DIR"
BT_CERT="$PANEL_CERT_DIR"
# 大库的本地 dump 由面板计划任务产出，本脚本只记录状态、不搬运
METRICS_DIR="${PANEL_DB_BACKUP_DIR:+${PANEL_DB_BACKUP_DIR}/metrics}"
MYSQL_BIN="$(command -v mysql || echo /www/server/mysql/bin/mysql)"
MYSQLDUMP_BIN="$(command -v mysqldump || echo /www/server/mysql/bin/mysqldump)"

TS="$(date +%Y%m%d_%H%M%S)"
NAME="srvbak_${TS}"
STAGE="${STAGE_ROOT}/.staging_${TS}"
ARCHIVE="${OUT_DIR}/${NAME}.7z"

WARNINGS=0
# 工具函数
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
warn() { WARNINGS=$((WARNINGS+1)); echo "[$(date '+%F %T')] [WARN] $*" | tee -a "$LOG_FILE"; }
die()  { echo "[$(date '+%F %T')] [FATAL] $*" | tee -a "$LOG_FILE"; hb /fail; notify "备份失败: $*"; rm -rf "$STAGE"; exit 1; }

# 失败告警。三条路依次尝试，能通一条就算送达。
# 为什么要重试：SMTP 的瞬时失败（DNS 拿到不可达的 AAAA、NAT 网关抖动）
# 会让告警**直接消失**，而告警消失正是这套系统最怕的那类故障。
notify() {
    local msg="$1" i sent=0
    [ -z "$LOCAL_ONLY" ] || return 0     # 本地模式由调用方看退出码和输出
    if [ -n "$MAIL_TO" ] && command -v msmtp >/dev/null 2>&1; then
        for i in 1 2 3; do
            printf 'To: %s\nSubject: [%s] 备份告警\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\n主机: %s\n时间: %s\n日志: %s\n' \
                "$MAIL_TO" "$(hostname)" "$msg" "$(hostname)" "$(date '+%F %T')" "$LOG_FILE" \
                | msmtp -t >>"$LOG_FILE" 2>&1 && { sent=1; break; }
            echo "[$(date '+%F %T')] [WARN] 告警邮件第 $i 次发送失败" >> "$LOG_FILE"
            [ "$i" -lt 3 ] && sleep 20
        done
    fi
    # webhook 兜底（Server酱 / TG Bot 等），配了才走
    if [ "$sent" -eq 0 ] && [ -n "${ALERT_WEBHOOK:-}" ]; then
        curl -fsS -m 10 -X POST --data-urlencode "text=[$(hostname)] $msg" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 && sent=1
    fi
    # 落盘兜底：一封都发不出去时至少留痕，别让告警彻底消失
    if [ "$sent" -eq 0 ]; then
        printf '[%s] [未送达] %s\n' "$(date '+%F %T')" "$msg" \
            >> "${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
        echo "[$(date '+%F %T')] [WARN] 告警三次均未送达，已写入 ${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}" >> "$LOG_FILE"
    fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }

# 反向监控心跳。留空则整个机制跳过，脚本行为不变。
#   hb /start  开始    hb  成功    hb /fail  失败
# 用 --retry：心跳本身也走出网，而出网正是可能抖动的那一环。
hb() {
    [ -z "$LOCAL_ONLY" ] || return 0
    [ -n "${VW_HEARTBEAT_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 "${VW_HEARTBEAT_URL}${1:-}" >/dev/null 2>&1 \
        || echo "[$(date '+%F %T')] [WARN] 心跳上报失败${1:-}" >> "$LOG_FILE"
}

# 防重入：每 6 小时一次时，上一轮若因上传慢还没结束，两轮会同时清理同一批包。
# 撞上就直接退出、不报心跳：偶尔一次无妨，一直撞上时由心跳监控发现「没按时完成」。
mkdir -p /run/lock
exec 9>/run/lock/vw-fullbackup.lock || die "无法创建锁文件 /run/lock/vw-fullbackup.lock"
# 本地模式是有人等着要包：等上一轮跑完（它也可能正卡在上传），而不是跳过
if [ -n "$LOCAL_ONLY" ]; then
    flock -w 7200 9 || die "等了 2 小时，上一轮备份还没结束"
else
    flock -n 9 || { log "上一轮备份还在运行，本次跳过"; exit 0; }
fi

# 前置检查
log "========== 开始备份 ${NAME} =========="
hb /start
[ "$LIB_OK" -eq 1 ] && declare -F bk_gfs_select >/dev/null \
    || die "公共库缺失或版本过旧（需要 1.2.0 起，含 bk_* 函数），先运行 opsget -u"
need tar; need 7z; need rclone; need sqlite3
[ -r "$PASS_FILE" ] || die "密码文件不存在或不可读: $PASS_FILE"
PASS="$(head -n1 "$PASS_FILE")"
[ -n "$PASS" ] || die "密码文件为空"
[ ${#PASS} -ge 16 ] || die "备份密码太短（<16 位），请换成长随机串"
[ -x "$MYSQLDUMP_BIN" ] || die "找不到 mysqldump: $MYSQLDUMP_BIN"

mkdir -p "$STAGE"/{db,vaultwarden,komari,subconverter,system} "$OUT_DIR" || die "无法创建暂存目录"
trap 'rm -rf "$STAGE"' EXIT

# 1. Vaultwarden 数据库
# 直接从 env 解析连接串，不重复保存密码
DBURL="$(grep -m1 '^DATABASE_URL=' "$VW_DIR/vaultwarden.env" 2>/dev/null | cut -d= -f2-)"
if [ -n "$DBURL" ]; then
    DBUSER="$(echo "$DBURL" | sed -E 's#^mysql://([^:]+):.*#\1#')"
    DBPASS="$(echo "$DBURL" | sed -E 's#^mysql://[^:]+:([^@]*)@.*#\1#')"
    DBHOST="$(echo "$DBURL" | sed -E 's#^mysql://[^@]+@([^:/]+).*#\1#')"
    DBNAME="$(echo "$DBURL" | sed -E 's#.*/([^/?]+)$#\1#')"
    [ "$DBHOST" = "host.docker.internal" ] && DBHOST="127.0.0.1"
    # 密码写进临时 option 文件（mktemp 建出即 600），不用 -p —— 命令行参数
    # 同机任何用户都能从 /proc/*/cmdline 读到。
    # 必须用 --defaults-file 而不是 --defaults-extra-file：后者之后还会读
    # ~/.my.cnf，面板机上那里常有 [client] 的 root 密码，会把这里的覆盖掉
    # （2.3.4 即因此 Access denied）。--defaults-file 只读这一个文件，所以
    # 先 !include 全局配置保留 [mysqldump] 等设置，password 放最后才能生效。
    # 值加双引号，密码里的 # 才不会被当成注释截断；\ 和 " 按 option 文件规则转义。
    DBCNF="$(mktemp)" || die "mktemp 失败"
    trap 'rm -rf "$STAGE"; rm -f "$DBCNF"' EXIT
    esc=${DBPASS//\\/\\\\}; esc=${esc//\"/\\\"}
    { for f in /etc/my.cnf /etc/mysql/my.cnf; do [ -r "$f" ] && printf '!include %s\n' "$f"; done
      printf '[client]\npassword="%s"\n' "$esc"; } > "$DBCNF"
    log "导出数据库 ${DBNAME}@${DBHOST} ..."
    if "$MYSQLDUMP_BIN" --defaults-file="$DBCNF" -h"$DBHOST" -u"$DBUSER" \
         --no-tablespaces --single-transaction --routines \
         --default-character-set=utf8mb4 "$DBNAME" 2>>"$LOG_FILE" \
         | gzip > "$STAGE/db/${DBNAME}.sql.gz"; then
        SZ=$(du -h "$STAGE/db/${DBNAME}.sql.gz" | cut -f1)
        # 不能只看 -s：gzip 压缩空输入也有 20 字节头，文件永远非空。要看解压后的内容。
        # 都先读完整个流再判断 —— zcat | grep -q 会在命中后提前关管道，zcat 吃
        # SIGPIPE，pipefail 下整条管道算失败，好的 dump 反被判坏。
        TABLES=$(zcat "$STAGE/db/${DBNAME}.sql.gz" | grep -c '^CREATE TABLE')
        [ "${TABLES:-0}" -gt 0 ] || die "数据库导出里没有任何表（${SZ}），不要信任这个 dump"
        TAIL=$(zcat "$STAGE/db/${DBNAME}.sql.gz" | tail -n 3)
        case "$TAIL" in
            *"-- Dump completed"*) ;;
            *) warn "${DBNAME} dump 末尾没有 'Dump completed' 标记，文件可能被截断" ;;
        esac
        log "  ✓ ${DBNAME} dump 完成 (${SZ}，${TABLES} 张表)"
        # 记录账号授权（还原时要照着重建用户，host 段错了容器就连不上）
        "$MYSQL_BIN" --defaults-file="$DBCNF" -h"$DBHOST" -u"$DBUSER" -N -B \
            -e "SELECT CURRENT_USER(); SHOW GRANTS;" > "$STAGE/db/${DBNAME}-grants.txt" 2>/dev/null \
            || warn "无法记录 ${DBNAME} 的授权信息"
    else
        die "mysqldump 失败"
    fi
else
    warn "未找到 DATABASE_URL，跳过数据库导出"
fi

# 大库按方案不进云端包，仅在此记录其本地备份状态
if [ -n "$METRICS_DIR" ] && ls "$METRICS_DIR"/*.sql.gz >/dev/null 2>&1; then
    LATEST_METRICS="$(ls -t "$METRICS_DIR"/*.sql.gz | head -1)"
    log "  i metrics 本地最新备份: $(basename "$LATEST_METRICS") ($(du -h "$LATEST_METRICS" | cut -f1)) —— 按方案不上云"
elif [ -n "$METRICS_DIR" ]; then
    warn "未找到 metrics 的本地备份，检查面板的数据库备份任务（可用 opsget ops/panel-cron-inspect 手动触发一次）"
fi

# 2. Vaultwarden 数据与配置
log "收集 Vaultwarden 数据 ..."
tar cf - -C "$VW_DIR" --exclude='icon_cache' --exclude='*.log' --exclude='tmp' data 2>/dev/null \
    | tar xf - -C "$STAGE/vaultwarden" || warn "Vaultwarden data 复制异常"
[ -f "$STAGE/vaultwarden/data/rsa_key.pem" ] || warn "rsa_key.pem 缺失！设备会被强制登出"
for f in vaultwarden.env compose.yaml; do
    [ -f "$VW_DIR/$f" ] && cp -a "$VW_DIR/$f" "$STAGE/vaultwarden/" || warn "缺少 $f"
done

# 3. Komari
log "收集 Komari 数据 ..."
if [ -n "$KOMARI_DATA" ] && [ -f "$KOMARI_DATA/komari.db" ]; then
    # 必须用 .backup，直接 cp 会丢 WAL 里的近期数据
    sqlite3 "$KOMARI_DATA/komari.db" ".backup '$STAGE/komari/komari.db'" \
        || die "komari.db 备份失败"
    sqlite3 "$STAGE/komari/komari.db" "PRAGMA integrity_check;" | head -1 | grep -q '^ok$' \
        || die "komari.db 完整性校验未通过"
    log "  ✓ komari.db ($(du -h "$STAGE/komari/komari.db" | cut -f1))"
else
    warn "未找到 komari.db"
fi
# 排除 backup/(备份的备份) 和 theme/(可重新下载)
for d in plugin plugin-data; do
    [ -n "$KOMARI_DATA" ] && [ -d "$KOMARI_DATA/$d" ] && cp -a "$KOMARI_DATA/$d" "$STAGE/komari/"
done
[ -n "$KOMARI_EXTRA" ] && [ -f "$KOMARI_EXTRA/auto-discovery.json" ] && cp -a "$KOMARI_EXTRA/auto-discovery.json" "$STAGE/komari/"
[ -n "$KOMARI_DATA" ] && [ -d "$KOMARI_DATA/theme" ] && ls "$KOMARI_DATA/theme" > "$STAGE/komari/theme-list.txt"
[ -n "$KOMARI_DATA" ] && [ -f "$(dirname "$KOMARI_DATA")/compose.yaml" ] && cp -a "$(dirname "$KOMARI_DATA")/compose.yaml" "$STAGE/komari/"

# 4. SubConverter
log "收集 SubConverter 配置 ..."
if [ -n "$SUBCONV_DIR" ] && [ -d "$SUBCONV_DIR" ]; then
    cp -a "$SUBCONV_DIR/." "$STAGE/subconverter/" 2>/dev/null || warn "SubConverter 复制异常"
else
    warn "未找到 SubConverter 目录: ${SUBCONV_DIR:-未配置}"
fi

# 5. 系统配置
log "收集系统配置 ..."
mkdir -p "$STAGE/system"/{nginx,cert,docker}
cp -a "$BT_VHOST"/*.conf "$STAGE/system/nginx/" 2>/dev/null || warn "站点配置复制异常"
cp -a "$BT_CERT"/. "$STAGE/system/cert/" 2>/dev/null || warn "证书复制异常"
[ -f /root/.config/rclone/rclone.conf ] && cp -a /root/.config/rclone/rclone.conf "$STAGE/system/"
crontab -l > "$STAGE/system/crontab.txt" 2>/dev/null
cp -a "$0" "$STAGE/system/" 2>/dev/null
# 配置本身也进包：换机器时照着它填，比回忆快得多。
# 注意 env.conf 并非全无凭据（NEWAPI_ROOT_PAT、心跳与 webhook URL），只能随加密包走。
cp -a "$ENV_FILE" "$STAGE/system/env.conf" 2>/dev/null
# 告警邮件配置，所有备份脚本的 msmtp 都读它。里面有 SMTP 密码：原文件可能是
# 640 root:msmtp，cp -a 会原样保留，所以用 install 直接以 600 落进暂存区。
# 没配 MAIL_TO 的机器本来就不发邮件，缺它不算异常，不计告警。
if [ -f /etc/msmtprc ]; then
    install -p -m 600 /etc/msmtprc "$STAGE/system/msmtprc" || warn "msmtprc 复制异常"
elif [ -n "$MAIL_TO" ]; then
    warn "配置了 MAIL_TO 但没有 /etc/msmtprc：告警邮件发不出去，包里也没有它"
else
    log "  i 没有 /etc/msmtprc（未配置 MAIL_TO），跳过"
fi
# new-api 隧道单元（本机 → 落地机的 SSH 隧道）。单元名只认 env.conf 的
# NEWAPI_TUNNEL_UNIT，不按 *tunnel*.service 通配去猜：猜中别的隧道，还原时就会
# 启用错的服务；未配置这个键的机器也不一定有 new-api 隧道。
TUNNEL_UNIT="${NEWAPI_TUNNEL_UNIT:-}"
if [ -n "$TUNNEL_UNIT" ]; then
    # 和 systemctl 一样，不写后缀按 .service 处理
    case "$TUNNEL_UNIT" in *.service) ;; *) TUNNEL_UNIT="${TUNNEL_UNIT}.service" ;; esac
    case "$TUNNEL_UNIT" in
        */*|.*|*[!A-Za-z0-9@._:-]*)
            warn "NEWAPI_TUNNEL_UNIT 不是合法的单元名（${NEWAPI_TUNNEL_UNIT}），隧道单元未进包"
            TUNNEL_UNIT="" ;;
        *)
            if [ -f "/etc/systemd/system/$TUNNEL_UNIT" ]; then
                mkdir -p "$STAGE/system/systemd"
                # -L：单元若是 systemctl link 出来的软链，要带走的是文件本身
                cp -pL "/etc/systemd/system/$TUNNEL_UNIT" "$STAGE/system/systemd/" \
                    || warn "隧道单元 $TUNNEL_UNIT 复制异常"
                # systemctl edit 产生的 drop-in 也一起带上，否则还原出来的是改动前的单元
                if [ -d "/etc/systemd/system/$TUNNEL_UNIT.d" ]; then
                    cp -a "/etc/systemd/system/$TUNNEL_UNIT.d" "$STAGE/system/systemd/" \
                        || warn "隧道单元的 drop-in 复制异常"
                fi
            else
                warn "没有 /etc/systemd/system/$TUNNEL_UNIT（NEWAPI_TUNNEL_UNIT），隧道单元未进包"
            fi ;;
    esac
else
    log "  i 未配置 NEWAPI_TUNNEL_UNIT，不收集隧道单元"
fi
ufw status verbose > "$STAGE/system/ufw-status.txt" 2>/dev/null
# 容器网段：compose 起的服务会有独立网络，和默认 bridge 不在同一网段
{
    docker network ls 2>/dev/null
    echo
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        printf '%-24s %s\n' "$c" "$(docker inspect -f '{{range $n, $v := .NetworkSettings.Networks}}{{$n}}={{$v.IPAddress}} {{end}}' "$c" 2>/dev/null)"
    done
    echo
    ip -4 addr show 2>/dev/null | grep -E 'docker|br-' | grep inet
} > "$STAGE/system/docker/networks.txt" 2>/dev/null

# 容器启动参数：没有 compose 的服务只能从运行时状态导出
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    docker inspect "$c" > "$STAGE/system/docker/${c}.json" 2>/dev/null
    {
        echo "# ${c}"
        echo -n "docker run -d --name ${c} --restart $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")"
        docker inspect -f '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}} -p {{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}}{{end}}{{end}}' "$c"
        docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}} -v {{.Source}}:{{.Destination}}{{end}}{{end}}' "$c"
        docker inspect -f '{{range .HostConfig.ExtraHosts}} --add-host {{.}}{{end}}' "$c"
        docker inspect -f '{{range .Config.Env}} -e "{{.}}"{{end}}' "$c"
        docker inspect -f ' {{.Config.Image}}' "$c"
        echo
    } >> "$STAGE/system/docker/run-commands.sh" 2>/dev/null
done

# 5b. rootfs 与还原清单：新机按 restore-manifest.tsv 自动放回，约定见 backup/README.md「包结构」。
# 上面按旧布局收的内容照旧保留（旧的还原步骤和工具还认它们），业务数据硬链接进
# rootfs，tar 对硬链接只存一份，不增加包体积。
log "收集 rootfs 与还原清单 ..."
bk_init "$STAGE"
# 公共库的 bk_mysql_* 读这两个变量
# shellcheck disable=SC2034
BK_MYSQL="$MYSQL_BIN"
# shellcheck disable=SC2034
BK_MYSQLDUMP="$MYSQLDUMP_BIN"
[ -f "$STAGE/db/${DBNAME:-}.sql.gz" ] && bk_row "db/${DBNAME}.sql.gz" - - mysql-db
bk_link "$VW_DIR/data" vaultwarden/data
bk_link "$VW_DIR/vaultwarden.env" vaultwarden/vaultwarden.env
bk_link "$VW_DIR/compose.yaml" vaultwarden/compose.yaml && bk_row "$VW_DIR" - - compose-project
if [ -n "$KOMARI_DATA" ]; then
    KOMARI_DIR="$(dirname "$KOMARI_DATA")"
    bk_link "$KOMARI_DATA/komari.db" komari/komari.db sqlite
    for d in plugin plugin-data; do bk_link "$KOMARI_DATA/$d" "komari/$d"; done
    bk_link "$KOMARI_DIR/compose.yaml" komari/compose.yaml && bk_row "$KOMARI_DIR" - - compose-project
fi
[ -n "$KOMARI_EXTRA" ] && bk_link "$KOMARI_EXTRA/auto-discovery.json" komari/auto-discovery.json
if [ -n "$SUBCONV_DIR" ] && bk_link "$SUBCONV_DIR" subconverter; then
    for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        [ -f "$SUBCONV_DIR/$f" ] || continue
        bk_row "$SUBCONV_DIR/$f" "$(stat -c %a "$SUBCONV_DIR/$f")" "$(bk_owner "$SUBCONV_DIR/$f")" file
        bk_row "$SUBCONV_DIR" - - compose-project
    done
fi
bk_system
# 全部 MySQL 账号（带密码哈希）与其余业务库。metrics 大库按方案只留本地、不进包。
if bk_mysql_ready; then
    bk_mysql_users db/mysql-users.sql
    bk_mysql_dbs "${DBNAME:-}" "${METRICS_DB_NAME:-metrics}"
fi
bk_compose_projects
bk_images "$STAGE/images.tsv"
log "  ✓ rootfs $(du -sh "$STAGE/rootfs" | cut -f1)，还原清单 $(grep -vc '^#' "$BK_MANIFEST") 项"

# 6. 清单与还原说明
log "生成清单 ..."
{
    echo "备份时间   : $(date '+%F %T %Z')"
    echo "主机名     : $(hostname)"
    echo "公网 IP    : $(curl -fsS -m 5 ifconfig.me 2>/dev/null || echo 未知)"
    echo "系统       : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    echo "内核       : $(uname -r)"
    echo
    echo "---- 容器 ----"
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    echo
    echo "---- 版本 ----"
    docker exec vaultwarden /vaultwarden --version 2>/dev/null
    echo "MySQL: $("$MYSQL_BIN" --version 2>/dev/null)"
    echo "Nginx: $(nginx -v 2>&1)"
    echo
    echo "---- 站点 ----"
    for f in "$BT_VHOST"/*.conf; do [ -e "$f" ] || continue; basename "$f"; done
    echo
    echo "---- 还原清单（restore-manifest.tsv）按类别 ----"
    grep -v '^#' "$BK_MANIFEST" | cut -f4 | sort | uniq -c
    echo "未进包的项见 system/rootfs-skipped.txt（$(wc -l < "$BK_SKIPPED") 项）"
    echo
    echo "---- 内容校验和 ----"
    (cd "$STAGE" && find . -type f -exec sha256sum {} \; | sort -k2)
} > "$STAGE/manifest.txt" 2>&1

# heredoc 用引号包住，里面的 $argon2id$v= 等内容才不会被 shell 展开
# （这正是 ADMIN_TOKEN 那个经典坑的同一个机制）。
# 需要按环境替换的地方用 {{占位符}}，生成后再 sed，两不耽误。
cat > "$STAGE/RESTORE.md" <<'RESTOREEOF'
# 还原步骤

> 解压：`7z x srvbak_YYYYMMDD_HHMMSS.7z`（会提示输密码），再 `tar xzf payload.tar.gz`
> 先读 `manifest.txt` 确认版本和域名，照着装同版本，避免数据库结构不匹配。
> `system/env.conf` 里是本机的路径与名称配置，新机照着填能省很多回忆。

## 自动还原
`restore-manifest.tsv` 列出了原样放回新机的全部内容（文件在 `rootfs/<原路径>`），
还原脚本 `migrate/restore-from-backup.sh` 按它放回配置、建账号、导入库、按
`images.tsv` 里的 digest 拉镜像并启动 compose 项目、启用 systemd 单元、导入 crontab。
没进包的东西和原因见 `system/rootfs-skipped.txt`；`system/ref/` 里的 fstab、IP 等
只作参考，不会自动放回。下面的手动步骤在没有还原脚本、或需要逐项核对时使用。

## 0. 新机器准备
1. 装 Docker：`curl -fsSL https://get.docker.com | sh && systemctl enable --now docker`
2. 装面板（可选，只为管 nginx 和证书），或直接用系统 nginx
3. 域名解析改到新机器 IP —— **先做这步**，否则证书和通行密钥都要重来
4. **确认公网 IP 在不在网卡上**：`ip -4 -br addr` 显示私网地址 = 机器在 NAT 后面，
   入站可达性要单独验证，且容器内不能用公网 IP 访问宿主机服务

## 1. 数据库
```bash
# 建库建用户（密码见 vaultwarden/vaultwarden.env 里的 DATABASE_URL）
mysql -uroot -p -e "CREATE DATABASE vaultwarden CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'vaultwarden'@'{{DB_CLIENT_HOST}}' IDENTIFIED BY '见env';
GRANT ALL ON vaultwarden.* TO 'vaultwarden'@'{{DB_CLIENT_HOST}}'; FLUSH PRIVILEGES;"
# 导入
zcat db/vaultwarden.sql.gz | mysql -uroot -p vaultwarden
```
host 段用 `{{DB_CLIENT_HOST}}`（覆盖整个容器网段），不要用具体容器 IP（重建就变），
也不要用 `%`（对全网开放）。原机的实际授权见 `db/vaultwarden-grants.txt`。

⚠️ 启用了 ufw 的话必须放行网桥：`ufw allow from {{DOCKER_CIDR}} to any port 3306 proto tcp`
漏了这条是**延迟发作**的：连接池里的旧连接还能撑几小时，然后突然全站 503，
日志报 `(115)` —— 115 是超时不是拒绝，说明包被静默丢弃。

## 2. Vaultwarden
```bash
mkdir -p /opt/vaultwarden && cp -a vaultwarden/data /opt/vaultwarden/
cp vaultwarden/vaultwarden.env vaultwarden/compose.yaml /opt/vaultwarden/
cd /opt/vaultwarden && docker compose up -d
docker exec vaultwarden printenv ADMIN_TOKEN | head -c 12   # 必须是 $argon2id$v=
```
`rsa_key.pem` 已在 data 里，老设备不会被强制登出。
`data/config.json` 存在的话会**覆盖** env 里的 DOMAIN 等项，换域名时两处都要改。

## 3. Komari
```bash
mkdir -p /opt/komari/data && cp komari/komari.db /opt/komari/data/
cp -a komari/plugin komari/plugin-data /opt/komari/data/ 2>/dev/null
cp komari/compose.yaml /opt/komari/ && cd /opt/komari && docker compose up -d
```
主题需要在面板里重新下载（清单见 komari/theme-list.txt）。
**监控历史不在备份内，重建后从零开始记录，agent token 在 komari.db 里，被控端不用重装。**

⚠️ **指标库的连接串写在 komari.db 的 `configs` 表里**，不是环境变量。
如果里面是宿主机的公网 IP，换到 NAT 后面的机器就连不上 —— 改成网桥网关地址：

```bash
sqlite3 /opt/komari/data/komari.db "SELECT rowid,value FROM configs WHERE value LIKE '%3306%'"
```

## 4. SubConverter
```bash
mkdir -p /opt/SubConverter-Extended && cp -a subconverter/. /opt/SubConverter-Extended/
cd /opt/SubConverter-Extended && docker compose up -d
```
`pref.toml` 是全部自定义配置的唯一载体，**不要用上游示例覆盖它**。

## 5. Nginx 与证书
```bash
cp system/nginx/*.conf /www/server/panel/vhost/nginx/
cp -a system/cert/. /www/server/panel/vhost/cert/
nginx -t && systemctl reload nginx
```
只手动放这两处的话，面板里需要重新"添加站点"，否则面板认不得这些配置。
按还原清单自动还原时，面板的 `vhost/`（含 proxy、rewrite、extension、well-known）、
`config/`、`data/` 整个放回，站点记录与续期记录都在其中。

⚠️ **证书文件能用 ≠ 会自动续期。** 面板目录整体还原这条路**尚未在真机验证过**：
还原后在面板里逐站确认续期任务还在；不在就**逐站重新申请一次**（算法选 EC256），
否则到期那天全站一起挂。

## 6. rclone、告警邮件与定时任务
```bash
mkdir -p /root/.config/rclone && cp system/rclone.conf /root/.config/rclone/
rclone listremotes
apt-get install -y msmtp msmtp-mta   # 没装的话；msmtp-mta 会替换系统自带的 MTA，属预期
cp system/msmtprc /etc/msmtprc && chmod 600 /etc/msmtprc
crontab system/crontab.txt   # 先看一遍再导入
```
`msmtprc` 里有 SMTP 密码，必须 600。包里没有它说明原机没配告警邮件（或备份时就缺失，
看备份日志的 WARN）。导入 crontab **之前**先确认能发信：`opsget ops/mail-doctor --send`，
否则备份失败的告警会无声消失。

⚠️ crontab 顶部必须有 `PATH=`，且每行都要有输出重定向 —— 缺了会让脚本
在手动跑正常、定时跑失败，且报错发给收不到的 root@主机名。

## 7. new-api 隧道（包里有 `system/systemd/` 才需要）
```bash
cp -a system/systemd/. /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now {{TUNNEL_UNIT}}
systemctl status {{TUNNEL_UNIT}} --no-pager
```
⚠️ 单元 `ExecStart` 里用到的 SSH 私钥和落地机的 host key 在 `rootfs/root/.ssh/`，
手动还原时先 `cp -a rootfs/root/.ssh /root/` 再 `enable`，否则隧道反复重启。
落地机 IP 或 SSH 端口变了的话，先改单元里的目标地址，并与 `env.conf` 的
`NEWAPI_HOST` / `NEWAPI_SSH_PORT` 保持一致。

## 8. 验收
- [ ] `https://域名/alive` 返回 200
- [ ] 用原邮箱 + 原主密码登录，条目数与 manifest 对得上
- [ ] TOTP 二步验证可用
- [ ] 通行密钥：换域名的话需在「账户设置 → 安全 → 两步登录」重新注册
- [ ] Komari 面板能看到原有被控端，且日志有 `Metric store initialized successfully`
- [ ] 订阅转换接口能正常返回
- [ ] `SELECT user,host FROM information_schema.processlist` 里来源是容器网段地址
- [ ] `opsget ops/mail-doctor --send` 能收到测试邮件
- [ ] 有隧道的话：`systemctl is-active {{TUNNEL_UNIT}}` 为 active，`opsget ops/newapi-linkcheck` 通过
RESTOREEOF
# TUNNEL_UNIT 已按单元名规则校验过，不含 | & \，可以直接进 sed
sed -i "s|{{DB_CLIENT_HOST}}|${DB_CLIENT_HOST}|g; s|{{DOCKER_CIDR}}|${DOCKER_CIDR}|g; s|{{TUNNEL_UNIT}}|${TUNNEL_UNIT:-<隧道单元名>}|g" \
    "$STAGE/RESTORE.md"

# 7. 打包加密
log "打包 ..."
tar czf "$STAGE/../payload_${TS}.tar.gz" -C "$STAGE" . || die "tar 打包失败"
mv "$STAGE/../payload_${TS}.tar.gz" "$STAGE/../payload.tar.gz.tmp"
mkdir -p "${STAGE_ROOT}/.pack_${TS}"
mv "$STAGE/../payload.tar.gz.tmp" "${STAGE_ROOT}/.pack_${TS}/payload.tar.gz"
cp "$STAGE/manifest.txt" "$STAGE/RESTORE.md" "${STAGE_ROOT}/.pack_${TS}/" 2>/dev/null

log "加密 ..."
rm -f "$ARCHIVE"
if 7z a -t7z -m0=lzma2 -mx=6 -mhe=on -p"$PASS" "$ARCHIVE" \
      "${STAGE_ROOT}/.pack_${TS}"/* >/dev/null 2>>"$LOG_FILE"; then
    log "  ✓ ${NAME}.7z ($(du -h "$ARCHIVE" | cut -f1))"
else
    rm -rf "${STAGE_ROOT}/.pack_${TS}"
    die "7z 加密失败"
fi
rm -rf "${STAGE_ROOT}/.pack_${TS}"

# 验证能解开（只测密码和完整性，不实际解压到磁盘）
7z t -p"$PASS" "$ARCHIVE" >/dev/null 2>&1 </dev/null || die "加密包自检失败，不要信任这个备份"
log "  ✓ 加密包自检通过"
sha256sum "$ARCHIVE" | tee -a "$LOG_FILE" > "${ARCHIVE}.sha256"

# 8. 上传
UPLOAD_FAIL=0
for remote in "${REMOTES[@]}"; do
    name="${remote%%:*}"
    log "上传到 ${name} ..."
    if rclone copy "$ARCHIVE" "$remote/" --stats-one-line --stats=30s \
         --retries 3 --low-level-retries 10 >>"$LOG_FILE" 2>&1; then
        # 云盘写入后元数据有延迟，立刻校验会误报
        sleep 10
        # 上传后校验，rclone copy 成功不代表内容一致
        if rclone check "$ARCHIVE" "$remote/" --size-only >>"$LOG_FILE" 2>&1; then
            log "  ✓ ${name} 上传并校验通过"
        else
            warn "${name} 上传后校验失败"
            UPLOAD_FAIL=1
        fi
    else
        warn "${name} 上传失败"
        UPLOAD_FAIL=1
    fi
done

# 9. 分级保留（GFS，按文件名里的时间戳）。本次上传有失败就一个都不删：
# 这时旧包可能是某个远端上唯一完好的那份。致命错误在前面已经 die，走不到这里。
if [ -n "$LOCAL_ONLY" ]; then
    log "只在本地生成（--local-only）：${ARCHIVE}；不上传、不清理"
elif [ "$UPLOAD_FAIL" -ne 0 ]; then
    log "本次上传有失败，跳过清理"
else
    log "分级保留：全留 ${KEEP_ALL_DAYS} 天，每天一份至 ${KEEP_DAILY_DAYS} 天，每周一份至 ${KEEP_WEEKLY_DAYS} 天，每月一份至上限 ..."
    bk_prune_local "$OUT_DIR" srvbak "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$KEEP_LOCAL_DAYS"
    for remote in "${REMOTES[@]}"; do
        bk_prune_remote "$remote" srvbak "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$KEEP_CLOUD_DAYS"
    done
fi

# 收尾
if [ "$UPLOAD_FAIL" -ne 0 ]; then
    hb /fail
    notify "备份已生成但上传失败，请检查 $LOG_FILE"
    log "========== 完成（有上传失败，共 ${WARNINGS} 条告警）=========="
    exit 2
fi
if [ "$WARNINGS" -gt 0 ]; then
    # 有告警也报 fail：让外部观察者看到「部分失败」，不要等它误判成健康
    hb /fail
    notify "备份完成但有 ${WARNINGS} 条告警，请检查 $LOG_FILE"
else
    hb
fi
log "========== 完成（${WARNINGS} 条告警）=========="
exit 0
