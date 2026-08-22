#!/usr/bin/env bash
# vpsscore/collect.sh — 把多台机器的 probe JSON 收到一处并打分
# VERSION: 1.0.0
#
# 主机清单**自动发现**，优先级从高到低：
#   1. 命令行指定的清单文件
#   2. /etc/ops-scripts/vps-hosts.txt 或 ~/.vps-hosts.txt
#   3. ~/.ssh/config 里的 Host 条目（通配条目跳过）
#
# 走 ssh 别名时端口/IP/用户全由 ssh 自己解析，不用在这里重复维护一份 ——
# 两处维护同一份连接信息，迟早会不一致，而不一致的那天你正在排别的故障。
#
# 清单文件格式（# 开头为注释）：每行一个 ssh 目标，可以是
#   ssh 别名             例如  hk-node
#   user@host            例如  root@1.2.3.4
#   user@host:端口       例如  root@1.2.3.4:2222
#
# 用法:
#   collect.sh                    自动发现主机，收集已有 JSON 并打分
#   collect.sh <清单文件>         用指定清单
#   collect.sh -p                 先在每台上重新采集，再收集打分
#   collect.sh -n                 只列出将要连接的主机，不动手（先看再跑）
#   collect.sh -o <目录>          指定汇总目录，默认 ~/vpsscore-baseline
#   collect.sh -j 4               并发数，默认 4（仅 -p 时有意义）
#   collect.sh -h
#
# 本机的 JSON 会自动带上，不用把自己也写进清单。

set -o pipefail

OUTDIR="${HOME}/vpsscore-baseline"
DO_PROBE=0; DRY=0; JOBS=4; LIST=""
REMOTE_DIR=/var/lib/vpsscore

usage() {
  cat <<'USAGE'
collect.sh — 汇总多台机器的 VPS 质量采集结果并打分

  collect.sh                  自动发现主机，收集已有 JSON 并打分
  collect.sh <清单文件>       用指定清单
  collect.sh -p               先在每台上重新采集（耗时约 1-2 分钟/台）
  collect.sh -n               只列出将要连接的主机，不实际连接
  collect.sh -o <目录>        汇总目录，默认 ~/vpsscore-baseline
  collect.sh -j <并发数>      默认 4，仅 -p 时有意义
  collect.sh -h

主机清单自动发现顺序：
  1. 命令行给的清单文件
  2. /etc/ops-scripts/vps-hosts.txt  或  ~/.vps-hosts.txt
  3. ~/.ssh/config 里的 Host 条目（跳过含 * ? 的通配条目）

清单每行一个 ssh 目标：ssh 别名 / user@host / user@host:端口
本机会自动包含在内，不用写进清单。
USAGE
}

log()  { printf '%s\n' "$*" >&2; }
die()  { printf '[致命] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    -p|--probe) DO_PROBE=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -o|--out)   [ -n "${2:-}" ] || die "-o 需要一个目录"; OUTDIR="$2"; shift 2 ;;
    -j|--jobs)  [ -n "${2:-}" ] || die "-j 需要一个数字"; JOBS="$2"; shift 2 ;;
    --) shift; break ;;
    -*) log "未知参数: $1"; usage; exit 1 ;;
    *)  LIST="$1"; shift ;;
  esac
done

command -v ssh >/dev/null 2>&1 || die "缺少 ssh"
case "$JOBS" in ''|*[!0-9]*) die "-j 必须是数字: $JOBS" ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1

# ── 发现主机 ────────────────────────────────────────────────
hosts_from_file() {
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" \
    | awk 'NF { print $1 }'
}

hosts_from_ssh_config() {
  local cfg="$HOME/.ssh/config"
  [ -r "$cfg" ] || return 0
  # 只取具体主机名，跳过 `Host *` 这类通配条目 —— 它们不是真实机器，
  # 连过去只会得到一串超时
  awk '
    /^[[:space:]]*[Hh]ost[[:space:]]+/ {
      for (i = 2; i <= NF; i++) if ($i !~ /[*?]/) print $i
    }' "$cfg"
}

SRC=""
if [ -n "$LIST" ]; then
  [ -r "$LIST" ] || die "读不到清单文件: $LIST"
  HOSTS=$(hosts_from_file "$LIST"); SRC="清单文件 $LIST"
elif [ -r /etc/ops-scripts/vps-hosts.txt ]; then
  HOSTS=$(hosts_from_file /etc/ops-scripts/vps-hosts.txt)
  SRC="/etc/ops-scripts/vps-hosts.txt"
elif [ -r "$HOME/.vps-hosts.txt" ]; then
  HOSTS=$(hosts_from_file "$HOME/.vps-hosts.txt")
  SRC="$HOME/.vps-hosts.txt"
else
  HOSTS=$(hosts_from_ssh_config); SRC="~/.ssh/config"
