#!/usr/bin/env bash
# 02-nat-probe.sh — 入站可达性验证
# VERSION: 2.0.1
# 2.0.1: 头部加 ENV-REQUIRED 声明，供 opsget 按需预检配置项（脚本逻辑未变）
#
# curl ifconfig.me 只证明出网 SNAT 通，不证明外面能连进来。这一步验的是入站。
#
#   新机: 02-nat-probe.sh listen          在 PROBE_PORTS 上起监听
#   旧机: 02-nat-probe.sh probe           从外部探测 NEW_HOST_IP
#         02-nat-probe.sh probe <IP>      探测指定地址
#
# 判据：
#   全部可达且源 IP 是探测端的真实地址 → 全端口 1:1 DNAT，最理想
#   只有个别端口可达                   → 端口映射型 NAT，去控制台补映射（别漏 UDP）
#   全部超时                           → 先查安全组；仍不通说明没有独立入站 IP
# ENV-REQUIRED: PROBE_PORTS

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env
require_cmd python3
require_env PROBE_PORTS

MODE=${1:-}

case "$MODE" in
listen)
  log "监听端口: $PROBE_PORTS"
  log "已被占用的端口会跳过（那些服务本身就在听，照样能被探测到）"
  # shellcheck disable=SC2086
  python3 - $PROBE_PORTS <<'PY'
import socket, sys, threading
def serve(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", p)); s.listen(5)
    except OSError as e:
        print(f"[skip] {p} 无法监听: {e}"); return
    print(f"[ok]   {p} 监听中")
    while True:
        try:
            c, a = s.accept()
            c.sendall(f"OK-{p}\n".encode()); c.close()
            print(f"[hit]  {p} <- {a[0]}")
        except Exception:
            pass
for p in [int(x) for x in sys.argv[1:]]:
    threading.Thread(target=serve, args=(p,), daemon=True).start()
print("--- 保持本窗口，去另一台跑 probe；完事 Ctrl-C ---")
try:
    threading.Event().wait()
except KeyboardInterrupt:
    print("\n已停止")
PY
  ;;

probe)
  HOST=${2:-$NEW_HOST_IP}
  [ -n "$HOST" ] || die "没有目标地址：填参数或在配置里设 NEW_HOST_IP"
  log "探测 $HOST 的 $PROBE_PORTS"
  # shellcheck disable=SC2086
  python3 - "$HOST" $PROBE_PORTS <<'PY'
import socket, sys
host = sys.argv[1]; bad = 0
for p in [int(x) for x in sys.argv[2:]]:
    try:
        s = socket.create_connection((host, p), timeout=5)
        data = s.recv(32).decode(errors="replace").strip(); s.close()
        print(f"{p:>7}  可达    回包: {data or '(无，可能是已有服务在听)'}")
    except socket.timeout:
        print(f"{p:>7}  超时    (被丢包，多半是安全组或防火墙)"); bad += 1
    except ConnectionRefusedError:
        print(f"{p:>7}  拒绝    (NAT 通了但没服务在听)")
    except Exception as e:
        print(f"{p:>7}  失败    {e}"); bad += 1
print()
print("提示：回到 listen 那一端看它打印的来源 IP。若显示的是本机真实地址，")
print("      说明是 1:1 DNAT、源地址保留，fail2ban 才能封到真实攻击者。")
sys.exit(1 if bad else 0)
PY
  ;;

*)
  echo "用法: $(basename "$0") listen | probe [IP]"
  exit 1 ;;
esac
