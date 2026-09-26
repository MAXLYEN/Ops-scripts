#!/usr/bin/env bats
# tests/opsget.bats — opsget 端到端：从本地模拟仓库拉取、安装、版本固定、配置预检、菜单入口

load helpers

setup_file() { mock_build; http_start; }
teardown_file() { http_stop; }
setup() { reset_host; }

@test "-u 安装引导器、公共库和菜单，并记进台账" {
  run opsget -u
  [ "$status" -eq 0 ]
  [ -x /usr/local/bin/opsbox ]
  [ -f /usr/local/lib/ops-common.sh ]
  grep -qx /usr/local/bin/opsbox /var/lib/ops-scripts/installed.list
}

@test "固定在没有菜单的旧 tag：-u 跳过菜单但不失败" {
  [ -d "$MOCK/$OLD_TAG" ] || skip "仓库里取不到 $OLD_TAG（浅克隆）"
  mkdir -p /etc/ops-scripts; echo "$OLD_TAG" > /etc/ops-scripts/ref
  run opsget -u
  [ "$status" -eq 0 ]
  has "没有 opsbox 菜单"
  [ ! -e /usr/local/bin/opsbox ]
}

@test "非终端下不带参数只打印帮助，不装菜单" {
  run opsget </dev/null
  [ "$status" -eq 0 ]
  has "opsget — ops-scripts 引导器"
  [ ! -e /usr/local/bin/opsbox ]
}

@test "终端里不带参数：没装菜单先装，然后打开" {
  drive opsget q
  [ "$status" -eq 0 ]
  has "运维工具箱"
  [ -x /usr/local/bin/opsbox ]
}

@test "终端里 -h 仍然只打印帮助" {
  drive "opsget -h"
  has "opsget — ops-scripts 引导器"
  lacks "运维工具箱"
}

@test "缺配置时拒绝执行，脚本不会被调用" {
  stub ops/ssl-audit 0 PANEL_CERT_DIR
  run opsget ops/ssl-audit
  [ "$status" -eq 1 ]
  has "配置未就绪"
  [ -z "$(calls)" ]
}

@test "配置齐全时执行并透传参数与退出码" {
  stub ops/cleanup-tidy 3
  run opsget ops/cleanup-tidy --apply
  [ "$status" -eq 3 ]
  calls_are "ops/cleanup-tidy --apply"
}

@test "--pin 拒绝 main，非法路径被拒" {
  run opsget --pin main
  [ "$status" -eq 1 ]
  run opsget ../etc/passwd
  [ "$status" -eq 1 ]
  has "路径不合法"
}

# 多数 ops 脚本没声明配置键，但开头 load_env 要求 env.conf 存在。
# 预检要如实反映这一点：否则会放行一个必然立刻退出的脚本（真机上发现的问题）
@test "会读 env.conf 的脚本：没有 env.conf 时预检拦下" {
  stub_loadenv ops/script-inventory
  run opsget ops/script-inventory
  [ "$status" -eq 1 ]
  has "需要 /etc/ops-scripts/env.conf"
  has "opsget -c ops/script-inventory"
  [ -z "$(calls)" ]
}

@test "会读 env.conf 的脚本：-e 说明要有 env.conf 文件" {
  stub_loadenv ops/script-inventory
  run opsget -e ops/script-inventory
  [ "$status" -eq 1 ]
  has "不需要配置键"
  has "还没有 /etc/ops-scripts/env.conf"
}

@test "会读 env.conf 的脚本：-c 建出空的 env.conf，之后能执行" {
  stub_loadenv ops/script-inventory
  run opsget -c ops/script-inventory
  [ "$status" -eq 0 ]
  [ "$(stat -c %a /etc/ops-scripts/env.conf)" = 600 ]
  run opsget ops/script-inventory
  [ "$status" -eq 0 ]
  calls_are "ops/script-inventory"
}

@test "-c 不带参数：已装脚本不要键但要文件时，也建出 env.conf" {
  stub_loadenv ops/script-inventory
  opsget -i ops/script-inventory >/dev/null
  run opsget -c
  [ "$status" -eq 0 ]
  [ -f /etc/ops-scripts/env.conf ]
}

@test "真正裸机可跑的脚本：-e 仍说不需要任何配置" {
  stub vpsscore/probe 0
  run opsget -e vpsscore/probe
  [ "$status" -eq 0 ]
  has "不需要任何配置"
}

# ── 已装脚本和固定版本对比（生产机上 22 个脚本落后却没人知道） ──
ver_of() { sed -n 's/^# VERSION: //p' "$1" | head -1; }

@test "--outdated：列出和固定版本不一致的已装脚本，一致的不列" {
  opsget -i ops/save-fw >/dev/null
  opsget -i ops/ssl-audit >/dev/null
  local lv; lv=$(ver_of /usr/local/bin/ssl-audit.sh)
  stub ops/ssl-audit 0                  # 仓库里出了新版（桩的版本是 0.0.0-stub）
  run opsget --outdated
  [ "$status" -eq 0 ]
  grep -qx "ops/ssl-audit	$lv	0.0.0-stub" <<<"$output"
  lacks "ops/save-fw"
}

@test "--outdated：都一致时明确说，不留空" {
  opsget -i ops/save-fw >/dev/null
  run opsget --outdated
  [ "$status" -eq 0 ]
  has "都和 main 一致"
}

@test "--outdated：工具箱本身（引导器、公共库、菜单）也一起对比" {
  opsget -u >/dev/null
  echo '# 新版本' >> "$MOCK/main/bin/opsbox"
  run opsget --outdated
  grep -q "^bin/opsbox	" <<<"$output"
  lacks "bin/opsget"
}
