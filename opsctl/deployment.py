#!/usr/bin/python3
# VERSION: 3.0.0
# MENU-EXCLUDE: installed by the verified opsctl bootstrap, never by opsget.
"""Durable, allowlisted deployment runner. This source is embedded in bootstrap.py.

The SSH process only validates/enqueues JSON. This module's daemon, started by
systemd independently of SSH, is the only process that runs deployment commands.
All destinations, artifacts and credential paths come from a root-owned policy.
"""

import base64
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import socket
import ssl
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

CORE = None
POLICY = pathlib.Path('/etc/opsctl/deployment.json')
MODULE = pathlib.Path('/usr/local/lib/opsctl/deployment.py')
SERVICE = pathlib.Path('/etc/systemd/system/opsctl-runner.service')
MAX_HTTP = 8 * 1024 * 1024
TERMINAL = {'succeeded', 'failed', 'rolled_back', 'rollback_failed', 'cancelled'}
DOMAIN = re.compile(r'(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\Z')
WORKER_ACTIONS = {'initialize', 'hardening', 'certificate', 'reality', 'agents',
                  'firewall', 'restart', 'probe', 'rollback', 'confirm_firewall'}
SERVICE_TEXT = '''[Unit]
Description=OpsDeck fixed-action deployment runner
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 -I /usr/local/lib/opsctl/deployment.py --daemon
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
'''


def bind(core):
    global CORE, POLICY, MODULE
    CORE = core
    POLICY = core.ETC / 'deployment.json'
    MODULE = core.CODE.parent / 'deployment.py'


def fail(code, message):
    raise CORE.Rejected(code, message)


def owned_json(path):
    return json.loads(CORE.read_owned(path, 0o600), object_pairs_hook=CORE.unique_pairs)


def save(path, value):
    CORE.atomic_write(path, CORE.canonical(value) + b'\n', 0o600)


def directory(name):
    CORE.ensure_state_dirs()
    path = CORE.HOME / name
    if not path.exists():
        path.mkdir(mode=0o700)
    CORE.safe_dir(path, 0o700)
    return path


def private_path(jid):
    CORE.job_path(jid)  # validates UUID and the root-owned job directory
    return directory('deployment-private') / (jid + '.json')


def token(path):
    p = pathlib.Path(path)
    if not p.is_absolute():
        fail('POLICY_INVALID', '服务端凭据路径必须为绝对路径')
    value = CORE.read_owned(p, 0o600).decode().strip()
    if not value or len(value) > 16384 or '\n' in value or '\r' in value:
        fail('CREDENTIAL_INVALID', '服务端凭据文件为空或格式不正确')
    return value


def endpoint(url, test=False):
    parsed = urllib.parse.urlsplit(url)
    local = parsed.hostname in ('127.0.0.1', '::1', 'localhost')
    if (parsed.scheme != 'https' and not (test and local and parsed.scheme == 'http')
            or not parsed.hostname or parsed.username or parsed.password
            or parsed.fragment):
        fail('POLICY_INVALID', '服务端接口须使用 HTTPS，测试 HTTP 仅允许回环地址')
    return url.rstrip('/')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fail('HTTP_REDIRECT_DENIED', '接口重定向已拒绝，避免向其他地址发送凭据')


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        hosts = {old.hostname}
        if old.hostname == 'github.com':
            hosts.update(('release-assets.githubusercontent.com', 'objects.githubusercontent.com'))
        if new.scheme != 'https' or new.hostname not in hosts or new.username or new.password:
            fail('ARTIFACT_REDIRECT_DENIED', '软件包重定向超出固定下载源范围')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def http(url, method='GET', body=None, bearer=None, *, test=False):
    endpoint(url, test)
    headers = {'Accept': 'application/json', 'User-Agent': 'OpsDeck-opsctl/3.0'}
    if bearer:
        headers['Authorization'] = 'Bearer ' + bearer
    data = None if body is None else CORE.canonical(body)
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    # Never inherit HTTP_PROXY/HTTPS_PROXY from a root daemon's environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(req, timeout=20) as reply:
            raw = reply.read(MAX_HTTP + 1)
        if len(raw) > MAX_HTTP:
            fail('UPSTREAM_INVALID', '上游响应超出大小限制')
        return json.loads(raw, object_pairs_hook=CORE.unique_pairs)
    except urllib.error.HTTPError as exc:
        fail('UPSTREAM_HTTP_' + str(exc.code), '上游接口返回 HTTP ' + str(exc.code) + '；请核对服务端授权和接口版本')
    except (OSError, ValueError, urllib.error.URLError):
        fail('UPSTREAM_UNAVAILABLE', '上游接口连接或响应失败；任务已暂停，可修复后继续')


def load_policy():
    if not POLICY.exists():
        fail('DEPLOYMENT_NOT_CONFIGURED', '部署中心尚未配置：请在服务器配置 /etc/opsctl/deployment.json；未执行任何部署')
    policy = owned_json(POLICY)
    if not isinstance(policy, dict) or policy.get('schema_version') != 1:
        fail('POLICY_INVALID', '部署策略版本无效')
    if policy.get('mode') not in ('coordinator', 'worker'):
        fail('POLICY_INVALID', '部署策略角色必须是 coordinator 或 worker')
    if not DOMAIN.fullmatch(policy.get('domain_suffix', '')):
        fail('POLICY_INVALID', '部署策略缺少合法域名后缀')
    if not isinstance(policy.get('assets'), dict) or not policy['assets']:
        fail('POLICY_INVALID', '部署策略必须登记稳定资产及独立核对的主机公钥')
    ports = policy.get('entry_ports', [443, 8443, 2053, 2083, 2087, 2096])
    if not isinstance(ports, list) or len(ports) > 128 or any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        fail('POLICY_INVALID', '入口端口策略不合法')
    if type(policy.get('allow_custom_ports', True)) is not bool:
        fail('POLICY_INVALID', '自定义端口策略必须为布尔值')
    return policy


def asset(policy, aid):
    if not isinstance(aid, str) or not CORE.ID_RE.fullmatch(aid):
        fail('ASSET_DENIED', '部署目标必须使用稳定资产 UUID')
    value = policy.get('assets', {}).get(aid)
    if not isinstance(value, dict):
        fail('ASSET_DENIED', '目标尚未在服务端部署策略登记')
    ipaddress.ip_address(value['ip'])
    if (type(value.get('ssh_port')) is not int or not 1 <= value['ssh_port'] <= 65535
            or not isinstance(value.get('host_key'), str)
            or not value['host_key'].startswith('ssh-ed25519 ')):
        fail('POLICY_INVALID', '资产缺少 SSH 端口或已独立核对的 Ed25519 主机公钥')
    CORE.public_key(value['host_key'])
    return value


def entry_port_allowed(policy, port):
    return (type(port) is int and 1 <= port <= 65535 and
            (policy.get('allow_custom_ports', True) or
             port in policy.get('entry_ports', [443, 8443, 2053, 2083, 2087, 2096])))


def normalize(policy, params):
    CORE.fields(params, ('target_asset_id', 'server_name', 'role', 'domain',
                         'node_ports', 'relay_bindings', 'init_system'),
                ('overwrite_ports',))
    target = asset(policy, params['target_asset_id'])
    domain = params['domain']
    if (params['role'] not in ('direct', 'landing') or type(params['init_system']) is not bool
            or not isinstance(params['server_name'], str) or not CORE.SAFE_NAME_RE.fullmatch(params['server_name'])
            or params['server_name'] != target.get('name')
            or not isinstance(domain, str) or not DOMAIN.fullmatch(domain)
            or domain != target.get('domain')
            or not domain.endswith('.' + policy['domain_suffix'])):
        fail('INVALID_DEPLOYMENT', '用途、名称或域名与服务端资产策略不匹配')
    ports = params['node_ports']
    if (not isinstance(ports, list) or len(ports) > 24
            or any(type(p) is not int or not 1 <= p <= 65535 for p in ports)
            or len(set(ports)) != len(ports)):
        fail('INVALID_DEPLOYMENT', '节点端口必须为不重复的 1–65535 整数，最多 24 个')
    bindings = params['relay_bindings']
    if not isinstance(bindings, list) or len(bindings) > 32:
        fail('INVALID_DEPLOYMENT', '中转绑定格式不正确')
    normalized = []
    seen, landing_ports = set(), set()
    for b in bindings:
        CORE.fields(b, ('relay_asset_id', 'landing_port', 'entry_port', 'internal_node', 'subscription_name'))
        relay = asset(policy, b['relay_asset_id'])
        if (b['relay_asset_id'] in seen or b['relay_asset_id'] == params['target_asset_id']
                or relay.get('role') != 'direct'
                or not entry_port_allowed(policy, b['entry_port'])
                or type(b['landing_port']) is not int or not 30000 <= b['landing_port'] <= 30999
                or b['landing_port'] in landing_ports
                or b['entry_port'] == relay['ssh_port']
                or not CORE.LABEL_RE.fullmatch(b['internal_node'])
                or not CORE.LABEL_RE.fullmatch(b['subscription_name'])):
            fail('INVALID_DEPLOYMENT', '中转入口、端口或名称不符合服务端策略')
        seen.add(b['relay_asset_id'])
        landing_ports.add(b['landing_port'])
        normalized.append(dict(b))
    if params['role'] == 'direct':
        if not ports or any(not entry_port_allowed(policy, p) for p in ports) or bindings:
            fail('INVALID_DEPLOYMENT', '直连节点端口不在服务端允许列表，或包含落地绑定')
    elif not bindings or ports:
        fail('INVALID_DEPLOYMENT', '落地机必须选择中转入口，节点端口由落地绑定生成')
    all_ports = ports + list(landing_ports)
    if target['ssh_port'] in all_ports or 8444 in all_ports:
        fail('PROTECTED_PORT', 'SSH 端口和 Reality 回源端口不能覆盖')
    overwrite = params.get('overwrite_ports', [])
    if not isinstance(overwrite, list) or any(type(p) is not int or p not in all_ports for p in overwrite):
        fail('INVALID_DEPLOYMENT', '覆盖端口必须属于本次目标端口')
    return {**params, 'node_ports': sorted(ports), 'overwrite_ports': sorted(set(overwrite)),
            'relay_bindings': sorted(normalized, key=lambda x: x['relay_asset_id'])}


class Panel:
    def __init__(self, policy):
        self.policy = policy
        self.spec = policy['xboard']
        self.base = endpoint(self.spec['url'], policy.get('test_mode') is True)
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', self.spec['admin_path']):
            fail('POLICY_INVALID', 'Xboard 管理路径不合法')
        self.root = self.base + '/api/v2/' + self.spec['admin_path'] + '/server/'

    def call(self, path, body=None):
        result = http(self.root + path, 'GET' if body is None else 'POST', body,
                      token(self.spec['token_file']), test=self.policy.get('test_mode') is True)
        if not isinstance(result, dict) or result.get('status') not in ('success', None) or 'data' not in result:
            fail('XBOARD_REJECTED', 'Xboard 返回失败或不支持当前 API 契约，请核对部署版本')
        return result['data']

    def nodes(self):
        rows = self.call('manage/getNodes')
        if not isinstance(rows, list) or any(not isinstance(r, dict) or type(r.get('id')) is not int for r in rows):
            fail('XBOARD_SCHEMA', 'Xboard 节点列表结构不匹配')
        return rows


class DNS:
    def __init__(self, policy):
        self.policy, self.spec = policy, policy['cloudflare']
        zone = self.spec['zone_id']
        if not re.fullmatch(r'[a-f0-9]{32}', zone):
            fail('POLICY_INVALID', 'Cloudflare Zone ID 不合法')
        base = self.spec.get('api_url', 'https://api.cloudflare.com/client/v4')
        self.root = endpoint(base, policy.get('test_mode') is True) + '/zones/' + zone + '/dns_records'

    def call(self, suffix='', method='GET', body=None):
        reply = http(self.root + suffix, method, body, token(self.spec['token_file']),
                     test=self.policy.get('test_mode') is True)
        if not isinstance(reply, dict) or reply.get('success') is not True:
            fail('DNS_REJECTED', 'Cloudflare 拒绝请求，请核对 Zone 与 DNS 编辑权限')
        return reply['result']

    def records(self, domain):
        rows = self.call('?name=' + urllib.parse.quote(domain, safe='') + '&per_page=100')
        if not isinstance(rows, list):
            fail('DNS_SCHEMA', 'Cloudflare 记录响应格式不正确')
        return rows


