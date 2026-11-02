"""bootstrap.py（opsctl 服务端）的隔离单测。

所有服务器路径都改指到临时目录，不读写真实 /etc/opsctl、不连任何主机。
文件属主校验要求 root，所以在 WSL 测试容器或 root 下运行：
    python3 -I windows/opsdeck_host/test/python/test_bootstrap.py
"""

import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
import uuid

HERE = pathlib.Path(__file__).resolve()
# OPSCTL_BOOTSTRAP 可指向别的副本（用于注入缺陷，证明测试能发现问题）。
_DEFAULT_SOURCE = HERE.parents[1] / "bootstrap.py"
if not _DEFAULT_SOURCE.exists():
    _DEFAULT_SOURCE = HERE.parents[2] / "vendor" / "bootstrap.py"
SOURCE = pathlib.Path(os.environ.get("OPSCTL_BOOTSTRAP") or _DEFAULT_SOURCE)
ASSET_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_ASSET = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
RELAY_A = "11111111-1111-4111-8111-111111111111"
RELAY_B = "22222222-2222-4222-8222-222222222222"


def load_module():
    spec = importlib.util.spec_from_file_location("opsctl_bootstrap_under_test", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Base(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.skipTest("文件属主校验需要 root；请在 WSL 测试容器里运行")
        self.m = load_module()
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="opsctl-unit-"))
        os.chmod(self.tmp, 0o755)
        m, t = self.m, self.tmp
        etc = t / "etc-opsctl"
        etc.mkdir(mode=0o755)
        home = t / "var-lib-opsctl"
        home.mkdir(mode=0o755)
        units = t / "systemd"
        units.mkdir(mode=0o755)
        proc = t / "proc"
        proc.mkdir(mode=0o755)
        (proc / "net").mkdir()
        for table in ("tcp", "tcp6"):
            (proc / "net" / table).write_text("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n")
        m.ETC, m.HOME, m.JOBS_DIR = etc, home, home / "jobs"
        m.AUTH = etc / "authorized_keys"
        m.BASELINE = home / "security_baseline.json"
        m.PROFILE = home / "role_profile.json"
        m.NODE_CONF = home / "node_binding.json"
        m.SUDOERS = t / "sudoers-opsctl"
        m.SSHD = t / "sshd-90-opsctl.conf"
        m.PROC = proc
        m.KOMARI_UNIT_DIRS = (units,)
        m.KOMARI_OVERRIDE = units / "komari-agent.service.d" / "override.conf"
        self.units, self.proc = units, proc
        m.atomic_write(m.AUTH, b"", 0o644)
        m.atomic_write(m.SUDOERS, m.SUDO_TEXT.encode("ascii"), 0o440)
        m.atomic_write(m.SSHD, m.SSHD_TEXT.encode("ascii"), 0o644)
        self.asset = {"asset_id": ASSET_ID, "version": m.VERSION, "artifact_sha256": "0" * 64}

    def tearDown(self):
        if hasattr(self, "tmp"):
            shutil.rmtree(self.tmp, ignore_errors=True)

    def apply(self, action, params, asset=None):
        asset = asset or self.asset
        norm, _summary = self.m.validate_plan_action(action, params, [])
        pid = self.m.plan_id(asset, action, norm)
        return self.m.execute_apply(asset, [], "SHA256:" + "A" * 43, {
            "job_id": str(uuid.uuid4()), "action": action, "plan_id": pid, "params": params,
        })

    def verify(self, job, asset=None):
        return self.m.execute_verify(asset or self.asset, {"job_id": job["job_id"]})

    def install_komari(self, running_env=None):
        (self.units / "komari-agent.service").write_text("[Service]\n")
        if running_env is not None:
            pid = self.proc / "4242"
            pid.mkdir()
            (pid / "comm").write_text("komari-agent\n")
            (pid / "environ").write_bytes(b"\0".join(running_env) + b"\0")


def binding(rid, landing, entry=443, prefix="Alpha"):
    return {
        "relay_asset_id": rid,
        "relay_name": f"Entry-{prefix}",
        "relay_prefix": prefix,
        "relay_host": "198.51.100.20",
        "landing_port": landing,
        "entry_port": entry,
        "internal_node": "落地-Test-HK2-L",
        "subscription_name": f"Test-HK2-L_{prefix}",
    }


