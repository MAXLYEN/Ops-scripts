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
  drive opsbox 9 5 "" wrong-host "" 0 q
  has "主机名不符"
  calls_are "ops/cleanup-purge"
}

@test "高危：输对主机名才执行" {
  stub ops/cleanup-purge 0
  drive opsbox 9 5 "" ops-test "" 0 q
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
@test "一键巡检：未配置的跳过，异常的照跑，最后汇总" {
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
  drive opsbox 6 "" "" "" 0 "" q
  calls_are "init/00-precheck"
  [[ "$(state)" == *"INIT_DONE=00"* ]]
  drive opsbox q
  has "初始化进行中：下一步 01"
}

@test "初始化向导：阶段 03 主机名不符就不执行" {
  stub init/03-ssh-firewall 0
  drive opsbox 6 "" 03 wrong-host "" 0 "" q
  [ -z "$(calls)" ]
}

@test "初始化向导：阶段 03 过两道确认后执行，并记下待重启" {
  stub init/03-ssh-firewall 0
  drive opsbox 6 "" 03 ops-test yes n "" 0 "" q
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
  drive opsbox 9 4 "" y "" 0 q
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
  has "还有 2 项配置没填 → 9 工具箱设置 → 3 配置管理"
}

@test "配置管理：逐项填写已装功能缺的配置，回车跳过" {
  stub ops/preflight-backup 0 BACKUP_DIRS BACKUP_SCRIPTS
  opsget -i ops/preflight-backup >/dev/null
  drive opsbox 9 3 "" 1 "/a /b" "" "" 0 q
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
  drive opsbox 9 3 "" 1 "$v" "" 0 q
  got=$(bash -c '. /etc/ops-scripts/env.conf; printf %s "$BACKUP_DIRS"')
  [ "$got" = "$v" ]
}

@test "凭据类输入不回显，查看配置时打码" {
  stub ops/newapi-log-prune 0 NEWAPI_ROOT_PAT
  opsget -i ops/newapi-log-prune >/dev/null
  drive opsbox 9 3 "" 1 sekret-token-123 "" 0 q
  lacks "sekret-token-123"
  grep -q "sekret-token-123" /etc/ops-scripts/env.conf
  drive opsbox 9 3 "" 2 "" 0 q
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
