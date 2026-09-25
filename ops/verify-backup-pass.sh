#!/usr/bin/env bash
# ops/verify-backup-pass.sh — 验证本地密码能否解开云端备份包
# VERSION: 2.1.0
# 2.1.0: 新增 --cron（失败告警 + 心跳）；检查最新包的时效，过旧即告警；按修改时间取最新包；超大包跳过。
# ENV-REQUIRED: BACKUP_PASS_FILES RCLONE_PATHS RCLONE_REMOTES
# 定时用法见 ops/README.md：每周一次，把「包能解开」从假设变成定期验证过的事实。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env RCLONE_REMOTES RCLONE_PATHS BACKUP_PASS_FILES
require_cmd rclone 7z

CRON=0; [ "${1:-}" = "--cron" ] && CRON=1
# 最新包超过这个时长就算失败：包本身能解开，但备份可能早已悄悄停止上传
MAX_AGE_H=$(( ${VERIFY_MAX_AGE_DAYS:-2} * 24 ))
# 超过这个体积的包不下载（如面板整机备份），只在汇总里注明
MAX_MB="${VERIFY_MAX_MB:-2048}"
SUMMARY=""
note() { SUMMARY="$SUMMARY$*"$'\n'; }

hb() {
  [ -n "${VERIFY_HEARTBEAT_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 "${VERIFY_HEARTBEAT_URL}${1:-}" >/dev/null 2>&1 || log "心跳上报失败${1:-}"
}

# 与备份脚本同一套：邮件重试三次 → webhook → 落盘，能通一条就算送达
alert() {  # $1=主题 $2=正文
  local sent=0 i
  if [ -n "${MAIL_TO:-}" ] && command -v msmtp >/dev/null 2>&1; then
    for i in 1 2 3; do
      printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$MAIL_TO" "$1" "$2" \
        | msmtp -t && { sent=1; break; }
      [ "$i" -lt 3 ] && sleep 20
    done
  fi
  if [ "$sent" = 0 ] && [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -fsS -m 10 -X POST --data-urlencode "text=[$(hostname)] $1" "$ALERT_WEBHOOK" >/dev/null 2>&1 && sent=1
  fi
  [ "$sent" = 1 ] || printf '[%s] [未送达] %s\n%s\n' "$(date -u '+%F %T')" "$1" "$2" \
    >> "${ALERT_FALLBACK_FILE:-/var/log/backup-alerts.log}"
}

[ "$CRON" = 1 ] && hb /start
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT

section "密码文件"
for f in $BACKUP_PASS_FILES; do
  if [ -f "$f" ]; then
    p=$(stat -c %a "$f")
    printf '  %-30s %s 字符  权限 %s\n' "$f" "$(wc -c < "$f" | tr -d ' ')" "$p"
    [ "$p" = 600 ] || { warn "$f 权限应为 600"; note "✗ 密码文件 $f 权限 $p"; }
  else
    warn "缺失 $f"; note "✗ 密码文件缺失 $f"
  fi
done

# 逐个远端目录取最新的包，逐个密码试
for r in $RCLONE_REMOTES; do
  for p in $RCLONE_PATHS; do
    section "$r:/$p"
    # 按修改时间取最新，而不是按文件名：目录里可能混着不同命名的包
    LINE=$(rclone lsf "$r:/$p" --include '*.7z' --format tsp 2>/dev/null | sort | tail -1)
    if [ -z "$LINE" ]; then warn "没有 .7z 文件"; note "✗ $r:/$p 没有 .7z 文件"; continue; fi
    MT=${LINE%%;*}; REST=${LINE#*;}; SIZE=${REST%%;*}; NEWEST=${REST#*;}
    case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac   # 个别网盘不报大小（-1），按 0 处理照常下载
    AGE_H=$(( ($(date +%s) - $(date -d "$MT" +%s 2>/dev/null || date +%s)) / 3600 ))
    echo "  最新包: $NEWEST（$MT，$((AGE_H / 24)) 天 $((AGE_H % 24)) 小时前，$((SIZE / 1048576))MB）"
    STALE=""
    if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
      warn "最新包已是 $((AGE_H / 24)) 天前 —— 备份可能已停止上传"
      STALE="，但已 $((AGE_H / 24)) 天没有新包"
    fi
    if [ "$SIZE" -gt $((MAX_MB * 1048576)) ]; then
      log "超过 ${MAX_MB}MB，跳过下载校验"
      note "- $r:/$p $NEWEST 超过 ${MAX_MB}MB，未校验$STALE"
      continue
    fi
    rclone copy "$r:/$p/$NEWEST" "$TD/" 2>&1 | tail -1
    [ -f "$TD/$NEWEST" ] || { warn "下载失败"; note "✗ $r:/$p $NEWEST 下载失败"; continue; }

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
      if [ -n "$STALE" ]; then note "✗ $r:/$p $NEWEST 可解开$STALE"
      else note "✓ $r:/$p $NEWEST 可解开（$((AGE_H / 24)) 天前）"; fi
    else
      warn "所有已配置的密码都打不开 $NEWEST"
      note "✗ $r:/$p $NEWEST 所有密码都打不开"
    fi
    rm -f "$TD/$NEWEST"
  done
done

section "汇总"
printf '%s' "$SUMMARY" | sed 's/^/  /'
if [ "$CRON" = 1 ]; then
  if [ "$OPS_WARNINGS" -gt 0 ]; then
    hb /fail
    alert "[$(hostname)] 云端备份校验未通过（${OPS_WARNINGS} 项）" \
          "$(printf '%s\n主机: %s\n时间: %s UTC\n' "$SUMMARY" "$(hostname)" "$(date -u '+%F %T')")"
  else
    hb
  fi
fi
finish
