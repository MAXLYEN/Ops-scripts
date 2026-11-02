#!/usr/bin/python3
"""Disposable Docker TLS + runner fixture. Never installed on managed servers."""
import http.server
import json
import os
import pathlib
import ssl
import subprocess
import sys
import time

ROOT = pathlib.Path('/tmp/opsdeck-deployment-fixture')
DOMAIN = 'fixture.example.net'


def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if os.environ.get('OPSDECK_DISPOSABLE_TEST') != '1' or not pathlib.Path('/.dockerenv').exists():
        raise SystemExit('Only an explicitly opted-in disposable Docker fixture is supported')
    if sys.argv[1:] == ['--serve']:
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'fixture')
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 8443), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(ROOT / 'leaf.crt'), str(ROOT / 'leaf.key'))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
        return
    if len(sys.argv) != 3 or sys.argv[1] != '--configure':
        raise SystemExit('Expected --configure <authorized test actor fingerprint>')
    actor = sys.argv[2]
    keys = json.loads(pathlib.Path('/etc/opsctl/keys.json').read_text())
    if actor not in {k['fingerprint'] for k in keys}:
        raise SystemExit('Test actor has not enrolled')
    policy_path = pathlib.Path('/etc/opsctl/deployment.json')
    if policy_path.exists() and json.loads(policy_path.read_text()).get('test_mode') is not True:
        raise SystemExit('Refusing to replace a non-test deployment policy')
    ROOT.mkdir(mode=0o700, exist_ok=True)
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
         '-subj', '/CN=OpsDeck Disposable Test CA', '-keyout', str(ROOT / 'ca.key'), '-out', str(ROOT / 'ca.crt')])
    run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + DOMAIN,
         '-keyout', str(ROOT / 'leaf.key'), '-out', str(ROOT / 'leaf.csr')])
    (ROOT / 'extensions.cnf').write_text('subjectAltName=DNS:' + DOMAIN + '\n')
    run(['openssl', 'x509', '-req', '-in', str(ROOT / 'leaf.csr'), '-CA', str(ROOT / 'ca.crt'),
         '-CAkey', str(ROOT / 'ca.key'), '-CAcreateserial', '-days', '2',
         '-extfile', str(ROOT / 'extensions.cnf'), '-out', str(ROOT / 'leaf.crt')])
    trust = pathlib.Path('/usr/local/share/ca-certificates/opsdeck-disposable-test.crt')
    trust.write_bytes((ROOT / 'ca.crt').read_bytes())
    run(['update-ca-certificates'])
    asset = json.loads(pathlib.Path('/etc/opsctl/asset.json').read_text())
    host_key = pathlib.Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().strip()
    policy = {'schema_version': 1, 'mode': 'worker', 'domain_suffix': 'example.net',
              'test_mode': True, 'coordinator_fingerprints': [actor],
              'assets': {asset['asset_id']: {'name': 'Fixture', 'ip': '127.0.0.1', 'ssh_port': 22,
                                           'host_key': host_key, 'domain': DOMAIN,
                                           'runner_version': '3.0.0'}}}
    policy_path.write_text(json.dumps(policy))
    policy_path.chmod(0o600)
    for filename in ('ca.key', 'leaf.key'):
        (ROOT / filename).chmod(0o600)
    for args, pid_name in ((['/usr/bin/python3', '-I', __file__, '--serve'], 'tls.pid'),
                           (['/usr/bin/python3', '-I', '/usr/local/lib/opsctl/deployment.py', '--daemon'], 'runner.pid')):
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        (ROOT / pid_name).write_text(str(process.pid))
    for _ in range(50):
        heartbeat = pathlib.Path('/var/lib/opsctl/runner-heartbeat.json')
        if heartbeat.exists() and time.time() - json.loads(heartbeat.read_text())['time'] < 10:
            print(json.dumps({'configured': True, 'asset_id': asset['asset_id']}))
            return
        time.sleep(.1)
    raise SystemExit('Runner did not become ready')


if __name__ == '__main__':
    main()
