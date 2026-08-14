#!/usr/bin/env bash
# ops/compare-backup-content.sh — 比对两个备份包的内容清单
# VERSION: 1.0.0
#
# 改动备份脚本后验证等价性用：文件路径列表必须一致，只允许你预期的那几项差异。
# 自动识别两种结构：包内直接铺开、或内容在 payload.tar.gz 里。
#
# 用法: compare-backup-content.sh <旧包> <新包>
#       compare-backup-content.sh <目录>        取该目录下最新的两个包比

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_cmd 7z

PASS_FILE="${VW_PASS_FILE:-$(echo $BACKUP_PASS_FILES | awk '{print $1}')}"
[ -r "$PASS_FILE" ] || die "读不到密码文件: $PASS_FILE"
PASS=$(head -1 "$PASS_FILE")

if [ $# -eq 1 ] && [ -d "$1" ]; then
  A=$(ls -t "$1"/*.7z 2>/dev/null | sed -n 2p)
  B=$(ls -t "$1"/*.7z 2>/dev/null | head -1)
  [ -n "$A" ] && [ -n "$B" ] || die "$1 下不足两个包"
elif [ $# -eq 2 ]; then
  A=$1; B=$2
else
  die "用法: $(basename "$0") <旧包> <新包> | <目录>"
fi

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT

listing() {  # $1=包路径 $2=输出文件
  local d="$TD/$(basename "$1" .7z)"
  mkdir -p "$d"
  # </dev/null 必需：-mhe=on 的包密码不对会交互式等输入
  7z x -p"$PASS" -o"$d" "$1" >/dev/null 2>&1 </dev/null || { echo "解包失败: $1" >&2; return 1; }
  if [ -f "$d/payload.tar.gz" ]; then
    { (cd "$d" && ls -1); tar -tzf "$d/payload.tar.gz" | sed 's|^\./||'; } \
      | grep -v '^payload.tar.gz$' | grep -v '/$' | sort -u > "$2"
  else
    (cd "$d" && find . -type f | sed 's|^\./||') | sort > "$2"
  fi
}

section "对比对象"
printf '  旧: %-52s %s\n' "$(basename "$A")" "$(human "$A")"
printf '  新: %-52s %s\n' "$(basename "$B")" "$(human "$B")"

listing "$A" "$TD/before.txt" || exit 1
listing "$B" "$TD/after.txt"  || exit 1

section "文件数"
printf '  旧 %s 个 ｜ 新 %s 个\n' "$(wc -l < "$TD/before.txt")" "$(wc -l < "$TD/after.txt")"

section "差异"
if diff -u "$TD/before.txt" "$TD/after.txt" | tail -n +3 | grep -E '^[+-]' ; then
  echo
  echo "  以 - 开头 = 新版少了这个文件（要解释清楚为什么）"
  echo "  以 + 开头 = 新版多了这个文件"
else
  ok "文件清单完全一致"
fi

section "体积对照（前 15 项差异最大的）"
python3 - "$A" "$B" "$TD" <<'PY' 2>/dev/null || true
import os, sys
a, b, td = sys.argv[1], sys.argv[2], sys.argv[3]
def sizes(arch):
    d = os.path.join(td, os.path.basename(arch)[:-3]); m = {}
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            m[os.path.relpath(p, d)] = os.path.getsize(p)
    return m
A, B = sizes(a), sizes(b)
rows = []
for k in sorted(set(A) | set(B)):
    x, y = A.get(k, 0), B.get(k, 0)
    if x != y: rows.append((abs(y - x), k, x, y))
rows.sort(reverse=True)
if not rows: print("  顶层文件体积无差异")
for _, k, x, y in rows[:15]:
    print(f"  {k:<44} {x:>10} -> {y:>10}")
PY
echo
echo "  只有体积差、清单一致 = 等价（差的是当天的数据量）"
finish
