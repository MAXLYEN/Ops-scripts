#!/bin/bash
# init/04-verify.sh — 重启后持久性验证（只读）
# VERSION: 1.1.0
# 1.1.0: fstab 校验区分「真实挂载点问题」与「已知无害项」。
#        findmnt --verify 在 Debian 上恒定报三类误报：/media/cdrom* 是安装时
#        留下的模板条目（noauto，从不挂载），以及 swapfile 被当成「非 bind
#        挂载源是普通文件」。原来一律打 ❌，等于每台新机都有一个永远不会
#        消失的红叉 —— 那会训练人忽略告警，真出问题时也不会有人看。
#
# 只读，随时可跑。确认前面几个阶段的配置在重启后仍然生效。
# 本目录的脚本刻意不依赖 lib/common.sh，理由见 00-precheck.sh 头部。
#
# 注意本脚本只覆盖系统层。容器与数据库那一侧另跑 migrate/08-post-start-check。

echo "════════ 04 · 开机后持久性检查 ════════"
. /etc/os-release 2>/dev/null
echo "  ${PRETTY_NAME:-未知} | 内核 $(uname -r) | 已运行 $(uptime -p 2>/dev/null | sed 's/^up //')"

# fstab 校验分类：把「Debian 模板遗留的虚拟光驱」和「swapfile 语义」这两类
# 恒定误报单独归类，只有真实挂载点的问题才算失败。
# 不这么做的话，每台新机都会看到一个永远不会消失的红叉 —— 那会训练人忽略告警。
fstab_verify() {
  local raw
  raw=$(findmnt --verify --verbose 2>&1)
  printf '%s\n' "$raw" | awk '
    # 无缩进且非计数行 = 一个挂载目标的小节标题
    /^[^ \t]/ && !/parse error/ {
      target = $0
      next
    }
    /\[E\]|\[W\]/ {
      msg = $0
      sub(/^[ \t]+/, "", msg)
      harmless = 0
      # /media/cdrom* 是 Debian 安装留下的模板条目，noauto 从不挂载
      if (target ~ /^\/media\/cdrom/) harmless = 1
      # findmnt 不理解 swap 语义，总把 swapfile 报成「非 bind 挂载源是普通文件」
      if (msg ~ /non-bind mount source/ && msg ~ /swap|swapfile/) harmless = 1
      if (target == "none" && msg ~ /non-bind mount source/) harmless = 1
      if (harmless) { hn++; hlist = hlist "\n      " target ": " msg }
      else          { rn++; rlist = rlist "\n      " target ": " msg }
    }
    END {
      print "REAL=" rn
      print "HARM=" hn
      if (rn) printf "RLIST=%s\n", rlist
      if (hn) printf "HLIST=%s\n", hlist
    }'
}

fstab_report() {   # $1: 缩进前缀
  local pre="${1:-  }" out real harm
  out=$(fstab_verify)
  real=$(printf '%s\n' "$out" | sed -n 's/^REAL=//p')
  harm=$(printf '%s\n' "$out" | sed -n 's/^HARM=//p')
  if [ "${real:-0}" -eq 0 ]; then
    printf '%s✅ 真实挂载点校验通过\n' "$pre"
    [ "${harm:-0}" -gt 0 ] && \
      printf '%sℹ️  另有 %s 项已知无害（虚拟光驱模板 / swapfile 语义），不影响启动\n' "$pre" "$harm"
    return 0
  fi
  printf '%s❌ 真实挂载点有 %s 项问题:\n' "$pre" "$real"
  printf '%s\n' "$out" | sed -n '/^RLIST=/,$p' | sed '1s/^RLIST=//' | sed '/^HLIST=/,$d'
  [ "${harm:-0}" -gt 0 ] && \
    printf '%s（另有 %s 项已知无害，已忽略）\n' "$pre" "$harm"
  return 1
}
echo
echo "[Swap]"
swapon --show 2>/dev/null | sed 's/^/  /' || \
  echo "  ⚠️  无 swap（阶段01 曾创建则说明 fstab 条目失效）"

