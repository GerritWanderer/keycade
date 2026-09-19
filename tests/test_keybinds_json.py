import importlib.machinery
import importlib.util
import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "keybinds-json"


def load_helper():
    loader = importlib.machinery.SourceFileLoader("keybinds_json", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CapturedStdout:
    """Stand-in for sys.stdout capturing text and buffer writes together."""

    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, text):
        self.buffer.write(text.encode("utf-8"))

    def flush(self):
        pass


class GuardStatusTests(unittest.TestCase):
    """The retained path: the --guard-status preflight InputGuard launches.

    The reply fixtures mirror the two shapes hyprctl getoption actually emits
    for a boolean option: an integer field through Hyprland 0.54, a JSON
    boolean from 0.55 on. Everything else must fail closed, and no test here
    needs a compositor: the trusted binary and the subprocess are mocked
    in-process, and the end-to-end cases assert the contract an unreachable
    compositor produces.
    """

    @classmethod
    def setUpClass(cls):
        cls.helper = load_helper()

    def option(self, **fields):
        return {"option": "binds:disable_keybind_grabbing", **fields}

    def run_guard(self, reply):
        with mock.patch.object(self.helper, "trusted_command", side_effect=lambda path: path), \
                mock.patch.object(self.helper, "command_output", return_value=reply):
            return self.helper.guard_status()

    def run_cli(self, argv, reply=None, error=None):
        """Run main() in-process with the trusted path and the query mocked.

        Scrubbing and signal handlers belong to the real process; the test
        runner's environment and handlers are not the helper's to take.
        """
        captured = CapturedStdout()
        patches = [
            mock.patch.object(self.helper, "trusted_command", side_effect=lambda path: path),
            mock.patch.object(self.helper, "command_output", side_effect=error)
            if error is not None
            else mock.patch.object(self.helper, "command_output", return_value=reply),
            mock.patch.object(self.helper, "scrub_environment"),
            mock.patch.object(self.helper, "install_signal_handlers"),
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(sys, "stdout", captured),
            mock.patch.object(sys, "stderr", io.StringIO()),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        try:
            code = self.helper.main()
        except SystemExit as raised:
            code = raised.code
        return code, captured.buffer.getvalue()

    # --- the two legitimate versioned reply shapes ---

    def test_modern_boolean_replies(self):
        # Hyprland 0.55 and later: {"option": ..., "bool": ..., "set": ...}.
        self.assertFalse(self.helper.guard_disabled(self.option(bool=False, set=False)))
        self.assertTrue(self.helper.guard_disabled(self.option(bool=True, set=True)))
        # "set" is metadata and may be absent.
        self.assertFalse(self.helper.guard_disabled(self.option(bool=False)))

    def test_legacy_integer_replies(self):
        # Hyprland 0.54 and earlier: {"option": ..., "int": 0|1, "set": ...}.
        self.assertFalse(self.helper.guard_disabled(self.option(int=0, set=False)))
        self.assertTrue(self.helper.guard_disabled(self.option(int=1, set=True)))
        self.assertTrue(self.helper.guard_disabled(self.option(int=1)))

    def test_unrelated_metadata_is_tolerated(self):
        self.assertTrue(self.helper.guard_disabled(self.option(bool=True, set=True, future="field")))

    # --- malformed replies fail closed ---

    def test_wrong_option_identity_is_rejected(self):
        for reply in (
            {"bool": False},  # no identity at all
            {"int": 0, "set": False},
            {"option": "general:border_size", "int": 0},  # a 0 for another option is not "safe"
            {"option": "binds:disable_keybind_grabbing2", "bool": False},
            {"option": 5, "bool": False},
            {"option": None, "bool": False},
        ):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    def test_wrong_typed_values_are_rejected(self):
        for reply in (
            self.option(bool="false"),  # strings are not booleans
            self.option(bool="true"),
            self.option(bool=0),
            self.option(bool=1),
            self.option(bool=None),
            self.option(int="0"),
            self.option(int="1"),
            self.option(int=True),  # a JSON bool is not the integer shape
            self.option(int=False),
            self.option(int=0.0),
            self.option(int=None),
        ):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    def test_out_of_range_integers_are_rejected(self):
        for value in (-1, 2, 65536):
            with self.subTest(value=value):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(self.option(int=value))

    def test_non_boolean_value_fields_are_rejected(self):
        # getoption answers "str"/"float"/... for differently typed options;
        # none of them says anything about a boolean, whatever they contain.
        for reply in (
            self.option(str="false"),
            self.option(str="true"),
            self.option(str="0"),
            self.option(float=0.0),
            self.option(vec2=[0, 0]),
            self.option(custom="x"),
        ):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    def test_multiple_value_fields_are_rejected(self):
        # Never a shape hyprctl emits - whether the fields agree or not.
        for reply in (
            self.option(bool=True, int=0),   # conflicting
            self.option(bool=False, int=1),  # conflicting
            self.option(bool=True, int=1),   # agreeing but undocumented
            self.option(bool=False, int=0, str="false"),
            self.option(int=0, str="0"),
            self.option(int=1, str="true"),
        ):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    def test_a_missing_value_is_rejected(self):
        for reply in (self.option(), self.option(set=False)):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    def test_non_object_replies_are_rejected(self):
        for reply in ([], 0, "text", None):
            with self.subTest(reply=reply):
                with self.assertRaises(self.helper.HelperError):
                    self.helper.guard_disabled(reply)

    # --- guard_status: JSON in, versioned record out ---

    def test_reports_the_guard_record_shape(self):
        result = self.run_guard(
            '{"option": "binds:disable_keybind_grabbing", "bool": false, "set": true }'
        )
        self.assertEqual(result, {"schemaVersion": 1, "type": "guard", "disabled": False})

    def test_guard_record_for_a_disabled_option(self):
        result = self.run_guard(
            '{"option": "binds:disable_keybind_grabbing", "int": 1, "set": true }'
        )
        self.assertEqual(result["disabled"], True)

    def test_malformed_json_is_an_error_not_a_guess(self):
        with self.assertRaises(json.JSONDecodeError):
            self.run_guard("{not json")

    def test_trailing_garbage_after_the_reply_is_rejected(self):
        with self.assertRaises(json.JSONDecodeError):
            self.run_guard(
                '{"option": "binds:disable_keybind_grabbing", "bool": false} extra'
            )

    def test_an_undocumented_reply_shape_is_an_error(self):
        with self.assertRaises(self.helper.HelperError):
            self.run_guard('{"option": "binds:disable_keybind_grabbing", "str": "false"}')

    def test_a_failing_query_propagates(self):
        with mock.patch.object(self.helper, "trusted_command", side_effect=lambda path: path), \
                mock.patch.object(self.helper, "command_output",
                                  side_effect=self.helper.HelperError("no compositor")):
            with self.assertRaises(self.helper.HelperError):
                self.helper.guard_status()

    def test_hyprctl_is_queried_read_only_through_the_trusted_path(self):
        with mock.patch.object(self.helper, "trusted_command",
                               side_effect=lambda path: path) as trusted, \
                mock.patch.object(self.helper, "command_output",
                                  return_value='{"option": "binds:disable_keybind_grabbing",'
                                               ' "bool": false, "set": false}') as output:
            self.helper.guard_status()
        # R7: the absolute, root-owned binary; R1: getoption never writes.
        trusted.assert_called_once_with(self.helper.HYPRCTL_PATH)
        (command,), kwargs = output.call_args
        self.assertEqual(
            command,
            ["/usr/bin/hyprctl", "-j", "getoption", "binds:disable_keybind_grabbing"],
        )
        # R2: the producer caps what it will read rather than trusting the peer.
        self.assertEqual(kwargs["max_stdout"], 64 * 1024)

    # --- the CLI contract ---

    def test_cli_emits_one_small_guard_record(self):
        code, output = self.run_cli(
            ["keybinds-json", "--guard-status"],
            reply='{"option": "binds:disable_keybind_grabbing", "bool": false, "set": false}',
        )
        self.assertEqual(code, 0)
        lines = output.splitlines()
        self.assertEqual(len(lines), 1)
        # InputGuard.qml caps what it retains at 4096 bytes while reading.
        self.assertLessEqual(len(lines[0]), 4096)
        self.assertEqual(
            json.loads(lines[0]),
            {"schemaVersion": 1, "type": "guard", "disabled": False},
        )

    def test_cli_query_failure_is_fail_closed(self):
        code, output = self.run_cli(
            ["keybinds-json", "--guard-status"],
            error=self.helper.HelperError("no compositor"),
        )
        self.assertEqual(code, 1)
        record = json.loads(output.splitlines()[0])
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["type"], "error")
        self.assertIn("no compositor", record["error"])
        # No "disabled" field: the consumer requires a real boolean and fails.
        self.assertNotIn("disabled", record)

    def test_cli_malformed_reply_is_fail_closed(self):
        code, _ = self.run_cli(["keybinds-json", "--guard-status"], reply="{not json")
        self.assertEqual(code, 1)

    def test_cli_undocumented_reply_shape_is_fail_closed(self):
        code, output = self.run_cli(
            ["keybinds-json", "--guard-status"],
            reply='{"option": "binds:disable_keybind_grabbing", "str": "false"}',
        )
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.splitlines()[0])["type"], "error")

    def test_cli_rejects_retired_interfaces(self):
        for argv in (
            ["keybinds-json"],
            ["keybinds-json", "--input", "binds.txt"],
            ["keybinds-json", "--devices-input", "devices.txt"],
            ["keybinds-json", "--pretty"],
            ["keybinds-json", "--xkb-environment-overridden"],
            ["keybinds-json", "--session-home", "/home/u"],
            ["keybinds-json", "--guard-status", "--input", "binds.txt"],
        ):
            with self.subTest(argv=argv[1:] or ["<none>"]):
                code, _ = self.run_cli(argv, reply='{"bool": false}')
                self.assertEqual(code, 2)

    def test_cli_without_a_compositor_fails_closed(self):
        # The real script, the real trusted /usr/bin/hyprctl, and a runtime
        # dir with no compositor socket in it: the query cannot succeed, so
        # the helper must say so on stdout and with its exit code. The same
        # contract covers a host where hyprctl is absent entirely.
        with tempfile.TemporaryDirectory() as runtime_dir:
            result = subprocess.run(
                [str(SCRIPT), "--guard-status"],
                capture_output=True,
                timeout=30,
                env={"PATH": "/usr/bin",
                     "HYPRLAND_INSTANCE_SIGNATURE": "keycade-test-no-such-instance",
                     "XDG_RUNTIME_DIR": runtime_dir},
            )
        self.assertEqual(result.returncode, 1)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 1)
        self.assertLessEqual(len(lines[0]), 4096)
        record = json.loads(lines[0])
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["type"], "error")
        self.assertNotIn("disabled", record)

    @unittest.skipUnless(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"),
                         "no compositor reachable")
    def test_the_running_compositors_reply_shape_is_accepted(self):
        # Read-only query through the real script and the real trusted
        # hyprctl: pins the validator to the versioned reply shape this
        # machine's Hyprland actually emits.
        result = subprocess.run(
            [str(SCRIPT), "--guard-status"], capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["type"], "guard")
        self.assertIsInstance(record["disabled"], bool)

    def test_ci_hyprctl_mock_reply_matches_the_guard_schema(self):
        # .github/workflows/ci.yml installs tests/mocks/hyprctl as the
        # root-owned /usr/bin/hyprctl; its preflight reply must stay a
        # versioned shape the validator accepts. The mock is executed
        # directly by its repo path - trusted_command is not relaxed for it -
        # behind a synthetic compositor socket.
        mock_path = ROOT / "tests" / "mocks" / "hyprctl"
        with tempfile.TemporaryDirectory() as runtime_dir:
            instance = Path(runtime_dir) / "hypr" / "keycade-test-instance"
            instance.mkdir(parents=True)
            listener = socket.socket(socket.AF_UNIX)
            try:
                listener.bind(str(instance / ".socket.sock"))
                result = subprocess.run(
                    [str(mock_path), "-j", "getoption", "binds:disable_keybind_grabbing"],
                    capture_output=True, text=True, timeout=10, check=True,
                    env={"PATH": "/usr/bin", "XDG_RUNTIME_DIR": runtime_dir,
                         "HYPRLAND_INSTANCE_SIGNATURE": "keycade-test-instance"},
                )
            finally:
                listener.close()
        self.assertFalse(self.helper.guard_disabled(json.loads(result.stdout)))

    def test_ci_hyprctl_mock_refuses_unsupported_requests(self):
        mock_path = ROOT / "tests" / "mocks" / "hyprctl"
        minimal_env = {"PATH": "/usr/bin"}
        cases = [
            # A different option, and a lookalike of the guard option.
            (["-j", "getoption", "general:border_size"], minimal_env),
            (["-j", "getoption", "binds:enable_keybind_grabbing"], minimal_env),
            # The retired interfaces.
            (["-j", "binds"], minimal_env),
            (["-j", "--batch", "getoption input:kb_layout"], minimal_env),
            (["binds"], minimal_env),
            (["devices"], minimal_env),
            ([], minimal_env),
            # The right query with no compositor behind it: no instance set,
            # and an instance whose socket does not exist.
            (["-j", "getoption", "binds:disable_keybind_grabbing"], minimal_env),
            (["-j", "getoption", "binds:disable_keybind_grabbing"],
             {"PATH": "/usr/bin", "XDG_RUNTIME_DIR": "/nonexistent",
              "HYPRLAND_INSTANCE_SIGNATURE": "keycade-test-no-such-instance"}),
        ]
        for argv, env in cases:
            with self.subTest(argv=argv, with_socket=env is not minimal_env):
                result = subprocess.run(
                    [str(mock_path), *argv], capture_output=True, timeout=10, env=env
                )
                self.assertNotEqual(result.returncode, 0)

    def test_user_lua_configuration_is_never_executed(self):
        # R1: the only thing this helper does with the compositor is a
        # read-only getoption query; user configuration is never executed,
        # whatever HOME the launcher was started with.
        with tempfile.TemporaryDirectory() as directory:
            fake_home = Path(directory)
            config = fake_home / ".config" / "hypr"
            config.mkdir(parents=True)
            sentinel = fake_home / "executed"
            (config / "hyprland.lua").write_text(
                f'os.execute("touch {sentinel}")\n', encoding="utf-8"
            )
            subprocess.run(
                [str(SCRIPT), "--guard-status"],
                capture_output=True,
                timeout=30,
                env={"PATH": "/usr/bin", "HOME": str(fake_home),
                     "HYPRLAND_INSTANCE_SIGNATURE": "keycade-test-no-such-instance",
                     "XDG_RUNTIME_DIR": str(fake_home)},
            )
            self.assertFalse(sentinel.exists())


