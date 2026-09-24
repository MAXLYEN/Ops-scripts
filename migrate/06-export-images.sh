#!/usr/bin/env bash
# migrate/06-export-images.sh — 在迁出机导出当前容器镜像
# VERSION: 2.0.1
# 2.0.1: 整理注释并补充目录文档，执行逻辑未变。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_cmd docker gzip
docker_ready || die "docker 不可用"

OUT="${IMAGE_EXPORT_DIR:-${SNAPSHOT_ROOT:?配置里缺 SNAPSHOT_ROOT}/images}"
mkdir -p "$OUT"

IMAGES=$(docker ps -a --format '{{.Image}}' | sort -u)
[ -n "$IMAGES" ] || die "没找到任何容器镜像"

section "待导出"
for i in $IMAGES; do
  sz=$(docker image inspect "$i" --format '{{.Size}}' 2>/dev/null | numfmt --to=iec 2>/dev/null)
  printf '  %-56s %s\n' "$i" "${sz:-?}"
done

section "导出"
for i in $IMAGES; do
  f="$OUT/$(echo "$i" | tr '/:' '__').tar.gz"
  if [ -f "$f" ]; then log "[=] 已存在，跳过 $(basename "$f")"; continue; fi
  log "导出 $i"
  docker save "$i" | gzip -1 > "$f"
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] || { rm -f "$f"; die "$i 导出失败"; }
  ok "$(basename "$f")  $(human "$f")"
done

section "记录镜像 ID（迁入后核对用）"
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' > "$OUT/images.list"
cat "$OUT/images.list" | sed 's/^/  /'

sha_write "$OUT"
section 完成
echo "  $OUT  ($(human "$OUT"))"
cat <<EOF

  传输并载入：
    scp -P <迁入机SSH端口> -r $OUT root@<迁入机IP>:/root/
  迁入机上：
    cd /root/$(basename "$OUT") \\
      && grep -v ' SHA256SUMS\$' SHA256SUMS | sha256sum -c - \\
      && for f in *.tar.gz; do echo "载入 \$f"; gunzip -c "\$f" | docker load; done \\
      && docker images

  载入后用 images.list 核对镜像 ID 是否一致。
EOF
finish
