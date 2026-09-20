import importlib.machinery
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RELAY = ROOT / "bin" / "bounded-relay"

# Drives the parent-death race against the real production spawn path of
# either helper: patches the module's os.getppid with a barrier (the
# _prepare_child signature stays untouched) and its subprocess.Popen only to
# pass the barrier's pipes through, then SIGKILLs the helper mid-barrier.
PARENT_DEATH_CONTROLLER = r"""
import ctypes
import os
import selectors
import signal
import subprocess
import sys

# The controller owns and reaps every process in this test; the child only
# writes an observation to a private pipe and exits.
libc = ctypes.CDLL('/usr/lib/libc.so.6', use_errno=True)
if libc.prctl(36, 1) != 0:  # PR_SET_CHILD_SUBREAPER
    raise OSError(ctypes.get_errno(), 'subreaper setup failed')
ready_r, ready_w = os.pipe()
go_r, go_w = os.pipe()
helper_code = r'''
import importlib.machinery, os, sys
module = importlib.machinery.SourceFileLoader('guard_probe', sys.argv[1]).load_module()
ready, go = int(sys.argv[2]), int(sys.argv[3])
getppid, popen = module.os.getppid, module.subprocess.Popen
observed = False
def delayed_parent_read():
    global observed
    if not observed:
        observed = True
        os.write(ready, ('FORKED %d\n' % os.getpid()).encode())
        os.read(go, 1)
    return getppid()
def spawn(*args, **kwargs):
    kwargs['pass_fds'] = (ready, go)
    return popen(*args, **kwargs)
module.os.getppid = delayed_parent_read
module.subprocess.Popen = spawn
command = [sys.executable, '-c',
    'import os,sys; os.write(int(sys.argv[1]), b"EXECUTED_AFTER_PARENT_DEATH\\n")', str(ready)]
if hasattr(module, 'command_output'):
    module.command_output(command, timeout=3)
else:
    sys.argv = ['bounded-relay', '--max-bytes', '1024', '--deadline', '3', '--'] + command
    module.main()
'''
target = sys.argv[1]
proc = subprocess.Popen([sys.executable, '-c', helper_code,
    target, str(ready_w), str(go_r)],
    pass_fds=(ready_w, go_r), start_new_session=True,
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
os.close(ready_w)
os.close(go_r)
selector = selectors.DefaultSelector()
selector.register(ready_r, selectors.EVENT_READ)
child = None
try:
    if not selector.select(5):
        raise RuntimeError('no pre-exec readiness message')
    first = os.read(ready_r, 4096)
    print(first.decode().strip())
    child = int(first.split()[1])
    proc.kill()
    proc.wait(timeout=5)
    os.write(go_w, b'x')
    if not selector.select(5):
        raise RuntimeError('no post-parent-death result')
    result = os.read(ready_r, 4096)
    print('OBSERVATION:', result.decode().strip() or 'child exited without executing')
    os.waitpid(child, 0)
    child = None
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait(timeout=5)
    if child is not None:
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(child, 0)
    selector.close()
    os.close(ready_r)
    os.close(go_w)
"""


def load_relay():
    loader = importlib.machinery.SourceFileLoader("bounded_relay", str(RELAY))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def wait_gone(check, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            check()
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


class CapturedStdout:
    """Stand-in for sys.stdout capturing text and buffer writes together."""

    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, text):
        self.buffer.write(text.encode("utf-8"))

    def flush(self):
        pass


def flood_command(total_bytes: int, delimited: bool) -> list[str]:
    marker = "b'\\n'" if delimited else "b''"
    script = (
        "import sys\n"
        f"chunk = b'x' * 65536 + {marker}\n"
        f"sent = 0\n"
        f"while sent < {total_bytes}:\n"
        "    sys.stdout.buffer.write(chunk)\n"
        "    sys.stdout.buffer.flush()\n"
        "    sent += len(chunk)\n"
    )
    return [sys.executable, "-c", script]


