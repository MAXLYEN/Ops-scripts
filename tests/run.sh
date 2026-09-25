#!/usr/bin/env bash
# tests/run.sh — 一次跑完全部测试：静态检查 + 一次性容器里的端到端测试
# VERSION: 1.0.0
# 1.0.0: 首版。静态检查同 CI；端到端在 Debian 12 容器里跑 opsget 与 opsbox，被调用的脚本用桩代替。
# 用法: tests/run.sh [--lint | --e2e] [bats 用例名过滤（正则）]
# 需要 Linux + docker（开发机上在 WSL 里跑，见仓库 CLAUDE.md）。

set -o pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=ops-scripts-test
DO_LINT=1 DO_E2E=1 FILTER=""
case "${1:-}" in
  --lint) DO_E2E=0; shift ;;
  --e2e)  DO_LINT=0; shift ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac
FILTER=${1:-}

LINT_RC=- E2E_RC=-
if [ "$DO_LINT" -eq 1 ]; then
  printf '\n════ 静态检查 ════\n'
  bash "$ROOT/tests/lint.sh"; LINT_RC=$?
fi

if [ "$DO_E2E" -eq 1 ]; then
  printf '\n════ 端到端（容器） ════\n'
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "✗ docker 不可用：端到端测试没有运行"; E2E_RC=1
  elif ! docker build -q -t "$IMAGE" "$ROOT/tests" >/dev/null; then
    echo "✗ 测试镜像构建失败"; E2E_RC=1
  else
    # --hostname 固定下来，测试里「输入主机名确认」才有确定的答案
    docker run --rm --hostname ops-test -v "$ROOT":/src:ro "$IMAGE" \
      bats ${FILTER:+--filter "$FILTER"} /src/tests
    E2E_RC=$?
  fi
fi

printf '\n════ 汇总 ════\n'
show() { case "$2" in -) printf '  %s  未运行\n' "$1" ;; 0) printf '  %s  ✓ 通过\n' "$1" ;; *) printf '  %s  ✗ 失败\n' "$1" ;; esac; }
show "静态检查" "$LINT_RC"
show "端到端  " "$E2E_RC"
[ "$LINT_RC" != - ] && [ "$LINT_RC" -ne 0 ] && exit 1
[ "$E2E_RC" != - ] && [ "$E2E_RC" -ne 0 ] && exit 1
exit 0