def policy_digest(policy):
    return CORE.digest(CORE.canonical(policy))


def health():
    path = CORE.HOME / 'runner-heartbeat.json'
    heartbeat = owned_json(path) if path.exists() else {}
    try:
        mode = load_policy()['mode']
    except CORE.Rejected:
        mode = None
    return {'ready': 0 <= time.time() - heartbeat.get('time', 0) < 15,
            'version': '3.0.0', 'policy_mode': mode}


def plan(policy, params, actor, core_asset):
    if policy['mode'] != 'coordinator':
        fail('COORDINATOR_REQUIRED', '完整部署计划需要连接已配置的汇总机')
    if not health()['ready']:
        fail('RUNNER_NOT_RUNNING', '部署中心 runner 未就绪，请检查 opsctl-runner 服务；未执行部署')
    norm = normalize(policy, params)
    if norm['target_asset_id'] == core_asset['asset_id']:
        fail('ASSET_DENIED', '部署中心不能通过节点初始化流程改造自身')
    panel, dns = Panel(policy), DNS(policy)
    rows, records = panel.nodes(), dns.records(norm['domain'])
    target = asset(policy, norm['target_asset_id'])
    # Existing DNS is only reused when already correct. Destructive replacement
    # needs a separately reviewed action; a countdown is not such authorization.
    if any(r.get('type') != 'A' or r.get('content') != target['ip'] or r.get('proxied') is not False for r in records):
        fail('DNS_CONFLICT', '已有 DNS 记录与目标不一致，请先核对记录后重新生成计划')
    machine_id = target.get('machine_id')
    target_ports_in_use = set(norm['node_ports']) | {b['landing_port'] for b in norm['relay_bindings']}
    if machine_id is not None and any(row.get('machine_id') == machine_id and str(row.get('server_port')) in {str(p) for p in target_ports_in_use} for row in rows):
        fail('PROTECTED_PORT', '目标机器的所选端口已有 Xboard 节点，不能新建重复监听节点')
    for b in norm['relay_bindings']:
        relay = asset(policy, b['relay_asset_id'])
        for row in rows:
            if (row.get('machine_id') == relay.get('machine_id')
                    and str(row.get('server_port')) == str(b['entry_port'])):
                fail('PROTECTED_PORT', '入口端口已被 Xboard 节点占用，不能覆盖其他落地机流量')
    for a in [target] + [asset(policy, b['relay_asset_id']) for b in norm['relay_bindings']]:
        if a.get('runner_version') != '3.0.0':
            fail('RUNNER_VERSION', '目标或入口未完成 opsctl 3.0.0 接管，请先升级并登记验收结果')
    snapshot = {'policy': policy_digest(policy), 'nodes': CORE.digest(CORE.canonical(rows)),
                'dns': CORE.digest(CORE.canonical(records))}
    identity = {'asset_id': core_asset['asset_id'], 'actor': actor, 'params': norm, 'snapshot': snapshot,
                'runner_sha256': CORE.DEPLOYMENT_SHA256, 'artifact_sha256': core_asset['artifact_sha256'],
                'job_id': str(uuid.uuid4())}
    pid = CORE.digest(CORE.canonical(identity))
    doc = {**identity, 'plan_id': pid, 'created_at': CORE.utc_now(), 'expires_at': time.time() + 900}
    save(directory('deployment-plans') / (pid + '.json'), doc)
    return {'plan_id': pid, 'job_id': identity['job_id'], 'action': 'deployment', 'params': norm,
            'summary': {'asset_id': core_asset['asset_id'], 'target_asset_id': norm['target_asset_id'],
                        'server_name': norm['server_name'], 'domain': norm['domain'], 'role': norm['role'], 'node_ports': norm['node_ports'],
                        'relay_count': len(norm['relay_bindings']), 'init_system': norm['init_system']},
            'steps': step_specs(norm), 'expires_in_seconds': 900}


def step_specs(params):
    steps = [('preflight', '逐机身份、版本与端口复检'),
             ('initialize', '系统初始化与必要重启检查'),
             ('hardening', '安全策略生效与独立检查'),
             ('registration', '汇总机登记与访问白名单'),
             ('dns', 'Cloudflare 灰云解析与读回'),
             ('certificate', '签发单机证书与安全下发'),
             ('reality', 'Reality 偷自己回源与 cloud-init 持久化'),
             ('panel', 'Xboard 机器与隐藏节点创建'),
             ('firewall', '目标机端口冲突处置、定向放行与独立连接确认'),
             ('agents', '固定版本探针和 xboard-node 安装')]
    steps += [('relay:' + b['relay_asset_id'], '中转入口放行、重启与逐入口试点验收') for b in params['relay_bindings']]
    steps += [('verify', 'Reality 证书及真实出口独立验收'), ('publish', '验收通过后发布订阅')]
    return [{'id': sid, 'title': title, 'status': 'pending'} for sid, title in steps]


def event(job, step, message):
    job['events'].append({'seq': len(job['events']) + 1, 'time': CORE.utc_now(), 'step': step, 'message': message})
    CORE.save_job(job)


def enqueue(core_asset, actor, params):
    CORE.fields(params, ('job_id', 'plan_id'))
    jid, pid = params['job_id'], params['plan_id']
    CORE.job_path(jid)
    if not isinstance(pid, str) or not CORE.HEX64_RE.fullmatch(pid):
        fail('INVALID_REQUEST', '部署计划 ID 无效')
    if CORE.job_path(jid).exists():
        job = CORE.load_job(jid)
        if job.get('actor') != actor or job.get('plan_id') != pid or job.get('action') != 'deployment':
            fail('JOB_CONFLICT', '任务 ID 已被其他计划占用')
        return job
    doc = owned_json(directory('deployment-plans') / (pid + '.json'))
    policy = load_policy()
    if (doc.get('actor') != actor or doc.get('job_id') != jid or doc.get('asset_id') != core_asset['asset_id']
            or doc.get('expires_at', 0) < time.time()
            or doc.get('runner_sha256') != CORE.DEPLOYMENT_SHA256
            or doc.get('artifact_sha256') != core_asset['artifact_sha256']
            or doc['snapshot']['policy'] != policy_digest(policy)):
        fail('PLAN_MISMATCH', '计划过期、策略或授权身份已变化，请重新预检确认')
    if CORE.digest(CORE.canonical(Panel(policy).nodes())) != doc['snapshot']['nodes'] or CORE.digest(CORE.canonical(DNS(policy).records(doc['params']['domain']))) != doc['snapshot']['dns']:
        fail('PLAN_MISMATCH', 'Xboard 或 DNS 在确认期间发生变化，请重新生成计划')
    save(private_path(jid), {'params': doc['params'], 'policy_sha256': policy_digest(policy),
                             'runner_sha256': CORE.DEPLOYMENT_SHA256, 'resources': [], 'values': {}})
    job = {'schema_version': 2, 'job_id': jid, 'asset_id': core_asset['asset_id'],
           'action': 'deployment', 'actor': actor, 'plan_id': pid, 'status': 'queued',
           'verified': False, 'started_at': CORE.utc_now(), 'events': [],
           'summary': {'target_asset_id': doc['params']['target_asset_id'], 'domain': doc['params']['domain'],
                       'server_name': doc['params']['server_name']},
           'steps': step_specs(doc['params']), 'result': {'deployment_verified': False}}
    event(job, 'job.queued', '部署任务已持久化，等待独立 runner；客户端断开不取消任务')
    return job


def control(core_asset, actor, params, operation):
    CORE.fields(params, ('job_id', 'plan_id'))
    job = CORE.load_job(params['job_id'])
    if job.get('action') != 'deployment' or job.get('actor') != actor or job.get('plan_id') != params['plan_id'] or job['asset_id'] != core_asset['asset_id']:
        fail('JOB_CONFLICT', '只能继续或撤销本人确认的部署任务')
    if job['status'] not in ('failed', 'waiting_reboot', 'waiting_external', 'rollback_failed', 'succeeded'):
        fail('JOB_RUNNING', '任务仍在运行或已终止，请先刷新状态')
    if operation == 'resume' and job['status'] == 'succeeded':
        return job
    if operation == 'resume' and owned_json(private_path(job['job_id']))['policy_sha256'] != policy_digest(load_policy()):
        fail('PLAN_MISMATCH', '部署策略已变化，不能沿用旧计划继续写入')
    job['status'] = 'queued' if operation == 'resume' else 'rollback_queued'
    job['verified'] = False
    job.pop('error', None)
    for step in job['steps']:
        if step['status'] in ('running', 'failed', 'waiting_reboot'):
            step['status'] = 'pending'
            step.pop('error', None)
    event(job, 'job.' + operation, '已请求从未通过步骤继续' if operation == 'resume' else '已请求撤销本任务可恢复资源；系统更新不回退')
    return job


def api(core_asset, actor, action, params):
    if action == 'deployment.plan':
        return plan(load_policy(), params, actor, core_asset)
    if action == 'deployment.apply':
        return enqueue(core_asset, actor, params)
    if action in ('deployment.resume', 'deployment.rollback'):
        return control(core_asset, actor, params, action.split('.')[1])
    if action == 'deployment.worker':
        return enqueue_worker(core_asset, actor, params)
    fail('ACTION_DENIED', '部署动作未在白名单中')


def command(argv, *, input_bytes=None, timeout=120):
    """Only internal handlers build argv; stdout/stderr never enter public jobs."""
    try:
        result = subprocess.run(argv, input=input_bytes, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False,
                                env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8',
                                     'DEBIAN_FRONTEND': 'noninteractive', 'NEEDRESTART_MODE': 'a'})
    except (OSError, subprocess.TimeoutExpired):
        fail('COMMAND_UNAVAILABLE', '固定动作超时或命令不可用：' + pathlib.Path(argv[0]).name)
    if result.returncode:
        fail('COMMAND_FAILED', '固定动作执行失败：' + pathlib.Path(argv[0]).name + '，退出码 ' + str(result.returncode) + '；请检查该服务的服务器日志')
    return result.stdout


