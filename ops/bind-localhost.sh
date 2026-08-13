#!/usr/bin/env bash
# ops/bind-localhost.sh — 把容器端口从 0.0.0.0 收到 127.0.0.1
# VERSION: 2.0.0
#
# 为什么必须做：Docker 会自己往 iptables 里插规则，**绕过 ufw**。
# 也就是说 0.0.0.0 绑定的容器端口，即使 ufw 里没放行，也是对全网敞开的。
# 只该走反向代理的服务不应该直接暴露。
#
# 端口映射不能热改，容器要重建。数据在 bind mount 里，不受影响。
#
# 用法: bind-localhost.sh            扫描并生成新的 run 命令（不执行）
#       bind-localhost.sh --apply    生成并执行

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_cmd docker python3
docker_ready || die "docker 不可用"

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
OUTDIR="${RESTORE_CMD_DIR:-/root/restore_cmds}/rebind"
mkdir -p "$OUTDIR"; chmod 700 "$OUTDIR"

section "当前对外暴露的容器端口"
EXPOSED=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' || true)
if [ -z "$EXPOSED" ]; then
  ok "没有 0.0.0.0 绑定的容器端口，无需处理"
  exit 0
fi
echo "$EXPOSED" | sed 's/^/  /'

section "生成收紧后的启动命令"
echo "$EXPOSED" | awk -F'\t' '{print $1}' | while read -r name; do
  [ -n "$name" ] || continue
  # compose 管理的容器不能这样重建，要改 compose 文件
  proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null)
  if [ -n "$proj" ] && [ "$proj" != "<no value>" ]; then
    wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name")
    warn "$name 由 compose 管理（项目 $proj，目录 $wd）—— 请改 compose 文件里的 ports 段，形如 \"127.0.0.1:主机端口:容器端口\""
    continue
  fi
  docker inspect "$name" > "$OUTDIR/$name.json"
  python3 - "$OUTDIR/$name.json" "$OUTDIR/$name.sh" <<'PY'
import json, shlex, subprocess, sys, os
d = json.load(open(sys.argv[1]))[0]
name = d["Name"].lstrip("/"); cfg, hc = d.get("Config",{}), d.get("HostConfig",{})
img = cfg.get("Image")
def image_env(i):
    try:
        o = subprocess.run(["docker","image","inspect",i,"--format","{{json .Config.Env}}"],
                           capture_output=True, text=True, timeout=20)
        return set(json.loads(o.stdout) or [])
    except Exception: return set()
parts = ["docker run -d", f"--name {shlex.quote(name)}"]
rp = (hc.get("RestartPolicy") or {}).get("Name")
if rp and rp != "no": parts.append(f"--restart {rp}")
nm = hc.get("NetworkMode")
if nm and nm not in ("default","bridge"): parts.append(f"--network {shlex.quote(nm)}")
for h in (hc.get("ExtraHosts") or []): parts.append(f"--add-host {shlex.quote(h)}")
seen = set()
for cport, binds in sorted((hc.get("PortBindings") or {}).items()):
    for b in binds or []:
        hip, hp = b.get("HostIp",""), b.get("HostPort","")
        if ":" in hip: continue            # 跳过 IPv6 绑定，避免拼出非法的 -p :::端口
        key = (hp, cport)
        if key in seen: continue
        seen.add(key)
        proto = "/udp" if cport.endswith("/udp") else ""
        parts.append(f"-p 127.0.0.1:{hp}:{cport.split('/')[0]}{proto}")   # ← 收紧点
for b in (hc.get("Binds") or []): parts.append(f"-v {shlex.quote(b)}")
base = image_env(img)
for e in (cfg.get("Env") or []):
    if e not in base: parts.append(f"-e {shlex.quote(e)}")
parts.append(shlex.quote(img))
if cfg.get("Cmd"): parts.extend(shlex.quote(c) for c in cfg["Cmd"])
with open(sys.argv[2], "w") as fh:
    fh.write("#!/usr/bin/env bash\nset -e\n"
             f"docker rm -f {shlex.quote(name)} >/dev/null 2>&1 || true\n"
             + " \\\n  ".join(parts) + "\n")
os.chmod(sys.argv[2], 0o700)
print(f"  [生成] {sys.argv[2]}")
PY
done

section "生成的命令"
for f in "$OUTDIR"/*.sh; do
  [ -e "$f" ] || continue
  echo "--- $f ---"; sed 's/^/  /' "$f"
done

if [ "$APPLY" -eq 0 ]; then
  cat <<EOF

  以上只是生成，没有执行。确认无误后：
    $(basename "$0") --apply
  或逐个手动执行 $OUTDIR/<容器>.sh
EOF
  exit 0
fi

section "执行"
confirm "将重建上述容器，服务会短暂中断，继续？"
for f in "$OUTDIR"/*.sh; do
  [ -e "$f" ] || continue
  log "执行 $(basename "$f")"
  bash "$f" >/dev/null && ok "$(basename "$f" .sh)" || warn "$(basename "$f" .sh) 重建失败"
done
sleep 8

section "验证"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
echo "  外部确认（在另一台机器上跑，两条都应失败）:"
for f in "$OUTDIR"/*.sh; do
  [ -e "$f" ] || continue
  grep -oE '127\.0\.0\.1:[0-9]+' "$f" | cut -d: -f2 | while read -r p; do
    echo "    nc -zv ${NEW_HOST_IP:-<本机公网IP>} $p"
  done
done
echo "  注意用 ; 分隔而不是 &&，否则第一条失败后第二条不会执行"
finish
