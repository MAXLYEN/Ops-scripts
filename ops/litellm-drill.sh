#!/usr/bin/env bash
# ops/litellm-drill.sh — 在备用机上演练 LiteLLM 备份包的恢复、核对与清理
# VERSION: 1.0.0
# 1.0.0: 首版。按包里 RESTORE.md 的顺序：先放 .env，只起 postgres，pg_restore --clean --if-exists，再按 digest 起全部并查健康；verify 与线上比行数、列模型、查解密错误；teardown 还原目标机。拒绝 LITELLM_HOST、NEWAPI_HOST 与本机。
# ENV-REQUIRED: LITELLM_HOST BACKUP_PASS_FILE
# 在汇总机运行，目标是一台备用机（SSH 端口从 ~/.vps-hosts.txt 取）；禁止指向生产节点。
# 用法：
#   litellm-drill.sh restore  <目标IP> [包路径]   不给包就从网盘取最新的 litellm_*.7z
#   litellm-drill.sh verify   <目标IP>            与线上节点比行数，查健康、模型列表与解密错误
#   litellm-drill.sh teardown <目标IP>            删掉演练实例；目标机原本没有 docker 就卸载
#   litellm-drill.sh status   <目标IP>

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env LITELLM_HOST BACKUP_PASS_FILE

usage() { sed -n '/^# 用法：/,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1; }
ACTION=${1:-}; TARGET=${2:-}; PKG=${3:-}
[ -n "$ACTION" ] && [ -n "$TARGET" ] || usage
case "$ACTION" in restore|verify|teardown|status) ;; *) usage ;; esac

DRILL_DIR=/opt/litellm-drill            # 目标机上的演练工作目录
MARK="$DRILL_DIR/.litellm-drill"        # 有这个标记才算演练建的，teardown 才会删
TABLES="LiteLLM_ProxyModelTable LiteLLM_VerificationToken LiteLLM_UserTable LiteLLM_TeamTable LiteLLM_Config LiteLLM_SpendLogs"

# 硬拦截：绝不对生产节点动手。地址还要拼进状态文件名，先查字符
guard_target() {
  local me
  case "$TARGET" in *[!A-Za-z0-9.:-]*) die "目标地址不合法: $TARGET" ;; esac
  [ "$TARGET" = "$LITELLM_HOST" ] && die "拒绝执行：$TARGET 是 env.conf 里的生产 LiteLLM 节点 LITELLM_HOST"
  [ -n "${NEWAPI_HOST:-}" ] && [ "$TARGET" = "$NEWAPI_HOST" ] && die "拒绝执行：$TARGET 是 env.conf 里的生产落地机 NEWAPI_HOST"
  case "$TARGET" in 127.*|localhost|::1|"$(hostname)") die "拒绝执行：目标是本机（汇总机）" ;; esac
  for me in $(hostname -I 2>/dev/null); do
    [ "$TARGET" = "$me" ] && die "拒绝执行：目标是本机（汇总机）"
  done
  return 0
}
guard_target
STATE_FILE="/var/lib/ops-scripts/litellm-drill-${TARGET}.state"

TPORT=$(vps_host_port "$TARGET")
[ -n "$TPORT" ] || die "$HOME/.vps-hosts.txt 里找不到 $TARGET 的 SSH 端口（每行 root@IP:端口）"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
rsh()  { ssh "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET" "$@"; }
rshn() { ssh -n "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET" "$@"; }

log "目标 root@$TARGET:$TPORT  动作 $ACTION"
rshn true 2>/dev/null || die "SSH 连不上 $TARGET:$TPORT"

