#!/bin/bash
#
# 全服务备份：Vaultwarden + Komari + SubConverter + 系统配置
# 打包 → 7z AES-256 加密 → 上传两个网盘
#
# VERSION: 2.2.1
# 2.2.1: 头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
# 2.2.0 变更：加反向监控心跳（dead man's switch）。正向告警盖不住「脚本压根没跑」
#            —— 宕机、cron 挂掉、crontab 被面板重写，这三种情况一封邮件都不会有。
#            心跳由外部观察者盯着：约定时间没收到就由它告警。
# 2.1.0 变更：告警发送加重试与落盘兜底 —— 实测遇到过一次瞬时 ENETUNREACH，
#            单次网络抖动不该让告警丢掉（告警丢了 = 静默失效）
# 2.0.0 变更：环境相关的值全部外置到 /etc/ops-scripts/env.conf，**主体逻辑一行未动**。
#            RESTORE.md 里的账号 host 从写死的 '%' 改为按配置生成，并补了三处提醒。
#
# 依赖：p7zip-full rclone sqlite3 mysql-client(或面板自带) tar
#
# ⚠️ cron 里调用本地路径 /usr/local/bin/vw-fullbackup.sh，**不要写成 opsget**。
#    不能让备份依赖外网才能启动。更新用 `opsget -i backup/vw-fullbackup` 显式安装。
#
# ENV-REQUIRED: VW_BACKUP_DIR VW_PASS_FILE VW_REMOTE_PATH RCLONE_REMOTES SVC_VW_DIR PANEL_VHOST_DIR PANEL_CERT_DIR DB_CLIENT_HOST DOCKER_CIDR
set -o pipefail

########## 配置（全部来自 env.conf，本文件不含任何域名/路径硬编码） ##########
ENV_FILE="${OPS_ENV_FILE:-/etc/ops-scripts/env.conf}"
[ -r "$ENV_FILE" ] || { echo "[FATAL] 缺少配置文件 $ENV_FILE（从 config/env.example.conf 复制）"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

# 缺配置直接退出，绝不回落到某个"看起来合理"的默认值 —— 用错的值静默跑完比报错危险
req() { local m=""; for v in "$@"; do [ -n "${!v:-}" ] || m="$m $v"; done
        [ -z "$m" ] || { echo "[FATAL] 配置项未填:$m（见 $ENV_FILE）"; exit 1; }; }
req VW_BACKUP_DIR VW_PASS_FILE VW_REMOTE_PATH RCLONE_REMOTES \
    SVC_VW_DIR PANEL_VHOST_DIR PANEL_CERT_DIR DB_CLIENT_HOST DOCKER_CIDR

STAGE_ROOT="$VW_BACKUP_DIR"
OUT_DIR="$STAGE_ROOT"
LOG_FILE="${VW_LOG_FILE:-/var/log/vw-fullbackup.log}"
PASS_FILE="$VW_PASS_FILE"
KEEP_LOCAL_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-180}"
KEEP_CLOUD_DAYS="${BACKUP_KEEP_CLOUD_DAYS:-400}"
# 远端由「远端名列表 × 目录名」组合，换云盘或改目录只动 env.conf
REMOTES=(); for r in $RCLONE_REMOTES; do REMOTES+=("${r}:${VW_REMOTE_PATH}"); done
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
########## 工具函数 ##########
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
warn() { WARNINGS=$((WARNINGS+1)); echo "[$(date '+%F %T')] [WARN] $*" | tee -a "$LOG_FILE"; }
die()  { echo "[$(date '+%F %T')] [FATAL] $*" | tee -a "$LOG_FILE"; hb /fail; notify "备份失败: $*"; rm -rf "$STAGE"; exit 1; }

