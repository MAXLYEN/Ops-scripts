#!/usr/bin/env bash
# ops/save-fw.sh — 改防火墙或系统配置前保存现状
# VERSION: 2.0.0
#
# 在跑任何会动 ufw / sshd / iptables 的东西之前跑一次。出事能照着恢复。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

D="/root/fwstate_$(date -u +%Y%m%d%H%M%S)"
mkdir -p "$D"

ufw status numbered  > "$D/ufw-numbered.txt" 2>&1
ufw show added       > "$D/ufw-added.txt"    2>&1
iptables-save        > "$D/iptables.rules"   2>&1
ip6tables-save       > "$D/ip6tables.rules"  2>&1
cp -a /etc/ufw       "$D/etc-ufw"            2>/dev/null
grep -E '^\s*(Port|PermitRootLogin|PasswordAuthentication|ListenAddress)' \
  /etc/ssh/sshd_config > "$D/sshd.txt" 2>/dev/null
[ -d /etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d "$D/sshd_config.d" 2>/dev/null
sshd -T > "$D/sshd-effective.txt" 2>/dev/null
systemctl list-units --type=service --state=running > "$D/services.txt" 2>&1
docker ps -a --format '{{.Names}} {{.Status}} {{.Ports}}' > "$D/containers.txt" 2>/dev/null
crontab -l           > "$D/crontab.txt"      2>/dev/null
timedatectl          > "$D/time.txt"         2>&1
ss -lntup            > "$D/listen.txt"       2>&1

sha_write "$D"
ok "已保存: $D"
ls -1 "$D" | sed 's/^/  /'

cat <<EOF

  恢复参考：
    ufw:      ufw --force reset && bash <(sed -n 's/^/ufw /p' $D/ufw-added.txt)
    iptables: iptables-restore < $D/iptables.rules
    sshd:     对照 $D/sshd.txt 与 $D/sshd_config.d/
    crontab:  crontab $D/crontab.txt

  提醒：动 ufw 之前先确认带外控制台能进 —— 规则配错时那是唯一的路。
EOF
