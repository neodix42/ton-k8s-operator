#!/usr/bin/env python3
"""Installer and tools-pod transport tests; never contact a real cluster."""
import io
import json
import os
import pty
import select
import signal
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
CHART = REPO / "charts/ton-k8s-operator"
PASSPHRASE = "hidden test recovery phrase"

MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
root=pathlib.Path(os.environ['TOOLS_TEST_ROOT'])
args=sys.argv[1:]
with (root/'events').open('a') as out: out.write(json.dumps([pathlib.Path(sys.argv[0]).name,*args])+'\n')
tool=pathlib.Path(sys.argv[0]).name
if tool=='helm':
    shutil.copyfile(root/'chart.tgz',pathlib.Path.cwd()/'ton-k8s-operator-0.3.4.tgz')
elif tool=='curl':
    asset=args[1].rsplit('/',1)[-1]
    if os.environ.get('TOOLS_TEST_FAIL')==asset: sys.exit(1)
    shutil.copyfile(root/'assets'/asset,args[args.index('-o')+1])
elif tool=='kubectl':
    if args[:1]==['-n']: args=args[2:]
    if args[:3]==['create','-f','-']:
        body=sys.stdin.read()
        with (root/'manifests').open('a') as out: out.write(body+'\n')
    elif args[:1]==['cp'] and ':/work/backup/.' in args[1]:
        shutil.copytree(root/'backup',args[2],dirs_exist_ok=True)
    elif args[:1]==['exec']:
        if 'main "$@"' in ' '.join(args):
            assert sys.stdin.read().strip()==os.environ['TOOLS_TEST_PASSPHRASE']
            if os.environ.get('TOOLS_TEST_FAIL')=='remote': sys.exit(17)
            print('remote operation complete')
        elif '-i' in args: sys.stdin.buffer.read()
