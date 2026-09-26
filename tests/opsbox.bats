#!/usr/bin/env bats
# tests/opsbox.bats — 菜单端到端：在伪终端里按键操作，被调用的脚本换成记录调用的桩。
# 输入按屏幕顺序写：分类号 → 功能号 → ""（说明卡片上回车开始）→ 各步确认 → ""（回车返回）→ 0 → q

load helpers

setup_file() { mock_build; http_start; }
teardown_file() { http_stop; }
setup() { reset_host; opsget -u >/dev/null; }

env_conf() {  # env_conf [键=值...]：建一个权限正确的 env.conf
  mkdir -p /etc/ops-scripts
  printf '%s\n' "$@" > /etc/ops-scripts/env.conf
  chmod 600 /etc/ops-scripts/env.conf
}
state() { cat /var/lib/ops-scripts/opsbox.state 2>/dev/null; }

# ── 界面 ────────────────────────────────────────────────────
@test "非终端运行时拒绝，并指向 opsget" {
  run opsbox </dev/null
  [ "$status" -eq 1 ]
  has "需要交互终端"
}

@test "主菜单：头部状态、九个分类和快捷键" {
  drive opsbox q
  [ "$status" -eq 0 ]
  has "运维工具箱"
  has "主机  ops-test"
  has "main（未固定）"
  has "还没有 env.conf"
  has "[1] 日常巡检"
  has "[9] 工具箱设置"
  has "[?] 不知道用哪个"
}

@test "头部显示固定的版本与待重启标记" {
  mkdir -p /etc/ops-scripts; echo v2099.01.01 > /etc/ops-scripts/ref
  touch /var/run/reboot-required
  drive opsbox q
  has "v2099.01.01（已固定）"
  has "系统标记需要重启"
}

@test "分类列表：每项都有「什么时候用」，本机缺配置的标 [未配置]" {
  stub ops/ssl-audit 0 WWWROOT
  opsget -i ops/ssl-audit >/dev/null
  drive opsbox 1 0 q
  has "证书对账"
  has "站点报证书错误"
  has "[未配置]"
}

@test "按场景找：从要办的事跳到功能的说明卡片" {
  drive opsbox "?" 14 0 0 q
  has "磁盘快满了"
  has "── 清理冗余文件 ──"
  has "什么时候用"
  [ -z "$(calls)" ]
}

@test "只读功能：卡片上回车才执行，并显示实际命令" {
  stub ops/ssl-audit 0
  drive opsbox 1 3 "" "" 0 q
  [ "$status" -eq 0 ]
  has "等价命令"
  has "▶ opsget ops/ssl-audit"
  has "✓ 完成"
  calls_are "ops/ssl-audit"
}

@test "说明卡片上按 0 返回，不执行" {
  stub ops/ssl-audit 0
  drive opsbox 1 3 0 0 q
  [ -z "$(calls)" ]
}

# ── 两段式与高危 ────────────────────────────────────────────
@test "两段式：不确认就只预演" {
  stub ops/cleanup-tidy 0
  drive opsbox 5 1 "" n "" 0 q
  calls_are "ops/cleanup-tidy"
}

@test "两段式：确认后才带 --apply 执行" {
  stub ops/cleanup-tidy 0
  drive opsbox 5 1 "" y "" 0 q
  calls_are "ops/cleanup-tidy" "ops/cleanup-tidy --apply"
}

@test "高危：主机名不符就取消" {
  stub ops/cleanup-purge 0
  drive opsbox 9 6 "" wrong-host "" 0 q
  has "主机名不符"
  calls_are "ops/cleanup-purge"
}

@test "高危：输对主机名才执行" {
  stub ops/cleanup-purge 0
  drive opsbox 9 6 "" ops-test "" 0 q
  calls_are "ops/cleanup-purge" "ops/cleanup-purge --apply"
}