# ── restore ─────────────────────────────────────────────────
open_package() {  # 取包、解开、核对，结果放 X / PKGNAME / PORT / IMAGES
  local f n r dir fp mfp
  require_cmd 7z sha256sum tar
  PASS=$(tr -d '\r\n' < "$BACKUP_PASS_FILE") || die "读不到密码文件 $BACKUP_PASS_FILE"
  [ "${#PASS}" -ge 16 ] || die "备份密码长度不足 16 位"
  WORK=$(mktemp -d /tmp/litellm-drill-XXXXXX) || die "建不了临时目录"
  trap 'rm -rf "$WORK"' EXIT
  if [ -n "$PKG" ]; then
    [ -f "$PKG" ] || die "包不存在: $PKG"
    case "$(basename "$PKG")" in litellm_*.7z) ;; *) die "不是 litellm_*.7z 包: $PKG" ;; esac
    f=$(readlink -f "$PKG")
  else
    [ -n "${RCLONE_REMOTES:-}" ] || die "没给包路径，要从网盘取就得在 env.conf 填 RCLONE_REMOTES"
    require_cmd rclone
    r=${LITELLM_DRILL_REMOTE:-${RCLONE_REMOTES%% *}}
    dir=${LITELLM_CLOUD_DIR:-Backup-LiteLLM}
    n=$(rclone lsf "$r:/$dir" --files-only --include 'litellm_*.7z' 2>/dev/null | sort | tail -1)
    [ -n "$n" ] || die "$r:/$dir 里没有 litellm_*.7z"
    log "网盘最新包：$r:/$dir/$n"
    rclone copy "$r:/$dir/$n" "$WORK/" || die "下载失败"
    rclone copy "$r:/$dir/$n.sha256" "$WORK/" 2>/dev/null || true
    f="$WORK/$n"
  fi
  PKGNAME=$(basename "$f")
  if [ -f "$f.sha256" ]; then
    [ "$(cut -d' ' -f1 < "$f.sha256")" = "$(sha256sum "$f" | cut -d' ' -f1)" ] || die "sha256 与 $f.sha256 不符"
    ok "sha256 与旁注一致"
  fi
  # -mhe=on 的包在管道里不喂 stdin 会挂住
  7z x -p"$PASS" -o"$WORK/x" "$f" </dev/null >/dev/null 2>&1 || die "解不开：密码不对或包已损坏"
  X="$WORK/x"
  [ -s "$X/db/litellm.dump" ] && [ "$(head -c 5 "$X/db/litellm.dump")" = PGDMP ] || die "包里没有可用的 db/litellm.dump"
  (cd "$X/db" && sha256sum -c --quiet litellm.dump.sha256) >/dev/null 2>&1 || die "db/litellm.dump 与包里记的校验和不符"
  grep -q '^LITELLM_SALT_KEY=.' "$X/workdir/.env" 2>/dev/null \
    || die "包里的 .env 没有 LITELLM_SALT_KEY —— 没有原来的盐值，恢复出来的上游凭据全部解不开"
  fp=$(grep -m1 '^LITELLM_SALT_KEY=' "$X/workdir/.env" | cut -d= -f2- | tr -d '\r\n' | sha256sum | cut -c1-12)
  mfp=$(sed -n 's/^LITELLM_SALT_KEY 指纹[^:]*: *//p' "$X/manifest.txt" 2>/dev/null)
  [ -z "$mfp" ] || [ "$mfp" = "$fp" ] || die "包里 .env 的盐值指纹 $fp 与 manifest.txt 记的 $mfp 不一致"
  [ -s "$X/system/docker-compose.pinned.yml" ] || die "包里没有 system/docker-compose.pinned.yml"
  grep -qE '^[[:space:]]*image:[[:space:]]*ghcr\.io/berriai/litellm@sha256:' "$X/system/docker-compose.pinned.yml" \
    || die "包里的 compose 没把 LiteLLM 锁到 digest，演练不按可能漂移的标签拉"
  PORT=$(grep -oE '127\.0\.0\.1:[0-9]+:4000' "$X/system/docker-compose.pinned.yml" | head -1 | cut -d: -f2)
  PORT=${PORT:-4000}
  IMAGES=$(awk -F'\t' '$1 !~ /^#/ && $3 != "-" && $3 != "" { printf "%s ", $3 }' "$X/images.tsv" 2>/dev/null)
  ok "包 $PKGNAME 已解开核对：导出 $(stat -c %s "$X/db/litellm.dump") 字节，盐值指纹 $fp，端口 $PORT"
}