def node_params(**extra):
    params = {
        "server_name": "Test-HK2",
        "role": "landing",
        "protocol": "vless_reality",
        "listen_port": 30205,
        "entry_asset_ids": [RELAY_A, RELAY_B],
        "relay_bindings": [binding(RELAY_A, 30205), binding(RELAY_B, 30403, 2083, "Beta")],
    }
    params.update(extra)
    return params


class ServiceControl(Base):
    def test_not_advertised(self):
        self.assertNotIn("service.control", self.m.CAPABILITIES)

    def test_plan_and_apply_rejected(self):
        with self.assertRaises(self.m.Rejected) as ctx:
            self.m.validate_plan_action("service.control", {"service": "ssh", "operation": "reload"}, [])
        self.assertEqual(ctx.exception.code, "ACTION_DENIED")
        with self.assertRaises(self.m.Rejected) as ctx:
            self.m.execute_apply(self.asset, [], "x", {
                "job_id": str(uuid.uuid4()), "action": "service.control",
                "plan_id": "0" * 64, "params": {"service": "ssh", "operation": "reload"},
            })
        self.assertEqual(ctx.exception.code, "ACTION_DENIED")

    def test_legacy_job_fails_verify(self):
        # 2.1.0 留在服务器上的旧「成功」任务，复验必须判失败。
        self.m.ensure_state_dirs()
        job = {"job_id": str(uuid.uuid4()), "asset_id": ASSET_ID, "action": "service.control",
               "plan_id": "0" * 64, "status": "succeeded", "verified": True, "events": [], "result": {}}
        self.m.save_job(job)
        out = self.verify(job)
        self.assertFalse(out["verified"])
        self.assertIn({"name": "service_control_unsupported", "ok": False}, out["verification"]["checks"])


class VerifyDefaults(Base):
    def test_unknown_action_rejected(self):
        self.m.ensure_state_dirs()
        job = {"job_id": str(uuid.uuid4()), "asset_id": ASSET_ID, "action": "key.revoke",
               "status": "succeeded", "events": [], "result": {}}
        self.m.save_job(job)
        with self.assertRaises(self.m.Rejected) as ctx:
            self.verify(job)
        self.assertEqual(ctx.exception.code, "ACTION_DENIED")

    def test_other_asset_fails(self):
        job = self.apply("template.apply", {"template": "landing_node"})
        other = {**self.asset, "asset_id": OTHER_ASSET}
        self.assertFalse(self.verify(job, other)["verified"])


class RecordConsistency(Base):
    def test_template_is_metadata_only_and_overwrite_fails_old_job(self):
        first = self.apply("template.apply", {"template": "landing_node"})
        self.assertTrue(first["result"]["metadata_only"])
        self.assertFalse(first["result"]["deployment_verified"])
        out = self.verify(first)
        self.assertTrue(out["verified"])
        self.assertEqual(out["verification"]["scope"], "record_consistency")
        self.assertFalse(out["verification"]["deployment_verified"])

        second = self.apply("template.apply", {"template": "docker_app"})
        self.assertFalse(self.verify(first)["verified"], "被覆盖后的旧任务不能再通过")
        self.assertTrue(self.verify(second)["verified"])

    def test_node_overwrite_fails_old_job(self):
        first = self.apply("node.configure", node_params())
        self.assertTrue(self.verify(first)["verified"])
        second = self.apply("node.configure", node_params(listen_port=30206, relay_bindings=[binding(RELAY_A, 30206)]))
        self.assertFalse(self.verify(first)["verified"])
        self.assertTrue(self.verify(second)["verified"])

    def test_tampered_record_fails(self):
        job = self.apply("node.configure", node_params())
        doc = json.loads(self.m.NODE_CONF.read_text(encoding="utf-8"))
        doc["deployment_verified"] = True
        self.m.atomic_write(self.m.NODE_CONF, self.m.canonical(doc) + b"\n", 0o600)
        self.assertFalse(self.verify(job)["verified"])


