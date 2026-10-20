import os
import signal
import subprocess
import sys
import time
from pathlib import Path

role = "child" if len(sys.argv) > 1 else "parent"
child = None


def interrupted(sig, frame):
    Path(role + "-interrupted").touch()
    if child is not None:
        child.wait(timeout=2)
    # The supervisor must still stop hooks when a directly forwarded signal
    # is caught by a script that reports success.
    sys.exit(0 if os.environ.get("JOG_SIGNAL_EXIT_ZERO") else 128 + sig)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
    signal.signal(sig, interrupted)
Path(role + ".pid").write_text(str(os.getpid()))
if role == "parent":
    if os.environ.get("JOG_EXPECT_TTY"):
        assert os.isatty(0) and os.isatty(1)
    child = subprocess.Popen(
        [sys.executable, __file__, "child"], stdout=subprocess.PIPE
    )
    assert child.stdout is not None
    assert child.stdout.readline() == b"ready\n"
print("ready", flush=True)
while True:
    time.sleep(1)
