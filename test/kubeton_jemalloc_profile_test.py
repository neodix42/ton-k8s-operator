#!/usr/bin/env python3
"""Exercise profiling startup, retention and shutdown without a cluster."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "charts/ton-k8s-operator/jemalloc-profile.py"
SPEC = importlib.util.spec_from_file_location("kubeton_jemalloc_profile", SCRIPT)
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)


class JemallocProfileTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kubeton-jemalloc-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "diagnostics"
        self.binary = self.directory / "artifacts/bin/validator-engine"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if sys.argv[1:] != ['--version']:
    raise SystemExit(2)
options = dict(item.split(':', 1) for item in os.environ['MALLOC_CONF'].split(','))
if options.get('prof') == 'true' and options.get('prof_final') == 'true':
    Path(options['prof_prefix'] + '.123.0.f.heap').write_bytes(b'heap_v2/524288\\n')
print('synthetic validator build information')
""")
        self.binary.chmod(0o755)
        (self.binary.parent.parent / "image-ref").write_text("example/ton@sha256:synthetic\n")

    def session(self):
        session, lock = PROFILE.create_session(self.binary, self.root)
        self.addCleanup(lock.close)
        return session, lock

    def test_probe_requires_a_real_profile_not_only_successful_version_output(self):
        PROFILE.probe(self.binary)
        self.binary.write_text("#!/usr/bin/env python3\nprint('validator version: no profiling support')\n")
        with self.assertRaisesRegex(RuntimeError, "did not produce a jemalloc profile"):
            PROFILE.probe(self.binary)

    def test_probe_rejects_failed_process_even_if_it_wrote_a_profile(self):
        with self.binary.open("a") as stream:
            stream.write("raise SystemExit(3)\n")
        with self.assertRaises(RuntimeError):
            PROFILE.probe(self.binary)

    def test_probe_rejects_non_profile_output(self):
        text = self.binary.read_text().replace("b'heap_v2/524288\\n'", "b'not a heap profile\\n'")
        self.binary.write_text(text)
        with self.assertRaises(RuntimeError):
            PROFILE.probe(self.binary)

    def test_session_saves_exact_binary_identity_with_private_permissions(self):
        with mock.patch.dict(os.environ, {"VAULT_TOKEN": "must-never-appear-in-metadata"}):
            session, _ = self.session()
        self.assertEqual((session / "validator-engine").read_bytes(), self.binary.read_bytes())
        metadata = json.loads((session / "metadata.json").read_text())
        self.assertEqual(metadata["binarySHA256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(metadata["tonImage"], "example/ton@sha256:synthetic")
        self.assertNotIn("must-never-appear", json.dumps(metadata))
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(session.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((session / "validator-engine").stat().st_mode), 0o500)

    def test_sessions_remain_unique_across_fast_restarts(self):
        first, _ = self.session()
        second, _ = self.session()
        self.assertNotEqual(first, second)

    def test_symlinked_diagnostic_root_is_rejected(self):
        outside = self.directory / "outside"
        outside.mkdir()
        self.root.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "cannot be a symlink"):
            self.session()
        self.assertEqual(list(outside.iterdir()), [])

    def test_retention_keeps_newest_profiles_across_restart_sessions(self):
        old, old_lock = self.session()
        current, _ = self.session()
        old_lock.close()
        for index, session in enumerate((old, old, current, current)):
            profile = session / f"validator.{index}.0.i0.heap"
            profile.write_bytes(b"heap_v2/524288\n")
            os.utime(profile, ns=(index + 1, index + 1))
        PROFILE.prune_sessions(self.root, current, 2)
        self.assertFalse(old.exists(), "inactive session with no remaining profiles must be removed")
        self.assertEqual(sorted(p.name for p in current.glob("*.heap")),
                         ["validator.2.0.i0.heap", "validator.3.0.i0.heap"])
        self.assertTrue((current / "validator-engine").exists())

    def test_retention_preserves_active_sessions_unmanaged_files_and_symlink_targets(self):
        active, _ = self.session()
        current, _ = self.session()
        outside = self.directory / "unrelated.heap"
        outside.write_text("do not remove")
        (current / "validator.external.heap").symlink_to(outside)
        unrelated = self.root / "user-created-diagnostics"
        unrelated.mkdir()
        (unrelated / "keep").write_text("user data")
        PROFILE.prune_sessions(self.root, current, 2)
        self.assertTrue(active.exists(), "another live wrapper holds its session lock")
        self.assertEqual(outside.read_text(), "do not remove")
        self.assertEqual((unrelated / "keep").read_text(), "user data")

    def snapshot_with_cgroup(self, files):
        session, _ = self.session()
        original_read = Path.read_text

        def read(path, *args, **kwargs):
            if str(path).startswith("/sys/fs/cgroup/"):
                if str(path) not in files:
                    raise FileNotFoundError(str(path))
                return files[str(path)]
            return original_read(path, *args, **kwargs)

        with mock.patch.object(Path, "read_text", read):
            PROFILE.snapshot_memory(session)
        return json.loads((session / "memory.json").read_text())

    def test_cgroup_v2_snapshot_records_memory_and_oom_counters(self):
        values = self.snapshot_with_cgroup({
            "/sys/fs/cgroup/memory.current": "12345\n",
            "/sys/fs/cgroup/memory.max": "max\n",
            "/sys/fs/cgroup/memory.events": "oom 1\noom_kill 1\n",
            "/sys/fs/cgroup/memory.stat": "anon 10000\nfile 2345\n",
        })
        self.assertEqual(values["current"], "12345")
        self.assertEqual(values["limit"], "max")
        self.assertIn("oom_kill 1", values["events"])
        self.assertIn("file 2345", values["stat"])

    def test_cgroup_v1_snapshot_and_unavailable_counters(self):
        values = self.snapshot_with_cgroup({
            "/sys/fs/cgroup/memory/memory.usage_in_bytes": "12345\n",
            "/sys/fs/cgroup/memory/memory.limit_in_bytes": "65536\n",
            "/sys/fs/cgroup/memory/memory.failcnt": "4\n",
        })
        self.assertEqual(values["current"], "12345")
        self.assertEqual(values["limit"], "65536")
        self.assertEqual(values["events"], "4")
        self.assertEqual(values["stat"], "unavailable")

    def test_wrapper_passes_managed_configuration_and_preserves_child_exit_status(self):
        output = self.directory / "child-env.json"
        command = [sys.executable, "-c", "import json,os,sys; "
                   "open(sys.argv[1],'w').write(json.dumps({'malloc':os.environ['MALLOC_CONF']})); "
                   "sys.exit(7)", str(output)]
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            with mock.patch.dict(os.environ, {"MALLOC_CONF": "prof:false"}):
                self.assertEqual(PROFILE.run(command, 20, 31, 4, self.root, self.binary), 7)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
        config = json.loads(output.read_text())["malloc"]
        self.assertIn("prof:true", config)
        self.assertIn("lg_prof_sample:20", config)
        self.assertIn("lg_prof_interval:31", config)
        self.assertIn("prof_final:false", config)
        session = next(self.root.iterdir())
        self.assertTrue((session / "memory.json").exists())

    def test_wrapper_forwards_termination_and_retains_already_written_profile(self):
        ready = self.directory / "child-ready"
        child = ("import os,pathlib,signal,sys,time; "
                 "signal.signal(signal.SIGTERM,lambda *_:sys.exit(23)); "
                 "prefix=dict(x.split(':',1) for x in os.environ['MALLOC_CONF'].split(','))['prof_prefix']; "
                 "pathlib.Path(prefix+'.100.0.i0.heap').write_bytes(b'heap_v2/524288\\n'); "
                 "pathlib.Path(sys.argv[1]).touch(); time.sleep(30)")
        driver = ("import importlib.util,pathlib,sys; "
                  "sys.dont_write_bytecode=True; "
                  "s=importlib.util.spec_from_file_location('profile',sys.argv[1]); "
                  "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                  "m.POLL_SECONDS=.05; "
                  "sys.exit(m.run([sys.executable,'-c',sys.argv[4],sys.argv[5]],19,34,8,"
                  "pathlib.Path(sys.argv[2]),pathlib.Path(sys.argv[3])))")
        process = subprocess.Popen([sys.executable, "-c", driver, str(SCRIPT), str(self.root),
                                    str(self.binary), child, str(ready)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "child did not finish initialization")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 23, stdout + stderr)
            profiles = list(self.root.glob("*/validator.*.heap"))
            self.assertEqual(len(profiles), 1)
            self.assertTrue(profiles[0].read_bytes().startswith(b"heap_v2/"))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