# 失败告警。三条路依次尝试，能通一条就算送达。
# 为什么要重试：SMTP 的瞬时失败（DNS 拿到不可达的 AAAA、NAT 网关抖动）
# 会让告警**直接消失**，而告警消失正是这套系统最怕的那类故障。
notify() {
    local msg="$1" i sent=0
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
    [ -n "${VW_HEARTBEAT_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 "${VW_HEARTBEAT_URL}${1:-}" >/dev/null 2>&1 \
        || echo "[$(date '+%F %T')] [WARN] 心跳上报失败${1:-}" >> "$LOG_FILE"
}

########## 前置检查 ##########
log "========== 开始备份 ${NAME} =========="
hb /start
need tar; need 7z; need rclone; need sqlite3
[ -r "$PASS_FILE" ] || die "密码文件不存在或不可读: $PASS_FILE"
PASS="$(head -n1 "$PASS_FILE")"
[ -n "$PASS" ] || die "密码文件为空"
[ ${#PASS} -ge 16 ] || die "备份密码太短（<16 位），请换成长随机串"
[ -x "$MYSQLDUMP_BIN" ] || die "找不到 mysqldump: $MYSQLDUMP_BIN"

mkdir -p "$STAGE"/{db,vaultwarden,komari,subconverter,system} "$OUT_DIR" || die "无法创建暂存目录"
trap 'rm -rf "$STAGE"' EXIT

########## 1. Vaultwarden 数据库 ##########
# 直接从 env 解析连接串，不重复保存密码
DBURL="$(grep -m1 '^DATABASE_URL=' "$VW_DIR/vaultwarden.env" 2>/dev/null | cut -d= -f2-)"
if [ -n "$DBURL" ]; then
    DBUSER="$(echo "$DBURL" | sed -E 's#^mysql://([^:]+):.*#\1#')"
    DBPASS="$(echo "$DBURL" | sed -E 's#^mysql://[^:]+:([^@]*)@.*#\1#')"
    DBHOST="$(echo "$DBURL" | sed -E 's#^mysql://[^@]+@([^:/]+).*#\1#')"
    DBNAME="$(echo "$DBURL" | sed -E 's#.*/([^/?]+)$#\1#')"
    [ "$DBHOST" = "host.docker.internal" ] && DBHOST="127.0.0.1"
    log "导出数据库 ${DBNAME}@${DBHOST} ..."
    if "$MYSQLDUMP_BIN" -h"$DBHOST" -u"$DBUSER" -p"$DBPASS" \
         --no-tablespaces --single-transaction --routines \
         --default-character-set=utf8mb4 "$DBNAME" 2>>"$LOG_FILE" \
         | gzip > "$STAGE/db/${DBNAME}.sql.gz"; then
        SZ=$(du -h "$STAGE/db/${DBNAME}.sql.gz" | cut -f1)
        [ -s "$STAGE/db/${DBNAME}.sql.gz" ] || die "数据库导出为空文件"
        log "  ✓ ${DBNAME} dump 完成 (${SZ})"
        # 记录账号授权（还原时要照着重建用户，host 段错了容器就连不上）
        "$MYSQL_BIN" -h"$DBHOST" -u"$DBUSER" -p"$DBPASS" -N -B \
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

########## 2. Vaultwarden 数据与配置 ##########
log "收集 Vaultwarden 数据 ..."
tar cf - -C "$VW_DIR" --exclude='icon_cache' --exclude='*.log' --exclude='tmp' data 2>/dev/null \
    | tar xf - -C "$STAGE/vaultwarden" || warn "Vaultwarden data 复制异常"
[ -f "$STAGE/vaultwarden/data/rsa_key.pem" ] || warn "rsa_key.pem 缺失！设备会被强制登出"
for f in vaultwarden.env compose.yaml; do
    [ -f "$VW_DIR/$f" ] && cp -a "$VW_DIR/$f" "$STAGE/vaultwarden/" || warn "缺少 $f"
done

########## 3. Komari ##########
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

########## 4. SubConverter ##########
log "收集 SubConverter 配置 ..."
if [ -n "$SUBCONV_DIR" ] && [ -d "$SUBCONV_DIR" ]; then
    cp -a "$SUBCONV_DIR/." "$STAGE/subconverter/" 2>/dev/null || warn "SubConverter 复制异常"
else
    warn "未找到 SubConverter 目录: ${SUBCONV_DIR:-未配置}"
fi

########## 5. 系统配置 ##########
log "收集系统配置 ..."
mkdir -p "$STAGE/system"/{nginx,cert,docker}
cp -a "$BT_VHOST"/*.conf "$STAGE/system/nginx/" 2>/dev/null || warn "站点配置复制异常"
cp -a "$BT_CERT"/. "$STAGE/system/cert/" 2>/dev/null || warn "证书复制异常"
[ -f /root/.config/rclone/rclone.conf ] && cp -a /root/.config/rclone/rclone.conf "$STAGE/system/"
crontab -l > "$STAGE/system/crontab.txt" 2>/dev/null
cp -a "$0" "$STAGE/system/" 2>/dev/null
# 配置本身也进包：换机器时照着它填，比回忆快得多（里面没有密码，只有路径与名称）
cp -a "$ENV_FILE" "$STAGE/system/env.conf" 2>/dev/null
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

########## 6. 清单与还原说明 ##########
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
    ls "$BT_VHOST"/*.conf 2>/dev/null | xargs -n1 basename
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
mkdir -p /root/data && cp komari/komari.db /root/data/
cp -a komari/plugin komari/plugin-data /root/data/ 2>/dev/null
# 启动命令见 system/docker/run-commands.sh
```
主题需要在面板里重新下载（清单见 komari/theme-list.txt）。
**监控历史不在备份内，重建后从零开始记录，agent token 在 komari.db 里，被控端不用重装。**

⚠️ **指标库的连接串写在 komari.db 的 `configs` 表里**，不是环境变量。
如果里面是宿主机的公网 IP，换到 NAT 后面的机器就连不上 —— 改成网桥网关地址：

```bash
sqlite3 /root/data/komari.db "SELECT rowid,value FROM configs WHERE value LIKE '%3306%'"
```

## 4. SubConverter
```bash
mkdir -p /opt/SubConverter-Extended && cp -a subconverter/. /opt/SubConverter-Extended/
# 启动命令见 system/docker/run-commands.sh
```
`pref.toml` 是全部自定义配置的唯一载体，**不要用上游示例覆盖它**。

## 5. Nginx 与证书
```bash
cp system/nginx/*.conf /www/server/panel/vhost/nginx/
cp -a system/cert/. /www/server/panel/vhost/cert/
nginx -t && systemctl reload nginx
```
面板里需要重新"添加站点"，否则面板认不得这些配置。

⚠️ **证书文件能用 ≠ 会自动续期。** 面板的续期记录**不在这个包里**，
恢复后必须**逐站重新申请一次**（算法选 EC256），否则到期那天全站一起挂。

## 6. rclone 与定时任务
```bash
mkdir -p /root/.config/rclone && cp system/rclone.conf /root/.config/rclone/
rclone listremotes
crontab system/crontab.txt   # 先看一遍再导入
```
⚠️ crontab 顶部必须有 `PATH=`，且每行都要有输出重定向 —— 缺了会让脚本
在手动跑正常、定时跑失败，且报错发给收不到的 root@主机名。

## 7. 验收
- [ ] `https://域名/alive` 返回 200
- [ ] 用原邮箱 + 原主密码登录，条目数与 manifest 对得上
- [ ] TOTP 二步验证可用
- [ ] 通行密钥：换域名的话需在「账户设置 → 安全 → 两步登录」重新注册
- [ ] Komari 面板能看到原有被控端，且日志有 `Metric store initialized successfully`
- [ ] 订阅转换接口能正常返回
- [ ] `SELECT user,host FROM information_schema.processlist` 里来源是容器网段地址
RESTOREEOF
sed -i "s|{{DB_CLIENT_HOST}}|${DB_CLIENT_HOST}|g; s|{{DOCKER_CIDR}}|${DOCKER_CIDR}|g" \
    "$STAGE/RESTORE.md"

########## 7. 打包加密 ##########
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

########## 8. 上传 ##########
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

########## 9. 保留策略 ##########
log "清理本地超过 ${KEEP_LOCAL_DAYS} 天的备份 ..."
find "$OUT_DIR" -maxdepth 1 -name 'srvbak_*.7z*' -type f -mtime +$KEEP_LOCAL_DAYS -print -delete | tee -a "$LOG_FILE"

for remote in "${REMOTES[@]}"; do
    rclone delete "$remote/" --include 'srvbak_*.7z*' --min-age "${KEEP_CLOUD_DAYS}d" \
        >>"$LOG_FILE" 2>&1 && log "  ✓ ${remote%%:*} 已清理 ${KEEP_CLOUD_DAYS} 天前的备份"
done

########## 收尾 ##########
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