class RelayBindings(Base):
    def check_rejected(self, **extra):
        with self.assertRaises(self.m.Rejected):
            self.m.validate_plan_action("node.configure", node_params(**extra), [])

    def test_valid_sorted(self):
        norm, _ = self.m.validate_plan_action(
            "node.configure",
            node_params(relay_bindings=[binding(RELAY_B, 30403, 2083, "Beta"), binding(RELAY_A, 30205)]),
            [])
        self.assertEqual([b["relay_asset_id"] for b in norm["relay_bindings"]], [RELAY_A, RELAY_B])

    def test_extra_field_rejected(self):
        bad = binding(RELAY_A, 30205)
        bad["token"] = "x"
        self.check_rejected(relay_bindings=[bad])

    def test_missing_field_rejected(self):
        bad = binding(RELAY_A, 30205)
        del bad["entry_port"]
        self.check_rejected(relay_bindings=[bad])

    def test_duplicate_landing_port_rejected(self):
        self.check_rejected(relay_bindings=[binding(RELAY_A, 30205), binding(RELAY_B, 30205, 2083, "Beta")])

    def test_relay_not_selected_rejected(self):
        self.check_rejected(entry_asset_ids=[RELAY_A], relay_bindings=[binding(RELAY_B, 30205)])

    def test_builtin_relay_id_rejected(self):
        self.check_rejected(entry_asset_ids=["builtin-relay-198-51-100-20"], relay_bindings=[])

    def test_bad_port_and_host_rejected(self):
        self.check_rejected(relay_bindings=[binding(RELAY_A, 70000)])
        bad = binding(RELAY_A, 30205)
        bad["relay_host"] = "198.51.100.20; rm -rf /"
        self.check_rejected(relay_bindings=[bad])

    def test_too_many_rejected(self):
        self.check_rejected(relay_bindings=[binding(RELAY_A, 30000 + i) for i in range(33)])


class KomariRuntime(Base):
    def test_not_installed(self):
        sec = self.m.scan_security(self.asset)
        self.assertTrue(sec["komari_webssh_disabled"])
        self.assertEqual(sec["komari_runtime"], "not_installed")

    def test_override_missing(self):
        self.install_komari(running_env=[b"PATH=/usr/bin"])
        ids = {f["id"] for f in self.m.scan_security(self.asset)["findings"]}
        self.assertIn("SEC-KOMARI-WEBSSH", ids)

    def test_override_written_but_process_not_restarted(self):
        self.install_komari(running_env=[b"PATH=/usr/bin"])
        self.m.KOMARI_OVERRIDE.parent.mkdir(mode=0o755)
        self.m.atomic_write(self.m.KOMARI_OVERRIDE, b"[Service]\nEnvironment=AGENT_DISABLE_WEB_SSH=true\n", 0o644)
        sec = self.m.scan_security(self.asset)
        self.assertFalse(sec["komari_webssh_disabled"])
        self.assertTrue(sec["komari_override_written"])
        self.assertIn("SEC-KOMARI-WEBSSH-RESTART", {f["id"] for f in sec["findings"]})

    def test_running_with_variable(self):
        self.install_komari(running_env=[b"AGENT_DISABLE_WEB_SSH=true"])
        self.m.KOMARI_OVERRIDE.parent.mkdir(mode=0o755)
        self.m.atomic_write(self.m.KOMARI_OVERRIDE, b"[Service]\nEnvironment=AGENT_DISABLE_WEB_SSH=true\n", 0o644)
        sec = self.m.scan_security(self.asset)
        self.assertTrue(sec["komari_webssh_disabled"])
        self.assertEqual(sec["komari_runtime"], "running_disabled")


class SecurityFix(Base):
    def test_sshd_drift_needs_reload_so_verify_fails(self):
        self.m.atomic_write(self.m.SSHD, b"# drifted\n", 0o644)
        job = self.apply("security.fix", {"save_baseline": False})
        self.assertIn("ssh", job["result"]["pending_reload"])
        out = self.verify(job)
        self.assertFalse(out["verified"])
        self.assertIn({"name": "sshd_runtime_reloaded", "ok": False}, out["verification"]["checks"])

    def test_komari_written_but_running_old_process_fails(self):
        self.install_komari(running_env=[b"PATH=/usr/bin"])
        job = self.apply("security.fix", {"save_baseline": False})
        self.assertEqual(job["result"]["pending_reload"], ["komari-agent"])
        self.assertFalse(self.verify(job)["verified"])

    def test_no_drift_passes(self):
        self.install_komari(running_env=[b"AGENT_DISABLE_WEB_SSH=true"])
        self.m.KOMARI_OVERRIDE.parent.mkdir(mode=0o755)
        self.m.atomic_write(self.m.KOMARI_OVERRIDE, b"[Service]\nEnvironment=AGENT_DISABLE_WEB_SSH=true\n", 0o644)
        job = self.apply("security.fix", {"save_baseline": True})
        self.assertEqual(job["result"]["pending_reload"], [])
        out = self.verify(job)
        self.assertTrue(out["verified"])
        self.assertFalse(out["verification"]["deployment_verified"])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
