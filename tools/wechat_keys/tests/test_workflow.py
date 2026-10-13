import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

MODULE = Path(__file__).resolve().parents[1]


def load_module(name, file):
    specification = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


workflow = load_module("workflow", MODULE / "workflow.py")


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.key = os.urandom(32).hex()

    def database(self, relative="message/message_0.db"):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(os.urandom(16) + b"synthetic-only")
        return path

    def test_permission_error_does_not_look_like_an_empty_directory(self):
        with patch.object(workflow.os, "scandir", side_effect=PermissionError()):
            with self.assertRaises(PermissionError):
                workflow.encrypted_databases(self.source)

    def test_symlink_files_and_directories_are_not_read(self):
        self.database()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.db").write_bytes(os.urandom(32))
        (self.source / "link.db").symlink_to(outside / "secret.db")
        (self.source / "linked-directory").symlink_to(outside, target_is_directory=True)
        self.assertEqual(workflow.encrypted_databases(self.source), ["message/message_0.db"])

    def test_short_database_is_rejected(self):
        self.database().write_bytes(b"short")
        with self.assertRaises(workflow.WorkflowError):
            workflow.encrypted_databases(self.source)

    def test_plain_database_is_not_reported_as_encrypted(self):
        self.database().write_bytes(b"SQLite format 3\0" + b"synthetic")
        with self.assertRaises(workflow.WorkflowError):
            workflow.encrypted_databases(self.source)

    def test_exported_keys_are_private_and_cannot_overwrite(self):
        path = self.root / "keys.json"
        workflow.private_json(path, {"message/message_0.db": {"enc_key": self.key}})
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        before = path.read_bytes()
        with self.assertRaises(FileExistsError):
            workflow.private_json(path, {"replacement": True})
        self.assertEqual(path.read_bytes(), before)

    def test_private_key_output_does_not_follow_a_symlink(self):
        outside = self.root / "outside.json"
        outside.write_text("untouched")
        path = self.root / "link.json"
        path.symlink_to(outside)
        with self.assertRaises(FileExistsError):
            workflow.private_json(path, {"enc_key": self.key})
        self.assertEqual(outside.read_text(), "untouched")

    def test_key_validation_rejects_traversal_and_does_not_echo_input(self):
        path = self.root / "keys.json"
        path.write_text(json.dumps({"../outside.db": {"enc_key": self.key}}))
        with self.assertRaises(workflow.WorkflowError) as failure:
            workflow.load_keys(path)
        self.assertNotIn(self.key, str(failure.exception))

    def test_empty_key_file_is_rejected(self):
        path = self.root / "keys.json"
        path.write_text("{}")
        with self.assertRaises(workflow.WorkflowError):
            workflow.load_keys(path)

    def test_extra_untrusted_key_fields_are_not_persisted(self):
        path = self.root / "keys.json"
        path.write_text(json.dumps({"message/message_0.db": {"enc_key": self.key, "other": "not retained"}}))
        self.assertEqual(workflow.load_keys(path), {"message/message_0.db": {"enc_key": self.key}})

    @patch.object(workflow, "wechat_pids", return_value=[])
    def test_snapshot_preserves_wal_and_source_and_uses_private_modes(self, pids):
        source = self.database()
        wal = source.with_name(source.name + "-wal")
        wal.write_bytes(b"synthetic WAL")
        before = source.read_bytes()
        destination = self.root / "snapshot"
        workflow.snapshot(self.source, destination)
        self.assertEqual((destination / source.relative_to(self.source)).read_bytes(), before)
        self.assertEqual((destination / wal.relative_to(self.source)).read_bytes(), wal.read_bytes())
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((destination / source.relative_to(self.source)).stat().st_mode), 0o600)

    @patch.object(workflow, "wechat_pids", return_value=[123])
    def test_live_wechat_blocks_snapshot(self, pids):
        self.database()
        destination = self.root / "snapshot"
        with self.assertRaises(workflow.WorkflowError):
            workflow.snapshot(self.source, destination)
        self.assertFalse(destination.exists())

    @patch.object(workflow, "wechat_pids", return_value=[])
    def test_low_disk_space_blocks_before_creating_snapshot(self, pids):
        database = self.database()
        before = database.read_bytes()
        destination = self.root / "snapshot"
        with patch.object(workflow.shutil, "disk_usage", return_value=SimpleNamespace(free=10)):
            with self.assertRaises(workflow.WorkflowError):
                workflow.snapshot(self.source, destination)
        self.assertFalse(destination.exists())
        self.assertEqual(database.read_bytes(), before)

    @patch.object(workflow, "wechat_pids", return_value=[])
    def test_changed_source_snapshot_is_rejected(self, pids):
        database = self.database()
        original = workflow.regular_files
        calls = 0

        def changed(root):
            nonlocal calls
            calls += 1
            if calls == 2:
                database.write_bytes(database.read_bytes() + b"changed")
            return original(root)

        with patch.object(workflow, "regular_files", side_effect=changed):
            with self.assertRaises(workflow.WorkflowError):
                workflow.snapshot(self.source, self.root / "snapshot")

    def test_core_command_preserves_spaces_without_shell_interpolation(self):
        source = self.root / "directory with spaces"
        arguments = workflow.core_command(Path("cli"), "validate", source, Path("map.json"), Path("report.json"), ["migrate/old.db"])
        self.assertIn(str(source), arguments)
        self.assertEqual(arguments[-2:], ["--allow-missing", "migrate/old.db"])

    def test_capture_uses_terminal_interrupt_and_detaches(self):
        directory = self.root / "capture"
        directory.mkdir()
        child = MagicMock()
        child.poll.return_value = None
        child.returncode = 0
        sent = []
        terminal = None
        original_write = os.write

        def spawn(*args, **kwargs):
            nonlocal terminal
            terminal = os.dup(kwargs["stdout"])
            self.addCleanup(os.close, terminal)
            original_write(terminal, b"CAPTURE_READY: ready\n")
            (directory / "hook-candidates.json").write_text(json.dumps([self.key]))
            return child

        def write(fd, data):
            sent.append(data)
            written = original_write(fd, data)
            if data == b"\x03\n":
                original_write(terminal, b"Process stopped\n(lldb) ")
            if data == b"process continue\n":
                original_write(terminal, b"Process 123 resuming\n")
            if b"process detach" in data:
                original_write(terminal, b"Process 123 detached\n")
            if b"print(\"CAPTURE_STATS\"" in data:
                original_write(terminal, b"CAPTURE_STATS {}\n")
            if data == b"quit\n":
                child.poll.return_value = 0
            return written

        clock = iter(value / 4 for value in range(1000))
        with patch.object(workflow.subprocess, "Popen", side_effect=spawn), \
                patch.object(workflow.os, "write", side_effect=write), \
                patch.object(workflow, "wechat_pids", return_value=[]), \
                patch.object(workflow.time, "monotonic", side_effect=lambda: next(clock)):
            output = workflow.capture(123, 2, directory)
        child.send_signal.assert_not_called()
        self.assertIn(b"\x03\n", sent)
        self.assertIn(b"process detach\n", sent)
        self.assertIn(b"quit\n", sent)
        self.assertIn(b"process continue\n", sent)
        self.assertEqual(output, directory / "hook-candidates.json")

    def test_capture_attach_failure_cannot_become_empty_success(self):
        directory = self.root / "capture"
        directory.mkdir()
        child = MagicMock()
        child.stdin = io.BytesIO()
        child.poll.return_value = 1
        with patch.object(workflow.subprocess, "Popen", return_value=child):
            with self.assertRaises(workflow.WorkflowError):
                workflow.capture(123, 5, directory)


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        fake_lldb = SimpleNamespace(SBError=lambda: SimpleNamespace(Success=lambda: True))
        with patch.dict(sys.modules, {"lldb": fake_lldb}):
            self.capture = load_module("capture_fixture", MODULE / "capture_keys.py")
        self.capture.OUTPUT = Path(self.temporary.name) / "candidates.json"
        self.key = os.urandom(32)

    def frame(self, architecture="arm64", operation=1, algorithm=0, mode=False, length=32):
        registers = {"x0": operation, "x1": algorithm, "x2": algorithm, "x3": 4096, "x4": length, "x5": 4096, "x6": length,
                     "rdi": operation, "rsi": algorithm, "rdx": algorithm, "rcx": 4096, "r9": 4096, "r8": length, "rsp": 8192}
        process = SimpleNamespace(GetTarget=lambda: SimpleNamespace(GetTriple=lambda: architecture),
            ReadMemory=lambda pointer, length, error: self.key,
            ReadUnsignedFromMemory=lambda pointer, size, error: length if pointer == 8200 else 0)
        return SimpleNamespace(GetFunctionName=lambda: "CCCryptorCreateWithMode" if mode else "CCCryptorCreate",
            GetThread=lambda: SimpleNamespace(GetProcess=lambda: process),
            FindRegister=lambda name: SimpleNamespace(GetValueAsUnsigned=lambda: registers[name]))

    def test_arm_capture_records_only_private_candidate_bytes(self):
        self.capture.on_crypto(self.frame(), None, None)
        self.assertEqual(json.loads(self.capture.OUTPUT.read_text()), [self.key.hex()])
        self.assertEqual(stat.S_IMODE(self.capture.OUTPUT.stat().st_mode), 0o600)

    def test_non_32_byte_argument_buffers_are_ignored(self):
        self.capture.on_crypto(self.frame(length=16), None, None)
        self.assertFalse(self.capture.OUTPUT.exists())

    def test_aes_encryption_context_can_contain_the_database_key(self):
        self.capture.on_crypto(self.frame(operation=0), None, None)
        self.assertEqual(json.loads(self.capture.OUTPUT.read_text()), [self.key.hex()])

    def test_intel_with_mode_reads_key_length_from_argument_stack(self):
        self.capture.on_crypto(self.frame(architecture="x86_64", mode=True), None, None)
        self.assertEqual(json.loads(self.capture.OUTPUT.read_text()), [self.key.hex()])

    def test_breakpoints_resume_but_mixed_crash_stops_do_not(self):
        debugger = MagicMock()
        process = debugger.GetSelectedTarget.return_value.GetProcess.return_value
        process.GetState.return_value = 5
        thread = MagicMock()
        thread.GetStopReason.return_value = 3
        process.__iter__.return_value = iter([thread])
        self.capture.lldb.eStateStopped = 5
        self.capture.lldb.eStopReasonBreakpoint = 3
        self.capture.lldb.eStopReasonNone = 1
        self.capture.lldb.eStopReasonInvalid = 0
        self.capture.lldb.eStopReasonSignal = 5
        self.capture.lldb.eStopReasonPlanComplete = 8
        self.capture.lldb.eStopReasonException = 6
        self.capture.lldb.eStopReasonTrace = 2
        debugger.GetSelectedTarget.return_value.GetNumBreakpoints.return_value = 0
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()

        process.Continue.reset_mock()
        crash = MagicMock()
        crash.GetStopReason.return_value = 6
        process.__iter__.return_value = iter([thread, crash])
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_not_called()
        process.__iter__.return_value = iter([thread, crash])
        crash.GetStopReason.return_value = 5
        crash.GetStopReasonDataAtIndex.return_value = self.capture.signal.SIGSTOP
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()

        process.Continue.reset_mock()
        process.__iter__.return_value = iter([thread, crash])
        crash.GetStopReason.return_value = 2  # debugger single-step trace
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()
        process.Continue.reset_mock()
        process.__iter__.return_value = iter([thread, crash])
        thread.GetStopReason.return_value = 1
        crash.GetStopReason.return_value = 5
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()  # initial attach SIGSTOP
        process.Continue.reset_mock()
        process.__iter__.return_value = iter([thread, crash])
        crash.GetStopReason.return_value = 2
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()  # debugger trace without a breakpoint

    def test_simultaneous_trap_is_captured_only_at_owned_breakpoint(self):
        debugger = MagicMock()
        target = debugger.GetSelectedTarget.return_value
        target.GetTriple.return_value = "arm64"
        target.GetNumBreakpoints.return_value = 1
        breakpoint = target.GetBreakpointAtIndex.return_value
        breakpoint.GetID.return_value = 1
        breakpoint.GetNumLocations.return_value = 1
        location = breakpoint.GetLocationAtIndex.return_value
        location.IsResolved.return_value = True
        location.GetAddress.return_value.GetLoadAddress.return_value = 4096
        self.capture.BREAKPOINT_IDS.add(1)
        process = target.GetProcess.return_value
        process.GetState.return_value = 5
        thread = MagicMock()
        thread.GetStopReason.return_value = 6
        thread.GetStopDescription.return_value = "EXC_BREAKPOINT (code=1)"
        frame = self.frame(mode=True)
        frame.GetPC = lambda: 4100
        frame.SetPC = MagicMock(return_value=True)
        thread.GetFrameAtIndex.return_value = frame
        process.__iter__.return_value = iter([thread])
        for name, value in {"eStateStopped": 5, "eStopReasonBreakpoint": 3,
                            "eStopReasonNone": 1, "eStopReasonInvalid": 0,
                            "eStopReasonSignal": 5, "eStopReasonPlanComplete": 8,
                            "eStopReasonException": 6, "eStopReasonTrace": 2}.items():
            setattr(self.capture.lldb, name, value)
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_called_once()
        frame.SetPC.assert_called_once_with(4096)
        self.assertEqual(json.loads(self.capture.OUTPUT.read_text()), [self.key.hex()])
        process.Continue.reset_mock()
        process.__iter__.return_value = iter([thread])
        frame.GetPC = lambda: 123456  # an unrelated trap is never resumed
        self.capture.resume_breakpoint(debugger)
        process.Continue.assert_not_called()




if __name__ == "__main__":
    unittest.main()
