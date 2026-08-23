#!/bin/bash
# init/03-ssh-firewall.sh — SSH 与防火墙
# VERSION: 1.3.0
# 1.3.0: 新增交互式 SSH 会话的空闲超时（默认 2 小时，可由 env.conf 的
#        SSH_IDLE_TIMEOUT 覆盖，设 0 关闭）。
#        用 shell 层的 TMOUT 而非 ClientAlive* —— 后者管的是「对端失联多久算断」，
#        只要终端还在回应保活包，挂多久都不会断，实现不了「无操作超时」。
#        TMOUT 只在 bash 等待输入时计数，跑长任务期间不会被打断。
# 1.2.0: 端口段可由 /etc/ops-scripts/env.conf 覆盖；容器数据库放行改为按配置生成
# 1.1.0: 去掉 61000:62000；ufw enable 后检查 Docker iptables 链
#
# 本目录的脚本刻意不依赖 lib/common.sh，理由见 00-precheck.sh 头部。
#
# ⚠️ 跑之前先连好第二个 SSH 窗口。脚本布置了 5 分钟自动回滚兜底，
#    但带外控制台（VNC/管理终端）才是真正的最后一道保险。

set -e
[ "$(id -u)" -eq 0 ] || { echo "❌ 需要 root"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
export DEBIAN_FRONTEND=noninteractive

# ── 除 SSH 外要放行的端口 ──
# 默认值适用于大多数机器；若本机已有 /etc/ops-scripts/env.conf，
# 以它的 SVC_TCP_RANGES / SVC_UDP_RANGES 为准。
EXTRA_TCP="80 443 10000:11000 50000:60000"
EXTRA_UDP="443 50000:60000"
DOCKER_CIDR=""
[ -f /etc/ops-scripts/env.conf ] && . /etc/ops-scripts/env.conf 2>/dev/null || true
EXTRA_TCP="${SVC_TCP_RANGES:-$EXTRA_TCP}"
# 交互式 SSH 会话空闲多久自动退出（秒）。0 = 不启用。
IDLE_TIMEOUT="${SSH_IDLE_TIMEOUT:-7200}"
EXTRA_UDP="${SVC_UDP_RANGES:-$EXTRA_UDP}"

echo "════════ 03 · SSH 与防火墙 ════════"
echo "─ 0. 能力探测 ─"
sshd -t || { echo "❌ 现有 sshd_config 已有语法错误，先修复"; exit 1; }
if sshd -T -o 'KbdInteractiveAuthentication=no' >/dev/null 2>&1; then
  KBD=KbdInteractiveAuthentication
else
  KBD=ChallengeResponseAuthentication
fi
SSH_UNIT=$(systemctl list-unit-files --no-legend 'ssh.service' 'sshd.service' 2>/dev/null | awk 'NR==1{print $1}')
SSH_UNIT=${SSH_UNIT:-ssh.service}
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  DROPIN=1
else
  DROPIN=0
fi
# SSH 端口自动探测：sshd 配置里的 + 当前连接实际用的，取并集。
# 所以换机器不用手工改端口，这一点容易被忘掉而白白改配置。
CFG_PORTS=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
CUR_PORT=$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')
PORTS=$(printf '%s\n' $CFG_PORTS $CUR_PORT | grep -E '^[0-9]+$' | sort -un)
[ -n "$PORTS" ] || { echo "❌ 无法确定 SSH 端口"; exit 1; }
F2B_PORTS=$(echo $PORTS | tr ' ' ',')
printf '  %-16s %s\n' \
  认证选项名 "$KBD" \
  SSH单元    "$SSH_UNIT" \
  drop-in    "$([ $DROPIN -eq 1 ] && echo 支持 || echo 不支持)" \
  SSH端口    "$F2B_PORTS" \
  放行TCP    "$EXTRA_TCP" \
  放行UDP    "$EXTRA_UDP"

echo
echo "─ 1. 安装组件 ─"
apt-get -o DPkg::Lock::Timeout=300 update -qq 2>/dev/null || {
  echo "❌ apt 源有问题，请先跑阶段 00"; exit 1; }
apt-get -o DPkg::Lock::Timeout=300 install -y -qq ufw fail2ban python3-systemd >/dev/null
if python3 -c 'import systemd.journal' 2>/dev/null; then
  F2B_BACKEND=systemd
else
  F2B_BACKEND=auto
fi
if [ -f /etc/fail2ban/action.d/ufw.conf ]; then
  F2B_ACTION=ufw
else
  F2B_ACTION=iptables-multiport
fi
printf '  %-16s %s\n' \
  fail2ban "$(dpkg-query -W -f='${Version}' fail2ban 2>/dev/null || echo 未知)" \
  ufw      "$(dpkg-query -W -f='${Version}' ufw 2>/dev/null || echo 未知)" \
  后端     "$F2B_BACKEND" \
  封禁动作 "$F2B_ACTION"

echo
echo "─ 2. 人工确认 ─"
echo "  将修改 SSH 配置并启用防火墙（保留密码登录），并布置 5 分钟自动回滚。"
printf "  确认继续？(yes/no) "
read -r A </dev/tty
[ "$A" = yes ] || { echo "  已取消，未做任何修改"; exit 0; }

echo
echo "─ 3. 布置自动回滚 ─"
BAK=/etc/ssh/sshd_config.bak.$TS
cp -a /etc/ssh/sshd_config "$BAK"
systemctl stop server-rollback.timer 2>/dev/null || true
systemd-run --on-active=300 --unit=server-rollback \
  --description='auto rollback ufw+sshd' \
  /bin/sh -c "/usr/sbin/ufw --force disable; rm -f /etc/ssh/sshd_config.d/00-hardening.conf; cp -a $BAK /etc/ssh/sshd_config; systemctl reload $SSH_UNIT" \
  >/dev/null 2>&1
T0=$(date +%s)
echo "  ⏰ 5 分钟后若未取消：关闭 ufw + 还原 sshd 配置"

echo
echo "─ 4. SSH 配置（明确保留密码登录）─"
if [ "$DROPIN" -eq 1 ]; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-hardening.conf << INNER
# hardening $TS
# 00- 前缀确保先于 50-cloud-init.conf 被读取（SSH 首次出现的指令优先）
PasswordAuthentication yes
PubkeyAuthentication yes
$KBD no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 60
ClientAliveCountMax 5
TCPKeepAlive yes
INNER
  echo "  写入 /etc/ssh/sshd_config.d/00-hardening.conf"
else
  sed -i -E "/^[[:space:]]*#?[[:space:]]*($KBD|PermitEmptyPasswords|MaxAuthTries|LoginGraceTime|ClientAliveInterval|ClientAliveCountMax)[[:space:]]/d" /etc/ssh/sshd_config
  cat >> /etc/ssh/sshd_config << INNER

# hardening $TS
PasswordAuthentication yes
$KBD no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 60
ClientAliveCountMax 5
INNER
  echo "  已写入 sshd_config"
fi
sshd -t || {
  echo "❌ 语法错误，立即回滚"
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  cp -a "$BAK" /etc/ssh/sshd_config
  exit 1
}
systemctl reload "$SSH_UNIT"
echo "  实际生效: $(sshd -T | grep -iE "^(passwordauthentication|${KBD}|maxauthtries)" | tr '\n' ' ')"

# 空闲超时走 shell 层。ClientAliveInterval/CountMax 管的是「对端失联多久算断」，
# 终端只要还在回应保活包就永远不断 —— 用它实现不了「无操作超时」。
IDLE_FILE=/etc/profile.d/99-idle-timeout.sh
case "$IDLE_TIMEOUT" in
  ''|0|*[!0-9]*)
    rm -f "$IDLE_FILE"
    echo "  空闲超时: 未启用（SSH_IDLE_TIMEOUT=${IDLE_TIMEOUT:-未设})"
    ;;
  *)
    cat > "$IDLE_FILE" << INNER
