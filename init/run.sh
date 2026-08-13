#!/bin/bash
# init/run.sh — 初始化阶段调度器
# VERSION: 2.0.0
# 2.0.0: 改为配合 opsget 使用 —— 阶段脚本从云端拉取，不再依赖 /root/s0*.sh
#
#   opsget init/run              列出阶段与当前状态
#   opsget init/run 03           执行指定阶段（会自动拉取该阶段的最新版）

STAGES="00:precheck:环境探测与更新:检查系统/硬件/网络形态/能力/软件源，打补丁，判断是否需重启
01:swap-memory:Swap 与内存参数:按内存分档创建 swapfile，配置 swappiness / 脏页写回
02:system-network:系统与网络调优:UTC 时区、IPv4 优先、SUID、磁盘 udev、BBR、内核参数、日志上限
03:ssh-firewall:SSH 与防火墙:SSH 加固、ufw、fail2ban（含 5 分钟自动回滚）
04:verify:重启后持久性验证:确认所有配置开机后仍生效"

script_for() {  # $1=阶段号 → 仓库内路径
  printf '%s\n' "$STAGES" | while IFS=: read -r n s _ _; do
    [ "$n" = "$1" ] && printf 'init/%s-%s\n' "$n" "$s"
  done
}

if [ -z "${1:-}" ]; then
  echo "════════ 服务器初始化阶段调度器 ════════"
  echo
  echo "用法: opsget init/run <00|01|02|03|04>"
  echo
  printf '%s\n' "$STAGES" | while IFS=: read -r n s t d; do
    printf '  %-4s %-22s %s\n' "$n" "$t" "$d"
  done
  echo
  echo "推荐顺序: 00 →(需要则重启)→ 01 → 02 → 03 →(重启)→ 04"
  echo
  echo "已安装的阶段脚本:"
  N=0
  printf '%s\n' "$STAGES" | while IFS=: read -r n s _ _; do
    f="/usr/local/bin/${n}-${s}.sh"
    if [ -e "$f" ]; then
      printf '  %-24s %s  %s\n' "$(basename "$f")" \
        "$(date -r "$f" '+%m-%d %H:%M')" \
        "$(grep -m1 -oE '^# VERSION: [0-9.]+' "$f" | sed 's/^# //')"
    fi
  done
  [ -z "$(ls /usr/local/bin/0*-*.sh 2>/dev/null)" ] && \
    echo "  （还没装，执行任一阶段时会自动拉取）"
  echo
  echo "当前状态:"
  printf '  %-16s %s\n' \
    主机 "$(hostname)" \
    系统 "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}")" \
    已运行 "$(uptime -p 2>/dev/null | sed 's/^up //')" \
    时区 "$(timedatectl show -p Timezone --value 2>/dev/null)" \
    Swap "$(free -m | awk '/^Swap:/{print ($2==0)?"未配置":$2"MB"}')" \
    拥塞控制 "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
    ufw "$(ufw status 2>/dev/null | head -1 | awk '{print $2}' || echo 未安装)" \
    fail2ban "$(systemctl is-active fail2ban 2>/dev/null || echo 未安装)"
  systemctl list-timers --all 2>/dev/null | grep -qi rollback && \
    echo "  ⚠️  存在遗留回滚定时器: systemctl stop server-rollback.timer"
  [ -f /var/run/reboot-required ] && echo "  ⚠️  系统标记需要重启"
  [ -f /etc/ops-scripts/env.conf ] && echo "  ℹ️  已有 env.conf，02/03 的端口段会以它为准"
  exit 0
fi

STAGE=$(printf '%02d' "$((10#${1#0}))" 2>/dev/null || echo "$1")
P=$(script_for "$STAGE")
[ -n "$P" ] || { echo "❌ 未知阶段: $1"; exit 1; }

if [ "$STAGE" = 03 ]; then
  echo "⚠️  阶段 03 会修改 SSH 配置并启用防火墙。"
  echo "   请先连好【第二个 SSH 窗口】用于连通性验证——现在就连，不要等跑完。"
  echo "   另外确认带外控制台（VNC/管理终端）能进：脚本有 5 分钟自动回滚兜底，"
  echo "   但那是最后一道保险，不是第一道。"
  echo
  printf "   已准备好？(yes/no) "
  read -r A </dev/tty
  [ "$A" = yes ] || { echo "   已取消"; exit 0; }
  echo
fi

if command -v opsget >/dev/null 2>&1; then
  exec opsget "$P"
else
  echo "❌ 找不到 opsget。先装引导器:"
  echo "   curl -fsSL https://raw.githubusercontent.com/MAXLYEN/ops-scripts/main/bin/opsget \\"
  echo "     -o /usr/local/bin/opsget && chmod +x /usr/local/bin/opsget"
  exit 1
fi