# ── 缺配置引导 ──────────────────────────────────────────────
@test "缺配置：执行前当场逐项填写（显示模板说明），填完直接执行" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  drive opsbox 1 2 "" y "/bak" "" 0 q
  has "这个功能还缺配置：BACKUP_DIRS"
  lacks "配置未就绪"                # 执行前就问，不先报一屏错
  has "本地备份落盘目录"          # 模板里的行尾说明
  has "/bak 现在不存在"          # 路径类填错提醒
  calls_are "ops/preflight-backup"
  grep -qx "BACKUP_DIRS='/bak'" /etc/ops-scripts/env.conf
  [ "$(stat -c %a /etc/ops-scripts/env.conf)" = 600 ]
}

@test "缺配置：不想现在填，告诉以后去哪补，不执行" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  drive opsbox 1 2 "" n "" 0 q
  has "以后要补：主菜单 9 工具箱设置"
  [ -z "$(calls)" ]
}

# ── 联动 ────────────────────────────────────────────────────
fake_mysql() {  # 让「本机有 MySQL」的前提成立
  printf '#!/bin/sh
exit 0
' > /usr/local/bin/mysql; chmod 755 /usr/local/bin/mysql
  touch /tmp/my.cnf
  env_conf "MYSQL_DEFAULTS_FILE=/tmp/my.cnf"
}

@test "一键巡检：未配置的跳过，异常的照跑，最后汇总" {
  fake_mysql
  stub ops/preflight-backup 0 BACKUP_DIRS
  stub ops/ssl-audit 0
  stub ops/check-llm-security 1
  stub ops/komari-metrics-check 0
  stub ops/script-inventory 0
  drive opsbox a "" "" q
  calls_are "ops/ssl-audit" "ops/check-llm-security" "ops/komari-metrics-check" "ops/script-inventory"
  has "一键巡检 · 汇总"
  has "未配置"
  has "异常 1"
}

@test "备份体检：云端校验失败时自动诊断告警邮件" {
  stub ops/preflight-backup 0; stub ops/verify-backup-pass 1; stub ops/mail-doctor 0
  drive opsbox b "" "" q
  calls_are "ops/preflight-backup" "ops/verify-backup-pass" "ops/mail-doctor"
  has "云端校验没通过"
}

@test "备份体检：云端校验通过就不诊断邮件" {
  stub ops/preflight-backup 0; stub ops/verify-backup-pass 0; stub ops/mail-doctor 0
  drive opsbox b "" "" q
  calls_are "ops/preflight-backup" "ops/verify-backup-pass"
}

@test "LLM 访问控制：确认后先快照、再同步、再复查" {
  env_conf
  stub ops/check-llm-security 0; stub ops/save-fw 0; stub ops/sync-llm-allowlist 0
  drive opsbox 3 2 "" y "" 0 q
  calls_are "ops/check-llm-security" "ops/save-fw" "ops/sync-llm-allowlist" "ops/check-llm-security"
}

@test "LLM 访问控制：快照失败且不继续，就不改规则" {
  env_conf
  stub ops/check-llm-security 0; stub ops/save-fw 1; stub ops/sync-llm-allowlist 0
  drive opsbox 3 2 "" y n "" 0 q
  calls_are "ops/check-llm-security" "ops/save-fw"
}

@test "LLM 访问控制：不确认就只盘点" {
  env_conf
  stub ops/check-llm-security 0; stub ops/sync-llm-allowlist 0
  drive opsbox 3 2 "" n "" 0 q
  calls_are "ops/check-llm-security"
}

@test "Vaultwarden 升级：先做新备份，再升级" {
  stub ops/upgrade-vaultwarden 0
  local_stub vw-fullbackup
  drive opsbox 5 2 "" y y "" 0 q
  calls_are "ops/upgrade-vaultwarden" "local/vw-fullbackup" "ops/upgrade-vaultwarden -y"
}

@test "Vaultwarden 升级：备份失败且不坚持，就不升级" {
  stub ops/upgrade-vaultwarden 0
  local_stub vw-fullbackup 1
  drive opsbox 5 2 "" y y n "" 0 q
  calls_are "ops/upgrade-vaultwarden" "local/vw-fullbackup"
}

