#!/usr/bin/env bash
# 07-restore-containers.sh — 恢复容器数据并生成启动命令
# VERSION: 2.0.0
#
# 在迁入机运行。只恢复文件、只生成命令，**不启动任何容器** ——
# 生成的东西要人工过目再执行。
#
# 用法: 07-restore-containers.sh [快照目录]
#       不给参数则取 SNAPSHOT_ROOT 下最新的 premigrate_*
# ENV-REQUIRED: CONTAINER_DATA_DIRS SNAPSHOT_ROOT

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env SNAPSHOT_ROOT CONTAINER_DATA_DIRS
require_cmd tar python3 docker

SNAP=${1:-$(ls -dt "$SNAPSHOT_ROOT"/premigrate_* 2>/dev/null | head -1)}
[ -n "$SNAP" ] && [ -d "$SNAP" ] || die "找不到快照目录（传参或检查 SNAPSHOT_ROOT）"
STAGE="${RESTORE_STAGE:-/root/restore_stage}"
CMDDIR="${RESTORE_CMD_DIR:-/root/restore_cmds}"
TS=$(date -u +%Y%m%d%H%M%S)
log "快照: $SNAP"

section "1. 解包到暂存目录"
mkdir -p "$STAGE" "$CMDDIR"; chmod 700 "$CMDDIR"
[ -f "$SNAP/files.tar.gz" ] || die "快照里没有 files.tar.gz"
tar -xzf "$SNAP/files.tar.gz" -C "$STAGE" 2>/dev/null
rc=$?; [ $rc -le 2 ] || die "解包失败 rc=$rc"
ok "解到 $STAGE"

section "2. 恢复数据目录"
for d in $CONTAINER_DATA_DIRS; do
  src="$STAGE${d}"
  if [ ! -e "$src" ]; then warn "快照里没有 $d"; continue; fi
  if [ -e "$d" ]; then
    mv "$d" "${d}.bak.${TS}" && log "[备份] $d -> ${d}.bak.${TS}"
  fi
  mkdir -p "$(dirname "$d")"
  cp -a "$src" "$d" && ok "$d  ($(human "$d"))" || { warn "恢复失败 $d"; }
done

section "3. 关键文件检查"
# CRITICAL_FILES 在配置里逐条列出。这些是"丢了就回不来"的东西：
# 加密密钥、应用 KEY、token 数据库、被覆盖会导致重新初始化的配置。
if [ -n "${CRITICAL_FILES:-}" ]; then
  for f in $CRITICAL_FILES; do
    [ -e "$f" ] && ok "$f" || { warn "缺失: $f"; }
  done
else
  warn "未配置 CRITICAL_FILES —— 强烈建议填上，这是最后一道防线"
fi

section "4. 生成启动命令"
python3 - "$SNAP" "$CMDDIR" <<'PY'
import json, glob, os, shlex, subprocess, sys
snap, cmddir = sys.argv[1], sys.argv[2]

def image_env(img):
    try:
        out = subprocess.run(["docker","image","inspect",img,"--format","{{json .Config.Env}}"],
                             capture_output=True, text=True, timeout=20)
        return set(json.loads(out.stdout) or [])
    except Exception:
        return set()

for f in sorted(glob.glob(os.path.join(snap, "inspect_*.json"))):
    try:
        d = json.load(open(f))[0]
    except Exception as e:
        print(f"  [失败] 解析 {f}: {e}"); continue

    name = d["Name"].lstrip("/")
    cfg, hc = d.get("Config", {}), d.get("HostConfig", {})
    labels = cfg.get("Labels") or {}
    proj = labels.get("com.docker.compose.project")
    if proj:
        wd = labels.get("com.docker.compose.project.working_dir", "?")
        print(f"  [compose] {name}  项目={proj}  目录={wd}")
        continue

    img = cfg.get("Image")
    parts = ["docker run -d", f"--name {shlex.quote(name)}"]
    rp = (hc.get("RestartPolicy") or {}).get("Name")
    if rp and rp != "no":
        parts.append(f"--restart {rp}")
    nm = hc.get("NetworkMode")
    if nm and nm not in ("default", "bridge"):
        parts.append(f"--network {shlex.quote(nm)}")
    for h in (hc.get("ExtraHosts") or []):
        parts.append(f"--add-host {shlex.quote(h)}")

    # 端口：同一容器端口可能同时有 IPv4 和 IPv6 两条绑定，直接照搬会拼出
    # -p :::10086:25774 这种非法格式。docker 不指定 HostIp 时本来就同时
    # 绑 v4/v6，所以按 (HostPort, 容器端口) 去重，只保留非 IPv6 的 HostIp。
    seen = set()
    for cport, binds in sorted((hc.get("PortBindings") or {}).items()):
        for b in binds or []:
            hip, hp = b.get("HostIp",""), b.get("HostPort","")
            if ":" in hip:          # IPv6 绑定，跳过
                continue
            key = (hp, cport)
            if key in seen: continue
            seen.add(key)
            proto = "/udp" if cport.endswith("/udp") else ""
            prefix = f"{hip}:" if hip and hip != "0.0.0.0" else ""
            parts.append(f"-p {prefix}{hp}:{cport.split('/')[0]}{proto}")

    for b in (hc.get("Binds") or []):
        parts.append(f"-v {shlex.quote(b)}")
    base = image_env(img)
    for e in (cfg.get("Env") or []):
        if e in base:               # 与镜像默认值相同，不必重复
            continue
        parts.append(f"-e {shlex.quote(e)}")
    parts.append(shlex.quote(img))
    if cfg.get("Cmd"):
        parts.extend(shlex.quote(c) for c in cfg["Cmd"])

    out = os.path.join(cmddir, f"{name}.sh")
    with open(out, "w") as fh:
        fh.write("#!/usr/bin/env bash\nset -e\n" + " \\\n  ".join(parts) + "\n")
    os.chmod(out, 0o700)
    print(f"  [生成] {out}")
PY

section "5. compose 项目"
for p in ${COMPOSE_DIRS:-}; do
  c=$(ls "$p"/compose.y*ml "$p"/docker-compose.y*ml 2>/dev/null | head -1)
  [ -n "$c" ] && ok "$c" || warn "$p 下没有 compose 文件"
done

section "6. 生成的命令（启动前请逐条过目）"
for f in "$CMDDIR"/*.sh; do
  [ -e "$f" ] || continue
  echo "--- $f ---"; sed 's/^/  /' "$f"
done

cat <<EOF

  确认无误后，先起不依赖数据库的，再起依赖数据库的：
    $CMDDIR/<容器>.sh
    cd <compose目录> && docker compose up -d
    docker ps -a

  生成的命令含环境变量（可能有凭据），文件权限已设为 700。
EOF
finish
