#!/usr/bin/env bash
# vpsscore/collect.sh — 把多台机器的 probe JSON 收到一处并打分
# VERSION: 1.2.2
# 1.2.2: -p 时本机也重新采集。原来本机只从 /var/lib/vpsscore 复制已有 JSON，
#        远程却是重采 —— 两条路径不对称，导致本机数据永远停在上一次手动
#        跑探针的时刻，而它照样参与排名。实测本机因此长期用着几个版本前的
#        旧数据，榜单上完全看不出来（又一个「结果不对但表面正常」）。
#        现在本机与远程走同一套参数，采集完再复制。
# 1.2.1: ① 采集前后都对账探针版本。两条采集路径拿到的可能不是同一个版本 ——
#           装了 opsget 的机器从云端拉，没装的用本机 /usr/local/bin/probe.sh 推送。
#           实测出现过本机 1.1.2、云端 1.1.3，21 台跑的是旧版而输出完全看不出来，
#           白跑一轮才发现。现在开跑前比对，跑完统计版本分布，不一致就告警。
#        ② 实时进度：每台完成打印一行带耗时，不再是十几分钟静默。
#        ③ --ipq 不再压低并发。原来降到 4 的理由是「汇总机出口会成为瓶颈」，
#           但 IPQ 的耗时全在各机器自己等第三方 API，请求不经过汇总机 ——
#           那是没有依据的猜测。默认改 8，-j 可继续调高。
# 1.2.0: 新增 --ipq，透传给远程探针做深度 IP 质量检测。
#        它每台要跑 1-2 分钟（查十几个第三方库），所以启用时默认并发降到 4；
#        显式给了 -j 则以你给的为准。
# 1.1.0: 远程采集不再吞掉错误。原来整段 >/dev/null 2>&1，失败只能在下一步
#        以「取不到」的形式间接暴露，而真正的原因（没装 opsget、不是 root、
#        磁盘满、探针报错）一个都看不见 —— 手工跑同一条命令却是成功的，
#        这种「脚本里失败、手工能成」最耗排查时间。现在按台保留输出，
#        失败时打印最后几行，并在采集阶段就统计成败。
#        另修两处：① 探测 opsget 的 ssh 补 </dev/null，它会抢走 stdin，
#        把后面要喂给 probe.sh 的内容吃掉；② 非 root 用户自动尝试 sudo -n，
#        探针要写 /var/lib/vpsscore、读 /proc/stat，普通用户跑不了。
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
#   collect.sh -p --ipq           采集时额外做深度 IP 质量检测（每台 +1~2 分钟）
#   collect.sh -n                 只列出将要连接的主机，不动手（先看再跑）
#   collect.sh -o <目录>          指定汇总目录，默认 ~/vpsscore-baseline
#   collect.sh -j 4               并发数，默认 4（仅 -p 时有意义）
#   collect.sh -h
#
# 本机的 JSON 会自动带上，不用把自己也写进清单。

set -o pipefail

OUTDIR="${HOME}/vpsscore-baseline"
DO_PROBE=0; DRY=0; JOBS=4; JOBS_SET=0; DO_IPQ=0; LIST=""
PROBE_ARGS=""
REMOTE_DIR=/var/lib/vpsscore

usage() {
  cat <<'USAGE'
collect.sh — 汇总多台机器的 VPS 质量采集结果并打分

  collect.sh                  自动发现主机，收集已有 JSON 并打分
  collect.sh <清单文件>       用指定清单
  collect.sh -p               先在每台上重新采集（耗时约 1-2 分钟/台）
  collect.sh -p --ipq         额外做深度 IP 质量检测（每台再加 1-2 分钟）
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
    --ipq)      DO_IPQ=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -o|--out)   [ -n "${2:-}" ] || die "-o 需要一个目录"; OUTDIR="$2"; shift 2 ;;
    -j|--jobs)  [ -n "${2:-}" ] || die "-j 需要一个数字"; JOBS="$2"; JOBS_SET=1; shift 2 ;;
    --) shift; break ;;
    -*) log "未知参数: $1"; usage; exit 1 ;;
    *)  LIST="$1"; shift ;;
  esac
done

command -v ssh >/dev/null 2>&1 || die "缺少 ssh"

if [ "$DO_IPQ" -eq 1 ]; then
  PROBE_ARGS="--ipq"
  # IPQ 的耗时全在各机器自己等第三方 API，请求不经过汇总机，
  # 所以并发数不影响对端看到的负载分布，只影响总时长。
  # 默认 8 而非更高，纯粹是为了控制故障爆炸半径 —— 出问题时
  # 你有时间 Ctrl-C，而不是一次性全打出去。
  [ "$JOBS_SET" -eq 1 ] || JOBS=8
fi

