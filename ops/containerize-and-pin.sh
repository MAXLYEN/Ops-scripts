#!/usr/bin/env bash
# containerize-and-pin.sh
# VERSION: 1.0.0
#
# 把 komari 与 SubConverter-Extended 从 docker run 转为 compose 管理，
# 并将四个容器的镜像由 latest 锁定为当前正在运行的 digest。不升级版本。
#
# 注意：
# - 锁 digest 而非 tag：digest 取自本地镜像的 RepoDigests，必定存在，不依赖 registry 上 tag 是否可用
# - container_name 显式写死：compose 默认名为 <项目>-<服务>-1，会导致按容器名查找的脚本失效
# - 旧容器停止后改名保留（不删除），compose 起不来时可改回
# - xboard 与 vaultwarden 已是 compose 管理，只改 image 行
set -o pipefail

TS=$(date +%Y%m%d%H%M%S)
BAK="/root/container-freeze-bak/${TS}"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die()  { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

put_file() {  # $1=临时文件 $2=目标 $3=权限
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "  [=] $2 未变化"; return 1; fi
  [ -f "$2" ] && cp -a "$2" "${BAK}/$(echo "$2" | tr '/' '_')"
  install -D -m "$3" "$1" "$2"; echo "  [+] $2 已写入"; return 0
}

digest_of() {  # $1=镜像引用
  docker image inspect "$1" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null
}

# ---------- 0. 预检 ----------
log "预检"
docker compose version >/dev/null 2>&1 || die "docker compose v2 不可用"
for c in komari SubConverter-Extended xboard-xboard-1 vaultwarden; do
  docker inspect "$c" >/dev/null 2>&1 || die "容器 $c 不存在"
done
[ -f /opt/xboard/compose.yaml ] || die "读不到 /opt/xboard/compose.yaml"

D_KOMARI=$(digest_of ghcr.io/komari-monitor/komari:latest)
D_SUB=$(digest_of aethersailor/subconverter-extended:latest)
D_XBOARD=$(digest_of ghcr.io/cedar2025/xboard:latest)
for v in "$D_KOMARI" "$D_SUB" "$D_XBOARD"; do
  case "$v" in *@sha256:*) ;; *) die "取不到镜像 digest，中止" ;; esac
done
echo "  将锁定："
echo "    komari        $D_KOMARI"
echo "    subconverter  $D_SUB"
echo "    xboard        $D_XBOARD"

mkdir -p "$BAK" || die "建不了 $BAK"
log "备份目录：$BAK"

# ---------- 1. 留存原容器参数 ----------
log "1/6 导出原容器完整参数（回滚依据）"
for c in komari SubConverter-Extended xboard-xboard-1 vaultwarden; do
  docker inspect "$c" > "${BAK}/inspect-${c}.json" && echo "  [+] inspect-${c}.json"
done

# ---------- 2. 停机冷备 ----------
log "2/6 停止 komari 与 SubConverter-Extended 并冷备数据"
docker stop komari SubConverter-Extended >/dev/null || die "停止容器失败"

if [ -d /root/data ]; then
  tar czf "${BAK}/komari-data.tar.gz" -C /root data || die "komari 数据打包失败"
  echo "  [+] komari-data.tar.gz  $(du -h "${BAK}/komari-data.tar.gz" | cut -f1)"
else
  warn "/root/data 不存在，跳过"
fi
if [ -d /opt/SubConverter-Extended ]; then
  tar czf "${BAK}/subconverter.tar.gz" -C /opt SubConverter-Extended || die "SubConverter 数据打包失败"
  echo "  [+] subconverter.tar.gz  $(du -h "${BAK}/subconverter.tar.gz" | cut -f1)"
fi

# ---------- 3. 搬迁 komari 数据目录 ----------
log "3/6 komari 数据目录 /root/data -> /opt/komari/data"
if [ -d /opt/komari/data ]; then
  echo "  [=] 目标已存在，跳过搬迁"
