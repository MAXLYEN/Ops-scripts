#!/usr/bin/env bats
# tests/ssh-allowlist.bats — 真跑 ops/ssh-allowlist（不是桩）。
# ufw 换成记状态的假实现（规则按 `ufw show added` 的格式存成一行一条），sshd / systemd-run / systemctl 换成记调用的桩。
# 能证明：名单的来源与去重、当前会话来源的核对、先加放行再删全开、只动自己打注释的规则、自动回滚的布置 / 确认 / 回滚。
# 证明不了：真实 ufw 的规则语法与匹配、systemd 定时器真的到点回滚、真实网络下连不连得上。

load helpers

none() {  # none <正则> <文本>：文本里不能有匹配的行
  grep -qE -- "$1" <<<"$2" || return 0
  printf '不该出现: %s\n%s\n' "$1" "$2" >&2
  return 1
}

S=/tmp/sa            # 假实现的状态与日志
FB=/tmp/sabin         # 假命令
PENDING=/var/lib/ops-scripts/ssh-allowlist.pending

setup() {
  rm -rf "$S" "$FB" /etc/ops-scripts /usr/local/lib/ops-common.sh "$PENDING" /root/ops-backups/ufw.*
  mkdir -p "$S" "$FB" /etc/ufw /etc/ops-scripts
  echo ORIGINAL4 > /etc/ufw/user.rules; echo ORIGINAL6 > /etc/ufw/user6.rules
  printf '%s\n' "ufw allow 80/tcp" "ufw allow 443/tcp" "ufw limit 59967/tcp comment 'SSH rate-limited'" \
    "ufw allow from 172.16.0.0/12 to any port 3306 proto tcp" > "$S/rules"
  printf '%s\n' '# 机群' 'root@203.0.113.21:22' 'root@203.0.113.22:60690' '' > /root/.vps-hosts.txt
  env_conf 'ADMIN_IPS="198.51.100.7 198.51.100.64/26"' 'ALLOW_EXTRA_IPS="198.51.100.7 192.0.2.10"'
  fakes
  export PATH="$FB:$PATH" SSH_CONNECTION="198.51.100.7 50000 192.0.2.10 59967"
}

teardown() { rm -rf "$S" "$FB" /root/.vps-hosts.txt /etc/ufw "$PENDING"; }

env_conf() { printf '%s\n' "$@" > /etc/ops-scripts/env.conf; chmod 600 /etc/ops-scripts/env.conf; }

fakes() {
  # ufw：show added 列规则；allow 追加；--force delete 按规则本身（去掉注释）删第一条，没有就失败；
  # $S/allow-fail 里写的地址 allow 时失败
  cat > "$FB/ufw" <<'EOF'
#!/bin/bash
R=/tmp/sa/rules
echo "ufw $*" >> /tmp/sa/calls
[ "$1" = --force ] && shift
case "$1" in
  show) echo "Added user rules (see 'ufw status' for running firewall):"; cat "$R" ;;
  allow)
    if [ "$2" = from ] && grep -qxF "$3" /tmp/sa/allow-fail 2>/dev/null; then exit 1; fi
    if [ "${@: -2:1}" = comment ]; then c=${@: -1}; set -- "${@:1:$#-2}"; echo "ufw $* comment '$c'" >> "$R"
    else echo "ufw $*" >> "$R"; fi ;;
  delete)
    shift; want="ufw $*"; n=0
    while IFS= read -r l; do
      n=$((n + 1)); [ "${l%% comment *}" = "$want" ] || continue
      sed -i "${n}d" "$R"; exit 0
    done < "$R"
    exit 1 ;;
  reload) ;;