do_restore() {
  local found pre
  [ -f "$STATE_FILE" ] && die "上次演练的状态还在（$STATE_FILE），先 teardown $TARGET"
  section "取包与核对"
  open_package

  section "目标机预检"
  # 已有 litellm 容器、生产用的目录或端口被占：不是干净的备用机，一律拒绝
  found=$(rsh "PORT=$PORT W=$(printf '%q' "${LITELLM_WORKDIR:-/opt/litellm}") D=$DRILL_DIR bash -s" 2>/dev/null <<'REMOTE'
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^litellm(-postgres|-redis)?$' | sed 's/^/容器 /'
for d in "$D" /opt/litellm "$W"; do [ -e "$d" ] && echo "目录 $d"; done | sort -u
ss -lnt 2>/dev/null | grep -q ":$PORT " && echo "端口 $PORT 已被占用"
REMOTE
)
  [ -z "$found" ] || die "目标机不像干净的备用机，拒绝演练：${found//$'\n'/；}"
  ok "没有 litellm 容器与目录，端口 $PORT 空闲"

  mkdir -p "$(dirname "$STATE_FILE")"
  if rshn "command -v docker >/dev/null 2>&1"; then pre=1; log "目标机原本有 docker，teardown 时保留"
  else pre=0; log "目标机原本没有 docker，teardown 时会卸载还原"; fi
  # 状态文件在 teardown 时会被 source：值一律 %q 转义
  printf 'DOCKER_PREEXISTING=%q\nDRILL_START=%q\n' "$pre" "$(date -u '+%F %T')" > "$STATE_FILE"

  section "目标机安装 docker"
  rsh "bash -s" <<'REMOTE_DOCKER' || die "目标机 docker 安装失败"
set -o pipefail
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "  已就绪：$(docker --version)"
  systemctl is-active docker >/dev/null 2>&1 || systemctl start docker 2>/dev/null
  exit 0
fi
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null 2>&1
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || exit 1
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1 || exit 1
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null 2>&1 && echo "  安装完成：$(docker --version)" || exit 1
REMOTE_DOCKER

  section "按 RESTORE.md 恢复"
  rshn "mkdir -p $DRILL_DIR/.restore && touch $MARK" || die "目标机建目录失败"
  ( cd "$X" && tar czf - workdir db/litellm.dump system/docker-compose.pinned.yml ) \
    | rsh "tar xzf - -C $DRILL_DIR/.restore" || die "传输失败"
  rsh "D=$DRILL_DIR PORT=$PORT bash -s" <<'REMOTE_RUN' || die "恢复没有完成（原因见上）；清理用 teardown"
set -o pipefail
die() { echo "  ✗ $*"; exit 1; }
# 整段包进 { } 并接 /dev/null：bash 先读完整段再执行，中间哪个命令读 stdin 也吃不到后面的脚本
{
cd "$D" || die "没有 $D"
# 1. 先放 .env：postgres 首次启动按它初始化账号，litellm 启动时读盐值
cp -a .restore/workdir/. ./ && chmod 600 .env || die "放回工作目录失败"
cp .restore/system/docker-compose.pinned.yml docker-compose.yml || die "换 compose 失败"
echo "  .env 已放回（600），compose 已换成按 digest 锁定的版本"
docker compose pull -q >/dev/null 2>&1 || die "按 digest 拉镜像失败"
# 2. 只起 postgres（服务名，容器名是 litellm-postgres）
docker compose up -d postgres >/dev/null 2>&1 || die "postgres 起不来"
for _ in $(seq 60); do docker exec litellm-postgres pg_isready -U litellm -d litellm >/dev/null 2>&1 && break; sleep 2; done
docker exec litellm-postgres pg_isready -U litellm -d litellm >/dev/null 2>&1 || die "postgres 两分钟内没就绪"
# 3. 导入
docker exec -i litellm-postgres pg_restore -U litellm -d litellm --clean --if-exists \
  < .restore/db/litellm.dump 2> .restore/pg_restore.err \
  || { tail -n 5 .restore/pg_restore.err | sed 's/^/    /'; die "pg_restore 报错"; }
n=$(docker exec litellm-postgres psql -U litellm -d litellm -Atc 'SELECT count(*) FROM "LiteLLM_ProxyModelTable"' 2>/dev/null)
echo "  pg_restore 完成：LiteLLM_ProxyModelTable ${n:-?} 行"
# 4. 起全部，等健康
docker compose up -d >/dev/null 2>&1 || die "起全部容器失败"
c=""
for _ in $(seq 36); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null)
  [ "$c" = 200 ] && break; sleep 5
done
[ "$c" = 200 ] || { docker compose logs --tail=40 litellm 2>&1 | sed 's/^/    /'; die "LiteLLM 三分钟内没就绪（/health/liveliness 返回 ${c:-无响应}）"; }
echo "  /health/liveliness 200"
rm -rf .restore
docker compose ps --format '  {{.Name}}  {{.Image}}  {{.Status}}' 2>/dev/null
} </dev/null
REMOTE_RUN

  printf 'RESTORED_FROM=%q\nIMAGES=%q\nPORT=%q\n' "$PKGNAME" "$IMAGES" "$PORT" >> "$STATE_FILE"
  ok "恢复完成。下一步：litellm-drill.sh verify $TARGET"
}

