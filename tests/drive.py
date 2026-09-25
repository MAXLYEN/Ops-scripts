#!/usr/bin/env python3
"""在伪终端里运行交互命令，按顺序喂入输入，输出去掉控制序列后打印。

用法: drive.py [--idle 秒] [--timeout 秒] <命令> [输入行...]

每当程序安静 --idle 秒（在等输入），就送下一行；输入送完后等程序自己退出，
超过 --timeout 就杀掉并以 124 退出。退出码透传被测命令的退出码。
菜单读的是 /dev/tty，管道喂不进去，所以测试要经过这个驱动。
"""
import os
import pty
import re
import select
import signal
import sys
import time

args = sys.argv[1:]
idle, timeout = 0.4, 60.0
while args and args[0].startswith("--"):
    opt = args.pop(0)
    if opt == "--idle":
        idle = float(args.pop(0))
    elif opt == "--timeout":
        timeout = float(args.pop(0))
    else:
        sys.exit(f"未知选项: {opt}")
if not args:
    sys.exit(__doc__)
cmd, inputs = args[0], args[1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", cmd])

out = bytearray()
start = last = time.monotonic()
status = None
while True:
    now = time.monotonic()
    if now - start > timeout:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.stdout.write(out.decode("utf-8", "replace"))
        sys.stdout.write("\n[drive] 超时\n")
        sys.exit(124)
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            break
        out += data
        last = time.monotonic()
        continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        # 子进程退出后把残留输出读完
        while select.select([fd], [], [], 0.05)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            out += data
        break
    if inputs and time.monotonic() - last >= idle:
        os.write(fd, (inputs.pop(0) + "\n").encode())
        last = time.monotonic()

if status is None:
    _, status = os.waitpid(pid, 0)
text = out.decode("utf-8", "replace")
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text).replace("\r", "")
sys.stdout.write(text)
if inputs:
    sys.stdout.write(f"\n[drive] 还有 {len(inputs)} 行输入没用上: {inputs}\n")
sys.exit(os.waitstatus_to_exitcode(status))