# 交互式 SSH 会话空闲超时  $TS
# TMOUT 只在 bash 等待输入时计数：跑备份/采集等长任务期间不会被打断，
# 任务结束回到提示符才开始计时。
# 只对 SSH 会话生效 —— VNC/串口等救援通道不设超时，免得 SSH 出问题时
# 连补救的入口也一起被掐。
# 需要长时间挂着请用 screen/tmux：那样断线也不丢进度，比放宽超时更可靠。
case \$- in
  *i*) [ -n "\$SSH_CONNECTION" ] && { TMOUT=$IDLE_TIMEOUT; readonly TMOUT; export TMOUT; } ;;
esac
INNER
    chmod 644 "$IDLE_FILE"
    echo "  空闲超时: ${IDLE_TIMEOUT}秒（$((IDLE_TIMEOUT / 60)) 分钟）→ $IDLE_FILE"
    echo "    下次登录生效；当前会话不受影响"
    ;;
esac

echo
echo "─ 5. 防火墙规则（先写全，最后才 enable）─"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in $PORTS; do
  ufw limit "$p"/tcp comment 'SSH rate-limited' >/dev/null
  echo "  SSH $p/tcp 放行+限速"
done
for r in $EXTRA_TCP; do ufw allow "$r"/tcp >/dev/null && echo "  $r/tcp"; done
for r in $EXTRA_UDP; do ufw allow "$r"/udp >/dev/null && echo "  $r/udp"; done
# 容器访问宿主机数据库：只有配置里明确写了 DOCKER_CIDR 才加，
# 通用机器不需要这条。漏了它是延迟发作的 —— 连接池里的旧连接还能撑
# 几小时，然后突然全站 503。
if [ -n "$DOCKER_CIDR" ] && command -v docker >/dev/null 2>&1; then
  ufw allow from "$DOCKER_CIDR" to any port 3306 proto tcp \
    comment 'containers -> host MySQL' >/dev/null \
    && echo "  3306/tcp ← $DOCKER_CIDR（容器访问宿主机数据库）"
