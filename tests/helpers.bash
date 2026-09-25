# tests/helpers.bash — bats 公共设置：模拟仓库、本地 HTTP 服务、脚本桩、伪终端驱动
# 只在 tests/Dockerfile 构建的一次性容器里运行（tests/run.sh 负责启动），会改动 /usr/local 与 /etc。
# shellcheck shell=bash
# shellcheck disable=SC2154  # output、status 由 bats 的 run 设置

SRC=${SRC:-/src}                 # 只读挂载的仓库（含未提交的改动）
BASE_DIR=/tmp/mock-base          # 每个测试文件构建一次的模拟仓库模板
MOCK=/tmp/mock                   # HTTP 根目录：$MOCK/<ref>/<仓库路径>，每个测试重置
PORT=8765
CALLS=/tmp/calls                 # 桩脚本记录自己被怎样调用，一行一次
OLD_TAG=v2026.09.25              # 没有 opsbox 的旧版本，测「固定在旧 tag」
export OPS_REPO="http://127.0.0.1:$PORT"

# ── 每个测试文件一次 ───────────────────────────────────────
mock_build() {  # 模板：main = 当前工作区；旧 tag 从 git 里取（CI 浅克隆没有 tag 时跳过）
  rm -rf "$BASE_DIR"; mkdir -p "$BASE_DIR/main"
  tar -C "$SRC" --exclude=.git -cf - . | tar -C "$BASE_DIR/main" -xf -
  if git -c safe.directory='*' -C "$SRC" rev-parse -q --verify "refs/tags/$OLD_TAG" >/dev/null; then
    mkdir -p "$BASE_DIR/$OLD_TAG"
    git -c safe.directory='*' -C "$SRC" archive "$OLD_TAG" | tar -C "$BASE_DIR/$OLD_TAG" -xf -
  fi
}
http_start() {
  mkdir -p "$MOCK"
  python3 -m http.server "$PORT" -b 127.0.0.1 -d "$MOCK" >/tmp/http.log 2>&1 &
  echo $! > /tmp/http.pid
  local _
  for _ in $(seq 50); do curl -fs "http://127.0.0.1:$PORT/" >/dev/null && return 0; sleep 0.1; done
  echo "HTTP 服务没起来" >&2; return 1
}
http_stop() { [ -f /tmp/http.pid ] && kill "$(cat /tmp/http.pid)" 2>/dev/null; rm -f /tmp/http.pid; }

# ── 每个测试一次：回到「只装了 opsget 的新机」 ──────────────
reset_host() {
  rm -rf /usr/local/bin/* /usr/local/lib/ops-common.sh /etc/ops-scripts /var/lib/ops-scripts \
         /var/run/reboot-required "$CALLS" /tmp/*.lock /root/fwstate_*
  crontab -r 2>/dev/null || true
  rm -rf "${MOCK:?}"/*; cp -a "$BASE_DIR"/. "$MOCK"/
  install -m 755 "$MOCK/main/bin/opsget" /usr/local/bin/opsget
  unset OPS_REF EDITOR
  export NO_COLOR=1 LC_ALL=C.UTF-8 TERM=xterm
}

# ── 桩脚本 ──────────────────────────────────────────────────
_stub_body() {  # _stub_body <标签> <退出码> [ENV-REQUIRED 键...]
  local tag=$1 rc=$2; shift 2
  printf '#!/usr/bin/env bash\n# VERSION: 0.0.0-stub\n'
  [ $# -gt 0 ] && printf '# ENV-REQUIRED: %s\n' "$*"
  printf 'echo "%s $*" | sed "s/ *$//" >> %s\n' "$tag" "$CALLS"
  printf 'echo "[桩] %s $*"\nexit %s\n' "$tag" "$rc"
}
stub() {  # stub <仓库路径> [退出码] [ENV-REQUIRED 键...]：把模拟仓库里的脚本换成桩
  local p=$1 rc=${2:-0}; shift; [ $# -gt 0 ] && shift
  _stub_body "$p" "$rc" "$@" > "$MOCK/main/$p.sh"
}
stub_loadenv() {  # stub_loadenv <仓库路径> [退出码]：像多数 ops 脚本那样先 load_env（没有 env.conf 就退出）再干活
  local p=$1 rc=${2:-0}
  { printf '#!/usr/bin/env bash\n# VERSION: 0.0.0-stub\n'
    printf '. /usr/local/lib/ops-common.sh\nload_env\n'
    _stub_body "$p" "$rc" | tail -n +3
  } > "$MOCK/main/$p.sh"
}
local_stub() {  # local_stub <脚本名> [退出码]：直接放一个已安装的本地脚本（备份类不经 opsget）
  _stub_body "local/$1" "${2:-0}" > "/usr/local/bin/$1.sh"; chmod 755 "/usr/local/bin/$1.sh"
}
calls() { cat "$CALLS" 2>/dev/null; }

# ── 伪终端驱动与断言 ────────────────────────────────────────
drive() {  # drive <命令> [输入行...]：在伪终端里跑，结果放在 $output / $status
  run timeout 120 python3 "$SRC/tests/drive.py" --idle 0.3 "$@"
  # 按键没用完 = 用例写的步骤和界面对不上，只是碰巧通过；当失败处理
  if grep -q '^\[drive\] 还有' <<<"$output"; then
    printf '%s\n──── 输出末尾 ────\n%s\n' "$(grep '^\[drive\] 还有' <<<"$output")" "$(tail -n 30 <<<"$output")" >&2
    return 1
  fi
}
has() {  # has <文本>：$output 里必须有
  grep -qF -- "$1" <<<"$output" && return 0
  printf '输出里没有: %s\n──── 输出末尾 ────\n%s\n' "$1" "$(tail -n 40 <<<"$output")" >&2
  return 1
}
lacks() {  # lacks <文本>：$output 里不能有
  grep -qF -- "$1" <<<"$output" || return 0
  printf '输出里不该有: %s\n' "$1" >&2
  return 1
}
calls_are() {  # calls_are <行...>：桩的调用记录必须逐行相等
  local want got
  want=$(printf '%s\n' "$@"); got=$(calls)
  [ "$got" = "$want" ] && return 0
  printf '调用记录不符\n期望:\n%s\n实际:\n%s\n' "$want" "$got" >&2
  return 1
}
