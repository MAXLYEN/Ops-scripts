#!/usr/bin/env bash
# ops/verify-backup-pass.sh — 验证本地密码能否解开云端备份包
# VERSION: 3.1.0
# 3.1.0: 核对 .sha256：每个 .7z 都要有 .sha256，缺了告警；下载下来的最新包和它的 .sha256 比对，不符告警；网盘能直接报 sha256 的（如 Google Drive）不用下载，目录里每个包都和自己的 .sha256 比一遍，报不了的（如 OneDrive）只比最新包。装了 panel-backup-upload 就把宝塔整机备份的目录（PANEL_BACKUP_REMOTE_PATH，默认 Backups/panel）也校验，每周一次，超过 8 天才算过旧。
# 3.0.0: 按 2026-10 备份重新规划：装了哪个备份脚本就校验它的 <BACKUP_CLOUD_ROOT>/<包名>（vault、hk-host、newapi、litellm），RCLONE_PATHS 改为可选（额外要校验的目录）。「最新包过旧」按包算：litellm 每周一次，超过 8 天才算；其余超过 VERIFY_MAX_AGE_DAYS（默认 2 天）。
# 2.2.0: 本机装了哪个备份脚本，就把它的云端目录并入校验（不在 RCLONE_PATHS 里时自动加上并提示补配置），LiteLLM 包不会漏校验。
# 2.1.0: 新增 --cron（失败告警 + 心跳）；检查最新包的时效，过旧即告警；按修改时间取最新包；超大包跳过。
# ENV-REQUIRED: BACKUP_PASS_FILES RCLONE_REMOTES
# 定时用法见 ops/README.md：每周一次，把「包能解开」从假设变成定期验证过的事实。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_env RCLONE_REMOTES BACKUP_PASS_FILES
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

