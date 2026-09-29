#!/usr/bin/env bash
# backup/xboard-fullbackup.sh — 生成 Xboard 加密备份包并上传云端
# VERSION: 2.5.0
# 2.5.0: 新增 --local-only <目录>：包只写到该目录，不上传、不清理、不报心跳、不发告警；上一轮还在跑就等它结束（一键迁移现做包用）。
# 2.4.1: 其余业务库跳过 METRICS_DB_NAME（与 vw 一致，指标库只留本地），否则每 6 小时把整个指标库打进包上云。
# 2.4.0: 新增 rootfs/ 与 restore-manifest.tsv（整个 Xboard 目录、系统配置、crontab、全部 MySQL 账号与业务库、镜像 digest），包内先打 tar 保留属主，改为 GFS 分级保留，防重入锁。
# ENV-REQUIRED: SVC_XBOARD_DIR XBOARD_DB_NAME XBOARD_DB_USER XBOARD_DB_PASS_FILE XBOARD_BACKUP_DIR XBOARD_REMOTE_PATH RCLONE_REMOTES BACKUP_PASS_FILE|VW_PASS_FILE PANEL_VHOST_DIR PANEL_CERT_DIR WWWROOT DB_CLIENT_HOST DOCKER_CIDR
# 定时任务调用已安装的本地脚本，密码从配置文件指定的文件读取。
# 用法：xboard-fullbackup.sh [--local-only <目录>]

set -uo pipefail
# --local-only：一键迁移（migrate/live-migrate）在旧机上现做包、经 SSH 直传新机。
# 不上传、不清理：这份包不是例行备份，不该挤掉网盘上的旧包；不报心跳：心跳的意思是「例行备份已上云」
LOCAL_ONLY=""
case "${1:-}" in
    --local-only) LOCAL_ONLY=${2:-}; [ -n "$LOCAL_ONLY" ] || { echo "[FATAL] --local-only 后面要跟目录"; exit 1; } ;;
    "") ;;
    *) echo "[FATAL] 未知参数: $1（只认 --local-only <目录>）"; exit 1 ;;
esac

# 公共库：rootfs 采集、还原清单、分级保留。opsget -i 安装本脚本时会同步到同一版本。
# 先加载，下面本脚本自己的 log / warn 会覆盖库里的同名函数。
LIB_OK=0
# shellcheck disable=SC1091
{ . /usr/local/lib/ops-common.sh || . "$(dirname "$0")/../lib/common.sh"; } 2>/dev/null && LIB_OK=1

# 配置（全部来自 env.conf）
ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

req() { local m=""; for v in "$@"; do [ -n "${!v:-}" ] || m="$m $v"; done
        [ -z "$m" ] || { echo "[FATAL] 配置项未填:$m（见 $ENV_FILE）"; exit 1; }; }
req SVC_XBOARD_DIR XBOARD_DB_NAME XBOARD_DB_USER XBOARD_DB_PASS_FILE \
    XBOARD_BACKUP_DIR XBOARD_REMOTE_PATH RCLONE_REMOTES \
    PANEL_VHOST_DIR PANEL_CERT_DIR WWWROOT DB_CLIENT_HOST DOCKER_CIDR

XBOARD_DIR="$SVC_XBOARD_DIR"
DB_NAME="$XBOARD_DB_NAME"
DB_USER="$XBOARD_DB_USER"
DB_HOST="${XBOARD_DB_HOST:-127.0.0.1}"
DB_PORT="${XBOARD_DB_PORT:-3306}"

DB_PASS_FILE="$XBOARD_DB_PASS_FILE"
# 备份加密密码与 vw-fullbackup 共用同一个文件 —— 只记一个密码，少一处出错的地方
# 新键优先、旧键回落 —— 现有机器的 env.conf 一个字不用动
BACKUP_PASS_FILE="${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}"
req BACKUP_PASS_FILE