'''


class FleetToolsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        bindir = self.root / "bin"
        bindir.mkdir()
        for name in ("kubectl", "helm", "curl"):
            path = bindir / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ, TOOLS_TEST_ROOT=str(self.root), TOOLS_TEST_PASSPHRASE=PASSPHRASE,
                        KUBETON_FLEET_RUNTIME="pod", KUBETON_FLEET_PASSPHRASE_FD="0",
                        PATH=str(bindir)+":"+os.environ["PATH"])
        assets = self.root / "assets"
        assets.mkdir()
        for name in ("kubeton", "main-wallet.sh", "fleet.sh", "fleet.py", "fleet-crypto.sh"):
            (assets / name).write_bytes((CHART / name).read_bytes())
        with tarfile.open(self.root / "chart.tgz", "w:gz") as archive:
            for name, value in (("Chart.yaml", b"version: 0.3.4\n"),
                                ("operator-values.yaml", b"replicaCount: 1\n"),
                                ("tonnode-values.yaml", b"tonNode: {}\n"),
                                ("kubeton", b"old chart client\n")):
                member = tarfile.TarInfo("ton-k8s-operator/"+name)
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
        (self.root / "backup").mkdir()
        for name in ("fleet.json", "recovery.gpg"):
            (self.root / "backup" / name).write_text("encrypted fixture\n")

    def command(self, *args, fail=""):
        result = subprocess.run(["bash", "-c", 'source "$1/kubeton"; shift; confirm_or_exit() { :; }; main "$@"',
                                 "_", str(CHART), *args], input=PASSPHRASE+"\n", text=True,
                                capture_output=True, env=dict(self.env, TOOLS_TEST_FAIL=fail),
                                cwd=self.root, timeout=10)
        self.assertNotIn(PASSPHRASE, result.stdout+result.stderr)
        if (self.root / "events").exists():
            self.assertNotIn(PASSPHRASE, (self.root / "events").read_text())
        if (self.root / "manifests").exists():
            self.assertNotIn(PASSPHRASE, (self.root / "manifests").read_text())
        return result

    def test_installer_fetches_cli_and_every_helper_from_release(self):
        destination = self.root / "installed"
        result = subprocess.run(["bash", str(REPO / "install.sh")], capture_output=True, text=True,
                                cwd=self.root, env=dict(self.env, INSTALL_DIR=str(destination)), timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        for name in ("kubeton", "main-wallet.sh", "fleet.sh", "fleet.py", "fleet-crypto.sh"):
            self.assertEqual((destination / name).read_bytes(), (CHART / name).read_bytes())
        self.assertTrue(os.access(destination / "kubeton", os.X_OK))
        self.assertTrue(os.access(destination / "main-wallet.sh", os.X_OK))
        self.assertFalse(list(destination.glob("*.download")))

    def test_installer_reports_missing_release_asset(self):
        for missing in ("fleet.py", "main-wallet.sh"):
            with self.subTest(missing=missing):
                result = subprocess.run(["bash", str(REPO / "install.sh")], capture_output=True, text=True,
                                        cwd=self.root, env=dict(self.env, INSTALL_DIR=str(self.root / ("installed-" + missing)),
                                                               TOOLS_TEST_FAIL=missing), timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Done. Chart version", result.stdout)

    def test_backup_uses_tools_image_and_downloads_private_local_directory(self):
        output = self.root / "export"
        result = self.command("backup-fleet", str(output))
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue((output / "recovery.gpg").exists())
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        manifests = (self.root / "manifests").read_text()
        self.assertIn("kind: ClusterRole", manifests)
        self.assertIn("ton-k8s-operator:fleet-tools-0.3.4", manifests)
        self.assertIn("medium: Memory", manifests)
        events = (self.root / "events").read_text()
        self.assertIn('"delete", "clusterrolebinding"', events)
        self.assertIn('"delete", "serviceaccount"', events)

    def test_backup_default_output_directory(self):
        result = self.command("backup-fleet")
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(len(list((self.root / "fleet-backups").glob("*/recovery.gpg"))), 1)

    def test_restore_uses_temporary_admin_binding_and_forwards_options(self):
        result = self.command("restore-fleet", str(self.root / "backup"), "--storage-class", "new-local", "--bootstrap")
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        events = (self.root / "events").read_text()
        self.assertIn("--clusterrole=cluster-admin", events)
        self.assertIn('"--storage-class", "new-local"', events)
        self.assertIn('"--bootstrap"', events)
        self.assertIn('"delete", "clusterrolebinding"', events)

    def test_remote_failure_does_not_publish_backup_and_removes_rbac(self):
        output = self.root / "failed"
        result = self.command("backup-fleet", str(output), fail="remote")
        self.assertEqual(result.returncode, 17, result.stdout+result.stderr)
        self.assertFalse(output.exists())
        self.assertIn('"delete", "clusterrolebinding"', (self.root / "events").read_text())

    def test_existing_backup_refused_before_cluster_writes(self):
        result = self.command("backup-fleet", str(self.root / "backup"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "events").exists())

    def test_interactive_passphrase_is_hidden_and_confirmed(self):
        for confirmation, expected_rc in ((PASSPHRASE, 0), ("different recovery phrase", 1)):
            with self.subTest(matching=expected_rc == 0):
                pid, terminal = pty.fork()
                if pid == 0:
                    env = dict(self.env)
                    env.pop("KUBETON_FLEET_PASSPHRASE_FD", None)
                    os.execve("/bin/bash", ["bash", "-c", 'source "$1/kubeton"; source "$1/fleet.sh"; passphrase_file=""; fleet_passphrase=""; fleet_prompt_passphrase backup',
                                           "_", str(CHART)], env)
                output = b""
                stage = 0
                deadline = time.monotonic() + 10
                try:
                    while time.monotonic() < deadline:
                        if not select.select([terminal], [], [], 0.1)[0]:
                            continue
                        try:
                            data = os.read(terminal, 4096)
                        except OSError:
                            break
                        if not data:
                            break
                        output += data
                        if stage == 0 and b"Fleet recovery passphrase:" in output:
                            os.write(terminal, (PASSPHRASE+"\n").encode())
                            stage = 1
                        elif stage == 1 and b"Confirm recovery passphrase:" in output:
                            os.write(terminal, (confirmation+"\n").encode())
                            stage = 2
                    else:
                        os.kill(pid, signal.SIGKILL)
                        self.fail("interactive passphrase prompt timed out")
                finally:
                    os.close(terminal)
                    _, status = os.waitpid(pid, 0)
                self.assertEqual(os.waitstatus_to_exitcode(status), expected_rc, output.decode())
                self.assertNotIn(PASSPHRASE.encode(), output)
                self.assertNotIn(confirmation.encode(), output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