def service_state(unit):
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+(?:\.service)?', unit):
        fail('PROTECTED_SERVICE', '服务名称不在固定动作允许格式内')
    try:
        active = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        enabled = subprocess.run(['/usr/bin/systemctl', 'is-enabled', unit],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        fail('SYSTEMD_REQUIRED', '真实部署需要可用的 systemd 服务管理器')
    return {'active': active.returncode == 0, 'enabled': enabled.stdout.decode().strip()}


def valid_worker(policy, core_asset, actor, params):
    if policy['mode'] != 'worker':
        fail('ACTION_DENIED', '汇总机编排角色不开放节点初始化动作')
    if actor not in policy.get('coordinator_fingerprints', []):
        fail('COORDINATOR_KEY_REQUIRED', '此动作仅允许服务器上独立登记的编排密钥')
    CORE.fields(params, ('job_id', 'operation', 'params'))
    CORE.job_path(params['job_id'])
    op, inner = params['operation'], params['params']
    if op not in WORKER_ACTIONS or not isinstance(inner, dict):
        fail('ACTION_DENIED', '远程固定动作未获允许')
    schemas = {
        'initialize': (('ssh_port',), ()), 'hardening': ((), ()),
        'certificate': (('domain', 'certificate', 'private_key'), ()),
        'reality': (('domain',), ()),
        'agents': (('machine_id', 'machine_token', 'panel_url', 'komari_token', 'komari_url', 'artifacts'), ('existing_komari',)),
        'firewall': (('ports', 'source_ips', 'overwrite_ports'), ()),
        'confirm_firewall': (('firewall_job_id',), ()),
        'restart': ((), ()),
        'probe': (('domain', 'ports'), ()),
        'rollback': (('worker_job_id',), ()),
    }
    CORE.fields(inner, *schemas[op])
    me = asset(policy, core_asset['asset_id'])
    if 'domain' in inner and inner['domain'] != me['domain']:
        fail('ASSET_DENIED', '证书与回源只能配置本资产已登记的域名')
    if op == 'initialize' and inner['ssh_port'] != me['ssh_port']:
        fail('PROTECTED_PORT', '初始化只允许保留已登记的 SSH 端口')
    if op in ('firewall', 'probe'):
        ports = inner['ports']
        if (not isinstance(ports, list) or not 1 <= len(ports) <= 32
                or any(type(p) is not int or p == me['ssh_port'] or p == 8444
                       or not (entry_port_allowed(policy, p) or 30000 <= p <= 30999) for p in ports)):
            fail('PROTECTED_PORT', '远程端口不符合工作机策略或碰到受保护端口')
    if op == 'firewall':
        sources = inner['source_ips']
        if not isinstance(sources, list) or len(sources) > 32:
            fail('INVALID_REQUEST', '来源列表格式不正确')
        for value in sources:
            ipaddress.ip_address(value)
        overwrite = inner['overwrite_ports']
        if not isinstance(overwrite, list) or any(type(p) is not int or p not in inner['ports'] for p in overwrite):
            fail('INVALID_REQUEST', '覆盖端口不属于本次放行端口')
    if op == 'certificate':
        if (not isinstance(inner['certificate'], str) or len(inner['certificate']) > 131072
                or not inner['certificate'].startswith('-----BEGIN CERTIFICATE-----')
                or not isinstance(inner['private_key'], str) or len(inner['private_key']) > 16384
                or not inner['private_key'].startswith('-----BEGIN PRIVATE KEY-----')):
            fail('INVALID_CERTIFICATE', '证书或私钥格式无效')
    if op == 'agents':
        if type(inner['machine_id']) is not int or inner['machine_id'] < 1:
            fail('INVALID_REQUEST', '机器 ID 不合法')
        for key in ('panel_url', 'komari_url'):
            if inner[key] != policy.get(key):
                fail('POLICY_MISMATCH', '探针或节点面板地址与工作机策略不一致')
        if inner['artifacts'] != policy.get('artifacts'):
            fail('POLICY_MISMATCH', '安装包与工作机固定版本清单不一致')
        for key in ('machine_token', 'komari_token'):
            if not isinstance(inner[key], str) or not inner[key] or len(inner[key]) > 4096 or any(c in inner[key] for c in '\n\r\x00'):
                fail('INVALID_REQUEST', '单机通讯凭据格式不正确')
    for key in ('worker_job_id', 'firewall_job_id'):
        if key in inner and (not isinstance(inner[key], str) or not CORE.ID_RE.fullmatch(inner[key])):
            fail('INVALID_REQUEST', '关联任务 ID 无效')


def enqueue_worker(core_asset, actor, params):
    policy = load_policy()
    valid_worker(policy, core_asset, actor, params)
    jid = params['job_id']
    request_hash = CORE.digest(CORE.canonical(params))
    if CORE.job_path(jid).exists():
        existing = CORE.load_job(jid)
        if existing.get('actor') != actor or existing.get('plan_id') != request_hash:
            fail('JOB_CONFLICT', '工作任务 ID 已被其他动作占用')
        # A failed child resumes only when its coordinator explicitly re-submits
        # this same immutable request. Successful children are never repeated.
        if existing['status'] in ('failed', 'waiting_reboot'):
            existing['status'] = 'queued'
            existing.pop('error', None)
            event(existing, 'worker.resumed', '编排中心已请求重试本固定动作')
        return existing
    save(private_path(jid), {'params': params['params'], 'resources': [], 'values': {},
                             'runner_sha256': CORE.DEPLOYMENT_SHA256,
                             'policy_sha256': policy_digest(policy)})
    job = {'schema_version': 2, 'job_id': jid, 'asset_id': core_asset['asset_id'],
           'actor': actor, 'action': 'deployment.worker', 'operation': params['operation'],
           'plan_id': request_hash, 'status': 'queued', 'verified': False,
           'started_at': CORE.utc_now(), 'events': [], 'result': {},
           'steps': [{'id': params['operation'], 'title': params['operation'], 'status': 'pending'}]}
    event(job, 'worker.queued', '固定动作已入队：' + params['operation'])
    return job


class Context:
    def __init__(self, job, policy):
        self.job, self.policy = job, policy
        self.secret = owned_json(private_path(job['job_id']))

    def persist(self):
        save(private_path(self.job['job_id']), self.secret)

    def resource(self, value):
        self.secret['resources'].append(value)
        self.persist()  # WAL: intent precedes the side effect.
        return value

    def write(self, path, payload, mode=0o600):
        path = pathlib.Path(path)
        parent = path.parent
        missing = []
        while not parent.exists():
            missing.append(parent)
            parent = parent.parent
        CORE.safe_dir(parent)
        for d in reversed(missing):
            d.mkdir(mode=0o755)
        CORE.safe_dir(path.parent)
        new_hash = CORE.digest(payload)
        prior = next((r for r in self.secret['resources'] if r.get('kind') == 'file' and r['path'] == str(path)), None)
        if prior:
            if prior['new_sha256'] != new_hash:
                fail('RESOURCE_CONFLICT', '同一任务试图用不同内容覆盖同一配置')
            if path.exists() and CORE.digest(CORE.read_owned(path, mode)) == new_hash:
                return
            if (not path.exists() and prior['old'] is not None) or (path.exists() and
                    (prior['old'] is None or path.read_bytes() != base64.b64decode(prior['old']))):
                fail('RESOURCE_CONFLICT', '恢复时配置已被外部修改，保留现场并停止覆盖')
        else:
            old, old_mode = None, None
            if path.exists() or path.is_symlink():
                CORE.safe_file(path)
                old_mode = path.stat().st_mode & 0o777
                old = base64.b64encode(path.read_bytes()).decode('ascii')
            self.resource({'kind': 'file', 'path': str(path), 'old': old,
                           'old_mode': old_mode, 'new_sha256': new_hash})
        CORE.atomic_write(path, payload, mode)

    def value(self, key, value=None):
        if value is not None:
            self.secret['values'][key] = value
            self.persist()
        return self.secret['values'].get(key)

    def service(self, unit):
        if not any(r.get('kind') == 'service_state' and r['unit'] == unit for r in self.secret['resources']):
            self.resource({'kind': 'service_state', 'unit': unit, **service_state(unit)})


def verified_download(spec, *, test=False):
    CORE.fields(spec, ('url', 'sha256', 'version'), ('member',))
    if not CORE.HEX64_RE.fullmatch(spec['sha256']) or not re.fullmatch(r'[A-Za-z0-9._-]{1,64}', spec['version']):
        fail('ARTIFACT_INVALID', '软件包必须固定版本和 SHA-256')
    url = endpoint(spec['url'], test)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), ArtifactRedirect())
    try:
        with opener.open(url, timeout=90) as reply:
            data = reply.read(128 * 1024 * 1024 + 1)
    except (OSError, urllib.error.URLError):
        fail('ARTIFACT_DOWNLOAD_FAILED', '固定版本安装包下载失败，请检查服务端清单地址')
    if len(data) > 128 * 1024 * 1024 or CORE.digest(data) != spec['sha256']:
        fail('ARTIFACT_HASH_MISMATCH', '软件包 SHA-256 不匹配，已阻止安装')
    if 'member' in spec:
        import io
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
                item = archive.getmember(spec['member'])
                if not item.isfile() or item.size > 128 * 1024 * 1024:
                    fail('ARTIFACT_INVALID', '安装包成员不是合法普通文件')
                data = archive.extractfile(item).read()
        except (tarfile.TarError, KeyError, ValueError):
            fail('ARTIFACT_INVALID', '安装包中缺少固定的二进制成员')
    if not data.startswith(b'\x7fELF'):
        fail('ARTIFACT_INVALID', '安装包不是 Linux ELF 二进制')
    return data


def worker_initialize(ctx, p):
    if not ctx.value('initialized'):
        command(['/usr/bin/apt-get', 'update'], timeout=600)
        command(['/usr/bin/apt-get', '-y', 'upgrade'], timeout=3600)
        command(['/usr/bin/apt-get', '-y', 'install', 'ufw', 'fail2ban', 'ca-certificates'], timeout=900)
        command(['/usr/bin/timedatectl', 'set-timezone', 'UTC'])
        # Preserve the registered management port before enabling a fresh firewall.
        command(['/usr/sbin/ufw', 'allow', str(p['ssh_port']) + '/tcp'])
        command(['/usr/sbin/ufw', '--force', 'enable'])
        ctx.write('/etc/fail2ban/jail.d/opsdeck-sshd.local',
                  ('[sshd]\nenabled=true\nport=' + str(p['ssh_port']) + '\nbackend=systemd\n').encode(), 0o644)
        command(['/usr/bin/systemctl', 'enable', '--now', 'fail2ban'])
        command(['/usr/bin/fail2ban-client', 'status', 'sshd'])
        ctx.value('initialized', True)
    security = CORE.scan_security({'asset_id': ctx.job['asset_id']})
    if security['reboot_required']:
        boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        if ctx.value('reboot_boot_id') != boot:
            ctx.value('reboot_boot_id', boot)
            fail('REBOOT_REQUIRED', '安全更新需要重启；任务已保存，请重启后从本步继续，重连将核对运行内核')
        fail('REBOOT_REQUIRED', '尚未检测到本次更新后的重启，请完成重启再继续')
    return {'utc': True, 'firewall_active': True, 'kernel': os.uname().release,
            'evidence': 'UTC、ufw、fail2ban 与安全更新完成；无待重启标记'}


def worker_hardening(ctx, _p):
    ctx.write(CORE.SUDOERS, CORE.SUDO_TEXT.encode(), 0o440)
    ctx.write(CORE.SSHD, CORE.SSHD_TEXT.encode(), 0o644)
    command(['/usr/sbin/visudo', '-cf', str(CORE.SUDOERS)])
    command(['/usr/sbin/sshd', '-t'])
    CORE.reload_ssh_service(check=True)
    if any((d / 'komari-agent.service').is_file() for d in CORE.KOMARI_UNIT_DIRS):
        ctx.write(CORE.KOMARI_OVERRIDE, b'[Service]\nEnvironment=AGENT_DISABLE_WEB_SSH=true\n', 0o644)
        command(['/usr/bin/systemctl', 'daemon-reload'])
        command(['/usr/bin/systemctl', 'restart', 'komari-agent'])
    scan = CORE.scan_security({'asset_id': ctx.job['asset_id']})
    if not scan['sshd_hardened'] or not scan['sudo_hardened'] or not scan['komari_webssh_disabled']:
        fail('HARDENING_VERIFY_FAILED', '安全策略文件或 Komari 运行时 WebSSH 检查未通过')
    return {'evidence': 'visudo、sshd 配置检查与服务重载完成；Komari 运行时安全检查通过'}


def worker_certificate(ctx, p):
    root = pathlib.Path('/etc/opsctl/certificates') / p['domain']
    ctx.write(root / 'fullchain.pem', p['certificate'].encode(), 0o644)
    ctx.write(root / 'privkey.pem', p['private_key'].encode())
    command(['/usr/bin/openssl', 'x509', '-in', str(root / 'fullchain.pem'), '-checkend', '604800', '-noout'])
    command(['/usr/bin/openssl', 'x509', '-in', str(root / 'fullchain.pem'), '-checkhost', p['domain'], '-noout'])
    cert_pub = command(['/usr/bin/openssl', 'x509', '-in', str(root / 'fullchain.pem'), '-pubkey', '-noout'])
    key_pub = command(['/usr/bin/openssl', 'pkey', '-in', str(root / 'privkey.pem'), '-pubout'])
    if cert_pub != key_pub:
        fail('CERTIFICATE_KEY_MISMATCH', '证书与私钥不匹配，已停止')
    if pathlib.Path('/etc/nginx/conf.d/opsdeck-reality.conf').is_file():
        command(['/usr/sbin/nginx', '-t'])
        command(['/usr/bin/systemctl', 'reload', 'nginx'])
    return {'evidence': '单机证书域名、有效期和密钥匹配检查通过'}