fi

echo
echo "─ 6. 启用防火墙 ─"
ufw --force enable >/dev/null
MISS=""
for p in $PORTS; do
  ufw status | grep -qE "(^|[^0-9])$p/tcp" || MISS="$MISS $p"
done
if [ -n "$MISS" ]; then
  echo "❌ 严重: 端口$MISS 未出现在规则中，立即关闭防火墙"
  ufw --force disable
  exit 1
fi
echo "  ✅ 所有 SSH 端口已确认放行"
# ufw enable 会重建 iptables，可能打乱 dockerd 自插的 DOCKER 链，
# 表现为容器端口突然不通、或容器连不上宿主机服务。
if command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -q 2>/dev/null)" ]; then
  if iptables -S DOCKER 2>/dev/null | grep -q -- '-j ACCEPT'; then
    echo "  ✅ Docker iptables 链完好"
  else
    echo "  ⚠️  Docker 转发规则疑似被 ufw 冲掉，重启 docker 恢复"
    systemctl restart docker; sleep 8
    iptables -S DOCKER 2>/dev/null | grep -q -- '-j ACCEPT' \
      && echo "  ✅ 已恢复" \
      || echo "  ❌ 仍异常，跑完手动排查: iptables -S DOCKER"
  fi
  echo "  运行中容器: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
fi

echo
echo "─ 7. fail2ban ─"
mkdir -p /etc/fail2ban/jail.d
rm -f /etc/fail2ban/jail.d/sshd.conf
write_jail() {
  {
    echo '[DEFAULT]'
    echo "banaction = $F2B_ACTION"
    echo "banaction_allports = $F2B_ACTION"
    echo "backend = $F2B_BACKEND"
    if [ "$1" = inc ]; then
      echo '# 重复触犯时封禁时长翻倍，上限 60 天'
      echo 'bantime.increment = true'
      echo 'bantime.factor = 2'
      echo 'bantime.maxtime = 5184000'
    fi
    echo
    echo '[sshd]'
    echo 'enabled = true'
    echo 'mode = normal'
    echo "port = $F2B_PORTS"
    echo 'maxretry = 3'
    echo 'findtime = 3600'
    echo 'bantime = 604800'
    if [ "$F2B_BACKEND" = systemd ]; then
      echo "journalmatch = _SYSTEMD_UNIT=$SSH_UNIT + _COMM=sshd"
    else
      for L in /var/log/auth.log /var/log/secure; do
        [ -f "$L" ] && { echo "logpath = $L"; break; }
      done
    fi
  } > /etc/fail2ban/jail.d/99-sshd.conf
  return 0
}
write_jail inc
if fail2ban-client -t >/dev/null 2>&1; then
  echo "  已启用递增封禁"
