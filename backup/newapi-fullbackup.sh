#!/usr/bin/env bash
# backup/newapi-fullbackup.sh — 从汇总机拉取 new-api 数据，生成一致性快照并加密上传
# VERSION: 1.0.2
# 1.0.2: 整理注释并补充目录文档，执行逻辑未变。
# ENV-REQUIRED: NEWAPI_HOST NEWAPI_SSH_PORT NEWAPI_DATA_DIR NEWAPI_BAK_DIR BACKUP_PASS_FILE MAIL_TO
# 定时任务调用已安装的本地脚本；SQLite 使用在线备份生成一致性快照。

set -o pipefail

# 配置载入
ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

TS="$(date -u +%Y%m%d_%H%M%S)"
LOG="${NEWAPI_BACKUP_LOG:-/var/log/newapi-fullbackup.log}"
LOCAL_KEEP_DAYS="${NEWAPI_LOCAL_KEEP_DAYS:-180}"
CLOUD_KEEP_DAYS="${NEWAPI_CLOUD_KEEP_DAYS:-400}"
CLOUD_DIR="${NEWAPI_CLOUD_DIR:-Backup-NewAPI}"
RCLONE_REMOTES="${NEWAPI_RCLONE_REMOTES:-onedrive gdrive}"
CONTAINER="${NEWAPI_CONTAINER:-new-api}"
ALERT_FALLBACK_FILE="${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"

WARN=0
FAIL=0

