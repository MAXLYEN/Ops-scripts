#!/usr/bin/env bats
# tests/opsctl.bats — 隔离 sshd 中验证 OpsDeck 受限账号、协议、审计和密钥吊销。

ROOT=/tmp/opsctl-test
KEY1=$ROOT/computer-one
KEY2=$ROOT/computer-two
KEY3=$ROOT/computer-three
HOST=127.0.0.1
PORT=22
ID1=11111111-1111-4111-8111-111111111111
ID2=22222222-2222-4222-8222-222222222222
ID3=44444444-4444-4444-8444-444444444444
REQ=33333333-3333-4333-8333-333333333333

install_request() {
  local computer_id=$1 public_key=$2 host_fp
  host_fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | awk '{print $2}')
  jq -nc --arg id "$computer_id" --arg key "$public_key" --arg host "$host_fp" \
    '{version:1,computer_id:$id,public_key:$key,expected_host_fingerprint:$host}' \
    | python3 "$ROOT/bootstrap.py"
}

remote() {
  local key=$1 payload=$2
  printf '%s\n' "$payload" | ssh -q -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$key" "opsdeck@$HOST" opsctl
}

request() {
  local action=$1 params=$2
  jq -nc --arg id "$REQ" --arg action "$action" --argjson params "$params" \
    '{version:1,id:$id,action:$action,params:$params}'
}

setup_file() {
  mkdir -p "$ROOT" /run/sshd
  chmod 700 "$ROOT"
  install -m 600 /src/opsctl/bootstrap.py "$ROOT/bootstrap.py"
  ssh-keygen -A >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$KEY1"
  ssh-keygen -q -t ed25519 -N '' -f "$KEY2"
  ssh-keygen -q -t ed25519 -N '' -f "$KEY3"
  echo 'root:opsctl-test-only' | chpasswd
  cat > /etc/ssh/sshd_config <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Port 22
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
Subsystem sftp internal-sftp
PidFile /run/sshd-opsctl.pid
EOF
  python3 -c "import runpy; b=runpy.run_path('/src/opsctl/bootstrap.py'); d=runpy.run_path('/src/tests/opsctl-dev-server.py'); open('/etc/ssh/sshd_config','a',encoding='ascii').write(b['SSHD_TEXT']+d['JUMP_MATCH'])"
  python3 /src/tests/opsctl-journal.py &
  echo $! > "$ROOT/journal.pid"
  for _ in 1 2 3 4 5; do [ -S /run/systemd/journal/socket ] && break; sleep 0.1; done
  /usr/sbin/useradd --system --home-dir "$ROOT/untrusted-home" --shell /bin/sh opsdeck
  install_request "$ID1" "$(cat "$KEY1.pub")" > "$ROOT/untrusted.json" || true
  /usr/sbin/userdel opsdeck
  jq -e '.error.code == "UNTRUSTED_STATE"' "$ROOT/untrusted.json" >/dev/null
  [ ! -e /etc/opsctl ]
  printf 'UnknownOpsctlTestDirective yes\n' > /etc/ssh/sshd_config.d/99-opsctl-test-invalid.conf
  install_request "$ID1" "$(cat "$KEY1.pub")" > "$ROOT/rollback.json" || true
  rm /etc/ssh/sshd_config.d/99-opsctl-test-invalid.conf
  jq -e '.error.code == "INSTALL_FAILED"' "$ROOT/rollback.json" >/dev/null
  [ ! -e /etc/opsctl ] && [ ! -e /usr/local/bin/opsctl ] && ! getent passwd opsdeck >/dev/null
  if ! install_request "$ID1" "$(cat "$KEY1.pub")" > "$ROOT/install-one.json"; then
    cat "$ROOT/install-one.json"
    return 1
  fi
  jq -e '.ok == true' "$ROOT/install-one.json" >/dev/null
  if ! install_request "$ID2" "$(cat "$KEY2.pub")" > "$ROOT/install-two.json"; then
    cat "$ROOT/install-two.json"
    return 1
  fi
  jq -e '.ok == true' "$ROOT/install-two.json" >/dev/null
  python3 -c "import runpy; runpy.run_path('/src/tests/opsctl-dev-server.py')['configure_jump']()"
  /usr/sbin/sshd -D -e > "$ROOT/sshd.log" 2>&1 &
  echo $! > "$ROOT/sshd.pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ssh-keyscan -T 1 -p "$PORT" -t ed25519 "$HOST" > "$ROOT/known_hosts" 2>/dev/null && [ -s "$ROOT/known_hosts" ] && break
    sleep 0.1
  done
  [ -s "$ROOT/known_hosts" ]
}

