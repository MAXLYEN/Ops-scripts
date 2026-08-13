#!/bin/bash
# init/02-system-network.sh — 系统与网络调优
# VERSION: 1.0.0
#
# UTC 时区、IPv4 优先解析、SUID 加固、磁盘 udev、BBR、内核参数、日志上限。
# 本目录的脚本刻意不依赖 lib/common.sh，理由见 00-precheck.sh 头部。

set -e
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
export DEBIAN_FRONTEND=noninteractive

# ── 服务端口段 ──
# 默认值适用于大多数机器；若本机已有 /etc/ops-scripts/env.conf，以它的
# SVC_TCP_RANGES 为准，这样端口规划只在一处维护。
SVC_RANGES="10000:11000 50000:60000"
[ -f /etc/ops-scripts/env.conf ] && . /etc/ops-scripts/env.conf 2>/dev/null || true
SVC_RANGES="${SVC_TCP_RANGES:-$SVC_RANGES}"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CORES=$(nproc)
echo "════════ 02 · 系统与网络调优 ════════"
echo "内存 ${MEM_MB}MB | CPU ${CORES} 核 | 服务端口段 $SVC_RANGES"

echo
echo "─ 1. 时区与时间同步 ─"
# 统一 UTC：多机日志时间戳可直接对比，cron 表达式跨机器语义一致。
# 注意数据库进程的 system_time_zone 是启动时读的，改完时区需重启数据库。
timedatectl set-timezone UTC 2>/dev/null || {
  rm -f /etc/localtime
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime
  echo UTC > /etc/timezone
}
if systemctl list-unit-files 2>/dev/null | grep -qE '^(chrony|chronyd|ntpsec)\.service'; then
  echo "  检测到 chrony/ntpsec，保持现有时间同步方案不动"
else
  systemctl list-unit-files 2>/dev/null | grep -q systemd-timesyncd || {
    apt-get -o DPkg::Lock::Timeout=300 update -qq
    apt-get -o DPkg::Lock::Timeout=300 install -y -qq systemd-timesyncd
  }
  mkdir -p /etc/systemd/timesyncd.conf.d
  cat > /etc/systemd/timesyncd.conf.d/99-ntp.conf << 'INNER'
[Time]
NTP=time.cloudflare.com time.google.com
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org
INNER
  timedatectl set-ntp true 2>/dev/null || true
  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
hwclock --systohc --utc 2>/dev/null || true
echo "  $(date -u '+%F %T UTC') | 已同步=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知)"

echo
echo "─ 2. IPv4 优先解析 ─"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  echo "  有全局 IPv6，本配置将实际生效"
else
  echo "  无全局 IPv6，写入但不产生实际影响"
fi
[ -f /etc/gai.conf ] && cp -a /etc/gai.conf "/etc/gai.conf.bak.$TS"
cat > /etc/gai.conf << 'INNER'
# IPv4-first —— 必须写完整表
# glibc 中只要存在任一 precedence，内置默认表即整体失效
label ::1/128 0
label ::/0 1
label 2002::/16 2
label ::/96 3
label ::ffff:0:0/96 4
precedence ::1/128 50
precedence ::/0 40
precedence 2002::/16 30
precedence ::/96 20
precedence ::ffff:0:0/96 100
INNER
for h in deb.debian.org github.com; do
  A=$(getent ahosts "$h" 2>/dev/null | head -1 | awk '{print $1}')
  case "$A" in
    "")      echo "  ⚠️  $h 解析失败" ;;
    *.*.*.*) echo "  ✅ $h → $A (IPv4)" ;;
    *)       echo "  ⚠️  $h → $A (IPv6 在前)" ;;
  esac
done

echo
echo "─ 3. SUID 加固 ─"
N=0
for f in /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp /usr/bin/gpasswd; do
  [ -e "$f" ] || continue
  if command -v dpkg-statoverride >/dev/null 2>&1; then
    dpkg-statoverride --list "$f" >/dev/null 2>&1 || {
      dpkg-statoverride --update --add root root 0755 "$f" 2>/dev/null && {
        echo "  已登记去除 SUID: $f"; N=$((N+1)); }
    }
  else
    [ -u "$f" ] && chmod u-s "$f" && { echo "  已去除 SUID: $f"; N=$((N+1)); }
  fi
done
[ "$N" -eq 0 ] && echo "  已全部处理过，无需变更"
echo "  （保留 mount/umount 的 SUID，摘除会破坏 fstab 的 user 选项）"

echo
echo "─ 4. 磁盘调度器与预读 ─"
cat > /etc/udev/rules.d/60-disk-tuning.rules << INNER
# disk tuning $TS
# 注意：udev 的 KERNEL 不支持 | 分隔多模式，必须逐类分开写
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="xvd[a-z]", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256"
INNER
udevadm control --reload-rules
udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
sleep 2
BAD=0
for d in /sys/block/*; do
  n=$(basename "$d")
  case $n in loop*|ram*|sr*|zram*|dm-*) continue ;; esac
  [ -e "$d/queue/scheduler" ] || continue
  RA=$(cat "$d/queue/read_ahead_kb")
  ROT=$([ "$(cat "$d/queue/rotational" 2>/dev/null)" = 1 ] && echo HDD || echo SSD)
  echo "  $n ($ROT): $(sed 's/.*\[\(.*\)\].*/\1/' "$d/queue/scheduler") | 预读 ${RA}KB"
  case "$RA" in 256|1024) ;; *) BAD=1 ;; esac