def worker_reality(ctx, p):
    domain = p['domain']
    root = '/etc/opsctl/certificates/' + domain
    ctx.service('nginx')
    if not pathlib.Path('/usr/sbin/nginx').exists():
        command(['/usr/bin/apt-get', 'update'], timeout=600)
        command(['/usr/bin/apt-get', '-y', 'install', 'nginx', 'ca-certificates'], timeout=900)
        default = pathlib.Path('/etc/nginx/sites-enabled/default')
        if default.is_symlink() and default.lstat().st_uid == 0 and default.resolve() == pathlib.Path('/etc/nginx/sites-available/default'):
            ctx.resource({'kind': 'removed_symlink', 'path': str(default), 'target': os.readlink(default)})
            default.unlink()
    config = ('server {\n listen 127.0.0.1:8444 ssl;\n server_name ' + domain + ';\n'
              ' ssl_certificate ' + root + '/fullchain.pem;\n ssl_certificate_key ' + root + '/privkey.pem;\n'
              ' ssl_protocols TLSv1.2 TLSv1.3;\n location / { return 200 "Welcome\\n"; }\n}\n')
    ctx.write('/etc/nginx/conf.d/opsdeck-reality.conf', config.encode(), 0o644)
    for path in (pathlib.Path('/etc/hosts'), pathlib.Path('/etc/cloud/templates/hosts.debian.tmpl')):
        if path.exists():
            text = path.read_text()
            line = '127.0.0.1 ' + domain + ' # opsdeck-reality\n'
            # Existing conflicting mappings are never silently replaced.
            for entry in text.splitlines():
                fields = entry.split('#', 1)[0].split()
                if domain in fields[1:] and fields[0] != '127.0.0.1':
                    fail('HOSTS_CONFLICT', 'hosts 或 cloud-init 模板已有冲突域名映射')
            if not any(domain in row.split('#', 1)[0].split()[1:] for row in text.splitlines()):
                ctx.write(path, (text.rstrip('\n') + '\n' + line).encode(), 0o644)
    command(['/usr/sbin/nginx', '-t'])
    command(['/usr/bin/systemctl', 'enable', '--now', 'nginx'])
    command(['/usr/bin/systemctl', 'reload', 'nginx'])
    context = ssl.create_default_context()
    with socket.create_connection(('127.0.0.1', 8444), timeout=10) as sock:
        with context.wrap_socket(sock, server_hostname=domain) as tls:
            certificate = CORE.digest(tls.getpeercert(binary_form=True))
    return {'certificate_sha256': certificate, 'evidence': '127.0.0.1:8444 真证书握手通过，hosts 与存在的 cloud-init 模板已持久化'}


def worker_agents(ctx, p):
    me = asset(ctx.policy, ctx.job['asset_id'])
    existing_config = pathlib.Path('/etc/xboard-node/config.yml')
    reuse_xboard = existing_config.exists()
    if reuse_xboard:
        if CORE.digest(CORE.read_owned(existing_config, 0o600)) != me.get('xboard_config_sha256'):
            fail('UNMANAGED_XBOARD', '已有 xboard-node 配置未登记或发生变化；保留原服务，不覆盖配置')
        if me.get('machine_id') != p['machine_id']:
            fail('XBOARD_MACHINE_CONFLICT', '已有服务与本次机器 ID 不匹配')
    elif any((d / 'xboard-node.service').exists() for d in CORE.KOMARI_UNIT_DIRS):
        fail('UNMANAGED_XBOARD', '已有 xboard-node 单元但配置位置未登记，拒绝覆盖')
    for name in ('xboard-node', 'komari-agent'):
        ctx.service(name)
    for name in ('xboard-node', 'komari-agent'):
        if name == 'komari-agent' and p.get('existing_komari'):
            continue
        payload = verified_download(p['artifacts'][name], test=ctx.policy.get('test_mode') is True)
        ctx.write('/usr/local/bin/' + name, payload, 0o755)
    config = {'panel': {'url': p['panel_url']}, 'machine': {'machine_id': p['machine_id'], 'token': p['machine_token']},
              'kernel': {'type': 'singbox'}, 'log': {'level': 'warn'}}
    if not reuse_xboard:
        ctx.write('/etc/xboard-node/config.yml', CORE.canonical(config) + b'\n')
    unit = ('[Unit]\nAfter=network-online.target\n[Service]\nExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml\n'
            'Restart=on-failure\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n')
    if not reuse_xboard:
        ctx.write('/etc/systemd/system/xboard-node.service', unit.encode(), 0o644)
    if not p.get('existing_komari'):
        env = 'AGENT_ENDPOINT=' + p['komari_url'] + '\nAGENT_TOKEN=' + p['komari_token'] + '\nAGENT_DISABLE_WEB_SSH=true\n'
        ctx.write('/etc/opsctl/komari.env', env.encode())
        unit = ('[Unit]\nAfter=network-online.target\n[Service]\nEnvironmentFile=/etc/opsctl/komari.env\n'
                'ExecStart=/usr/local/bin/komari-agent -e ${AGENT_ENDPOINT} -t ${AGENT_TOKEN}\n'
                'Restart=on-failure\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n')
        ctx.write('/etc/systemd/system/komari-agent.service', unit.encode(), 0o644)
    ctx.write(CORE.KOMARI_OVERRIDE, b'[Service]\nEnvironment=AGENT_DISABLE_WEB_SSH=true\n', 0o644)
    command(['/usr/bin/systemctl', 'daemon-reload'])
    for name in ('komari-agent', 'xboard-node'):
        command(['/usr/bin/systemctl', 'enable', '--now', name])
        command(['/usr/bin/systemctl', 'restart', name])
        command(['/usr/bin/systemctl', 'is-active', name])
    if not CORE.scan_security({'asset_id': ctx.job['asset_id']})['komari_webssh_disabled']:
        fail('AGENT_UNSAFE', 'Komari 运行时未确认禁用 WebSSH')
    return {'evidence': '固定哈希二进制已安装，两项服务 active，Komari 运行时禁用 WebSSH'}


def worker_firewall(ctx, p):
    listeners = {x['port']: x for x in CORE.scan_listening_ports()}
    for port in p['ports']:
        listener = listeners.get(port)
        if listener and not listener.get('self_managed'):
            if listener.get('shared_service') or port not in p['overwrite_ports']:
                fail('PORT_CONFLICT', '端口 ' + str(port) + ' 由共享或未经确认覆盖的服务占用')
            unit = listener.get('unit', '')
            if not re.fullmatch(r'[A-Za-z0-9_.@-]+\.service', unit) or unit in ('ssh.service', 'sshd.service', 'opsctl-runner.service'):
                fail('PROTECTED_SERVICE', '无法可靠识别可替换的独立 systemd 单元')
            before = service_state(unit)
            if not any(r.get('kind') == 'stopped_service' and r['unit'] == unit for r in ctx.secret['resources']):
                ctx.resource({'kind': 'stopped_service', 'unit': unit, 'enabled': before['enabled'] == 'enabled'})
            command(['/usr/bin/systemctl', 'disable', '--now', unit])
    added = command(['/usr/sbin/ufw', 'show', 'added']).decode()
    for port in p['ports']:
        for source in p['source_ips'] or ['any']:
            args = ['allow', 'from', source, 'to', 'any', 'port', str(port), 'proto', 'tcp']
            marker = 'opsdeck:' + ctx.job['job_id']
            rule = 'ufw ' + ' '.join(args)
            if rule in added or (source == 'any' and 'ufw allow ' + str(port) + '/tcp' in added):
                continue
            previous = next((r for r in ctx.secret['resources'] if r.get('kind') == 'ufw' and r['args'] == args), None)
            if previous is None:
                ctx.resource({'kind': 'ufw', 'args': args, 'marker': marker,
                              'deadline': time.time() + 180, 'confirmed': False})
            command(['/usr/sbin/ufw', *args, 'comment', marker])
    return {'evidence': '本任务端口规则已写入；等待新建独立 SSH 连接确认，超时自动撤销'}


def worker_confirm_firewall(ctx, p):
    other = CORE.load_job(p['firewall_job_id'])
    if other.get('actor') != ctx.job['actor'] or other.get('operation') != 'firewall':
        fail('JOB_CONFLICT', '防火墙确认任务身份不匹配')
    state = owned_json(private_path(other['job_id']))
    for resource in state['resources']:
        if resource.get('kind') == 'ufw':
            if resource.get('reverted'):
                fail('FIREWALL_REVERTED', '防火墙确认超时，规则已经自动撤销')
            resource['confirmed'] = True
    save(private_path(other['job_id']), state)
    return {'evidence': '编排中心通过新建、独立认证的 SSH 连接确认管理通道可用'}


def worker_restart(_ctx, _p):
    # The SSH request has already persisted/acknowledged this worker task.
    time.sleep(5)
    command(['/usr/bin/systemctl', 'restart', 'xboard-node'])
    command(['/usr/bin/systemctl', 'is-active', 'xboard-node'])
    return {'evidence': 'xboard-node 已重启并处于 active；任务由独立 runner 持续保存'}


def worker_probe(ctx, p):
    me = asset(ctx.policy, ctx.job['asset_id'])
    certs = []
    for port in p['ports']:
        context = ssl.create_default_context()
        with socket.create_connection((me['ip'], port), timeout=15) as sock:
            with context.wrap_socket(sock, server_hostname=p['domain']) as tls:
                certs.append({'port': port, 'certificate_sha256': CORE.digest(tls.getpeercert(binary_form=True))})
    return {'certificates': certs, 'evidence': '各节点端口 TLS 证书域名与信任链握手通过'}


def rollback_files(state, persist=lambda: None):
    # Validate drift before stopping any service or changing any resource.
    for resource in state['resources']:
        if resource.get('kind') == 'file' and not resource.get('reverted'):
            path = pathlib.Path(resource['path'])
            if path.exists():
                CORE.safe_file(path)
                if (CORE.digest(path.read_bytes()) != resource['new_sha256'] and
                        (resource['old'] is None or path.read_bytes() != base64.b64decode(resource['old']))):
                    fail('ROLLBACK_DRIFT', '配置被其他操作修改，停止覆盖：' + str(path))
            elif resource['old'] is not None:
                fail('ROLLBACK_DRIFT', '原配置被外部删除，停止自动恢复：' + str(path))
    # Stop newly installed units before removing their binary/configuration.
    paths = {r.get('path') for r in state['resources'] if r.get('kind') == 'file' and r.get('old') is None}
    for unit in ('xboard-node', 'komari-agent'):
        if '/etc/systemd/system/' + unit + '.service' in paths:
            command(['/usr/bin/systemctl', 'disable', '--now', unit])
    for resource in reversed(state['resources']):
        if resource.get('reverted'):
            continue
        kind = resource['kind']
        if kind == 'file':
            path = pathlib.Path(resource['path'])
            if path.exists():
                CORE.safe_file(path)
                if resource['old'] is not None and path.read_bytes() == base64.b64decode(resource['old']):
                    resource['reverted'] = True
                    persist()
                    continue
                if CORE.digest(path.read_bytes()) != resource['new_sha256']:
                    fail('ROLLBACK_DRIFT', '配置被其他操作修改，停止覆盖：' + str(path))
                if resource['old'] is None:
                    path.unlink()
                else:
                    CORE.atomic_write(path, base64.b64decode(resource['old']), resource['old_mode'])
        elif kind == 'ufw':
            added = command(['/usr/sbin/ufw', 'show', 'added']).decode()
            if resource['marker'] in added:
                command(['/usr/sbin/ufw', '--force', 'delete', *resource['args'], 'comment', resource['marker']])
        elif kind == 'stopped_service':
            if resource['enabled']:
                command(['/usr/bin/systemctl', 'enable', resource['unit']])
            command(['/usr/bin/systemctl', 'start', resource['unit']])
        elif kind == 'removed_symlink':
            path = pathlib.Path(resource['path'])
            if path.exists() or path.is_symlink():
                if not path.is_symlink() or os.readlink(path) != resource['target']:
                    fail('ROLLBACK_DRIFT', '原默认站点路径已变化，停止恢复')
            else:
                path.symlink_to(resource['target'])
        resource['reverted'] = True
        persist()
    command(['/usr/bin/systemctl', 'daemon-reload'])
    for resource in state['resources']:
        if resource.get('kind') != 'service_state':
            continue
        unit = resource['unit']
        if not any((d / (unit if unit.endswith('.service') else unit + '.service')).exists() for d in CORE.KOMARI_UNIT_DIRS):
            continue
        if resource['enabled'] == 'enabled':
            command(['/usr/bin/systemctl', 'enable', unit])
        elif resource['enabled'] in ('disabled', '', 'not-found'):
            command(['/usr/bin/systemctl', 'disable', unit])
        command(['/usr/bin/systemctl', 'restart' if resource['active'] else 'stop', unit])