teardown_file() {
  [ ! -f "$ROOT/sshd.pid" ] || kill "$(cat "$ROOT/sshd.pid")" 2>/dev/null || true
  [ ! -f "$ROOT/journal.pid" ] || kill "$(cat "$ROOT/journal.pid")" 2>/dev/null || true
}

@test "opsctl：不可信同名账号拒绝且失败安装完整回滚" {
  jq -e '.error.code == "UNTRUSTED_STATE"' "$ROOT/untrusted.json" >/dev/null
  jq -e '.error.code == "INSTALL_FAILED"' "$ROOT/rollback.json" >/dev/null
  [ -e /etc/opsctl/asset.json ]
}

@test "opsctl：首次主机指纹未知或变化时在认证前拒绝" {
  : > "$ROOT/unknown_hosts"
  run ssh -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$ROOT/unknown_hosts" -i "$KEY1" "opsdeck@$HOST" opsctl
  [ "$status" -ne 0 ]
  ssh-keygen -q -t ed25519 -N '' -f "$ROOT/wrong_host"
  printf '%s %s\n' "$HOST" "$(cat "$ROOT/wrong_host.pub" | cut -d' ' -f1,2)" > "$ROOT/changed_hosts"
  run ssh -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$ROOT/changed_hosts" -i "$KEY1" "opsdeck@$HOST" opsctl
  [ "$status" -ne 0 ]
}

@test "opsctl：错误 root 密码被拒绝" {
  run sshpass -p wrong-password ssh -p "$PORT" -o NumberOfPasswordPrompts=1 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" "root@$HOST" true
  [ "$status" -ne 0 ]
  run sshpass -p opsctl-test-only sftp -q -P "$PORT" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" "root@$HOST"
  [ "$status" -eq 0 ] || { echo "$output"; tail -n 10 "$ROOT/sshd.log"; }
  [ "$status" -eq 0 ]
}

@test "opsctl：受限账号拒绝任意命令、PTY 与 direct-tcpip" {
  run ssh -q -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck@$HOST" id
  [ "$status" -eq 0 ] || { echo "$output"; tail -n 15 "$ROOT/sshd.log"; }
  [ "$status" -ne 0 ]
  [[ "$output" == *SSH_COMMAND_DENIED* ]]
  run timeout 5 ssh -tt -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck@$HOST" opsctl
  [ "$status" -ne 0 ]
  [[ "$output" == *"PTY allocation request failed"* ]]
  run timeout 5 ssh -W 127.0.0.1:22 -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck@$HOST"
  [ "$status" -ne 0 ]
  run timeout 5 sftp -q -b /dev/null -P "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck@$HOST"
  [ "$status" -ne 0 ]
}

@test "opsctl：测试跳板仅可转发登记的目标端口" {
  run timeout 5 ssh -W 127.0.0.1:22 -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck-jump@$HOST"
  [[ "$output" == *SSH-2.0* ]] || { echo "$output"; tail -n 20 "$ROOT/sshd.log"; }
  [[ "$output" == *SSH-2.0* ]]
  run timeout 5 ssh -W 127.0.0.1:23 -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/known_hosts" \
    -i "$KEY1" "opsdeck-jump@$HOST"
  [ "$status" -ne 0 ]
  [[ "$output" != *SSH-2.0* ]]
}

