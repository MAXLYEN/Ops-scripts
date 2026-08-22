#!/usr/bin/env bash
# ops/diag-key.sh — 诊断某台机器为什么密钥登录不上
# VERSION: 1.0.0
#
# 密钥下发成功、却依然登不上时用。按 sshd 拒绝密钥的实际原因逐项排查，
# 而不是猜 —— 这类问题的表现完全一样（Permission denied），成因却有五六种。
#
# 用法:
#   diag-key.sh <ssh目标[:端口]> [密码]
#   diag-key.sh -h
#
# 例:
#   diag-key.sh root@1.2.3.4:22 'MyPassw0rd'
#   diag-key.sh root@1.2.3.4:2222          # 已能密钥登录时可省略密码
#
# 只读不改。要自动修复用: opsget ops/setup-key-login <IP> <端口> <密码>

set -o pipefail

usage() {
  cat <<'USAGE'
diag-key.sh — 诊断密钥登录失败的原因

  diag-key.sh <ssh目标[:端口]> [密码]

  密码可省略 —— 省略时用密钥登录去查（适合「能登但想确认配置」的场景）；
  提供密码则用密码登录去查（适合密钥完全登不上的场景）。

检查项: 家目录与 .ssh 权限、authorized_keys 内容、sshd 生效配置、
        磁盘是否写满、SELinux、以及客户端侧的完整认证过程。

只读不改。要自动修复: opsget ops/setup-key-login <IP> <端口> <密码>
USAGE
}

die() { printf '[致命] %s\n' "$*" >&2; exit 1; }

case "${1:-}" in -h|--help|'') usage; exit 0 ;; esac

tgt="$1"; pw="${2:-}"
case "$tgt" in *:*) t=${tgt%:*}; p=${tgt##*:} ;; *) t=$tgt; p=22 ;; esac
case "$p" in ''|*[!0-9]*) die "端口必须是数字: $p" ;; esac

# 有密码就用密码连（密钥登不上时唯一的进入方式），否则用密钥
if [ -n "$pw" ]; then
  command -v sshpass >/dev/null 2>&1 || die "缺 sshpass: apt-get install -y sshpass"
  rsh() {
    SSHPASS="$pw" sshpass -e ssh -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no -p "$p" "$t" "$@"
  }
  MODE="密码"
else
  rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$p" "$t" "$@"; }
  MODE="密钥"
fi

printf '════ %s（用%s登录检查）════\n' "$tgt" "$MODE"

rsh '
  S="sudo -n"; [ "$(id -u)" -eq 0 ] && S=""
  echo "── 当前用户"; id
  echo
  echo "── 家目录与 .ssh 权限"
  # sshd 对权限极严：家目录组/其他可写、.ssh 非 700、authorized_keys 非 600
  # 都会导致静默拒绝，日志里也只是一句 Authentication refused
  ls -ld ~ ~/.ssh ~/.ssh/authorized_keys 2>&1
  echo
  echo "── authorized_keys"
  if [ -f ~/.ssh/authorized_keys ]; then
    echo "  行数: $(wc -l < ~/.ssh/authorized_keys)"
    echo "  指纹:"
    ssh-keygen -lf ~/.ssh/authorized_keys 2>/dev/null | sed "s/^/    /" || echo "    （无法解析）"
  else
    echo "  文件不存在 —— 公钥根本没下发成功"
  fi
  echo
  echo "── sshd 生效配置"
  $S sshd -T 2>/dev/null | grep -iE "^(pubkeyauthentication|passwordauthentication|authorizedkeysfile|permitrootlogin|allowusers|allowgroups|denyusers|strictmodes)" | sed "s/^/  /" \
    || { echo "  读不到 sshd -T（需要 root），改看配置文件:"
         grep -riE "^\s*(PubkeyAuthentication|AuthorizedKeysFile|PermitRootLogin|AllowUsers|AllowGroups|StrictModes)" \
           /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed "s/^/    /"; }
  echo
  echo "── Match 块（会覆盖全局设置，容易被忽略）"
  grep -rniE "^\s*Match\s" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed "s/^/  /" || echo "  无"
  echo
  echo "── 磁盘"
  df -h ~ | tail -1 | sed "s/^/  /"
  echo
  echo "── SELinux"
  getenforce 2>/dev/null || echo "  未启用"
' </dev/null 2>&1

echo
echo "── 客户端侧认证过程（sshd 拒绝的实际位置）"
ssh -vv -o BatchMode=yes -o ConnectTimeout=8 -p "$p" "$t" true </dev/null 2>&1 \
  | grep -iE "offering|send_pubkey|authentications that can continue|denied|Authenticated to|refused|no mutual" \
  | sed 's/^/  /' | head -15

echo
echo "── 常见成因对照"
cat <<'HINT'
  pubkeyauthentication no        服务端关了公钥认证 → setup-key-login 会自动打开
  家目录 drwxrwxr-x 之类          组/其他可写，StrictModes 会拒绝 → chmod g-w,o-w ~
  authorized_keys 行数 0          公钥没下发成功 → 重跑 push-keys / setup-key-login
  allowusers / allowgroups 有值   你的用户不在白名单里 → 需要人工加
  Match 块                        块内设置会覆盖全局，需逐块确认
  磁盘 100%                       写不进 authorized_keys，也可能导致登录失败
HINT