BACKUP_DIR="$XBOARD_BACKUP_DIR"
# 本地模式的包放到指定目录；这个目录也不进包（bk_init 把 BACKUP_DIRS 当成落盘目录排除）
[ -n "$LOCAL_ONLY" ] && BACKUP_DIRS="${BACKUP_DIRS:-} $LOCAL_ONLY"
# 分级保留：全留 / 每天一份 / 每周一份 / 每月一份直到上限（本地与云端上限不同）
KEEP_ALL_DAYS="${BACKUP_KEEP_ALL_DAYS:-7}"
KEEP_DAILY_DAYS="${BACKUP_KEEP_DAILY_DAYS:-30}"
KEEP_WEEKLY_DAYS="${BACKUP_KEEP_WEEKLY_DAYS:-90}"
LOCAL_KEEP_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-180}"
CLOUD_KEEP_DAYS="${BACKUP_KEEP_CLOUD_DAYS:-400}"
RCLONE_TARGETS=(); for r in $RCLONE_REMOTES; do RCLONE_TARGETS+=("${r}:${XBOARD_REMOTE_PATH}"); done

MAIL_TO="${MAIL_TO:-}"
MAIL_SUBJECT_PREFIX="${XBOARD_MAIL_PREFIX:-[Xboard备份]}"

# 体积过大时可在此排除表（只影响云端包，本地库仍是全量）
read -r -a EXCLUDE_TABLES <<< "${XBOARD_EXCLUDE_TABLES:-}"
# 站点列表。留空 = 自动模式：扫 vhost 目录，把所有站点都收进来。
# 自动模式的好处是面板里增删域名不用回来改配置；代价是可能多收几个
# 无关站点的 conf —— 那些文件才几 KB，比漏备份一个站划算得多。
SITES_MODE=auto
if [ -n "${XBOARD_SITES:-}" ]; then
    SITES_MODE=explicit
    read -r -a SITES <<< "$XBOARD_SITES"
else
    mapfile -t SITES < <(
        for f in "${PANEL_VHOST_DIR}"/*.conf; do
            [ -f "$f" ] || continue
            # 从 server_name 取域名，排开 _ 和 IP
            sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;]+);.*/\1/p' "$f" \
              | tr ' ' '\n' | grep -E '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        done | sort -u
    )
fi
ASSETS_SITE="${XBOARD_ASSETS_SITE:-}"