# 探针版本对账：本机副本用于推送给没装 opsget 的机器，云端版本给装了的。
# 两者不一致时，同一轮采集会混用两个版本，而结果里完全看不出来。
probe_ver_of() { grep -m1 -oE '^# VERSION: *[0-9.]+' "$1" 2>/dev/null | grep -oE '[0-9.]+$'; }
check_probe_version() {
  local local_v cloud_v tmp
  [ -r /usr/local/bin/probe.sh ] || return 0
  local_v=$(probe_ver_of /usr/local/bin/probe.sh)
  tmp=$(mktemp)
  if curl -fsSL --max-time 20 \
       "https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/vpsscore/probe.sh?_=$(date +%s)" \
       -o "$tmp" 2>/dev/null; then
    cloud_v=$(probe_ver_of "$tmp")
  fi
  rm -f "$tmp"
  [ -n "$local_v" ] && [ -n "$cloud_v" ] || return 0
  if [ "$local_v" != "$cloud_v" ]; then
    log "⚠ 探针版本不一致：本机 $local_v，云端 $cloud_v"
    log "  装了 opsget 的机器会拉云端版，没装的会用本机版 —— 同一轮会混用两个版本"
    log "  先执行: opsget -i vpsscore/probe"
    return 1
  fi
  return 0
}
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
  if [ "$DO_PROBE" -eq 1 ]; then
    log "模式: 先远程采集再收集（并发 $JOBS）${PROBE_ARGS:+ 探针参数: $PROBE_ARGS}"
  else
    log "模式: 只收集已有 JSON"
  fi
  exit 0
fi

mkdir -p "$OUTDIR" || die "建不了目录: $OUTDIR"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
FAILED=""

