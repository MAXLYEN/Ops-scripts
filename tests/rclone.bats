#!/usr/bin/env bats
# tests/rclone.bats — lib/common.sh 的 ensure_rclone：缺失或太旧时装官方版，按 SHA256SUMS 校验。
# 用 file:// 目录模拟 downloads.rclone.org（RCLONE_DL_BASE），不联网。
# 能证明：版本判断、下载地址拼法、校验不过就不装、够新就不动。证明不了：真实官网的目录结构（真机演练验证过）。

load helpers

DL=/tmp/rclone-dl

setup() {
  rm -rf "$DL" /usr/local/bin/rclone
  mkdir -p "$DL"
  export RCLONE_DL_BASE="file://$DL"
}

arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; esac; }

fake_rclone() {  # fake_rclone <版本串>：已装的 rclone
  printf '#!/bin/sh\necho "rclone %s"\n' "$1" > /usr/local/bin/rclone
  chmod 755 /usr/local/bin/rclone
}

release() {  # release <版本> [bad]：在模拟官网放一个版本的 zip 与 SHA256SUMS；bad = 校验和写错
  local v=$1 d
  d="rclone-$v-linux-$(arch)"
  mkdir -p "$DL/$v/src/$d"
  printf '#!/bin/sh\necho "rclone %s"\n' "$v" > "$DL/$v/src/$d/rclone"
  (cd "$DL/$v/src" && python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2]); z.close()' "../$d.zip" "$d/rclone")
  if [ "${2:-}" = bad ]; then
    printf '%064d  %s\n' 0 "$d.zip" > "$DL/$v/SHA256SUMS"
  else
    (cd "$DL/$v" && sha256sum "$d.zip" > SHA256SUMS)
  fi
  echo "rclone $v" > "$DL/version.txt"
}

run_ensure() { run bash -c ". $SRC/lib/common.sh; ensure_rclone; echo \"rc=\$?\"; rclone version 2>/dev/null | head -1"; }

@test "rclone：没装时装官方版到 /usr/local/bin" {
  release v1.80.0
  run_ensure
  [[ $output == *"rc=0"* ]]
  [[ $output == *"已装到 /usr/local/bin/rclone"* ]]
  [[ $output == *"rclone v1.80.0" ]]
  [ -x /usr/local/bin/rclone ]
}

@test "rclone：发行版的旧版（1.60.1-DEV）会被换成官方版" {
  fake_rclone v1.60.1-DEV
  release v1.80.0
  run_ensure
  [[ $output == *"rclone 1.60.1，低于 1.75.0"* ]]
  [[ $output == *"rc=0"* ]]
  [[ $output == *"rclone v1.80.0" ]]
}

@test "rclone：版本够新就不动，也不去官网取版本号" {
  fake_rclone v1.75.0
  rm -f "$DL/version.txt"
  run_ensure
  [[ $output == *"rc=0"* ]]
  [[ $output != *"装官方版"* ]]
  [[ $output == *"rclone v1.75.0" ]]
}

@test "rclone：校验和对不上就不装，原来的留着" {
  fake_rclone v1.60.1
  release v1.80.0 bad
  run_ensure
  [[ $output == *"rc=1"* ]]
  [[ $output == *"SHA256 校验"* ]]
  [[ $output == *"rclone v1.60.1" ]]
}

@test "rclone：RCLONE_MIN_VERSION 可以调低" {
  fake_rclone v1.60.1
  rm -f "$DL/version.txt"
  RCLONE_MIN_VERSION=1.60.0 run_ensure
  [[ $output == *"rc=0"* ]]
  [[ $output == *"rclone v1.60.1" ]]
}
