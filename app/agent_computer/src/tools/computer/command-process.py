"""Own one foreground command group through exit and cleanup."""

import os
import signal
import subprocess
import sys
import time


def main():
    cancelled = False

    def cancel(_signal, _frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    timeout_ms = float(sys.argv[1])
    if cancelled:
        return 130
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    deadline = time.monotonic() + timeout_ms / 1000 if timeout_ms > 0 else None
    kill_at = None
    outcome = None
    try:
        while True:
            if cancelled:
                outcome = 130
                break
            # Do not reap here: the child PID pins the process-group identity
            # until cleanup, including when descendants close their output.
            exited = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if exited is not None:
                if kill_at is not None:
                    outcome = 124
                break
            now = time.monotonic()
            if kill_at is not None and now >= kill_at:
                outcome = 137
                break
            if deadline is not None and now >= deadline:
                os.killpg(process.pid, signal.SIGTERM)
                deadline = None
                kill_at = now + 5
            time.sleep(0.01)
    finally:
        # The direct child is still unreaped, so this group cannot be reused.
        # Persistent processes belong to their own runtime, not this command.
        exited = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin returns EPERM for a group with only its zombie leader.
            # Linux and live-leader permission failures remain errors.
            if sys.platform != "darwin" or exited is None:
                raise
        finally:
            status = process.wait()
    return outcome if outcome is not None else status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
