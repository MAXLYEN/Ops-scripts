#!/usr/bin/env bash
# ops/newapi-drill.sh — 在备用机演练 new-api 备份的恢复与清理
# VERSION: 1.0.2
# 1.0.2: 整理注释并补充目录文档，执行逻辑未变。
# ENV-REQUIRED: NEWAPI_HOST BACKUP_PASS_FILE NEWAPI_CLOUD_DIR
# 在备用机运行；禁止指向生产落地机。
# 用法：
#   newapi-drill.sh restore <目标IP>
#   newapi-drill.sh verify <目标IP>
#   newapi-drill.sh teardown <目标IP>
#   newapi-drill.sh status <目标IP>

set -o pipefail

ENV_FILE=/etc/ops-scripts/env.conf
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

ACTION="${1:-}"
TARGET="${2:-}"

DRILL_CONTAINER="new-api-drill"
DRILL_DATA="/opt/new-api-drill/data"
DRILL_PORT=3000
STATE_FILE="/var/lib/ops-scripts/newapi-drill-${TARGET}.state"
RCLONE_REMOTE="${NEWAPI_DRILL_REMOTE:-onedrive}"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die()  { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

usage() {
  sed -n '/^# 用法：/,/^$/p' "$0" | sed 's/^# \?//'
  exit 1
}

[ -z "$ACTION" ] && usage
[ -z "$TARGET" ] && usage

# 硬拦截：绝不对生产落地机动手
guard_target() {
  [ "$TARGET" = "${NEWAPI_HOST:-}" ] && \
    die "拒绝执行：$TARGET 是 env.conf 里的生产落地机 NEWAPI_HOST"
  case "$TARGET" in
    127.0.0.1|localhost|"$(hostname -I 2>/dev/null | awk '{print $1}')")
      die "拒绝执行：目标看起来是本机（汇总机）" ;;
  esac
  return 0
}
guard_target

TPORT="$(awk -F: -v h="$TARGET" '$0 ~ h {print $NF}' "${HOME}/.vps-hosts.txt" 2>/dev/null | head -1)"
[ -z "$TPORT" ] && die "~/.vps-hosts.txt 里找不到 $TARGET 的 SSH 端口"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
rsh() { ssh "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET" "$@"; }
rsh_n() { ssh -n "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET" "$@"; }

log "目标 root@$TARGET:$TPORT  动作 $ACTION"
rsh_n true 2>/dev/null || die "SSH 连不上 $TARGET:$TPORT"

