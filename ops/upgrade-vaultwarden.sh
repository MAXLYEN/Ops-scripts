#!/usr/bin/env bash
# upgrade-vaultwarden.sh
# VERSION: 1.1.0
#
# 升级 vaultwarden 并把 compose 的 image 由 tag 锁定为 digest。
#
# 用法:
#   upgrade-vaultwarden.sh              查询最新版并显示对比，不执行升级
#   upgrade-vaultwarden.sh -y           查询最新版并直接升级
#   upgrade-vaultwarden.sh <版本号>     升级到指定版本
#   upgrade-vaultwarden.sh <版本号> -y  同上（-y 在指定版本时无作用，保留以便统一写法）
#
# 注意：
# - 升级前强制要求 24 小时内有备份产出，否则中止
# - migration 不可逆：compose 可回滚，库结构不能；失败时以还原备份为准
# - 锁 digest 而非 tag：digest 在 pull 后从本地镜像读出，保证存在
# - GitHub API 未认证限流 60 次/小时，被限流时原样打印返回消息，不当作「无新版本」
set -o pipefail

GH_REPO="dani-garcia/vaultwarden"
IMAGE_REPO="vaultwarden/server"
COMPOSE="/opt/vaultwarden/compose.yaml"
BACKUP_GLOB="/box/vaul_bak/srvbak_*.7z"
TS=$(date +%Y%m%d%H%M%S)
BAK="/root/vw-upgrade-bak/${TS}"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die()  { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

# ---------- 参数 ----------
TARGET_TAG=""
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "未知参数: $a" ;;
    *) TARGET_TAG="$a" ;;
  esac
done

[ -f "$COMPOSE" ] || die "读不到 $COMPOSE"
docker inspect vaultwarden >/dev/null 2>&1 || die "容器 vaultwarden 不存在"

OLD_ID=$(docker inspect vaultwarden --format '{{.Image}}')
OLD_VER=$(docker image inspect "$OLD_ID" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)

# ---------- 查询最新版本 ----------
if [ -z "$TARGET_TAG" ]; then
  log "查询上游最新版本"
  RESP=$(curl -s -m 20 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${GH_REPO}/releases/latest")
  [ -n "$RESP" ] || die "GitHub API 无响应（网络不通？）"

  PARSED=$(printf '%s' "$RESP" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception as e: print("PARSE_ERR|"+str(e)); raise SystemExit
if "tag_name" in d:
    print("OK|%s|%s|%s|%s" % (d["tag_name"], d.get("html_url",""), d.get("published_at",""), d.get("prerelease")))
else:
    print("API_ERR|"+str(d.get("message","未知错误")))
' 2>/dev/null)

  case "$PARSED" in
    OK\|*)
      IFS='|' read -r _ LATEST NOTES_URL PUBLISHED PRE <<EOF2
$PARSED
EOF2
      ;;
    API_ERR\|*)
      die "GitHub API 返回：${PARSED#API_ERR|}"
      ;;
    *)
      die "解析 GitHub API 响应失败：${PARSED:-空}"
      ;;
  esac

  TARGET_TAG="${LATEST#v}"
  echo "  当前已装：${OLD_VER}"
  echo "  上游最新：${TARGET_TAG}   发布于 ${PUBLISHED}   prerelease=${PRE}"
  echo "  更新说明：${NOTES_URL}"

  if [ "$OLD_VER" = "$TARGET_TAG" ]; then
    log "已是最新版本，无需升级"
    exit 0
  fi

  if [ "$ASSUME_YES" != 1 ]; then
    echo
    echo "  未执行升级。看过更新说明后，用下面任一条继续："
    echo "    $0 -y              升到 ${TARGET_TAG}"
    echo "    $0 <版本号>        升到指定版本"
    exit 0
  fi
  log "已指定 -y，继续升级到 ${TARGET_TAG}"
fi

# ---------- 前置检查 ----------
log "前置检查"
LATEST_BAK=$(ls -t $BACKUP_GLOB 2>/dev/null | head -1)
[ -n "$LATEST_BAK" ] || die "找不到任何备份包，中止"
BAK_AGE=$(( ($(date +%s) - $(stat -c %Y "$LATEST_BAK")) / 3600 ))
echo "  最新备份：$(basename "$LATEST_BAK")  $(du -h "$LATEST_BAK" | cut -f1)  ${BAK_AGE} 小时前"
[ "$BAK_AGE" -le 24 ] || die "最新备份已超过 24 小时，先跑 vw-fullbackup.sh 再升级"
echo "  当前版本：${OLD_VER}"
echo "  目标版本：${TARGET_TAG}"
[ "$OLD_VER" = "$TARGET_TAG" ] && { log "已是目标版本，无需升级"; exit 0; }

