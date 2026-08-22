#!/usr/bin/env bash
# ops/compare-backup-content.sh — 比对两个备份包的内容清单
# VERSION: 1.0.1
# 1.0.1: ① 密码键跟上 backup/*.sh 2.3.x：BACKUP_PASS_FILE 优先，VW_PASS_FILE 回落。
#           原来只认 VW_PASS_FILE，旧键一旦清掉就会掉到 BACKUP_PASS_FILES（复数，
#           是另一个键——密码文件**列表**）取第一项，多半是别的密码文件，
#           于是报「解包失败」，人会以为是备份包坏了，而不是脚本取错了密码。
#        ② 补 -h/--help；原来给任何非法参数都只吐一行 die，看不到用法。
#
# 改动备份脚本后验证等价性用：文件路径列表必须一致，只允许你预期的那几项差异。
# 自动识别两种结构：包内直接铺开、或内容在 payload.tar.gz 里。
#
# 用法: compare-backup-content.sh <旧包> <新包>    顺序是旧在前、新在后
#       compare-backup-content.sh <目录>          取该目录下最新的两个包比
#       compare-backup-content.sh -h
#
# ENV-REQUIRED: BACKUP_PASS_FILE|VW_PASS_FILE

usage() {
  cat <<'USAGE'
compare-backup-content.sh — 比对两个备份包的内容清单

  compare-backup-content.sh <旧包> <新包>    顺序是旧在前、新在后
  compare-backup-content.sh <目录>          取该目录下最新的两个包比

改动备份脚本后验证等价性用：文件路径列表必须一致，只允许你预期的那几项差异。
自动识别两种结构：包内直接铺开、或内容在 payload.tar.gz 里。
密码取自 env.conf 的 BACKUP_PASS_FILE（旧机器回落到 VW_PASS_FILE）。
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_cmd 7z

# 与 backup/vw-fullbackup.sh、backup/xboard-fullbackup.sh 2.3.x 保持同一套取值顺序。
# 三者必须一致 —— 比对工具用错密码，得到的结论是「包坏了」，方向完全反了。
PASS_FILE="${BACKUP_PASS_FILE:-${VW_PASS_FILE:-}}"
# 最后才回落到复数的列表键，并且明说取的是哪一项，免得静默取错
if [ -z "$PASS_FILE" ] && [ -n "${BACKUP_PASS_FILES:-}" ]; then
  PASS_FILE=$(echo $BACKUP_PASS_FILES | awk '{print $1}')
  warn "BACKUP_PASS_FILE / VW_PASS_FILE 都为空，回落到 BACKUP_PASS_FILES 的第一项: $PASS_FILE"
fi
[ -n "$PASS_FILE" ] || die "没有可用的密码文件：请在 env.conf 填 BACKUP_PASS_FILE"
[ -r "$PASS_FILE" ] || die "读不到密码文件: $PASS_FILE"
PASS=$(head -1 "$PASS_FILE")

if [ $# -eq 1 ] && [ -d "$1" ]; then
  A=$(ls -t "$1"/*.7z 2>/dev/null | sed -n 2p)
  B=$(ls -t "$1"/*.7z 2>/dev/null | head -1)
  [ -n "$A" ] && [ -n "$B" ] || die "$1 下不足两个包"
elif [ $# -eq 2 ]; then
  A=$1; B=$2
else
  usage; die "参数不对：需要两个包，或一个目录"
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
