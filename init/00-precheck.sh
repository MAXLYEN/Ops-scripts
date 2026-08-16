#!/bin/bash
# init/00-precheck.sh — 环境探测与更新
# VERSION: 1.0.1
# 1.0.1 修正：网络形态判断在 dual-stack 机器上误报 NAT ——
#            `curl ifconfig.me` 优先走 IPv6 返回 v6 地址，却拿去和 IPv4 网卡列表比对，
#            必然不匹配。现在分别探测两个协议族，各自和对应的地址列表比。
#
# 新机初始化的第一步。只探测和更新，不改任何配置。
#
# 本目录的脚本**刻意不依赖 lib/common.sh** —— 它们要能在一台什么都没有的
# 新机上单跑（甚至直接 curl 下来执行），少一个依赖就少一个失败点。

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root，请先执行 sudo -i"; exit 1; }
. /etc/os-release 2>/dev/null

echo "════════ 00 · 环境探测与更新 ════════"
echo
echo "[系统]"
printf '  %-14s %s\n' \
  发行版 "${PRETTY_NAME:-未知}" \
  代号   "${VERSION_CODENAME:-未知}" \
  内核   "$(uname -r)" \
  架构   "$(dpkg --print-architecture 2>/dev/null || uname -m)" \
  虚拟化 "$(systemd-detect-virt 2>/dev/null || echo 未知)" \
  已运行 "$(uptime -p 2>/dev/null | sed 's/^up //')"
[ "${ID:-}" = debian ] || echo "  ⚠️  非 Debian（$ID），后续阶段可能不适用"
case "${VERSION_CODENAME:-}" in
  buster|bullseye) echo "  ⚠️  支持周期即将/已结束，建议重装为当前稳定版" ;;
  bookworm)        echo "  ℹ️  已进入 LTS-only 阶段" ;;
  trixie|forky)    echo "  ✅ 受支持的较新版本" ;;
esac

echo
echo "[硬件]"
RFS=$(findmnt -no FSTYPE / 2>/dev/null || stat -f -c %T /)
printf '  %-14s %s\n' \
  内存       "$(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)" \
  CPU        "$(nproc) 核" \
  根文件系统 "$RFS" \
  根分区     "$(findmnt -no SIZE,AVAIL / | awk '{print "总"$1" 可用"$2}')" \
  现有Swap   "$(free -m | awk '/^Swap:/{print $2"MB"}')"
case "$RFS" in
  xfs)       echo "  ℹ️  XFS：阶段01 的 swapfile 会走 dd 路径（较慢，正常）" ;;
  btrfs|zfs) echo "  ⚠️  $RFS：阶段01 将跳过 swap 创建" ;;
