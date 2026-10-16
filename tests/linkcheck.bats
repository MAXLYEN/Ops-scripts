#!/usr/bin/env bats
# tests/linkcheck.bats — 真跑 ops/newapi-linkcheck（不是桩）。
# curl、systemctl、sleep 换成假实现：探测内层 / 外层时按 $L/codes-<local|public> 逐行给出 HTTP 码（没写就是 200），
# 心跳地址的请求记进 $L/hb.log；systemctl 与 sleep 只记录调用。
# 能证明：不通先重探、重探恢复不报失败、两次都不通才报 /fail、内层重探仍不通才重启隧道。
# 证明不了：真实隧道、nginx 与 Healthchecks 的行为。

L=/tmp/lc
FB=/tmp/lcbin

setup() {
  rm -rf "$L" "$FB" /etc/ops-scripts
  mkdir -p "$L" "$FB" /etc/ops-scripts
  printf '%s\n' 'NEWAPI_TUNNEL_UNIT="newapi-tunnel.service"' 'NEWAPI_LOCAL_URL="http://127.0.0.1:3001/api/status"' \
    'NEWAPI_PUBLIC_URL="https://api.example.com/api/status"' 'NEWAPI_LINK_HEARTBEAT_URL="https://hc.example/ping/lc"' \
    "NEWAPI_LINKCHECK_LOG=\"$L/link.log\"" "NEWAPI_RESTART_STATE=\"$L/restarts\"" \
    "ALERT_FALLBACK_FILE=\"$L/alerts.log\"" > /etc/ops-scripts/env.conf
  cat > "$FB/curl" <<'EOF'
#!/bin/bash
for a; do u=$a; done                       # 最后一个参数是地址
case "$u" in
  https://hc.example/*) echo "$u" >> /tmp/lc/hb.log; exit 0 ;;
  http://127.0.0.1:*) f=/tmp/lc/codes-local ;;
  *) f=/tmp/lc/codes-public ;;
esac
c=200
if [ -s "$f" ]; then c=$(head -1 "$f"); sed -i 1d "$f"; fi
printf '%s' "$c"
EOF
  printf '#!/bin/sh\necho "systemctl $*" >> /tmp/lc/systemctl.log\n' > "$FB/systemctl"
  printf '#!/bin/sh\necho "$*" >> /tmp/lc/sleep.log\n' > "$FB/sleep"
  chmod 755 "$FB"/*
  export PATH="$FB:$PATH"
}

teardown() { rm -rf "$L" "$FB"; }

check() { run bash /src/ops/newapi-linkcheck.sh; }
hb() { cat "$L/hb.log" 2>/dev/null; }

@test "都通：报成功心跳，不重探、不重启" {
  check
  [ "$status" -eq 0 ]
  [ "$(hb)" = "https://hc.example/ping/lc" ]
  [ ! -e "$L/sleep.log" ] && [ ! -e "$L/systemctl.log" ]
  grep -q '正常 内层=200 外层=200' "$L/link.log"
}

@test "外层抖一下：隔 20 秒重探恢复，不报 /fail，日志记一行抖动" {
  printf '000\n' > "$L/codes-public"
  check
  [ "$status" -eq 0 ]
  [ "$(hb)" = "https://hc.example/ping/lc" ]
  grep -qx 20 "$L/sleep.log"
  grep -q '外层 第一次探测不通，20 秒后重探恢复' "$L/link.log"
}

@test "外层两次都不通：报 /fail，不重启隧道" {
  printf '502\n502\n' > "$L/codes-public"
  check
  [ "$status" -eq 1 ]
  [ "$(hb)" = "https://hc.example/ping/lc/fail" ]
  [ ! -e "$L/systemctl.log" ]
  grep -q '内层通但外层不通.*外层=502' "$L/link.log"
}

@test "内层抖一下：重探恢复，不重启隧道" {
  printf '000\n' > "$L/codes-local"
  check
  [ "$status" -eq 0 ]
  [ ! -e "$L/systemctl.log" ]
  grep -q '内层 第一次探测不通' "$L/link.log"
}

@test "内层重探仍不通：重启隧道，恢复后照常报成功；重探间隔可配" {
  printf '000\n000\n' > "$L/codes-local"
  echo 'NEWAPI_LINK_RETRY_WAIT="5"' >> /etc/ops-scripts/env.conf
  check
  [ "$status" -eq 0 ]
  grep -qx 'systemctl restart newapi-tunnel.service' "$L/systemctl.log"
  grep -qx 5 "$L/sleep.log"
  [ "$(hb)" = "https://hc.example/ping/lc" ]
  grep -q '正常（本轮重启过隧道）' "$L/link.log"
}
