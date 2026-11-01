#!/usr/bin/python3
"""Disposable SSH server for Windows-to-WSL OpsDeck bootstrap testing only."""

import pathlib
import runpy
import secrets
import subprocess
import time

CONFIG = pathlib.Path("/etc/ssh/sshd_config")
DROPIN = pathlib.Path("/etc/ssh/sshd_config.d/90-opsctl.conf")
READY = pathlib.Path("/etc/opsctl/ready")
JUMP_MATCH = (
    "Match User opsdeck-jump\n"
    "    AuthorizedKeysFile /etc/opsctl-jump/authorized_keys\n"
    "    AuthenticationMethods publickey\n"
    "    PasswordAuthentication no\n"
    "    KbdInteractiveAuthentication no\n"
    "    AllowTcpForwarding local\n"
    "    PermitOpen 127.0.0.1:22\n"
    "    PermitTTY no\n"
    "    X11Forwarding no\n"
    "    AllowAgentForwarding no\n"
    "    PermitUserRC no\n"
    "    ForceCommand /bin/false\n"
)


def configure_jump():
    auth = pathlib.Path("/etc/opsctl/authorized_keys")
    lines = [line for line in auth.read_text(encoding="ascii").splitlines() if line.strip()]
    if not lines or any(" ssh-ed25519 " not in line for line in lines):
        raise RuntimeError("opsctl 授权文件不可用于跳板联调")
    keys = [line.split(" ssh-ed25519 ", 1)[1].split()[0] for line in lines]
    root = pathlib.Path("/etc/opsctl-jump")
    root.mkdir(mode=0o755)
    jump_auth = root / "authorized_keys"
    jump_auth.write_text("".join(
        'restrict,port-forwarding,permitopen="127.0.0.1:22",command="/bin/false" '
        + "ssh-ed25519 " + key + " opsctl-test-jump\n" for key in keys
    ), encoding="ascii")
    jump_auth.chmod(0o644)
    subprocess.run(["useradd", "--system", "--home-dir", "/var/lib/opsctl-jump",
                    "--shell", "/bin/false", "--no-create-home", "opsdeck-jump"], check=True)
    salt = secrets.token_hex(8)
    random_hash = secrets.token_hex(43)
    subprocess.run(["chpasswd", "--encrypted"], input=f"opsdeck-jump:$6${salt}${random_hash}\n",
                   text=True, check=True)
    subprocess.run(["/usr/sbin/sshd", "-t"], check=True)


def main():
    pathlib.Path("/run/sshd").mkdir(exist_ok=True)
    subprocess.run(["ssh-keygen", "-A"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["chpasswd"], input="root:opsctl-test-only\n", text=True, check=True)
    restricted = runpy.run_path("/src/opsctl/bootstrap.py")["SSHD_TEXT"]
    CONFIG.write_text(
        "Include /etc/ssh/sshd_config.d/*.conf\n"
        "Port 22\nListenAddress 0.0.0.0\n"
        "HostKey /etc/ssh/ssh_host_ed25519_key\n"
        "PermitRootLogin yes\nPasswordAuthentication yes\n"
        "KbdInteractiveAuthentication no\nUsePAM no\n"
        "Subsystem sftp internal-sftp\n" + restricted + JUMP_MATCH,
        encoding="ascii",
    )
    journal = subprocess.Popen(["/usr/bin/python3", "/src/tests/opsctl-journal.py"])
    sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e"])
    fingerprint = subprocess.check_output(
        ["ssh-keygen", "-lf", "/etc/ssh/ssh_host_ed25519_key.pub", "-E", "sha256"], text=True
    ).split()[1]
    print("仅供一次性测试：root 密码 opsctl-test-only", flush=True)
    print("SSH 主机指纹：" + fingerprint, flush=True)
    print("Windows 连接：127.0.0.1:22222", flush=True)
    configured = False
    try:
        while True:
            if sshd.poll() is not None:
                sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e"])
                print("测试 sshd 主进程已重新启动", flush=True)
            if not configured and READY.exists() and DROPIN.exists():
                configure_jump()
                configured = True
                print("测试跳板账号 opsdeck-jump 已就绪，仅可转发到 127.0.0.1:22", flush=True)
            time.sleep(0.2)
    finally:
        if sshd.poll() is None:
            sshd.terminate()
            sshd.wait(timeout=5)
        journal.terminate()
        journal.wait(timeout=5)


if __name__ == "__main__":
    main()
