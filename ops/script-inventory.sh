#!/usr/bin/env bash
# ops/script-inventory.sh — 盘点本机所有运维脚本及其来源
# VERSION: 1.0.0
#
# 回答三个问题：
#   1. 本机装了哪些脚本
#   2. 哪些来自云端仓库（有版本管理、可 opsget 更新）
#   3. 哪些只存在于本地（改坏了没有回退，换机器会丢）
#
# 判定依据：/var/lib/ops-scripts/installed.list 台账 + 云端 MANIFEST。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env

LEDGER=/var/lib/ops-scripts/installed.list
BASE="${OPS_REPO:-https://raw.githubusercontent.com/MAXLYEN/ops-scripts}/${OPS_REF:-main}"
SCAN_DIRS="${SCRIPT_SCAN_DIRS:-/usr/local/bin /usr/local/sbin /root/deploy /root}"

MAN=$(curl -fsSL --max-time 20 "$BASE/MANIFEST" 2>/dev/null)
[ -n "$MAN" ] && ok "已取到云端 MANIFEST" || warn "拉不到云端 MANIFEST，只按台账判定"

in_ledger()  { [ -f "$LEDGER" ] && grep -qxF "$1" "$LEDGER"; }
in_manifest() {
  [ -n "$MAN" ] || return 1
  printf '%s\n' "$MAN" | grep -qE "^[a-z]+/$(basename "$1" .sh)([[:space:]]|$)"
}
ver() { grep -m1 -oE '^#[[:space:]]*VERSION:[[:space:]]*[0-9.]+' "$1" 2>/dev/null | grep -oE '[0-9.]+'; }

CLOUD=0; LOCAL=0; ORPHAN=0
CLOUD_L=$(mktemp); LOCAL_L=$(mktemp); ORPHAN_L=$(mktemp)
trap 'rm -f "$CLOUD_L" "$LOCAL_L" "$ORPHAN_L"' EXIT

section "扫描"
for d in $SCAN_DIRS; do
  [ -d "$d" ] || continue
  echo "  $d"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    v=$(ver "$f"); v=${v:-—}
    line=$(printf '%-34s %-10s %8s' "$(basename "$f")" "$v" "$(stat -c %s "$f")")
    if in_ledger "$f"; then
      printf '%s  %s\n' "$line" "$f" >> "$CLOUD_L"; CLOUD=$((CLOUD+1))
    elif in_manifest "$f"; then
      printf '%s  %s\n' "$line" "$f" >> "$ORPHAN_L"; ORPHAN=$((ORPHAN+1))
    else
      printf '%s  %s\n' "$line" "$f" >> "$LOCAL_L"; LOCAL=$((LOCAL+1))
    fi
  done < <(find "$d" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null | sort)
done

section "① 来自云端仓库（$CLOUD 个）"
echo "   有版本管理，opsget 可更新，换机器重新拉即可"
if [ -s "$CLOUD_L" ]; then sort "$CLOUD_L" | sed 's/^/  /'; else echo "  (无)"; fi

section "② 名字在 MANIFEST 里但不在台账（$ORPHAN 个）"
echo "   多半是 opsget 1.1.0 之前装的，或手工放进去的同名文件"
if [ -s "$ORPHAN_L" ]; then
  sort "$ORPHAN_L" | sed 's/^/  /'
  echo
  echo "   处理：opsget <对应路径> 重新拉一次，就会进台账"
else
  echo "  (无)"
fi

section "③ 只存在于本地（$LOCAL 个）"
echo "   没有版本管理，改坏了没有回退，换机器会丢 —— 这一栏越短越好"
if [ -s "$LOCAL_L" ]; then sort "$LOCAL_L" | sed 's/^/  /'; else echo "  (无)"; fi

section "本地脚本里哪些是关键路径"
# 被 crontab 调用的本地脚本风险最高：静默失效不会有人发现
if [ -s "$LOCAL_L" ]; then
  CRON=$(crontab -l 2>/dev/null)
  while IFS= read -r line; do
    p=$(echo "$line" | awk '{print $NF}')
    n=$(basename "$p")
    if printf '%s' "$CRON" | grep -qF "$n"; then
      warn "$n 被 crontab 调用，却没有版本管理"
    fi
  done < "$LOCAL_L"
fi

section 汇总
printf '  云端管理 %s 个 ｜ 待纳管 %s 个 ｜ 纯本地 %s 个\n' "$CLOUD" "$ORPHAN" "$LOCAL"
cat <<EOF

  判断一个本地脚本该不该上云，问两件事：
    1. 它含不含拓扑信息（域名 / IP / 路径 / 库名 / 邮箱）？
       含 → 先把这些抽到 env.conf，脚本本身通用化，然后可以公开托管
    2. 它出错的后果是不是"静默"的？
       是 → 优先级最高。备份类脚本坏了不会有人喊，等要用时才发现
EOF
finish
