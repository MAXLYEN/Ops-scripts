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