# ── 本地备份与锁 ────────────────────────────────────────────
@test "立即备份：跑本地脚本，用 crontab 里的同一把锁" {
  local_stub vw-fullbackup
  echo '30 3 * * * flock -w 3600 /tmp/fb.lock /usr/local/bin/vw-fullbackup.sh >> /dev/null 2>&1' | crontab -
  drive opsbox 2 2 "" y "" 0 q
  has "flock -n /tmp/fb.lock /usr/local/bin/vw-fullbackup.sh"
  calls_are "local/vw-fullbackup"
}

@test "立即备份：锁被占用时不跑并提示" {
  local_stub vw-fullbackup
  echo '30 3 * * * flock /tmp/fb.lock /usr/local/bin/vw-fullbackup.sh' | crontab -
  flock /tmp/fb.lock sleep 60 &
  local holder=$!
  sleep 0.3
  drive opsbox 2 2 "" y "" 0 q
  kill "$holder" 2>/dev/null
  has "锁被占用"
  [ -z "$(calls)" ]
}

# ── 向导 ────────────────────────────────────────────────────
@test "初始化向导：回车执行下一步并记住进度，头部提示下一步" {
  stub init/00-precheck 0
  drive opsbox 6 "" "" y "" 0 "" q
  calls_are "init/00-precheck"
  [[ "$(state)" == *"INIT_DONE=00"* ]]
  drive opsbox q
  has "初始化进行中：下一步 01"
}

@test "初始化向导：阶段 03 主机名不符就不执行" {
  stub init/03-ssh-firewall 0
  drive opsbox 6 "" 03 y wrong-host "" 0 "" q
  [ -z "$(calls)" ]
}

@test "初始化向导：阶段 03 过两道确认后执行，并记下待重启" {
  stub init/03-ssh-firewall 0
  drive opsbox 6 "" 03 y ops-test yes n "" 0 "" q
  calls_are "init/03-ssh-firewall"
  [[ "$(state)" == *"INIT_BOOT="* ]]
  drive opsbox q
  has "需先重启"
}

@test "迁移向导：记住角色，只列这台该跑的步骤" {
  drive opsbox 8 "" 1 0 "" q
  has "冷快照"
  lacks "修正数据库账号"
  [[ "$(state)" == *"MIG_ROLE=out"* ]]
}

@test "迁移向导：停服步骤主机名不符就不执行" {
  stub migrate/03-pre-migrate 0
  mkdir -p /var/lib/ops-scripts; echo MIG_ROLE=out > /var/lib/ops-scripts/opsbox.state
  drive opsbox 8 "" 03 wrong-host "" 0 "" q
  [ -z "$(calls)" ]
}

# ── 工具箱设置 ──────────────────────────────────────────────
@test "更新工具箱：菜单本身有新版时自动重新载入" {
  echo '# 新版本' >> "$MOCK/main/bin/opsbox"
  drive opsbox 9 1 "" q
  has "菜单本身也更新了"
  [ "$status" -eq 0 ]
}

@test "定时任务：按文档添加每周云端备份校验" {
  local_stub verify-backup-pass
  drive opsbox 9 5 "" y "" 0 q
  crontab -l | grep -q 'verify-backup-pass.sh --cron'
}

# ── 会读 env.conf 的脚本（真机上发现：没 env.conf 时巡检里直接报错退出） ──
@test "一键巡检：会读 env.conf 的项在没有 env.conf 时算未配置跳过" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  stub ops/ssl-audit 0 WWWROOT
  stub ops/check-llm-security 0 LITELLM_SITE
  stub_loadenv ops/komari-metrics-check
  stub_loadenv ops/script-inventory
  drive opsbox a "" "" q
  [ -z "$(calls)" ]
  [ "$(grep -c '^  未配置' <<<"$output")" -eq 5 ]
}

@test "缺 env.conf 文件：引导建好后重新执行" {
  stub_loadenv ops/script-inventory
  drive opsbox 1 7 "" y "" 0 q
  has "还缺配置：env.conf"
  [ -f /etc/ops-scripts/env.conf ]
  calls_are "ops/script-inventory"
}