class BoundedRelayTests(unittest.TestCase):
    def run_relay(self, *arguments, timeout=20):
        return subprocess.run(
            [str(RELAY), *arguments],
            capture_output=True,
            timeout=timeout,
        )

    def test_absolute_interpreter_and_no_path_lookup(self):
        source = RELAY.read_text(encoding="utf-8")
        self.assertTrue(source.startswith("#!/usr/bin/python3"))
        self.assertNotIn("/usr/bin/env", source)
        self.assertNotIn("shell=True", source)

    def test_untrusted_libc_is_refused(self):
        # The relay degrades rather than loading a library anyone but root can
        # replace, so a planted file has to be rejected before the CDLL call.
        import importlib.machinery
        import importlib.util
        import tempfile

        loader = importlib.machinery.SourceFileLoader("relay", str(RELAY))
        module = importlib.util.module_from_spec(
            importlib.util.spec_from_loader("relay", loader)
        )
        loader.exec_module(module)
        self.assertEqual(
            module._trusted_library(module.LIBC_PATH), module.LIBC_PATH
        )
        with tempfile.TemporaryDirectory() as directory:
            planted = Path(directory) / "libc.so.6"
            planted.write_bytes(b"")
            planted.chmod(0o777)
            with self.assertRaises(OSError):
                module._trusted_library(str(planted))
            with self.assertRaises(OSError):
                module._trusted_library(str(Path(directory) / "missing"))

    def test_relative_and_untrusted_child_commands_are_refused(self):
        relative = self.run_relay(
            "--max-bytes", "1024", "--deadline", "5",
            "--", "python3", "-c", "print('must not run')",
        )
        self.assertEqual(relative.returncode, 2)
        self.assertIn("not an absolute command", json.loads(relative.stdout)["error"])

        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            planted = Path(directory) / "planted-command"
            planted.write_text("#!/usr/bin/bash\nprintf 'must not run\\n'\n", encoding="utf-8")
            planted.chmod(0o755)
            result = self.run_relay(
                "--max-bytes", "1024", "--deadline", "5", "--", str(planted),
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not owned by root", json.loads(result.stdout)["error"])

    def test_output_within_budget_passes_through_unchanged(self):
        payload = "hello\nworld\n"
        result = self.run_relay(
            "--max-bytes", "1048576", "--deadline", "5",
            "--", sys.executable, "-c", f"import sys; sys.stdout.write({payload!r})",
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode(), payload)

    def test_undelimited_flood_is_capped(self):
        # The case QML cannot bound on its own: a child that never emits the
        # split marker. The relay must still stop it well short of the flood.
        limit = 65536
        result = self.run_relay(
            "--max-bytes", str(limit), "--deadline", "15",
            "--", *flood_command(32 * 1024 * 1024, delimited=False),
        )
        self.assertEqual(result.returncode, 1)
        self.assertLessEqual(len(result.stdout), limit + 4096)
        # The error record is appended after whatever was forwarded, which in
        # this case carries no delimiter of its own.
        error = json.loads(result.stdout[result.stdout.rindex(b"{"):])
        self.assertEqual(error["type"], "error")
        self.assertIn("byte budget", error["error"])

    def test_delimited_flood_is_capped(self):
        limit = 65536
        result = self.run_relay(
            "--max-bytes", str(limit), "--deadline", "15",
            "--", *flood_command(32 * 1024 * 1024, delimited=True),
        )
        self.assertEqual(result.returncode, 1)
        self.assertLessEqual(len(result.stdout), limit + 4096)

    def test_deadline_is_enforced(self):
        started = time.monotonic()
        result = self.run_relay(
            "--max-bytes", "1048576", "--deadline", "1",
            "--", "/usr/bin/sleep", "10",
        )
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("deadline", json.loads(result.stdout)["error"])

    def test_child_is_killed_when_the_relay_is_killed(self):
        # SIGKILL leaves the relay no chance to clean up, so the kernel death
        # signal has to take the child down.
        relay = subprocess.Popen(
            [str(RELAY), "--max-bytes", "1048576", "--deadline", "30",
             "--", sys.executable, "-c",
             "import os, sys, time; sys.stdout.write(str(os.getpid()) + '\\n'); "
             "sys.stdout.flush(); time.sleep(30)"],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            child_pid = int(relay.stdout.readline().strip())
            relay.kill()
            relay.wait(timeout=5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                os.kill(child_pid, signal.SIGKILL)
                self.fail("child survived the relay")
        finally:
            if relay.poll() is None:
                relay.kill()
                relay.wait()
            relay.stdout.close()

    def test_invalid_budget_and_missing_command_are_refused(self):
        for arguments in (
            ("--max-bytes", "0", "--deadline", "5", "--", "/usr/bin/true"),
            ("--max-bytes", "1024", "--deadline", "0", "--", "/usr/bin/true"),
            ("--max-bytes", "1024", "--deadline", "5", "--"),
        ):
            result = self.run_relay(*arguments)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)["type"], "error")

    def test_child_exit_code_is_propagated(self):
        result = self.run_relay(
            "--max-bytes", "1024", "--deadline", "5",
            "--", sys.executable, "-c", "raise SystemExit(7)",
        )
        self.assertEqual(result.returncode, 7)

    def test_normal_exit_reaps_the_whole_group(self):
        # A leader that exits 0 with its own stdout closed must not leave a
        # sleeping descendant behind: the relay's job is the whole tree.
        child_code = (
            "import os, time\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    os.close(1); os.close(2)\n"
            "    time.sleep(30)\n"
            "    os._exit(0)\n"
            "os.write(1, (str(pid) + '\\n').encode())\n"
            "os._exit(0)\n"
        )
        result = self.run_relay(
            "--max-bytes", "1024", "--deadline", "5",
            "--", sys.executable, "-c", child_code,
        )
        self.assertEqual(result.returncode, 0)
        grandchild_pid = int(result.stdout.strip())
        if not wait_gone(lambda: os.kill(grandchild_pid, 0)):
            try:
                os.kill(grandchild_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.fail("descendant survived the leader's clean exit")

    def test_parent_death_before_first_parent_read_blocks_exec(self):
        # The R8 fork race, driven deterministically: a subreaper controller
        # holds the child's first parent read behind a barrier, SIGKILLs the
        # relay, and only then releases the read. The child must compare
        # against the relay identity captured before the fork and exit before
        # exec instead of running the command. The controller reaps every
        # process it owns, on failure too.
        result = subprocess.run(
            [sys.executable, "-c", PARENT_DEATH_CONTROLLER, str(RELAY)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FORKED", result.stdout)
        self.assertNotIn("EXECUTED_AFTER_PARENT_DEATH", result.stdout)
        self.assertIn("child exited without executing", result.stdout)


class BoundedRelayFaultTests(unittest.TestCase):
    """In-process fault injection against the real spawn/cleanup paths."""

    def recording_popen(self, spawned):
        real_popen = subprocess.Popen

        def wrapper(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            spawned.append(process)
            return process

        return wrapper

    def assert_group_dead(self, process):
        self.assertIsNotNone(process.poll())
        if not wait_gone(lambda: os.killpg(process.pid, 0)):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.fail("process group survived the relay")

    def run_main(self, module, argv, stdout=None):
        """Run main() in-process with I/O captured.

        Signal handlers and the stdin redirect belong to the real process;
        the test runner's are not the relay's to take.
        """
        captured = stdout if stdout is not None else CapturedStdout()
        patches = [
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(sys, "stdout", captured),
            mock.patch.object(module.signal, "signal"),
            mock.patch.object(module.os, "dup2",
                              side_effect=OSError("stdin redirect skipped in-process")),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        return module.main(), captured

    def test_pdeathsig_setup_failure_refuses_to_exec(self):
        # Losing the death signal fails the spawn: the start failure is
        # reported and the command never runs.
        module = load_relay()
        real_library = module._trusted_library

        def deny_libc(path):
            if path == module.LIBC_PATH:
                raise OSError("untrusted libc")
            return real_library(path)

        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "executed"
            with mock.patch.object(module, "_trusted_library", side_effect=deny_libc):
                code, captured = self.run_main(module, [
                    "bounded-relay", "--max-bytes", "1024", "--deadline", "5", "--",
                    sys.executable, "-c",
                    f"import pathlib; pathlib.Path({str(sentinel)!r}).touch()",
                ])
            self.assertEqual(code, 2)
            self.assertIn("could not start",
                          json.loads(captured.buffer.getvalue())["error"])
            self.assertFalse(sentinel.exists())
        self.assertIsNone(module._CHILD)

    def test_a_failed_prctl_refuses_to_exec(self):
        module = load_relay()
        fake_libc = mock.Mock()
        fake_libc.prctl.return_value = -1
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "executed"
            with mock.patch.object(module.ctypes, "CDLL", return_value=fake_libc), \
                    mock.patch.object(module.ctypes, "get_errno", return_value=13):
                code, captured = self.run_main(module, [
                    "bounded-relay", "--max-bytes", "1024", "--deadline", "5", "--",
                    sys.executable, "-c",
                    f"import pathlib; pathlib.Path({str(sentinel)!r}).touch()",
                ])
            self.assertEqual(code, 2)
            self.assertIn("could not start",
                          json.loads(captured.buffer.getvalue())["error"])
            self.assertFalse(sentinel.exists())
        self.assertIsNone(module._CHILD)

    def test_a_selector_setup_failure_kills_the_group(self):
        module = load_relay()
        spawned = []
        with mock.patch.object(module.subprocess, "Popen",
                               side_effect=self.recording_popen(spawned)), \
                mock.patch.object(module.selectors, "DefaultSelector",
                                  side_effect=OSError("injected selector failure")):
            code, captured = self.run_main(module, [
                "bounded-relay", "--max-bytes", "1024", "--deadline", "30", "--",
                sys.executable, "-c", "import time; time.sleep(30)",
            ])
        self.assertEqual(code, 1)
        self.assertIn("stream failed", json.loads(captured.buffer.getvalue())["error"])
        self.assertEqual(len(spawned), 1)
        self.assert_group_dead(spawned[0])
        self.assertIsNone(module._CHILD)

    def test_a_read_failure_kills_the_whole_group(self):
        module = load_relay()
        spawned = []
        real_read = os.read

        def failing_read(fd, size):
            # Fail only the child's pipe, once it exists; the spawn's own
            # error pipe and everything unrelated keep working.
            if spawned and fd == spawned[0].stdout.fileno():
                raise OSError("injected read failure")
            return real_read(fd, size)

        child_code = (
            "import subprocess, time; "
            "subprocess.Popen(['/usr/bin/sleep', '30'], stdout=subprocess.DEVNULL); "
            "print('hello', flush=True); time.sleep(30)"
        )
        with mock.patch.object(module.subprocess, "Popen",
                               side_effect=self.recording_popen(spawned)), \
                mock.patch.object(module.os, "read", side_effect=failing_read):
            code, captured = self.run_main(module, [
                "bounded-relay", "--max-bytes", "1024", "--deadline", "30", "--",
                sys.executable, "-c", child_code,
            ])
        self.assertEqual(code, 1)
        self.assertIn("stream failed", json.loads(captured.buffer.getvalue())["error"])
        self.assertEqual(len(spawned), 1)
        self.assert_group_dead(spawned[0])
        self.assertIsNone(module._CHILD)

    def test_a_broken_output_pipe_kills_the_group(self):
        # The consumer going away is a quiet exit, not an error record - but
        # the child's tree still comes down.
        module = load_relay()
        spawned = []

        class BrokenBuffer:
            def write(self, chunk):
                raise BrokenPipeError("consumer gone")

            def flush(self):
                pass

        class BrokenStdout:
            buffer = BrokenBuffer()

            def write(self, text):
                raise BrokenPipeError("consumer gone")

            def flush(self):
                pass

        child_code = (
            "import time; print('x' * 100, flush=True); time.sleep(30)"
        )
        with mock.patch.object(module.subprocess, "Popen",
                               side_effect=self.recording_popen(spawned)):
            code, _ = self.run_main(
                module,
                ["bounded-relay", "--max-bytes", "1024", "--deadline", "30", "--",
                 sys.executable, "-c", child_code],
                stdout=BrokenStdout(),
            )
        self.assertEqual(code, 1)
        self.assertEqual(len(spawned), 1)
        self.assert_group_dead(spawned[0])
        self.assertIsNone(module._CHILD)


if __name__ == "__main__":
    unittest.main()
