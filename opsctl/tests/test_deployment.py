"""Root-only isolated deployment tests: temp state + real loopback HTTP, no fleet."""
import base64
import contextlib
import http.server
import importlib.util
import json
import pathlib
import threading
import time
import types
import unittest
import uuid
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bootstrap_tests', HERE / 'test_bootstrap.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
ACTOR = 'SHA256:' + 'A' * 43
WORKER = 'SHA256:' + 'B' * 43
TARGET = base.OTHER_ASSET
RELAY = base.RELAY_A
PUB = 'ssh-ed25519 ' + base64.b64encode(b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20' + bytes(32)).decode()


class Upstream:
    def __init__(self):
        self.calls = []
        self.nodes = []
        self.dns = []
        self.machines = [{'id': 7, 'name': 'Test-HK2', 'notes': ''}]
        self.lost_dns = False
        self.lost_node = False
        self.payload = b'\x7fELFtest-binary'
        self.redirect = False
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.route()

            def do_POST(self):
                self.route()

            def do_DELETE(self):
                self.route()

            def route(self):
                path = self.path.split('?', 1)[0]
                raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                body = json.loads(raw) if raw else None
                owner.calls.append((self.command, path, body))
                if owner.redirect:
                    self.send_response(302)
                    self.send_header('Location', owner.url + '/stolen')
                    self.end_headers()
                    return
                if path == '/artifact':
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(owner.payload)
                    return
                if path.endswith('/manage/getNodes'):
                    result = {'data': owner.nodes}
                elif path.endswith('/manage/save'):
                    # Validate the public PHP ServerSave contract, not a custom
                    # endpoint that only happens to accept our implementation.
                    required = {'type', 'name', 'host', 'port', 'server_port', 'rate'}
                    if not required.issubset(body) or body['type'] != 'vless':
                        self.send_error(422)
                        return
                    owner.nodes.append({**body, 'id': 100 + len(owner.nodes)})
                    if owner.lost_node:
                        owner.lost_node = False
                        self.connection.shutdown(2)
                        self.connection.close()
                        return
                    result = {'data': True}
                elif path.endswith('/manage/update'):
                    for node in owner.nodes:
                        if node['id'] == body['id']:
                            node.update({k: v for k, v in body.items() if k != 'id'})
                    result = {'data': True}
                elif path.endswith('/manage/drop'):
                    owner.nodes[:] = [n for n in owner.nodes if n['id'] != body['id']]
                    result = {'data': True}
                elif path.endswith('/machine/fetch'):
                    result = {'data': owner.machines}
                elif path.endswith('/machine/getToken'):
                    result = {'data': {'token': 'test-single-machine-token'}}
                elif '/dns_records' in path:
                    if self.command == 'POST':
                        owner.dns.append({**body, 'id': 'test-dns-id'})
                        if owner.lost_dns:
                            owner.lost_dns = False
                            self.connection.shutdown(2)
                            self.connection.close()
                            return
                        result = {'success': True, 'result': owner.dns[-1]}
                    elif self.command == 'DELETE':
                        owner.dns.clear()
                        result = {'success': True, 'result': {'id': 'test-dns-id'}}
                    else:
                        result = {'success': True, 'result': owner.dns}
                else:
                    self.send_error(404)
                    return
                payload = json.dumps(result).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class Deployment(base.Base):
    def setUp(self):
        super().setUp()
        if not hasattr(self, 'tmp'):
            return
        self.d = self.m.deployment_module()
        self.d.POLICY = self.m.ETC / 'deployment.json'
        self.d.CORE.audit = lambda *args: None
        self.d.CORE.load_state = lambda: (self.asset, [{'fingerprint': ACTOR}, {'fingerprint': WORKER}])
        self.server = Upstream()
        credential = self.tmp / 'token'
        credential.write_text('test-upstream-token')
        credential.chmod(0o600)
        self.policy = {
            'schema_version': 1, 'mode': 'coordinator', 'domain_suffix': 'example.net',
            'test_mode': True, 'coordinator_fingerprints': [WORKER],
            'assets': {
                TARGET: {'name': 'Test-HK2', 'ip': '192.0.2.10', 'ssh_port': 22,
                         'host_key': PUB, 'domain': 'test.example.net', 'runner_version': '3.0.0',
                         'machine_id': 7},
                RELAY: {'name': 'Entry', 'ip': '192.0.2.20', 'ssh_port': 22, 'role': 'direct',
                        'host_key': PUB, 'domain': 'entry.example.net', 'runner_version': '3.0.0',
                        'machine_id': 8, 'template_node_id': 1},
                self.asset['asset_id']: {'name': 'Center', 'ip': '192.0.2.30', 'ssh_port': 22,
                                        'host_key': PUB, 'domain': 'center.example.net', 'runner_version': '3.0.0'},
            },
            'xboard': {'url': self.server.url, 'admin_path': 'test-admin', 'token_file': str(credential),
                       'template_node_id': 1},
            'cloudflare': {'api_url': self.server.url, 'zone_id': 'a' * 32, 'token_file': str(credential)},
            'panel_url': self.server.url, 'komari_url': self.server.url,
            'artifacts': {}, 'probe_uuid_file': str(credential),
        }
        self.d.save(self.d.POLICY, self.policy)
        self.d.save(self.m.HOME / 'runner-heartbeat.json', {'time': time.time()})
        self.params = {'target_asset_id': TARGET, 'server_name': 'Test-HK2', 'role': 'direct',
                       'domain': 'test.example.net', 'node_ports': [443], 'relay_bindings': [],
                       'init_system': False}

    def tearDown(self):
        if hasattr(self, 'server'):
            self.server.close()
        super().tearDown()

    def make_plan(self):
        return self.d.plan(self.policy, self.params, ACTOR, self.asset)

    def queued(self):
        plan = self.make_plan()
        return self.d.enqueue(self.asset, ACTOR, {'job_id': plan['job_id'], 'plan_id': plan['plan_id']})

    def test_unknown_fields_and_unregistered_assets_rejected(self):
        for params in ({**self.params, 'shell': 'touch /tmp/no'},
                       {**self.params, 'target_asset_id': str(uuid.uuid4())},
                       {**self.params, 'domain': 'another.example.net'},
                       {**self.params, 'node_ports': [22]},
                       {**self.params, 'node_ports': [443, True]}):
            with self.subTest(params=params), self.assertRaises(self.m.Rejected):
                self.d.normalize(self.policy, params)

    def test_custom_ports_are_supported_without_bypassing_protected_ports(self):
        norm = self.d.normalize(self.policy, {**self.params, 'node_ports': [12345]})
        self.assertEqual(norm['node_ports'], [12345])
        worker = {**self.policy, 'mode': 'worker'}
        self.d.valid_worker(worker, {'asset_id': TARGET}, WORKER,
            {'job_id': str(uuid.uuid4()), 'operation': 'probe',
             'params': {'domain': 'test.example.net', 'ports': [12345]}})
        for port in (22, 8444):
            with self.assertRaises(self.m.Rejected):
                self.d.normalize(self.policy, {**self.params, 'node_ports': [port]})
        with self.assertRaises(self.m.Rejected):
            self.d.normalize({**self.policy, 'allow_custom_ports': False},
                             {**self.params, 'node_ports': [12345]})

    def test_port_scan_keeps_loopback_conflicts_and_real_inode_unit(self):
        proc = self.proc / '1234'
        (proc / 'fd').mkdir(parents=True)
        (proc / 'comm').write_text('nginx\n')
        (proc / 'cgroup').write_text('0::/system.slice/nginx.service\n')
        (proc / 'exe').symlink_to('/usr/sbin/nginx')
        (proc / 'fd' / '7').symlink_to('socket:[555]')
        table = self.proc / 'net' / 'tcp'
        table.write_text(table.read_text() + '0: 0100007F:01BB 00000000:0000 0A 0 0 0 0 0 555\n')
        ports = self.m.scan_listening_ports()
        self.assertEqual(ports[0]['port'], 443)
        self.assertEqual(ports[0]['unit'], 'nginx.service')
        self.assertFalse(ports[0]['self_managed'])

    def test_unreadable_port_tables_are_unknown_not_free(self):
        (self.proc / 'net' / 'tcp').unlink()
        (self.proc / 'net' / 'tcp6').unlink()
        with self.assertRaises(self.m.Rejected) as err:
            self.m.scan_listening_ports()
        self.assertEqual(err.exception.code, 'PORT_SCAN_FAILED')

    def test_runner_missing_heartbeat_blocks_plan(self):
        (self.m.HOME / 'runner-heartbeat.json').unlink()
        with self.assertRaises(self.m.Rejected) as err:
            self.make_plan()
        self.assertEqual(err.exception.code, 'RUNNER_NOT_RUNNING')

    def test_restart_waits_after_enqueue_and_verifies_active_service(self):
        with patch.object(self.d.time, 'sleep') as sleep, patch.object(self.d, 'command', return_value=b'') as cmd:
            result = self.d.worker_restart(None, {})
        sleep.assert_called_once_with(5)
        self.assertEqual(cmd.call_args_list[0].args[0], ['/usr/bin/systemctl', 'restart', 'xboard-node'])
        self.assertEqual(cmd.call_args_list[1].args[0], ['/usr/bin/systemctl', 'is-active', 'xboard-node'])
        self.assertIn('active', result['evidence'])

    def test_plan_binds_actor_job_policy_and_snapshot(self):
        plan = self.make_plan()
        request = {'job_id': plan['job_id'], 'plan_id': plan['plan_id']}
        with self.assertRaises(self.m.Rejected):
            self.d.enqueue(self.asset, WORKER, request)
        with self.assertRaises(self.m.Rejected):
            self.d.enqueue(self.asset, ACTOR, {**request, 'job_id': str(uuid.uuid4())})
        self.server.nodes.append({'id': 9})
        with self.assertRaises(self.m.Rejected) as ctx:
            self.d.enqueue(self.asset, ACTOR, request)
        self.assertEqual(ctx.exception.code, 'PLAN_MISMATCH')
        self.assertEqual(list(self.m.JOBS_DIR.glob('*.json')), [])

    def test_enqueue_is_durable_idempotent_and_not_success(self):
        job = self.queued()
        repeated = self.d.enqueue(self.asset, ACTOR, {'job_id': job['job_id'], 'plan_id': job['plan_id']})
        self.assertEqual(job, repeated)
        self.assertEqual(job['status'], 'queued')
        self.assertFalse(job['verified'])
        self.assertFalse(job['result']['deployment_verified'])
        self.assertEqual(len(list(self.m.JOBS_DIR.glob('*.json'))), 1)
        self.assertEqual(self.m.load_job(job['job_id']), job)

    def test_expired_plan_rejected(self):
        plan = self.make_plan()
        path = self.d.directory('deployment-plans') / (plan['plan_id'] + '.json')
        doc = self.d.owned_json(path)
        doc['expires_at'] = time.time() - 1
        self.d.save(path, doc)
        with self.assertRaises(self.m.Rejected):
            self.d.enqueue(self.asset, ACTOR, {'job_id': plan['job_id'], 'plan_id': plan['plan_id']})

    def test_root_policy_change_invalidates_resume(self):
        job = self.queued()
        job['status'] = 'failed'
        self.m.save_job(job)
        self.policy['entry_ports'] = [8443]
        self.d.save(self.d.POLICY, self.policy)
        with self.assertRaises(self.m.Rejected):
            self.d.control(self.asset, ACTOR, {'job_id': job['job_id'], 'plan_id': job['plan_id']}, 'resume')

    def test_crash_resume_skips_passed_steps_and_retains_events(self):
        job = self.queued()
        calls = []
        failed = [False]

        def execute(ctx, remote, step):
            calls.append(step)
            if step == 'dns' and not failed[0]:
                failed[0] = True
                raise OSError('test-secret-must-never-appear')
            if step == 'verify':
                ctx.value('verification_evidence', [{'exit_ip': '192.0.2.10'}])
            return 'independent evidence: ' + step

        with patch.object(self.d, 'coordinator_step', side_effect=execute):
            self.d.run_one(job['job_id'])
            paused = self.m.load_job(job['job_id'])
            self.assertEqual(paused['status'], 'failed')
            self.assertEqual(paused['steps'][0]['status'], 'succeeded')
            self.assertEqual(paused['steps'][4]['status'], 'failed')
            self.assertEqual(paused['steps'][5]['status'], 'pending')
            self.assertNotIn('test-secret', json.dumps(paused))
            self.d.control(self.asset, ACTOR, {'job_id': job['job_id'], 'plan_id': job['plan_id']}, 'resume')
            self.d.run_one(job['job_id'])
        final = self.m.load_job(job['job_id'])
        self.assertEqual(calls.count('preflight'), 1)
        self.assertEqual(calls.count('dns'), 2)
        self.assertEqual(final['status'], 'succeeded')
        self.assertTrue(final['result']['deployment_verified'])
        seq = [e['seq'] for e in final['events']]
        self.assertEqual(seq, list(range(1, len(seq) + 1)))

    def test_revoked_device_cannot_run_queued_job(self):
        job = self.queued()
        self.d.CORE.load_state = lambda: (self.asset, [])
        with patch.object(self.d, 'coordinator_step') as execute:
            self.d.run_one(job['job_id'])
        execute.assert_not_called()
        self.assertEqual(self.m.load_job(job['job_id'])['error']['code'], 'ACCESS_REVOKED')

    def test_client_key_cannot_enqueue_worker_and_secret_not_in_status(self):
        self.policy['mode'] = 'worker'
        self.d.save(self.d.POLICY, self.policy)
        req = {'job_id': str(uuid.uuid4()), 'operation': 'certificate', 'params': {
            'domain': 'center.example.net', 'certificate': '-----BEGIN CERTIFICATE-----\ntest',
            'private_key': '-----BEGIN PRIVATE KEY-----\ntest-sensitive-private-key'}}
        with self.assertRaises(self.m.Rejected):
            self.d.enqueue_worker(self.asset, ACTOR, req)
        job = self.d.enqueue_worker(self.asset, WORKER, req)
        self.assertNotIn('test-sensitive-private-key', json.dumps(job))
        state = self.d.owned_json(self.d.private_path(req['job_id']))
        self.assertIn('test-sensitive-private-key', state['params']['private_key'])
        self.assertEqual(self.d.private_path(req['job_id']).stat().st_mode & 0o777, 0o600)
        with self.assertRaises(self.m.Rejected):
            self.d.enqueue_worker(self.asset, WORKER, {**req, 'operation': 'restart', 'params': {}})

    def test_real_http_redirect_is_rejected_before_auth_can_leak(self):
        self.server.redirect = True
        with self.assertRaises(self.m.Rejected) as ctx:
            self.d.http(self.server.url + '/redirect', bearer='test-token', test=True)
        self.assertEqual(ctx.exception.code, 'HTTP_REDIRECT_DENIED')
        self.assertFalse(any(path == '/stolen' for _, path, _ in self.server.calls))

    def test_real_download_checks_hash_before_elf(self):
        spec = {'url': self.server.url + '/artifact', 'version': 'test-1', 'sha256': '0' * 64}
        with self.assertRaises(self.m.Rejected) as ctx:
            self.d.verified_download(spec, test=True)
        self.assertEqual(ctx.exception.code, 'ARTIFACT_HASH_MISMATCH')
        spec['sha256'] = self.m.digest(self.server.payload)
        self.assertEqual(self.d.verified_download(spec, test=True), self.server.payload)

    def test_dns_ambiguous_success_reconciles_without_duplicate(self):
        job = self.queued()
        ctx = self.d.Context(job, self.policy)
        self.server.lost_dns = True
        with self.assertRaises(self.m.Rejected):
            self.d.coordinator_dns(ctx)
        ctx = self.d.Context(self.m.load_job(job['job_id']), self.policy)
        self.d.coordinator_dns(ctx)
        self.assertEqual(len(self.server.dns), 1)
        self.assertEqual(len([1 for method, path, _ in self.server.calls if method == 'POST' and path.endswith('/dns_records')]), 1)
        self.assertEqual(ctx.secret['resources'][0]['id'], 'test-dns-id')

    def test_node_ambiguous_success_reconciles_without_duplicate(self):
        job = self.queued()
        ctx = self.d.Context(job, self.policy)
        row = {'type': 'vless', 'code': 'test-owned-code', 'name': 'Test-HK2-L',
               'host': 'test.example.net', 'machine_id': 7, 'port': '443', 'server_port': 443,
               'rate': 1, 'protocol_settings': {}, 'custom_outbounds': [], 'custom_routes': []}
        self.server.lost_node = True
        with self.assertRaises(self.m.Rejected):
            self.d.node_create(ctx, self.d.Panel(self.policy), row)
        ctx = self.d.Context(job, self.policy)
        self.d.node_create(ctx, self.d.Panel(self.policy), row)
        self.assertEqual(len(self.server.nodes), 1)
        self.assertEqual(len([1 for method, path, _ in self.server.calls if method == 'POST' and path.endswith('/manage/save')]), 1)

    def test_rollback_preserves_external_file_changes(self):
        job = self.queued()
        ctx = self.d.Context(job, self.policy)
        path = self.tmp / 'a-config'
        path.write_bytes(b'original')
        path.chmod(0o600)
        ctx.write(path, b'owned')
        path.write_bytes(b'external-change')
        with patch.object(self.d, 'command', return_value=b''), self.assertRaises(self.m.Rejected) as err:
            self.d.rollback_files(ctx.secret)
        self.assertEqual(err.exception.code, 'ROLLBACK_DRIFT')
        self.assertEqual(path.read_bytes(), b'external-change')

    def test_publish_requires_positive_exit_evidence(self):
        ctx = self.d.Context(self.queued(), self.policy)
        with self.assertRaises(self.m.Rejected) as err:
            self.d.coordinator_publish(ctx)
        self.assertEqual(err.exception.code, 'VERIFY_REQUIRED')

    def test_resume_write_preserves_external_changes(self):
        ctx = self.d.Context(self.queued(), self.policy)
        path = self.tmp / 'resume-config'
        path.write_bytes(b'original')
        path.chmod(0o600)
        ctx.write(path, b'owned')
        path.write_bytes(b'external')
        with self.assertRaises(self.m.Rejected):
            ctx.write(path, b'owned')
        self.assertEqual(path.read_bytes(), b'external')

    def test_rollback_reconciles_crash_after_file_restored(self):
        ctx = self.d.Context(self.queued(), self.policy)
        path = self.tmp / 'restore-config'
        path.write_bytes(b'original')
        path.chmod(0o600)
        ctx.write(path, b'owned')
        path.write_bytes(b'original')  # Killed between restoration and checkpoint.
        with patch.object(self.d, 'command', return_value=b''):
            self.d.rollback_files(ctx.secret)
            self.d.rollback_files(ctx.secret)
        self.assertEqual(path.read_bytes(), b'original')
        self.assertTrue(ctx.secret['resources'][0]['reverted'])

    def test_task_list_does_not_disclose_another_device_deployment(self):
        job = self.queued()
        own = self.m.list_jobs(self.asset, {'limit': 100}, ACTOR)
        foreign = self.m.list_jobs(self.asset, {'limit': 100}, WORKER)
        self.assertEqual([j['job_id'] for j in own['jobs']], [job['job_id']])
        self.assertEqual(foreign['jobs'], [])

    def test_center_cannot_use_worker_initialization_api(self):
        with self.assertRaises(self.m.Rejected) as err:
            self.d.enqueue_worker(self.asset, WORKER, {'job_id': str(uuid.uuid4()),
                'operation': 'initialize', 'params': {'ssh_port': 22}})
        self.assertEqual(err.exception.code, 'ACTION_DENIED')

    def test_renewal_uses_registered_asset_and_keeps_failure_for_retry(self):
        directory = self.d.directory('deployment-certificates')
        path = directory / (TARGET + '.json')
        self.d.save(path, {'asset_id': TARGET, 'domain': 'test.example.net',
                           'created_from_job': str(uuid.uuid4()), 'next_check': 0})
        with patch.object(self.d, 'coordinator_certificate', side_effect=self.m.Rejected('DNS_REJECTED', 'failed')):
            self.d.renew_certificate(TARGET)
        lease = self.d.owned_json(path)
        self.assertEqual(lease['error'], 'DNS_REJECTED')
        self.assertGreater(lease['next_check'], time.time())
        with patch.object(self.d, 'coordinator_certificate', return_value='certificate delivery verified'):
            self.d.renew_certificate(TARGET)
        lease = self.d.owned_json(path)
        self.assertNotIn('error', lease)
        self.assertIn('last_ok', lease)

    def test_foreign_or_referenced_panel_node_not_dropped(self):
        ctx = self.d.Context(self.queued(), self.policy)
        wanted = {'type': 'vless', 'code': 'test-owned-code', 'name': 'Test-HK2-L',
                  'host': 'test.example.net', 'machine_id': 7, 'port': '443', 'server_port': 443,
                  'rate': 1, 'protocol_settings': {}, 'custom_outbounds': [], 'custom_routes': []}
        row = self.d.node_create(ctx, self.d.Panel(self.policy), wanted)
        self.server.nodes.append({'id': 200, 'parent_id': row['id']})
        with self.assertRaises(self.m.Rejected) as err:
            self.d.coordinator_rollback(ctx, None)
        self.assertEqual(err.exception.code, 'ROLLBACK_REFERENCED')
        self.assertEqual(len(self.server.nodes), 2)

    def test_firewall_watchdog_only_removes_unconfirmed_owned_rules(self):
        job = self.queued()
        state = self.d.owned_json(self.d.private_path(job['job_id']))
        state['resources'] = [
            {'kind': 'ufw', 'args': ['allow', '443/tcp'], 'marker': 'opsdeck:test',
             'deadline': time.time() - 1, 'confirmed': False},
            {'kind': 'ufw', 'args': ['allow', '8443/tcp'], 'marker': 'opsdeck:confirmed',
             'deadline': time.time() - 1, 'confirmed': True},
        ]
        self.d.save(self.d.private_path(job['job_id']), state)
        with patch.object(self.d, 'command', return_value=b'ufw allow 443/tcp comment opsdeck:test') as cmd:
            self.d.expire_firewalls()
        deletes = [c.args[0] for c in cmd.call_args_list if 'delete' in c.args[0]]
        self.assertEqual(deletes, [['/usr/sbin/ufw', '--force', 'delete', 'allow', '443/tcp', 'comment', 'opsdeck:test']])
        self.assertEqual(self.m.load_job(job['job_id'])['error']['code'], 'FIREWALL_REVERTED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