class SharedSafetyTests(unittest.TestCase):
    """Acceptance tests for the machinery the guard path runs on (R7/R8)."""

    @classmethod
    def setUpClass(cls):
        cls.helper = load_helper()

    def assert_pid_dead(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.fail(f"process {pid} survived the helper")

    def assert_group_dead(self, process):
        # The direct child is reaped by the helper itself; this waits out the
        # group members it leaves to the init reaper.
        self.assertIsNotNone(process.poll())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.fail("process group survived the helper")

    def recording_popen(self, spawned):
        real_popen = subprocess.Popen

        def wrapper(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            spawned.append(process)
            return process

        return wrapper

    def test_control_characters_are_normalized(self):
        self.assertEqual(self.helper.sanitize_text("safe\u202eevil\n", 20), "safe evil ")

    def test_commands_and_interpreter_are_absolute_and_trusted(self):
        # Nothing the long-lived plugin executes may be resolved through PATH.
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(source.startswith("#!/usr/bin/python3"))
        self.assertNotIn("/usr/bin/env", source)
        self.assertNotIn('"hyprctl"', source)
        self.assertEqual(self.helper.HYPRCTL_PATH, "/usr/bin/hyprctl")
        self.assertEqual(self.helper.trusted_command("/usr/bin/hyprctl"), "/usr/bin/hyprctl")

    def test_trusted_command_rejects_untrusted_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            planted = Path(directory) / "hyprctl"
            planted.write_text("#!/bin/sh\necho pwned\n", encoding="utf-8")
            planted.chmod(0o777)
            # Owned by the user rather than root, and world writable.
            with self.assertRaises(self.helper.HelperError):
                self.helper.trusted_command(str(planted))
            with self.assertRaises(self.helper.HelperError):
                self.helper.trusted_command(str(Path(directory) / "missing"))

    def test_child_environment_is_rebuilt_not_inherited(self):
        with mock.patch.dict(
            os.environ,
            {"HYPRLAND_INSTANCE_SIGNATURE": "sig", "XDG_RUNTIME_DIR": "/run/user/1",
             "LD_PRELOAD": "/tmp/evil.so", "PATH": "/tmp/evil"},
            clear=True,
        ):
            environment = self.helper.child_environment()
        self.assertEqual(
            environment,
            {"PATH": "/usr/bin", "HYPRLAND_INSTANCE_SIGNATURE": "sig", "XDG_RUNTIME_DIR": "/run/user/1"},
        )

    def test_helper_environment_is_a_whitelist_not_a_blacklist(self):
        # A variable a library starts reading later cannot slip through a
        # whitelist; a blacklist would have to be chased.
        self.assertEqual(
            set(self.helper.HELPER_ENVIRONMENT_KEYS),
            {"PATH", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR"},
        )
        environment = {"PATH": "/usr/bin", "XKB_CONFIG_ROOT": "/tmp",
                       "LD_PRELOAD": "/tmp/evil.so", "HOME": "/tmp"}
        with mock.patch.dict(self.helper.os.environ, environment, clear=True):
            self.helper.scrub_environment()
            self.assertEqual(dict(self.helper.os.environ), {"PATH": "/usr/bin"})

    def test_child_dies_with_the_helper(self):
        # A helper killed with SIGKILL cannot run cleanup code, so the kernel
        # death signal has to take the child down instead.
        script = (
            "import subprocess, sys, time, importlib.machinery, importlib.util\n"
            f"loader = importlib.machinery.SourceFileLoader('kb', {str(SCRIPT)!r})\n"
            "kb = importlib.util.module_from_spec(importlib.util.spec_from_loader('kb', loader))\n"
            "loader.exec_module(kb)\n"
            "child = subprocess.Popen(['/usr/bin/sleep', '30'], preexec_fn=kb._prepare_child)\n"
            "print(child.pid, flush=True)\n"
            "time.sleep(30)\n"
        )
        helper = subprocess.Popen(
            [sys.executable, "-c", script], stdout=subprocess.PIPE, text=True
        )
        try:
            child_pid = int(helper.stdout.readline().strip())
            helper.kill()
            helper.wait(timeout=5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                os.kill(child_pid, signal.SIGKILL)
                self.fail("child survived the helper")
        finally:
            if helper.poll() is None:
                helper.kill()
                helper.wait()
            helper.stdout.close()

    def test_sigterm_reaps_the_child_process_group(self):
        # A consumer that wants the helper gone sends SIGTERM first; the
        # handler reaps the child's whole group so the tree cannot outlive it.
        script = (
            "import subprocess, sys, time, importlib.machinery, importlib.util\n"
            f"loader = importlib.machinery.SourceFileLoader('kb', {str(SCRIPT)!r})\n"
            "kb = importlib.util.module_from_spec(importlib.util.spec_from_loader('kb', loader))\n"
            "loader.exec_module(kb)\n"
            "kb.install_signal_handlers()\n"
            "kb._ACTIVE_CHILD = subprocess.Popen(['/usr/bin/sleep', '30'],"
            " preexec_fn=kb._prepare_child)\n"
            "print(kb._ACTIVE_CHILD.pid, flush=True)\n"
            "time.sleep(30)\n"
        )
        helper = subprocess.Popen(
            [sys.executable, "-c", script], stdout=subprocess.PIPE, text=True
        )
        try:
            child_pid = int(helper.stdout.readline().strip())
            helper.send_signal(signal.SIGTERM)
            helper.wait(timeout=5)
            self.assertEqual(helper.returncode, 143)
            self.assert_pid_dead(child_pid)
        finally:
            if helper.poll() is None:
                helper.kill()
                helper.wait()
            helper.stdout.close()

    def test_subprocess_stdout_limit_is_enforced(self):
        with self.assertRaisesRegex(self.helper.HelperError, "stdout byte limit"):
            self.helper.command_output(
                [sys.executable, "-c", "import sys; sys.stdout.write('x' * 4096)"],
                max_stdout=128,
                timeout=1,
            )

    def test_subprocess_stderr_limit_is_enforced(self):
        with self.assertRaisesRegex(self.helper.HelperError, "stderr byte limit"):
            self.helper.command_output(
                [sys.executable, "-c", "import sys; sys.stderr.write('x' * 4096)"],
                max_stderr=128,
                timeout=1,
            )

    def test_subprocess_deadline_is_enforced(self):
        with self.assertRaisesRegex(self.helper.HelperError, "deadline"):
            self.helper.command_output(
                [sys.executable, "-c", "import time; time.sleep(5)"],
                timeout=0.05,
            )

    def test_subprocess_deadline_kills_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            child_code = (
                "import os,pathlib,time; "
                f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                "time.sleep(5)"
            )
            parent_code = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable, '-c', {child_code!r}]); "
                "time.sleep(5)"
            )
            with self.assertRaisesRegex(self.helper.HelperError, "deadline"):
                self.helper.command_output([sys.executable, "-c", parent_code], timeout=0.2)
            self.assert_pid_dead(int(pid_file.read_text()))

    def test_an_over_limit_stream_kills_the_whole_group(self):
        # The byte budget trips while the child is still running: it and the
        # group member it spawned must both be terminated, not just reported.
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "child.pid"
            grandchild_pid_file = Path(directory) / "grandchild.pid"
            child_code = (
                "import os, subprocess, time; "
                "grandchild = subprocess.Popen(['/usr/bin/sleep', '30'],"
                " stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                f"open({str(grandchild_pid_file)!r}, 'w').write(str(grandchild.pid)); "
                f"open({str(child_pid_file)!r}, 'w').write(str(os.getpid())); "
                "print('x' * 4096, flush=True); time.sleep(30)"
            )
            with self.assertRaisesRegex(self.helper.HelperError, "stdout byte limit"):
                self.helper.command_output(
                    [sys.executable, "-c", child_code], max_stdout=128, timeout=30
                )
            self.assert_pid_dead(int(child_pid_file.read_text()))
            self.assert_pid_dead(int(grandchild_pid_file.read_text()))
        self.assertIsNone(self.helper._ACTIVE_CHILD)

    def test_a_decode_failure_kills_the_whole_group(self):
        # stdout that is not UTF-8 fails the strict decode after the child
        # exited 0; a group member it left behind must not survive that.
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "grandchild.pid"
            child_code = (
                "import subprocess, sys; "
                "sys.stdout.buffer.write(b'\\xff'); sys.stdout.buffer.flush(); "
                "grandchild = subprocess.Popen(['/usr/bin/sleep', '30'],"
                " stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                f"open({str(pid_file)!r}, 'w').write(str(grandchild.pid))"
            )
            with self.assertRaisesRegex(self.helper.HelperError, "failed"):
                self.helper.command_output([sys.executable, "-c", child_code], timeout=30)
            self.assert_pid_dead(int(pid_file.read_text()))

    def test_a_read_failure_kills_the_whole_process_group(self):
        # A stream error mid-read is not a hygiene event: the whole tree goes.
        spawned = []

        real_read = os.read

        def failing_read(fd, size):
            # Fail only the child's pipes, once it exists; the spawn's own
            # error pipe and everything unrelated keep working.
            if spawned and fd in (spawned[0].stdout.fileno(), spawned[0].stderr.fileno()):
                raise OSError("injected read failure")
            return real_read(fd, size)

        child_code = (
            "import subprocess, time; "
            "subprocess.Popen(['/usr/bin/sleep', '30']); "
            "print('hello', flush=True); time.sleep(30)"
        )
        with mock.patch.object(self.helper.subprocess, "Popen",
                               side_effect=self.recording_popen(spawned)), \
                mock.patch.object(self.helper.os, "read", side_effect=failing_read):
            with self.assertRaisesRegex(self.helper.HelperError, "injected read failure"):
                self.helper.command_output([sys.executable, "-c", child_code], timeout=30)
        self.assertEqual(len(spawned), 1)
        self.assert_group_dead(spawned[0])
        self.assertIsNone(self.helper._ACTIVE_CHILD)

    def test_a_selector_setup_failure_kills_the_group(self):
        spawned = []
        with mock.patch.object(self.helper.subprocess, "Popen",
                               side_effect=self.recording_popen(spawned)), \
                mock.patch.object(self.helper.selectors, "DefaultSelector",
                                  side_effect=OSError("injected selector failure")):
            with self.assertRaisesRegex(self.helper.HelperError, "injected selector failure"):
                self.helper.command_output(
                    [sys.executable, "-c", "import time; time.sleep(30)"], timeout=30
                )
        self.assertEqual(len(spawned), 1)
        self.assert_group_dead(spawned[0])
        self.assertIsNone(self.helper._ACTIVE_CHILD)

    def test_a_spawn_failure_is_a_helper_error(self):
        with mock.patch.object(self.helper.subprocess, "Popen",
                               side_effect=OSError("cannot fork")):
            with self.assertRaisesRegex(self.helper.HelperError, "cannot fork"):
                self.helper.command_output(["/usr/bin/true"])

    def test_pdeathsig_setup_failure_fails_the_spawn(self):
        # Losing the death signal used to be a silent degradation; a child
        # that cannot arm it must never exec, and the failure must surface in
        # the fail-closed HelperError contract.
        real_command = self.helper.trusted_command

        def deny_libc(path):
            if path == self.helper.LIBC_PATH:
                raise self.helper.HelperError("untrusted libc")
            return real_command(path)

        with mock.patch.object(self.helper, "trusted_command", side_effect=deny_libc):
            with self.assertRaises(self.helper.HelperError):
                self.helper.command_output(["/usr/bin/true"], timeout=5)

    def test_a_failed_prctl_fails_the_spawn(self):
        fake_libc = mock.Mock()
        fake_libc.prctl.return_value = -1
        with mock.patch.object(self.helper.ctypes, "CDLL", return_value=fake_libc), \
                mock.patch.object(self.helper.ctypes, "get_errno", return_value=13):
            with self.assertRaises(self.helper.HelperError):
                self.helper.command_output(["/usr/bin/true"], timeout=5)

    def test_every_library_load_is_checked_not_just_absolute(self):
        # R7 covers dynamic libraries, and an absolute path only says where the
        # file is, not who may replace it. Every CDLL argument in a keep-loaded
        # path therefore goes through the same root-owned, non-writable check
        # the commands do.
        loaders = ("trusted_command(", "_trusted_library(")
        keep_loaded = (
            "keybinds-json", "bounded-relay", "state-store", "app-config-json",
        )
        for script in keep_loaded:
            source = (ROOT / "bin" / script).read_text(encoding="utf-8")
            for index, tail in enumerate(source.split("ctypes.CDLL(")[1:]):
                with self.subTest(script=script, load=index):
                    self.assertTrue(
                        tail.startswith(loaders),
                        f"{script}: unchecked ctypes.CDLL({tail[:40]}...)",
                    )

    def test_no_library_is_loaded_by_soname(self):
        # R7: keep-loaded paths must not resolve executable code, shared
        # objects included, through the loader's ambient search.
        keep_loaded = (
            "keybinds-json", "bounded-relay", "state-store", "app-config-json",
        )
        for script in keep_loaded:
            source = (ROOT / "bin" / script).read_text(encoding="utf-8")
            with self.subTest(script=script):
                self.assertNotIn('CDLL("lib', source)
                self.assertNotIn("CDLL('lib", source)


if __name__ == "__main__":
    unittest.main()