def worker_rollback(ctx, p):
    original = CORE.load_job(p['worker_job_id'])
    if original.get('action') != 'deployment.worker' or original.get('actor') != ctx.job['actor']:
        fail('JOB_CONFLICT', '只能撤销本编排身份创建的工作任务')
    if original.get('status') in ('queued', 'running'):
        fail('JOB_RUNNING', '原工作任务仍在执行，不能同时回滚')
    state = owned_json(private_path(original['job_id']))
    rollback_files(state, lambda: save(private_path(original['job_id']), state))
    save(private_path(original['job_id']), state)
    return {'evidence': '本工作任务可恢复资源已撤销；系统更新与已有共享服务保留'}


WORKERS = {'initialize': worker_initialize, 'hardening': worker_hardening,
           'certificate': worker_certificate, 'reality': worker_reality,
           'agents': worker_agents, 'firewall': worker_firewall,
           'confirm_firewall': worker_confirm_firewall, 'restart': worker_restart,
           'probe': worker_probe, 'rollback': worker_rollback}


class Remote:
    def __init__(self, policy):
        self.policy = policy

    def call(self, aid, action, params):
        target = asset(self.policy, aid)
        key = pathlib.Path(self.policy['ssh_key_file'])
        CORE.read_owned(key, 0o600)
        alias = 'opsdeck-' + aid
        known = directory('deployment-known-hosts') / aid
        CORE.atomic_write(known, (alias + ' ' + target['host_key'] + '\n').encode('ascii'), 0o600)
        rid = str(uuid.uuid4())
        request = CORE.canonical({'version': 1, 'id': rid, 'action': action, 'params': params}) + b'\n'
        if len(request) > CORE.MAX_REQUEST:
            fail('REQUEST_TOO_LARGE', '单机部署请求超出协议大小限制')
        raw = command(['/usr/bin/ssh', '-F', '/dev/null', '-T', '-o', 'BatchMode=yes',
                       '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
                       '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
                       '-o', 'HostKeyAlias=' + alias, '-o', 'UserKnownHostsFile=' + str(known),
                       '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=10',
                       '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3',
                       '-i', str(key), '-p', str(target['ssh_port']),
                       'opsdeck@' + target['ip'], 'opsctl'], input_bytes=request, timeout=45)
        if len(raw) > MAX_HTTP:
            fail('REMOTE_REPORT_INVALID', '工作机响应超出限制')
        try:
            reply = json.loads(raw, object_pairs_hook=CORE.unique_pairs)
        except ValueError:
            fail('REMOTE_REPORT_INVALID', '工作机未返回合法任务响应')
        if reply.get('id') != rid or reply.get('version') != 1:
            fail('REMOTE_REPORT_INVALID', '工作机响应与本次请求不匹配')
        if reply.get('ok') is not True:
            err = reply.get('error', {})
            code = err.get('code', 'REMOTE_REJECTED')
            fail(code if re.fullmatch('[A-Z0-9_]{1,64}', code) else 'REMOTE_REJECTED',
                 '工作机拒绝固定动作，请检查其服务端策略、版本和编排密钥授权')
        data = reply['data']
        if not isinstance(data, dict) or data.get('asset_id') != aid:
            fail('ASSET_MISMATCH', '工作机稳定资产身份不匹配，已停止')
        return data

    def work(self, ctx, aid, operation, params):
        step_id = ctx.job['current_step']
        child = str(uuid.uuid5(uuid.UUID(ctx.job['job_id']), aid + ':' + step_id + ':' + operation))
        requests = ctx.secret['values'].setdefault('children', {})
        marker = aid + ':' + step_id + ':' + operation
        request = {'job_id': child, 'operation': operation, 'params': params}
        if marker not in requests:
            requests[marker] = request
            if operation == 'rollback':
                ctx.persist()  # Do not add cleanup tasks to the resources being cleaned.
            else:
                ctx.resource({'kind': 'worker', 'asset_id': aid, 'job_id': child})
        elif requests[marker] != request:
            fail('PLAN_MISMATCH', '恢复时固定动作参数变化，已停止重复执行')
        self.call(aid, 'deployment.worker', request)
        deadline, failures = time.monotonic() + 7200, 0
        while time.monotonic() < deadline:
            try:
                result = self.call(aid, 'status', {'job_id': child, 'after_seq': 0})
                failures = 0
            except CORE.Rejected as exc:
                if exc.code in ('ASSET_MISMATCH', 'REMOTE_REPORT_INVALID'):
                    raise
                failures += 1
                if failures > 12:
                    raise
                time.sleep(min(2 ** failures, 20))
                continue  # Reads only: never re-submit after an uncertain write.
            if result.get('status') == 'succeeded' and result.get('verified') is True:
                return result['result']
            if result.get('status') in ('failed', 'rollback_failed', 'waiting_reboot'):
                code = (result.get('error') or {}).get('code', 'WORKER_FAILED')
                fail(code, '工作机 ' + aid + ' 的 ' + operation + ' 未通过；请查看该工作任务 ' + child)
            time.sleep(1)
        fail('WORKER_TIMEOUT', '等待工作任务超时；请刷新原任务，禁止重新创建部署单')


def coordinator_preflight(ctx, remote):
    p = ctx.secret['params']
    aid = p['target_asset_id']
    reports = {}
    for node_id in [aid] + [b['relay_asset_id'] for b in p['relay_bindings']]:
        report = remote.call(node_id, 'host.discover', {})
        if 'deployment.worker' not in report.get('capabilities', []):
            fail('RUNNER_VERSION', '工作机尚未提供固定动作 runner，请先升级首次接入组件')
        if not report.get('runner', {}).get('ready') or report.get('runner', {}).get('policy_mode') is None:
            fail('RUNNER_NOT_RUNNING', '工作机 runner 或部署策略未就绪，已停止且未改动部署对象')
        reports[node_id] = report
    def check_listeners(aid, ports, overwrite):
        listeners = {l['port']: l for l in reports[aid].get('listening_ports', [])}
        for port in ports:
            listener = listeners.get(port)
            if listener and not listener.get('self_managed'):
                if (listener.get('shared_service') or not listener.get('unit') or port not in overwrite):
                    fail('PORT_CONFLICT', '资产 ' + aid + ' 的端口 ' + str(port) + ' 存在共享、未知或未经确认的占用')
    check_listeners(aid, target_ports(p), p['overwrite_ports'])
    for b in p['relay_bindings']:
        check_listeners(b['relay_asset_id'], [b['entry_port']], [])
    # Recheck every ingress against authoritative panel state immediately before
    # mutation; a locally cached port list never authorizes a replacement.
    rows = Panel(ctx.policy).nodes()
    for b in p['relay_bindings']:
        relay = asset(ctx.policy, b['relay_asset_id'])
        for row in rows:
            if row.get('machine_id') == relay.get('machine_id') and str(row.get('server_port')) == str(b['entry_port']):
                fail('PROTECTED_PORT', 'Xboard 已存在占用该入口端口的节点，请重新规划端口')
    ctx.value('reports', reports)
    return '所有目标稳定身份、工作机能力及 Xboard 入口端口复检通过'


def coordinator_registration(ctx):
    p = ctx.secret['params']
    target = asset(ctx.policy, p['target_asset_id'])
    spec = ctx.policy.get('registration')
    if not isinstance(spec, dict) or not {'inventory_file', 'allowlist_file'}.issubset(spec) or set(spec) - {'inventory_file', 'allowlist_file', 'ingress_port'}:
        fail('POLICY_INVALID', '部署中心尚未登记主机清单和来源白名单文件')
    inventory, allowlist = pathlib.Path(spec['inventory_file']), pathlib.Path(spec['allowlist_file'])
    # Root chooses these two existing files during provisioning, never the App.
    for path in (inventory, allowlist):
        CORE.safe_file(path)
        if not path.exists() or path.stat().st_size > 1024 * 1024:
            fail('REGISTRATION_INVALID', '清单或白名单不存在，或超过安全大小限制')
    text = inventory.read_text()
    line = p['server_name'] + ' ' + target['ip'] + ' ' + str(target['ssh_port'])
    if line not in text.splitlines():
        ctx.write(inventory, (text.rstrip('\n') + '\n' + line + '\n').encode())
    text = allowlist.read_text()
    line = 'allow ' + target['ip'] + ';'
    if line not in text.splitlines():
        ctx.write(allowlist, (text.rstrip('\n') + '\n' + line + '\n').encode(), 0o644)
    ingress = spec.get('ingress_port')
    if ingress is not None:
        if type(ingress) is not int or not 1 <= ingress <= 65535:
            fail('POLICY_INVALID', '汇总机来源放行端口配置不合法')
        args = ['allow', 'from', target['ip'], 'to', 'any', 'port', str(ingress), 'proto', 'tcp']
        existing = command(['/usr/sbin/ufw', 'show', 'added']).decode()
        if 'ufw ' + ' '.join(args) not in existing:
            marker = 'opsdeck:' + ctx.job['job_id']
            if not any(r['kind'] == 'ufw' and r['args'] == args for r in ctx.secret['resources']):
                ctx.resource({'kind': 'ufw', 'args': args, 'marker': marker, 'confirmed': True})
            command(['/usr/sbin/ufw', *args, 'comment', marker])
    command(['/usr/sbin/nginx', '-t'])
    command(['/usr/bin/systemctl', 'reload', 'nginx'])
    return '汇总机主机清单与来源白名单已登记，Nginx 配置检查及重载通过'


def coordinator_dns(ctx):
    p = ctx.secret['params']
    target = asset(ctx.policy, p['target_asset_id'])
    dns = DNS(ctx.policy)
    records = dns.records(p['domain'])
    marker = 'opsdeck:' + ctx.job['job_id']
    wanted = {'type': 'A', 'name': p['domain'], 'content': target['ip'], 'ttl': 120, 'proxied': False, 'comment': marker}
    if not records:
        resource = next((r for r in ctx.secret['resources'] if r['kind'] == 'dns'), None)
        if resource is None:
            resource = ctx.resource({'kind': 'dns', 'id': None, 'domain': p['domain'], 'content': target['ip'], 'marker': marker})
        row = dns.call('', 'POST', wanted)
        resource['id'] = row['id']
        ctx.persist()
        records = dns.records(p['domain'])
    if len(records) != 1 or any(records[0].get(k) != wanted[k] for k in ('type', 'name', 'content', 'proxied')):
        fail('DNS_VERIFY_FAILED', 'DNS 写入后读回不匹配，已暂停')
    if records[0].get('comment') == marker:
        for r in ctx.secret['resources']:
            if r['kind'] == 'dns':
                r['id'] = records[0]['id']
                ctx.persist()
    return '灰云 A 记录读回一致：' + p['domain'] + ' → ' + target['ip']


