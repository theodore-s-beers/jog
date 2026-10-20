import json
import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("JOG_BINARY", PROJECT / "jog")).resolve()


class JogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jog-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.package = self.root / "package.json"
        self.write({"args": "printf '<%s>\\n'", "fail": "exit 42", "input": "cat"})

    def write(self, scripts):
        self.package.write_text(json.dumps({"scripts": scripts}))

    def run_jog(self, *args, cwd=None, input=""):
        return subprocess.run(
            [str(BINARY), *args],
            cwd=cwd or self.root,
            input=input,
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_listing(self):
        result = self.run_jog()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "args\nfail\ninput\n")

    def test_arguments_are_literal(self):
        args = ["a b", "", "it's", "$(touch injected)", "; echo bad", "*", "a\nb"]
        for separator in [[], ["--"]]:
            result = self.run_jog("args", *separator, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "".join(f"<{arg}>\n" for arg in args))
            self.assertFalse((self.root / "injected").exists())

    def test_exit_and_streams(self):
        self.assertEqual(self.run_jog("fail").returncode, 42)
        self.assertEqual(self.run_jog("input", input="hello\n").stdout, "hello\n")
        self.write({"err": "printf problem >&2"})
        self.assertEqual(self.run_jog("err").stderr, "problem")

    def test_directory_environment_and_bins(self):
        nested = self.root / "src"
        nested.mkdir()
        bin_dir = self.root / "node_modules" / ".bin"
        bin_dir.mkdir(parents=True)
        tool = bin_dir / "jog-test-tool"
        tool.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$PWD" "$INIT_CWD" "$npm_lifecycle_event"\n'
        )
        tool.chmod(0o755)
        self.write({"local": "jog-test-tool"})
        result = self.run_jog("local", cwd=nested)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{self.root}\n{nested}\nlocal\n")

    def test_errors(self):
        self.assertNotEqual(self.run_jog("missing").returncode, 0)
        for content in [
            "{",
            "[]",
            '{"scripts": 2}',
            '{"scripts":{"bad":2}}',
            '{"scripts":{}} trailing',
            '{"scripts":{},}',
            '{"scripts":{}} @',
            '{"scripts":{"bad":"\\u0000"}}',
        ]:
            self.package.write_text(content)
            result = self.run_jog()
            self.assertNotEqual(result.returncode, 0, content)
            self.assertIn("jog:", result.stderr)
        self.package.unlink()
        self.assertNotEqual(self.run_jog().returncode, 0)
        self.assertEqual(self.run_jog("--help").returncode, 0)

    def test_empty_scripts(self):
        self.package.write_text("{}")
        self.assertEqual(self.run_jog().stdout, "")

    def test_hooks_and_environment(self):
        command = 'printf "%s\\n" "$npm_lifecycle_event" "$npm_lifecycle_script" "$npm_package_json" "$INIT_CWD" "$JOG_TEST_INHERITED"; printf "[%s]\\n"'
        self.write({name: command for name in ["pretest", "test", "posttest"]})
        with unittest.mock.patch.dict(os.environ, {"JOG_TEST_INHERITED": "inherited"}):
            result = self.run_jog("test", "argument")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ""
        for name in ["pretest", "test", "posttest"]:
            arg = "argument" if name == "test" else ""
            expected += (
                f"{name}\n{command}\n{self.package}\n{self.root}\ninherited\n[{arg}]\n"
            )
        self.assertEqual(result.stdout, expected)

    def test_hook_failure_stops_sequence(self):
        for failing in ["pretest", "test", "posttest"]:
            names = ["pretest", "test", "posttest"]
            self.write(
                {
                    name: f"echo {name}; exit {37 if name == failing else 0}"
                    for name in names
                }
            )
            result = self.run_jog("test")
            self.assertEqual(result.returncode, 37)
            self.assertEqual(
                result.stdout.splitlines(), names[: names.index(failing) + 1]
            )

    def test_explicit_hook_does_not_recurse(self):
        self.write(
            {
                "pretest": "echo direct",
                "prepretest": "exit 99",
                "postpretest": "exit 99",
            }
        )
        self.assertEqual(self.run_jog("pretest").stdout, "direct\n")

    def test_exact_names_and_option_escape(self):
        self.write({"test": "echo exact", "--help": "echo script"})
        self.assertNotEqual(self.run_jog("t").returncode, 0)
        self.assertEqual(self.run_jog("--", "--help").stdout, "script\n")

    def test_shell_expressions_and_isolation(self):
        self.write(
            {
                "pretest": "cd /; export JOG_HOOK_LEAK=yes",
                "test": 'test -z "$JOG_HOOK_LEAK" && printf hello | tr a-z A-Z',
                "posttest": "pwd",
            }
        )
        result = self.run_jog("test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"HELLO{self.root}\n")

    def test_nearest_package_and_ancestor_bins(self):
        child = self.root / "child"
        child.mkdir()
        (child / "package.json").write_text(
            json.dumps({"scripts": {"local": "jog-test-tool"}})
        )
        for directory, output in [(self.root, "ancestor"), (child, "nearest")]:
            bins = directory / "node_modules" / ".bin"
            bins.mkdir(parents=True)
            tool = bins / "jog-test-tool"
            tool.write_text(f"#!/bin/sh\necho {output}\n")
            tool.chmod(0o755)
        self.assertEqual(self.run_jog("local", cwd=child).stdout, "nearest\n")
        (child / "node_modules" / ".bin" / "jog-test-tool").unlink()
        self.assertEqual(self.run_jog("local", cwd=child).stdout, "ancestor\n")

    def test_invocation_from_supported_shells(self):
        for shell in ["bash", "zsh", "fish"]:
            with self.subTest(shell=shell):
                self.assertIsNotNone(
                    shutil.which(shell), f"{shell} is required for validation"
                )
                result = subprocess.run(
                    [shell, "-c", '"$JOG_TEST_BINARY" args "a b"'],
                    cwd=self.root,
                    env={**os.environ, "JOG_TEST_BINARY": str(BINARY)},
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "<a b>\n")

    def test_completion_candidates(self):
        env = {
            **os.environ,
            "PATH": f"{BINARY.parent}:{os.environ['PATH']}",
            "JOG_COMPLETIONS": str(PROJECT / "completions"),
        }
        commands = {
            "bash": 'source "$JOG_COMPLETIONS/jog.bash"; COMP_WORDS=(jog ar); COMP_CWORD=1; _jog_complete; printf "%s\\n" "${COMPREPLY[@]}"',
            "fish": 'source "$JOG_COMPLETIONS/jog.fish"; complete -C "jog ar"',
            # compadd needs ZLE during real completion. Capture its candidate
            # arguments here while exercising the actual completion file.
            "zsh": 'compadd() { shift; printf "%s\\n" "$@"; }; CURRENT=2; source "$JOG_COMPLETIONS/_jog"',
        }
        for shell, command in commands.items():
            result = subprocess.run(
                [shell, "-c", command],
                cwd=self.root,
                env=env,
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout, "args\nfail\ninput\n" if shell == "zsh" else "args\n"
            )

    def test_terminal_and_ctrl_c(self):
        self.check_terminal(hooks=False)

    def test_terminal_and_ctrl_c_with_hooks(self):
        self.check_terminal(hooks=True)

    def check_terminal(self, hooks):
        # Signal only after the entire process tree is ready, not while the
        # shell is between fork and exec.
        worker = self.root / "worker.py"
        shutil.copyfile(PROJECT / "tests" / "fixtures" / "signal_worker.py", worker)
        scripts = {"terminal": "python3 worker.py"}
        if hooks:
            scripts.update({"preterminal": "true", "postterminal": "touch post-ran"})
        self.write(scripts)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.root)
            os.execv(str(BINARY), [str(BINARY), "terminal"])
        reaped = False
        try:
            self.assertTrue(select.select([fd], [], [], 5)[0], "terminal timed out")
            self.assertIn(b"ready", os.read(fd, 1024))
            os.write(fd, b"\x03")
            # A terminal interrupt must kill the job, not leave it running.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.02)[0]:
                    try:
                        os.read(fd, 65536)
                    except OSError:
                        pass  # Linux returns EIO when the slave closes.
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    reaped = True
                    self.assertIn(
                        os.waitstatus_to_exitcode(status), [-signal.SIGINT, 130]
                    )
                    break
                time.sleep(0.02)
            self.assertTrue(reaped, "Ctrl-C did not terminate the job")
            self.assertFalse((self.root / "post-ran").exists())
            for role in ["parent", "child"]:
                marker = self.root / (role + "-interrupted")
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(marker.exists(), f"{role} did not receive Ctrl-C")
        finally:
            if not reaped:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