# 装了哪个备份脚本，就校验它的云端目录 <BACKUP_CLOUD_ROOT>/<包名>（不用手填，新增脚本不会漏）。
# RCLONE_PATHS 可选：另外要校验的目录（例如别的机器传上来的包）
section "校验范围"
PATHS=""
declare -A MAXH=()
while read -r s pkg days; do
  [ -x "${OPS_BIN_DIR:-/usr/local/bin}/$s.sh" ] || continue
  d=$(bk_cloud_dir "$pkg")
  [ "$pkg" = panel ] && [ -n "${PANEL_BACKUP_REMOTE_PATH:-}" ] && { d=${PANEL_BACKUP_REMOTE_PATH#/}; d=${d%/}; }
  PATHS="$PATHS $d"; MAXH[$d]=$(( ${days:-0} * 24 ))
  echo "  $s → $d"
done <<'EOF'
vault-backup vault
hk-host-backup hk-host
newapi-fullbackup newapi
litellm-fullbackup litellm 8
panel-backup-upload panel 8
EOF
for p in ${RCLONE_PATHS:-}; do
  p=${p#/}; p=${p%/}
  [ -n "$p" ] || continue
  case " $PATHS " in *" $p "*) ;; *) PATHS="$PATHS $p"; echo "  RCLONE_PATHS → $p" ;; esac
done
[ -n "${PATHS// /}" ] || { warn "本机一个备份脚本都没装，RCLONE_PATHS 也没填，没有可校验的目录"; finish; exit $?; }

# 每个 .7z 都要有 .sha256。网盘能直接报 sha256 的（如 Google Drive）不用下载，逐个和 .sha256 比；
# 报不了的（如 OneDrive）只比下面下载下来的最新包
first3() { local a; read -r -a a <<<"$1"; printf '%s' "${a[*]:0:3}"; [ "${#a[@]}" -le 3 ] || printf ' …'; }
sha_audit() {  # sha_audit <远端> <目录>
  local r=$1 p=$2 lst f got want hs d miss="" nm=0 bad="" nb=0 nc=0
  lst=$(rclone lsf "$r:/$p" --files-only 2>/dev/null) || return 0
  while IFS= read -r f; do
    [[ $f == *.7z ]] || continue
    grep -qxF "$f.sha256" <<<"$lst" || { miss="$miss $f"; nm=$((nm + 1)); }
  done <<<"$lst"
  if [ "$nm" -gt 0 ]; then
    warn "$nm 个包没有 .sha256：$(first3 "$miss")"
    note "✗ $r:/$p 有 $nm 个包没有 .sha256"
  fi
  hs=$(rclone hashsum sha256 "$r:/$p" --include '*.7z' 2>/dev/null | grep -E '^[0-9a-f]{64}  ') || hs=""
  if [ -z "$hs" ]; then log "这个网盘报不了 sha256，只核对下载下来的最新包"; return 0; fi
  d="$TD/sha"; rm -rf "$d"; mkdir -p "$d"
  rclone copy "$r:/$p" "$d/" --include '*.sha256' >/dev/null 2>&1
  while read -r got f; do
    [ -f "$d/$f.sha256" ] || continue
    want=$(cut -d' ' -f1 < "$d/$f.sha256"); nc=$((nc + 1))
    [ "$want" = "$got" ] || { bad="$bad $f"; nb=$((nb + 1)); }
  done <<<"$hs"
  rm -rf "$d"
  if [ "$nb" -gt 0 ]; then
    warn "$nb 个包和自己的 .sha256 对不上：$(first3 "$bad")"
    note "✗ $r:/$p 有 $nb 个包和 .sha256 对不上"
  else
    ok "网盘报的 sha256：$nc 个包都和 .sha256 一致"
  fi
}

# 逐个远端目录取最新的包，逐个密码试
for r in $RCLONE_REMOTES; do
  for p in $PATHS; do
    section "$r:/$p"
    # 按修改时间取最新，而不是按文件名：目录里可能混着不同命名的包
    LINE=$(rclone lsf "$r:/$p" --include '*.7z' --format tsp 2>/dev/null | sort | tail -1)
    if [ -z "$LINE" ]; then warn "没有 .7z 文件"; note "✗ $r:/$p 没有 .7z 文件"; continue; fi
    MT=${LINE%%;*}; REST=${LINE#*;}; SIZE=${REST%%;*}; NEWEST=${REST#*;}
    sha_audit "$r" "$p"
    case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac   # 个别网盘不报大小（-1），按 0 处理照常下载
    AGE_H=$(( ($(date +%s) - $(date -d "$MT" +%s 2>/dev/null || date +%s)) / 3600 ))
    echo "  最新包: $NEWEST（$MT，$((AGE_H / 24)) 天 $((AGE_H % 24)) 小时前，$((SIZE / 1048576))MB）"
    STALE=""
    lim=${MAXH[$p]:-0}; [ "$lim" -gt 0 ] || lim=$MAX_AGE_H
    if [ "$AGE_H" -gt "$lim" ]; then
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
    SHA=""
    if rclone copy "$r:/$p/$NEWEST.sha256" "$TD/" >/dev/null 2>&1 && [ -s "$TD/$NEWEST.sha256" ]; then
      if [ "$(cut -d' ' -f1 < "$TD/$NEWEST.sha256")" = "$(sha256sum "$TD/$NEWEST" | cut -d' ' -f1)" ]; then
        ok "sha256 与 .sha256 一致"; SHA="、sha256 一致"
      else
        warn "$NEWEST 和它的 .sha256 对不上：包被改过或没传完整"
        STALE="$STALE，sha256 对不上"
      fi
    fi

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
      else note "✓ $r:/$p $NEWEST 可解开$SHA（$((AGE_H / 24)) 天前）"; fi
    else
      warn "所有已配置的密码都打不开 $NEWEST"
      note "✗ $r:/$p $NEWEST 所有密码都打不开"
    fi
    rm -f "$TD/$NEWEST" "$TD/$NEWEST.sha256"
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