@test "头部：用提交号覆盖时缩短显示，不撑出一行" {
  export OPS_REF=b49ee19df100dec0ef13230b8f676617e0a320c7
  drive opsbox q
  has "b49ee19df100…（环境变量覆盖）"
  lacks "b49ee19df100dec0ef13230b8f676617e0a320c7"
}

# ── 逐项填写配置（新机器上少敲命令） ──────────────────────
@test "头部提示已装功能还有几项配置没填、去哪填" {
  stub ops/preflight-backup 0 BACKUP_DIRS BACKUP_SCRIPTS
  opsget -i ops/preflight-backup >/dev/null
  drive opsbox q
  has "还有 2 项配置没填 → 9 工具箱设置 → 4 配置管理"
}

@test "配置管理：逐项填写已装功能缺的配置，回车跳过" {
  stub ops/preflight-backup 0 BACKUP_DIRS BACKUP_SCRIPTS
  opsget -i ops/preflight-backup >/dev/null
  drive opsbox 9 4 "" 1 "/a /b" "" "" 0 q
  has "还有 2 项没填"
  has "已跳过"
  has "还没填：BACKUP_SCRIPTS"
  grep -qx "BACKUP_DIRS='/a /b'" /etc/ops-scripts/env.conf
  ls /etc/ops-scripts/env.conf.bak.* >/dev/null   # 改之前留了备份
}

@test "填写的值原样保存：引号、$、反斜杠、空格都不走样" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  opsget -i ops/preflight-backup >/dev/null
  local v='it'"'"'s $HOME "x" a\b'
  drive opsbox 9 4 "" 1 "$v" "" 0 q
  got=$(bash -c '. /etc/ops-scripts/env.conf; printf %s "$BACKUP_DIRS"')
  [ "$got" = "$v" ]
}

@test "凭据类输入不回显，查看配置时打码" {
  stub ops/newapi-log-prune 0 NEWAPI_ROOT_PAT
  opsget -i ops/newapi-log-prune >/dev/null
  drive opsbox 9 4 "" 1 sekret-token-123 "" 0 q
  lacks "sekret-token-123"
  grep -q "sekret-token-123" /etc/ops-scripts/env.conf
  drive opsbox 9 4 "" 2 "" 0 q
  has "sekr***"
  lacks "sekret-token-123"
}

@test "一键巡检有跳过项时，提示怎么启用" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  stub ops/ssl-audit 0; stub ops/check-llm-security 0
  stub ops/komari-metrics-check 0; stub ops/script-inventory 0
  drive opsbox a "" "" q
  has "要启用哪一项，就在「日常巡检」里单独选它执行"
}

# ── 真机第二轮：服务不存在、空配置 ──────────────────────────
daily_stubs() {  # 一键巡检里的其余几项都放成通过的桩
  stub ops/preflight-backup 0; stub ops/ssl-audit 0; stub ops/check-llm-security 0
  stub ops/script-inventory 0
}

@test "一键巡检：本机没有 MySQL 时，监控库体检算「不适用」而不是异常" {
  env_conf "MYSQL_DEFAULTS_FILE=/nonexistent/.my.cnf"
  daily_stubs; stub ops/komari-metrics-check 0 MYSQL_DEFAULTS_FILE
  drive opsbox a "" "" q
  calls_are "ops/preflight-backup" "ops/ssl-audit" "ops/check-llm-security" "ops/script-inventory"
  has "本机没有 MySQL"
  grep -q '^  不适用 *监控指标库体检' <<<"$output"
  lacks "异常"
}

@test "一键巡检：有 MySQL 时照常跑监控库体检" {
  env_conf "MYSQL_DEFAULTS_FILE=/root/.my.cnf"
  touch /root/.my.cnf
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/mysql; chmod 755 /usr/local/bin/mysql
  daily_stubs; stub ops/komari-metrics-check 0 MYSQL_DEFAULTS_FILE
  drive opsbox a "" "" q
  calls_are "ops/preflight-backup" "ops/ssl-audit" "ops/check-llm-security" \
            "ops/komari-metrics-check" "ops/script-inventory"
  rm -f /root/.my.cnf
}

