#!/usr/bin/env bash
# ops/save-fw.sh — 在修改防火墙前保存当前配置快照
# VERSION: 2.0.2
# 2.0.2: 修正 ufw 恢复命令（原命令会让防火墙停在关闭状态）；另存 ufw status verbose 以保留默认策略。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env

D="/root/fwstate_$(date -u +%Y%m%d%H%M%S)"
mkdir -p "$D"

ufw status numbered  > "$D/ufw-numbered.txt" 2>&1
ufw status verbose   > "$D/ufw-verbose.txt"  2>&1
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
SSHP=$(awk '/^port /{print $2; exit}' "$D/sshd-effective.txt" 2>/dev/null)

# ufw show added 的每行本身就以 "ufw " 开头，首行是标题。reset 会关掉防火墙，
# 所以恢复分三步，确认 SSH 端口已在规则里才重新启用 —— 否则要么一直敞着，要么把自己锁外面。
cat <<EOF

  恢复参考：
    ufw:      ufw --force reset
              grep '^ufw ' $D/ufw-added.txt | sh     # 逐条重加，留意有无报错
              ufw show added | grep -q ' ${SSHP:-<SSH端口>}/tcp' && ufw --force enable
              ufw status verbose                      # 与 $D/ufw-verbose.txt 对照默认策略
    iptables: iptables-restore < $D/iptables.rules
    sshd:     对照 $D/sshd.txt 与 $D/sshd_config.d/
    crontab:  crontab $D/crontab.txt

  提醒：动 ufw 之前先确认带外控制台能进 —— 规则配错时那是唯一的路。
EOF
