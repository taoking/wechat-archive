"""Synthetic CLI acceptance: no real WeChat data or global viewer preferences."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import importlib.util

PROJECT = Path(__file__).resolve().parents[3]
CLI = Path(os.environ.get("WECHAT_ARCHIVE_CLI", PROJECT / ".build/debug/WeChatArchiveCLI"))
specification = importlib.util.spec_from_file_location("acceptance_workflow", PROJECT / "tools/wechat_keys/workflow.py")
workflow = importlib.util.module_from_spec(specification)
specification.loader.exec_module(workflow)


@unittest.skipUnless(CLI.is_file() and shutil.which("sqlcipher"), "Build WeChatArchiveCLI and install SQLCipher first")
class CLIAcceptanceTests(unittest.TestCase):
    def setUp(self):
        if sys.platform == "darwin" and subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "WeChat"], capture_output=True).returncode == 0:
            self.skipTest("CLI requires WeChat fully exited, including for synthetic acceptance tests")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "Source"
        self.database = self.source / "message/message_0.db"
        self.database.parent.mkdir(parents=True)
        self.account = self.root / "Account"
        self.account.mkdir()
        self.key = os.urandom(32).hex()
        script = '.bail on\nPRAGMA key="x\'' + self.key + "'\";\n" + """
CREATE TABLE Msg_0123456789abcdef0123456789abcdef
(local_id INTEGER, local_type INTEGER, create_time INTEGER, message_content TEXT);
INSERT INTO Msg_0123456789abcdef0123456789abcdef VALUES(1, 1, 1700000000, 'synthetic CLI acceptance');
"""
        subprocess.run(["sqlcipher", str(self.database)], input=script, text=True, capture_output=True, check=True)
        self.map = self.root / "fixture-keys.json"
        self.map.write_text(json.dumps({"message/message_0.db": {"enc_key": self.key}}))
        self.report = self.root / "result.json"

    def invoke(self, action, *extra):
        return subprocess.run([str(CLI), action, "--db-dir", str(self.source), "--keys", str(self.map), "--report", str(self.report), *extra], capture_output=True, text=True)

    def test_encrypted_database_to_complete_archive(self):
        original = self.database.read_bytes()
        archive = self.root / "Archive"
        plain = self.root / "Plain"
        result = self.invoke("archive", "--output", str(plain), "--account-root", str(self.account), "--archive-output", str(archive))
        self.assertEqual(result.returncode, 0, result.stderr + (self.report.read_text() if self.report.exists() else ""))
        report = json.loads(self.report.read_bytes())
        self.assertEqual(report["validated"], 1)
        self.assertEqual(report["exported"], 1)
        self.assertEqual(report["messagesImported"], 1)
        self.assertTrue(report["archiveCreated"])
        self.assertTrue(report["completeCoverage"])
        self.assertEqual(self.database.read_bytes(), original)
        self.assertTrue((archive / "archive.sqlite").is_file())
        self.assertNotIn(self.key, self.report.read_text() + result.stdout + result.stderr)
        self.assertEqual(self.report.stat().st_mode & 0o777, 0o600)

    def test_import_plain_preserves_source_and_does_not_claim_key_coverage(self):
        plain = self.root / "Plain"
        database = plain / "message/message_0.db"
        database.parent.mkdir(parents=True)
        with sqlite3.connect(database) as connection:
            connection.executescript("CREATE TABLE Msg_0123456789abcdef0123456789abcdef (local_id INTEGER, local_type INTEGER, create_time INTEGER, message_content TEXT); INSERT INTO Msg_0123456789abcdef0123456789abcdef VALUES (1, 1, 1700000000, 'plain fixture');")
        original = database.read_bytes()
        archive = self.root / "Archive"
        result = subprocess.run([str(CLI), "import-plain", "--db-dir", str(plain), "--account-root", str(self.account), "--archive-output", str(archive), "--report", str(self.report)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.report.read_bytes())
        self.assertTrue(report["archiveCreated"])
        self.assertEqual(report["messagesImported"], 1)
        self.assertFalse(report["keyCoverageChecked"])
        self.assertFalse(report["completeCoverage"])
        self.assertEqual(database.read_bytes(), original)
        repeated = subprocess.run([str(CLI), "import-plain", "--db-dir", str(plain), "--account-root", str(self.account), "--archive-output", str(archive), "--report", str(self.root / "again.json")], capture_output=True)
        self.assertNotEqual(repeated.returncode, 0)
        archived_database = (archive / "archive.sqlite").read_bytes()
        resumed = subprocess.run([str(CLI), "import-plain", "--db-dir", str(plain), "--account-root", str(self.account), "--archive-output", str(archive), "--report", str(self.root / "resume.json"), "--resume"], capture_output=True)
        self.assertNotEqual(resumed.returncode, 0)
        self.assertEqual((archive / "archive.sqlite").read_bytes(), archived_database)
        self.assertEqual(database.read_bytes(), original)

    def test_missing_database_blocks_before_plaintext_export(self):
        missing = self.source / "migrate/old.db"
        missing.parent.mkdir()
        missing.write_bytes(os.urandom(4096))
        plain = self.root / "Plain"
        result = self.invoke("archive", "--output", str(plain), "--account-root", str(self.account), "--archive-output", str(self.root / "Archive"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(plain.exists())
        self.assertEqual(json.loads(self.report.read_bytes())["missingDatabases"], ["migrate/old.db"])

    def test_explicit_missing_is_reported_as_partial_coverage(self):
        missing = self.source / "migrate/old.db"
        missing.parent.mkdir()
        missing.write_bytes(os.urandom(4096))
        result = self.invoke("validate", "--allow-missing", "migrate/old.db")
        self.assertEqual(result.returncode, 0)
        report = json.loads(self.report.read_bytes())
        self.assertEqual(report["status"], "completed_with_allowed_missing")
        self.assertFalse(report["completeCoverage"])

    def test_existing_report_is_not_overwritten_or_used_as_success(self):
        self.report.write_text("untouched")
        plain = self.root / "Plain"
        result = self.invoke("archive", "--output", str(plain), "--account-root", str(self.account), "--archive-output", str(self.root / "Archive"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.report.read_text(), "untouched")
        self.assertFalse(plain.exists())

    def test_archive_cannot_write_inside_original_source(self):
        result = self.invoke("archive", "--output", str(self.source / "plain"), "--account-root", str(self.account), "--archive-output", str(self.root / "Archive"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.source / "plain").exists())

    def test_one_command_reuses_keys_archives_and_cleans_working_secrets(self):
        source = self.account / "db_storage"
        shutil.move(self.source, source)
        workspace = self.root / "workflow"
        original_keys = self.map.read_bytes()
        with patch.object(workflow, "PROJECT", self.root), patch.object(workflow, "WORKSPACE", workspace), \
                patch.object(workflow, "build_tools", return_value=(CLI, None)):
            workflow.main(["archive", "--db-dir", str(source), "--keys", str(self.map)])
        reports = list((workspace / "runs").glob("*/result.json"))
        self.assertEqual(len(reports), 1)
        report = json.loads(reports[0].read_text())
        self.assertEqual(report["messagesImported"], 1)
        self.assertTrue(report["archiveCreated"])
        self.assertEqual(len(list((workspace / "archives").glob("*/archive.sqlite"))), 1)
        self.assertFalse(list((workspace / "keys").glob("*/all_keys.json")))
        self.assertFalse(list((workspace / "databases").iterdir()))
        self.assertEqual(self.map.read_bytes(), original_keys)

    def test_failed_workflow_cleans_its_key_copy_and_preserves_input(self):
        source = self.account / "db_storage"
        shutil.move(self.source, source)
        self.map.write_text(json.dumps({"message/message_0.db": {"enc_key": os.urandom(32).hex()}}))
        original_keys = self.map.read_bytes()
        workspace = self.root / "workflow"
        with patch.object(workflow, "PROJECT", self.root), patch.object(workflow, "WORKSPACE", workspace), \
                patch.object(workflow, "build_tools", return_value=(CLI, None)):
            with self.assertRaises(workflow.WorkflowError):
                workflow.main(["archive", "--db-dir", str(source), "--keys", str(self.map)])
        self.assertFalse(list((workspace / "keys").glob("*/all_keys.json")))
        self.assertFalse(list((workspace / "databases").iterdir()))
        self.assertEqual(self.map.read_bytes(), original_keys)
        report = json.loads(next((workspace / "runs").glob("*/result.json")).read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["invalid"], 1)


if __name__ == "__main__":
    unittest.main()
