#!/usr/bin/env bash
# 01-inventory.sh — 迁移前摸底
# VERSION: 2.0.0
#
# 在新旧机各跑一次，把两份输出逐段对比。重点看：OS 版本、磁盘命名与类型、
# 时区、出网情况、已装组件版本。
#
# 输出同时落盘到 /root/inventory_<主机名>_<时间戳>.txt

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
load_env

OUT="/root/inventory_$(hostname)_$(date -u +%Y%m%d%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

section 基本信息
hostname
date -u '+UTC %F %T'; date '+LOCAL %F %T %Z'
. /etc/os-release 2>/dev/null && echo "OS: $PRETTY_NAME ($VERSION_CODENAME)"
echo "Kernel: $(uname -r)  Arch: $(uname -m)"
echo "Virt: $(systemd-detect-virt 2>/dev/null || echo unknown)"

section CPU与内存
lscpu 2>/dev/null | grep -Ei 'model name|^cpu\(s\)|thread|core'
free -h
swapon --show 2>/dev/null || echo "(无 swap)"

section 磁盘
lsblk -o NAME,SIZE,TYPE,FSTYPE,ROTA,MOUNTPOINT
echo "--- df ---"; df -hT -x tmpfs -x devtmpfs
echo "--- RAID ---"; cat /proc/mdstat 2>/dev/null | head -20
echo "--- 挂载参数 ---"; findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS / /boot 2>/dev/null

section 网络
ip -4 -br addr; ip -6 -br addr
ip route show default; ip -6 route show default 2>/dev/null
echo "--- MTU ---"; ip -o link | awk '{print $2,$5}' | grep -v '^lo'
echo "--- DNS ---"; grep -E '^nameserver' /etc/resolv.conf
echo "--- 拥塞控制 ---"; sysctl -n net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null
echo "--- 公网出口 ---"
PUB=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null)
echo "  出口 IP: ${PUB:-取不到}"
if [ -n "$PUB" ] && ! ip -4 -br addr | grep -q "$PUB"; then
  echo "  [注意] 公网 IP 不在网卡上 —— 机器在 NAT 后面。"
  echo "         入站可达性必须另外验证（见 02-nat-probe），"
  echo "         且容器内不能用公网 IP 访问宿主机服务（见迁移教程坑 6）"
fi

section 出网测试
for u in https://github.com https://cdn.jsdelivr.net; do
  printf '%-32s' "$u"
  curl -s -o /dev/null -w 'HTTP %{http_code}  %{time_total}s\n' --max-time 10 "$u" || echo FAIL
done

section 已安装组件
for c in docker docker-compose mysql mysqldump nginx php ufw fail2ban-client \
         rclone msmtp 7z sqlite3 curl rsync tar flock; do
  printf '  %-16s' "$c"
  if command -v "$c" >/dev/null 2>&1; then
    v=$("$c" --version 2>/dev/null | head -1)
    # 有些命令不认 --version（比如 7z），退化成"已装"
    [ -n "$v" ] && echo "$v" || echo "(已装)"
  else
    echo "-- 未安装"
  fi
done
[ -n "${PANEL_ROOT:-}" ] && [ -d "$PANEL_ROOT" ] && echo "  面板: 已安装于 $PANEL_ROOT" \
  || echo "  面板: 未安装或未配置 PANEL_ROOT"

section 监听端口
ss -lntup 2>/dev/null | sed 's/users:.*(("/ [/; s/",pid=/ pid /; s/,fd=[0-9]*))//'

section 防火墙
ufw status numbered 2>/dev/null || echo "(ufw 未装或未启用)"
iptables -S 2>/dev/null | head -30

section Docker现状
if docker_ready; then
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  echo "--- 网络 ---"; docker network ls
  echo "--- 挂载 ---"
  for n in $(docker ps -aq); do
    echo "[$(docker inspect -f '{{.Name}}' "$n")]"
    docker inspect -f '{{range .Mounts}}  {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$n"
  done
else
  echo "(docker 不可用)"
fi

section 计划任务
crontab -l 2>/dev/null || echo "(无 root crontab)"

section 关键目录体积
for d in $CONTAINER_DATA_DIRS $BACKUP_DIRS $SNAPSHOT_ROOT "$WWWROOT" /opt; do
  [ -n "$d" ] && [ -e "$d" ] && printf '  %-40s %s\n' "$d" "$(human "$d")"
done

section 时区核对
echo "  当前: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo "  期望: ${TZ_EXPECTED:-未配置}"
if command -v mysql >/dev/null 2>&1 && [ -f "${MYSQL_DEFAULTS_FILE:-}" ]; then
  echo "  MySQL system_time_zone: $(myq 'SELECT @@system_time_zone' 2>/dev/null)"
fi

printf '\n输出已保存: %s\n' "$OUT"
