#!/usr/bin/env bash
# ops/preflight-backup.sh — 首次手动跑备份脚本前的检查
# VERSION: 2.0.0
#
# 备份脚本通常有一串 need <命令> 的前置断言，缺一个就中途 die。
# 与其跑到一半失败，不如先全查一遍。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env BACKUP_SCRIPTS BACKUP_DIRS

section "1. 命令可用性"
# 注意：探测时不要用 --version。有些命令（如 7z）不认这个参数，
# 会让"已安装"被误判成"缺失"。用 command -v 判断存在性即可。
MISS=""
for c in tar gzip 7z rclone sqlite3 mysql mysqldump flock msmtp curl find; do
  if p=$(command -v "$c" 2>/dev/null); then
    printf '  %-12s %s\n' "$c" "$p"
  else
    printf '  %-12s 缺失\n' "$c"; MISS="$MISS $c"
  fi
done
if [ -n "$MISS" ]; then
  warn "缺失:$MISS —— 尝试安装"
  declare -A PKG=( [sqlite3]=sqlite3 [7z]=p7zip-full [mysqldump]=default-mysql-client
                   [flock]=util-linux [msmtp]=msmtp [rclone]=rclone [curl]=curl )
  NEED=""; for c in $MISS; do NEED="$NEED ${PKG[$c]:-$c}"; done
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update -qq 2>/dev/null
  # shellcheck disable=SC2086
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq $NEED 2>/dev/null
  for c in $MISS; do command -v "$c" >/dev/null 2>&1 && ok "$c 已装上" || warn "$c 仍缺失"; done
fi

section "2. 备份脚本声明的依赖"
for s in $BACKUP_SCRIPTS; do
  f="/usr/local/bin/$s"
  [ -f "$f" ] || { warn "脚本不存在: $f"; continue; }
  echo "  --- $s ---"
  grep -nE '^\s*need ' "$f" | sed 's/^/    /' || echo "    (没有 need 声明)"
done

section "3. 前置条件"
chk() { if eval "$2"; then ok "$1"; else warn "$1"; fi; }
for f in $BACKUP_PASS_FILES; do
  chk "$f 存在且 600" "[ \"\$(stat -c %a '$f' 2>/dev/null)\" = 600 ]"
done
chk "MySQL 凭据可用" "mysql --defaults-file='$MYSQL_DEFAULTS_FILE' -e 'SELECT 1' >/dev/null 2>&1"
for d in $BACKUP_DIRS; do chk "$d 可写" "[ -w '$d' ]"; done
chk "磁盘剩余 > 5G" "[ \"\$(df --output=avail -BG / | tail -1 | tr -dc 0-9)\" -gt 5 ]"
chk "msmtp 配置可读" "[ -r /etc/msmtprc ]"
if [ -n "${RUN_CONTAINERS:-}${COMPOSE_DIRS:-}" ]; then
  chk "有容器在运行" "[ \"\$(docker ps -q | wc -l)\" -gt 0 ]"
fi

section "4. 大库的本地 dump 是否已产生"
# 有些备份脚本不自己导大库，而是取面板计划任务产出的 dump。
# 迁移后那个任务可能一次都没跑过，导致备份告警"找不到某个 dump"。
if [ -n "${PANEL_DB_BACKUP_DIR:-}" ] && [ -d "$PANEL_DB_BACKUP_DIR" ]; then
  found=0
  for d in "$PANEL_DB_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    n=$(ls -1 "$d"/*.sql.gz 2>/dev/null | wc -l)
    newest=$(ls -t "$d"/*.sql.gz 2>/dev/null | head -1)
    printf '  %-16s %s 个  最新: %s\n' "$(basename "$d")" "$n" "$(basename "${newest:-无}")"
    [ "$n" -gt 0 ] && found=1
  done
  [ "$found" -eq 1 ] || warn "一个 dump 都没有 —— 用 ops/panel-cron-inspect 找到备份任务并手动触发一次"
else
  log "未配置 PANEL_DB_BACKUP_DIR，跳过"
fi

section "5. 云端现状（跑之前的基线）"
for r in $RCLONE_REMOTES; do
  for p in $RCLONE_PATHS; do
    n=$(rclone lsf "$r:/$p" 2>/dev/null | wc -l)
    printf '  %-10s %-18s %s 个文件\n' "$r" "$p" "$n"
  done
done

section 下一步
for s in $BACKUP_SCRIPTS; do echo "  /usr/local/bin/$s 2>&1 | tail -40"; done
echo "  判断标准：零告警、零错误，且每个远端都出现当天的新包"
finish
