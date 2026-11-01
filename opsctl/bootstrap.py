#!/usr/bin/python3
# opsctl/bootstrap.py — OpsDeck 受控运维的首次安装器和受限服务端
# VERSION: 1.0.0
# 1.0.0: 建立固定 SSH 动作协议、root 管理授权、只读发现、密钥吊销与双重审计。

"""Run as root from a verified artifact; installed copies dispatch by argv[0]."""

import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import pwd
import re
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import uuid

VERSION = "1.0.0"
API_VERSION = 1
MAX_REQUEST = 65536
ETC = pathlib.Path("/etc/opsctl")
KEYS = ETC / "keys.json"
ASSET = ETC / "asset.json"
AUTH = ETC / "authorized_keys"
CODE = pathlib.Path("/usr/local/lib/opsctl/opsctl.py")
BIN = pathlib.Path("/usr/local/bin/opsctl")
SSH_BIN = pathlib.Path("/usr/local/bin/opsctl-ssh")
ADMIN_BIN = pathlib.Path("/usr/local/bin/opsctl-admin")
SUDOERS = pathlib.Path("/etc/sudoers.d/opsctl")
SSHD = pathlib.Path("/etc/ssh/sshd_config.d/90-opsctl.conf")
HOME = pathlib.Path("/var/lib/opsctl")
LOG_DIR = pathlib.Path("/var/log/opsctl")
JOURNAL = pathlib.Path("/run/systemd/journal/socket")
LOCK = ETC / "lock"
READY = ETC / "ready"
FP_RE = re.compile(r"^SHA256:[A-Za-z0-9+/]{43}$")
ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SUDO_TEXT = (
    "Defaults:opsdeck env_reset, !setenv\n"
    "opsdeck ALL=(root) NOPASSWD:NOEXEC: /usr/local/bin/opsctl --auth-key * --ssh-ok *\n"
)
SSHD_TEXT = (
    "Match User opsdeck\n"
    "    AuthorizedKeysFile /etc/opsctl/authorized_keys\n"
    "    AuthenticationMethods publickey\n"
    "    PubkeyAuthentication yes\n"
    "    PasswordAuthentication no\n"
    "    KbdInteractiveAuthentication no\n"
    "    DisableForwarding yes\n"
    "    PermitTTY no\n"
    "    PermitUserRC no\n"
    "    MaxSessions 1\n"
)