@test "opsctl：只读发现返回稳定资产且不改业务或授权文件" {
  before=$(sha256sum /etc/opsctl/authorized_keys /etc/opsctl/keys.json /etc/ssh/sshd_config)
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -eq 0 ] || { echo "$output"; tail -n 15 "$ROOT/sshd.log"; }
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .data.asset_id != "" and .data.os.id != ""' >/dev/null
  [ "$before" = "$(sha256sum /etc/opsctl/authorized_keys /etc/opsctl/keys.json /etc/ssh/sshd_config)" ]
  [ "$(echo "$output" | jq -r '.data.asset_id')" = "$(jq -r .data.asset_id "$ROOT/install-one.json")" ]
  fp=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-one.json")
  grep -Fq '"actor":"'"$fp"'"' /var/log/opsctl/audit-*.jsonl
  run su -s /bin/sh opsdeck -c 'echo unauthorized >> /etc/opsctl/authorized_keys'
  [ "$status" -ne 0 ]
}

@test "opsctl：未知动作、额外参数及错误 plan_id 被拒绝" {
  run remote "$KEY1" "$(request shell.run '{}')"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "ACTION_DENIED"' >/dev/null
  run remote "$KEY1" "$(request host.discover '{"unexpected":1}')"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "INVALID_REQUEST"' >/dev/null
  run remote "$KEY1" "$(jq -nc --arg id "$REQ" '{version:1,id:$id,action:"host.discover",params:{},actor:"forged"}')"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "INVALID_REQUEST"' >/dev/null
  fp=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-two.json")
  run remote "$KEY1" "$(request key.revoke "$(jq -nc --arg fp "$fp" '{fingerprint:$fp,plan_id:("0"*64)}')")"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "PLAN_MISMATCH"' >/dev/null
}

@test "opsctl：重复安装不扩权，key revoke 后新连接失败" {
  before=$(sha256sum /etc/opsctl/authorized_keys /etc/sudoers.d/opsctl /etc/ssh/sshd_config.d/90-opsctl.conf)
  run install_request "$ID1" "$(cat "$KEY1.pub")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true' >/dev/null
  [ "$before" = "$(sha256sum /etc/opsctl/authorized_keys /etc/sudoers.d/opsctl /etc/ssh/sshd_config.d/90-opsctl.conf)" ]
  [ "$(jq length /etc/opsctl/keys.json)" -eq 2 ]
  fp=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-two.json")
  plan_payload=$(request plan "$(jq -nc --arg fp "$fp" '{action:"key.revoke",fingerprint:$fp}')")
  plan_reply=$(remote "$KEY1" "$plan_payload")
  plan=$(echo "$plan_reply" | jq -r .data.plan_id)
  run remote "$KEY1" "$(request key.revoke "$(jq -nc --arg fp "$fp" --arg plan "$plan" '{fingerprint:$fp,plan_id:$plan}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .data.remaining_keys == 1' >/dev/null
  run remote "$KEY2" "$(request host.discover '{}')"
  [ "$status" -ne 0 ]
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -eq 0 ]
  grep -q '"action":"key.revoke"' /tmp/opsctl-journal.log
  grep -q '"action":"key.revoke"' /var/log/opsctl/audit-*.jsonl
}

@test "opsctl：吊销最终审计写入失败时恢复授权文件" {
  fp=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-one.json")
  before=$(sha256sum /etc/opsctl/keys.json /etc/opsctl/authorized_keys)
  plan_reply=$(remote "$KEY1" "$(request plan "$(jq -nc --arg fp "$fp" '{action:"key.revoke",fingerprint:$fp}')")")
  plan=$(echo "$plan_reply" | jq -r .data.plan_id)
  payload=$(request key.revoke "$(jq -nc --arg fp "$fp" --arg plan "$plan" '{fingerprint:$fp,plan_id:$plan}')")
  run python3 - "$fp" "$payload" <<'PY'
import io
import os
import runpy
import sys

fingerprint, request = sys.argv[1:]
service = runpy.run_path("/usr/local/lib/opsctl/opsctl.py")
real_audit = service["audit"]

def injected_audit(actor, action, params, plan_id, outcome):
    if action == "key.revoke" and outcome == "ok":
        raise OSError("simulated audit write failure")
    return real_audit(actor, action, params, plan_id, outcome)

service["serve"].__globals__["audit"] = injected_audit
os.environ["SUDO_USER"] = "opsdeck"
sys.argv = ["/usr/local/bin/opsctl", "--auth-key", fingerprint, "--ssh-ok", "1"]
sys.stdin = io.TextIOWrapper(io.BytesIO((request + "\n").encode()), encoding="utf-8")
raise SystemExit(service["serve"]())
PY
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "INTERNAL_ERROR"' >/dev/null
  [ "$before" = "$(sha256sum /etc/opsctl/keys.json /etc/opsctl/authorized_keys)" ]
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -eq 0 ]
}

