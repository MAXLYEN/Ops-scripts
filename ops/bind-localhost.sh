#!/usr/bin/env bash
# ops/bind-localhost.sh — 将容器端口映射从公网绑定改为本机绑定
# VERSION: 2.1.0
# 2.1.0: 每轮在独立子目录生成、--apply 只执行本轮的；含重建命令复现不了的配置（匿名卷、cap、设备、资源限制、多网络等）时拒绝生成；重建改为旧容器改名保留、失败自动回滚。
# 默认只生成命令，--apply 才执行容器重建。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_cmd docker python3
docker_ready || die "docker 不可用"

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
TS=$(date -u +%Y%m%d%H%M%S)
# 每轮一个子目录：--apply 只执行本轮刚生成的命令。原先共用一个目录，
# 上一轮留下的脚本会被一起执行，把之后升级过的容器按旧配置重建回去。
OUTDIR="${RESTORE_CMD_DIR:-/root/restore_cmds}/rebind/$TS"
umask 077
mkdir -p "$OUTDIR" || die "建不了 $OUTDIR"

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
  python3 - "$OUTDIR/$name.json" "$OUTDIR/$name.sh" "$TS" <<'PY' || warn "$name 未生成重建命令（原因见上）"
import json, shlex, subprocess, sys, os
d = json.load(open(sys.argv[1]))[0]
name = d["Name"].lstrip("/"); cfg, hc = d.get("Config",{}), d.get("HostConfig",{})
img = cfg.get("Image")
def image_cfg(i):
    try:
        o = subprocess.run(["docker","image","inspect",i,"--format","{{json .Config}}"],
                           capture_output=True, text=True, timeout=20)
        return json.loads(o.stdout) or {}
    except Exception: return None
icfg = image_cfg(img)
if icfg is None:
    print(f"  [拒绝] {name}: 读不到镜像 {img} 的配置，无法判断哪些参数是容器自己加的"); sys.exit(1)

# 下面只复现端口、bind/具名卷、环境变量、网络、extra hosts、重启策略和 Cmd。
# 容器还带着别的配置时，照这个命令重建会把它们悄悄丢掉 —— 最糟的是匿名卷：
# 新容器挂上一个空卷，服务照常起来，数据却是空的。宁可拒绝，让人改 compose 或手工处理。
bad = []
flags = {"Privileged": "--privileged", "CapAdd": "--cap-add", "CapDrop": "--cap-drop",
         "Devices": "--device", "DeviceRequests": "--gpus", "SecurityOpt": "--security-opt",
         "Memory": "--memory", "MemorySwap": "--memory-swap", "MemoryReservation": "--memory-reservation",
         "NanoCpus": "--cpus", "CpuShares": "--cpu-shares", "CpuQuota": "--cpu-quota",
         "CpusetCpus": "--cpuset-cpus", "PidsLimit": "--pids-limit", "OomKillDisable": "--oom-kill-disable",
         "PidMode": "--pid", "UTSMode": "--uts", "UsernsMode": "--userns", "Tmpfs": "--tmpfs",
         "Sysctls": "--sysctl", "Ulimits": "--ulimit", "GroupAdd": "--group-add", "Dns": "--dns",
         "DnsSearch": "--dns-search", "DnsOptions": "--dns-option", "VolumesFrom": "--volumes-from",
         "Links": "--link", "Init": "--init", "ReadonlyRootfs": "--read-only"}
for k, flag in flags.items():
    if hc.get(k): bad.append(flag)
if hc.get("IpcMode") not in (None, "", "private", "shareable"): bad.append("--ipc")
if hc.get("ShmSize") not in (None, 0, 67108864): bad.append("--shm-size")
lc = hc.get("LogConfig") or {}
if lc.get("Type") not in (None, "", "json-file") or lc.get("Config"): bad.append("--log-driver/--log-opt")
for k, flag in (("User", "--user"), ("Entrypoint", "--entrypoint"), ("WorkingDir", "--workdir"),
                ("Healthcheck", "--health-*"), ("StopSignal", "--stop-signal")):
    if cfg.get(k) and cfg.get(k) != icfg.get(k): bad.append(flag)
if cfg.get("Tty") or cfg.get("OpenStdin"): bad.append("-t/-i")
nets = (d.get("NetworkSettings") or {}).get("Networks") or {}
if len(nets) > 1: bad.append(f"多个网络（{', '.join(nets)}）")
if any((n or {}).get("IPAMConfig") for n in nets.values()): bad.append("--ip（固定 IP）")
bind_dst = {b.split(":")[1] for b in (hc.get("Binds") or []) if b.count(":") >= 1}
for m in d.get("Mounts") or []:
    if m.get("Destination") in bind_dst: continue
    # 具名卷 -v name:/path 会出现在 Binds 里，上面已跳过；剩下的是匿名卷或 --mount 挂的卷
    if m.get("Type") == "volume":
        bad.append(f"卷 {m.get('Destination')}（匿名卷或 --mount，重建会换成空卷）")
    else:
        bad.append(f"--mount {m.get('Type')} {m.get('Destination')}")
if bad:
    print(f"  [拒绝] {name}: 含重建命令复现不了的配置 —— {'；'.join(bad)}")
    print(f"         改用 compose 管理，或参照 {sys.argv[1]} 手工重建")
    sys.exit(1)

parts = ["docker run -d", f"--name {shlex.quote(name)}"]
rp = (hc.get("RestartPolicy") or {}).get("Name") or "no"
mrc = (hc.get("RestartPolicy") or {}).get("MaximumRetryCount") or 0
if rp == "on-failure" and mrc: rp = f"on-failure:{mrc}"
if rp != "no": parts.append(f"--restart {rp}")
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
base = set(icfg.get("Env") or [])
for e in (cfg.get("Env") or []):
    if e not in base: parts.append(f"-e {shlex.quote(e)}")
parts.append(shlex.quote(img))
if cfg.get("Cmd"): parts.extend(shlex.quote(c) for c in cfg["Cmd"])

# 不再 docker rm -f：旧容器改名留着，新容器起不来就改回原名重启。
# 旧容器先关掉自动重启，否则重启机器后它会抢回原端口，新容器反而起不来。
n, old = shlex.quote(name), shlex.quote(f"{name}-prebind-{sys.argv[3]}")
run = " \\\n  ".join(parts)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(f"""#!/usr/bin/env bash
set -u
docker update --restart=no {n} >/dev/null || exit 1
docker stop {n} >/dev/null || {{ docker update --restart={rp} {n} >/dev/null; exit 1; }}
docker rename {n} {old} || {{ docker update --restart={rp} {n} >/dev/null; docker start {n}; exit 1; }}
if {run} >/dev/null; then
  echo "  旧容器保留为 {old}（已停止、不自动重启），确认无误后 docker rm {old}"
else
  echo "  新容器启动失败，回滚到原容器" >&2
  docker rm -f {n} >/dev/null 2>&1
  docker rename {old} {n} && docker update --restart={rp} {n} >/dev/null && docker start {n} >/dev/null
  exit 1
fi
""")
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
ls "$OUTDIR"/*.sh >/dev/null 2>&1 || { ok "本轮没有可自动重建的容器"; finish; exit $?; }
confirm "将重建上述容器，服务会短暂中断，继续？"
for f in "$OUTDIR"/*.sh; do
  [ -e "$f" ] || continue
  log "执行 $(basename "$f")"
  # 输出要留着：里面有旧容器的保留名，失败时还有回滚结果
  bash "$f" && ok "$(basename "$f" .sh)" || warn "$(basename "$f" .sh) 重建失败（脚本已尝试回滚到原容器）"
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