# 内部
STAMP=$(date -u +%Y%m%d_%H%M%S)
WORK=$(mktemp -d /tmp/xboard-bak.XXXXXX)
ARCHIVE="${LOCAL_ONLY:-$BACKUP_DIR}/xboard_${STAMP}.7z"
# LOGPREFIX 已弃用：时间戳改为在 log/warn/fail 内实时生成
WARNINGS=()
FATAL=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log()  { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { WARNINGS+=("$*"); printf '[%s] [WARN] %s\n' "$(date -u '+%F %T')" "$*" >&2; }
fail() { FATAL="$*"; printf '[%s] [FATAL] %s\n' "$(date -u '+%F %T')" "$*" >&2; hb /fail; send_mail; exit 1; }

send_mail() {
    [ -z "$LOCAL_ONLY" ] || return 0     # 本地模式由调用方看退出码和输出
    [ -n "$MAIL_TO" ] || return 0
    command -v msmtp >/dev/null 2>&1 || return 0
    local subject body
    if [ -n "$FATAL" ]; then
        subject="$MAIL_SUBJECT_PREFIX 失败 - $(hostname)"
        body="备份失败\n\n主机: $(hostname)\n时间: $(date -u '+%F %T') UTC\n\n致命错误:\n  $FATAL\n"
        [ ${#WARNINGS[@]} -gt 0 ] && body="${body}\n此前的告警:\n$(printf '  - %s\n' "${WARNINGS[@]}")"
    elif [ ${#WARNINGS[@]} -gt 0 ]; then
        subject="$MAIL_SUBJECT_PREFIX ${#WARNINGS[@]} 条告警 - $(hostname)"
        body="备份完成但有告警\n\n主机: $(hostname)\n包体: $ARCHIVE\n\n$(printf '  - %s\n' "${WARNINGS[@]}")"
    else
        return 0
    fi
    # 重试三次：SMTP 的瞬时失败会让告警直接消失，而那正是最怕的故障
    local i sent=0
    for i in 1 2 3; do
        printf 'Subject: %s\n\n%b\n' "$subject" "$body" | msmtp "$MAIL_TO" && { sent=1; break; }
        printf '[%s] [WARN] 告警邮件第 %s 次发送失败\n' "$(date -u '+%F %T')" "$i" >&2
        [ "$i" -lt 3 ] && sleep 20
    done
    if [ "$sent" -eq 0 ] && [ -n "${ALERT_WEBHOOK:-}" ]; then
        curl -fsS -m 10 -X POST --data-urlencode "text=[$(hostname)] $subject" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 && sent=1
    fi
    if [ "$sent" -eq 0 ]; then
        printf '[%s] [未送达] %s\n%b\n' "$(date -u '+%F %T')" "$subject" "$body" \
            >> "${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
    fi
}

need() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"; }

# 反向监控心跳，留空则跳过
hb() {
    [ -z "$LOCAL_ONLY" ] || return 0
    [ -n "${XBOARD_HEARTBEAT_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 "${XBOARD_HEARTBEAT_URL}${1:-}" >/dev/null 2>&1 \
        || printf '[%s] [WARN] 心跳上报失败%s\n' "$(date -u '+%F %T')" "${1:-}" >&2
}

# 防重入：每 6 小时一次时，上一轮若因上传慢还没结束，两轮会同时清理同一批包。
# 撞上就直接退出、不报心跳：偶尔一次无妨，一直撞上时由心跳监控发现「没按时完成」。
mkdir -p /run/lock
exec 9>/run/lock/xboard-fullbackup.lock || fail "无法创建锁文件 /run/lock/xboard-fullbackup.lock"
# 本地模式是有人等着要包：等上一轮跑完（它也可能正卡在上传），而不是跳过
if [ -n "$LOCAL_ONLY" ]; then
    flock -w 7200 9 || fail "等了 2 小时，上一轮备份还没结束"
else
    flock -n 9 || { log "上一轮备份还在运行，本次跳过"; exit 0; }
fi

# 前置检查
log "=== Xboard 备份开始 ==="
hb /start
[ "$LIB_OK" -eq 1 ] && declare -F bk_gfs_select >/dev/null \
    || fail "公共库缺失或版本过旧（需要 1.2.0 起，含 bk_* 函数），先运行 opsget -u"

need mysqldump
need 7z
[ -f "$DB_PASS_FILE" ]     || fail "数据库密码文件不存在: $DB_PASS_FILE"
[ -f "$BACKUP_PASS_FILE" ] || fail "备份密码文件不存在: $BACKUP_PASS_FILE"
[ -d "$XBOARD_DIR" ]       || fail "Xboard 目录不存在: $XBOARD_DIR"

DB_PASS=$(head -1 "$DB_PASS_FILE")
BACKUP_PASS=$(head -1 "$BACKUP_PASS_FILE")
[ -n "$DB_PASS" ]     || fail "数据库密码为空"
[ -n "$BACKUP_PASS" ] || fail "备份密码为空"
[ ${#BACKUP_PASS} -ge 16 ] || fail "备份密码太短（<16 位），请换成长随机串"

mkdir -p "$BACKUP_DIR" ${LOCAL_ONLY:+"$LOCAL_ONLY"} || fail "无法创建 $BACKUP_DIR ${LOCAL_ONLY}"

# 用 defaults-file 传密码，避免出现在 ps 输出里。
# 值加双引号，密码里的 # 才不会被当成注释截断；\ 和 " 按 option 文件规则转义。
MYCNF="$WORK/.my.cnf"
umask 077
DB_PASS_ESC=${DB_PASS//\\/\\\\}; DB_PASS_ESC=${DB_PASS_ESC//\"/\\\"}
cat > "$MYCNF" <<EOF
[client]
user=$DB_USER
password="$DB_PASS_ESC"
host=$DB_HOST
port=$DB_PORT
EOF

# 1. 数据库
log "--- 导出数据库 $DB_NAME ---"

mkdir -p "$WORK/db"

# 先记录各表体积，便于日后判断要不要排除大表
mysql --defaults-file="$MYCNF" -N -e "
SELECT CONCAT(table_name,'  ',
       ROUND(((data_length+index_length)/1024/1024),1),' MB  ',
       table_rows,' 行')
FROM information_schema.tables
WHERE table_schema='$DB_NAME'
ORDER BY (data_length+index_length) DESC LIMIT 10;
" > "$WORK/db/table-sizes.txt" 2>/dev/null \
    || warn "无法读取表体积信息（不影响备份）"

# 记录账号授权：恢复时要照着重建用户，host 段错了容器就连不上
mysql --defaults-file="$MYCNF" -N -B -e "SELECT CURRENT_USER(); SHOW GRANTS;" \
    > "$WORK/db/${DB_NAME}-grants.txt" 2>/dev/null \
    || warn "无法记录 ${DB_NAME} 的授权信息"

DUMP_ARGS=(--defaults-file="$MYCNF" --single-transaction --quick
           --routines --triggers --events --default-character-set=utf8mb4
           --no-tablespaces)
for t in "${EXCLUDE_TABLES[@]:-}"; do
    [ -n "$t" ] && DUMP_ARGS+=(--ignore-table="${DB_NAME}.${t}")
done

mysqldump "${DUMP_ARGS[@]}" "$DB_NAME" > "$WORK/db/${DB_NAME}.sql"
DUMP_RC=${PIPESTATUS[0]}
[ "$DUMP_RC" -eq 0 ] || fail "mysqldump 失败，退出码 $DUMP_RC"

# 被排除的表：只导结构不导数据，避免恢复后面板查表报错
if [ "${#EXCLUDE_TABLES[@]}" -gt 0 ] && [ -n "${EXCLUDE_TABLES[0]:-}" ]; then
    log "补充导出被排除表的结构（不含数据）..."
    mysqldump --defaults-file="$MYCNF" --no-tablespaces --no-data \
        "$DB_NAME" "${EXCLUDE_TABLES[@]}" >> "$WORK/db/${DB_NAME}.sql"
    SCHEMA_RC=$?
    [ "$SCHEMA_RC" -eq 0 ] || fail "排除表结构导出失败，退出码 $SCHEMA_RC"
fi

DUMP_SIZE=$(stat -c%s "$WORK/db/${DB_NAME}.sql")
[ "$DUMP_SIZE" -gt 1024 ] || fail "dump 文件异常小（${DUMP_SIZE} 字节），可能没导出成功"
grep -q "Dump completed" "$WORK/db/${DB_NAME}.sql" \
    || warn "dump 末尾没有 'Dump completed' 标记，文件可能被截断"
log "dump 大小: $(numfmt --to=iec "$DUMP_SIZE")"

# 2. 应用文件
log "--- 打包应用文件 ---"

mkdir -p "$WORK/app"

# .env 是最关键的一个文件：APP_KEY 丢了，数据库里的加密字段全部解不开
if [ -f "$XBOARD_DIR/.env" ]; then
    cp -a "$XBOARD_DIR/.env" "$WORK/app/.env"
    grep -q '^APP_KEY=.\+' "$WORK/app/.env" || fail ".env 里没有 APP_KEY，备份没有意义"
else
    fail "$XBOARD_DIR/.env 不存在"
fi

cp -a "$XBOARD_DIR/compose.yaml" "$WORK/app/" 2>/dev/null \
    || warn "compose.yaml 不存在（改过端口绑定和 ENABLE_REDIS 的话会丢）"

for d in .docker/.data storage/theme plugins; do
    if [ -e "$XBOARD_DIR/$d" ]; then
        mkdir -p "$WORK/app/$(dirname "$d")"
        cp -a "$XBOARD_DIR/$d" "$WORK/app/$d"
    fi
done

# 3. nginx 与证书
log "--- 打包 nginx 配置与证书 ---"

mkdir -p "$WORK/nginx/vhost" "$WORK/nginx/cert"
log "站点来源: $SITES_MODE（${#SITES[@]} 个）"
for site in "${SITES[@]}"; do
    [ -n "$site" ] || continue
    # vhost 的文件名不一定等于域名 —— 面板可能加前缀（如 html_<域名>.conf）。
    # 按 server_name 反查才可靠：文件名可以随面板怎么起，server_name 骗不了人。
    FOUND=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        cp -a "$f" "$WORK/nginx/vhost/" && FOUND=1
    done < <(grep -lE "server_name[^;]*[[:space:]]${site//./\\.}[[:space:];]" \
                  "${PANEL_VHOST_DIR}"/*.conf 2>/dev/null)
    [ -d "${PANEL_CERT_DIR}/${site}" ] && cp -a "${PANEL_CERT_DIR}/${site}" "$WORK/nginx/cert/"
    # 只在「配置里明确列了、实际却没有」时才告警。
    # 自动模式下站点是从 vhost 扫出来的，不存在「找不到」这回事。
    if [ "$SITES_MODE" = explicit ]; then
        [ "$FOUND" -eq 1 ] || warn "配置里列了 $site 但找不到它的 vhost —— 站点已删就把它从 XBOARD_SITES 移除，或改为留空启用自动模式"
        [ -d "${PANEL_CERT_DIR}/${site}" ] || warn "配置里列了 $site 但没有证书目录"
    fi
done
# 静态资源站：没指定就挑一个 wwwroot 下真实存在的
if [ -z "$ASSETS_SITE" ]; then
    for s in "${SITES[@]}"; do
        [ -d "${WWWROOT}/${s}" ] && { ASSETS_SITE="$s"; break; }
    done
fi
# ASSETS_SITE 为空时 "${WWWROOT}/" 本身就是目录，会把整个 wwwroot 抄进 /tmp
if [ -n "$ASSETS_SITE" ] && [ -d "${WWWROOT}/${ASSETS_SITE}" ]; then
    cp -a "${WWWROOT}/${ASSETS_SITE}" "$WORK/nginx/assets-site"
else
    log "没有可收的静态资源站（XBOARD_ASSETS_SITE 未设，站点目录也都不在 ${WWWROOT} 下）"
fi

# 4. 部署元数据
log "--- 打包部署元数据 ---"

mkdir -p "$WORK/deploy"
[ -d /root/deploy ] && cp -a /root/deploy/. "$WORK/deploy/" 2>/dev/null
[ -f /etc/xboard-toolkit.conf ] && cp -a /etc/xboard-toolkit.conf "$WORK/deploy/"
# 配置本身也进包：换机器时照着它填（里面没有密码，只有路径与名称）
cp -a "$ENV_FILE" "$WORK/deploy/env.conf" 2>/dev/null

# 4b. rootfs 与还原清单：新机按 restore-manifest.tsv 自动放回，约定见 backup/README.md「包结构」。
# 上面按旧布局收的内容照旧保留；rootfs 里重复的部分 7z 固实压缩时只存一份。
log "--- 收集 rootfs 与还原清单 ---"
bk_init "$WORK"
bk_row "db/${DB_NAME}.sql" - - mysql-db
# 整个 Xboard 目录（含 git 检出、.env、compose、容器数据、主题、插件）原样放回，
# 不用再 git clone 一个可能更新的版本。框架日志不收。
bk_dir "$XBOARD_DIR" "$XBOARD_DIR/storage/logs" || fail "Xboard 目录收进 rootfs 失败"
for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    [ -f "$XBOARD_DIR/$f" ] || continue
    bk_row "$XBOARD_DIR/$f" "$(stat -c %a "$XBOARD_DIR/$f")" "$(bk_owner "$XBOARD_DIR/$f")" file
    bk_row "$XBOARD_DIR" - - compose-project
done
bk_opt /root/deploy
bk_opt /etc/xboard-toolkit.conf
bk_system
if bk_mysql_ready; then
    bk_mysql_users db/mysql-users.sql
    # 指标库体积大、按方案只留本地（与 vw-fullbackup 一致）
    bk_mysql_dbs "$DB_NAME" "${METRICS_DB_NAME:-metrics}"
fi
bk_compose_projects
bk_images "$WORK/images.tsv"
log "rootfs $(du -sh "$WORK/rootfs" | cut -f1)，还原清单 $(grep -vc '^#' "$BK_MANIFEST") 项"

# 5. 清单
cat > "$WORK/MANIFEST.txt" <<EOF
Xboard 备份包
================================
主机      : $(hostname)
时间      : $(date -u '+%F %T') UTC
数据库    : $DB_NAME ($(numfmt --to=iec "$DUMP_SIZE"))
排除表    : ${EXCLUDE_TABLES[*]:-无}
站点来源  : $SITES_MODE
Xboard 目录: $XBOARD_DIR
站点      : ${SITES[*]}

内容
  db/${DB_NAME}.sql      数据库全量
  db/table-sizes.txt     各表体积 Top10（判断是否需要排除大表）
  db/${DB_NAME}-grants.txt 账号授权，恢复时照着重建
  RESTORE.md             恢复步骤（灾难现场自足版）
  app/.env               ★ 含 APP_KEY，恢复时必须用这一份
  app/compose.yaml       改过端口绑定和 ENABLE_REDIS
  app/.docker/.data      容器数据目录
  app/storage/theme      主题
  app/plugins            插件
  nginx/vhost            各站点的 vhost
  nginx/cert             各站点的证书
  nginx/assets-site      LOGO / 用户条款静态文件
  deploy/                机器清单、中转路径表、工具箱配置、env.conf
  rootfs/                原样放回新机的文件（整个 Xboard 目录、系统配置、SSH、面板等）
  restore-manifest.tsv   还原清单：path mode owner kind，还原脚本据此自动放回
  images.tsv             每个容器的镜像与 RepoDigest，还原时按 digest 拉取
  db/mysql-users.sql     全部 MySQL 账号（带密码哈希）与授权
  system/crontab.txt     root 的 crontab
  system/rootfs-skipped.txt  没进包的项与原因（如解密密码）

不在包里（可重建，无需备份）
  · Redis                纯缓存
  · 各节点的 xboard-node 配置    面板里重装即可，machine token 存在数据库里
  · Docker 镜像          按 images.tsv 里的 digest 拉回来
  · 解密密码             备份包的密码不进包，另行保管

恢复要点
  1. APP_KEY 必须和数据库配套，用错会导致加密字段全部解不开
  2. 恢复后必须跑 Redis 属主修复和 config:cache
  3. 面板域名不变的话，各节点会自动重连，不用逐台重装
EOF

# heredoc 用引号包住，里面的 %{http_code} 等内容才不会被 shell 展开。
# 需要按环境替换的地方用 {{占位符}}，生成后再 sed。
cat > "$WORK/RESTORE.md" <<'RESTOREEOF'
# Xboard 恢复步骤

> 顺序不能乱。完整版见《Xboard备份与恢复》，此处是灾难现场自足版。
> `deploy/env.conf` 里是本机的路径与名称配置，新机照着填能省很多回忆。

## 自动还原
`restore-manifest.tsv` 列出了原样放回新机的全部内容（文件在 `rootfs/<原路径>`），
还原脚本 `migrate/restore-from-backup.sh` 按它放回配置、建账号、导入库、按
`images.tsv` 里的 digest 拉镜像并启动 compose 项目、启用 systemd 单元、导入 crontab。
没进包的东西和原因见 `system/rootfs-skipped.txt`；`system/ref/` 里的 fstab、IP 等
只作参考，不会自动放回。下面的手动步骤在没有还原脚本、或需要逐项核对时使用。

## 0. 解包

    7z x xboard_YYYYMMDD_HHMMSS.7z
    tar xzf payload.tar.gz        # 2.4.0 起内容在这一层里（保留属主），路径与旧版相同
    cat MANIFEST.txt

## 1. 建库建账号

授权照着 `db/{{DB_NAME}}-grants.txt` 重建。host 段必须是 `{{DB_CLIENT_HOST}}`，
写具体容器 IP 的话容器重建后连不上，写 `%` 是对全网开放。

    CREATE DATABASE {{DB_NAME}} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER '{{DB_USER}}'@'{{DB_CLIENT_HOST}}' IDENTIFIED BY '密码';
    GRANT ALL PRIVILEGES ON {{DB_NAME}}.* TO '{{DB_USER}}'@'{{DB_CLIENT_HOST}}';
    FLUSH PRIVILEGES;

ufw 要放行容器到宿主机：

    ufw allow from {{DOCKER_CIDR}} to any port 3306 proto tcp

## 2. 导入

    mysql -u root -p {{DB_NAME}} < db/{{DB_NAME}}.sql

被排除的表会存在但是 0 行，这是设计如此，不是备份损坏。

## 3. 放回应用文件

    git clone -b compose --depth 1 https://github.com/cedar2025/Xboard {{XBOARD_DIR}}
    cp app/.env {{XBOARD_DIR}}/.env
    cp app/compose.yaml {{XBOARD_DIR}}/compose.yaml
    cp -a app/.docker {{XBOARD_DIR}}/ 2>/dev/null
    cp -a app/storage/theme {{XBOARD_DIR}}/storage/ 2>/dev/null
    cp -a app/plugins {{XBOARD_DIR}}/ 2>/dev/null

⚠️ 绝对不要跑 `xboard:install`。它会重新生成 APP_KEY 并清空数据库，
   而 APP_KEY 一旦和数据库对不上，加密字段全部解不开。

⚠️ 镜像别按标签重新 pull。compose 里是 `:latest`，重拉可能拿到更新的版本，
   而 Xboard 启动时会跑数据库 migration，把按旧版结构恢复的库改掉。
   按 `images.tsv` 里的 digest 拉（`docker pull <repo>@sha256:...` 后
   `docker tag` 成 compose 里写的名字）；原机还在的话也可以 `docker save` 搬过去。

## 4. 起容器 + Redis 属主修复

    cd {{XBOARD_DIR}} && docker compose up -d && sleep 15
    docker compose exec xboard redis-cli -s /data/redis.sock ping

不是 PONG 就跑（每次全新部署都要）：

    docker compose exec -u root xboard chown -R redis:redis /data
    docker compose restart

## 5. 刷新配置缓存

    docker compose exec xboard php artisan config:cache
    curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:7001

直连返回 403 是正常的（缺 Host 头），带上真实域名的 Host 头再测。

## 6. nginx 与证书

    cp nginx/vhost/*.conf {{PANEL_VHOST_DIR}}/
    cp -a nginx/cert/* {{PANEL_CERT_DIR}}/
    cp -a nginx/assets-site {{WWWROOT}}/{{ASSETS_SITE}}
    nginx -t && nginx -s reload

面板里需要重新「添加站点」，否则面板认不得这些配置。
DNS 要先改到新 IP，否则证书续期会失败。

按还原清单自动还原时，面板的 `vhost/`、`config/`、`data/` 整个放回，
站点记录与续期记录都在其中。

⚠️ **证书文件能用 ≠ 会自动续期。** 面板目录整体还原这条路**尚未在真机验证过**：
还原后在面板里逐站确认续期任务还在；不在就**逐站重新申请一次**（算法选 EC256），
否则到期那天面板、订阅、静态站会同时失效。

## 7. 部署元数据

    mkdir -p /root/deploy && cp -a deploy/. /root/deploy/
    chmod 600 /root/deploy/nodes.txt

## 8. 节点

**面板域名没变的话，各节点会自己重连**（machine token 存在数据库里）。

域名变了则每台都要重新绑定：

    xt node --panel https://新域名 --token <该机器Token> --machine-id <SID>

有个别节点不上线时，先查它最后一次上报的时间：停在你停服那一刻 =
agent 卡在重连循环，上去重启即可；停在更早 = 本来就断了。
注意**一台机器可能挂着多个节点**，先按 machine_id 归组再判断。

## 9. 验收

- [ ] 面板能登录，用户/节点/权限组/套餐都在
- [ ] 订阅链接返回 200（curl 要带 -A "clash-verge/v1.5.0"）
- [ ] 节点端日志出现 discovered / started
- [ ] 客户端实测能连
- [ ] `SELECT user,host FROM information_schema.processlist` 里来源是容器网段地址
RESTOREEOF
sed -i "s|{{DB_NAME}}|${DB_NAME}|g; s|{{DB_USER}}|${DB_USER}|g;
        s|{{DB_CLIENT_HOST}}|${DB_CLIENT_HOST}|g; s|{{DOCKER_CIDR}}|${DOCKER_CIDR}|g;
        s|{{XBOARD_DIR}}|${XBOARD_DIR}|g; s|{{PANEL_VHOST_DIR}}|${PANEL_VHOST_DIR}|g;
        s|{{PANEL_CERT_DIR}}|${PANEL_CERT_DIR}|g; s|{{WWWROOT}}|${WWWROOT}|g;
        s|{{ASSETS_SITE}}|${ASSETS_SITE}|g" "$WORK/RESTORE.md"

# 6. 打包加密
log "--- 7z 打包（AES-256，文件名一并加密）---"

# 先打成 tar 再加密：7z 不记文件属主，rootfs 里容器数据（redis 等）的属主会全变成 root。
# 包内路径与旧版一致，只是多解一层 payload.tar.gz；清单和还原说明在外层也放一份。
PACK="$BACKUP_DIR/.pack_${STAMP}"
mkdir -p "$PACK" || fail "无法创建 $PACK"
trap 'rm -rf "$WORK" "$PACK"' EXIT
tar czf "$PACK/payload.tar.gz" -C "$WORK" . || fail "tar 打包失败"
cp "$WORK/MANIFEST.txt" "$WORK/RESTORE.md" "$PACK/"
7z a -t7z -m0=lzma2 -mx=6 -mhe=on -p"$BACKUP_PASS" \
     "$ARCHIVE" "$PACK"/* >/dev/null
SEVEN_RC=$?
rm -rf "$PACK"
[ "$SEVEN_RC" -eq 0 ] || fail "7z 打包失败，退出码 $SEVEN_RC"

log "--- 自检 ---"
# </dev/null 是必需的：-mhe=on 的包在密码不对时会交互式等输入，会把任务挂住
7z t -p"$BACKUP_PASS" "$ARCHIVE" >/dev/null </dev/null
TEST_RC=$?
[ "$TEST_RC" -eq 0 ] || fail "包体自检失败，退出码 $TEST_RC"

ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE")
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
log "包体: $ARCHIVE ($(numfmt --to=iec "$ARCHIVE_SIZE"))"
log "校验和: $(cut -d' ' -f1 < "${ARCHIVE}.sha256")"

# 7. 上传
UPLOAD_FAIL=0
if [ -n "$LOCAL_ONLY" ]; then
    log "只在本地生成（--local-only）：${ARCHIVE}；不上传、不清理"
elif command -v rclone >/dev/null 2>&1; then
    for remote in "${RCLONE_TARGETS[@]}"; do
        log "--- 上传到 $remote ---"
        if rclone copy "$ARCHIVE" "$remote" --transfers 1 --retries 3 2>&1; then
            # 云盘写入后元数据有延迟，立刻校验会误报
            sleep 10
            # 看退出码而不是 grep 提示语 —— 措辞会随 rclone 版本变
            if rclone check "$ARCHIVE" "$remote" --size-only >/dev/null 2>&1; then
                log "$remote 校验通过"
            else
                warn "$remote 上传后校验未通过"; UPLOAD_FAIL=1
            fi
        else
            warn "$remote 上传失败"; UPLOAD_FAIL=1
        fi
    done
else
    warn "未安装 rclone，跳过云端上传（备份只存在于本机）"; UPLOAD_FAIL=1
fi

# 8. 分级保留（GFS，按文件名里的时间戳）。本次上传有失败就一个都不删：
# 这时旧包可能是某个远端上唯一完好的那份。致命错误在前面已经 fail 退出，走不到这里。
[ -n "$LOCAL_ONLY" ] || log "--- 分级保留：全留 ${KEEP_ALL_DAYS} 天，每天一份至 ${KEEP_DAILY_DAYS} 天，每周一份至 ${KEEP_WEEKLY_DAYS} 天，每月一份至上限 ---"
if [ -n "$LOCAL_ONLY" ]; then
    :
elif [ "$UPLOAD_FAIL" -ne 0 ]; then
    log "本次上传有失败，跳过清理"
else
    bk_prune_local "$BACKUP_DIR" xboard "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$LOCAL_KEEP_DAYS"
    for remote in "${RCLONE_TARGETS[@]}"; do
        bk_prune_remote "$remote" xboard "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$CLOUD_KEEP_DAYS"
    done
fi

# 9. 汇总
log "--- 数据库体积 Top10 ---"
sed 's/^/    /' "$WORK/db/table-sizes.txt" 2>/dev/null || true

LOCAL_COUNT=$(find "$BACKUP_DIR" -name 'xboard_*.7z' | wc -l)
log "本地备份份数: $LOCAL_COUNT"

send_mail

if [ ${#WARNINGS[@]} -gt 0 ]; then
    # 有告警也报 fail：别让外部观察者把「部分失败」误判成健康
    hb /fail
    log "=== 完成，但有 ${#WARNINGS[@]} 条告警 ==="
    exit 1
fi
hb
log "=== 备份完成 ==="
exit 0
