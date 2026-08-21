#!/usr/bin/env bash
#
# xboard-fullbackup.sh —— Xboard 面板单包备份
#
# VERSION: 2.2.1
# 2.2.1 变更：XBOARD_SITES 留空时改为**自动扫描 vhost 目录**收集全部站点与证书。
#            写死列表的毛病是：每次在面板增删域名都要记得同步改配置，
#            忘了就报假警（或更糟——静默漏备份一个站）。
# 2.2.0 变更：加反向监控心跳（同 vw-fullbackup）
# 2.1.0 变更：告警发送加重试与落盘兜底（同 vw-fullbackup，实测遇到过瞬时 ENETUNREACH）
# 2.0.1 变更：vhost 改为按 server_name 反查，不再假设文件名等于域名
#            （实测漏了一个站点的 vhost —— 面板给它的文件名带了前缀）
# 2.0.0 变更：环境相关的值全部外置到 /etc/ops-scripts/env.conf，**主体逻辑一行未动**。
#            RESTORE.md 里的域名与 host 段改为按配置生成；补 sleep 10 再校验；
#            7z 自检加 </dev/null（-mhe=on 的包缺密码会交互式等输入）。
#
# 与 vw-fullbackup.sh 保持同一套约定：
#   · 单包、7z AES-256、-mhe=on 连文件名一起加密
#   · 密码从文件读，不出现在命令行
#   · 打包后 7z t 自检，双云上传后 rclone check 校验
#   · 任何一步失败都发邮件告警，退出码非零
#
# ⚠️ cron 里调用本地路径 /usr/local/bin/xboard-fullbackup.sh，**不要写成 opsget**。
#    更新用 `opsget -i backup/xboard-fullbackup` 显式安装。
#

set -uo pipefail

# ==================== 配置（全部来自 env.conf） ====================
ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

req() { local m=""; for v in "$@"; do [ -n "${!v:-}" ] || m="$m $v"; done
        [ -z "$m" ] || { echo "[FATAL] 配置项未填:$m（见 $ENV_FILE）"; exit 1; }; }
req SVC_XBOARD_DIR XBOARD_DB_NAME XBOARD_DB_USER XBOARD_DB_PASS_FILE \
    XBOARD_BACKUP_DIR XBOARD_REMOTE_PATH RCLONE_REMOTES \
    VW_PASS_FILE PANEL_VHOST_DIR PANEL_CERT_DIR WWWROOT DB_CLIENT_HOST DOCKER_CIDR

XBOARD_DIR="$SVC_XBOARD_DIR"
DB_NAME="$XBOARD_DB_NAME"
DB_USER="$XBOARD_DB_USER"
DB_HOST="${XBOARD_DB_HOST:-127.0.0.1}"
DB_PORT="${XBOARD_DB_PORT:-3306}"

DB_PASS_FILE="$XBOARD_DB_PASS_FILE"
# 备份加密密码与 vw-fullbackup 共用同一个文件 —— 只记一个密码，少一处出错的地方
BACKUP_PASS_FILE="$VW_PASS_FILE"

BACKUP_DIR="$XBOARD_BACKUP_DIR"
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

