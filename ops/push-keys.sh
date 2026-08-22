#!/usr/bin/env bash
# ops/push-keys.sh — 按「每行一台、各自密码」的清单批量下发公钥
# VERSION: 1.0.0
#
# 一次性操作：下发完成后各机器即可免密登录，清单（含明文密码）随即销毁。
# 单台新机器用 ops/setup-key-login.sh 更合适，它带服务端配置修复与回滚。
# 本脚本的定位是「一次处理一批」，比如刚接手一堆机器时。
#
# 清单格式（默认 /root/.vps-keyinit.txt，权限必须 600）：
#   ssh目标[:端口]<空格>密码
#   root@1.2.3.4:22        密码可以包含空格和任意特殊字符
#   root@5.6.7.8:2222      # 行内 # 之后是注释
#
# 用法:
#   push-keys.sh [清单文件]
#   push-keys.sh -h
#
# 已免密的机器自动跳过，重复运行安全（不会在 authorized_keys 里堆重复行）。
# 下发失败的会列出来，改完密码重跑即可。

set -o pipefail

usage() {
  cat <<'USAGE'
push-keys.sh — 批量下发 SSH 公钥

  push-keys.sh [清单文件]      默认 /root/.vps-keyinit.txt

清单每行:  ssh目标[:端口]<空格>密码
  root@1.2.3.4:22  MyPassw0rd
  root@5.6.7.8:2222  another pass with spaces

清单含明文密码，权限必须是 600，脚本会检查。
下发完成后请销毁: shred -u <清单文件>

已免密的机器自动跳过，可重复运行。
单台新机器建议改用: opsget ops/setup-key-login <IP> <端口> <密码>
USAGE
}

die() { printf '[致命] %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

LIST="${1:-/root/.vps-keyinit.txt}"
KEY="$HOME/.ssh/id_ed25519.pub"
[ -r "$KEY" ]  || die "找不到公钥 $KEY（先跑 ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519）"
[ -r "$LIST" ] || die "读不到清单 $LIST（格式见 push-keys.sh -h）"
command -v sshpass >/dev/null 2>&1 || die "缺 sshpass: apt-get install -y sshpass"

# 清单是明文密码，权限必须锁死
perm=$(stat -c %a "$LIST" 2>/dev/null)
case "$perm" in 600|400) ;; *) die "$LIST 权限是 $perm，含明文密码必须 600: chmod 600 $LIST" ;; esac

PUBKEY=$(cat "$KEY")
total=$(awk 'NF && $1 !~ /^#/ {n++} END{print n+0}' "$LIST")
log "清单共 $total 台"; log ""

ok=0; skip=0; nopw=0; n=0; fail=""
# fd 3 读清单，stdin 留给 ssh —— 用 stdin 读会被 ssh/ssh-copy-id 把剩余行吃掉，
# 结果只处理第一台（而且看不出来，因为统计数字本身也只算了一台）
while IFS= read -r line <&3 || [ -n "$line" ]; do
  case "$line" in \#*) continue ;; esac
  [ -n "${line//[[:space:]]/}" ] || continue
  # 按第一段空白切分，密码取剩余部分原样 —— 不用 eval：
  # 密码里的引号会让解析失败，而 $(...) 会被真的执行
  tgt=${line%%[[:space:]]*}
  pw=${line#"$tgt"}
  pw=${pw#"${pw%%[![:space:]]*}"}
  pw=${pw%"${pw##*[![:space:]]}"}
  case "$tgt" in *:*) t=${tgt%:*}; p=${tgt##*:} ;; *) t=$tgt; p=22 ;; esac
  n=$((n+1))
  printf '  [%2d/%d] %-38s ' "$n" "$total" "$tgt"

  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o PasswordAuthentication=no \
         -o StrictHostKeyChecking=accept-new -p "$p" "$t" true </dev/null 2>/dev/null; then
    echo "已免密"; skip=$((skip+1)); continue
  fi
  [ -n "$pw" ] || { echo "无密码（清单这行没填）"; nopw=$((nopw+1)); continue; }

  # sshpass -e 从环境变量读密码，不进 ps 的命令行（-p 会被同机其他用户看到）。
  # 强制密码认证：否则这台若已配过密钥，会用密钥登录成功而掩盖真实状态。
  if ! SSHPASS="$pw" sshpass -e ssh-copy-id \
       -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       -p "$p" "$t" </dev/null >/dev/null 2>&1; then
    echo "失败（密码/端口/服务端禁用密码登录）"; fail="$fail $tgt"; continue
  fi

  if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$p" "$t" true </dev/null 2>/dev/null; then
    echo "ok"; ok=$((ok+1)); continue
  fi

  # 下发成功却登不上，绝大多数是远程 ~/.ssh 权限过宽（sshd 会静默拒绝）。
  # 不猜，直接修最常见的那个，修不好再报出来
  SSHPASS="$pw" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -p "$p" "$t" \
    'chmod g-w,o-w ~ 2>/dev/null; chmod 700 ~/.ssh 2>/dev/null
     chmod 600 ~/.ssh/authorized_keys 2>/dev/null; restorecon -R ~/.ssh 2>/dev/null; true' \
    </dev/null >/dev/null 2>&1
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$p" "$t" true </dev/null 2>/dev/null; then
    echo "ok（修正了远程 .ssh 权限）"; ok=$((ok+1))
  else
    echo "可疑：下发成功但密钥登录仍失败"; fail="$fail $tgt"
  fi
done 3< "$LIST"

log ""
log "处理 $n / 清单 $total —— 新下发 $ok，已免密 $skip，缺密码 $nopw"
[ -n "$fail" ] && {
  log ""
  log "未成功:$fail"
  log "  多半是服务端 PubkeyAuthentication no —— 逐台处理并自动修复:"
  log "    opsget ops/setup-key-login <IP> <端口> <密码>"
  log "  或诊断: opsget ops/diag-key <ssh目标[:端口]> <密码>"
}
log ""
log "全部成功后销毁明文密码清单: shred -u $LIST"
exit 0