# ── verify ──────────────────────────────────────────────────
count_rows() {  # count_rows <端口> <主机>：只读计数
  ssh "${SSH_OPTS[@]}" -p "$1" "root@$2" "TABLES='$TABLES' bash -s" 2>/dev/null <<'REMOTE'
for t in $TABLES; do
  n=$(docker exec litellm-postgres psql -U litellm -d litellm -Atc "SELECT count(*) FROM \"$t\"" 2>/dev/null) || n=
  printf '%s %s\n' "$t" "${n:-n/a}"
done
REMOTE
}

do_verify() {
  local pport prod drill t pv dv diff=0 rc PORT=4000
  [ -f "$STATE_FILE" ] || die "没有进行中的演练（$STATE_FILE），先 restore"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  section "与线上节点比行数（只读）"
  pport=${LITELLM_SSH_PORT:-$(vps_host_port "$LITELLM_HOST")}
  prod=$(count_rows "${pport:-22}" "$LITELLM_HOST")
  drill=$(count_rows "$TPORT" "$TARGET")
  [ -n "$drill" ] || die "读不到演练实例的数据"
  [ -n "$prod" ] || warn "读不到线上节点的数据（$LITELLM_HOST:${pport:-22}），只看演练实例"
  printf '  %-28s %-10s %-10s %s\n' 表 线上 演练 判定
  for t in $TABLES; do
    pv=$(awk -v k="$t" '$1 == k { print $2 }' <<<"$prod"); dv=$(awk -v k="$t" '$1 == k { print $2 }' <<<"$drill")
    if [ "$pv" = "$dv" ]; then printf '  %-28s %-10s %-10s 一致\n' "$t" "${pv:--}" "$dv"
    else printf '  %-28s %-10s %-10s 差异\n' "$t" "${pv:--}" "$dv"; diff=$((diff + 1)); fi
  done
  if [ "$diff" -eq 0 ]; then ok "行数全部一致"
  else log "有 ${diff} 张表不一致 —— 先看是不是备份之后线上又有写入（SpendLogs 每个请求一行，几乎总会差），再怀疑备份"; fi

  section "演练实例自检"
  rsh "PORT=$PORT D=$DRILL_DIR bash -s" <<'REMOTE'
c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null)
echo "  /health/liveliness: ${c:-无响应}"
# master key 经 stdin 交给 curl，不进命令行
body=$(grep -m1 '^LITELLM_MASTER_KEY=' "$D/.env" | cut -d= -f2- | sed 's/^/Authorization: Bearer /' \
  | curl -s -m 10 -H @- "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)
echo "  带 master key 列模型：$(printf '%s' "$body" | grep -o '"id"' | wc -l) 个"
e=$(docker logs litellm 2>&1 | grep -iE 'decrypt|salt' | tail -n 3 | cut -c1-200)
[ -z "$e" ] || { echo "  日志里有疑似解密错误："; printf '%s\n' "$e" | sed 's/^/    /'; exit 3; }
[ "$c" = 200 ] || exit 2
REMOTE
  rc=$?
  case $rc in
    0) ok "健康检查通过，日志里没有解密错误" ;;
    3) warn "日志里有疑似解密错误 —— 盐值可能不对，这份包恢复出来的上游凭据用不了" ;;
    *) warn "演练实例没有通过健康检查" ;;
  esac
  cat <<EOF

  列表出来只说明库导进去了（模型名不加密）。盐值对不对要实际调用一次：
    ssh -N -L $PORT:127.0.0.1:$PORT -p $TPORT root@$TARGET
  浏览器打开 http://127.0.0.1:$PORT/ui（admin / master key），Models 里对每条点 Test。
  演练实例能调通上游：说明这台机器的出口地区可用，也说明包里的盐值是对的。
  确认无误后：litellm-drill.sh teardown $TARGET
