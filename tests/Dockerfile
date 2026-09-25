# 端到端测试用的一次性系统：每次 docker run 都是干净的 root 环境，
# opsget 往 /usr/local/bin、/etc/ops-scripts 里装东西不会弄脏开发机。
# 基础镜像跟生产机同为 Debian 12。
FROM debian:12
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash bats ca-certificates cron curl git locales p7zip-full procps python3 sqlite3 util-linux \
 && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8