echo
echo "[内存参数]"
for k in vm.swappiness vm.vfs_cache_pressure vm.dirty_bytes vm.dirty_background_bytes; do
  printf '  %-30s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
done

echo
echo "[网络]"
printf '  %-30s = %s\n' \
  拥塞控制   "$(sysctl -n net.ipv4.tcp_congestion_control)" \
  队列算法   "$(sysctl -n net.core.default_qdisc)" \
  somaxconn  "$(sysctl -n net.core.somaxconn)" \
  临时端口段 "$(sysctl -n net.ipv4.ip_local_port_range | tr -s '[:space:]' ' ')" \
  pid_max    "$(sysctl -n kernel.pid_max)" \
  sysrq      "$(sysctl -n kernel.sysrq)"
if lsmod 2>/dev/null | grep -q tcp_bbr; then
  echo "  tcp_bbr 模块                   = 已加载（modules-load.d 生效）"
else
  echo "  tcp_bbr 模块                   = 未加载（若拥塞控制仍是 bbr 则已编译进内核）"
fi

echo
echo "[磁盘]"
for d in /sys/block/*; do
  n=$(basename "$d")
  case $n in loop*|ram*|sr*|zram*|dm-*) continue ;; esac
  [ -e "$d/queue/scheduler" ] || continue
  RA=$(cat "$d/queue/read_ahead_kb")
  case $RA in 256|1024) M="✅" ;; *) M="⚠️ udev 规则未生效" ;; esac
  echo "  $n: $(sed 's/.*\[\(.*\)\].*/\1/' "$d/queue/scheduler") | 预读 ${RA}KB $M"
done

echo
echo "[时间]"
echo "  $(date -u '+%F %T UTC') | 已同步=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知) | 时区=$(timedatectl show -p Timezone --value 2>/dev/null)"
if command -v mysql >/dev/null 2>&1 && [ -f /root/.my.cnf ]; then
  # 数据库的 system_time_zone 是启动时读的，改完时区不重启就对不上
  echo "  数据库 system_time_zone = $(mysql --defaults-file=/root/.my.cnf -N -B -e 'SELECT @@system_time_zone' 2>/dev/null || echo 取不到)"
fi

echo
echo "[服务]"
for s in ssh fail2ban systemd-timesyncd docker; do
  systemctl list-unit-files 2>/dev/null | grep -q "^$s.service" && \
    printf '  %-22s 运行=%-10s 自启=%s\n' "$s" \
      "$(systemctl is-active $s 2>/dev/null)" "$(systemctl is-enabled $s 2>/dev/null)"
done
printf '  %-22s 运行=%-10s 自启=%s\n' ufw \
  "$(ufw status 2>/dev/null | head -1 | awk '{print $2}')" \
  "$(systemctl is-enabled ufw 2>/dev/null)"

echo
echo "[SSH 生效配置]"
sshd -T 2>/dev/null | grep -iE '^(port|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|maxauthtries|clientaliveinterval)' | sed 's/^/  /'

echo
echo "[防火墙规则]"
ufw status verbose 2>/dev/null | sed 's/^/  /'

echo
echo "[fail2ban]"
fail2ban-client status sshd 2>/dev/null | grep -E 'Currently|Total|Journal' | sed 's/^/  /' || \
  echo "  未就绪"

echo
echo "[fstab]"
fstab_report "  " || true

echo
echo "[遗留定时器]"
systemctl list-timers --all 2>/dev/null | grep -qi rollback && \
  echo "  ⚠️  仍有回滚定时器！执行: systemctl stop server-rollback.timer" || \
  echo "  ✅ 无遗留"

echo
echo "[本次开机的错误日志]"
journalctl -p err -b --no-pager 2>/dev/null | tail -10 | sed 's/^/  /' || echo "  无"

echo
echo "✅ 阶段 04 完成"
echo "   容器与数据库侧的验收另跑: opsget migrate/08-post-start-check"