# 日志与告警
# 时间戳在调用时计算，不用启动时冻结的变量
log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; WARN=$((WARN+1)); }
fail() { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*" | tee -a "$LOG"; FAIL=$((FAIL+1)); }

# 心跳：成功 ping 根路径，失败 ping /fail，开始 ping /start
hb() {
  [ -z "${NEWAPI_HEARTBEAT_URL:-}" ] && return 0
  curl -fsS -m 10 --retry 2 "${NEWAPI_HEARTBEAT_URL}$1" >/dev/null 2>&1 || true
}

# 三次重试 + webhook 兜底 + 落盘兜底
send_mail() {
  local subject="$1" body="$2" i
  if command -v msmtp >/dev/null 2>&1 && [ -n "${MAIL_TO:-}" ]; then
    for i in 1 2 3; do
      printf 'To: %s\nSubject: %s\n\n%s\n' "$MAIL_TO" "$subject" "$body" \
        | msmtp -t 2>>"$LOG" && return 0
      sleep 20
    done
  fi
  if [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -fsS -m 15 -X POST "$ALERT_WEBHOOK" \
      -H 'Content-Type: application/json' \
      --data "$(printf '{"text":"%s\\n%s"}' "$subject" "$body" | tr -d '\r')" \
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
    send_mail "[FAIL] new-api backup $TS" "$(tail -n 60 "$LOG")"
    log "结束：FAIL=$FAIL WARN=$WARN 传入码=$rc 实际退出码=1"
    exit 1
  elif [ "$WARN" -gt 0 ]; then
    hb /fail
    send_mail "[WARN] new-api backup $TS" "$(tail -n 60 "$LOG")"
    log "结束：WARN=$WARN"
    exit 0
  else
    hb ""
    log "结束：正常"
    exit 0
  fi
}

require_env() {
  local k v
  for k in "$@"; do
    eval "v=\${$k:-}"
    [ -z "$v" ] && { fail "env.conf 缺少必填项 $k"; finish 1; }
  done
}

hb /start
log "===== new-api 备份开始 $TS ====="

require_env NEWAPI_HOST NEWAPI_SSH_PORT NEWAPI_DATA_DIR NEWAPI_BAK_DIR BACKUP_PASS_FILE MAIL_TO

# 预检
for c in 7z rclone ssh tar sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { fail "本机缺少命令：$c"; finish 1; }
done

[ -r "$BACKUP_PASS_FILE" ] || { fail "读不到密码文件 $BACKUP_PASS_FILE"; finish 1; }
PASS="$(tr -d '\r\n' < "$BACKUP_PASS_FILE")"
[ "${#PASS}" -ge 16 ] || { fail "备份密码长度不足 16 位"; finish 1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
ssh -n "${SSH_OPTS[@]}" -p "$NEWAPI_SSH_PORT" "root@$NEWAPI_HOST" true 2>>"$LOG" \
  || { fail "SSH 连不上 $NEWAPI_HOST:$NEWAPI_SSH_PORT"; finish 1; }
log "落地机 SSH 可达"

mkdir -p "$NEWAPI_BAK_DIR" || { fail "建不了 $NEWAPI_BAK_DIR"; finish 1; }
STAGE="$NEWAPI_BAK_DIR/.staging_$TS"
mkdir -p "$STAGE/payload" || { fail "建不了暂存目录"; finish 1; }

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# 在落地机生成一致性快照并流式拉回
log "在落地机生成 SQLite 一致性快照并打包"

REMOTE_SNAP=$(cat <<REMOTE_EOF
set -o pipefail
D="\$(mktemp -d /tmp/newapi-snap-XXXXXX)" || exit 1
SRC="${NEWAPI_DATA_DIR}"

# SQLite 在线备份：不停容器，自动合并 WAL
if [ -f "\$SRC/one-api.db" ]; then
  python3 - "\$SRC/one-api.db" "\$D/one-api.db" <<'PY' || exit 1
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close(); src.close()
PY
else
  echo "落地机上找不到 \$SRC/one-api.db" >&2
  exit 1
fi

# 其余数据目录内容（排除 db 本体与 WAL/SHM，它们已由快照覆盖）
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude 'one-api.db' --exclude 'one-api.db-wal' --exclude 'one-api.db-shm' \
    "\$SRC/" "\$D/data-rest/" 2>/dev/null || true
else
  mkdir -p "\$D/data-rest"
  (cd "\$SRC" && tar cf - --exclude='one-api.db' --exclude='one-api.db-wal' \
      --exclude='one-api.db-shm' .) | (cd "\$D/data-rest" && tar xf -) 2>/dev/null || true
fi

# 容器还原线索：镜像 tag、完整 inspect、端口与挂载
mkdir -p "\$D/system"
docker inspect ${CONTAINER} > "\$D/system/container-inspect.json" 2>/dev/null || true
docker inspect --format '{{.Config.Image}}' ${CONTAINER} > "\$D/system/image-tag.txt" 2>/dev/null || true
docker ps -a --filter name=${CONTAINER} --format '{{.Names}}\t{{.Image}}\t{{.Status}}' \
  > "\$D/system/container-ps.txt" 2>/dev/null || true
uname -a > "\$D/system/uname.txt" 2>/dev/null || true
(. /etc/os-release 2>/dev/null && echo "\$PRETTY_NAME") > "\$D/system/os-release.txt" 2>/dev/null || true
df -h "\$SRC" > "\$D/system/df.txt" 2>/dev/null || true

tar czf - -C "\$D" . || exit 1
rm -rf "\$D"
REMOTE_EOF
)

if ! printf '%s' "$REMOTE_SNAP" \
  | ssh "${SSH_OPTS[@]}" -p "$NEWAPI_SSH_PORT" "root@$NEWAPI_HOST" "bash -s" 2>>"$LOG" \
  | tar xzf - -C "$STAGE/payload" 2>>"$LOG"; then
  fail "快照生成或传输失败"
  finish 1
fi

[ -s "$STAGE/payload/one-api.db" ] || { fail "拉回的快照为空"; finish 1; }
DBSIZE=$(stat -c %s "$STAGE/payload/one-api.db")
log "快照到手：one-api.db ${DBSIZE} 字节"

# 快照完整性自检
if command -v sqlite3 >/dev/null 2>&1; then
  R=$(sqlite3 "$STAGE/payload/one-api.db" 'PRAGMA integrity_check;' 2>>"$LOG")
  [ "$R" = "ok" ] && log "SQLite integrity_check: ok" || warn "SQLite integrity_check 返回：$R"
elif command -v python3 >/dev/null 2>&1; then
  R=$(python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
print(c.execute('PRAGMA integrity_check').fetchone()[0])" "$STAGE/payload/one-api.db" 2>>"$LOG")
  [ "$R" = "ok" ] && log "SQLite integrity_check: ok" || warn "SQLite integrity_check 返回：$R"
else
  warn "本机无 sqlite3/python3，跳过完整性校验"
fi

# 记录配置项数量作为内容抽样（不打印任何值）
if command -v python3 >/dev/null 2>&1; then
  N=$(python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
try: print(c.execute('SELECT COUNT(*) FROM options').fetchone()[0])
except Exception: print('?')" "$STAGE/payload/one-api.db" 2>/dev/null)
  log "options 表条目数：$N"
fi

# 清单与还原说明
{
  echo "new-api backup manifest"
  echo "打包时间(UTC): $(date -u '+%F %T')"
  echo "落地机: $NEWAPI_HOST:$NEWAPI_SSH_PORT"
  echo "数据目录: $NEWAPI_DATA_DIR"
  echo "容器名: $CONTAINER"
  echo "镜像: $(cat "$STAGE/payload/system/image-tag.txt" 2>/dev/null || echo 未知)"
  echo "---- 文件清单 ----"
  (cd "$STAGE/payload" && find . -type f -printf '%10s  %p\n' | sort -k2)
} > "$STAGE/payload/manifest.txt"

# heredoc 加引号：避免 $ 被展开；需替换处用 {{占位符}}，生成后再 sed
cat > "$STAGE/payload/RESTORE.md" <<'RESTORE_EOF'
# new-api 恢复步骤

## 前置
新机需要 docker。数据目录默认 `{{DATA_DIR}}`，容器名 `{{CONTAINER}}`。

## 1. 解包
```bash
7z x newapi_<时间戳>.7z -p'<备份密码>'
```

## 2. 还原数据目录
```bash
mkdir -p {{DATA_DIR}}
cp one-api.db {{DATA_DIR}}/one-api.db
# data-rest 里是日志等其余内容，按需复制
cp -a data-rest/. {{DATA_DIR}}/ 2>/dev/null || true
```

**注意**：不要把 `one-api.db-wal` / `one-api.db-shm` 一起放回去。快照已经合并过 WAL，
放回旧的 WAL 文件会让 SQLite 拿到不一致的状态。包里本来就没有这两个文件。

## 3. 起容器
镜像 tag 见 `system/image-tag.txt`，完整参数见 `system/container-inspect.json`。
原始启动命令形如：

```bash
docker run -d --name {{CONTAINER}} --restart always \
  -p 127.0.0.1:3000:3000 \
  -e TZ=UTC \
  -v {{DATA_DIR}}:/data \
  calciumion/new-api:<image-tag.txt 里的版本>
```

**锁死具体版本号，不要用 :latest** —— 版本漂移后 migration 可能不可逆。

## 4. 自检
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
```
返回 200 即容器正常。

## 5. 换机时必须同步改的地方
如果落地机 IP 变了：

1. 前置机的 SSH 隧道 systemd 单元 `/etc/systemd/system/newapi-tunnel.service`
   里的目标 IP 和端口，改完 `systemctl daemon-reload && systemctl restart newapi-tunnel`
2. `env.conf` 里的 `NEWAPI_HOST` / `NEWAPI_SSH_PORT`
3. 确认新机能直连官方 API（不在被拒地区），判据是无 Key 请求
   `https://api.openai.com/v1/models` 返回 401 而不是 403

如果对外域名变了：

1. 后台「系统信息 → 服务器地址」
2. 「身份验证 → 通行密钥认证」里的主域名与允许网站，**旧 passkey 会失效**，
   需要重新注册；动手前先确认密码登录可用，否则会把自己锁在外面
3. 前置机 nginx 的 vhost 与证书
4. Turnstile 站点的 Hostname

## 6. 恢复后要自己核对的
- 渠道里的上游 Key 是否还在（加密存于 DB，跟包一起恢复）
- 令牌是否还有效
- 额度与速率限制设置
RESTORE_EOF

sed -i -e "s|{{DATA_DIR}}|${NEWAPI_DATA_DIR}|g" \
       -e "s|{{CONTAINER}}|${CONTAINER}|g" \
       "$STAGE/payload/RESTORE.md"

# env.conf 的结构副本（只留键名与非敏感值，供还原时对照）
if [ -r "$ENV_FILE" ]; then
  grep -vE '(PASS|SECRET|TOKEN|KEY|HEARTBEAT|WEBHOOK)' "$ENV_FILE" \
    > "$STAGE/payload/system/env.conf.sample" 2>/dev/null || true
fi

# 打包
ARCHIVE="$NEWAPI_BAK_DIR/newapi_${TS}.7z"
log "打包为 $ARCHIVE"
if ! 7z a -t7z -m0=lzma2 -mx=5 -mhe=on -p"$PASS" "$ARCHIVE" "$STAGE/payload/"* \
     >>"$LOG" 2>&1; then
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
( cd "$NEWAPI_BAK_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
log "已生成 .sha256 旁注文件"

# 上传
UPLOADED=0
for R in $RCLONE_REMOTES; do
  log "上传到 ${R}:/${CLOUD_DIR}"
  if rclone copy "$ARCHIVE" "${R}:/${CLOUD_DIR}/" >>"$LOG" 2>&1 \
     && rclone copy "${ARCHIVE}.sha256" "${R}:/${CLOUD_DIR}/" >>"$LOG" 2>&1; then
    # Google Drive 元数据有延迟，立刻 check 会误报
    sleep 10
    if rclone check "$NEWAPI_BAK_DIR" "${R}:/${CLOUD_DIR}" \
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

# 保留策略
log "清理本地超过 ${LOCAL_KEEP_DAYS} 天的包"
find "$NEWAPI_BAK_DIR" -maxdepth 1 -name 'newapi_*.7z*' -mtime "+${LOCAL_KEEP_DAYS}" \
  -print -delete >>"$LOG" 2>&1

log "清理云端超过 ${CLOUD_KEEP_DAYS} 天的包"
for R in $RCLONE_REMOTES; do
  rclone delete "${R}:/${CLOUD_DIR}" --min-age "${CLOUD_KEEP_DAYS}d" \
    --include 'newapi_*' >>"$LOG" 2>&1 || warn "${R} 云端清理失败"
done

log "汇总：包体 ${PKGSIZE} 字节，成功上传 ${UPLOADED} 处，WARN=${WARN} FAIL=${FAIL}"
finish 0