@test "opsctl：匹配计划可吊销自己的最后一把密钥，root 可重新接入" {
  fp1=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-one.json")
  plan_reply=$(remote "$KEY1" "$(request plan "$(jq -nc --arg fp "$fp1" '{action:"key.revoke",fingerprint:$fp}')")")
  plan=$(echo "$plan_reply" | jq -r .data.plan_id)
  run remote "$KEY1" "$(request key.revoke "$(jq -nc --arg fp "$fp1" --arg plan "$plan" '{fingerprint:$fp,plan_id:$plan}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.remaining_keys == 0' >/dev/null
  [ "$(jq length /etc/opsctl/keys.json)" -eq 0 ]
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -ne 0 ]
  run install_request "$ID1" "$(cat "$KEY1.pub")"
  [ "$status" -eq 0 ]
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -eq 0 ]
}

@test "opsctl：任务执行闭环（plan/apply/status/verify/jobs.list）、安全基线与角色模板" {
  run remote "$KEY1" "$(request security.scan '{}')"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .data.gate_passed == true' >/dev/null

  plan_reply=$(remote "$KEY1" "$(request plan '{"action":"security.fix","params":{"save_baseline":true}}')")
  plan=$(echo "$plan_reply" | jq -r .data.plan_id)
  job_id="55555555-5555-4555-8555-555555555555"

  run remote "$KEY1" "$(request apply "$(jq -nc --arg jid "$job_id" --arg pid "$plan" '{job_id:$jid,action:"security.fix",plan_id:$pid,params:{save_baseline:true}}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .data.status == "succeeded" and .data.verified == false' >/dev/null

  # 相同 job_id 幂等重放不报错且返回原任务
  run remote "$KEY1" "$(request apply "$(jq -nc --arg jid "$job_id" --arg pid "$plan" '{job_id:$jid,action:"security.fix",plan_id:$pid,params:{save_baseline:true}}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg jid "$job_id" '.data.job_id == $jid' >/dev/null

  # 断线续读 status 与独立验收 verify
  run remote "$KEY1" "$(request status "$(jq -nc --arg jid "$job_id" '{job_id:$jid,after_seq:1}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.events | length) >= 2' >/dev/null

  run remote "$KEY1" "$(request verify "$(jq -nc --arg jid "$job_id" '{job_id:$jid}')")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.verified == true and .data.verification.passed == true' >/dev/null

  run remote "$KEY1" "$(request jobs.list '{"limit":10}')"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.jobs | length) >= 1' >/dev/null
}

@test "opsctl：root 手工吊销最后一把密钥有审计" {
  run install_request "$ID3" "$(cat "$KEY3.pub")"
  [ "$status" -eq 0 ]
  fp=$(echo "$output" | jq -r .data.authorized_key_fingerprint)
  run /usr/local/bin/opsctl-admin keys list
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg fp "$fp" '.data.keys | any(.fingerprint == $fp)' >/dev/null
  run /usr/local/bin/opsctl-admin key revoke "$fp"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.remaining_keys == 1' >/dev/null
  run remote "$KEY3" "$(request host.discover '{}')"
  [ "$status" -ne 0 ]
  fp1=$(jq -r .data.authorized_key_fingerprint "$ROOT/install-one.json")
  run /usr/local/bin/opsctl-admin key revoke "$fp1"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.remaining_keys == 0' >/dev/null
  run remote "$KEY1" "$(request host.discover '{}')"
  [ "$status" -ne 0 ]
  grep -q '"actor":"root.local"' /var/log/opsctl/audit-*.jsonl
}
