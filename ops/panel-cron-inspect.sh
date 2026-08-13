#!/usr/bin/env bash
# ops/panel-cron-inspect.sh — 查明面板计划任务的真实身份
# VERSION: 2.0.1
# 2.0.1: 修正"没有日志文件"的措辞 —— 手动触发不会产生日志，日志重定向写在 crontab 行里
#
# 面板的计划任务在 crontab 里是一串 hash，看不出干什么。而且迁移后
# hash 会被重新生成，不能靠 hash 匹配新旧机。必须打开脚本看内容。
#
# 典型误判：以为两个任务都是数据库备份，实际一个是证书续期。
#
# 用法: panel-cron-inspect.sh [--run <hash>]   带 --run 则手动触发一次

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env PANEL_CRON_DIR

if [ "${1:-}" = "--run" ]; then
  H=${2:?用法: $0 --run <hash>}
  F="$PANEL_CRON_DIR/$H"
  [ -f "$F" ] || die "任务不存在: $F"
  log "手动触发 $H"
  bash "$F" start 2>&1 | tail -30 | sed 's/^/  /'
  exit 0
fi

section "crontab 里的面板任务"
crontab -l 2>/dev/null | grep -F "$PANEL_CRON_DIR/" | sed 's/^/  /'

section "各任务在做什么"
crontab -l 2>/dev/null | grep -oE "${PANEL_CRON_DIR}/[a-f0-9]{32}" | sort -u | while read -r f; do
  h=$(basename "$f")
  sched=$(crontab -l 2>/dev/null | grep -m1 -F "$h" | awk '{print $1,$2,$3,$4,$5}')
  echo "  ── $h   计划: $sched"
  if [ -f "$f" ]; then
    # 猜一下身份，再把真正干活的那几行打出来
    kind="未知"
    grep -qi 'acme'                "$f" && kind="SSL 证书续期"
    grep -qi 'backup.*database'    "$f" && kind="数据库备份"
    grep -qi 'backup.*site'        "$f" && kind="站点备份"
    grep -qi 'logs\?_clean\|清理'  "$f" && kind="日志清理"
    echo "     身份推断: $kind"
    grep -vE '^\s*#|^\s*$|^echo|^endDate|^rm -f|^PATH=|^export ' "$f" \
      | head -6 | sed 's/^/     /'
    if [ -f "$f.log" ]; then
      echo "     最近日志尾部:"
      tail -4 "$f.log" 2>/dev/null | sed 's/^/       /'
    else
      echo "     [注意] 没有日志文件 —— 可能一次都没被 cron 调度过。"
      echo "            （手动触发不会产生日志：重定向写在 crontab 行里，不在脚本里）"
    fi
  else
    warn "脚本文件不存在: $f"
  fi
  echo
done

section "输出目录现状"
if [ -n "${PANEL_DB_BACKUP_DIR:-}" ]; then
  if [ -d "$PANEL_DB_BACKUP_DIR" ]; then
    for d in "$PANEL_DB_BACKUP_DIR"/*/; do
      [ -d "$d" ] || { echo "  (目录下没有任何子目录 —— 备份任务还没跑过)"; break; }
      printf '  %-18s %s 个文件  最新: %s\n' "$(basename "$d")" \
        "$(ls -1 "$d" 2>/dev/null | wc -l)" "$(ls -t "$d" 2>/dev/null | head -1)"
    done
  else
    warn "$PANEL_DB_BACKUP_DIR 不存在"
  fi
fi

section 提示
cat <<EOF
  手动触发某个任务：
    $(basename "$0") --run <hash>

  迁移后的常见情况：任务迁过来了但一次没跑过，于是依赖它产物的备份脚本
  会告警"找不到某个 dump"。手动触发一次即可。

  另外：面板的自定义备份目录设置通常会随迁移一起过来，路径一般不用改 ——
  先跑一次看文件落在哪，再决定改配置还是改脚本。
EOF
finish
