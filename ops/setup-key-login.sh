#!/usr/bin/env bash
# ops/setup-key-login.sh — 给新机器配置密钥登录（一条命令）
# VERSION: 1.0.0
#
# 把本机的 ~/.ssh/id_ed25519.pub 装到目标机，验证密钥登录可用，
# 需要时自动打开服务端的 PubkeyAuthentication，失败自动回滚。
#
# 用法:
#   setup-key-login.sh <IP> <端口> <密码>
#   setup-key-login.sh <IP> <端口> <密码> --user root
#   setup-key-login.sh -h
#
# 例:
#   setup-key-login.sh 1.2.3.4 22 'MyPassw0rd'
#   setup-key-login.sh 1.2.3.4 2222 'MyPassw0rd' --user administrator
#
# 做的事，按顺序：
#   1. 用密码连上去，追加公钥到 ~/.ssh/authorized_keys（去重，可重复跑）
#   2. 修正 ~ 与 ~/.ssh 权限（sshd 对权限极严，过宽会静默拒绝密钥）
#   3. 验证密钥登录
#   4. 不通则查 sshd -T；若 PubkeyAuthentication no，写 drop-in 打开并 reload
#   5. 再验；仍不通则回滚 drop-in，并打印诊断信息
#   6. 成功后把这台追加进 ~/.vps-hosts.txt（去重），供 collect.sh 使用
#
# 全程不动 PasswordAuthentication —— 密码登录始终保留，作为退路。
# 非 root 用户会自动尝试 sudo -n 把公钥同时装到 root。

set -o pipefail

usage() {
  cat <<'USAGE'
setup-key-login.sh — 给新机器配置密钥登录

  setup-key-login.sh <IP> <端口> <密码> [--user 用户名]

  <IP>      新机器公网 IP
  <端口>    SSH 端口（通常 22）
  <密码>    该机器的登录密码，含特殊字符时用单引号包起来
  --user    登录用户，默认 root

例:
  setup-key-login.sh 1.2.3.4 22 'MyPassw0rd'
  setup-key-login.sh 1.2.3.4 2222 'MyPassw0rd' --user administrator

成功后会把这台追加到 ~/.vps-hosts.txt，collect.sh 下次即可带上它。
密码登录不会被关闭 —— 始终保留退路。
USAGE
}

die() { printf '[致命] %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

case "${1:-}" in -h|--help|'') usage; exit 0 ;; esac

IP="$1"; PORT="$2"; PW="$3"; shift 3 2>/dev/null || die "参数不足，看 setup-key-login.sh -h"
USER_NAME=root
while [ $# -gt 0 ]; do
  case "$1" in
    --user) [ -n "${2:-}" ] || die "--user 需要用户名"; USER_NAME="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$IP" ] && [ -n "$PORT" ] && [ -n "$PW" ] || die "用法: setup-key-login.sh <IP> <端口> <密码>"
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字: $PORT" ;; esac
command -v sshpass >/dev/null 2>&1 || die "缺 sshpass: apt-get install -y sshpass"

PUB="$HOME/.ssh/id_ed25519.pub"
[ -r "$PUB" ] || die "找不到公钥 $PUB（先跑 ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519）"
KEY=$(cat "$PUB")
TGT="$USER_NAME@$IP"
HOSTLIST="$HOME/.vps-hosts.txt"

# 用函数而不是字符串变量拼命令：密码含空格或特殊字符时，
# 字符串变量靠词分割展开会散架（转义出的反斜杠在词分割阶段不生效）。
# sshpass -e 从环境变量读密码，不进 ps 的命令行 —— -p 会被同机其他用户看到。
pwssh() {
  # 强制走密码认证：否则这台若已配过密钥，ssh 会用密钥登录成功，
  # 让你误以为密码是对的，掩盖真实状态
  SSHPASS="$PW" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -p "$PORT" "$@"
}
keyssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$PORT" "$@"; }

say "▸ $TGT:$PORT"

# ── 1-2. 下发公钥 + 修权限 ──────────────────────────────────
# shellcheck disable=SC2086
pwssh "$TGT" "
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  chmod g-w,o-w ~ 2>/dev/null
  touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  grep -qxF '$KEY' ~/.ssh/authorized_keys || echo '$KEY' >> ~/.ssh/authorized_keys
  echo OK" </dev/null >/dev/null 2>&1 \
  || die "密码登录失败 —— 检查 IP / 端口 / 密码，或服务端是否禁用了密码登录"
say "  [1/4] 公钥已下发"

# 非 root 时顺带装到 root：探针等运维脚本需要 root，
# 只装普通用户会导致「能登录但干不了活」
if [ "$USER_NAME" != "root" ]; then
  if pwssh "$TGT" 'sudo -n true' </dev/null >/dev/null 2>&1; then
      pwssh "$TGT" "
      sudo -n install -d -m 700 -o root -g root /root/.ssh
      sudo -n touch /root/.ssh/authorized_keys
      sudo -n chmod 600 /root/.ssh/authorized_keys
      sudo -n chown root:root /root/.ssh/authorized_keys
      sudo -n grep -qxF '$KEY' /root/.ssh/authorized_keys \
        || echo '$KEY' | sudo -n tee -a /root/.ssh/authorized_keys >/dev/null" \
      </dev/null >/dev/null 2>&1 \
      && say "  [1/4] 已同时装到 root（之后可直接用 root@$IP）"
  else
    say "  [!] $USER_NAME 无免密 sudo —— 探针等需要 root 的脚本在这台跑不了"
  fi
