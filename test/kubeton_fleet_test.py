#!/usr/bin/env python3
"""Fleet portability and failure-path tests. No Kubernetes cluster is contacted."""

import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True
CHART = Path(__file__).resolve().parents[1] / "charts/ton-k8s-operator"
MODULE = importlib.util.spec_from_file_location("fleet", CHART / "fleet.py")
fleet = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(fleet)
KEY = base64.b64encode(bytes(range(48))).decode()


MOCK_KUBECTL = r'''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
root = pathlib.Path(os.environ['FAKE_STATE'])
state_file = root / 'state.json'
state = json.loads(state_file.read_text())
args = sys.argv[1:]
with (root / 'events').open('a') as stream:
    stream.write(json.dumps(args) + '\n')
ns = ''
if args[:1] == ['-n']:
    ns, args = args[1], args[2:]
op = args[0]
mode = os.environ.get('FAKE_MODE', '')
def save(): state_file.write_text(json.dumps(state))
def template(name):
    cr = state['fleets'][ns + '/' + name]
    spec = cr['spec']
    keys = spec['keyManagement']
    claims = []
    for claim in ('ton-work','ton-src','mytoncore','mytonctrl','keybundle'):
        claims.append({'metadata':{'name':claim},'spec':{'accessModes':['ReadWriteOnce'],
          'storageClassName': keys['encryptedBundle']['storageClassName'] if claim == 'keybundle' else spec['storage']['storageClassName'],
          'resources':{'requests':{'storage':'1Gi'}}}})
    env = [{'name': 'VAULT_TRANSIT_KEY','value':keys['vaultTransitKey']},
           {'name':'KEY_BUNDLE_FILE','value':keys['encryptedBundle'].get('fileName','keys.bundle.enc')},
           {'name':'KEY_BUNDLE_META_FILE','value':keys['encryptedBundle'].get('metaFileName','keys.bundle.meta')}]
    return {'metadata':cr['metadata'],'spec':{'volumeClaimTemplates':claims,'template':{'spec':{
      'nodeSelector':spec['nodeSelector'],'containers':[
      {'name':'key-backup','image':spec['image'],'env':env,'envFrom':[{'secretRef':keys['credentialsSecretRef']}]},
      {'name':'ton-node','resources':{'requests':{'cpu':'1','memory':'1Gi'}},
       'ports':[{'name':'validator-udp','containerPort':30001,'hostPort':30001,'protocol':'UDP'}]}]}}}}
if op == 'get':
    kind = args[1]
    if kind == 'tonnodes.ton.ton.org':
        if os.environ.get('SOURCE'):
            print((root / 'source.json').read_text())
        elif mode == 'existing-fleet': print('tonnode.ton.ton.org/occupied')
        else: print('\n'.join(state['fleets']))
    elif kind == 'crd':
        if mode == 'crd-error': sys.exit(1)
        if mode == 'existing-fleet': print('customresourcedefinition/tonnodes.ton.ton.org')
    elif kind == 'statefulsets': pass
    elif kind == 'statefulset':
        if os.environ.get('SOURCE'): print(2 if args[2] == 'alpha' else 1)
        elif args[-1] == 'json': print(json.dumps(template(args[2])))
        elif 'containerPort' in args[-1]: print('30001')
        else: print('statefulset/' + args[2])
    elif kind == 'pvc':
        if mode == 'existing-pvc': print('persistentvolumeclaim/' + args[2])
    elif kind in ('storageclass','secret','namespace'): print(kind + '/ready')
    elif kind == 'deploy': print('operator\t1')
    elif kind == 'node':
        if 'go-template' in args[-1]: print(args[2])
        else: print('203.0.113.' + args[2].split('-')[-1])
    elif kind == 'pods': pass
    elif kind == 'pod':
        if args[2] in state['helpers']:
            item = state['helpers'][args[2]]
            print(item['node'] if 'nodeName' in args[-1] else '198.51.100.100')
        else:
            ordinal = int(args[2].split('-')[-1])
            print(state['nodes'][ns + '/' + args[2].rsplit('-',1)[0]][ordinal])
    else: raise RuntimeError(args)
elif op == 'create':
    value = json.load(sys.stdin) if args[-1] == '-' else json.loads(pathlib.Path(args[-1]).read_text())
    objects = value['items'] if value['kind'] == 'List' else [value]
    for value in objects:
        kind = value['kind']
        metadata = value['metadata']
        if kind == 'TonNode':
            assert value['spec']['replicas'] == 0
            state['fleets'][metadata['namespace'] + '/' + metadata['name']] = value
        elif kind == 'Pod':
            ordinal = int(value['spec']['volumes'][0]['persistentVolumeClaim']['claimName'].rsplit('-',1)[-1])
            name = metadata['labels']['ton.ton.org/fleet-name']
            identity = metadata['namespace'] + '/' + name
            node = 'new-worker-' + str(10 + len(state['helpers']))
            state['helpers'][metadata['name']] = {'node':node, 'ordinal':ordinal}
            state['nodes'].setdefault(identity,[]).append(node)
            assert value['spec']['volumes'][-1]['emptyDir']['medium'] == 'Memory'
            assert value['spec']['containers'][0]['envFrom'][0]['secretRef']['name'] == 'ton-vault-creds'
            state['helper_objects'].append(value)
        elif kind == 'PersistentVolumeClaim': state['claims'].append(value)
        else: raise RuntimeError(kind)
    save()
elif op == 'exec':
    if args[-1] == 'unwrap':
        sys.stdin.read()
        if mode == 'unwrap-failure': sys.exit(1)
        print(os.environ['RECOVERY_KEY'])
    else:
        key = sys.stdin.read().strip()
        assert key == os.environ['RECOVERY_KEY']
        if mode in ('provider-failure', 'cleanup-failure'): sys.exit(1)
        state['staged'] += 1
        save()
elif op == 'patch':
    if args[1] == 'tonnodes.ton.ton.org':
        replicas = json.loads(args[-1])['spec']['replicas']
        if mode == 'cleanup-failure' and replicas == 0: sys.exit(1)
        if replicas:
            assert state['staged'] == 3, 'started TON before all identities were staged'
            assert not state['helpers'], 'started TON with staging volumes still mounted'
        state['fleets'][ns + '/' + args[2]]['spec']['replicas'] = replicas
        save()
elif op == 'delete':
    state['helpers'].pop(args[2], None)
    save()
elif op == 'scale':
    if mode == 'pause-failure' and args[1] == 'deployment' and args[-1] == '--replicas=0':
        sys.exit(1)
    if mode == 'resume-failure' and args[1] == 'deployment' and args[-1] == '--replicas=1':
        sys.exit(1)
elif op in ('cp','rollout','wait','apply'): pass
else: raise RuntimeError(args)
'''


class FleetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backup = self.root / "backup"
        self.backup.mkdir()
        self.passphrase = self.root / "passphrase"
        self.passphrase.write_text("fleet test passphrase\n")
        self.home = self.root / "gnupg"
        self.home.mkdir(mode=0o700)
        self.env = dict(os.environ, GNUPGHOME=str(self.home), RECOVERY_KEY=KEY,
                        KUBETON_LAUNCH_LOGS_ENABLED="false")
        spec = {"replicas": 2, "image": "example/mytonctrl:1", "tonImage": "example/ton:1",
                "storage": {"storageClassName": "old-disk"},
                "nodeSelector": {"kubernetes.io/hostname": "old-worker"},
                "network": {"publicIP": "192.0.2.99", "validatorPort": 30001},
                "env": [{"name": "PUBLIC_IP", "value": "192.0.2.99"}],
                "keyManagement": {"enabled": True, "provider": "vault", "vaultTransitKey": "old-transit",
                                  "credentialsSecretRef": {"name": "old-creds"}, "encryptedBundle": {}}}
        second = copy.deepcopy(spec)
        second["replicas"] = 1
        second["keyManagement"]["encryptedBundle"] = {"fileName": "custom.enc", "metaFileName": "custom.meta"}
        self.manifest = {"format": "kubeton-fleet", "version": 1, "fleets": [
            {"namespace": "default", "name": "alpha", "spec": spec},
            {"namespace": "other", "name": "beta", "spec": second}]}
        files = {}
        for ns, name, ordinal, enc, meta in fleet.entries(self.manifest):
            directory = self.backup / ns / name / ordinal / "bundle"
            directory.mkdir(parents=True)
            for filename, data in ((enc, b"encrypted payload"), (meta, b"wrapped_key=vault:v1:old\n")):
                path = directory / filename
                path.write_bytes(data)
                files[str(path.relative_to(self.backup))] = fleet.digest(path)
        self.manifest["files"] = files
        fleet.write_json(self.backup / "fleet.json", self.manifest)
        recovery = "kubeton-fleet-v1\t" + fleet.digest(self.backup / "fleet.json") + "\n"
        recovery += "".join("/".join(row[:3]) + "\t" + KEY + "\n" for row in fleet.entries(self.manifest))
        self.gpg("--symmetric", "--cipher-algo", "AES256", "--output", str(self.backup / "recovery.gpg"), input=recovery)
        self.state = self.root / "mock"
        self.state.mkdir()
        (self.state / "state.json").write_text(json.dumps({"fleets": {}, "claims": [], "helpers": {},
                                                        "helper_objects": [], "nodes": {}, "staged": 0}))
        (self.state / "source.json").write_text(json.dumps({"items": [
            {"metadata": {"namespace": item["namespace"], "name": item["name"]}, "spec": item["spec"]}
            for item in self.manifest["fleets"]]}))
        bindir = self.root / "bin"
        bindir.mkdir()
        for name, script in (("kubectl", MOCK_KUBECTL), ("helm", "#!/bin/sh\nexit 0\n")):
            path = bindir / name
            path.write_text(script)
            path.chmod(0o755)
        self.env.update(FAKE_STATE=str(self.state), PATH=str(bindir) + ":" + self.env["PATH"])

    def gpg(self, *args, input=None):
        return subprocess.run(["gpg", "--no-options", "--batch", "--yes", "--pinentry-mode", "loopback",
                               "--no-symkey-cache", "--passphrase-file", str(self.passphrase), *args],
                              input=input, text=True, capture_output=True, env=self.env, check=True)

    def cli(self, *args, mode="", source=False):
        env = dict(self.env, FAKE_MODE=mode)
        if source:
            env.update(SOURCE="true", FIXTURE=str(self.backup))
        script = r'''
source "$1/kubeton"
shift
confirm_or_exit() { :; }
run_backup_keys() { cp -R "$FIXTURE"/. "$1/"; }
ensure_auto_bootstrap_stack() { printf 'bootstrap\n' >> "$FAKE_STATE/events"; }
initialize_and_unseal_vault() { printf 'mock-root-token'; }
configure_vault_for_ton() { printf 'credentials %s\n' "$TON_NAMESPACE" >> "$FAKE_STATE/events"; }
main "$@"
'''
        return subprocess.run(["bash", "-c", script, "_", str(CHART), *args], text=True,
                              capture_output=True, env=env, timeout=25)

    def restore(self, **kwargs):
        return self.cli("restore-fleet", str(self.backup), "--passphrase-file", str(self.passphrase),
                        "--storage-class", "new-local", "--bundle-storage-class", "new-csi", **kwargs)

    def test_restore_new_nodes_storage_and_counts(self):
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads((self.state / "state.json").read_text())
        self.assertEqual([value["spec"]["replicas"] for value in state["fleets"].values()], [2, 1])
        self.assertEqual(len(state["claims"]), 15)
        self.assertEqual(state["staged"], 3)
        self.assertFalse(state["helpers"])
        for cr in state["fleets"].values():
            self.assertEqual(cr["spec"]["nodeSelector"], {})
            self.assertNotIn("publicIP", cr["spec"]["network"])
            self.assertNotIn("old-worker", json.dumps(cr))
        for claim in state["claims"]:
            expected = "new-csi" if claim["metadata"]["name"].startswith("keybundle-") else "new-local"
            self.assertEqual(claim["spec"]["storageClassName"], expected)
        self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_backup_publishes_portable_recovery(self):
        output = self.root / "new-backup"
        result = self.cli("backup-fleet", str(output), "--passphrase-file", str(self.passphrase), source=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fleet.load(output, verify=True)
        self.assertEqual(self.gpg("--decrypt", str(output / "recovery.gpg")).stdout.count(KEY), 3)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_wrong_passphrase_before_cluster_access(self):
        self.passphrase.write_text("wrong passphrase\n")
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "events").exists())

    def test_corrupt_or_missing_bundle_before_cluster_access(self):
        path = self.backup / next(iter(self.manifest["files"]))
        path.write_bytes(b"corrupted")
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "events").exists())
        path.unlink()
        self.assertNotEqual(self.restore().returncode, 0)

    def test_changed_manifest_is_not_authenticated(self):
        self.manifest["fleets"][0]["spec"]["image"] = "tampered/image"
        fleet.write_json(self.backup / "fleet.json", self.manifest)
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authenticate", result.stderr)
        self.assertFalse((self.state / "events").exists())

    def test_existing_fleets_or_claims_are_not_overwritten(self):
        for mode in ("existing-fleet", "existing-pvc"):
            with self.subTest(mode=mode):
                result = self.restore(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                events = (self.state / "events").read_text()
                self.assertNotIn('["create"', events)
                self.assertNotIn('["patch"', events)

    def test_provider_failure_stops_all_destination_fleets(self):
        result = self.restore(mode="provider-failure")
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.state / "state.json").read_text())
        self.assertTrue(state["fleets"])
        self.assertTrue(all(cr["spec"]["replicas"] == 0 for cr in state["fleets"].values()))
        self.assertFalse(state["helpers"])
        self.assertNotIn("Fleet restore complete", result.stdout)

    def test_failed_unwrap_does_not_publish_backup(self):
        output = self.root / "failed-backup"
        result = self.cli("backup-fleet", str(output), "--passphrase-file", str(self.passphrase),
                          mode="unwrap-failure", source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob("failed-backup.partial.*")))

    def test_bootstrap_configures_each_destination_namespace(self):
        result = self.cli("restore-fleet", str(self.backup), "--passphrase-file", str(self.passphrase), "--bootstrap")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = (self.state / "events").read_text()
        self.assertIn("credentials default", events)
        self.assertIn("credentials other", events)
        self.assertNotIn("mock-root-token", result.stdout + result.stderr)

    def test_operator_resume_failure_is_reported_and_fleets_stopped(self):
        result = self.restore(mode="resume-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Fleet restore complete", result.stdout)
        state = json.loads((self.state / "state.json").read_text())
        self.assertTrue(all(cr["spec"]["replicas"] == 0 for cr in state["fleets"].values()))

    def test_operator_pause_failure_resumes_operator_without_starting_ton(self):
        result = self.restore(mode="pause-failure")
        self.assertNotEqual(result.returncode, 0)
        state = json.loads((self.state / "state.json").read_text())
        self.assertTrue(all(cr["spec"]["replicas"] == 0 for cr in state["fleets"].values()))
        self.assertEqual(state["staged"], 0)
        events = (self.state / "events").read_text()
        self.assertIn('["-n", "ton-k8s-operator-system", "scale", "deployment", "operator", "--replicas=1"]', events)

    def test_crd_query_failure_aborts_without_mutation(self):
        result = self.restore(mode="crd-error")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('["create"', (self.state / "events").read_text())
        self.assertFalse(json.loads((self.state / "state.json").read_text())["fleets"])

    def test_unconfirmed_cleanup_does_not_resume_operator(self):
        result = self.restore(mode="cleanup-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reconciliation remains paused", result.stderr)
        events = (self.state / "events").read_text()
        self.assertNotIn('["-n", "ton-k8s-operator-system", "scale", "deployment", "operator", "--replicas=1"]', events)

    def test_destination_selector_and_public_ip_override(self):
        mapping = self.root / "public-ips.json"
        mapping.write_text(json.dumps({"default/alpha/0": "203.0.113.42"}))
        result = self.cli("restore-fleet", str(self.backup), "--passphrase-file", str(self.passphrase),
                          "--node-selector", "pool=destination", "--public-ips", str(mapping))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("advertised IP 203.0.113.42", result.stdout)
        state = json.loads((self.state / "state.json").read_text())
        self.assertTrue(all(cr["spec"]["nodeSelector"] == {"pool": "destination"}
                            for cr in state["fleets"].values()))

    def test_unknown_public_ip_mapping_rejected_before_mutation(self):
        mapping = self.root / "public-ips.json"
        mapping.write_text(json.dumps({"default/alpha/99": "203.0.113.42"}))
        result = self.cli("restore-fleet", str(self.backup), "--passphrase-file", str(self.passphrase),
                          "--public-ips", str(mapping))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown fleet/ordinal", result.stderr)
        self.assertNotIn('["create"', (self.state / "events").read_text())

    def test_unsafe_paths_and_external_dependencies_rejected(self):
        fleet.validate_fleets(self.manifest)
        for value in ("../../other", "bad/name"):
            manifest = copy.deepcopy(self.manifest)
            manifest["fleets"][0]["namespace"] = value
            with self.assertRaises(ValueError):
                fleet.validate_fleets(manifest)
        linked = self.backup / next(iter(self.manifest["files"]))
        linked.unlink()
        linked.symlink_to(self.passphrase)
        with self.assertRaisesRegex(ValueError, "symlink"):
            fleet.load(self.backup, verify=True)
        manifest = copy.deepcopy(self.manifest)
        manifest["fleets"][0]["spec"]["env"] = [{"name": "SECRET", "valueFrom": {}}]
        with self.assertRaisesRegex(ValueError, "dependencies"):
            fleet.validate_fleets(manifest)

    def test_rebind_preserves_identity_and_updates_advertised_ip(self):
        source, target = self.root / "old.tar.gz", self.root / "new.tar.gz"
        identity = b"original validator identity"
        for service in (b"ExecStart=/usr/bin/validator --ip 192.0.2.99:30001 --db /var/ton-work/db\n",
                        b"ExecStart=/usr/bin/validator --db /var/ton-work/db\n"):
            with tarfile.open(source, "w:gz") as archive:
                for name, value in (("keys/client", identity),
                                    ("tondb/config.json", b'{"addrs":[{"ip":-1,"port":30001}]}'),
                                    ("controller/services/validator.service", service)):
                    member = tarfile.TarInfo("./" + name)
                    member.size = len(value)
                    archive.addfile(member, io.BytesIO(value))
            fleet.rebind(source, target, "203.0.113.10", "30001")
            with tarfile.open(target) as archive:
                self.assertEqual(archive.extractfile("./keys/client").read(), identity)
                config = json.load(archive.extractfile("./tondb/config.json"))
                self.assertEqual(config["addrs"][0], {"ip": -889163510, "port": 30001})
                self.assertNotIn(b"192.0.2.99", archive.extractfile("./controller/services/validator.service").read())

    def test_real_crypto_rewrap_and_decrypt_on_destination(self):
        bundle_dir, scratch = self.root / "bundle", self.root / "scratch"
        bundle_dir.mkdir()
        scratch.mkdir()
        shutil.copyfile(CHART / "fleet.py", scratch / "fleet.py")
        source = self.root / "payload.tar.gz"
        with tarfile.open(source, "w:gz") as archive:
            for name, value in (("keys/client", b"original private key"),
                                ("tondb/config.json", b'{"addrs":[{"ip":-1,"port":30001}]}'),
                                ("controller/services/validator.service", b"ExecStart=validator --db /var/ton-work/db\n")):
                member = tarfile.TarInfo(name)
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
        env = dict(self.env, DATA_KEY_B64=KEY, FLEET_BUNDLE_DIR=str(bundle_dir), FLEET_RECOVERY_DIR=str(scratch),
                   KEY_BUNDLE_FILE="keys.bundle.enc", KEY_BUNDLE_META_FILE="keys.bundle.meta",
                   VAULT_ADDR="https://mock.invalid", VAULT_TOKEN="test-token", VAULT_TRANSIT_KEY="new-transit")
        # Simulate the Vault API only; run real OpenSSL, JSON and tar processing.
        curl = self.root / "bin/curl"
        curl.write_text('''#!/usr/bin/env python3
import json, sys
payload = json.load(sys.stdin)
if sys.argv[-1].endswith('/encrypt/new-transit'):
    print(json.dumps({'data': {'ciphertext': 'vault:v9:' + payload['plaintext']}}))
else:
    print(json.dumps({'data': {'plaintext': payload['ciphertext'].split(':', 2)[2]}}))
''')
        curl.chmod(0o755)
        encrypted = bundle_dir / "keys.bundle.enc"
        subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-md", "sha256",
                        "-pass", "env:DATA_KEY_B64", "-in", str(source), "-out", str(encrypted)],
                       env=env, capture_output=True, check=True)
        crypto = ["sh", str(CHART / "fleet-crypto.sh")]
        result = subprocess.run([*crypto, "restore", "203.0.113.10", "30001"], input=KEY + "\n",
                                text=True, capture_output=True, env=env, check=True)
        self.assertNotIn(KEY, result.stdout + result.stderr)
        meta = (bundle_dir / "keys.bundle.meta").read_text()
        unwrapped = subprocess.run([*crypto, "unwrap"], input=meta, text=True, env=env,
                                   capture_output=True, check=True)
        self.assertEqual(unwrapped.stdout, KEY)
        self.assertTrue((bundle_dir / ".restore-controller-state").exists())
        self.assertEqual(list(scratch.glob("*.tar.gz")), [])
        subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-md", "sha256",
                        "-pass", "env:DATA_KEY_B64", "-in", str(encrypted), "-out", str(source)],
                       env=env, capture_output=True, check=True)
        with tarfile.open(source) as archive:
            self.assertEqual(archive.extractfile("keys/client").read(), b"original private key")
            self.assertEqual(json.load(archive.extractfile("tondb/config.json"))["addrs"][0]["ip"], -889163510)


if __name__ == "__main__":
    unittest.main(verbosity=2)
