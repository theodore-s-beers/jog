import os
import signal
import subprocess
import sys
import time
from pathlib import Path

role = "child" if len(sys.argv) > 1 else "parent"


def interrupted(sig, frame):
    Path(role + "-interrupted").touch()
    sys.exit(130)


signal.signal(signal.SIGINT, interrupted)
if role == "parent":
    assert os.isatty(0) and os.isatty(1)
    child = subprocess.Popen(
        [sys.executable, __file__, "child"], stdout=subprocess.PIPE
    )
    assert child.stdout is not None
    assert child.stdout.readline() == b"ready\n"
print("ready", flush=True)
while True:
    time.sleep(1)