# ── 可选：先在每台上重新采集 ────────────────────────────────
if [ "$DO_PROBE" -eq 1 ] && [ -n "$HOSTS" ]; then
  check_probe_version || log ""
  NHOSTS=$(printf '%s\n' $HOSTS | wc -l)
  if [ "$DO_IPQ" -eq 1 ]; then
    PER=180
    log "▸ 远程采集 + 深度 IP 质量（$NHOSTS 台，并发 $JOBS）"
  else
    PER=90
    log "▸ 远程采集（$NHOSTS 台，并发 $JOBS）"
  fi
  # 粗估：批数 × 每台耗时。给个数量级，免得十几分钟静默让人以为卡死
  EST=$(( (NHOSTS + JOBS - 1) / JOBS * PER ))
  log "  预计约 $((EST / 60)) 分钟（$(( (NHOSTS + JOBS - 1) / JOBS )) 批 × 每台约 $((PER / 60)) 分钟）"
  T0=$(date +%s)
  PLOG=$(mktemp -d) || die "mktemp 失败"
  running=0
  # 本机也要重新采集 —— 只复制旧文件的话，本机数据会永远停在上次手动跑
  # 探针的时刻，而它在榜单里照样参与排名（表面完全正常，看不出是旧数据）。
  # 放后台与远程并行：本机采集不占用 ssh 并发额度，串行跑纯属浪费时间。
  LOCAL_PID=""
  if [ -x /usr/local/bin/probe.sh ] && [ "$(id -u)" -eq 0 ]; then
    ( /usr/local/bin/probe.sh $PROBE_ARGS >"$PLOG/.local" 2>&1
      printf '%s\n' "$?" > "$PLOG/.local.rc" ) &
    LOCAL_PID=$!
  elif [ -x /usr/local/bin/probe.sh ]; then
    log "  [提示] 非 root，跳过本机采集（探针需要 root）"
  fi

  # 进度上报要先起：采集循环自己是阻塞的，放在循环之后就永远等不到实时输出
  : > "$PLOG/.done"
  (
    shown=0
    while [ "$shown" -lt "$NHOSTS" ]; do
      sleep 3
      cur=$(wc -l < "$PLOG/.done" 2>/dev/null || echo 0)
      while [ "$shown" -lt "$cur" ]; do
        shown=$((shown + 1))
        line=$(sed -n "${shown}p" "$PLOG/.done" 2>/dev/null)
        printf '  [%2d/%d] %-34s %ss\n' "$shown" "$NHOSTS" "${line% *}" "${line##* }" >&2
      done
    done
  ) &
  PROG_PID=$!

  PIDS=""
  running=0
  for h in $HOSTS; do
    (
      out="$PLOG/$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_')"
      t_start=$(date +%s)
      # 完成信号写文件而不是靠变量：子 shell 里的赋值传不回父进程
      trap 'printf "%s %s\n" "$h" "$(( $(date +%s) - t_start ))" >> "$PLOG/.done"' EXIT
      # 探针要写 /var/lib/vpsscore、读 /proc/stat，普通用户跑不了。
      # 有免密 sudo 就用，没有就如实报错，不要静默产出半份数据。
      pfx=''
      if ! ssh $SSH_OPTS $(ssh_args "$h") '[ "$(id -u)" -eq 0 ]' </dev/null 2>/dev/null; then
        if ssh $SSH_OPTS $(ssh_args "$h") 'sudo -n true' </dev/null 2>/dev/null; then
          pfx='sudo -n '
        else
          echo "不是 root 且无免密 sudo —— 探针需要 root 权限" > "$out"
          exit 1
        fi
      fi
      # 注意 </dev/null：不加的话这条会抢走 stdin，
      # 把下面本该喂给 probe.sh 的脚本内容吃掉
      if ssh $SSH_OPTS $(ssh_args "$h") 'command -v opsget >/dev/null 2>&1' </dev/null 2>/dev/null; then
        ssh $SSH_OPTS $(ssh_args "$h") "${pfx}opsget vpsscore/probe $PROBE_ARGS" </dev/null > "$out" 2>&1
      elif [ -r /usr/local/bin/probe.sh ]; then
        ssh $SSH_OPTS $(ssh_args "$h") "cat > /tmp/.probe.sh && ${pfx}bash /tmp/.probe.sh $PROBE_ARGS; rc=\$?; rm -f /tmp/.probe.sh; exit \$rc" \
          < /usr/local/bin/probe.sh > "$out" 2>&1
      else
        echo "对方没有 opsget，本机也没有 /usr/local/bin/probe.sh 可推送" > "$out"
        exit 1
      fi
    ) &
    PIDS="$PIDS $!"
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
      wait -n 2>/dev/null && running=$((running - 1)) || { wait $PIDS 2>/dev/null; running=0; }
    fi
  done
  # 只等采集任务，不要用无参 wait —— 那会连进度上报器一起等，永远不返回
  wait $PIDS 2>/dev/null
  sleep 4                      # 让上报器把最后几行打完
  kill "$PROG_PID" 2>/dev/null
  wait "$PROG_PID" 2>/dev/null

  if [ -n "$LOCAL_PID" ]; then
    wait "$LOCAL_PID" 2>/dev/null
    if [ "$(cat "$PLOG/.local.rc" 2>/dev/null || echo 1)" = "0" ]; then
      log "  本机: 采集完成"
    else
      log "  本机: 采集失败 —— 单独运行 probe.sh $PROBE_ARGS 看原因"
      tail -3 "$PLOG/.local" 2>/dev/null | sed 's/^/      /' >&2
    fi
  fi

  ELAPSED=$(( $(date +%s) - T0 ))
  log "  采集耗时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"

  pok=0; pbad=""
  for h in $HOSTS; do
    out="$PLOG/$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_')"
    if [ -f "$out" ] && grep -q '════ 完成 ════' "$out" 2>/dev/null; then
      pok=$((pok + 1))
    else
      pbad="$pbad $h"
      log "  [采集失败] $h"
      if [ -s "$out" ]; then
        sed -e 's/^/      /' "$out" | tail -6 >&2
      else
        log "      （没有任何输出，多半是连接就断了）"
      fi
    fi
  done
  log "  采集成功 $pok 台"
  if [ "$DO_IPQ" -eq 1 ]; then
    iok=0; ibad=""
    for h in $HOSTS; do
      out="$PLOG/$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_')"
      [ -f "$out" ] || continue
      # 探针在 IPQ 成功时会打印「风险 max」，失败/降级时不会
      if grep -q '风险 max' "$out" 2>/dev/null; then
        iok=$((iok + 1))
      elif grep -q 'IP 质量深度' "$out" 2>/dev/null; then
        ibad="$ibad $h"
      fi
    done
    log "  IP 质量成功 $iok 台"
    [ -n "$ibad" ] && {
      log "  IP 质量未取到:$ibad"
      for h in $ibad; do
        out="$PLOG/$(printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_')"
        grep -A2 'IP 质量深度' "$out" 2>/dev/null \
          | grep -vE 'IP 质量深度|════' | head -1 | sed "s|^ *|      $h: |" >&2
      done
    }
  fi
  [ -n "$pbad" ] && log "  采集失败:$pbad"
  rm -rf "$PLOG"
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
# 版本分布从收到的 JSON 读（probe_ver 只在 JSON 里，终端输出没有）。
# 两条采集路径可能拿到不同版本，混用时结果不可比而表面完全正常
if command -v python3 >/dev/null 2>&1; then
  python3 - "$OUTDIR" <<'PYVER' >&2
import json, glob, os, sys, collections
best = {}
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    if os.path.basename(f) == "latest.json":
        continue
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    ip = d.get("ipv4") or d.get("host") or f
    if ip not in best or (d.get("probed_at") or "") > (best[ip].get("probed_at") or ""):
        best[ip] = d
c = collections.Counter(d.get("probe_ver") or "未知" for d in best.values())
if len(c) > 1:
    print("")
    print("  ⚠ 探针版本不一致：" + "，".join(f"{v} × {n}" for v, n in c.most_common()))
    print("    装了 opsget 的机器拉云端版，没装的用本机 /usr/local/bin/probe.sh")
    print("    先执行 opsget -i vpsscore/probe，再重采")
PYVER
fi

SCORE=$(command -v score.sh || echo /usr/local/bin/score.sh)
if [ -x "$SCORE" ]; then
  "$SCORE" "$OUTDIR"
else
  log ""
  log "没找到 score.sh，JSON 已收在 $OUTDIR"
  log "装上再打分: opsget -i vpsscore/score && score.sh $OUTDIR"
fi
