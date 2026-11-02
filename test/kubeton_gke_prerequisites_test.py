#!/usr/bin/env python3
"""GKE host setup without Kubernetes access or changes to the test host."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


KUBETON = Path(__file__).resolve().parents[1] / "charts/ton-k8s-operator/kubeton"

FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE"])
args = sys.argv[1:]
with (root / "calls").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
mode = os.environ.get("MODE", "ubuntu")
if args[:2] == ["get", "nodes"]:
    if mode == "denied": sys.exit(23)
    if mode == "baremetal": sys.exit(0)
    if args[-1] == "name":
        print("node/worker-1")
    else:
        selector = args[args.index("-l") + 1]
        if "pool=storage" in selector:
            image = {"cos":"Container-Optimized OS from Google", "unsupported":"Flatcar"}.get(mode, "Ubuntu 24.04.3 LTS")
            print("worker-1|gce://project/zone/worker-1|" + image)
        else:
            print("worker-2|gce://project/zone/worker-2|Ubuntu 24.04.3 LTS")
elif args[:2] == ["apply", "-f"]:
    (root / "manifest.json").write_text(sys.stdin.read())
    if mode == "apply-failed": sys.exit(23)
elif "rollout" in args:
    if mode == "not-ready": sys.exit(23)
elif "get" in args and "daemonset" in args:
    print("0|0|1|1" if mode == "zero-coverage" else "2|2|1|1")
elif "logs" in args:
    print("fixture worker dependency failure")
else:
    sys.exit("Unexpected kubectl: " + repr(args))
'''

FAKE_HOST_COMMAND = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["FIXTURE"])
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "host-calls").open("a") as stream:
    stream.write(json.dumps([command] + args) + "\n")
if command == "chroot":
    args = args[1:]
    if args[:2] == ["mkdir", "-p"]:
        (root / "host" / args[2].lstrip("/")).mkdir(parents=True, exist_ok=True)
        sys.exit(0)
    if args[:2] == ["/bin/bash", "-ec"]:
        # Execute the actual Ubuntu setup body with fake tools; redirect its
        # modules-load write into the fixture rather than the test host /etc.
        script = args[2].replace("/etc/modules-load.d/kubeton-longhorn.conf", str(root / "modules.conf"))
        sys.exit(subprocess.run(["bash", "-ec", script]).returncode)
    sys.exit(subprocess.run(args).returncode)
if command == "dpkg-query":
    assert args[1] == "-f=${Status}", args
    if os.environ.get("PACKAGES_INSTALLED") == "true": print("install ok installed", end="")
    else: sys.exit(1)
elif command == "apt-get":
    if os.environ.get("MODE") == "apt-failed": sys.exit(23)
elif command == "modprobe":
    if os.environ.get("MODE") == "module-failed": sys.exit(23)
    (root / "host/sys/module" / args[0]).mkdir(parents=True, exist_ok=True)
elif command == "nsenter":
    args = args[args.index("--") + 1:]
    if args[0] == "findmnt": sys.exit(1)
    if args[0] == "modprobe": sys.exit(subprocess.run(args).returncode)
elif command == "pgrep":
    sys.exit(0 if (root / "iscsid").exists() else 1)
elif command == "iscsid":
    (root / "iscsid").touch()
elif command == "systemctl":
    if args[:2] == ["enable", "--now"]: (root / "iscsid").touch()
    else: sys.exit(0 if (root / "iscsid").exists() else 1)
'''


class GkePrerequisitesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, FIXTURE=str(self.root),
                        PATH=str(self.bin) + ":" + os.environ["PATH"],
                        HOST_ROOT=str(self.root / "host"), READY_FILE=str(self.root / "ready"))
        self.write_executable("kubectl", FAKE_KUBECTL)

    def write_executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def shell(self, body, **env):
        return subprocess.run(["bash", "-euo", "pipefail", "-c", 'source "$1"\n' + body,
                               "_", str(KUBETON)], env=dict(self.env, **env),
                              text=True, capture_output=True, timeout=15)

    def prepare(self, **env):
        return self.shell('''
LONGHORN_NODE_SELECTOR=pool=storage
KUBETON_NODE_CHECK_TON_SELECTOR=pool=ton
ensure_namespace() { :; }
ensure_namespace_not_terminating() { :; }
ensure_gke_longhorn_prerequisites
printf "PBKDF=%s\\n" "$KUBETON_LONGHORN_CRYPTO_PBKDF"
''', **env)

    def test_selected_storage_and_mount_workers_are_prepared(self):
        for mode, pbkdf in (("ubuntu", "argon2i"), ("cos", "pbkdf2")):
            with self.subTest(mode=mode):
                result = self.prepare(MODE=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PBKDF=" + pbkdf, result.stdout)
                manifest = json.loads((self.root / "manifest.json").read_text())
                config, ds = manifest["items"]
                subprocess.run(["bash", "-n"], input=config["data"]["entrypoint.sh"], text=True, check=True)
                spec = ds["spec"]["template"]["spec"]
                affinity = spec["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
                names = affinity["nodeSelectorTerms"][0]["matchFields"][0]["values"]
                self.assertEqual(set(names), {"worker-1", "worker-2"})
                self.assertNotIn("nodeSelector", spec)  # Exact bounded name affinity, not all GKE nodes.
                self.assertFalse(spec["automountServiceAccountToken"])
                self.assertTrue(spec["hostPID"])
                self.assertTrue(spec["containers"][0]["securityContext"]["privileged"])

    def test_api_and_apply_failures_and_missing_coverage_stop_bootstrap(self):
        for mode in ("denied", "unsupported", "apply-failed", "not-ready", "zero-coverage"):
            with self.subTest(mode=mode):
                result = self.prepare(MODE=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("PBKDF=", result.stdout)

    def test_other_platforms_and_unselected_nodes_are_not_modified(self):
        result = self.prepare(MODE="baremetal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "manifest.json").exists())
        result = self.shell('''
LONGHORN_NODE_SELECTOR=""
KUBETON_NODE_CHECK_TON_SELECTOR=""
ensure_gke_longhorn_prerequisites
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "manifest.json").exists())

    def test_new_cos_secret_and_existing_secret_preservation(self):
        for existing in (False, True):
            result = self.shell('''
KUBETON_LONGHORN_CRYPTO_PBKDF=pbkdf2
kubectl() {
  if [[ "$*" == *"get secret"* ]]; then [[ "$EXISTING" == true ]]; return; fi
  [[ "$*" == *"CRYPTO_PBKDF=pbkdf2"* ]] || return 23
  printf created
}
ensure_longhorn_crypto_secret
''', EXISTING=str(existing).lower())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("Creating Longhorn encryption secret" in result.stdout, not existing)

    def test_actual_host_script_handles_packages_services_and_failures(self):
        script = self.shell("gke_longhorn_prerequisite_script").stdout
        path = self.root / "entrypoint.sh"
        path.write_text(script.replace("/sbin/iscsid", str(self.bin / "iscsid")))
        host_etc = self.root / "host/etc"
        host_etc.mkdir(parents=True)
        for command in ("chroot", "dpkg-query", "apt-get", "modprobe", "systemctl", "iscsiadm",
                        "cryptsetup", "nsenter", "pgrep", "zypper", "iscsid", "sleep"):
            self.write_executable(command, FAKE_HOST_COMMAND)
        for distro in ("ubuntu", "cos"):
            with self.subTest(distro=distro):
                if (self.root / "iscsid").exists():
                    (self.root / "iscsid").unlink()
                (host_etc / "os-release").write_text('ID="' + distro + '"\n')
                result = subprocess.run(["bash", str(path)], env=self.env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = subprocess.run(["bash", str(path), "check"], env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / "host-calls").read_text().splitlines()]
        self.assertIn(["apt-get", "install", "-y", "open-iscsi", "cryptsetup", "dmsetup", "nfs-common"], calls)
        (host_etc / "os-release").write_text("ID=ubuntu\n")
        (self.root / "host-calls").unlink()
        result = subprocess.run(["bash", str(path)], env=dict(self.env, PACKAGES_INSTALLED="true"), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / "host-calls").read_text().splitlines()]
        self.assertFalse(any(call[0] == "apt-get" for call in calls))
        result = subprocess.run(["bash", str(path)], env=dict(self.env, MODE="apt-failed"), capture_output=True)
        self.assertEqual(result.returncode, 23)
        result = subprocess.run(["bash", str(path)], env=dict(self.env, MODE="module-failed", PACKAGES_INSTALLED="true"), capture_output=True)
        self.assertEqual(result.returncode, 23)


if __name__ == "__main__":
    unittest.main(verbosity=2)