fi

# ── 3. 验证 ─────────────────────────────────────────────────
# shellcheck disable=SC2086
if keyssh "$TGT" true </dev/null 2>/dev/null; then
  say "  [2/4] 密钥登录可用"
  OK=1
else
  say "  [2/4] 密钥登录还不通，查服务端配置…"
  OK=0
fi

# ── 4. 需要时打开 PubkeyAuthentication ──────────────────────
ROLLBACK=0
if [ "$OK" -eq 0 ]; then
  PUBSET=$(pwssh "$TGT" 'sudo -n sshd -T 2>/dev/null || sshd -T 2>/dev/null' </dev/null 2>/dev/null \
           | grep -i '^pubkeyauthentication' | awk '{print $2}')
  if [ "$PUBSET" = "no" ]; then
    say "  [3/4] 服务端 PubkeyAuthentication no —— 正在打开"
    # 写独立 drop-in 而非改主配置；先 sshd -t 校验语法；用 reload 不断开现有连接
      pwssh "$TGT" '
      set -e
      S="sudo -n"; [ "$(id -u)" -eq 0 ] && S=""
      if $S grep -qiE "^[[:space:]]*PubkeyAuthentication[[:space:]]+no" /etc/ssh/sshd_config; then
        $S cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date -u +%Y%m%d%H%M%S)
        $S sed -i -E "s/^([[:space:]]*PubkeyAuthentication[[:space:]]+no)/#\1/I" /etc/ssh/sshd_config
      fi
      if [ -d /etc/ssh/sshd_config.d ] && $S grep -qiE "^[[:space:]]*Include[[:space:]]+.*sshd_config\.d" /etc/ssh/sshd_config; then
        printf "PubkeyAuthentication yes\n" | $S tee /etc/ssh/sshd_config.d/00-enable-pubkey.conf >/dev/null
        $S chmod 644 /etc/ssh/sshd_config.d/00-enable-pubkey.conf
      else
        printf "\n# added by setup-key-login.sh\nPubkeyAuthentication yes\n" | $S tee -a /etc/ssh/sshd_config >/dev/null
      fi
      $S sshd -t
      $S systemctl reload sshd 2>/dev/null || $S systemctl reload ssh 2>/dev/null || $S service ssh reload' \
      </dev/null >/dev/null 2>&1 \
      && ROLLBACK=1 || say "  [!] 改配置失败（语法校验没过或权限不足）"
    sleep 2
      keyssh "$TGT" true </dev/null 2>/dev/null && { OK=1; ROLLBACK=0; say "  [3/4] 已开启，密钥登录可用"; }
  else
    say "  [3/4] PubkeyAuthentication 是 ${PUBSET:-读不到}，问题不在这里"
  fi
fi

# 改了配置却没换来可用的密钥登录，就别留着这个中间状态
if [ "$ROLLBACK" -eq 1 ]; then
  pwssh "$TGT" '
    S="sudo -n"; [ "$(id -u)" -eq 0 ] && S=""
    $S rm -f /etc/ssh/sshd_config.d/00-enable-pubkey.conf
    $S sed -i -E "/# added by setup-key-login.sh/,+1d" /etc/ssh/sshd_config 2>/dev/null
    $S sshd -t && { $S systemctl reload sshd 2>/dev/null || $S systemctl reload ssh 2>/dev/null || $S service ssh reload; }' \
    </dev/null >/dev/null 2>&1
  say "  [!] 已回滚服务端配置改动"
fi

if [ "$OK" -eq 0 ]; then
  say ""
  say "  密钥登录仍不可用。诊断信息："
  pwssh "$TGT" '
    S="sudo -n"; [ "$(id -u)" -eq 0 ] && S=""
    echo "  家目录权限:"; ls -ld ~ ~/.ssh ~/.ssh/authorized_keys 2>&1 | sed "s/^/    /"
    echo "  sshd 配置:"
    $S sshd -T 2>/dev/null | grep -iE "^(pubkeyauthentication|authorizedkeysfile|permitrootlogin|allowusers|allowgroups)" | sed "s/^/    /"
    echo "  磁盘:"; df -h ~ | tail -1 | sed "s/^/    /"' </dev/null 2>&1
  say ""
  say "  常见剩余原因：AllowUsers/AllowGroups 限制、Match 块覆盖、SELinux 上下文"
  say "  密码登录未受影响，仍可正常使用"
  exit 1
fi

# ── 5. 追加到主机清单 ───────────────────────────────────────
ENTRY="$TGT:$PORT"
touch "$HOSTLIST" 2>/dev/null
if grep -qxF "$ENTRY" "$HOSTLIST" 2>/dev/null; then
  say "  [4/4] $HOSTLIST 里已有这台"
elif grep -qE "^[^#]*@$IP:" "$HOSTLIST" 2>/dev/null; then
  # 同一 IP 换了用户或端口：提示而不静默追加，避免清单里出现两条指向同一台
  say "  [4/4] ⚠ $HOSTLIST 里已有 $IP 的其它条目，未追加，请自行核对："
  grep -nE "^[^#]*@$IP:" "$HOSTLIST" | sed 's/^/      /'
else
  printf '%s\n' "$ENTRY" >> "$HOSTLIST"
  say "  [4/4] 已追加到 $HOSTLIST"
fi

say ""
say "  完成。验证: ssh -p $PORT $TGT"
say "  下次 collect.sh 会自动带上这台"