def coordinator_certificate(ctx, remote):
    p = ctx.secret['params']
    domain = p['domain']
    name = 'opsdeck-' + domain
    root = pathlib.Path('/etc/letsencrypt/live') / name
    spec = ctx.policy['cloudflare']
    credential = directory('deployment-certbot') / 'cloudflare.ini'
    CORE.atomic_write(credential, ('dns_cloudflare_api_token = ' + token(spec['token_file']) + '\n').encode(), 0o600)
    email = ctx.policy.get('acme_email', '')
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
        fail('POLICY_INVALID', '部署中心缺少证书续期联系邮箱')
    command(['/usr/bin/certbot', 'certonly', '--non-interactive', '--agree-tos',
             '--email', email, '--dns-cloudflare', '--dns-cloudflare-credentials', str(credential),
             '--dns-cloudflare-propagation-seconds', '30', '--cert-name', name,
             '--key-type', 'ecdsa', '-d', domain], timeout=600)
    # certbot's live/ tree deliberately uses symlinks; resolve and validate the
    # target's ownership and its location under the fixed ACME archive directory.
    def read_cert(filename):
        resolved = (root / filename).resolve(strict=True)
        if pathlib.Path('/etc/letsencrypt/archive') not in resolved.parents:
            fail('CERTIFICATE_INVALID', '证书文件未指向受信 ACME 归档目录')
        CORE.safe_file(resolved)
        return resolved.read_text()
    certificate, key = read_cert('fullchain.pem'), read_cert('privkey.pem')
    result = remote.work(ctx, p['target_asset_id'], 'certificate',
                         {'domain': domain, 'certificate': certificate, 'private_key': key})
    ctx.value('certificate_sha256', CORE.digest(ssl.PEM_cert_to_DER_cert(certificate[:certificate.index('-----END CERTIFICATE-----') + 25])))
    return result['evidence']


NODE_FIELDS = ('type', 'code', 'parent_id', 'machine_id', 'group_ids', 'route_ids', 'name', 'rate',
               'transfer_enable', 'rate_time_enable', 'rate_time_ranges', 'tags', 'host', 'port',
               'server_port', 'protocol_settings', 'custom_outbounds', 'custom_routes', 'cert_config',
               'show', 'enabled', 'sort')


def node_marker(ctx, suffix):
    return 'od-' + ctx.job['job_id'].replace('-', '')[:20] + '-' + suffix


def node_create(ctx, panel, wanted):
    rows = panel.nodes()
    found = [row for row in rows if row.get('code') == wanted['code']]
    if not found:
        if any(row.get('name') == wanted['name'] and row.get('host') == wanted['host']
               and str(row.get('port')) == str(wanted['port']) for row in rows):
            fail('XBOARD_NODE_CONFLICT', '已有同名、同地址和端口节点，请先确认复用关系')
        resource = next((r for r in ctx.secret['resources'] if r['kind'] == 'xboard_node' and r['code'] == wanted['code']), None)
        if resource is None:
            resource = ctx.resource({'kind': 'xboard_node', 'id': None, 'code': wanted['code'], 'expected': wanted})
        panel.call('manage/save', wanted)
        found = [row for row in panel.nodes() if row.get('code') == wanted['code']]
    if len(found) != 1:
        fail('XBOARD_VERIFY_FAILED', 'Xboard 创建后读回不能唯一匹配任务节点')
    row = found[0]
    for key in ('name', 'host', 'machine_id', 'server_port', 'protocol_settings', 'custom_outbounds', 'custom_routes'):
        if row.get(key) != wanted[key]:
            fail('XBOARD_VERIFY_FAILED', 'Xboard 节点字段读回不匹配：' + key)
    for resource in ctx.secret['resources']:
        if resource['kind'] == 'xboard_node' and resource['code'] == wanted['code']:
            resource['id'] = row['id']
            ctx.persist()
    return row


def coordinator_panel(ctx):
    p, panel = ctx.secret['params'], Panel(ctx.policy)
    target = asset(ctx.policy, p['target_asset_id'])
    machines = panel.call('machine/fetch')
    mid = ctx.value('machine_id') or target.get('machine_id')
    if mid is None:
        marker = 'opsdeck:' + ctx.job['job_id']
        found = [m for m in machines if m.get('notes') == marker]
        if not found:
            if any(m.get('name') == p['server_name'] for m in machines):
                fail('XBOARD_MACHINE_CONFLICT', '已有同名机器，请在服务端策略登记其机器 ID')
            ctx.resource({'kind': 'xboard_machine', 'id': None, 'marker': marker})
            panel.call('machine/save', {'name': p['server_name'], 'notes': marker, 'is_active': True})
            found = [m for m in panel.call('machine/fetch') if m.get('notes') == marker]
        if len(found) != 1:
            fail('XBOARD_VERIFY_FAILED', '新建 Xboard 机器无法唯一读回')
        mid = found[0]['id']
        for resource in ctx.secret['resources']:
            if resource['kind'] == 'xboard_machine':
                resource['id'] = mid
        ctx.value('machine_id', mid)
    elif not any(m.get('id') == mid for m in machines):
        fail('XBOARD_MACHINE_MISSING', '服务端登记的 Xboard 机器不存在')
    mt = panel.call('machine/getToken?id=' + str(mid))
    ctx.value('machine_token', mt['token'])
    templates = {row['id']: row for row in panel.nodes()}
    template = templates.get(ctx.policy['xboard']['template_node_id'])
    if not template or template.get('type') != 'vless' or template.get('protocol_settings', {}).get('tls') != 2:
        fail('XBOARD_TEMPLATE_INVALID', '固定模板必须是已核对的 VLESS Reality 节点')
    keys = ctx.value('reality_keys')
    if keys is None:
        private = command(['/usr/bin/openssl', 'genpkey', '-algorithm', 'X25519', '-outform', 'DER'])
        public = command(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], input_bytes=private)
        keys = {'private_key': base64.urlsafe_b64encode(private[-32:]).decode().rstrip('='),
                'public_key': base64.urlsafe_b64encode(public[-32:]).decode().rstrip('='),
                'short_id': os.urandom(8).hex()}
        ctx.value('reality_keys', keys)
    reality = {**keys, 'server_name': p['domain'], 'server_port': 8444}
    def base():
        result = {k: copy.deepcopy(template[k]) for k in NODE_FIELDS if k in template}
        result.update({'parent_id': None, 'machine_id': mid, 'host': p['domain'], 'show': 0,
                       'enabled': True, 'route_ids': [], 'custom_outbounds': [], 'custom_routes': []})
        result['protocol_settings'] = {**result['protocol_settings'], 'reality_settings': reality}
        return result
    public_ids, internal_ids = [], []
    if p['role'] == 'direct':
        for index, port in enumerate(p['node_ports']):
            row = base()
            row.update({'code': node_marker(ctx, 'direct-' + str(port)),
                        'name': p['server_name'] + '-L' + ('' if index == 0 else '-' + str(port)),
                        'port': str(port), 'server_port': port,
                        'group_ids': ctx.policy['xboard'].get('public_group_ids', ['1'])})
            public_ids.append(node_create(ctx, panel, row)['id'])
    else:
        for binding in p['relay_bindings']:
            relay = asset(ctx.policy, binding['relay_asset_id'])
            row = base()
            row.update({'code': node_marker(ctx, 'landing-' + str(binding['landing_port'])),
                        'name': binding['internal_node'], 'port': str(binding['landing_port']),
                        'server_port': binding['landing_port'],
                        'group_ids': ctx.policy['xboard'].get('internal_group_ids', ['3'])})
            internal_ids.append(node_create(ctx, panel, row)['id'])
            entry = templates.get(relay['template_node_id'])
            if not entry or entry.get('machine_id') != relay['machine_id'] or entry.get('type') != 'vless':
                fail('XBOARD_TEMPLATE_INVALID', '入口模板与已登记的中转机器不匹配')
            row = {k: copy.deepcopy(entry[k]) for k in NODE_FIELDS if k in entry}
            outbound_templates = entry.get('custom_outbounds')
            if (not isinstance(outbound_templates, list) or len(outbound_templates) != 1
                    or outbound_templates[0].get('protocol') != 'vless'
                    or not isinstance(outbound_templates[0].get('settings'), dict)):
                fail('XBOARD_TEMPLATE_INVALID', '入口须登记已核对的 VLESS 中转出站模板；不能将验收账号用于业务出站')
            outbound = copy.deepcopy(outbound_templates[0])
            outbound['tag'] = 'to-landing'
            settings = outbound['settings']
            settings.update(server=p['domain'], server_port=binding['landing_port'])
            settings['tls'] = {**settings.get('tls', {}), 'enabled': True, 'server_name': p['domain'],
                               'reality': {'enabled': True, 'public_key': keys['public_key'], 'short_id': keys['short_id']}}
            row.update({'code': node_marker(ctx, 'entry-' + str(binding['entry_port']) + '-' + binding['relay_asset_id'][:8]),
                        'name': binding['subscription_name'], 'host': relay['domain'],
                        'port': str(binding['entry_port']), 'server_port': binding['entry_port'],
                        'show': 0, 'enabled': True, 'parent_id': None,
                        'group_ids': ctx.policy['xboard'].get('public_group_ids', ['1']),
                        'custom_routes': [{'domain': [p['domain']], 'outbound': 'direct'},
                                          {'network': ['tcp', 'udp'], 'outbound': 'to-landing'}],
                        'custom_outbounds': [outbound]})
            public_ids.append(node_create(ctx, panel, row)['id'])
    ctx.value('public_node_ids', public_ids)
    ctx.value('internal_node_ids', internal_ids)
    return 'Xboard 机器与节点创建后逐字段读回一致；对外节点保持隐藏'


def coordinator_agents(ctx, remote):
    p = ctx.secret['params']
    komari = ctx.policy['komari']
    base = endpoint(komari['url'], ctx.policy.get('test_mode') is True)
    bearer = token(komari['token_file'])
    target = asset(ctx.policy, p['target_asset_id'])
    kid = ctx.value('komari_uuid') or target.get('komari_uuid')
    if kid is None:
        # A durable task marker lets retry reconcile an ambiguous POST response.
        marker = 'opsdeck-' + ctx.job['job_id']
        rows = http(base + '/api/admin/client/list', bearer=bearer, test=ctx.policy.get('test_mode') is True)
        clients = rows if isinstance(rows, list) else rows.get('data', [])
        found = [c for c in clients if c.get('name') == marker]
        if not found:
            ctx.resource({'kind': 'komari', 'uuid': None, 'marker': marker})
            http(base + '/api/admin/client/add', 'POST', {'name': marker}, bearer, test=ctx.policy.get('test_mode') is True)
            rows = http(base + '/api/admin/client/list', bearer=bearer, test=ctx.policy.get('test_mode') is True)
            clients = rows if isinstance(rows, list) else rows.get('data', [])
            found = [c for c in clients if c.get('name') == marker]
        if len(found) != 1:
            fail('KOMARI_VERIFY_FAILED', '探针创建后无法唯一读回任务标记')
        kid = found[0]['uuid']
        ctx.value('komari_uuid', kid)
        for resource in ctx.secret['resources']:
            if resource['kind'] == 'komari':
                resource['uuid'] = kid
        ctx.persist()
    reply = http(base + '/api/admin/client/' + kid + '/token', bearer=bearer, test=ctx.policy.get('test_mode') is True)
    agent_token = reply.get('token') or (reply.get('data') or {}).get('token')
    if not isinstance(agent_token, str) or not agent_token:
        fail('KOMARI_TOKEN_MISSING', '未取得该机器自己的探针 token')
    result = remote.work(ctx, p['target_asset_id'], 'agents', {
        'machine_id': ctx.value('machine_id'), 'machine_token': ctx.value('machine_token'),
        'panel_url': ctx.policy['xboard']['url'], 'komari_token': agent_token,
        'komari_url': base, 'artifacts': ctx.policy['artifacts'],
        'existing_komari': bool(target.get('komari_uuid'))})
    return result['evidence']


