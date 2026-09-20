#!/usr/bin/env bash
# deploy-litellm.sh
# VERSION: 1.0.0
# ENV-REQUIRED: (none — 目标机与域名写在脚本头部常量区)
#
# 在 43.165.176.248 上部署 LiteLLM + Postgres + Redis 三容器。
# 从汇总机执行，通过 SSH 操作目标机。
#
# 注意：
# - LITELLM_SALT_KEY 加密 Postgres 里的 provider 凭据，加过模型后不可更改，
#   首次生成必须立刻存入密码管理器，否则备份还原时库里凭据全部读不出来。
# - 容器全部绑 127.0.0.1，不直接暴露公网；对外走香港前置的 nginx 反代。
# - 镜像版本在部署时实时查询当前 stable 并锁定，不使用 latest。
set -o pipefail

TARGET_IP="43.165.176.248"
LITELLM_PORT=4000
WORKDIR=/opt/litellm
PG_VERSION=17
REDIS_VERSION=7
NEWAPI_BASE="https://k3vq.210723.xyz/v1"

log()  { printf '%s [INFO] %s\n' "$(date -u '+%F %T')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date -u '+%F %T')" "$*"; }
die()  { printf '%s [FAIL] %s\n' "$(date -u '+%F %T')" "$*"; exit 1; }

mask() {
  local s="$1"
  local n=${#s}
  if   [ "$n" -eq 0 ]; then echo "(空)"
  elif [ "$n" -le 8 ]; then printf '%*s  [len=%d]\n' "$n" '' | tr ' ' '*'
  else printf '%s…%s  [len=%d]\n' "${s:0:4}" "${s: -2}" "$n"; fi
}

TPORT="$(awk -F: -v h="$TARGET_IP" '$0 ~ h {print $NF}' "${HOME}/.vps-hosts.txt" 2>/dev/null | head -1)"
[ -z "$TPORT" ] && TPORT=22
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)
rsh()  { ssh "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET_IP" "$@"; }
rshn() { ssh -n "${SSH_OPTS[@]}" -p "$TPORT" "root@$TARGET_IP" "$@"; }

log "目标 root@$TARGET_IP:$TPORT"
rshn true 2>/dev/null || die "SSH 连不上"

# ---------- 收集凭据 ----------
echo
echo "===== 需要两个上游凭据（均不回显、不落本机磁盘）====="
read -rsp "1/2 new-api 令牌（sk- 开头，给中转渠道用）: " NEWAPI_TOKEN; echo
[ -z "$NEWAPI_TOKEN" ] && die "未输入 new-api 令牌"
echo "    已读取：$(mask "$NEWAPI_TOKEN")"

read -rsp "2/2 DeepSeek 官方 Key（给直连对照渠道用，留空则跳过该渠道）: " DEEPSEEK_KEY; echo
if [ -n "$DEEPSEEK_KEY" ]; then
  echo "    已读取：$(mask "$DEEPSEEK_KEY")"
else
  warn "未提供 DeepSeek Key，将只配置经 new-api 的渠道"
fi

# ---------- 查询当前 stable 版本 ----------
echo
log "查询 LiteLLM 当前 stable 版本"
LITELLM_TAG=$(rshn "curl -s -m 25 https://api.github.com/repos/BerriAI/litellm/releases/latest" 2>/dev/null \
  | grep -oE '\"tag_name\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' \
  | head -1 | sed 's/.*\"\(v\?[0-9][^\"]*\)\"/\1/')

if [ -z "$LITELLM_TAG" ]; then
  warn "取不到版本号（GitHub API 限流或网络问题）"
  read -rp "手动输入版本 tag（形如 1.99.1，留空则中止）: " LITELLM_TAG
  [ -z "$LITELLM_TAG" ] && die "无版本号，中止"
fi
# release 的 tag_name 带 v 前缀，镜像标签两种都有，统一去掉 v
LITELLM_TAG="${LITELLM_TAG#v}"
case "$LITELLM_TAG" in
  *dev*|*rc*|*nightly*) warn "取到的是预发布版本 $LITELLM_TAG，建议改用正式 stable" ;;
esac
log "锁定镜像版本：ghcr.io/berriai/litellm:${LITELLM_TAG}"

# ---------- 安装 docker ----------
echo
log "检查并安装 docker"
rsh "bash -s" <<'REMOTE_DOCKER'
set -o pipefail
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "  已就绪：$(docker --version)"
  systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
  exit 0
fi
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
echo "  系统：$PRETTY_NAME  codename=$CODENAME"
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg >/dev/null 2>&1
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || exit 1
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
  >/dev/null 2>&1 || exit 1
systemctl enable --now docker >/dev/null 2>&1
echo "  安装完成：$(docker --version)"
REMOTE_DOCKER
[ $? -ne 0 ] && die "docker 安装失败"