# restore
do_restore() {
  log "----- 预检 -----"

  # 3000 端口必须空闲，否则会顶掉别的服务
  if rsh_n "ss -lntp 2>/dev/null | grep -q ':${DRILL_PORT} '"; then
    die "目标机 ${DRILL_PORT} 端口已被占用，换端口或先排查"
  fi
  log "端口 ${DRILL_PORT} 空闲"

  # 上游地区可达性：无 Key 请求返回 401 才算通过
  for u in https://api.openai.com/v1/models https://api.anthropic.com/v1/models; do
    C=$(rsh_n "curl -s -o /dev/null -w '%{http_code}' -m 12 '$u'" 2>/dev/null)
    [ "$C" = "401" ] && log "上游可达 ${u##*//} -> 401" \
                     || warn "上游异常 ${u##*//} -> ${C:-无响应}（演练可继续，但该机不适合做落地）"
  done

  # 记录动手前的状态，teardown 据此还原
  mkdir -p "$(dirname "$STATE_FILE")"
  if rsh_n "command -v docker >/dev/null 2>&1"; then
    echo "DOCKER_PREEXISTING=1" > "$STATE_FILE"
    log "目标机原本已装 docker，teardown 时不会卸载"
  else
    echo "DOCKER_PREEXISTING=0" > "$STATE_FILE"
    log "目标机原本没有 docker，teardown 时会卸载还原"
  fi
  echo "DRILL_START='$(date -u '+%F %T')'" >> "$STATE_FILE"

  log "----- 从云端取最新备份 -----"
  command -v rclone >/dev/null 2>&1 || die "本机缺少 rclone"
  [ -r "${BACKUP_PASS_FILE:-}" ] || die "读不到密码文件 ${BACKUP_PASS_FILE:-未配置}"
  PASS="$(tr -d '\r\n' < "$BACKUP_PASS_FILE")"
  [ "${#PASS}" -ge 16 ] || die "备份密码长度不足 16 位"

  LATEST=$(rclone lsf "${RCLONE_REMOTE}:/${NEWAPI_CLOUD_DIR}" --include 'newapi_*.7z' 2>/dev/null \
           | sort | tail -1)
  [ -z "$LATEST" ] && die "${RCLONE_REMOTE}:/${NEWAPI_CLOUD_DIR} 里没有 newapi_*.7z"
  log "最新云端包：$LATEST"

  WORK=$(mktemp -d /tmp/newapi-drill-XXXXXX) || die "建不了临时目录"
  trap 'rm -rf "$WORK"' EXIT

  rclone copy "${RCLONE_REMOTE}:/${NEWAPI_CLOUD_DIR}/${LATEST}" "$WORK/" \
    || die "从云端下载失败"
  log "已下载到本地临时目录"

  # -mhe=on 的包在管道里不喂 stdin 会挂住
  7z x -p"$PASS" -o"$WORK/x" "$WORK/$LATEST" < /dev/null >/dev/null 2>&1 \
    || die "解包失败（密码不对或包损坏）"
  [ -s "$WORK/x/one-api.db" ] || die "包里没有 one-api.db"
  log "解包成功"

  IMAGE=$(cat "$WORK/x/system/image-tag.txt" 2>/dev/null | tr -d '\r\n')
  [ -z "$IMAGE" ] && die "包里读不到镜像 tag，无法保证版本一致"
  log "镜像 tag（来自备份）：$IMAGE"

  log "----- 目标机安装 docker -----"
  rsh "bash -s" <<'REMOTE_DOCKER'
set -o pipefail
if command -v docker >/dev/null 2>&1; then
  echo "  已安装：$(docker --version)"
  systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
  exit 0
fi
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
echo "  系统：$PRETTY_NAME  codename=$CODENAME"
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg >/dev/null 2>&1
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || exit 1
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq >/dev/null 2>&1
# 跳过 Recommends：EOL 系统上那条依赖链会拉到已从 pool 删除的包
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
  >/dev/null 2>&1 || exit 1
systemctl enable --now docker >/dev/null 2>&1
command -v docker >/dev/null 2>&1 && echo "  安装完成：$(docker --version)" || exit 1
REMOTE_DOCKER
  [ $? -ne 0 ] && die "目标机 docker 安装失败"

  log "----- 传输数据并起容器 -----"
  rsh_n "rm -rf ${DRILL_DATA} && mkdir -p ${DRILL_DATA}" || die "目标机建目录失败"

  # 只传 db 与 data-rest；-wal/-shm 包里本就没有，放回去反而会造成不一致
  ( cd "$WORK/x" && tar czf - one-api.db $( [ -d data-rest ] && echo data-rest ) ) \
    | rsh "tar xzf - -C ${DRILL_DATA} --strip-components=0" \
    || die "数据传输失败"
  rsh_n "[ -s ${DRILL_DATA}/one-api.db ]" || die "目标机上快照为空"
  # data-rest 里的内容平铺进数据目录
  rsh_n "[ -d ${DRILL_DATA}/data-rest ] && cp -a ${DRILL_DATA}/data-rest/. ${DRILL_DATA}/ && rm -rf ${DRILL_DATA}/data-rest || true"
  log "数据已就位"

  rsh "IMAGE='$IMAGE' bash -s" <<REMOTE_RUN
set -o pipefail
docker rm -f ${DRILL_CONTAINER} >/dev/null 2>&1 || true
docker pull "\$IMAGE" >/dev/null 2>&1 || { echo "  拉镜像失败"; exit 1; }
docker run -d --name ${DRILL_CONTAINER} --restart no \
  -p 127.0.0.1:${DRILL_PORT}:3000 \
  -e TZ=UTC \
  -v ${DRILL_DATA}:/data \
  "\$IMAGE" >/dev/null 2>&1 || { echo "  起容器失败"; exit 1; }
sleep 10
C=\$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:${DRILL_PORT}/ 2>/dev/null)
echo "  自检 HTTP \${C:-无响应}"
docker ps --filter name=${DRILL_CONTAINER} --format '  {{.Names}}  {{.Image}}  {{.Status}}'
[ "\$C" = "200" ] || exit 1
REMOTE_RUN
  [ $? -ne 0 ] && die "恢复实例起不来或自检不过"

  echo "RESTORED_FROM='$LATEST'" >> "$STATE_FILE"
  echo "IMAGE='$IMAGE'" >> "$STATE_FILE"
  log "恢复完成。下一步：newapi-drill.sh verify $TARGET"
}