@test "查看配置：还没有任何配置项时，说清楚怎么加" {
  env_conf "# 只有说明头"
  drive opsbox 9 4 "" 2 "" 0 q
  has "逐项填写本机还没填的配置"          # 卡片说明是新功能，不再是「直接编辑」
  lacks "直接编辑 env.conf"
  has "还没有任何配置项"
}

# ── 输入容错（真机第三轮：第一次按 a 菜单只是默默刷新） ─────
@test "输入容错：首尾空格、全角字母和问号都能识别" {
  drive opsbox " ？ " 0 "ｑ"
  [ "$status" -eq 0 ]
  has "按要办的事找"
}

@test "输入容错：认不出的输入明确提示，不默默刷新" {
  drive opsbox zz q
  has "没有这个选项：「zz」"
}

@test "说明卡片上全角０也是返回，不会误执行" {
  stub ops/ssl-audit 0
  drive opsbox 1 3 "０" 0 q
  [ -z "$(calls)" ]
}

# ── 更新已装脚本（生产机上 22 个脚本落后于固定版本） ──────
two_outdated() {  # 装两个脚本，再让仓库里两个都出新版
  opsget -i ops/save-fw >/dev/null; opsget -i ops/ssl-audit >/dev/null
  stub ops/save-fw 0; stub ops/ssl-audit 0
}

@test "更新已装脚本：列出落后的，全部更新，旧版留备份，只更新不执行" {
  two_outdated
  drive opsbox 9 2 "" a y "" 0 q
  has "ops/save-fw"
  has "ops/ssl-audit"
  cmp /usr/local/bin/save-fw.sh "$MOCK/main/ops/save-fw.sh"
  cmp /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
  ls /usr/local/bin/ssl-audit.sh.bak.* >/dev/null
  [ -z "$(calls)" ]
}

@test "更新已装脚本：只更新选中的" {
  two_outdated
  drive opsbox 9 2 "" 2 y "" 0 q
  cmp /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
  ! cmp -s /usr/local/bin/save-fw.sh "$MOCK/main/ops/save-fw.sh"
}

@test "更新已装脚本：不确认就什么都不动" {
  two_outdated
  drive opsbox 9 2 "" a n "" 0 q
  ! cmp -s /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
}

@test "更新已装脚本：都一致时直接说" {
  opsget -i ops/save-fw >/dev/null
  drive opsbox 9 2 "" "" 0 q
  has "都和固定版本一致"
}

@test "更新已装脚本：定时任务在用的标出来，更新后提醒手动跑一次" {
  two_outdated
  echo '0 3 * * * /usr/local/bin/ssl-audit.sh >/dev/null 2>&1' | crontab -
  drive opsbox 9 2 "" a y "" 0 q
  has "定时任务在用"
  has "建议现在手动跑一次：/usr/local/bin/ssl-audit.sh"
}

@test "更新工具箱之后顺便检查已装脚本" {
  two_outdated
  drive opsbox 9 1 "" y a y "" 0 q
  cmp /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
}

@test "本机脚本盘点的说明不再承诺比较版本，并指向更新已装脚本" {
  drive opsbox 1 0 q
  lacks "版本有没有落后"
  drive opsbox "?" 0 q
  has "本机脚本落后于固定版本"
}

# ── 启动时检查更新 ──────────────────────────────────────────
upd_cache() { cat /var/lib/ops-scripts/opsbox.updates 2>/dev/null; }

@test "启动检查：发现更新时头部提示，并出现 u 一键更新" {
  two_outdated
  opsbox --check-updates
  drive opsbox q
  has "发现 2 个更新"
  has "[u] 一键更新"
}

@test "启动检查：都一致时显示已是最新，不出现 u" {
  opsbox --check-updates
  drive opsbox q
  has "已是最新"
  lacks "[u] 一键更新"
}

@test "启动检查在后台跑：菜单马上出来，稍后结果写进缓存" {
  unset OPSBOX_NO_CHECK
  drive opsbox q
  has "正在后台检查更新"
  local i; for i in $(seq 100); do [ -s /var/lib/ops-scripts/opsbox.updates ] && break; sleep 0.2; done
  [[ "$(upd_cache)" == main$'\t'*$'\t'ok* ]]
}