# ---------- 生成凭据 ----------
echo
log "生成本次部署的凭据"
MASTER_KEY="sk-$(rshn 'openssl rand -hex 24' 2>/dev/null)"
SALT_KEY="$(rshn 'openssl rand -hex 32' 2>/dev/null)"
PG_PASS="$(rshn 'openssl rand -hex 20' 2>/dev/null)"
[ ${#MASTER_KEY} -lt 20 ] && die "凭据生成失败（openssl 不可用？）"

echo "  LITELLM_MASTER_KEY  $(mask "$MASTER_KEY")"
echo "  LITELLM_SALT_KEY    $(mask "$SALT_KEY")"
echo "  POSTGRES_PASSWORD   $(mask "$PG_PASS")"

# ---------- 写入目标机 ----------
echo
log "写入配置到 $WORKDIR"
rshn "mkdir -p ${WORKDIR}" || die "建目录失败"

# .env：凭据落在目标机，权限 600
rsh "cat > ${WORKDIR}/.env && chmod 600 ${WORKDIR}/.env" <<ENVEOF
LITELLM_MASTER_KEY=${MASTER_KEY}
LITELLM_SALT_KEY=${SALT_KEY}
POSTGRES_PASSWORD=${PG_PASS}
DATABASE_URL=postgresql://litellm:${PG_PASS}@postgres:5432/litellm
STORE_MODEL_IN_DB=True
NEWAPI_TOKEN=${NEWAPI_TOKEN}
DEEPSEEK_API_KEY=${DEEPSEEK_KEY}
LITELLM_IMAGE_TAG=${LITELLM_TAG}
ENVEOF

# config.yaml：两条中转渠道 + 一条直连对照渠道
{
cat <<'CFGHEAD'
model_list:
CFGHEAD
cat <<CFGRELAY
  - model_name: relay/gpt-5.6-sol
    litellm_params:
      model: openai/gpt-5.6-sol
      api_base: ${NEWAPI_BASE}
      api_key: os.environ/NEWAPI_TOKEN

  - model_name: relay/deepseek-v4-pro
    litellm_params:
      model: openai/deepseek-v4-pro
      api_base: ${NEWAPI_BASE}
      api_key: os.environ/NEWAPI_TOKEN
CFGRELAY
if [ -n "$DEEPSEEK_KEY" ]; then
cat <<'CFGDIRECT'

  - model_name: direct/deepseek-v4-pro
    litellm_params:
      model: openai/deepseek-v4-pro
      api_base: https://api.deepseek.com/v1
      api_key: os.environ/DEEPSEEK_API_KEY
CFGDIRECT
fi
cat <<'CFGTAIL'

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL

litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: redis
    port: 6379
  # SpendLogs 每请求写一条，不设保留期会无上限增长
  maximum_spend_logs_retention_period: "30d"
  maximum_spend_logs_retention_interval: "1d"
CFGTAIL
} | rsh "cat > ${WORKDIR}/config.yaml"

# compose：三容器，全部绑 127.0.0.1
rsh "cat > ${WORKDIR}/docker-compose.yml" <<COMPOSEEOF
services:
  litellm:
    image: ghcr.io/berriai/litellm:${LITELLM_TAG}
    container_name: litellm
    restart: always
    ports:
      - "127.0.0.1:${LITELLM_PORT}:4000"
    env_file: .env
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started

  postgres:
    image: postgres:${PG_VERSION}
    container_name: litellm-postgres
    restart: always
    environment:
      POSTGRES_USER: litellm
      POSTGRES_DB: litellm
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    env_file: .env
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:${REDIS_VERSION}
    container_name: litellm-redis
    restart: always
    command: ["redis-server", "--save", "", "--appendonly", "no"]
COMPOSEEOF

log "配置已写入"

# ---------- 拉起 ----------
echo
log "拉取镜像并启动（首次拉取较慢）"
rsh "cd ${WORKDIR} && docker compose pull && docker compose up -d" || die "启动失败"

log "等待 LiteLLM 就绪（最多 90 秒）"
OK=0
for i in $(seq 1 18); do
  C=$(rshn "curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null)
  if [ "$C" = "200" ]; then OK=1; break; fi
  sleep 5
done

echo
echo "===== 结果 ====="
rsh "cd ${WORKDIR} && docker compose ps --format '  {{.Name}}  {{.Image}}  {{.Status}}'"
if [ "$OK" = 1 ]; then
  log "LiteLLM 已就绪（/health/liveliness 返回 200）"
  C=$(rshn "curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Authorization: Bearer ${MASTER_KEY}' http://127.0.0.1:${LITELLM_PORT}/v1/models" 2>/dev/null)
  echo "  带 master key 列模型：HTTP ${C:-无响应}（200 = 配置生效）"
else
  warn "90 秒内未就绪，查日志：ssh -p ${TPORT} root@${TARGET_IP} 'cd ${WORKDIR} && docker compose logs --tail=60 litellm'"
fi

cat <<'TAIL'

=====================================================================
 必做收尾（现在就做，别拖）
=====================================================================

1. 把下面三个凭据存进 Vaultwarden：
   - LITELLM_MASTER_KEY   管理与调用凭据
   - LITELLM_SALT_KEY     ★ 加过模型后不可更改。没有它，备份里的
                            provider 凭据全部无法解密，等于没备份
   - POSTGRES_PASSWORD

   明文在目标机 /opt/litellm/.env（权限 600），取值：
     ssh root@<目标机> 'cat /opt/litellm/.env'
   取完记得 history -c && history -w

2. 本地开隧道访问管理面板（Windows PowerShell）：
     ssh -N -L 4000:127.0.0.1:4000 -p <SSH端口> root@<目标机IP>
   浏览器打开 http://127.0.0.1:4000/ui
   登录用户名 admin，密码用 LITELLM_MASTER_KEY

3. 面板验证无误后，再做香港前置的隧道与 nginx 反代。

=====================================================================
TAIL