# ==================== 内部 ====================
STAMP=$(date -u +%Y%m%d_%H%M%S)
WORK=$(mktemp -d /tmp/xboard-bak.XXXXXX)
ARCHIVE="$BACKUP_DIR/xboard_${STAMP}.7z"
# LOGPREFIX 已弃用：时间戳改为在 log/warn/fail 内实时生成
WARNINGS=()
FATAL=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log()  { printf '[%s] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { WARNINGS+=("$*"); printf '[%s] [WARN] %s\n' "$(date -u '+%F %T')" "$*" >&2; }
fail() { FATAL="$*"; printf '[%s] [FATAL] %s\n' "$(date -u '+%F %T')" "$*" >&2; hb /fail; send_mail; exit 1; }

send_mail() {
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
    [ -n "${XBOARD_HEARTBEAT_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 "${XBOARD_HEARTBEAT_URL}${1:-}" >/dev/null 2>&1 \
        || printf '[%s] [WARN] 心跳上报失败%s\n' "$(date -u '+%F %T')" "${1:-}" >&2
}

# ==================== 前置检查 ====================
log "=== Xboard 备份开始 ==="
hb /start

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

mkdir -p "$BACKUP_DIR" || fail "无法创建 $BACKUP_DIR"

# 用 defaults-file 传密码，避免出现在 ps 输出里
MYCNF="$WORK/.my.cnf"
umask 077
cat > "$MYCNF" <<EOF
[client]
user=$DB_USER
password=$DB_PASS
host=$DB_HOST
port=$DB_PORT
EOF

# ==================== 1. 数据库 ====================
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

# ==================== 2. 应用文件 ====================
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

# ==================== 3. nginx 与证书 ====================
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
[ -d "${WWWROOT}/${ASSETS_SITE}" ] \
    && cp -a "${WWWROOT}/${ASSETS_SITE}" "$WORK/nginx/assets-site"

# ==================== 4. 部署元数据 ====================
log "--- 打包部署元数据 ---"

mkdir -p "$WORK/deploy"
[ -d /root/deploy ] && cp -a /root/deploy/. "$WORK/deploy/" 2>/dev/null
[ -f /etc/xboard-toolkit.conf ] && cp -a /etc/xboard-toolkit.conf "$WORK/deploy/"
# 配置本身也进包：换机器时照着它填（里面没有密码，只有路径与名称）
cp -a "$ENV_FILE" "$WORK/deploy/env.conf" 2>/dev/null

# ==================== 5. 清单 ====================
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

不在包里（可重建，无需备份）
  · Redis                纯缓存
  · 各节点的 xboard-node 配置    面板里重装即可，machine token 存在数据库里
  · Docker 镜像          docker compose pull 拉回来
  · **面板的证书续期记录**       恢复后必须逐站重新申请，见 RESTORE.md

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

## 0. 解包

    7z x xboard_YYYYMMDD_HHMMSS.7z
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

⚠️ 镜像别重新 pull。compose 里是 `:latest`，重拉可能拿到更新的版本，
   而 Xboard 启动时会跑数据库 migration，把按旧版结构恢复的库改掉。
   原机还在的话用 `docker save` 把镜像搬过去，版本锁死。

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

⚠️ **证书文件能用 ≠ 会自动续期。** 面板的续期记录**不在这个包里**，
恢复后必须**逐站重新申请一次**（算法选 EC256），否则到期那天
面板、订阅、静态站会同时失效。

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

# ==================== 6. 打包加密 ====================
log "--- 7z 打包（AES-256，文件名一并加密）---"

7z a -t7z -m0=lzma2 -mx=6 -mhe=on -p"$BACKUP_PASS" \
     "$ARCHIVE" "$WORK"/* >/dev/null
SEVEN_RC=$?
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

# ==================== 7. 上传 ====================
if command -v rclone >/dev/null 2>&1; then
    for remote in "${RCLONE_TARGETS[@]}"; do
        log "--- 上传到 $remote ---"
        if rclone copy "$ARCHIVE" "$remote" --transfers 1 --retries 3 2>&1; then
            # 云盘写入后元数据有延迟，立刻校验会误报
            sleep 10
            # 看退出码而不是 grep 提示语 —— 措辞会随 rclone 版本变
            if rclone check "$ARCHIVE" "$remote" --size-only >/dev/null 2>&1; then
                log "$remote 校验通过"
            else
                warn "$remote 上传后校验未通过"
            fi
        else
            warn "$remote 上传失败"
        fi
    done
else
    warn "未安装 rclone，跳过云端上传（备份只存在于本机）"
fi

# ==================== 8. 保留策略 ====================
log "--- 清理过期备份 ---"

DELETED=$(find "$BACKUP_DIR" -name 'xboard_*.7z*' -mtime "+$LOCAL_KEEP_DAYS" -print -delete | wc -l)
[ "$DELETED" -gt 0 ] && log "本地清理 $DELETED 个（保留 $LOCAL_KEEP_DAYS 天）"

if command -v rclone >/dev/null 2>&1; then
    for remote in "${RCLONE_TARGETS[@]}"; do
        rclone delete "$remote" --min-age "${CLOUD_KEEP_DAYS}d" --include 'xboard_*.7z*' 2>/dev/null \
            || warn "$remote 清理过期文件失败"
    done
fi

# ==================== 9. 汇总 ====================
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