elif [ -d /root/data ]; then
  mkdir -p /opt/komari
  mv /root/data /opt/komari/data || die "搬迁失败（数据已备份在 $BAK）"
  echo "  [+] 已搬迁，$(du -sh /opt/komari/data | cut -f1)"
else
  die "/root/data 不存在，无法搬迁"
fi

# ---------- 4. 生成 compose ----------
log "4/6 生成 compose 文件"
T=$(mktemp)
cat > "$T" <<EOF
# komari —— 由 containerize-and-pin.sh 生成
# 运行版本：1.5.0-fix1（镜像构建于 2026-09-14）
# 镜像锁 digest，升级时改 image 行并先跑备份
services:
  komari:
    container_name: komari
    image: ${D_KOMARI}
    restart: unless-stopped
    ports:
      - "127.0.0.1:10086:25774"
    volumes:
      - /opt/komari/data:/app/data
    environment:
      GIN_MODE: release
      KOMARI_LISTEN: 0.0.0.0:25774
EOF
put_file "$T" /opt/komari/compose.yaml 644
rm -f "$T"

T=$(mktemp)
cat > "$T" <<EOF
# SubConverter-Extended —— 由 containerize-and-pin.sh 生成
# 运行版本：v1.9.6（镜像构建于 2026-09-16）
# 镜像锁 digest，升级时改 image 行并先跑备份
services:
  subconverter:
    container_name: SubConverter-Extended
    image: ${D_SUB}
    restart: unless-stopped
    ports:
      - "127.0.0.1:25500:25500"
    volumes:
      - /opt/SubConverter-Extended/stats:/base/stats
      - /opt/SubConverter-Extended/base/pref.toml:/base/pref.toml
    environment:
      TZ: Asia/Shanghai
EOF
put_file "$T" /opt/SubConverter-Extended/compose.yaml 644
rm -f "$T"

# ---------- 5. 切换 ----------
log "5/6 旧容器改名保留并用 compose 接管"
docker rename komari "komari-preswitch-${TS}" || die "改名失败"
docker rename SubConverter-Extended "SubConverter-preswitch-${TS}" || die "改名失败"
echo "  [~] 旧容器已改名保留（确认无误后再手动 docker rm）"

docker compose -f /opt/komari/compose.yaml up -d || die "komari 启动失败，旧容器名为 komari-preswitch-${TS}"
docker compose -f /opt/SubConverter-Extended/compose.yaml up -d || die "SubConverter 启动失败，旧容器名为 SubConverter-preswitch-${TS}"

# ---------- 6. xboard 锁版本 ----------
log "6/6 xboard compose 锁定 digest"
N=$(grep -cE '^[[:space:]]*image:.*cedar2025/xboard' /opt/xboard/compose.yaml)
if [ "$N" != 1 ]; then
  warn "xboard compose 里匹配到 ${N} 行 image，未自动修改，请手工处理"
else
  cp -a /opt/xboard/compose.yaml "${BAK}/xboard-compose.yaml"
  sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*cedar2025/xboard.*|\1${D_XBOARD}|" /opt/xboard/compose.yaml
  echo "  [+] 已改为：$(grep -E '^[[:space:]]*image:' /opt/xboard/compose.yaml)"
  docker compose -f /opt/xboard/compose.yaml up -d || die "xboard 启动失败，原文件在 ${BAK}/xboard-compose.yaml"
fi

# ---------- 自检 ----------
echo; echo "===== 自检 ====="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
echo
echo "  本地端口："
for p in 10086 25500; do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:${p}/" 2>/dev/null)
  printf '    127.0.0.1:%-6s HTTP %s\n' "$p" "${C:-无响应}"
done
echo "  对外站点："
for S in komari.techx.blog api.29s.org; do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://${S}/" 2>/dev/null)
  printf '    %-22s HTTP %s\n' "$S" "${C:-无响应}"
done
echo
echo "  保留的旧容器（确认无误后手动删除）："
docker ps -a --filter 'name=preswitch' --format '    {{.Names}}  {{.Status}}'
echo
echo "  备份目录：$BAK"
