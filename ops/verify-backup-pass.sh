#!/usr/bin/env bash
# ops/verify-backup-pass.sh — 验证本地密码能打开云端的加密包
# VERSION: 2.0.0
#
# 从云端取最近的包下来，用本机的密码文件实际解一次。
# 如果哪天真要靠云端的包重建，密码必须是对的 —— 现在验比那时候验强得多。
#
# 建议每季度跑一次，配合还原演练。
# ENV-REQUIRED: BACKUP_PASS_FILES RCLONE_PATHS RCLONE_REMOTES

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env RCLONE_REMOTES RCLONE_PATHS BACKUP_PASS_FILES
require_cmd rclone 7z

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT

section "密码文件"
for f in $BACKUP_PASS_FILES; do
  if [ -f "$f" ]; then
    p=$(stat -c %a "$f")
    printf '  %-30s %s 字符  权限 %s\n' "$f" "$(wc -c < "$f" | tr -d ' ')" "$p"
    [ "$p" = 600 ] || warn "$f 权限应为 600"
  else
    warn "缺失 $f"
  fi
done

# 逐个远端目录取最新的包，逐个密码试
for r in $RCLONE_REMOTES; do
  for p in $RCLONE_PATHS; do
    section "$r:/$p"
    NEWEST=$(rclone lsf "$r:/$p" --include '*.7z' 2>/dev/null | sort | tail -1)
    if [ -z "$NEWEST" ]; then warn "没有 .7z 文件"; continue; fi
    echo "  最新包: $NEWEST"
    rclone copy "$r:/$p/$NEWEST" "$TD/" 2>&1 | tail -1
    [ -f "$TD/$NEWEST" ] || { warn "下载失败"; continue; }
    echo "  大小: $(human "$TD/$NEWEST")"

    okpass=""
    for f in $BACKUP_PASS_FILES; do
      [ -f "$f" ] || continue
      # < /dev/null 很关键：文件名也加密的包在缺密码时会交互式等输入，
      # 不喂 stdin 会一直挂住
      if 7z t -p"$(cat "$f")" "$TD/$NEWEST" >/dev/null 2>&1 < /dev/null; then
        okpass=$f; break
      fi
    done
    if [ -n "$okpass" ]; then
      ok "可用密码: $okpass，完整性自检通过"
      echo "  内容:"
      7z l -p"$(cat "$okpass")" "$TD/$NEWEST" < /dev/null 2>/dev/null \
        | tail -12 | sed 's/^/    /'
    else
      warn "所有已配置的密码都打不开 $NEWEST"
    fi
    rm -f "$TD/$NEWEST"
  done
done
finish