esac
printf '  %-14s ' 块设备
for d in /sys/block/*; do
  n=$(basename "$d")
  case $n in loop*|ram*|sr*|zram*) continue ;; esac
  [ -e "$d/size" ] || continue
  printf '%s(%dG,%s) ' "$n" "$(( $(cat "$d/size") / 2097152 ))" \
    "$([ "$(cat "$d/queue/rotational" 2>/dev/null)" = 1 ] && echo HDD || echo SSD)"
done
echo

echo
echo "[网络形态]"
# 公网 IP 不在网卡上 = 机器在 NAT 后面。这会影响两件事：
#   1. 入站可达性必须单独验证（出网通不代表能连进来）
#   2. 容器内不能用宿主机公网 IP 访问宿主机服务 —— 包会发到网关再也回不来
#
# ⚠️ 必须分协议族探测。dual-stack 机器上 curl 默认可能走 IPv6，
#    拿回来的 v6 地址去和 IPv4 网卡列表比对必然不匹配，会误报成 NAT。
PUB4=$(curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null)
PUB6=$(curl -s -6 --max-time 10 https://ifconfig.me 2>/dev/null)
printf '  %-16s %s\n' 网卡IPv4 "$(ip -4 -br addr | grep -v '^lo' | awk '{print $1"="$3}' | tr '\n' ' ')"
printf '  %-16s %s\n' 网卡IPv6 "$(ip -6 -br addr | grep -v '^lo' | awk '{print $1"="$3}' | tr '\n' ' ')"
printf '  %-16s %s\n' 公网出口IPv4 "${PUB4:-取不到}"
printf '  %-16s %s\n' 公网出口IPv6 "${PUB6:-无}"
if [ -z "$PUB4" ]; then
  echo "  ⚠️  取不到 IPv4 出口地址（纯 IPv6 环境，或探测服务不可达）"
elif ip -4 -br addr | grep -qF "$PUB4"; then
  echo "  ✅ 公网 IPv4 直绑在网卡上"
  echo "     注意：容器里仍然不要写宿主机公网 IP —— 这台能用，"
  echo "     搬到 NAT 后面的机器就会突然不通。一律用网桥网关地址。"
else
  echo "  ⚠️  公网 IPv4 不在网卡上，机器在 NAT 后面"
  echo "      入站可达性请用 migrate/02-nat-probe 单独验证"
  echo "      且容器内不能用公网 IP 访问宿主机服务"
fi
if [ -n "$PUB6" ]; then
  ip -6 route show default | grep -q . \
    && echo "  ℹ️  有可用的全局 IPv6 —— 阶段 02 的 IPv4-first 是取舍而非修复，见该阶段说明" \
    || echo "  ⚠️  能取到 IPv6 出口但没有默认路由，解析到 AAAA 时会立刻 ENETUNREACH"
fi

echo
echo "[能力探测]"
if sshd -T >/dev/null 2>&1; then
  if sshd -T -o 'KbdInteractiveAuthentication=no' >/dev/null 2>&1; then
    echo "  认证选项名     KbdInteractiveAuthentication（新名）"
  else
    echo "  认证选项名     ChallengeResponseAuthentication（旧名，OpenSSH<8.7）"
  fi
  SP=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | tr '\n' ' ')
else
  echo "  ⚠️  sshd -T 执行失败，无法探测认证选项与端口"
  SP=未知
fi
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
  echo "  sshd drop-in   支持（阶段03 用 00- 前缀抢读取优先级）"
else
  echo "  sshd drop-in   不支持，阶段03 将直接改 sshd_config"
fi
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  BBRS="内核已支持"
elif modprobe tcp_bbr 2>/dev/null && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  BBRS="需加载模块（可用）"
else
  BBRS="不可用"
fi
if systemctl list-unit-files 2>/dev/null | grep -qE '^(chrony|ntpsec)'; then
  TSYNC=chrony/ntpsec
elif systemctl list-unit-files 2>/dev/null | grep -q systemd-timesyncd; then
  TSYNC=systemd-timesyncd
else
  TSYNC=无
fi
printf '  %-14s %s\n' \
  SSH单元  "$(systemctl list-unit-files --no-legend 'ssh.service' 'sshd.service' 2>/dev/null | awk 'NR==1{print $1}')" \
  SSH端口  "$SP" \
  fail2ban "$(dpkg-query -W -f='${Version}' fail2ban 2>/dev/null || echo 未安装)" \
  ufw      "$(dpkg-query -W -f='${Version}' ufw 2>/dev/null || echo 未安装)" \
  BBR      "$BBRS" \
  全局IPv6 "$(ip -6 addr show scope global 2>/dev/null | grep -q inet6 && echo 有 || echo 无)" \
  时间同步 "$TSYNC"

echo
echo "[配置冲突预检]"
FOUND=0
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -e "$f" ] || continue
  FOUND=1
  C=$(grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | head -1)
  echo "  $(basename "$f")  (${C:-0} 条有效指令)"
  grep -iE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|KbdInteractive|ChallengeResponse|Port)' \
    "$f" 2>/dev/null | sed 's/^/      ↳ /'
done
[ "$FOUND" -eq 0 ] && echo "  sshd drop-in 目录: 无文件"
SC=$(grep -cvE '^[[:space:]]*(#|$)' /etc/sysctl.conf 2>/dev/null | head -1); SC=${SC:-0}
if [ "$SC" -gt 0 ]; then
  echo "  ⚠️  /etc/sysctl.conf 有 $SC 条配置（zz 前缀排在其后，会正确覆盖）:"
  grep -vE '^[[:space:]]*(#|$)' /etc/sysctl.conf | sed 's/^/      ↳ /'
else
  echo "  /etc/sysctl.conf: 无有效配置，无冲突"
fi
ls -1 /etc/sysctl.d/99-zz-*.conf /etc/udev/rules.d/60-disk*.rules \
      /etc/fail2ban/jail.d/*.conf 2>/dev/null | sed 's/^/  已有: /'
systemctl list-timers --all 2>/dev/null | grep -qi rollback && \
  echo "  ⚠️  存在遗留回滚定时器: systemctl stop server-rollback.timer"

echo
echo "[软件源]"
ERR=$(apt-get -o DPkg::Lock::Timeout=300 update -qq 2>&1 >/dev/null)
OK=1
if [ -n "$ERR" ]; then
  OK=0
  echo "  ⚠️  报错:"
  printf '%s\n' "$ERR" | head -8 | sed 's/^/    /'
  echo
  FIX=""
  printf '%s' "$ERR" | grep -q "${VERSION_CODENAME}/updates" && \
    FIX="sed -i -E 's|security\.debian\.org[^ ]* +${VERSION_CODENAME}/updates|security.debian.org/debian-security ${VERSION_CODENAME}-security|g' /etc/apt/sources.list; "
  printf '%s' "$ERR" | grep -qi backports && \
    FIX="${FIX}sed -i -E '/backports/ s|^[[:space:]]*deb|#deb|' /etc/apt/sources.list; "
  printf '%s' "$ERR" | grep -qiE 'lock|denied' && \
    echo "  提示: 锁冲突可等 apt-daily 跑完；若 root 能手动写入却报 denied，多为命令传输截断"
  if [ -n "$FIX" ]; then
    echo "  建议: cp -a /etc/apt/sources.list /etc/apt/sources.list.bak.\$(date +%s); $FIX apt-get update"
    printf "  现在执行？(yes/no) "
    read -r A </dev/tty
    if [ "$A" = yes ]; then
      cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
      eval "$FIX"
      E2=$(apt-get update -qq 2>&1 >/dev/null)
      if [ -n "$E2" ]; then
        printf '%s\n' "$E2" | head -6 | sed 's/^/    /'
      else
        echo "  ✅ 修复成功"; OK=1
      fi
    fi
  else
    echo "  未匹配到已知的源路径问题"
  fi
else
  echo "  ✅ 正常"
fi

echo
if [ "$OK" -eq 1 ]; then
  echo "[系统更新]"
  apt-get -o DPkg::Lock::Timeout=300 -y -o Dpkg::Options::="--force-confold" upgrade
  apt-get -y autoremove --purge >/dev/null
  echo
else
  echo "[系统更新] 已跳过（软件源未修复）"
  echo
fi

echo "════════ 重启判断 ════════"
NEED=0; RSN=""
[ -f /var/run/reboot-required ] && { NEED=1; RSN="$RSN 系统标记"; }
RUN_K=$(uname -r)
NEW_K=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
[ -n "$NEW_K" ] && [ "$NEW_K" != "$RUN_K" ] && \
  { NEED=1; RSN="$RSN 已装更新内核($NEW_K，运行中 $RUN_K)"; }
command -v needrestart >/dev/null 2>&1 && \
  needrestart -b 2>/dev/null | grep -q 'NEEDRESTART-KSTA: [23]' && \
  { NEED=1; RSN="$RSN needrestart 报告内核过时"; }

if [ "$NEED" -eq 1 ]; then
  [ -f /var/run/reboot-required.pkgs ] && {
    echo "  触发重启的包:"; sort -u /var/run/reboot-required.pkgs | sed 's/^/    /'; }
  echo "  原因:$RSN"
  echo
  echo "  ⚠️  重启后 SSH 会断开，约 30-60 秒后可重连"
  printf "  是否现在重启？(yes/no) "
  read -r R </dev/tty
  if [ "$R" = yes ]; then
    echo; echo "  正在重启，重连后执行阶段 01…"; sleep 2; systemctl reboot
  else
    echo; echo "  已跳过重启。未重启状态下跑 01/02，配置可能与运行中的旧组件不一致。"
  fi
else
  echo "  ✅ 无需重启，可直接执行阶段 01"
fi