mkdir -p "$BAK" || die "建不了 $BAK"
cp -a "$COMPOSE" "${BAK}/compose.yaml"
docker inspect vaultwarden > "${BAK}/inspect-vaultwarden.json"
{ echo "升级前版本: ${OLD_VER}"; echo "升级前镜像: ${OLD_ID}"; } > "${BAK}/OLD-VERSION.txt"
log "存档目录：$BAK"

rollback() {
  warn "开始回滚 compose"
  cp -a "${BAK}/compose.yaml" "$COMPOSE"
  docker compose -f "$COMPOSE" up -d
  echo
  echo "  compose 已回滚到升级前（镜像 ${OLD_ID}）"
  echo "  若容器仍起不来，说明 migration 已改动库结构，旧版无法连接新库。"
  echo "  此时唯一可靠路径是还原备份：${LATEST_BAK}"
  echo "  还原步骤见包内 RESTORE.md"
  exit 1
}

# ---------- 1. 拉取 ----------
log "1/5 拉取 ${IMAGE_REPO}:${TARGET_TAG}"
docker pull "${IMAGE_REPO}:${TARGET_TAG}" >/dev/null || die "拉取失败，未做任何改动"

NEW_DIGEST=$(docker image inspect "${IMAGE_REPO}:${TARGET_TAG}" \
  --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')
case "$NEW_DIGEST" in *@sha256:*) ;; *) die "取不到 digest，未做任何改动" ;; esac
NEW_VER=$(docker image inspect "${IMAGE_REPO}:${TARGET_TAG}" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
echo "  镜像版本标签：${NEW_VER}"
echo "  digest：${NEW_DIGEST}"
[ "$NEW_VER" = "$TARGET_TAG" ] || warn "镜像标签 ${NEW_VER} 与目标 ${TARGET_TAG} 不一致，请确认"

# ---------- 2. 改 compose ----------
log "2/5 compose 锁定 digest"
N=$(grep -cE "^[[:space:]]*image:.*${IMAGE_REPO}" "$COMPOSE")
[ "$N" = 1 ] || die "compose 里匹配到 ${N} 行 image，未自动修改"
sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*${IMAGE_REPO}.*|\1${NEW_DIGEST}  # ${TARGET_TAG}|" "$COMPOSE"
grep -nE '^[[:space:]]*image:' "$COMPOSE" | sed 's/^/  /'

# ---------- 3. 重建 ----------
log "3/5 重建容器"
docker compose -f "$COMPOSE" up -d || rollback

log "等待健康检查（最多 120 秒）"
OK=0
for i in $(seq 1 24); do
  H=$(docker inspect vaultwarden --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' 2>/dev/null)
  S=$(docker inspect vaultwarden --format '{{.State.Status}}' 2>/dev/null)
  if [ "$H" = "healthy" ] || { [ "$H" = "nohealth" ] && [ "$S" = "running" ] && [ "$i" -ge 4 ]; }; then
    OK=1; echo "  容器状态：${S} / ${H}（第 $((i*5)) 秒）"; break
  fi
  [ "$S" = "exited" ] && { warn "容器已退出"; break; }
  sleep 5
done

# ---------- 4. 校验 ----------
log "4/5 校验"
echo "  --- 启动日志 ---"
docker logs vaultwarden --since 3m 2>&1 | grep -iE 'Version |migrat|panic' | tail -10 | sed 's/^/    /'
if docker logs vaultwarden --since 3m 2>&1 | grep -qiE 'panic|Error running migrations'; then
  warn "日志中出现 migration 错误"; OK=0
fi

ALIVE=$(docker exec vaultwarden sh -c 'command -v curl >/dev/null && curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/alive' 2>/dev/null)
echo "  /alive : ${ALIVE:-取不到（容器内无 curl）}"

RUN_VER=$(docker image inspect "$(docker inspect vaultwarden --format '{{.Image}}')" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)
echo "  运行版本：${RUN_VER}"

[ "$OK" = 1 ] && [ "$RUN_VER" = "$TARGET_TAG" ] || { warn "校验未通过"; rollback; }

# ---------- 5. 收尾 ----------
log "5/5 收尾提示"
echo "  旧镜像仍带 tag，确认客户端正常后可删："
echo "    docker rmi ${IMAGE_REPO}:${OLD_VER}"

echo
echo "===== 结果 ====="
echo "  ${OLD_VER}  ->  ${RUN_VER}"
docker ps --filter 'name=vaultwarden' --format '  {{.Names}}  {{.Image}}  {{.Status}}'
echo
echo "  存档目录：$BAK"
echo "  客户端验收：解锁一次密码库 + 手动同步 + /admin 的 Diagnostics"