esac
exit 0
EOF
  printf '#!/bin/sh\n[ "$1" = -T ] && echo "port 59967"\nexit 0\n' > "$FB/sshd"
  printf '#!/bin/sh\necho "systemd-run $*" >> /tmp/sa/calls\nexit 0\n' > "$FB/systemd-run"
  printf '#!/bin/sh\necho "systemctl $*" >> /tmp/sa/calls\nexit 0\n' > "$FB/systemctl"
  chmod 755 "$FB"/*
}

sa() { run bash "$SRC/ops/ssh-allowlist.sh" "$@"; }
tagged() { grep -c "comment 'ssh-allowlist'" "$S/rules"; }

@test "预演：列出名单（机群 + ADMIN_IPS + ALLOW_EXTRA_IPS，去重）与要做的改动，防火墙不动" {
  cp "$S/rules" "$S/before"
  sa
  [ "$status" -eq 0 ]
  has "198.51.100.7         ADMIN_IPS、ALLOW_EXTRA_IPS"
  has "203.0.113.22         机群"
  has "198.51.100.64/26     ADMIN_IPS"
  has "当前会话的来源 198.51.100.7 在名单里"
  has "+ ufw allow from 203.0.113.21 to any port 59967 proto tcp comment 'ssh-allowlist'"
  has "- ufw delete limit 59967/tcp comment 'SSH rate-limited'"
  cmp "$S/rules" "$S/before"
  none 'systemd-run' "$(cat "$S/calls" 2>/dev/null)"
}

@test "执行：先备份、布置 5 分钟回滚，再逐个放行，最后删全开的规则；别的端口不动；--confirm 取消回滚" {
  sa --apply
  [ "$status" -eq 0 ]
  [ "$(tagged)" = 5 ]
  grep -qxF "ufw allow from 198.51.100.64/26 to any port 59967 proto tcp comment 'ssh-allowlist'" "$S/rules"
  none '59967/tcp' "$(cat "$S/rules")"
  grep -qxF 'ufw allow 80/tcp' "$S/rules" && grep -qF 'port 3306' "$S/rules"
  grep -q 'systemd-run --on-active=300 --unit=ssh-allowlist-rollback' "$S/calls"
  b=$(cat "$PENDING"); [ "$(cat "$b/user.rules")" = ORIGINAL4 ] && [ "$(cat "$b/user6.rules")" = ORIGINAL6 ]
  # 顺序：回滚在前，放行在删全开之前
  run_line() { grep -n -- "$1" "$S/calls" | head -1 | cut -d: -f1; }
  [ "$(run_line 'systemd-run')" -lt "$(run_line 'ufw allow from')" ]
  [ "$(grep -n 'ufw allow from' "$S/calls" | tail -1 | cut -d: -f1)" -lt "$(run_line 'delete limit 59967/tcp')" ]
  sa --confirm
  [ "$status" -eq 0 ]
  grep -q 'systemctl stop ssh-allowlist-rollback.timer' "$S/calls"
  [ ! -e "$PENDING" ]
}

@test "当前会话的来源不在名单里：拒绝执行，什么都不动" {
  cp "$S/rules" "$S/before"
  export SSH_CONNECTION="100.64.9.9 50000 192.0.2.10 59967"
  sa --apply
  [ "$status" -ne 0 ]
  has "当前会话的来源 100.64.9.9 不在名单里"
  cmp "$S/rules" "$S/before"
  [ ! -e "$PENDING" ]
  none 'systemd-run' "$(cat "$S/calls" 2>/dev/null)"
}

@test "名单变了再执行：只删自己加过、已不在名单里的，其余不动；一致时不改" {
  sa --apply; sa --confirm
  printf '%s\n' 'root@203.0.113.22:60690' > /root/.vps-hosts.txt
  sa --apply
  [ "$status" -eq 0 ]
  none 'from 203.0.113.21 ' "$(cat "$S/rules")"
  [ "$(tagged)" = 4 ]
  sa --confirm
  sa
  has "规则已经和名单一致，不用改"
}

@test "有一条放行没加上：不删全开的规则（宁可多开），告警" {
  echo 203.0.113.22 > "$S/allow-fail"
  sa --apply
  [ "$status" -ne 0 ]
  has "没有删「对所有来源开放」的规则"
  grep -qF "ufw limit 59967/tcp comment 'SSH rate-limited'" "$S/rules"
}

@test "--rollback：放回执行前的规则并重载，取消定时回滚" {
  sa --apply
  echo CHANGED > /etc/ufw/user.rules
  sa --rollback
  [ "$status" -eq 0 ]
  [ "$(cat /etc/ufw/user.rules)" = ORIGINAL4 ]
  grep -q 'ufw reload' "$S/calls"
  grep -q 'systemctl stop ssh-allowlist-rollback.timer' "$S/calls"
  [ ! -e "$PENDING" ]
}

@test "认不出的地址与太宽的网段跳过并告警，不写进规则" {
  env_conf 'ADMIN_IPS="198.51.100.7 0.0.0.0/0 not-an-ip"'
  sa --apply
  has "跳过太宽的网段：0.0.0.0/0"
  has "跳过认不出的地址：not-an-ip"
  none '0.0.0.0/0|not-an-ip' "$(cat "$S/rules")"
}
