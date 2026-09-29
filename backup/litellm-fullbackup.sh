#!/usr/bin/env bash
# backup/litellm-fullbackup.sh — 从汇总机拉取 LiteLLM 节点的库导出与工作目录，加密上传
# VERSION: 1.0.0
# 1.0.0: 首版。远端 pg_dump -Fc 一致性导出并用容器自己的 pg_restore --list 校验；工作目录（.env 等，不含 pgdata 与日志）；三个容器的镜像 digest 与 inspect；GFS 分级保留，防重入锁，心跳。
# ENV-REQUIRED: LITELLM_HOST LITELLM_WORKDIR LITELLM_BACKUP_DIR BACKUP_PASS_FILE RCLONE_REMOTES MAIL_TO
# 定时任务调用已安装的本地脚本（ops/install-backup-cron，每 6 小时 :40）。Redis 只是缓存，不备份（见 RESTORE.md）。

set -o pipefail
# 暂存区里是明文的 .env（LITELLM_SALT_KEY、master key）和整库导出，一律 700 / 600
umask 077

# 公共库：分级保留、镜像 digest、主机清单。opsget -i 安装本脚本时会同步到同一版本。
# 先加载，下面本脚本自己的 log / warn / finish 等会覆盖库里的同名函数。
LIB_OK=0
# shellcheck disable=SC1091
{ . /usr/local/lib/ops-common.sh || . "$(dirname "$0")/../lib/common.sh"; } 2>/dev/null && LIB_OK=1

ENV_FILE=/etc/ops-scripts/env.conf
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

TS="$(date -u +%Y%m%d_%H%M%S)"
LOG="${LITELLM_BACKUP_LOG:-/var/log/litellm-fullbackup.log}"
# 每 6 小时一次，档位与 vw / xboard 共用
KEEP_ALL_DAYS="${BACKUP_KEEP_ALL_DAYS:-7}"
KEEP_DAILY_DAYS="${BACKUP_KEEP_DAILY_DAYS:-30}"
KEEP_WEEKLY_DAYS="${BACKUP_KEEP_WEEKLY_DAYS:-90}"
LOCAL_KEEP_DAYS="${BACKUP_KEEP_LOCAL_DAYS:-180}"
CLOUD_KEEP_DAYS="${BACKUP_KEEP_CLOUD_DAYS:-400}"
CLOUD_DIR="${LITELLM_CLOUD_DIR:-Backup-LiteLLM}"
ALERT_FALLBACK_FILE="${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
# 容器名与 ops/deploy-litellm 写进 compose 的一致
PG_CONTAINER=litellm-postgres
CONTAINERS="litellm litellm-postgres litellm-redis"

WARN=0
FAIL=0

# 时间戳在调用时计算，不用启动时冻结的变量
log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; WARN=$((WARN+1)); }
fail() { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; FAIL=$((FAIL+1)); }

# 心跳：成功 ping 根路径，失败 ping /fail，开始 ping /start
hb() {
  [ -z "${LITELLM_HEARTBEAT_URL:-}" ] && return 0
  curl -fsS -m 10 --retry 2 "${LITELLM_HEARTBEAT_URL}$1" >/dev/null 2>&1 || true
}

# webhook 的 JSON 要转义：正文是日志尾部，含引号、反斜杠或换行
json_esc() {
  printf '%s' "$1" | tr -d '\r' \
    | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); if (NR>1) print "\\n"; print}'
}