EOF
}

# ── teardown ────────────────────────────────────────────────
do_teardown() {
  local DOCKER_PREEXISTING=1 IMAGES=""
  # shellcheck disable=SC1090
  [ -r "$STATE_FILE" ] && . "$STATE_FILE"
  if ! rshn "[ -e $MARK ]"; then
    rshn "[ -e $DRILL_DIR ]" && die "目标机的 $DRILL_DIR 没有演练标记，不是本脚本建的，拒绝删除"
    log "目标机上没有演练目录"
  fi
  confirm "删除 $TARGET 上的演练实例（$DRILL_DIR 与 litellm 三个容器）？"
  section "清理演练实例"
  rsh "D=$DRILL_DIR IMAGES='$IMAGES' bash -s" <<'REMOTE'
if [ -e "$D/.litellm-drill" ]; then
  (cd "$D" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  echo "  已停并删除容器"
  rm -rf "$D" && echo "  已删除 $D"
fi
for i in $IMAGES; do docker rmi "$i" >/dev/null 2>&1 || true; done
[ -n "$IMAGES" ] && echo "  已删除演练拉的镜像"
exit 0
REMOTE
  if [ "$DOCKER_PREEXISTING" = 0 ]; then
    section "目标机原本没有 docker，卸载还原"
    rsh "bash -s" <<'REMOTE_PURGE'
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
rm -rf /var/lib/docker /var/lib/containerd
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
apt-get update -qq >/dev/null 2>&1 || true
command -v docker >/dev/null 2>&1 && echo "  docker 仍在（卸载未完全）" || echo "  docker 已卸载"
REMOTE_PURGE
  else
    log "目标机原本就有 docker，保留不动"
  fi
  section "还原确认"
  rsh "D=$DRILL_DIR bash -s" <<'REMOTE_CHECK'
echo "  $D: $([ -e "$D" ] && echo 仍存在 || echo 已清除)"
echo "  litellm 容器: $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -cE '^litellm(-postgres|-redis)?$') 个"
echo "  docker: $(command -v docker >/dev/null 2>&1 && docker --version || echo 未安装)"
REMOTE_CHECK
  rm -f "$STATE_FILE"
  ok "演练结束，目标机已还原"
}

# ── status ──────────────────────────────────────────────────
do_status() {
  if [ -r "$STATE_FILE" ]; then echo "--- 演练状态 $STATE_FILE ---"; sed 's/^/  /' "$STATE_FILE"
  else echo "没有进行中的演练（无状态文件）"; fi
  rsh "D=$DRILL_DIR bash -s" <<'REMOTE'
echo "--- 目标机 ---"
echo "  docker: $(command -v docker >/dev/null 2>&1 && docker --version || echo 未安装)"
docker ps -a --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | grep -E '^litellm(-postgres|-redis)?  ' | sed 's/^/  容器 /'
echo "  $D: $([ -e "$D/.litellm-drill" ] && echo 演练目录 || { [ -e "$D" ] && echo 存在但没有演练标记 || echo 不存在; })"
REMOTE
}

case "$ACTION" in
  restore)  do_restore ;;
  verify)   do_verify ;;
  teardown) do_teardown ;;
  status)   do_status ;;
esac
