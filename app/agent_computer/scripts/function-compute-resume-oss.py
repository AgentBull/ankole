"""Reconnect OSSFS2 after Function Compute restores a memory snapshot."""

import ctypes
import errno
import os
from pathlib import Path
import socket


def reconnect(pid):
    process = Path('/proc') / str(pid)
    tcp_inodes = set()
    for name in ('tcp', 'tcp6'):
        table = process / 'net' / name
        if name == 'tcp6' and not table.exists():
            continue
        for row in table.read_text().splitlines()[1:]:
            fields = row.split()
            if fields[3] != '0A':  # Leave listening sockets open.
                tcp_inodes.add(int(fields[9]))

    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = os.pidfd_open(pid)
    try:
        for path in (process / 'fd').iterdir():
            try:
                link = os.readlink(path)
                if not link.startswith('socket:['):
                    continue
                inode = int(link[8:-1])
                if inode not in tcp_inodes:
                    continue
                # pidfd_getfd is syscall 438 on Function Compute's amd64 Linux.
                duplicate = libc.syscall(438, pidfd, int(path.name), 0)
                if duplicate < 0:
                    raise OSError(ctypes.get_errno(), 'pidfd_getfd')
                # The daemon can close or replace an fd during this scan.
                if os.fstat(duplicate).st_ino != inode:
                    os.close(duplicate)
                    continue
                with socket.socket(fileno=duplicate) as connection:
                    connection.shutdown(socket.SHUT_RDWR)
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.EBADF, errno.ENOTCONN):
                    raise
    finally:
        os.close(pidfd)


def main():
    found = False
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if (process / 'comm').read_text().strip() != 'ossfs2':
                continue
            if b'/workspace' not in (process / 'cmdline').read_bytes().split(b'\0'):
                continue
        except FileNotFoundError:
            continue
        reconnect(int(process.name))
        found = True
    if not found:
        raise RuntimeError('OSSFS2 Home mount is not running')


if __name__ == '__main__':
    main()