done
[ "$BAD" -eq 1 ] && echo "  ⚠️  预读未按预期变化，设备名可能不匹配任何规则"

echo
echo "─ 5. 网络与拥塞控制 ─"
modprobe tcp_bbr 2>/dev/null || true
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  CC=bbr
  mkdir -p /etc/modules-load.d
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  echo "  使用 BBR（已写 modules-load.d，重启自动加载）"
else
  CC=$(sysctl -n net.ipv4.tcp_congestion_control)
  echo "  ⚠️  内核不支持 BBR，保持 $CC"
fi
LO=32768; HI=49999
for r in $SVC_RANGES; do
  RS=${r%%:*}; RE=${r##*:}
  [ "$RS" -le "$HI" ] && [ "$RE" -ge "$LO" ] && \
    echo "  ⚠️  临时端口段 $LO-$HI 与服务端口 $r 重叠"
done
echo "  临时端口段 $LO-$HI（已避开 $SVC_RANGES）"
SOMAX=$((CORES*1024)); [ $SOMAX -lt 4096 ] && SOMAX=4096
BUF=33554432
cat > /etc/sysctl.d/99-zz-network.conf << INNER
# Network tuning - $TS
# zz 前缀确保排在 Debian 自带的 99-sysctl.conf 之后
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $CC
net.core.somaxconn = $SOMAX
net.core.netdev_max_backlog = $((CORES*2000))
# socket 缓冲上限固定 32MB，不随总内存线性放大
net.core.rmem_max = $BUF
net.core.wmem_max = $BUF
net.ipv4.tcp_rmem = 4096 131072 $BUF
net.ipv4.tcp_wmem = 4096 16384 $BUF
net.ipv4.tcp_max_syn_backlog = $((CORES*2048))
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
# 避开服务端口段: $SVC_RANGES
net.ipv4.ip_local_port_range = $LO $HI
# tcp_max_tw_buckets 保持内核默认，调小会导致 TIME_WAIT 溢出
INNER

echo
echo "─ 6. 内核参数 ─"
PIDMAX=$((CORES*16384))
[ $PIDMAX -lt 65536 ] && PIDMAX=65536
[ $PIDMAX -gt 4194304 ] && PIDMAX=4194304
SHMMAX=$((MEM_MB*1024*1024/2))
cat > /etc/sysctl.d/99-zz-kernel.conf << INNER
# Kernel tuning - $TS
kernel.pid_max = $PIDMAX
# 176 = sync + remount-ro + 进程管理，不含 reboot/crash
kernel.sysrq = 176
kernel.core_uses_pid = 1
kernel.shmmax = $SHMMAX
# shmall 单位是页(4KB)，必须与 shmmax 换算一致
kernel.shmall = $((SHMMAX/4096))
fs.file-max = $((MEM_MB*256))
fs.inotify.max_user_watches = 524288
INNER
sysctl --system >/dev/null
echo "  已应用"

echo
echo "─ 7. 日志上限 ─"
LOGMAX=$(((MEM_MB/1024+1)*50))
[ $LOGMAX -lt 100 ] && LOGMAX=100
[ $LOGMAX -gt 500 ] && LOGMAX=500
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-size.conf << INNER
[Journal]
SystemMaxUse=${LOGMAX}M
SystemMaxFileSize=$((LOGMAX/5))M
SystemKeepFree=200M
INNER
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=${LOGMAX}M >/dev/null 2>&1 || true
echo "  上限 ${LOGMAX}MB"

echo
echo "─ 8. fstab 校验（只读，本阶段不修改 fstab）─"
if findmnt --verify >/dev/null 2>&1; then
  echo "  ✅ 通过"
else
  echo "  ❌ 有问题:"
  findmnt --verify --verbose 2>&1 | sed -n '1,20p' | sed 's/^/    /'
fi

echo
echo "════════ 验证实际生效值 ════════"
MIS=""
for kv in "net.ipv4.tcp_congestion_control=$CC" "net.core.default_qdisc=fq" \
          "net.core.somaxconn=$SOMAX" "net.core.rmem_max=$BUF" \
          "kernel.sysrq=176" "kernel.pid_max=$PIDMAX"; do
  k=${kv%%=*}; w=${kv#*=}
  g=$(sysctl -n "$k" 2>/dev/null)
  printf '  %-32s = %s\n' "$k" "$g"
  [ "$g" = "$w" ] || MIS="$MIS $k"
done
PR=$(sysctl -n net.ipv4.ip_local_port_range | tr -s '[:space:]' ' ' | sed 's/ $//')
printf '  %-32s = %s\n' net.ipv4.ip_local_port_range "$PR"
[ "$PR" = "$LO $HI" ] || MIS="$MIS net.ipv4.ip_local_port_range"
echo
if [ -n "$MIS" ]; then
  echo "  ⚠️  以下参数未生效，覆盖来源:"
  for k in $MIS; do
    echo "    $k:"
    grep -rln "^[[:space:]]*$k" /etc/sysctl.conf /etc/sysctl.d/ \
      /run/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null | sed 's/^/      /'
  done
else
  echo "  ✅ 全部生效"
fi
echo
echo "⚠️  时区若刚从别的时区改成 UTC，记得重启数据库让 system_time_zone 跟上"
echo "✅ 阶段 02 完成"