# verify
db_counts() {  # $1=ssh端口 $2=主机 $3=db路径 $4=容器名
  ssh -n "${SSH_OPTS[@]}" -p "$1" "root@$2" "
    T=\$(mktemp -d)
    docker cp $4:/data/one-api.db \"\$T/db\" >/dev/null 2>&1 || cp $3 \"\$T/db\"
    docker cp $4:/data/one-api.db-wal \"\$T/db-wal\" >/dev/null 2>&1 || true
    python3 -c \"
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
def n(t):
    try: return c.execute('SELECT COUNT(*) FROM '+t).fetchone()[0]
    except Exception: return 'n/a'
for t in ['options','users','tokens','channels','abilities','logs']:
    print(t, n(t))
\" \"\$T/db\"
    rm -rf \"\$T\"
  " 2>/dev/null
}

do_verify() {
  log "----- 对比恢复实例与线上实例 -----"
  PPORT="$(awk -F: -v h="${NEWAPI_HOST}" '$0 ~ h {print $NF}' "${HOME}/.vps-hosts.txt" | head -1)"
  [ -z "$PPORT" ] && die "找不到生产机 ${NEWAPI_HOST} 的 SSH 端口"

  PROD=$(db_counts "$PPORT" "$NEWAPI_HOST" "/opt/new-api/data/one-api.db" "new-api")
  DRILL=$(db_counts "$TPORT" "$TARGET" "${DRILL_DATA}/one-api.db" "$DRILL_CONTAINER")

  [ -z "$PROD" ] && warn "读不到线上实例数据"
  [ -z "$DRILL" ] && die "读不到恢复实例数据"

  printf '\n  %-12s %-12s %-12s %s\n' "表" "线上" "恢复实例" "判定"
  printf '  %s\n' "----------------------------------------------------"
  DIFF=0
  while read -r t pv; do
    dv=$(echo "$DRILL" | awk -v k="$t" '$1==k{print $2}')
    if [ "$pv" = "$dv" ]; then
      printf '  %-12s %-12s %-12s %s\n' "$t" "$pv" "$dv" "一致"
    else
      printf '  %-12s %-12s %-12s %s\n' "$t" "$pv" "$dv" "差异"
      DIFF=$((DIFF+1))
    fi
  done <<< "$PROD"

  echo
  if [ "$DIFF" -eq 0 ]; then
    log "所有表行数一致。注意：备份有 RPO，线上在备份之后若有写入，出现差异是正常的"
  else
    warn "有 ${DIFF} 张表存在差异 —— 先看是不是备份之后线上又写入了，再怀疑备份本身"
  fi

  log "----- 恢复实例的配置项抽查 -----"
  rsh_n "
    T=\$(mktemp -d); docker cp ${DRILL_CONTAINER}:/data/one-api.db \"\$T/db\" >/dev/null 2>&1
    python3 -c \"
import sqlite3,sys,re
SEC=re.compile(r'(key|secret|token|password)', re.I)
SAFE=re.compile(r'^(true|false|null|\d{1,6}|\[.*\]|\{.*\})$', re.I)
c=sqlite3.connect(sys.argv[1])
for k,v in sorted(c.execute('SELECT key,value FROM options')):
    v=v or ''
    if SEC.search(k) and v and not SAFE.match(v):
        v=('%s…%s [len=%d]' % (v[:4], v[-2:], len(v))) if len(v)>8 else ('*'*len(v))
    elif len(v)>50: v=v[:50]+' …'
    print('  %-32s = %s' % (k, v or '(空)'))
\" \"\$T/db\"; rm -rf \"\$T\"" 2>/dev/null

  log "校验完毕。确认无误后：newapi-drill.sh teardown $TARGET"
}