class Rejected(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def response(request_id=None, data=None, error=None):
    result = {"version": API_VERSION, "id": request_id, "ok": error is None}
    if error is None:
        result["data"] = data
    else:
        result["error"] = {"code": error.code, "message": error.message}
    return result


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Rejected("INVALID_REQUEST", "JSON 字段重复")
        result[key] = value
    return result


def reject_constant(_value):
    raise Rejected("INVALID_REQUEST", "JSON 数值无效")


def read_json_line():
    line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
    if not line or len(line) > MAX_REQUEST or sys.stdin.buffer.read(1):
        raise Rejected("INVALID_REQUEST", "请求必须是单行且不超过 64 KiB")
    try:
        return json.loads(line.decode("utf-8"), object_pairs_hook=unique_pairs,
                          parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise Rejected("INVALID_REQUEST", "JSON 格式无效") from exc


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise Rejected("INVALID_REQUEST", "字段缺失或包含未知字段")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def key_fingerprint(key_blob):
    return "SHA256:" + base64.b64encode(hashlib.sha256(key_blob).digest()).decode("ascii").rstrip("=")


def public_key(value):
    if not isinstance(value, str) or len(value) > 2048:
        raise Rejected("INVALID_KEY", "公钥格式无效")
    clean = value.strip()
    if "\n" in clean or "\r" in clean:
        raise Rejected("INVALID_KEY", "公钥格式无效")
    parts = clean.split()
    if len(parts) < 2 or parts[0] != "ssh-ed25519":
        raise Rejected("INVALID_KEY", "只接受 Ed25519 公钥")
    try:
        raw = base64.b64decode(parts[1], validate=True)
    except ValueError as exc:
        raise Rejected("INVALID_KEY", "公钥编码无效") from exc
    if len(raw) != 51 or raw[:15] != b"\x00\x00\x00\x0bssh-ed25519" or raw[15:19] != b"\x00\x00\x00\x20":
        raise Rejected("INVALID_KEY", "Ed25519 公钥内容无效")
    return parts[1], key_fingerprint(raw)


def host_fingerprints():
    found = set()
    for path in pathlib.Path("/etc/ssh").glob("ssh_host_*_key.pub"):
        try:
            parts = path.read_text(encoding="ascii").split()
            found.add(key_fingerprint(base64.b64decode(parts[1], validate=True)))
        except (OSError, IndexError, ValueError):
            continue
    return found


def check_root():
    if os.geteuid() != 0:
        raise Rejected("ROOT_REQUIRED", "需要 root 权限")


def safe_file(path, mode=None):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
        raise Rejected("UNTRUSTED_STATE", "已有文件不受 root 管理")
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        raise Rejected("UNTRUSTED_STATE", "已有文件权限不符合要求")
    return True


def safe_dir(path, mode=None):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise Rejected("UNTRUSTED_STATE", "已有目录不受 root 管理")
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        raise Rejected("UNTRUSTED_STATE", "已有目录权限不符合要求")
    return True


def read_owned(path, mode):
    if not safe_file(path, mode):
        raise Rejected("UNTRUSTED_STATE", "安装状态不完整")
    return path.read_bytes()


def atomic_write(path, content, mode):
    fd, temp = tempfile.mkstemp(prefix=".opsctl-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def make_auth(keys):
    lines = []
    for item in sorted(keys, key=lambda x: x["fingerprint"]):
        fp = item["fingerprint"]
        if not FP_RE.fullmatch(fp):
            raise Rejected("UNTRUSTED_STATE", "密钥指纹无效")
        lines.append(f'restrict,command="/usr/local/bin/opsctl-ssh {fp}" ssh-ed25519 {item["key"]} opsdeck-{item["computer_id"]}\n')
    return "".join(lines).encode("ascii")


def load_state():
    if not safe_dir(ETC, 0o755):
        raise Rejected("UNTRUSTED_STATE", "缺少安装状态")
    try:
        asset = json.loads(read_owned(ASSET, 0o600))
        keys = json.loads(read_owned(KEYS, 0o600))
    except (ValueError, UnicodeError) as exc:
        raise Rejected("UNTRUSTED_STATE", "安装状态格式无效") from exc
    if (not isinstance(asset, dict) or set(asset) != {"asset_id", "version", "artifact_sha256"}
            or not isinstance(asset["asset_id"], str) or not ID_RE.fullmatch(asset["asset_id"])
            or not isinstance(asset["artifact_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", asset["artifact_sha256"])):
        raise Rejected("UNTRUSTED_STATE", "资产记录无效")
    if asset["version"] != VERSION or not isinstance(keys, list):
        raise Rejected("UNTRUSTED_STATE", "安装版本或密钥记录无效")
    seen_fp, seen_id = set(), set()
    for item in keys:
        if not isinstance(item, dict) or set(item) != {"computer_id", "fingerprint", "key"}:
            raise Rejected("UNTRUSTED_STATE", "密钥记录无效")
        if not isinstance(item["computer_id"], str) or not ID_RE.fullmatch(item["computer_id"]):
            raise Rejected("UNTRUSTED_STATE", "电脑标识无效")
        if not isinstance(item["key"], str) or not isinstance(item["fingerprint"], str):
            raise Rejected("UNTRUSTED_STATE", "密钥记录无效")
        try:
            _key, fp = public_key("ssh-ed25519 " + item["key"])
        except Rejected as exc:
            raise Rejected("UNTRUSTED_STATE", "密钥记录无效") from exc
        if fp != item["fingerprint"] or fp in seen_fp or item["computer_id"] in seen_id:
            raise Rejected("UNTRUSTED_STATE", "密钥记录冲突")
        seen_fp.add(fp)
        seen_id.add(item["computer_id"])
    if read_owned(AUTH, 0o644) != make_auth(keys):
        raise Rejected("UNTRUSTED_STATE", "SSH 授权文件与密钥记录不一致")
    if read_owned(READY, 0o600) != (VERSION + "\n").encode("ascii"):
        raise Rejected("UNTRUSTED_STATE", "安装尚未完成")
    return asset, keys


def audit(actor, action, params, plan_id, outcome):
    now = dt.datetime.now(dt.timezone.utc)
    record = {"time": now.isoformat(timespec="seconds"), "actor": actor,
              "action": action, "params_sha256": digest(canonical(params)),
              "plan_id": plan_id, "outcome": outcome}
    payload = canonical(record)
    if not safe_dir(LOG_DIR, 0o700):
        raise Rejected("AUDIT_UNAVAILABLE", "审计目录不可用")
    target = LOG_DIR / ("audit-" + now.strftime("%Y-%m-%d") + ".jsonl")
    if target.exists():
        safe_file(target, 0o600)
    fd = os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != 0 or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Rejected("AUDIT_UNAVAILABLE", "审计文件不可用")
        os.write(fd, payload + b"\n")
        os.fsync(fd)
    finally:
        os.close(fd)
    message = b"SYSLOG_IDENTIFIER=opsctl\nPRIORITY=5\nMESSAGE=" + payload
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2)
            sock.sendto(message, str(JOURNAL))
    except OSError as exc:
        raise Rejected("AUDIT_UNAVAILABLE", "journald 审计不可用") from exc


def discover(asset):
    os_id, os_version = "unknown", "unknown"
    try:
        for line in pathlib.Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if line.startswith("ID="):
                os_id = line[3:].strip().strip('"')
            elif line.startswith("VERSION_ID="):
                os_version = line[11:].strip().strip('"')
    except OSError:
        pass
    packages = []
    wanted = {"openssh-server", "sudo", "docker.io", "nginx", "fail2ban", "ufw", "python3"}
    try:
        blocks = pathlib.Path("/var/lib/dpkg/status").read_text(encoding="utf-8").split("\n\n")
        for block in blocks:
            lines = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line and not line[0].isspace())
            if lines.get("Package") in wanted and lines.get("Status") == "install ok installed":
                packages.append({"name": lines["Package"], "version": lines.get("Version", "")})
    except OSError:
        pass
    services = []
    for name in ("ssh", "nginx", "docker", "fail2ban", "ufw"):
        installed = any((base / (name + ".service")).is_file() for base in
                        (pathlib.Path("/etc/systemd/system"), pathlib.Path("/lib/systemd/system"),
                         pathlib.Path("/usr/lib/systemd/system")))
        if installed:
            services.append({"name": name, "installed": True})
    return {"asset_id": asset["asset_id"], "hostname": socket.gethostname(),
            "os": {"id": os_id, "version": os_version}, "kernel": platform.release(),
            "architecture": platform.machine(), "services": services,
            "packages": sorted(packages, key=lambda x: x["name"]),
            "capabilities": ["host.discover", "plan", "key.revoke"]}


def plan_id(asset, action, params):
    return digest(canonical({"asset_id": asset["asset_id"], "action": action,
                             "params": params, "authorized_keys_sha256": digest(read_owned(AUTH, 0o644)),
                             "opsctl_version": VERSION}))


def serve():
    request_id, action, params, plan = None, "invalid", {}, None
    revoke_restore = None
    actor = "unknown"
    try:
        check_root()
        if len(sys.argv) != 5 or sys.argv[1] != "--auth-key" or sys.argv[3] != "--ssh-ok":
            raise Rejected("ACCESS_DENIED", "调用方式无效")
        actor = sys.argv[2]
        if not FP_RE.fullmatch(actor) or os.environ.get("SUDO_USER") != "opsdeck":
            raise Rejected("ACCESS_DENIED", "认证身份无效")
        if sys.argv[4] != "1":
            action = "ssh.command"
            raise Rejected("SSH_COMMAND_DENIED", "只允许固定 opsctl 命令")
        read_owned(LOCK, 0o600)
        with open(LOCK, "rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            asset, keys = load_state()
            if actor not in {item["fingerprint"] for item in keys}:
                raise Rejected("ACCESS_DENIED", "认证密钥已撤销")
            request = read_json_line()
            fields(request, ("version", "id", "action", "params"))
            if type(request["version"]) is not int or request["version"] != API_VERSION:
                raise Rejected("INVALID_REQUEST", "协议版本无效")
            request_id = request["id"]
            if not isinstance(request_id, str) or not ID_RE.fullmatch(request_id):
                request_id = None
                raise Rejected("INVALID_REQUEST", "请求 ID 无效")
            action, params = request["action"], request["params"]
            if not isinstance(action, str) or not isinstance(params, dict):
                raise Rejected("INVALID_REQUEST", "动作或参数无效")
            if action == "host.discover":
                fields(params, ())
                data = discover(asset)
            elif action == "plan":
                fields(params, ("action", "fingerprint"))
                if params["action"] != "key.revoke" or not isinstance(params["fingerprint"], str) or not FP_RE.fullmatch(params["fingerprint"]):
                    raise Rejected("ACTION_DENIED", "计划动作无效")
                if params["fingerprint"] not in {item["fingerprint"] for item in keys}:
                    raise Rejected("KEY_NOT_FOUND", "目标密钥不存在")
                plan = plan_id(asset, "key.revoke", {"fingerprint": params["fingerprint"]})
                data = {"action": "key.revoke", "plan_id": plan,
                        "summary": {"asset_id": asset["asset_id"], "fingerprint": params["fingerprint"]}}
            elif action == "key.revoke":
                fields(params, ("fingerprint", "plan_id"))
                target, plan = params["fingerprint"], params["plan_id"]
                if not isinstance(target, str) or not FP_RE.fullmatch(target) or not isinstance(plan, str) or not re.fullmatch(r"[0-9a-f]{64}", plan):
                    raise Rejected("INVALID_REQUEST", "吊销参数无效")
                if target not in {item["fingerprint"] for item in keys}:
                    raise Rejected("KEY_NOT_FOUND", "目标密钥不存在")
                if plan != plan_id(asset, action, {"fingerprint": target}):
                    raise Rejected("PLAN_MISMATCH", "计划已变化，请重新预览")
                new_keys = [item for item in keys if item["fingerprint"] != target]
                audit(actor, action, params, plan, "started")
                old_keys, old_auth = read_owned(KEYS, 0o600), read_owned(AUTH, 0o644)
                try:
                    atomic_write(KEYS, canonical(new_keys) + b"\n", 0o600)
                    atomic_write(AUTH, make_auth(new_keys), 0o644)
                except OSError:
                    atomic_write(KEYS, old_keys, 0o600)
                    atomic_write(AUTH, old_auth, 0o644)
                    raise
                revoke_restore = (old_keys, old_auth)
                data = {"revoked_fingerprint": target, "remaining_keys": len(new_keys)}
            else:
                raise Rejected("ACTION_DENIED", "动作未获允许")
            try:
                audit(actor, action, params, plan, "ok")
            except (Rejected, OSError):
                if revoke_restore is not None:
                    atomic_write(KEYS, revoke_restore[0], 0o600)
                    atomic_write(AUTH, revoke_restore[1], 0o644)
                raise
            emit(response(request_id, data=data))
            return 0
    except Rejected as exc:
        try:
            audit(actor, action, params, plan, "denied:" + exc.code)
        except Rejected:
            pass
        emit(response(request_id, error=exc))
        return 1
    except (OSError, ValueError, TypeError, KeyError) as exc:
        try:
            audit(actor, action, params, plan, "failed")
        except Rejected:
            pass
        emit(response(request_id, error=Rejected("INTERNAL_ERROR", "服务端处理失败")))
        return 1


def ssh_entry():
    if len(sys.argv) != 2 or not FP_RE.fullmatch(sys.argv[1]):
        return 1
    allowed = "1" if os.environ.get("SSH_ORIGINAL_COMMAND") == "opsctl" else "0"
    completed = subprocess.run(["/usr/bin/sudo", "-n", str(BIN), "--auth-key", sys.argv[1],
                                "--ssh-ok", allowed], check=False)
    return completed.returncode


def admin():
    try:
        check_root()
        if len(sys.argv) == 3 and sys.argv[1:] == ["keys", "list"]:
            asset, keys = load_state()
            audit("root.local", "keys.list", {}, None, "ok")
            emit({"version": API_VERSION, "ok": True,
                  "data": {"asset_id": asset["asset_id"], "keys": [
                      {"computer_id": item["computer_id"], "fingerprint": item["fingerprint"]}
                      for item in keys]}})
            return 0
        if len(sys.argv) != 4 or sys.argv[1:3] != ["key", "revoke"] or not FP_RE.fullmatch(sys.argv[3]):
            raise Rejected("INVALID_REQUEST", "用法：opsctl-admin keys list | key revoke SHA256:...")
        target = sys.argv[3]
        read_owned(LOCK, 0o600)
        with open(LOCK, "rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            asset, keys = load_state()
            if target not in {item["fingerprint"] for item in keys}:
                raise Rejected("KEY_NOT_FOUND", "目标密钥不存在")
            params = {"fingerprint": target}
            plan = plan_id(asset, "key.revoke", params)
            audit("root.local", "key.revoke", params, plan, "started")
            old_keys, old_auth = read_owned(KEYS, 0o600), read_owned(AUTH, 0o644)
            try:
                new_keys = [item for item in keys if item["fingerprint"] != target]
                atomic_write(KEYS, canonical(new_keys) + b"\n", 0o600)
                atomic_write(AUTH, make_auth(new_keys), 0o644)
                audit("root.local", "key.revoke", params, plan, "ok")
            except (OSError, Rejected):
                atomic_write(KEYS, old_keys, 0o600)
                atomic_write(AUTH, old_auth, 0o644)
                raise
            emit({"version": API_VERSION, "ok": True,
                  "data": {"revoked_fingerprint": target, "remaining_keys": len(new_keys)}})
            return 0
    except Rejected as exc:
        try:
            audit("root.local", "admin", {}, None, "denied:" + exc.code)
        except Rejected:
            pass
        emit({"version": API_VERSION, "ok": False,
              "error": {"code": exc.code, "message": exc.message}})
        return 1
    except (OSError, ValueError, TypeError):
        emit({"version": API_VERSION, "ok": False,
              "error": {"code": "INTERNAL_ERROR", "message": "管理员操作失败"}})
        return 1


def install():
    check_root()
    request = read_json_line()
    fields(request, ("version", "computer_id", "public_key", "expected_host_fingerprint"))
    if type(request["version"]) is not int or request["version"] != API_VERSION:
        raise Rejected("INVALID_REQUEST", "安装协议版本无效")
    computer_id = request["computer_id"]
    if not isinstance(computer_id, str) or not ID_RE.fullmatch(computer_id):
        raise Rejected("INVALID_REQUEST", "电脑标识无效")
    encoded, fingerprint = public_key(request["public_key"])
    expected = request["expected_host_fingerprint"]
    if not isinstance(expected, str) or not FP_RE.fullmatch(expected) or expected not in host_fingerprints():
        raise Rejected("HOST_MISMATCH", "服务器主机指纹不匹配")
    source = pathlib.Path(__file__)
    if not safe_file(source):
        raise Rejected("UNTRUSTED_ARTIFACT", "安装文件不受 root 管理")
    source_bytes = source.read_bytes()
    source_hash = digest(source_bytes)
    return install_checked(computer_id, encoded, fingerprint, expected, source_bytes, source_hash)


def install_checked(computer_id, encoded, fingerprint, host_fp, source_bytes, source_hash):
    targets = (ETC, CODE.parent, LOG_DIR, HOME, ASSET, KEYS, AUTH, LOCK, READY, CODE,
               BIN, SSH_BIN, ADMIN_BIN, SUDOERS, SSHD)
    marker_exists = ASSET.exists()
    if marker_exists:
        asset, keys = load_state()
        if asset["artifact_sha256"] != source_hash or read_owned(CODE, 0o755) != source_bytes:
            raise Rejected("VERSION_MISMATCH", "已安装版本不同，不能隐式替换")
        for path in (SUDOERS, SSHD):
            expected = SUDO_TEXT if path == SUDOERS else SSHD_TEXT
            if read_owned(path, 0o440 if path == SUDOERS else 0o644) != expected.encode():
                raise Rejected("UNTRUSTED_STATE", "已有权限配置不匹配")
        for link in (BIN, SSH_BIN, ADMIN_BIN):
            if not link.is_symlink() or link.resolve() != CODE or link.lstat().st_uid != 0:
                raise Rejected("UNTRUSTED_STATE", "已有入口不匹配")
        if not safe_dir(HOME, 0o755) or not safe_dir(LOG_DIR, 0o700):
            raise Rejected("UNTRUSTED_STATE", "已有目录不匹配")
        read_owned(LOCK, 0o600)
        try:
            user = pwd.getpwnam("opsdeck")
        except KeyError as exc:
            raise Rejected("UNTRUSTED_STATE", "受限账号不存在") from exc
        if user.pw_dir != str(HOME) or user.pw_shell != "/bin/sh":
            raise Rejected("UNTRUSTED_STATE", "已有账号不匹配")
    else:
        for path in targets:
            if path.exists() or path.is_symlink():
                raise Rejected("UNTRUSTED_STATE", "发现不受信的同名账号或文件")
        try:
            pwd.getpwnam("opsdeck")
            raise Rejected("UNTRUSTED_STATE", "发现已有 opsdeck 账号")
        except KeyError:
            pass
        asset = {"asset_id": str(uuid.uuid4()), "version": VERSION,
                 "artifact_sha256": source_hash}
        keys = []
    for item in keys:
        if item["computer_id"] == computer_id and (item["fingerprint"] != fingerprint or item["key"] != encoded):
            raise Rejected("KEY_CONFLICT", "电脑标识已绑定其他密钥")
        if item["fingerprint"] == fingerprint and item["computer_id"] != computer_id:
            raise Rejected("KEY_CONFLICT", "公钥已绑定其他电脑")
    new_key = not any(item["computer_id"] == computer_id for item in keys)
    if new_key:
        keys.append({"computer_id": computer_id, "fingerprint": fingerprint, "key": encoded})
    if marker_exists and not new_key:
        return {"asset_id": asset["asset_id"], "opsctl_version": VERSION,
                "artifact_sha256": source_hash, "authorized_key_fingerprint": fingerprint,
                "host_fingerprint": host_fp}
    created_files, created_dirs, created_user = [], [], False
    old_keys = read_owned(KEYS, 0o600) if marker_exists else None
    old_auth = read_owned(AUTH, 0o644) if marker_exists else None
    try:
        if not marker_exists:
            for path, mode in ((ETC, 0o755), (CODE.parent, 0o755),
                               (LOG_DIR, 0o700), (HOME, 0o755)):
                path.mkdir(mode=mode)
                created_dirs.append(path)
            atomic_write(CODE, source_bytes, 0o755); created_files.append(CODE)
            for link in (BIN, SSH_BIN, ADMIN_BIN):
                link.symlink_to(CODE)
                created_files.append(link)
            atomic_write(ASSET, canonical(asset) + b"\n", 0o600); created_files.append(ASSET)
            atomic_write(LOCK, b"", 0o600); created_files.append(LOCK)
            atomic_write(SUDOERS, SUDO_TEXT.encode(), 0o440); created_files.append(SUDOERS)
            atomic_write(SSHD, SSHD_TEXT.encode(), 0o644); created_files.append(SSHD)
            subprocess.run(["/usr/sbin/useradd", "--system", "--home-dir", str(HOME),
                            "--shell", "/bin/sh", "--no-create-home", "opsdeck"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            created_user = True
            # A locked shadow entry also blocks public-key login on some sshd builds.
            # Use an unguessable synthetic hash; Match disables password auth as well.
            alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            salt = "".join(secrets.choice(alphabet) for _ in range(16))
            random_digest = "".join(secrets.choice(alphabet) for _ in range(86))
            shadow_hash = "$6$" + salt + "$" + random_digest
            subprocess.run(["/usr/sbin/chpasswd", "--encrypted"], input="opsdeck:" + shadow_hash + "\n",
                           text=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atomic_write(KEYS, canonical(keys) + b"\n", 0o600)
        if not marker_exists: created_files.append(KEYS)
        atomic_write(AUTH, make_auth(keys), 0o644)
        if not marker_exists: created_files.append(AUTH)
        subprocess.run(["/usr/sbin/visudo", "-cf", str(SUDOERS)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/sbin/sshd", "-t"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        effective = subprocess.check_output(["/usr/sbin/sshd", "-T", "-C",
                                             "user=opsdeck,host=localhost,addr=127.0.0.1"],
                                            text=True, stderr=subprocess.DEVNULL)
        settings = dict(line.split(" ", 1) for line in effective.splitlines() if " " in line)
        required = {"authorizedkeysfile": str(AUTH), "authenticationmethods": "publickey",
                    "passwordauthentication": "no", "kbdinteractiveauthentication": "no",
                    "disableforwarding": "yes", "permittty": "no", "permituserrc": "no",
                    "permituserenvironment": "no"}
        if any(settings.get(k) != v for k, v in required.items()):
            raise Rejected("SSHD_CONFIG", "sshd 对受限账号的有效配置不符合要求")
        # A running systemd sshd must re-read the validated Match block.
        if not marker_exists and pathlib.Path("/run/systemd/system").exists():
            subprocess.run(["/usr/bin/systemctl", "reload", "ssh"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not marker_exists:
            atomic_write(READY, (VERSION + "\n").encode("ascii"), 0o600)
            created_files.append(READY)
        return {"asset_id": asset["asset_id"], "opsctl_version": VERSION,
                "artifact_sha256": source_hash, "authorized_key_fingerprint": fingerprint,
                "host_fingerprint": host_fp}
    except (OSError, subprocess.CalledProcessError, Rejected):
        if marker_exists:
            if old_keys is not None: atomic_write(KEYS, old_keys, 0o600)
            if old_auth is not None: atomic_write(AUTH, old_auth, 0o644)
        else:
            if created_user:
                subprocess.run(["/usr/sbin/userdel", "opsdeck"], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for path in reversed(created_files):
                path.unlink(missing_ok=True)
            for path in reversed(created_dirs):
                path.rmdir()
            if pathlib.Path("/run/systemd/system").exists():
                subprocess.run(["/usr/bin/systemctl", "reload", "ssh"], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise


def main():
    entry = pathlib.Path(sys.argv[0]).name
    if entry == "opsctl-ssh":
        return ssh_entry()
    if entry == "opsctl":
        return serve()
    if entry == "opsctl-admin":
        return admin()
    try:
        data = install()
        emit({"version": API_VERSION, "ok": True, "data": data})
        return 0
    except Rejected as exc:
        emit({"version": API_VERSION, "ok": False,
              "error": {"code": exc.code, "message": exc.message}})
        return 1
    except (OSError, subprocess.CalledProcessError, ValueError, TypeError) as exc:
        emit({"version": API_VERSION, "ok": False,
              "error": {"code": "INSTALL_FAILED", "message": "安装失败，已回滚本轮更改"}})
        return 1


if __name__ == "__main__":
    sys.exit(main())