fi
HOSTS=$(printf '%s\n' $HOSTS | awk 'NF && !seen[$0]++')

if [ -z "$HOSTS" ] && [ ! -d "$REMOTE_DIR" ]; then
  log "没有发现任何远程主机，本机也没有 $REMOTE_DIR。"
  log "做法二选一："
  log "  · 在 ~/.ssh/config 里配好各机器（推荐，端口/IP 只维护一处）"
  log "  · 建 ~/.vps-hosts.txt，每行一个 user@host 或 user@host:端口"
  exit 1
fi

# user@host:端口 → ssh 参数
ssh_args() {
  case "$1" in
    *:*) printf '%s -p %s' "${1%:*}" "${1##*:}" ;;
    *)   printf '%s' "$1" ;;
  esac
}
scp_args() {  # scp 的端口参数是 -P，且要放在源之前
  case "$1" in
    *:*) printf -- '-P %s' "${1##*:}" ;;
    *)   printf '' ;;
  esac
}
target_of() { printf '%s' "${1%:*}"; }

if [ "$DRY" -eq 1 ]; then
  log "主机来源: $SRC"
  log "将要连接的主机："
  if [ -n "$HOSTS" ]; then printf '  %s\n' $HOSTS >&2; else log "  （无）"; fi
  [ -d "$REMOTE_DIR" ] && log "  （本机 $REMOTE_DIR 也会一并纳入）"
  log "汇总目录: $OUTDIR"
  [ "$DO_PROBE" -eq 1 ] && log "模式: 先远程采集再收集（并发 $JOBS）" || log "模式: 只收集已有 JSON"
  exit 0
fi

mkdir -p "$OUTDIR" || die "建不了目录: $OUTDIR"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
FAILED=""

# ── 可选：先在每台上重新采集 ────────────────────────────────
if [ "$DO_PROBE" -eq 1 ] && [ -n "$HOSTS" ]; then
  log "▸ 远程采集（并发 $JOBS，每台约 1-2 分钟）"
  running=0
  for h in $HOSTS; do
    (
      # 优先用远程自己的 opsget，保证拿到的是云端最新版探针；
      # 没有 opsget 就把本机的 probe.sh 推过去跑，不强求对方装过东西
      if ssh $SSH_OPTS $(ssh_args "$h") 'command -v opsget >/dev/null 2>&1' 2>/dev/null; then
        ssh $SSH_OPTS $(ssh_args "$h") 'opsget vpsscore/probe' >/dev/null 2>&1
      elif [ -r /usr/local/bin/probe.sh ]; then
        ssh $SSH_OPTS $(ssh_args "$h") 'cat > /tmp/.probe.sh && bash /tmp/.probe.sh; rm -f /tmp/.probe.sh' \
          < /usr/local/bin/probe.sh >/dev/null 2>&1
      else
        exit 3
      fi
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
  done
  wait
  log "  采集完成（失败的机器会在下一步收集时暴露）"
fi

# ── 收集 ────────────────────────────────────────────────────
log "▸ 收集到 $OUTDIR"
GOT=0

# 本机：直接复制，不绕 ssh
if [ -d "$REMOTE_DIR" ]; then
  n=0
  for f in "$REMOTE_DIR"/*.json; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in latest.json) continue ;; esac
    cp -p "$f" "$OUTDIR/" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && { log "  本机: $n 份"; GOT=$((GOT + n)); }
fi

for h in $HOSTS; do
  t=$(target_of "$h"); pa=$(scp_args "$h")
  # shellcheck disable=SC2086
  if scp -q $SSH_OPTS $pa "$t:$REMOTE_DIR/*.json" "$OUTDIR/" 2>/dev/null; then
    log "  $h: ok"
    GOT=$((GOT + 1))
  else
    log "  $h: 取不到（未采集过？连不上？权限？）"
    FAILED="$FAILED $h"
  fi
done

rm -f "$OUTDIR/latest.json"

if [ "$GOT" -eq 0 ]; then
  log ""
  die "一份 JSON 都没收到。先在目标机上跑一次采集：opsget vpsscore/probe（或本脚本加 -p）"
fi

if [ -n "$FAILED" ]; then
  log ""
  log "⚠ 以下主机没取到数据:$FAILED"
  log "  排名里不会有它们 —— 别把「没数据」当成「分低」"
fi

# ── 打分 ────────────────────────────────────────────────────
SCORE=$(command -v score.sh || echo /usr/local/bin/score.sh)
if [ -x "$SCORE" ]; then
  "$SCORE" "$OUTDIR"
else
  log ""
  log "没找到 score.sh，JSON 已收在 $OUTDIR"
  log "装上再打分: opsget -i vpsscore/score && score.sh $OUTDIR"
fi
