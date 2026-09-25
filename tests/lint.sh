#!/usr/bin/env bash
# tests/lint.sh — 静态检查：换行符、语法、shellcheck、版本头，以及几处「要人记得同步」的清单
# VERSION: 1.0.0
# 1.0.0: 从 CI 工作流里搬出来，本地与 CI 跑同一份，检查项不再两处维护。
# 只读检查，不执行任何脚本。在仓库任意位置运行均可；有问题时以 1 退出。

set -o pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
# WSL 下以 root 读 Windows 盘上的仓库，git 会因属主不同拒绝操作
g() { git -c safe.directory="$ROOT" "$@"; }

FAIL=0 BAD=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
err() {  # err <文件或空> <消息>
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error%s::%s\n' "${1:+ file=$1}" "$2"
  else
    printf '  ✗ %s%s\n' "${1:+$1: }" "$2"
  fi
  FAIL=1
}
check() {  # check <名称> <函数>：跑一项并打印结果
  FAIL=0
  "$2"
  if [ "$FAIL" -eq 0 ]; then printf '✓ %s\n' "$1"; else printf '✗ %s\n' "$1"; BAD=1; fi
}

{ g ls-files '*.sh'; echo bin/opsget; echo bin/opsbox; } > "$TMP/scripts"

# CRLF 进仓库，脚本在 Linux 上直接报 $'\r': command not found。
# 用 git 判断索引里的换行符（i/crlf、i/mixed），不受检出方式影响
lf_only() {
  local f
  for f in $(g ls-files --eol | awk '$1 ~ /^i\/(crlf|mixed)$/ {print $NF}'); do
    err "$f" "含 CRLF"
  done
}

# 按 shebang 选解释器：openclash/ 在路由器上用 sh 跑，不能用 bash 语法
syntax() {
  local f
  while read -r f; do
    case "$(head -1 "$f")" in
      *bash*) bash -n "$f" ;;
      *)      sh -n "$f" ;;
    esac || err "$f" "语法错误"
  done < "$TMP/scripts"
}

# 门槛为 warning。仓库根目录的 .shellcheckrc 关闭了 SC1090（source 运行时文件）；
# 其余确属有意的写法在行内用 disable 注释并写明理由，不要整条关掉。
shellcheck_all() {
  command -v shellcheck >/dev/null 2>&1 || { err "" "没装 shellcheck"; return; }
  xargs shellcheck -S warning < "$TMP/scripts" || err "" "shellcheck 有 warning 以上的问题（见上）"
}

version_head() {
  local f
  while read -r f; do
    grep -q '^# VERSION:' "$f" || err "$f" "缺少 # VERSION: 头"
  done < "$TMP/scripts"
}

# MANIFEST 是 opsget -l 的数据源；漏列的脚本用户看不到，多列的照着敲会 404。
# lib/ 是公共库、tests/ 是测试，都不经 opsget 分发
manifest() {
  grep -oE '^[a-z]+/[A-Za-z0-9_-]+' MANIFEST | sort > "$TMP/manifest"
  g ls-files '*.sh' | grep -vE '^(lib|tests)/' | sed 's/\.sh$//' | sort > "$TMP/files"
  diff -u --label MANIFEST --label 实际文件 "$TMP/manifest" "$TMP/files" \
    || err MANIFEST "与实际脚本不一致（见上面的 diff）"
}

# opsbox 的登记表：每个 MANIFEST 脚本要么登记进菜单，要么写进 MENU-EXCLUDE 并说明原因；
# 登记的路径必须真实存在。新增脚本忘了归类，这里会拦下
menu() {
  local x
  grep -oE '^[a-z]+/[A-Za-z0-9_-]+' MANIFEST | sort -u > "$TMP/man"
  sed -n "/^ITEMS=\$(cat <<'EOF'/,/^EOF/p" bin/opsbox | awk -F'|' 'NF >= 7 { print $3 }' \
    | tr ' ' '\n' | grep -v '^-\?$' | sort -u > "$TMP/menu"
  sed -n 's/^# MENU-EXCLUDE:[[:space:]]*\([^[:space:]]*\).*/\1/p' bin/opsbox | sort -u > "$TMP/excl"
  [ -s "$TMP/menu" ] || { err bin/opsbox "没解析到登记表"; return; }
  for x in $(comm -23 "$TMP/menu" "$TMP/man"); do err bin/opsbox "登记了 MANIFEST 里没有的路径: $x"; done
  for x in $(comm -12 "$TMP/menu" "$TMP/excl"); do err bin/opsbox "既登记又排除: $x"; done
  for x in $(sort -u "$TMP/menu" "$TMP/excl" | comm -13 - "$TMP/man"); do
    err bin/opsbox "没归类（登记进菜单或写 MENU-EXCLUDE）: $x"
  done
}

# 声明了模板里没有的键，opsget -c 就补不出来，脚本运行时必然 die
env_keys() {
  local T=config/env.example.conf f k a
  grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Z_][A-Z0-9_]*=' "$T" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort -u > "$TMP/tplkeys"
  while read -r f; do
    for k in $(sed -n 's/^#[[:space:]]*ENV-REQUIRED:[[:space:]]*//p' "$f"); do
      for a in ${k//|/ }; do
        grep -qx "$a" "$TMP/tplkeys" || err "$f" "$a 不在 $T 里"
      done
    done
  done < "$TMP/scripts"
}

printf '共 %s 个脚本\n' "$(wc -l < "$TMP/scripts")"
check "换行符都是 LF" lf_only
check "语法" syntax
check "shellcheck" shellcheck_all
check "每个脚本都有 VERSION 头" version_head
check "MANIFEST 与文件一致" manifest
check "opsbox 菜单与 MANIFEST 一致" menu
check "ENV-REQUIRED 的键都在配置模板里" env_keys
exit "$BAD"
