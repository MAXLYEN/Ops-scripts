#!/usr/bin/env python3
"""Container-only journald datagram sink for opsctl integration tests."""

import os
import socket

path = "/run/systemd/journal/socket"
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    os.unlink(path)
except FileNotFoundError:
    pass
with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
    sock.bind(path)
    while True:
        message = sock.recv(65536)
        with open("/tmp/opsctl-journal.log", "ab") as stream:
            stream.write(message + b"\n")