# teardown
do_teardown() {
  log "----- 清理恢复实例 -----"
  DOCKER_PREEXISTING=1
  [ -r "$STATE_FILE" ] && . "$STATE_FILE"

  rsh "bash -s" <<REMOTE_CLEAN
set -o pipefail
echo "  停并删除容器"
docker rm -f ${DRILL_CONTAINER} >/dev/null 2>&1 || true
echo "  删除镜像"
docker rmi ${IMAGE:-calciumion/new-api} >/dev/null 2>&1 || true
echo "  删除数据目录"
rm -rf /opt/new-api-drill
REMOTE_CLEAN

  if [ "${DOCKER_PREEXISTING:-1}" = "0" ]; then
    log "----- 目标机原本没有 docker，卸载还原 -----"
    rsh "bash -s" <<'REMOTE_PURGE'
set -o pipefail
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
  >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
rm -rf /var/lib/docker /var/lib/containerd
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
apt-get update -qq >/dev/null 2>&1 || true
command -v docker >/dev/null 2>&1 && echo "  docker 仍在（卸载未完全）" || echo "  docker 已卸载"
REMOTE_PURGE
  else
    log "目标机原本就有 docker，保留不动"
  fi

  log "----- 还原确认 -----"
  rsh "bash -s" <<'REMOTE_CHECK'
echo "  docker: $(command -v docker >/dev/null 2>&1 && docker --version || echo 未安装)"
echo "  /opt/new-api-drill: $([ -e /opt/new-api-drill ] && echo 仍存在 || echo 已清除)"
echo "  docker apt 源: $([ -e /etc/apt/sources.list.d/docker.list ] && echo 仍存在 || echo 已清除)"
echo "  3000 端口: $(ss -lntp 2>/dev/null | grep -q ':3000 ' && echo 仍被占用 || echo 已释放)"
echo "  原有服务:"
for s in x-ui xboard-node komari-agent; do
  systemctl is-active "$s" >/dev/null 2>&1 && echo "    $s: active" || echo "    $s: 非 active（原本就没有则正常）"
done
echo "  磁盘:"; df -h / | tail -1 | sed 's/^/    /'
REMOTE_CHECK

  rm -f "$STATE_FILE"
  log "演练结束，目标机已还原"
}

# status
do_status() {
  [ -r "$STATE_FILE" ] && { echo "--- 演练状态文件 ---"; cat "$STATE_FILE"; } \
                       || echo "没有进行中的演练（无状态文件）"
  echo
  rsh "bash -s" <<REMOTE_STATUS
echo "--- 目标机现状 ---"
echo "  docker: \$(command -v docker >/dev/null 2>&1 && docker --version || echo 未安装)"
docker ps -a --filter name=${DRILL_CONTAINER} --format '  容器: {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null
echo "  数据目录: \$([ -d ${DRILL_DATA} ] && du -sh ${DRILL_DATA} 2>/dev/null || echo 不存在)"
REMOTE_STATUS
}

case "$ACTION" in
  restore)  do_restore ;;
  verify)   do_verify ;;
  teardown) do_teardown ;;
  status)   do_status ;;
  *)        usage ;;
esac