@test "一键更新：列出后确认一次就全部更新（含菜单本身，并自动重新载入）" {
  two_outdated
  echo '# 新版本' >> "$MOCK/main/bin/opsbox"
  opsbox --check-updates
  drive opsbox u y q
  has "菜单本身也更新了"
  cmp /usr/local/bin/opsbox "$MOCK/main/bin/opsbox"
  cmp /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
  cmp /usr/local/bin/save-fw.sh "$MOCK/main/ops/save-fw.sh"
  [ -z "$(calls)" ]
}

@test "一键更新：不确认就什么都不动" {
  two_outdated
  opsbox --check-updates
  drive opsbox u n "" q
  ! cmp -s /usr/local/bin/ssl-audit.sh "$MOCK/main/ops/ssl-audit.sh"
}

@test "检查失败时如实提示，不假装已是最新" {
  OPS_REPO=http://127.0.0.1:1 opsbox --check-updates
  drive opsbox q
  has "更新检查失败"
  lacks "已是最新"
}

@test "切换固定版本后，旧的检查结果作废" {
  two_outdated
  opsbox --check-updates
  mkdir -p /etc/ops-scripts; echo v2099.01.01 > /etc/ops-scripts/ref
  drive opsbox q
  lacks "发现 2 个更新"
}

@test "主菜单直接回车是刷新，不报「没有这个选项」" {
  drive opsbox "" q
  lacks "没有这个选项"
}

# ── 测试机第四轮 ─────────────────────────────────────────────
@test "一键更新后立刻重新检查，头部不停在「还没检查」" {
  two_outdated
  opsbox --check-updates
  unset OPSBOX_NO_CHECK
  drive opsbox u y "" q
  lacks "还没检查"
}

@test "逐项填写：模板有默认值的项也列出来，显示默认值，回车保留" {
  stub ops/komari-metrics-check 0 MYSQL_DEFAULTS_FILE
  opsget -i ops/komari-metrics-check >/dev/null
  env_conf "# 只有说明头"
  drive opsbox 9 4 "" 1 "" "" 0 q
  has "还有 1 项没填"
  has "当前：/root/.my.cnf"
  has "/root/.my.cnf 现在不存在"
  lacks "都填好了"
  grep -q '^MYSQL_DEFAULTS_FILE="/root/.my.cnf"' /etc/ops-scripts/env.conf
}

# ── 测试机第五轮：屏幕上显示「1^H^H^H」，实际内容却是空，回车触发了初始化阶段 00 ──
# 终端的退格键发 ^H、tty 认的删除键是 DEL 时，内核把 ^H 原样回显。事后在程序里把它当删除，
# 修的只是内容，屏幕照样是一串 ^H —— 看到的和实际输入的对不上，才会误触发。
# 改成 read -e（bash 自带的行编辑）：两种删除键都真的删掉字符，看到什么就是什么。

@test "退格键：屏幕上不再出现 ^H，两种删除键（^H / DEL）都真正删掉字符" {
  drive opsbox $'3\b' $'x\x7f?' 0 q
  lacks "^H"
  lacks "^?"
  lacks "没有这个选项"
  has "按要办的事找"
}

@test "向导：选了阶段不确认就不执行" {
  stub init/00-precheck 0
  drive opsbox 6 "" "" n 0 "" q
  has "执行阶段 00"
  [ -z "$(calls)" ]
}

@test "向导：输入删光后回车也只是「选中下一步」，仍要确认才执行" {
  stub init/00-precheck 0
  drive opsbox 6 "" $'1\b\b\b' n 0 "" q
  has "执行阶段 00"
  [ -z "$(calls)" ]
}

@test "填配置值：删除键真正删掉字符，文件里不会有控制字符" {
  stub ops/preflight-backup 0 BACKUP_DIRS
  drive opsbox 1 2 "" y $'/bakx\b' "" 0 q
  grep -qx "BACKUP_DIRS='/bak'" /etc/ops-scripts/env.conf
  lacks "^H"
}