def target_ports(p):
    return p['node_ports'] if p['role'] == 'direct' else [b['landing_port'] for b in p['relay_bindings']]


def coordinator_firewall(ctx, remote, aid, ports, sources, overwrite):
    result = remote.work(ctx, aid, 'firewall', {'ports': ports, 'source_ips': sources, 'overwrite_ports': overwrite})
    child = str(uuid.uuid5(uuid.UUID(ctx.job['job_id']), aid + ':' + ctx.job['current_step'] + ':firewall'))
    remote.work(ctx, aid, 'confirm_firewall', {'firewall_job_id': child})
    return result['evidence'] + '；独立管理连接已确认'


def tls_probe(ip, port, domain):
    with socket.create_connection((ip, port), timeout=15) as sock:
        with ssl.create_default_context().wrap_socket(sock, server_hostname=domain) as tls:
            return CORE.digest(tls.getpeercert(binary_form=True))


def exit_probe(ctx, node):
    """Exercise a real authenticated VLESS/Reality connection via sing-box."""
    executable = ctx.policy['probe_binary']
    binary = pathlib.Path(executable)
    CORE.safe_file(binary)
    if CORE.digest(binary.read_bytes()) != ctx.policy['probe_binary_sha256']:
        fail('PROBE_HASH_MISMATCH', '出口验收程序与服务端固定哈希不匹配')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        local_port = sock.getsockname()[1]
    reality = node['protocol_settings']['reality_settings']
    outbound = {'type': 'vless', 'tag': 'probe', 'server': node['host'], 'server_port': int(node['port']),
                'uuid': token(ctx.policy['probe_uuid_file']), 'flow': 'xtls-rprx-vision',
                'tls': {'enabled': True, 'server_name': reality['server_name'],
                        'utls': {'enabled': True, 'fingerprint': 'chrome'},
                        'reality': {'enabled': True, 'public_key': reality['public_key'], 'short_id': reality['short_id']}}}
    config = {'log': {'disabled': True}, 'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': local_port}],
              'outbounds': [outbound], 'route': {'final': 'probe'}}
    path = directory('deployment-probes') / (str(uuid.uuid4()) + '.json')
    save(path, config)
    proc = None
    try:
        proc = subprocess.Popen([executable, 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if proc.poll() is not None:
                fail('PROBE_FAILED', '真实出口验收程序启动失败，请核对固定版本和配置兼容性')
            try:
                with socket.create_connection(('127.0.0.1', local_port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        url = endpoint(ctx.policy['exit_check_url'])
        proxy = 'http://127.0.0.1:' + str(local_port)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({'http': proxy, 'https': proxy}), NoRedirect())
        with opener.open(url, timeout=30) as reply:
            raw = reply.read(4096).decode().strip()
        try:
            value = json.loads(raw)
            actual = value['ip']
        except (ValueError, TypeError, KeyError):
            actual = raw
        actual = str(ipaddress.ip_address(actual))
        target = asset(ctx.policy, ctx.secret['params']['target_asset_id'])
        if actual != target.get('expected_exit_ip', target['ip']):
            fail('EXIT_IP_MISMATCH', '实际出口与服务端登记的落地出口不一致，订阅保持隐藏')
        return actual
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        path.unlink(missing_ok=True)


def coordinator_verify(ctx):
    p = ctx.secret['params']
    rows = {r['id']: r for r in Panel(ctx.policy).nodes()}
    evidence = []
    for nid in ctx.value('public_node_ids') or []:
        node = rows.get(nid)
        if not node:
            fail('XBOARD_VERIFY_FAILED', '待验收节点不存在')
        candidates = [asset(ctx.policy, p['target_asset_id'])] + [asset(ctx.policy, b['relay_asset_id']) for b in p['relay_bindings']]
        owner = next((a for a in candidates if a['domain'] == node['host']), None)
        if owner is None:
            fail('ASSET_MISMATCH', '验收节点不属于本任务资产')
        cert_hash = tls_probe(owner['ip'], int(node['port']), node['protocol_settings']['reality_settings']['server_name'])
        if p['role'] == 'direct' and cert_hash != ctx.value('certificate_sha256'):
            fail('CERTIFICATE_MISMATCH', '节点端口未返回本任务签发的自家证书')
        actual = exit_probe(ctx, node)
        evidence.append({'node_id': nid, 'port': int(node['port']), 'certificate_sha256': cert_hash, 'exit_ip': actual})
    if not evidence:
        fail('VERIFY_EMPTY', '没有实际节点验收证据，不能发布订阅')
    ctx.value('verification_evidence', evidence)
    return '全部节点证书握手及真实 VLESS/Reality 出口通过：' + ', '.join(str(e['port']) for e in evidence)


def coordinator_publish(ctx):
    if not ctx.value('verification_evidence'):
        fail('VERIFY_REQUIRED', '缺少真实验收证据，拒绝发布')
    panel = Panel(ctx.policy)
    rows = {r['id']: r for r in panel.nodes()}
    for nid in ctx.value('public_node_ids'):
        node = rows.get(nid)
        resource = next((r for r in ctx.secret['resources'] if r['kind'] == 'xboard_node' and r['id'] == nid), None)
        if node is None or resource is None or node.get('code') != resource['code']:
            fail('RESOURCE_CONFLICT', '发布前节点身份已变化')
        panel.call('manage/update', {'id': nid, 'show': 1})
        resource['published'] = True
        ctx.persist()
    visible = {r['id']: r for r in panel.nodes()}
    if any(visible[nid].get('show') != 1 for nid in ctx.value('public_node_ids')):
        fail('PUBLISH_VERIFY_FAILED', '订阅可见状态读回未通过')
    aid = ctx.secret['params']['target_asset_id']
    lease_path = directory('deployment-certificates') / (aid + '.json')
    if not lease_path.exists():
        ctx.resource({'kind': 'certificate_lease', 'asset_id': aid, 'job_id': ctx.job['job_id']})
        save(lease_path, {'asset_id': aid, 'domain': ctx.secret['params']['domain'],
                          'created_from_job': ctx.job['job_id'], 'next_check': time.time() + 43200,
                          'last_ok': CORE.utc_now()})
    return '所有验收通过的对外订阅已发布并读回确认'


def coordinator_step(ctx, remote, step_id):
    p = ctx.secret['params']
    aid = p['target_asset_id']
    if step_id == 'preflight':
        return coordinator_preflight(ctx, remote)
    if step_id == 'initialize':
        if not p['init_system']:
            return '用户选择保留老机业务，已跳过系统初始化'
        return remote.work(ctx, aid, 'initialize', {'ssh_port': asset(ctx.policy, aid)['ssh_port']})['evidence']
    if step_id == 'hardening':
        return remote.work(ctx, aid, 'hardening', {})['evidence']
    if step_id == 'registration':
        return coordinator_registration(ctx)
    if step_id == 'dns':
        return coordinator_dns(ctx)
    if step_id == 'certificate':
        return coordinator_certificate(ctx, remote)
    if step_id == 'reality':
        return remote.work(ctx, aid, 'reality', {'domain': p['domain']})['evidence']
    if step_id == 'panel':
        return coordinator_panel(ctx)
    if step_id == 'agents':
        return coordinator_agents(ctx, remote)
    if step_id == 'firewall':
        return coordinator_firewall(ctx, remote, aid, target_ports(p),
                                    [asset(ctx.policy, b['relay_asset_id'])['ip'] for b in p['relay_bindings']], p['overwrite_ports'])
    if step_id.startswith('relay:'):
        rid = step_id.split(':', 1)[1]
        binding = next(b for b in p['relay_bindings'] if b['relay_asset_id'] == rid)
        coordinator_firewall(ctx, remote, rid, [binding['entry_port']], [], [])
        remote.work(ctx, rid, 'restart', {})
        # Each ingress is accepted before the next one is touched.
        rows = Panel(ctx.policy).nodes()
        nid = next(r for r in rows if r['id'] in ctx.value('public_node_ids') and r['machine_id'] == asset(ctx.policy, rid)['machine_id'])
        tls_probe(asset(ctx.policy, rid)['ip'], binding['entry_port'], nid['protocol_settings']['reality_settings']['server_name'])
        actual = exit_probe(ctx, nid)
        return '本入口端口、Reality 握手及落地出口通过：' + actual
    if step_id == 'verify':
        return coordinator_verify(ctx)
    if step_id == 'publish':
        return coordinator_publish(ctx)
    fail('ACTION_DENIED', '未知部署步骤')


def coordinator_rollback(ctx, remote):
    panel, dns = Panel(ctx.policy), DNS(ctx.policy)
    # Hide owned public nodes first so cleanup never advertises a broken route.
    for resource in ctx.secret['resources']:
        if resource['kind'] == 'xboard_node' and resource.get('published'):
            matching = [n for n in panel.nodes() if n.get('code') == resource['code']]
            if len(matching) == 1:
                panel.call('manage/update', {'id': matching[0]['id'], 'show': 0})
    for resource in reversed(ctx.secret['resources']):
        if resource.get('reverted'):
            continue
        kind = resource['kind']
        if kind == 'worker':
            ctx.job['current_step'] = 'rollback:' + resource['job_id']
            remote.work(ctx, resource['asset_id'], 'rollback', {'worker_job_id': resource['job_id']})
        elif kind == 'xboard_node':
            rows = panel.nodes()
            matching = [n for n in rows if n.get('code') == resource['code']]
            if matching:
                if len(matching) != 1:
                    fail('ROLLBACK_DRIFT', '任务节点标记不唯一，停止删除')
                row = matching[0]
                expected = resource['expected']
                if any(row.get(k) != expected[k] for k in ('name', 'host', 'machine_id', 'server_port', 'protocol_settings', 'custom_outbounds', 'custom_routes')):
                    fail('ROLLBACK_DRIFT', '任务节点已被其他操作修改，保留并停止回滚')
                if any(n.get('parent_id') == row['id'] for n in rows):
                    fail('ROLLBACK_REFERENCED', '任务节点已被其他节点引用，保留并停止回滚')
                panel.call('manage/drop', {'id': row['id']})
        elif kind == 'xboard_machine':
            matching = [m for m in panel.call('machine/fetch') if m.get('notes') == resource['marker']]
            if matching:
                if len(matching) != 1 or any(n.get('machine_id') == matching[0]['id'] for n in panel.nodes()):
                    fail('ROLLBACK_REFERENCED', '机器已被节点引用，保留机器记录')
                panel.call('machine/drop', {'id': matching[0]['id']})
        elif kind == 'dns':
            rows = dns.records(resource['domain'])
            owned = [r for r in rows if r.get('comment') == resource['marker']]
            for row in owned:
                if row.get('type') != 'A' or row.get('content') != resource['content']:
                    fail('ROLLBACK_DRIFT', 'DNS 记录已变化，保留并停止回滚')
                dns.call('/' + row['id'], 'DELETE')
        elif kind == 'komari':
            spec = ctx.policy['komari']
            base, bearer = spec['url'].rstrip('/'), token(spec['token_file'])
            data = http(base + '/api/admin/client/list', bearer=bearer, test=ctx.policy.get('test_mode') is True)
            rows = data if isinstance(data, list) else data.get('data', [])
            matching = [r for r in rows if r.get('name') == resource['marker']]
            if len(matching) > 1:
                fail('ROLLBACK_DRIFT', '探针任务标记不唯一，保留并停止回滚')
            for row in matching:
                http(base + '/api/admin/client/' + row['uuid'] + '/remove', 'POST', {}, bearer,
                     test=ctx.policy.get('test_mode') is True)
        elif kind in ('file', 'ufw'):
            partial = {'resources': [resource]}
            rollback_files(partial)
        elif kind == 'certificate_lease':
            with lock_file('renew-' + resource['asset_id']) as locked:
                if not locked:
                    fail('JOB_RUNNING', '该资产证书正在续期，请等待续期任务结束后重试回滚')
                path = directory('deployment-certificates') / (resource['asset_id'] + '.json')
                if path.exists():
                    lease = owned_json(path)
                    if lease['created_from_job'] != resource['job_id']:
                        fail('ROLLBACK_REFERENCED', '证书续期登记已由其他任务接管，停止删除')
                    path.unlink()
        resource['reverted'] = True
        ctx.persist()
        event(ctx.job, 'rollback.resource', '已处理本任务资源：' + kind)
    if any(r['kind'] == 'file' for r in ctx.secret['resources']):
        command(['/usr/sbin/nginx', '-t'])
        command(['/usr/bin/systemctl', 'reload', 'nginx'])
    return '本任务可恢复资源已撤销；安全更新、ACME 账户与已签发证书归档保留'


@contextlib.contextmanager
def lock_file(name):
    path = directory('deployment-locks') / name
    if not path.exists():
        CORE.atomic_write(path, b'', 0o600)
    CORE.safe_file(path, 0o600)
    with path.open('rb') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def run_one(jid):
    with lock_file(jid) as locked:
        if not locked:
            return
        job = CORE.load_job(jid)
        worker = job.get('action') == 'deployment.worker'
        if job.get('action') not in ('deployment', 'deployment.worker') or job['status'] not in ('queued', 'running', 'rollback_queued', 'rolling_back', 'verify_queued'):
            return
        with lock_file('worker' if worker else 'coordinator') as role_locked:
            if not role_locked:
                return
            policy = load_policy()
            ctx = Context(job, policy)
            try:
                core_asset, keys = CORE.load_state()
                if job['actor'] not in {k['fingerprint'] for k in keys}:
                    fail('ACCESS_REVOKED', '任务发起设备密钥已撤销，停止后续动作')
                if ctx.secret['policy_sha256'] != policy_digest(policy):
                    fail('PLAN_MISMATCH', '服务端部署策略已经变化，停止沿用旧部署单')
                if ctx.secret.get('runner_sha256') != CORE.DEPLOYMENT_SHA256:
                    fail('RUNNER_VERSION', '任务绑定的执行器哈希已变化，停止用新版代码执行旧任务')
                rolling_back = job['status'] in ('rollback_queued', 'rolling_back')
                reverify = job['status'] == 'verify_queued'
                job['status'] = 'rolling_back' if rolling_back else 'running'
                CORE.save_job(job)
                if worker:
                    operation = job['operation']
                    valid_worker(policy, core_asset, job['actor'], {'job_id': jid, 'operation': operation, 'params': ctx.secret['params']})
                    job['steps'][0]['status'] = 'running'
                    event(job, operation + '.started', '正在执行并验收固定动作：' + operation)
                    CORE.audit(job['actor'], 'runner.' + operation, {}, job['plan_id'], 'started')
                    result = WORKERS[operation](ctx, ctx.secret['params'])
                    job['result'] = result
                    job['steps'][0].update(status='succeeded', result_note=result['evidence'])
                    CORE.audit(job['actor'], 'runner.' + operation, {}, job['plan_id'], 'succeeded')
                elif rolling_back:
                    message = coordinator_rollback(ctx, Remote(policy))
                    job['status'] = 'rolled_back'
                    job['verified'] = False
                    job['result'] = {'deployment_verified': False, 'rollback_note': message}
                    event(job, 'rollback.completed', message)
                    return
                elif reverify:
                    message = coordinator_verify(ctx)
                    job['result']['verification_evidence'] = ctx.value('verification_evidence')
                    event(job, 'deployment.reverified', message)
                else:
                    remote = Remote(policy)
                    for step in job['steps']:
                        if step['status'] == 'succeeded':
                            continue
                        _, current_keys = CORE.load_state()
                        if job['actor'] not in {k['fingerprint'] for k in current_keys}:
                            fail('ACCESS_REVOKED', '设备密钥已撤销，停止下一步')
                        job['current_step'] = step['id']
                        step['status'], step['started_at'] = 'running', CORE.utc_now()
                        step.pop('error', None)
                        event(job, step['id'] + '.started', step['title'])
                        CORE.audit(job['actor'], 'runner.' + step['id'], {}, job['plan_id'], 'started')
                        started = time.monotonic()
                        evidence = coordinator_step(ctx, remote, step['id'])
                        step.update(status='succeeded', finished_at=CORE.utc_now(),
                                    duration_seconds=round(time.monotonic() - started, 2), result_note=evidence)
                        CORE.audit(job['actor'], 'runner.' + step['id'], {}, job['plan_id'], 'succeeded')
                        event(job, step['id'] + '.verified', evidence)
                    job['result'] = {'deployment_verified': True,
                                     'verification_evidence': ctx.value('verification_evidence'),
                                     'public_node_ids': ctx.value('public_node_ids')}
                job.update(status='succeeded', verified=True, finished_at=CORE.utc_now())
                event(job, 'job.completed', '固定动作独立验收通过' if worker else '全部步骤与真实出口验收通过，订阅已发布')
            except Exception as exc:
                if isinstance(exc, CORE.Rejected):
                    code, message = exc.code, exc.message
                else:
                    code, message = 'RUNNER_FAILED', '步骤异常，已保存现场；请查看服务器 journald 并修复后继续'
                job['status'] = ('waiting_reboot' if code == 'REBOOT_REQUIRED' else
                                 'rollback_failed' if job['status'] == 'rolling_back' else 'failed')
                job['verified'] = False
                job['error'] = {'code': code, 'message': message}
                for step in job['steps']:
                    if step['status'] == 'running':
                        step['status'] = job['status'] if code == 'REBOOT_REQUIRED' else 'failed'
                        step['error'] = message
                        step['remediation'] = '完成服务器重启后继续原任务' if code == 'REBOOT_REQUIRED' else '按错误码检查工作机策略、上游授权及服务器日志，修复后继续原任务；不要重新创建部署单'
                event(job, 'job.paused', message)
                try:
                    CORE.audit(job['actor'], 'runner.paused', {}, job['plan_id'], 'failed:' + code)
                except CORE.Rejected:
                    pass


def expire_firewalls():
    for path in directory('deployment-private').glob('*.json'):
        try:
            with lock_file(path.stem) as locked:
                if not locked:
                    continue
                state = owned_json(path)
                changed = False
                for resource in state.get('resources', []):
                    if (resource.get('kind') == 'ufw' and not resource.get('confirmed')
                            and not resource.get('reverted') and resource['deadline'] <= time.time()):
                        added = command(['/usr/sbin/ufw', 'show', 'added']).decode()
                        if resource['marker'] in added:
                            command(['/usr/sbin/ufw', '--force', 'delete', *resource['args'], 'comment', resource['marker']])
                        resource['reverted'] = True
                        changed = True
                if changed:
                    save(path, state)
                    job = CORE.load_job(path.stem)
                    job.update(status='failed', verified=False,
                               error={'code': 'FIREWALL_REVERTED', 'message': '独立连接确认超时，本任务新加的规则已自动撤销'})
                    event(job, 'firewall.reverted', '独立连接确认超时，本任务新加的规则已自动撤销')
        except (CORE.Rejected, OSError, ValueError):
            continue


def renew_certificate(aid):
    with lock_file('renew-' + aid) as locked:
        if not locked:
            return
        path = directory('deployment-certificates') / (aid + '.json')
        lease = owned_json(path)
        policy = load_policy()
        if policy['mode'] != 'coordinator' or asset(policy, aid)['domain'] != lease['domain']:
            fail('POLICY_MISMATCH', '续期资产与当前服务端策略不一致')
        jid = str(uuid.uuid4())
        core_asset, _ = CORE.load_state()
        job = {'schema_version': 2, 'job_id': jid, 'asset_id': core_asset['asset_id'],
               'actor': 'root.renew', 'action': 'deployment.renew', 'plan_id': policy_digest(policy),
               'current_step': 'certificate.renew', 'status': 'running', 'verified': False,
               'started_at': CORE.utc_now(), 'events': [], 'steps': [], 'result': {}}
        save(private_path(jid), {'params': {'target_asset_id': aid, 'domain': lease['domain']},
                                 'policy_sha256': policy_digest(policy), 'runner_sha256': CORE.DEPLOYMENT_SHA256,
                                 'resources': [], 'values': {}})
        event(job, 'certificate.renew.started', '开始核对并续签已部署资产的证书')
        try:
            CORE.audit('root.renew', 'certificate.renew', {'asset_id': aid}, None, 'started')
            evidence = coordinator_certificate(Context(job, policy), Remote(policy))
            job.update(status='succeeded', verified=True, finished_at=CORE.utc_now(), result={'evidence': evidence})
            lease.update(next_check=time.time() + 43200, last_ok=CORE.utc_now())
            lease.pop('error', None)
            CORE.audit('root.renew', 'certificate.renew', {'asset_id': aid}, None, 'ok')
            event(job, 'certificate.renew.verified', evidence)
        except Exception as exc:
            code = exc.code if isinstance(exc, CORE.Rejected) else 'RENEWAL_FAILED'
            lease.update(next_check=time.time() + 3600, error=code)
            job.update(status='failed', error={'code': code, 'message': '证书续期或安全下发未通过，请检查服务端日志'})
            event(job, 'certificate.renew.failed', '证书续期未通过，保留现有证书，1 小时后再检查')
        save(path, lease)


def daemon():
    active = {}
    heartbeat_at = 0
    while True:
        try:
            if time.monotonic() - heartbeat_at >= 3:
                save(CORE.HOME / 'runner-heartbeat.json', {'time': time.time(), 'pid': os.getpid()})
                heartbeat_at = time.monotonic()
            expire_firewalls()
            for jid, proc in list(active.items()):
                if proc.poll() is not None:
                    del active[jid]
            if not any(key.startswith('renew-') for key in active) and len(active) < 3:
                for lease_path in directory('deployment-certificates').glob('*.json'):
                    if not CORE.ID_RE.fullmatch(lease_path.stem):
                        continue
                    lease = owned_json(lease_path)
                    if lease.get('next_check', 0) <= time.time():
                        active['renew-' + lease_path.stem] = subprocess.Popen(
                            ['/usr/bin/python3', '-I', str(MODULE), '--renew', lease_path.stem],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        break
            for path in CORE.JOBS_DIR.glob('*.json'):
                if len(active) >= 4:
                    break
                if not CORE.ID_RE.fullmatch(path.stem) or path.stem in active:
                    continue
                job = CORE.load_job(path.stem)
                if (job.get('action') in ('deployment', 'deployment.worker')
                        and job.get('status') in ('queued', 'running', 'rollback_queued', 'rolling_back', 'verify_queued')):
                    active[path.stem] = subprocess.Popen(
                        ['/usr/bin/python3', '-I', str(MODULE), '--run', path.stem],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (CORE.Rejected, OSError, ValueError):
            # Config missing during first provisioning is a reported preflight
            # failure, not a reason to lose the persistent queue.
            pass
        time.sleep(1)


def main():
    import runpy
    import sys
    import types
    core = types.SimpleNamespace(**runpy.run_path('/usr/local/lib/opsctl/opsctl.py'))
    bind(core)
    CORE.check_root()
    if CORE.digest(CORE.read_owned(MODULE, 0o755)) != CORE.DEPLOYMENT_SHA256:
        fail('RUNNER_HASH_MISMATCH', 'runner 与安装时的固定哈希不匹配')
    CORE.ensure_state_dirs()
    if sys.argv[1:] == ['--daemon']:
        daemon()
    elif len(sys.argv) == 3 and sys.argv[1] == '--run' and CORE.ID_RE.fullmatch(sys.argv[2]):
        run_one(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == '--renew' and CORE.ID_RE.fullmatch(sys.argv[2]):
        renew_certificate(sys.argv[2])
    else:
        fail('ACTION_DENIED', 'runner 只接受固定运行入口')


if __name__ == '__main__':
    main()
