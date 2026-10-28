#!/usr/bin/env python3
"""Offline recovery bootstrap failure and resume tests; no cluster is contacted."""

import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True
CHART = Path(__file__).resolve().parents[1] / "charts/ton-k8s-operator"
SPEC = importlib.util.spec_from_file_location("restore_bootstrap_fleet", CHART / "fleet.py")
fleet = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fleet)


class RestoreBootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.request = self.bundle / ".restore-node-bootstrap.json"
        self.args = ["-m", "validator", "-n", "mainnet", "-d"]
        self.state = self.work / "controller"
        self.database = self.work / "db"
        self.cache = self.work / "dump-cache"
        self.identities = {
            self.state / "initialized.json": b'{"network":"mainnet","committed":true}\n',
            self.state / "global.config.json": b'{"fixture":"original-node-network"}\n',
            self.state / "mytoncore/wallets/validator_wallet_001.pk": b"original-wallet-key",
            self.state / "services/validator.service": b"--ip 203.0.113.14:30001\n",
            self.database / "config.json": b'{"adnl":"original-adnl","ip":"203.0.113.14"}\n',
            self.database / "keyring/validator": b"original-validator-key",
        }
        for path, value in self.identities.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        self.cache.mkdir()
        self.archive = self.cache / "pinned.tar.lz"
        self.archive.write_bytes(b"synthetic pinned archive")
        self.events = []
        self.download_result = True
        self.resolved_env = {"TON_WORK_DIR": "/var/ton-work", "DUMP": "true",
                             "DUMP_EXTRACT_THREADS": "1", "NETWORK": "mainnet"}
        def parse_environment(env, args):
            self.parsed_env = dict(env)
            return {**env, **self.resolved_env}

        self.parser = mock.Mock(side_effect=parse_environment)
        self.parser_module = types.ModuleType("mytonctrl_docker_args")
        self.parser_module.installation_environment = self.parser
        self.dump_module = types.ModuleType("mytoninstaller.dump")
        self.dump_module.download_dump = mock.Mock(side_effect=self.download)
        self.dump_module.get_dump_cache_dir = mock.Mock(return_value=str(self.cache))
        self.dump_module.cleanup_completed_dump = mock.Mock(side_effect=self.cleanup_dump)
        self.package = types.ModuleType("mytoninstaller")
        self.package.__path__ = []
        self.modules = {"mytonctrl_docker_args": self.parser_module,
                        "mytoninstaller": self.package, "mytoninstaller.dump": self.dump_module}
        self.output = io.StringIO()
        self.write_request()

    def write_request(self, value=None):
        self.request.write_text(json.dumps(value if value is not None else {
            "version": 1, "args": self.args}))

    def local_path(self, value):
        path = Path(value)
        for source, target in ((Path("/var/ton-work"), self.work),
                               (Path("/var/ton-key-bundle"), self.bundle)):
            if path == source or source in path.parents:
                return target / path.relative_to(source)
        return path

    def download(self, logger, context):
        self.events.append("download")
        self.assertEqual(context.paths.ton_work_dir, str(self.work))
        self.assertEqual(context.paths.ton_db_dir, str(self.database))
        self.assertEqual(context.paths.global_config_path, str(self.state / "global.config.json"))
        self.assertEqual(os.environ["DUMP_EXTRACT_THREADS"], "1")
        self.assertEqual(Path(context.paths.global_config_path).read_bytes(),
                         self.identities[self.state / "global.config.json"])
        logger.add_log("using the original node network")
        extracted = self.database / "celldb/fixture"
        if self.download_result:
            if extracted.exists():
                self.events.append("resume")
            else:
                extracted.parent.mkdir()
                extracted.write_bytes(b"synthetic blockchain database")
                self.events.append("extract")
        return self.download_result

    def chown(self, command, check):
        self.assertTrue(check)
        self.assertEqual(command, ["chown", "-R", "validator:validator", str(self.database)])
        self.assertTrue((self.database / "celldb/fixture").is_file())
        self.events.append("ownership")

    def cleanup_dump(self, cache, database):
        self.assertEqual((cache, database), (str(self.cache), str(self.database)))
        self.assertTrue(self.request.exists(), "request disappeared before dump completion")
        self.events.append("cleanup")
        self.archive.unlink(missing_ok=True)
        return True

    @contextlib.contextmanager
    def runtime(self, chown=None, modules=None, env=None):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(fleet, "Path", self.local_path))
            stack.enter_context(mock.patch.object(sys, "path", list(sys.path)))
            stack.enter_context(mock.patch.dict(sys.modules, self.modules if modules is None else modules))
            stack.enter_context(mock.patch.dict(os.environ, env or {}, clear=True))
            stack.enter_context(mock.patch.object(subprocess, "run", side_effect=chown or self.chown))
            stack.enter_context(contextlib.redirect_stdout(self.output))
            yield

    def assert_identity_retained(self):
        for path, expected in self.identities.items():
            self.assertEqual(path.read_bytes(), expected, str(path))

    def test_requested_dump_uses_restored_identity_and_original_global_config(self):
        with self.runtime(env={"MYTONCTRL_ARGS": "--telemetry --dump", "DUMP": "false"}):
            fleet.restore_bootstrap()
        self.assertEqual(self.parser.call_args.args[1], self.args)
        self.assertEqual(self.parsed_env["MYTONCTRL_ARGS"], "--telemetry --dump")
        self.assertEqual(self.events, ["download", "extract", "ownership", "cleanup"])
        self.assertFalse(self.request.exists())
        self.assertFalse(self.archive.exists())
        self.assertIn("Blockchain dump imported", self.output.getvalue())
        self.assert_identity_retained()

    def test_no_request_needs_no_installer_imports_or_files(self):
        self.request.unlink()
        guarded_import = __import__

        def reject_installer(name, *args, **kwargs):
            if name.startswith(("mytonctrl_docker_args", "mytoninstaller")):
                raise AssertionError("normal pod startup imported the recovery installer")
            return guarded_import(name, *args, **kwargs)

        with self.runtime(modules={}), mock.patch("builtins.__import__", side_effect=reject_installer):
            fleet.restore_bootstrap()
        self.assertFalse((self.state / ".container.lock").exists())
        self.assertEqual(self.events, [])
        self.assert_identity_retained()

    def test_resolved_environment_can_request_dump_without_explicit_args(self):
        self.args = []
        self.write_request()
        with self.runtime(env={"MYTONCTRL_ARGS": "-m validator -n mainnet -d"}):
            fleet.restore_bootstrap()
        self.assertEqual(self.parser.call_args.args[1], [])
        self.assertEqual(self.parsed_env["MYTONCTRL_ARGS"], "-m validator -n mainnet -d")
        self.assertIn("extract", self.events)

    def test_no_dump_does_not_import_downloader_or_change_database(self):
        self.resolved_env["DUMP"] = "false"
        modules = {"mytonctrl_docker_args": self.parser_module, "mytoninstaller": None,
                   "mytoninstaller.dump": None}
        with self.runtime(modules=modules):
            fleet.restore_bootstrap()
        self.assertFalse(self.request.exists())
        self.assertEqual(self.events, [])
        self.assertTrue(self.archive.exists())
        self.assertIn("synchronizing normally", self.output.getvalue())
        self.assert_identity_retained()

    def test_failed_import_keeps_request_and_cache_for_retry(self):
        original_request = self.request.read_bytes()
        self.download_result = False
        with self.runtime(), self.assertRaisesRegex(ValueError, "import failed"):
            fleet.restore_bootstrap()
        self.assertEqual(self.request.read_bytes(), original_request)
        self.assertTrue(self.archive.exists())
        self.assertEqual(self.events, ["download"])
        self.assert_identity_retained()
        self.download_result = True
        with self.runtime():
            fleet.restore_bootstrap()
        self.assertFalse(self.request.exists())
        self.assertEqual(self.events, ["download", "download", "extract", "ownership", "cleanup"])
        self.assert_identity_retained()

    def test_failed_ownership_keeps_successful_import_for_resume(self):
        def reject_ownership(*args, **kwargs):
            raise subprocess.CalledProcessError(1, args[0])

        with self.runtime(chown=reject_ownership), self.assertRaises(subprocess.CalledProcessError):
            fleet.restore_bootstrap()
        self.assertTrue(self.request.exists())
        self.assertTrue(self.archive.exists())
        self.assertTrue((self.database / "celldb/fixture").is_file())
        self.assertEqual(self.events, ["download", "extract"])
        with self.runtime():
            fleet.restore_bootstrap()
        self.assertEqual(self.events, ["download", "extract", "download", "resume", "ownership", "cleanup"])
        self.assertFalse(self.request.exists())
        self.assert_identity_retained()

    def test_cleanup_exception_preserves_request_and_identity(self):
        self.dump_module.cleanup_completed_dump.side_effect = OSError("cache unavailable")
        with self.runtime(), self.assertRaisesRegex(OSError, "cache unavailable"):
            fleet.restore_bootstrap()
        self.assertTrue(self.request.exists())
        self.assertTrue(self.archive.exists())
        self.assert_identity_retained()

    def test_completed_request_is_acknowledged_durably_and_next_startup_is_noop(self):
        original_fsync = os.fsync

        def commit_acknowledgement(descriptor):
            self.assertFalse(self.request.exists())
            self.assertEqual(self.events[-1], "cleanup")
            self.assertEqual(os.fstat(descriptor).st_ino, self.bundle.stat().st_ino)
            original_fsync(descriptor)

        with self.runtime(), mock.patch.object(os, "fsync", side_effect=commit_acknowledgement) as sync:
            fleet.restore_bootstrap()
        sync.assert_called_once()
        first_events = list(self.events)
        self.parser.reset_mock()
        with self.runtime():
            fleet.restore_bootstrap()
        self.parser.assert_not_called()
        self.assertEqual(self.events, first_events)
        self.assert_identity_retained()

    def test_startup_is_serialized_with_the_normal_entrypoint(self):
        with (self.state / ".container.lock").open("a") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.runtime(), self.assertRaises(BlockingIOError):
                fleet.restore_bootstrap()
        self.assertTrue(self.request.exists())
        self.assertEqual(self.events, [])
        self.assert_identity_retained()

    def test_missing_restored_files_never_starts_dump_import(self):
        for relative in ("controller/initialized.json", "db/config.json", "controller/global.config.json"):
            with self.subTest(missing=relative):
                path = self.work / relative
                saved = path.read_bytes()
                path.unlink()
                with self.runtime(), self.assertRaisesRegex(ValueError, "restored|restore"):
                    fleet.restore_bootstrap()
                path.write_bytes(saved)
                self.assertTrue(self.request.exists())
                self.assertEqual(self.events, [])
        self.assert_identity_retained()

    def test_unsupported_work_directory_preserves_request(self):
        self.resolved_env["TON_WORK_DIR"] = "/var/other-work"
        with self.runtime(), self.assertRaisesRegex(ValueError, "work directory"):
            fleet.restore_bootstrap()
        self.assertTrue(self.request.exists())
        self.assertEqual(self.events, [])
        self.assert_identity_retained()

    def test_invalid_dump_option_preserves_request(self):
        self.resolved_env["DUMP"] = "perhaps"
        with self.runtime(), self.assertRaisesRegex(ValueError, "DUMP"):
            fleet.restore_bootstrap()
        self.assertTrue(self.request.exists())
        self.assertEqual(self.events, [])
        self.assert_identity_retained()

    def test_invalid_request_is_rejected_before_parsing_or_import(self):
        for value in ([], {"version": True, "args": []}, {"version": 2, "args": []},
                      {"version": 1, "args": "-d"}, {"version": 1, "args": ["-d", None]},
                      {"version": 1}):
            with self.subTest(request=value):
                self.write_request(value)
                with self.runtime(), self.assertRaisesRegex(ValueError, "invalid.*request"):
                    fleet.restore_bootstrap()
                self.assertTrue(self.request.exists())
                self.parser.assert_not_called()
                self.assertEqual(self.events, [])
        self.assert_identity_retained()


if __name__ == "__main__":
    unittest.main()
