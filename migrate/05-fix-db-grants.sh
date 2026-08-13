#!/usr/bin/env bash
# 05-fix-db-grants.sh — 修正被面板改掉的数据库账号 host
# VERSION: 2.0.0
#
# 面板类工具在迁移时会按自己记录的"本地服务器"权限重建账号，把 host 从
# 容器网段通配改成 127.0.0.1。容器经 172.x 连库就匹配不上，全站 503。
#
# RENAME USER 会把密码哈希和授权一起搬过去，比删了重建安全。
#
# 注意：命令行改绕过了面板，面板自己的记录还是旧值。以后**别在面板的数据库
# 管理里点这几个库的「权限」设置**，一点就会重置回去。

. /usr/local/lib/ops-common.sh 2>/dev/null || . "$(dirname "$0")/../lib/common.sh"
require_root
load_env
require_env DB_NAMES DB_CLIENT_HOST DOCKER_CIDR
mysql_ready

# 从库名推出账号名；库名与账号名不一致时用 DB_USERS 覆盖
USERS="${DB_USERS:-$DB_NAMES}"
# 迁移后常见的错误 host，按需增减
WRONG_HOSTS="${WRONG_HOSTS:-127.0.0.1 %}"

section "改前 host 分布"
my -e "SELECT user,host FROM mysql.user
       WHERE user IN ($(echo "$USERS" | sed "s/[^ ]*/'&'/g; s/ /,/g"))
       ORDER BY user,host"

section "逐个修正"
for u in $USERS; do
  tgt=$(myq "SELECT COUNT(*) FROM mysql.user WHERE user='$u' AND host='$DB_CLIENT_HOST'")
  if [ "$tgt" -gt 0 ]; then
    ok "$u@'$DB_CLIENT_HOST' 已存在，跳过"
    continue
  fi
  moved=0
  for wh in $WRONG_HOSTS; do
    n=$(myq "SELECT COUNT(*) FROM mysql.user WHERE user='$u' AND host='$wh'")
    if [ "$n" -gt 0 ]; then
      my -e "RENAME USER '$u'@'$wh' TO '$u'@'$DB_CLIENT_HOST'" \
        && { log "[~] $u@'$wh' -> $u@'$DB_CLIENT_HOST'"; moved=1; break; } \
        || die "$u 改名失败"
    fi
  done
  [ "$moved" -eq 1 ] || warn "$u 既无 $DB_CLIENT_HOST 也无 ($WRONG_HOSTS)，需手工处理"
done
my -e "FLUSH PRIVILEGES"

section "改后 host 分布"
my -e "SELECT user,host FROM mysql.user
       WHERE user IN ($(echo "$USERS" | sed "s/[^ ]*/'&'/g; s/ /,/g"))
       ORDER BY user,host"

section "防火墙：放行容器网段访问数据库"
# 漏了这条是延迟发作的：连接池里的旧连接还能撑几小时，然后突然全站 503，
# 日志报 Can't connect to server (115) —— errno 115 是超时不是拒绝。
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qE "3306.*${DOCKER_CIDR//./\\.}"; then
    ok "规则已存在"
  else
    ufw allow from "$DOCKER_CIDR" to any port 3306 proto tcp && ok "已添加"
  fi
  ufw status numbered | grep -E '3306|Status' | sed 's/^/  /'
else
  warn "ufw 未安装，跳过（请自行确认容器能访问宿主机 3306）"
fi

section 提示
cat <<EOF
  真正的验证要等容器起来后看 MySQL 实际接到的来源地址：
    SELECT user, host FROM information_schema.processlist WHERE user <> 'root';
  应当显示容器自己的网段地址。

  宿主机侧用 mysql -h ${DOCKER_GATEWAY:-172.17.0.1} 探测不可靠 ——
  内核会把源地址选成网卡上的地址，报 ERROR 1130，这不代表授权有问题。
EOF
finish
