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

@test "--add：规范后写进 ADMIN_IPS（留 .bak）再执行；已在名单里的、认不出的、太宽的都拒绝" {
  sa --add 198.51.100.99
  grep -qx 'ADMIN_IPS="198.51.100.7 198.51.100.64/26 198.51.100.99"' /etc/ops-scripts/env.conf
  ls /etc/ops-scripts/env.conf.bak.* >/dev/null
  grep -qxF "ufw allow from 198.51.100.99 to any port 59967 proto tcp comment 'ssh-allowlist'" "$S/rules"
  [ -e "$PENDING" ]
  has "ssh-allowlist.sh --confirm"
  sa --confirm
  cp /etc/ops-scripts/env.conf "$S/env.before"
  sa --add 198.51.100.99
  [ "$status" -ne 0 ]; has "已经在名单里"
  sa --add 0.0.0.0/0
  [ "$status" -ne 0 ]; has "网段太宽"
  sa --add bogus
  [ "$status" -ne 0 ]; has "认不出的地址"
  cmp /etc/ops-scripts/env.conf "$S/env.before"
}

@test "--remove：从 ADMIN_IPS、ALLOW_EXTRA_IPS、机群清单里一并去掉（各留 .bak）；机群与 LLM 白名单给提示；不能删当前来源" {
  sa --apply; sa --confirm
  sa --remove 203.0.113.21
  none '203.0.113.21' "$(cat /root/.vps-hosts.txt)"
  grep -qx 'root@203.0.113.22:60690' /root/.vps-hosts.txt
  ls /root/.vps-hosts.txt.bak.* >/dev/null
  has "是 ~/.vps-hosts.txt 里的机器"
  none 'from 203.0.113.21 ' "$(cat "$S/rules")"
  sa --confirm
  sa --remove 192.0.2.10
  grep -qx 'ALLOW_EXTRA_IPS="198.51.100.7"' /etc/ops-scripts/env.conf
  has "opsget ops/sync-llm-allowlist"
  sa --confirm
  cp /etc/ops-scripts/env.conf "$S/env.before"
  sa --remove 198.51.100.7
  [ "$status" -ne 0 ]; has "是你当前会话的来源"
  cmp /etc/ops-scripts/env.conf "$S/env.before"
}

@test "改了配置又回滚（运行的窗口断了、定时回滚或 --rollback）：配置连同防火墙一起改回" {
  cp /etc/ops-scripts/env.conf "$S/env.before"
  sa --add 198.51.100.99
  grep -q '198.51.100.99' /etc/ops-scripts/env.conf
  # 定时回滚的命令里带着改回配置
  grep 'systemd-run' "$S/calls" | grep -qF "cp -a '/etc/ops-scripts/env.conf.bak."
  sa --rollback
  [ "$status" -eq 0 ]
  has "也改回去了"
  cmp /etc/ops-scripts/env.conf "$S/env.before"
  [ ! -e "$PENDING" ]
}

@test "菜单：新增 → 确认执行 → 新窗口能登录输 yes，保留并取消定时回滚" {
  drive "bash $SRC/ops/ssh-allowlist.sh" 1 198.51.100.99 yes yes
  has "[1] 新增  [2] 删除"
  grep -q '198.51.100.99' /etc/ops-scripts/env.conf
  grep -qF 'from 198.51.100.99 ' "$S/rules"
  has "已取消自动回滚，新规则保留"
  [ ! -e "$PENDING" ]
}

@test "菜单：按编号删除；新窗口登不上输别的，当场回滚" {
  drive "bash $SRC/ops/ssh-allowlist.sh" 2 4 yes no
  has "从 机群 里去掉 203.0.113.21"
  has "已回滚到执行前的规则"
  grep -q 'ufw reload' "$S/calls"
  [ "$(cat /etc/ufw/user.rules)" = ORIGINAL4 ]
  grep -qx 'root@203.0.113.21:22' /root/.vps-hosts.txt     # 顺带改过的机群清单也改回去了
  has "也改回去了"
  [ ! -e "$PENDING" ]
}

@test "菜单：不确认就什么都不写" {
  cp /etc/ops-scripts/env.conf "$S/env.before"; cp "$S/rules" "$S/before"
  drive "bash $SRC/ops/ssh-allowlist.sh" 1 198.51.100.99 no
  cmp /etc/ops-scripts/env.conf "$S/env.before"
  cmp "$S/rules" "$S/before"
  [ ! -e "$PENDING" ]
}

@test "认不出的地址与太宽的网段跳过并告警，不写进规则" {
  env_conf 'ADMIN_IPS="198.51.100.7 0.0.0.0/0 not-an-ip"'
  sa --apply
  has "跳过太宽的网段：0.0.0.0/0"
  has "跳过认不出的地址：not-an-ip"
  none '0.0.0.0/0|not-an-ip' "$(cat "$S/rules")"
}