else
  echo "  ℹ️  该版本不支持递增封禁，回退固定封禁"
  write_jail plain
  fail2ban-client -t >/dev/null 2>&1 || \
    echo "  ⚠️  配置校验仍失败: $(fail2ban-client -t 2>&1 | tail -3)"
fi
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban || echo "  ⚠️  fail2ban 启动失败: journalctl -u fail2ban -n 20"
for i in $(seq 1 20); do
  fail2ban-client status sshd >/dev/null 2>&1 && break
  sleep 1
done
fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || \
  echo "  ⚠️  未就绪（不影响防火墙）: journalctl -u fail2ban -n 30"

echo
echo "════════ 8. 连通性验证 ════════"
snap() {
  for p in $PORTS; do
    ss -tnH state established "( sport = :$p )" 2>/dev/null | awk '{print $4}'
  done | sort -u
  return 0
}
snap > /root/.ssh_base.txt
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "  👉 请【另开一个新窗口】登录本机（端口 $F2B_PORTS）"
echo "     检测到新连接会自动提示；也可直接输入 yes（能连上）/ no（连不上）后回车"
echo
DL=$((T0+250)); R=pending; TICK=0
while [ "$(date +%s)" -lt "$DL" ]; do
  if read -t 3 -r ANS </dev/tty; then
    case "$ANS" in
      yes|y|Y) R=ok;   break ;;
      no|n|N)  R=fail; break ;;
      "")      : ;;
      *)       echo "     请输入 yes 或 no" ;;
    esac
  fi
  AC=$(journalctl -u "$SSH_UNIT" --since "$STAMP" -q --no-pager 2>/dev/null | grep -c 'Accepted' || true)
  NC=$(snap | grep -vxFf /root/.ssh_base.txt || true)
  if [ "${AC:-0}" -gt 0 ] || [ -n "$NC" ]; then R=auto; break; fi
  TICK=$((TICK+1))
  [ $((TICK % 10)) -eq 0 ] && echo "     …等待中，回滚将在 $((DL - $(date +%s) + 50)) 秒后触发"
done
echo
case "$R" in
  auto)    echo "  ✅ 已自动检测到新的 SSH 登录，防火墙与 SSH 配置正常" ;;
  ok)      echo "  ✅ 你确认新窗口可以登录" ;;
  fail)    echo "  ❌ 新窗口无法登录" ;;
  pending) echo "  ⏱️  等待超时，未检测到新连接" ;;
esac
echo

if [ "$R" = auto ] || [ "$R" = ok ]; then
  printf "  是否取消回滚定时器、保留本次配置？(yes/no) "
  read -r C </dev/tty
  if [ "$C" = yes ]; then
    systemctl stop server-rollback.timer 2>/dev/null || true
    systemctl reset-failed server-rollback.service 2>/dev/null || true
    sleep 1
    if systemctl list-timers --all 2>/dev/null | grep -qi server-rollback; then
      echo "  ⚠️  定时器似乎仍在，请手动执行: systemctl stop server-rollback.timer"
    else
      echo "  ✅ 回滚定时器已取消，配置永久保留"
      echo
      echo "  ⚠️  下一步建议改一个强随机密码（当前是唯一防线）:"
      echo "     openssl rand -base64 24 | tr -d '/+=' | head -c 24; echo"
      echo
      echo "  重启可验证 swap / BBR模块 / udev规则 / 服务自启 是否真的持久。"
      echo "  建议 yes —— 初始化阶段是验证成本最低的时刻，业务上线后不再有这个机会。"
      printf "  是否现在重启？(yes/no) "
      read -r RB </dev/tty
      if [ "$RB" = yes ]; then
        echo; echo "  正在重启，重连后执行阶段 04…"; sleep 2; systemctl reboot
      else
        echo; echo "  已跳过重启。稍后手动 reboot，再执行阶段 04。"
      fi
    fi
  else
    echo "  已保留定时器，配置将在倒计时结束后自动还原。"
  fi
else
  echo "  🛑 不要重启，也不要做任何操作"
  echo "     回滚定时器会在倒计时结束后自动关闭 ufw 并还原 sshd 配置"
  echo "     注意：systemd-run 建的是临时单元，重启会使其消失、错误配置反而被固化"
  echo "     等待还原后把本窗口完整输出发我排查"
fi
echo
echo "✅ 阶段 03 结束"
