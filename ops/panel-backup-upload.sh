#!/usr/bin/env bash
# ops/panel-backup-upload.sh — 加密并上传面板生成的整机备份包
# VERSION: 1.0.5
# 1.0.5: --prune 只清理本机上传台账里、校验通过的包，不再按名字删掉整个云端目录里的其他文件。
# ENV-REQUIRED: RCLONE_REMOTES

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env RCLONE_REMOTES
require_cmd rclone

SRCDIR="${PANEL_BACKUP_DIR:-/www/backup/backup_restore}"
DEST="${PANEL_BACKUP_REMOTE_PATH:-BTBackup-AllServer}"
MODE=upload; RAW=0; PRUNE=0; FILE=""
# 本机上传且校验通过的包，一行「远端<TAB>文件名」，按上传先后排列。
# --prune 只按它删：云端目录（默认名就叫 AllServer）可能是多台机器共用的，
# 按目录列表删会连别的服务器的备份一起删掉。
UP_LEDGER=/var/lib/ops-scripts/panel-backup-uploaded.list

while [ $# -gt 0 ]; do
  case "$1" in
    --list)  MODE=list ;;
    --raw)   RAW=1 ;;
    --file)  shift; FILE="${1:?--file 后面要跟路径}" ;;
    --prune) shift; PRUNE="${1:?--prune 后面要跟数量}" ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

case "$PRUNE" in ''|*[!0-9]*) die "--prune 需要非负整数: $PRUNE" ;; esac
[ -d "$SRCDIR" ] || die "面板备份目录不存在: $SRCDIR（在配置里设 PANEL_BACKUP_DIR）"

section "本地面板备份包"
ls -lht "$SRCDIR"/*backup.tar.gz 2>/dev/null | head -10 | sed 's/^/  /' \
  || { echo "  (无)"; [ "$MODE" = upload ] && die "$SRCDIR 下没有备份包，先在面板里生成一个"; }

section "云端已有"
for r in $RCLONE_REMOTES; do
  echo "  --- $r:/$DEST ---"
  if rclone lsl "$r:/$DEST" 2>/dev/null | sort -k4 | tail -10 | sed 's/^/    /'; then :; else
    echo "    (目录不存在或为空，上传时会自动创建)"
  fi
done

[ "$MODE" = list ] && { finish; exit $?; }

# ── 选定要传的包 ────────────────────────────────────────────
if [ -z "$FILE" ]; then
  FILE=$(ls -t "$SRCDIR"/*backup.tar.gz 2>/dev/null | head -1)
fi
[ -n "$FILE" ] && [ -f "$FILE" ] || die "找不到要上传的包"
NAME=$(basename "$FILE")
SIZE=$(stat -c %s "$FILE")

section "待上传"
printf '  %s\n  %s  (%s 字节)\n' "$FILE" "$(human "$FILE")" "$SIZE"
# 按历史实测的上传速率粗估，心里有个数，别以为卡住了
EST=$((SIZE / 1200000))
[ "$EST" -gt 60 ] && log "按约 1.2MB/s 估算，每个远端约需 $((EST / 60)) 分钟"

WORK=""; UPFILE="$FILE"; UPDIR="$SRCDIR"
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

if [ "$RAW" -eq 1 ]; then
  warn "--raw：原样上传，不加密"
  echo "  面板备份包里含站点配置、数据库、证书私钥和面板凭据 —— 明文放网盘要想清楚"
else
  # 为什么默认加密：这个包能在任意一台面板上一键恢复，等于一把总钥匙。
  # 用 -mx=0 只封装不压缩 —— 里面已经是 tar.gz，再压一遍纯属浪费 CPU。
  PASSFILE=$(echo $BACKUP_PASS_FILES | awk '{print $1}')
  [ -n "$PASSFILE" ] && [ -f "$PASSFILE" ] || die "找不到备份密码文件（配置 BACKUP_PASS_FILES），或用 --raw 跳过加密"
  require_cmd 7z
  WORK=$(mktemp -d); chmod 700 "$WORK"
  UPFILE="$WORK/${NAME%.tar.gz}.7z"
  section "加密封装"
  log "用 $PASSFILE，AES-256 + 文件名加密，不重复压缩"
  7z a -t7z -mx=0 -mhe=on -p"$(cat "$PASSFILE")" "$UPFILE" "$FILE" >/dev/null < /dev/null \
    || die "7z 封装失败"
  # 自检：打不开的包等于没有备份
  7z t -p"$(cat "$PASSFILE")" "$UPFILE" >/dev/null 2>&1 < /dev/null \
    || die "加密包自检失败，不要信任它"
  ok "$(basename "$UPFILE")  $(human "$UPFILE")  自检通过"
  NAME=$(basename "$UPFILE"); UPDIR="$WORK"
fi

section "上传"
for r in $RCLONE_REMOTES; do
  log "→ $r:/$DEST"
  # 退出码不在这里判 —— 下面的 rclone check 做单向校验才是判据
  rclone copy "$UPFILE" "$r:/$DEST" --progress 2>&1 | tail -2 | sed 's/^/    /'
  # 云盘写入后元数据有延迟，立刻校验会误报，等一下再比
  sleep 10
  if rclone check "$UPDIR" "$r:/$DEST" --include "$NAME" --one-way >/dev/null 2>&1; then
    ok "$r 校验通过"
    mkdir -p "$(dirname "$UP_LEDGER")"
    grep -qxF "$r"$'\t'"$NAME" "$UP_LEDGER" 2>/dev/null || printf '%s\t%s\n' "$r" "$NAME" >> "$UP_LEDGER"
  else
    warn "$r 校验未通过"
  fi
done

if [ "$PRUNE" -gt 0 ]; then
  section "云端保留本机最近上传的 $PRUNE 个"
  echo "  只处理 $UP_LEDGER 里记录的包；其他服务器的、台账建立前上传的，一律不动"
  for r in $RCLONE_REMOTES; do
    OLD=$(awk -F'\t' -v r="$r" '$1==r {print $2}' "$UP_LEDGER" 2>/dev/null | head -n -"$PRUNE")
    if [ -z "$OLD" ]; then echo "  $r: 无需清理"; continue; fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if rclone deletefile "$r:/$DEST/$f" >/dev/null 2>&1; then
        echo "  $r 已删 $f"
        awk -F'\t' -v r="$r" -v f="$f" '!($1==r && $2==f)' "$UP_LEDGER" > "$UP_LEDGER.tmp" \
          && mv "$UP_LEDGER.tmp" "$UP_LEDGER"
      else
        echo "  $r 删除失败 $f"
      fi
    done <<< "$OLD"
  done
fi

section "结果"
for r in $RCLONE_REMOTES; do
  echo "  --- $r:/$DEST ---"
  rclone lsl "$r:/$DEST" 2>/dev/null | sort -k4 | tail -5 | sed 's/^/    /'
done

cat <<EOF

  恢复方式：
    1. 从网盘下载该包
$([ "$RAW" -eq 1 ] || echo "    2. 解密: 7z x <包名>.7z    （提示输密码，用 $PASSFILE 里的）")
    $([ "$RAW" -eq 1 ] && echo 2 || echo 3). 在目标机的面板里用「备份恢复」功能导入 tar.gz

  这个包是粗放的兜底手段。真要迁移，仍建议走 migrate/ 那套流程 ——
  它能逐表核对行数，出问题能定位到具体是哪一环。
EOF
finish