# 三次重试 + webhook 兜底 + 落盘兜底
send_mail() {
  local subject="$1" body="$2"
  if command -v msmtp >/dev/null 2>&1 && [ -n "${MAIL_TO:-}" ]; then
    for _ in 1 2 3; do
      printf 'To: %s\nSubject: %s\n\n%s\n' "$MAIL_TO" "$subject" "$body" \
        | msmtp -t 2>>"$LOG" && return 0
      sleep 20
    done
  fi
  if [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -fsS -m 15 -X POST "$ALERT_WEBHOOK" \
      -H 'Content-Type: application/json' \
      --data "{\"text\":\"$(json_esc "$subject"$'\n'"$body")\"}" \
      >/dev/null 2>&1 && return 0
  fi
  printf '%s %s\n%s\n---\n' "$(date -u '+%F %T')" "$subject" "$body" \
    >> "$ALERT_FALLBACK_FILE" 2>/dev/null
  return 1
}

finish() {
  local rc=$1
  if [ "$FAIL" -gt 0 ] || [ "$rc" -ne 0 ]; then
    hb /fail
    send_mail "[FAIL] LiteLLM backup $TS" "$(tail -n 60 "$LOG")"
    log "结束：FAIL=$FAIL WARN=$WARN 传入码=$rc 实际退出码=1"
    exit 1
  elif [ "$WARN" -gt 0 ]; then
    hb /fail
    send_mail "[WARN] LiteLLM backup $TS" "$(tail -n 60 "$LOG")"
    log "结束：WARN=$WARN"
    exit 0
  else
    hb ""
    log "结束：正常"
    exit 0
  fi
}

require_env() {
  local k
  for k in "$@"; do
    [ -n "${!k:-}" ] || { fail "env.conf 缺少必填项 $k"; finish 1; }
  done
}

# 防重入：上一轮若因上传慢还没结束，两轮会同时清理同一批包。
# 撞上就直接退出、不报心跳：一直撞上时由心跳监控发现「没按时完成」。
mkdir -p /run/lock
exec 9>/run/lock/litellm-fullbackup.lock || { fail "无法创建锁文件 /run/lock/litellm-fullbackup.lock"; finish 1; }
flock -n 9 || { log "上一轮备份还在运行，本次跳过"; exit 0; }

hb /start
log "===== LiteLLM 备份开始 $TS ====="
[ "$LIB_OK" -eq 1 ] && declare -F bk_gfs_select >/dev/null && declare -F vps_host_port >/dev/null \
  || { fail "公共库缺失或版本过旧（需要 1.2.3 起），先运行 opsget -u"; finish 1; }

require_env LITELLM_HOST LITELLM_WORKDIR LITELLM_BACKUP_DIR BACKUP_PASS_FILE RCLONE_REMOTES MAIL_TO

for c in 7z rclone ssh tar sha256sum flock; do
  command -v "$c" >/dev/null 2>&1 || { fail "本机缺少命令：$c"; finish 1; }
done

[ -r "$BACKUP_PASS_FILE" ] || { fail "读不到密码文件 $BACKUP_PASS_FILE"; finish 1; }
PASS="$(tr -d '\r\n' < "$BACKUP_PASS_FILE")"
[ "${#PASS}" -ge 16 ] || { fail "备份密码长度不足 16 位"; finish 1; }

# SSH 端口：env.conf 的 LITELLM_SSH_PORT > ~/.vps-hosts.txt（与 ops/deploy-litellm 同一份清单）> 22
if [ -n "${LITELLM_SSH_PORT:-}" ]; then
  SSH_PORT=$LITELLM_SSH_PORT; PORT_FROM=LITELLM_SSH_PORT
elif SSH_PORT=$(vps_host_port "$LITELLM_HOST") && [ -n "$SSH_PORT" ]; then
  PORT_FROM="$HOME/.vps-hosts.txt"
else
  SSH_PORT=22; PORT_FROM="默认"
fi
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$LITELLM_HOST" true 2>>"$LOG" \
  || { fail "SSH 连不上 $LITELLM_HOST:$SSH_PORT（端口来自 $PORT_FROM）"; finish 1; }
log "LiteLLM 节点 SSH 可达（$LITELLM_HOST:$SSH_PORT，端口来自 $PORT_FROM）"

mkdir -p "$LITELLM_BACKUP_DIR" || { fail "建不了 $LITELLM_BACKUP_DIR"; finish 1; }
STAGE="$LITELLM_BACKUP_DIR/.staging_$TS"
P="$STAGE/payload"
mkdir -p "$P" || { fail "建不了暂存目录"; finish 1; }
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# ── 在节点上生成快照并流式拉回 ──────────────────────────────
# 引号 heredoc：不在本机展开；参数经远端命令行的环境变量传进去
REMOTE_SNAP=$(cat <<'REMOTE_EOF'
set -o pipefail
die()  { echo "[节点] $*" >&2; exit 1; }
warn() { echo "[节点] $*" >&2; }
D=$(mktemp -d /tmp/litellm-snap-XXXXXX) || die "建不了临时目录"
trap 'rm -rf "$D"' EXIT
[ -d "$W" ] || die "没有工作目录 $W"
[ -s "$W/.env" ] || die "$W/.env 不存在或为空（LITELLM_SALT_KEY 在里面）"
grep -q '^LITELLM_SALT_KEY=.' "$W/.env" || die "$W/.env 里没有 LITELLM_SALT_KEY"
command -v docker >/dev/null 2>&1 || die "没有 docker"
[ "$(docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null)" = true ] || die "容器 $PG 没在运行"
mkdir -p "$D/db" "$D/workdir" "$D/system"

# pg_dump 在一个事务快照里读：库照常服务，导出的是同一时刻的一致状态。
# 绝不复制运行中的 pgdata —— 那是写到一半的数据文件，拿回去起不来或静默损坏。
docker exec "$PG" pg_dump -U litellm -Fc litellm > "$D/db/litellm.dump" 2> "$D/err" \
  || die "pg_dump 失败：$(tail -n 3 "$D/err")"
[ -s "$D/db/litellm.dump" ] || die "pg_dump 输出为空"
# 用容器自己（同版本）的 pg_restore 读一遍目录：读得开才算导出可用
docker exec -i "$PG" pg_restore --list < "$D/db/litellm.dump" > "$D/db/litellm.toc" 2> "$D/err" \
  || die "pg_restore --list 读不了这份导出：$(tail -n 3 "$D/err")"
(cd "$D/db" && sha256sum litellm.dump > litellm.dump.sha256) || die "算不了导出的校验和"
rm -f "$D/err"

# 行数抽样：只计数、不读内容；表不存在记 n/a
for t in LiteLLM_ProxyModelTable LiteLLM_VerificationToken LiteLLM_UserTable LiteLLM_TeamTable LiteLLM_Config; do
  n=$(docker exec "$PG" psql -U litellm -d litellm -Atc "SELECT count(*) FROM \"$t\"" 2>/dev/null) || n=
  printf '%s\t%s\n' "$t" "${n:-n/a}"
done > "$D/db/row-counts.tsv"

# 工作目录：除 pgdata（已导出）与日志外全收 —— .env、config.yaml、docker-compose.yml
tar -C "$W" --exclude=./pgdata --exclude=./logs --exclude='*.log' -cf - . \
  | tar -C "$D/workdir" -xpf - || die "工作目录复制失败"

# 镜像 digest（bk_images 由汇总机的公共库送过来）与容器参数
# shellcheck disable=SC2086
bk_images "$D/images.tsv" $CONTAINERS
for c in $CONTAINERS; do
  docker inspect "$c" > "$D/system/inspect-$c.json" 2>/dev/null || rm -f "$D/system/inspect-$c.json"
done
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$D/system/container-ps.txt" 2>/dev/null
docker version --format '{{.Server.Version}}' > "$D/system/docker-version.txt" 2>/dev/null
uname -a > "$D/system/uname.txt" 2>/dev/null
(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") > "$D/system/os-release.txt" 2>/dev/null
df -h "$W" > "$D/system/df.txt" 2>/dev/null
tar czf - -C "$D" . || die "打包传输失败"
REMOTE_EOF
)

log "在节点上导出 Postgres（pg_dump -Fc）并打包工作目录"
REMOTE_ENV="W=$(printf '%q' "$LITELLM_WORKDIR") PG=$PG_CONTAINER CONTAINERS='$CONTAINERS'"
if ! { declare -f bk_images; printf '%s\n' "$REMOTE_SNAP"; } \
  | ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$LITELLM_HOST" "$REMOTE_ENV bash -s" 2>"$STAGE/remote.err" \
  | tar xzf - -C "$P" 2>>"$STAGE/remote.err"; then
  sed 's/^/    /' "$STAGE/remote.err" | tee -a "$LOG"
  fail "快照生成或传输失败（原因见上）"
  finish 1
fi
# 节点上的非致命提示（如某个镜像没有 RepoDigest）也记进日志
[ -s "$STAGE/remote.err" ] && sed 's/^/    /' "$STAGE/remote.err" >> "$LOG"

# ── 本机复核 ────────────────────────────────────────────────
DUMP="$P/db/litellm.dump"
[ -s "$DUMP" ] || { fail "拉回的导出为空"; finish 1; }
[ "$(head -c 5 "$DUMP")" = PGDMP ] || { fail "拉回的不是 pg_dump 自定义格式（缺 PGDMP 文件头）"; finish 1; }
(cd "$P/db" && sha256sum -c --quiet litellm.dump.sha256) >>"$LOG" 2>&1 \
  || { fail "导出的校验和与节点上算的不符（传输损坏）"; finish 1; }
[ -s "$P/db/litellm.toc" ] || { fail "缺少 pg_restore --list 的目录"; finish 1; }
DUMPSIZE=$(stat -c %s "$DUMP")
NTAB=$(grep -cE '^[0-9]+; [0-9]+ [0-9]+ TABLE DATA ' "$P/db/litellm.toc")
log "导出到手：${DUMPSIZE} 字节，pg_restore --list 通过，含 ${NTAB} 张表的数据"
[ "$NTAB" -gt 0 ] || warn "导出里一张表的数据都没有（库是空的？）"
grep -qE ' TABLE DATA public "?LiteLLM_ProxyModelTable"? ' "$P/db/litellm.toc" \
  || warn "导出里没有 LiteLLM_ProxyModelTable 的数据（面板添加的模型与上游 Key 存在这张表）"
while IFS=$'\t' read -r t n; do log "  行数 $t: $n"; done < "$P/db/row-counts.tsv"

ENVF="$P/workdir/.env"
[ -s "$ENVF" ] || { fail "工作目录里没有 .env"; finish 1; }
for k in LITELLM_SALT_KEY LITELLM_MASTER_KEY POSTGRES_PASSWORD; do
  grep -q "^$k=." "$ENVF" || warn ".env 里没有 $k"
done
for f in config.yaml docker-compose.yml; do
  [ -s "$P/workdir/$f" ] || warn "工作目录里没有 $f"
done
[ -e "$P/workdir/pgdata" ] && { fail "pgdata 混进了包（应只有导出）"; finish 1; }
# 盐值的指纹（不是盐值本身）：恢复时核对 .env 与离线应急包里的是同一个
SALT_FP=$(grep -m1 '^LITELLM_SALT_KEY=' "$ENVF" | cut -d= -f2- | tr -d '\r\n' | sha256sum | cut -c1-12)
log ".env 在包里（LITELLM_SALT_KEY 指纹 ${SALT_FP}）"

while IFS=$'\t' read -r c img dig; do
  case "$c" in '#'*|'') continue ;; esac
  if [ "$img" = - ]; then warn "容器 $c 不存在，镜像没有记下"
  elif [ "$dig" = - ]; then warn "容器 $c 的镜像 $img 没有 RepoDigest，还原时无法按 digest 锁定"
  else log "  镜像 $c: $dig"; fi
done < "$P/images.tsv"

# 镜像换成 digest 的 compose：恢复时用它，不按可能已漂移的标签拉
COMPOSE="$P/workdir/docker-compose.yml"
if [ -s "$COMPOSE" ]; then
  awk -F'\t' 'NR == FNR { if ($1 !~ /^#/ && $2 != "-" && $3 != "-") d[$2] = $3; next }
    match($0, /^[[:space:]]*image:[[:space:]]*/) {
      img = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", img)
      if (img in d) { print substr($0, 1, RLENGTH) d[img]; next } }
    { print }' "$P/images.tsv" "$COMPOSE" > "$P/system/docker-compose.pinned.yml"
  grep -qE '^[[:space:]]*image:[[:space:]]*ghcr\.io/berriai/litellm@sha256:' "$P/system/docker-compose.pinned.yml" \
    || warn "docker-compose.pinned.yml 里 LiteLLM 镜像没能锁到 digest"
fi
PORT=$(grep -oE '127\.0\.0\.1:[0-9]+:4000' "$COMPOSE" 2>/dev/null | head -1 | cut -d: -f2)
PORT=${PORT:-${LITELLM_PORT:-4000}}

# ── 清单与还原说明 ──────────────────────────────────────────
{
  echo "LiteLLM backup manifest"
  echo "打包时间(UTC): $(date -u '+%F %T')"
  echo "节点: $LITELLM_HOST:$SSH_PORT"
  echo "工作目录: $LITELLM_WORKDIR"
  echo "LITELLM_SALT_KEY 指纹(sha256 前 12 位): $SALT_FP"
  echo "---- 镜像 ----"; cat "$P/images.tsv"
  echo "---- 备份时的行数 ----"; cat "$P/db/row-counts.tsv"
  echo "---- 文件清单 ----"
  (cd "$P" && find . -type f -printf '%10s  %p\n' | sort -k2)
} > "$P/manifest.txt"

# heredoc 加引号：避免 $ 被展开；需替换处用 {{占位符}}，生成后再 sed
cat > "$P/RESTORE.md" <<'RESTORE_EOF'
# LiteLLM 恢复步骤

> ## ⚠️ LITELLM_SALT_KEY 必须是原来那一个
>
> 面板里添加的模型和上游 API Key 存在 Postgres 里，用 `LITELLM_SALT_KEY` 加密。
> 换了盐值（包括「重新部署一套、生成新的 .env」），库照样导得进去、服务照样起得来，
> 但所有已存的上游凭据都解不开，调用全部失败，**而且没有任何办法找回**。
> 原值就在本包的 `workdir/.env` 里，离线应急包里也应有一份。**绝不要重新生成。**
>
> 本包盐值的指纹（sha256 前 12 位）：`{{SALT_FP}}`。核对（在解包目录里）：
>
> ```bash
> grep -m1 '^LITELLM_SALT_KEY=' workdir/.env | cut -d= -f2- | tr -d '\r\n' | sha256sum | cut -c1-12
> ```

## 包里有什么

| 路径 | 内容 |
| --- | --- |
| `workdir/` | 原工作目录 `{{WORKDIR}}`：`.env`、`config.yaml`、`docker-compose.yml`，不含 `pgdata/` 和日志 |
| `db/litellm.dump` | `pg_dump -Fc` 一致性导出（备份时已用容器自己的 `pg_restore --list` 读过一遍） |
| `db/litellm.toc`、`db/row-counts.tsv` | 导出的目录；备份时几张关键表的行数，恢复后拿来对照 |
| `images.tsv` | 三个容器的镜像与 RepoDigest |
| `system/docker-compose.pinned.yml` | 镜像换成 digest 的 compose，恢复用它 |
| `system/inspect-*.json` | 备份时 `docker inspect` 的完整输出 |

**Redis 不在包里**：它只是响应缓存，compose 里本来就关了持久化（`--save "" --appendonly no`），
每次重启都是空的。恢复后从空缓存开始，不影响任何数据。

有备用机的话，先用 `opsget ops/litellm-drill restore <备用机IP> <本包路径>` 演练一遍，它按下面同样的步骤做。

## 1. 装 docker（已有就跳过）

```bash
curl -fsSL https://get.docker.com | sh
docker compose version
```

## 2. 解包

```bash
7z x litellm_{{TS}}.7z -olitellm-restore      # 按提示输入备份密码
cd litellm-restore && R=$PWD                  # 下面用 $R 指解包目录
```

## 3. 先放回工作目录和 .env

```bash
mkdir -p {{WORKDIR}}
cp -a workdir/. {{WORKDIR}}/
chmod 600 {{WORKDIR}}/.env
cp system/docker-compose.pinned.yml {{WORKDIR}}/docker-compose.yml   # 原文件仍在 workdir/ 里
```

**.env 必须在起任何容器之前放好**：Postgres 第一次启动时按 `.env` 里的 `POSTGRES_PASSWORD` 初始化账号，
LiteLLM 启动时读 `LITELLM_SALT_KEY`。先起容器、后补 `.env`，库密码和 `DATABASE_URL` 就对不上了。
`{{WORKDIR}}/pgdata` 必须不存在或为空（有旧数据时 postgres 镜像不会重新初始化）。

## 4. 只起 Postgres，导入

compose 里的**服务名是 `postgres`**（`litellm-postgres` 是容器名）：

```bash
cd {{WORKDIR}}
docker compose up -d postgres
until docker exec litellm-postgres pg_isready -U litellm -d litellm; do sleep 2; done
docker exec -i litellm-postgres pg_restore -U litellm -d litellm --clean --if-exists < "$R/db/litellm.dump"
echo "pg_restore 退出码 $?（0 才算成功）"
docker exec litellm-postgres psql -U litellm -d litellm -Atc 'SELECT count(*) FROM "LiteLLM_ProxyModelTable"'
```

最后一行的模型数应与 `db/row-counts.tsv` 里 `LiteLLM_ProxyModelTable` 一致。

## 5. 起全部（LiteLLM 按备份时的 digest）

```bash
docker compose up -d
docker compose ps
```

`litellm` 的镜像应是 `images.tsv` 里的 digest。**不要改回标签或 `latest`**：新版本启动时会迁移库结构，迁移不可逆。

## 6. 验证

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:{{PORT}}/health/liveliness
```

返回 200 即服务起来了。再用 master key 列模型（key 经 stdin 交给 curl，不进命令行）：

```bash
grep -m1 '^LITELLM_MASTER_KEY=' .env | cut -d= -f2- | sed 's/^/Authorization: Bearer /' \
  | curl -s -H @- http://127.0.0.1:{{PORT}}/v1/models; echo
```

列表里的模型应与备份前一致。**列表出来只说明库导进去了（模型名不加密），盐值对不对要实际调用一次**：
开隧道进面板（`http://127.0.0.1:{{PORT}}/ui`，用户名 admin，密码是 master key），在 Models 里对每条点 Test；
全部失败、日志里有解密错误（`docker logs litellm 2>&1 | grep -iE 'decrypt|salt'`），就是盐值不对 ——
停下，找回原来的 `.env`，不要在面板里重新填 Key 覆盖。

## 7. 换机要同步改的

1. 汇总机 `env.conf` 的 `LITELLM_HOST`（以及 `LITELLM_SSH_PORT` 或 `~/.vps-hosts.txt` 里的端口）
2. **新节点的 SSH 要让汇总机连得上**，否则下一次定时备份就失败：
   - ufw 放行名单照原节点配（本地出口 IP、汇总机 / 前置机、各节点机），**汇总机的 IP 必须在里面**：
     `ufw allow from <汇总机IP> to any port <SSH端口> proto tcp`
   - **两步验证对汇总机的 IP 豁免**：定时备份是密钥非交互登录，输不了验证码。豁免照原节点（或落地机）抄，
     在那边用 `grep -rn '<汇总机IP>' /etc/ssh /etc/pam.d /etc/security` 找；改完 `sshd -t`，保持旧窗口重启 ssh
   - 汇总机的公钥加进 `/root/.ssh/authorized_keys`
   - 在汇总机上确认能免验证码连过来：`ssh -o BatchMode=yes -p <SSH端口> root@<新节点IP> true`，再手动跑一次 `litellm-fullbackup.sh`
   - 以后汇总机换 IP，节点上的 ufw 放行和两步验证豁免**两处都要改**
3. 前置机到 LiteLLM 的 SSH 隧道与 nginx 反代里的目标 IP
4. `LITELLM_SITE` 的白名单：新节点出口若要访问前置机，重新跑 `opsget ops/sync-llm-allowlist`
5. 新节点要能直连上游（不在被拒地区）：无 Key 请求 `https://api.openai.com/v1/models` 返回 401 而不是 403
RESTORE_EOF

sed -i -e "s|{{WORKDIR}}|${LITELLM_WORKDIR}|g" -e "s|{{PORT}}|${PORT}|g" \
       -e "s|{{SALT_FP}}|${SALT_FP}|g" -e "s|{{TS}}|${TS}|g" "$P/RESTORE.md"

# env.conf 的结构副本（只留键名与非敏感值，供还原时对照）
if [ -r "$ENV_FILE" ]; then
  grep -vE '(PASS|SECRET|TOKEN|KEY|HEARTBEAT|WEBHOOK)' "$ENV_FILE" \
    > "$P/system/env.conf.sample" 2>/dev/null || true
fi

# ── 打包、上传、清理 ────────────────────────────────────────
ARCHIVE="$LITELLM_BACKUP_DIR/litellm_${TS}.7z"
log "打包为 $ARCHIVE"
# 顶层没有点文件；workdir/.env 在子目录里，7z 递归时会收
if ! 7z a -t7z -m0=lzma2 -mx=5 -mhe=on -p"$PASS" "$ARCHIVE" "$P/"* >>"$LOG" 2>&1; then
  fail "7z 打包失败"
  finish 1
fi
# -mhe=on 的包在管道里不喂 stdin 会挂住
if ! 7z t -p"$PASS" "$ARCHIVE" < /dev/null >>"$LOG" 2>&1; then
  fail "7z 自检未通过，包可能损坏"
  finish 1
fi
PKGSIZE=$(stat -c %s "$ARCHIVE")
log "打包完成并自检通过，体积 ${PKGSIZE} 字节"

# 校验和旁注：避开 SHA256SUMS 自引用
( cd "$LITELLM_BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
log "已生成 .sha256 旁注文件"

UPLOADED=0
for R in $RCLONE_REMOTES; do
  log "上传到 ${R}:/${CLOUD_DIR}"
  if rclone copy "$ARCHIVE" "${R}:/${CLOUD_DIR}/" >>"$LOG" 2>&1 \
     && rclone copy "${ARCHIVE}.sha256" "${R}:/${CLOUD_DIR}/" >>"$LOG" 2>&1; then
    # Google Drive 元数据有延迟，立刻 check 会误报
    sleep 10
    if rclone check "$LITELLM_BACKUP_DIR" "${R}:/${CLOUD_DIR}" \
         --include "$(basename "$ARCHIVE")" >>"$LOG" 2>&1; then
      log "${R} 校验通过"
      UPLOADED=$((UPLOADED+1))
    else
      warn "${R} 上传后校验失败"
    fi
  else
    warn "${R} 上传失败"
  fi
done
[ "$UPLOADED" -eq 0 ] && fail "所有云端目标都没上传成功"

# 分级保留（GFS，按文件名里的时间戳）。有任何远端没传成功就一个都不删：
# 这时旧包可能是某个远端上唯一完好的那份。
read -r -a REMOTE_LIST <<< "$RCLONE_REMOTES"
NREMOTES=${#REMOTE_LIST[@]}
if [ "$FAIL" -gt 0 ] || [ "$UPLOADED" -lt "$NREMOTES" ]; then
  log "本次有失败（成功上传 ${UPLOADED}/${NREMOTES}），跳过清理"
else
  log "分级保留：全留 ${KEEP_ALL_DAYS} 天，每天一份至 ${KEEP_DAILY_DAYS} 天，每周一份至 ${KEEP_WEEKLY_DAYS} 天，每月一份至上限"
  bk_prune_local "$LITELLM_BACKUP_DIR" litellm "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$LOCAL_KEEP_DAYS"
  for R in $RCLONE_REMOTES; do
    bk_prune_remote "${R}:/${CLOUD_DIR}" litellm "$KEEP_ALL_DAYS" "$KEEP_DAILY_DAYS" "$KEEP_WEEKLY_DAYS" "$CLOUD_KEEP_DAYS"
  done
fi

log "汇总：导出 ${DUMPSIZE} 字节，包体 ${PKGSIZE} 字节，成功上传 ${UPLOADED} 处，WARN=${WARN} FAIL=${FAIL}"
finish 0
