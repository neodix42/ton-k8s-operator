#!/usr/bin/env python3
"""Single ordinal recovery tests. Kubernetes and crypto boundaries are synthetic."""
import json
import hashlib
import io
import ipaddress
import os
import pathlib
import subprocess
import sys
import tempfile
import tarfile
import unittest

sys.dont_write_bytecode = True

from kubeton_add_test import CLI, fixtures as add_fixtures


def fixtures():
    data = add_fixtures()
    data["sts"].update(apiVersion="apps/v1", kind="StatefulSet")
    data["cr"]["spec"]["keyManagement"] = {"enabled": True, "provider": "vault"}
    data["sts"]["spec"]["template"]["spec"]["containers"].append({
        "name": "key-backup", "env": [{"name": "KEY_BUNDLE_FILE", "value": "keys.bundle.enc"},
                                         {"name": "KEY_BUNDLE_META_FILE", "value": "keys.bundle.meta"}],
        "envFrom": [{"secretRef": {"name": "vault-creds"}}]})
    data["nodes"]["items"][-1]["status"] = {"addresses": [{"type": "ExternalIP", "address": "203.0.113.45"}]}
    for node in data["nodes"]["items"]:
        node.setdefault("status", {})["conditions"] = [{"type": "Ready", "status": "True"}]
    for prefix in ("ton-src", "mytoncore", "mytonctrl"):
        data["sts"]["spec"]["volumeClaimTemplates"].append({"metadata": {"name": prefix}, "spec": {
            "storageClassName": "local-path", "resources": {"requests": {"storage": "20Gi"}}}})
    for claim in data["sts"]["spec"]["volumeClaimTemplates"]:
        name = claim["metadata"]["name"] + "-tonnode-2"
        data["pvcs"]["items"].append({"metadata": {"name": name, "uid": name + "-uid"},
                                     "spec": {**claim["spec"], "volumeName": name + "-pv"}})
        data["pvs"]["items"].append({"metadata": {"name": name + "-pv", "uid": name + "-pv-uid"},
                                     "spec": {"claimRef": {"uid": name + "-uid"}, "persistentVolumeReclaimPolicy": "Delete"}})
    data["pods"]["items"][2]["status"]["conditions"] = []
    data["operator_paused"] = False
    return data


FAKE = r'''
import hashlib,json,os,pathlib,sys
root=pathlib.Path(os.environ["RECOVER_STATE"]); path=root/"state.json"; s=json.loads(path.read_text()); args=sys.argv[1:]; mode=os.environ["RECOVER_CASE"]
def save(): path.write_text(json.dumps(s))
def record(event):
 with (root/"events").open("a") as f: f.write(event+"\n")
def output(value): print(json.dumps(value))
if args[0]=="event":
 event=" ".join(args[1:]); record(event)
 if event=="pause": s["operator_paused"]=True; save()
 if event=="resume": s["operator_paused"]=False; save()
 if event=="commit": s["identity_staged"]=True; save()
 sys.exit(0)
a=args[1:]
if a[:2]==["label","node"]:
 key,value=a[3].split("=",1); s["nodes"]["items"][-1]["metadata"]["labels"][key]=value; save(); record("label")
elif a[:2]==["get","node"]: output(s["nodes"]["items"][-1])
elif a[:2]==["get","nodes"]: output(s["nodes"])
elif a[:2]==["get","storageclass"]: output(s["classes"])
elif a[:2]==["get","pv"]:
 if len(a)>2 and a[2]!="-o":
  item=next(x for x in s["pvs"]["items"] if x["metadata"]["name"]==a[2]); print(item["metadata"]["uid"]) if "jsonpath" in " ".join(a) else output(item)
 else: output(s["pvs"])
elif a[:2]==["patch","pv"]:
 assert s["operator_paused"] and s.get("sts")==None; assert a[2].startswith(tuple(p+"-tonnode-2" for p in ("ton-work","ton-src","mytoncore","mytonctrl","keybundle"))); next(x for x in s["pvs"]["items"] if x["metadata"]["name"]==a[2])["spec"]["persistentVolumeReclaimPolicy"]="Retain"; save(); record("retain "+a[2])
elif a[:2]==["create","-f"]:
 obj=json.load(sys.stdin) if a[2]=="-" else json.loads(pathlib.Path(a[2]).read_text())
 if obj["kind"]=="Pod":
  name=obj["metadata"]["name"]; obj["spec"]["nodeName"]="worker-5"; s.setdefault("helpers",{})[name]=obj; save(); record("helper "+("stage" if "stage" in name else "verify"))
 elif obj["kind"]=="List":
  assert s.get("sts")==None and len(s["pvcs"]["items"])==0
  s["pvcs"]["items"]=[dict(x,metadata={**x["metadata"],"uid":"new-"+x["metadata"]["name"]}) for x in obj["items"]]; save(); record("create claims")
 elif obj["kind"]=="StatefulSet":
  assert s.get("identity_staged") and s.get("sts")==None
  if mode=="recreate-failure": sys.exit(1)
  obj["metadata"]["uid"]="replacement-sts"; s["sts"]=obj
  for p in s["pods"]["items"]: p["metadata"]["ownerReferences"]=[{"kind":"StatefulSet","uid":"replacement-sts","controller":True}]
  s["pods"]["items"].append({"metadata":{"name":"tonnode-2","uid":"recovered-2","ownerReferences":[{"kind":"StatefulSet","uid":"replacement-sts","controller":True}]},"spec":{"nodeName":"worker-5"},"status":{"phase":"Pending"}})
  save(); record("recreate sts")
 else: raise AssertionError(obj)
elif a[:2]==["-n","ton-k8s-operator-system"] and a[2:4]==["wait","--for=delete"]: record("operator stopped")
elif a[:2]==["-n","unit-ns"]:
 op,kind=a[2:4]
 if op=="get" and kind=="statefulset":
  if "jsonpath" in " ".join(a): print("30001" if "validator-udp" in " ".join(a) else s["sts"]["metadata"]["uid"])
  else: output(s["sts"])
 elif op=="get" and kind=="tonnodes.ton.ton.org": output(s["cr"])
 elif op=="get" and kind=="pods": output(s["pods"])
 elif op=="get" and kind=="pvc":
  if len(a)>4 and a[4]!="-o":
   item=next(x for x in s["pvcs"]["items"] if x["metadata"]["name"]==a[4]); print(item["metadata"]["uid"]) if "jsonpath" in " ".join(a) else output(item)
  else: output(s["pvcs"])
 elif op=="get" and kind=="pod": print("original-2" if "metadata.uid" in " ".join(a) else "worker-5")
 elif op=="patch" and kind=="statefulset":
  patch=json.loads(a[a.index("-p")+1])
  for item in patch:
   keys=item["path"].split("/")[1:]; target=s["sts"]
   for key in keys[:-1]: target=target[key]
   if item["op"]=="test": assert target[keys[-1]]==item["value"]
   else: target[keys[-1]]=item["value"]
  save(); record("retention safe")
 elif op=="delete" and kind=="statefulset":
  assert "--cascade=orphan" in a and s["operator_paused"]
  for p in s["pods"]["items"]: p["metadata"].pop("ownerReferences",None)
  s["sts"]=None; save(); record("orphan")
 elif op=="delete" and kind=="pod":
  name=a[4]
  if name.startswith("kubeton-recover-"): s.setdefault("helpers",{}).pop(name,None); save(); record("delete helper")
  else:
   assert name=="tonnode-2" and not any("force" in x for x in a)
   if mode=="delete-failure": sys.exit(1)
   s["pods"]["items"]=[p for p in s["pods"]["items"] if p["metadata"]["name"]!=name]; save(); record("delete target")
 elif op=="delete" and kind=="pvc":
  name=a[4]; assert name.endswith("-tonnode-2"); pv=next(x for x in s["pvs"]["items"] if x["metadata"]["name"]==name+"-pv"); assert pv["spec"]["persistentVolumeReclaimPolicy"]=="Retain"; s["pvcs"]["items"]=[x for x in s["pvcs"]["items"] if x["metadata"]["name"]!=name]; save(); record("delete claim "+name)
 elif op=="wait":
  if mode=="stage-failure" and "stage" in " ".join(a): sys.exit(1)
  assert "tonnode-" not in " ".join(a), "waited for recovered TON pod readiness"; record("wait helper")
 elif op=="cp":
  values=[x for x in a[3:] if x!="key-backup" and x!="-c"]; src,dst=values[-2:]
  if ":" in src:
   filename=src.rsplit("/",1)[-1]; pathlib.Path(dst).write_bytes((root/filename).read_bytes())
  record("copy")
 elif op=="exec":
  if "sha256sum" in " ".join(a):
   for filename in ("keys.bundle.enc","keys.bundle.meta"): print(hashlib.sha256((root/filename).read_bytes()).hexdigest()+"  "+filename)
  elif "crypto=" in " ".join(a):
   record("validate rebind 203.0.113.45")
   if mode=="bad-bundle": sys.exit(1)
  elif "systemctl stop" in " ".join(a):
   record("stop source services")
   if mode=="fence-failure": sys.exit(1)
 else: raise AssertionError(a)
else: raise AssertionError(a)
'''

WRAPPER = r'''
source "$1"
kubectl() { python3 "$RECOVER_HELPER" kubectl "$@"; }
get_single_ton_statefulset() { local -n a="$1" b="$2" c="$3"; a=unit-ns; b=tonnode; c=5; }
run_node_prerequisite_check() {
  [[ "$1" == 1 && "$2" == pool=ton && "$KUBETON_ADD_CPU_MILLI" == 16000 && "$KUBETON_ADD_DATA_BYTES" == 816043786240 ]] || return 97
  [[ "${KUBETON_ADD_OCCUPIED_NODES[worker-2]:-}" == 1 ]] || return 98
  python3 "$RECOVER_HELPER" event admission
  [[ "$RECOVER_CASE" != no-capacity ]] || return 1
  KUBETON_NODE_CHECK_COMPATIBLE_NODES=(worker-5)
}
wait_ton_selected_nodes_longhorn_csi_ready() { python3 "$RECOVER_HELPER" event csi; }
confirm_or_exit() { python3 "$RECOVER_HELPER" event confirm; }
trigger_key_backup_once() { python3 "$RECOVER_HELPER" event fresh-backup; [[ "$RECOVER_CASE" != backup-failure ]]; }
pause_operator_reconcile() { local -n a="$1" b="$2"; a=(operator); b=(1); python3 "$RECOVER_HELPER" event pause; }
ton_add_resume_operator() { python3 "$RECOVER_HELPER" event resume; }
commit_uploaded_key_bundle() { python3 "$RECOVER_HELPER" event commit; }
if [[ -n "${RECOVER_BACKUP:-}" ]]; then
  run_restore_keys worker-2 "$RECOVER_BACKUP" --to-node worker-5
else
  run_restore_keys worker-2 --to-node worker-5
fi
'''


class TargetedRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = subprocess.check_output(["bash", "-c", 'source "$1"; ton_restore_plan_script', "_", str(CLI)], text=True)

    def plan(self, data, reference="worker-2"):
        payload = "\0".join(json.dumps(data[k]) for k in ("sts", "cr", "pods", "pvcs", "pvs", "classes", "nodes"))
        return subprocess.run(["python3", "-c", self.script, reference, "ton.ton.org/kubeton-prereq", "ready", "16", "64Gi", "ton.ton.org/sticky-ordinal-node-map"], input=payload, text=True, capture_output=True)

    def test_server_pod_and_namespace_resolve_same_single_ordinal(self):
        for ref in ("worker-2", "tonnode-2", "unit-ns/tonnode-2"):
            result = self.plan(fixtures(), ref)
            self.assertEqual(result.returncode, 0, result.stderr)
            context = json.loads(result.stdout)
            self.assertEqual(context["ordinal"], 2)
            self.assertEqual(context["replicas"], 5)
            self.assertEqual(len(context["siblings"]), 4)
            self.assertEqual(len(context["old_claims"]), 5)
            self.assertEqual(context["data"], 760 * 1024**3)

    def test_rejects_unsupported_provider_before_mutation(self):
        data = fixtures(); data["cr"]["spec"]["keyManagement"]["provider"] = "kms"
        result = self.plan(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Vault", result.stderr)

    def test_rejects_unhealthy_sibling_missing_pv_or_changed_ownership(self):
        for change in ("sibling", "pv", "owner"):
            data = fixtures()
            if change == "sibling": data["pods"]["items"][1]["status"]["conditions"] = []
            if change == "pv": data["pvs"]["items"][0]["spec"]["claimRef"]["uid"] = "foreign"
            if change == "owner": data["sts"]["metadata"]["ownerReferences"][0]["uid"] = "foreign"
            self.assertNotEqual(self.plan(data).returncode, 0)

    def test_offline_source_is_rejected_even_with_a_backup(self):
        data = fixtures(); data["nodes"]["items"][2]["status"]["conditions"] = []
        result = self.plan(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("graceful stop", result.stderr)

    def test_plan_detects_concurrent_non_replica_spec_edits(self):
        data = fixtures(); old = json.loads(self.plan(data).stdout)
        data["cr"]["spec"]["image"] = "updated:image"
        current = json.loads(self.plan(data).stdout)
        self.assertNotEqual(old["fingerprint"], current["fingerprint"])

    def flow(self, mode, external=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); data = fixtures()
            (root / "state.json").write_text(json.dumps(data)); (root / "events").write_text("")
            for filename in ("keys.bundle.enc", "keys.bundle.meta"): (root / filename).write_bytes(filename.encode())
            helper = root / "fake.py"; helper.write_text(FAKE)
            env = dict(os.environ, RECOVER_STATE=directory, RECOVER_CASE=mode, RECOVER_HELPER=str(helper))
            if external:
                backup = root / "backup"
                item = backup / "unit-ns" / "tonnode" / "2"
                bundle = item / "bundle"
                bundle.mkdir(parents=True)
                checksums = []
                for filename in ("keys.bundle.enc", "keys.bundle.meta"):
                    payload = (root / filename).read_bytes()
                    (bundle / filename).write_bytes(payload)
                    checksums.append(hashlib.sha256(payload).hexdigest() + "  bundle/" + filename)
                (item / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
                if mode == "corrupt-backup":
                    (bundle / "keys.bundle.enc").write_bytes(b"corrupted")
                env["RECOVER_BACKUP"] = str(backup)
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", WRAPPER, "_", str(CLI)], cwd=root, env=env, text=True, capture_output=True)
            state = json.loads((root / "state.json").read_text()); events = (root / "events").read_text()
            checkpoints = list(root.glob("kubeton-recovery-*"))
            phase = (checkpoints[0] / "phase").read_text().strip() if checkpoints else ""
            return result, state, events, phase

    def test_recovery_orphans_only_target_preserves_sibling_uids_and_old_volumes(self):
        result, state, events, phase = self.flow("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(phase, "complete")
        self.assertLess(events.index("fresh-backup"), events.index("orphan"))
        self.assertLess(events.index("validate rebind"), events.index("delete claim"))
        self.assertLess(events.index("commit"), events.index("recreate sts"))
        self.assertEqual(events.count("delete target"), 1)
        self.assertEqual(events.count("delete claim"), 5)
        self.assertFalse(state["operator_paused"])
        self.assertEqual(state["sts"]["spec"]["replicas"], 5)
        self.assertEqual(state["sts"]["spec"]["updateStrategy"], {"type": "OnDelete"})
        self.assertIn("2=worker-5", state["sts"]["metadata"]["annotations"]["ton.ton.org/sticky-ordinal-node-map"])
        self.assertEqual({p["metadata"]["uid"] for p in state["pods"]["items"] if p["metadata"]["name"] != "tonnode-2"}, {"original-0", "original-1", "original-3", "original-4"})
        self.assertTrue(all(p["spec"]["persistentVolumeReclaimPolicy"] == "Retain" for p in state["pvs"]["items"]))
        self.assertIn("synchronization continues in the background", result.stdout)

    def test_capacity_backup_or_crypto_failure_cannot_touch_target_storage(self):
        for mode in ("no-capacity", "backup-failure", "bad-bundle"):
            result, state, events, _ = self.flow(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("orphan", events)
            self.assertNotIn("delete claim", events)
            self.assertFalse(state["operator_paused"])
            self.assertEqual(len(state["pvcs"]["items"]), 5)

    def test_external_snapshot_is_verified_before_recovery_and_skips_live_backup(self):
        result, state, events, phase = self.flow("success", external=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(phase, "complete")
        self.assertNotIn("fresh-backup", events)
        self.assertIn("stop source services", events)
        self.assertIn("snapshot", result.stderr)
        self.assertFalse(state["operator_paused"])
        result, state, events, _ = self.flow("corrupt-backup", external=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("orphan", events)
        self.assertNotIn("delete claim", events)
        self.assertFalse(state["operator_paused"])
        self.assertEqual(len(state["pvcs"]["items"]), 5)

    def test_failed_graceful_source_stop_leaves_operator_paused_and_claims_untouched(self):
        for mode in ("delete-failure", "fence-failure"):
            result, state, events, phase = self.flow(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(phase, "orphaning")
            self.assertTrue(state["operator_paused"])
            self.assertNotIn("delete claim", events)
            self.assertEqual(len(state["pods"]["items"]), 5)
            self.assertEqual(len(state["pvcs"]["items"]), 5)
            self.assertIn("operator reconciliation remains paused", result.stderr)

    def test_staging_or_recreation_failure_never_resumes_operator(self):
        for mode in ("stage-failure", "recreate-failure"):
            result, state, events, phase = self.flow(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(state["operator_paused"])
            self.assertNotIn("resume", events)
            self.assertEqual(len(state["pods"]["items"]), 4)
            self.assertTrue(all(p["spec"]["persistentVolumeReclaimPolicy"] == "Retain" for p in state["pvs"]["items"]))

    def test_rebind_changes_only_advertised_ip_and_service_endpoint(self):
        payload = {"keys/client": b"fixture-client-key", "tondb/keyring/adnl": b"fixture-adnl-key",
                   "controller/mytoncore/wallets/validator.pk": b"fixture-wallet-key",
                   "controller/mytoncore/wallets/validator.addr": b"fixture-wallet-address",
                   "controller/mytoncore/mytoncore.db": b"fixture-controller-db",
                   "controller/services/validator.service": b"ExecStart=validator-engine --ip 198.51.100.7:30001 --db /var/ton-work/db\n"}
        config = {"addrs": [{"ip": -969710585, "port": 30001, "categories": [0]}], "adnl": [{"id": "fixture-adnl-id"}], "validators": [{"id": "fixture-validator-id"}]}
        payload["tondb/config.json"] = json.dumps(config).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); old = root / "old.tar.gz"; new = root / "new.tar.gz"
            with tarfile.open(old, "w:gz") as archive:
                for name, data in payload.items():
                    info = tarfile.TarInfo(name); info.size = len(data); archive.addfile(info, io.BytesIO(data))
            result = subprocess.run(["python3", str(CLI.parent / "fleet.py"), "rebind", str(old), str(new), "203.0.113.45", "30001"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tarfile.open(new) as archive:
                rebound = {m.name: archive.extractfile(m).read() for m in archive}
            for name, data in payload.items():
                if name not in ("tondb/config.json", "controller/services/validator.service"):
                    self.assertEqual(rebound[name], data)
            config["addrs"][0]["ip"] = int(ipaddress.IPv4Address("203.0.113.45")) - 2**32
            self.assertEqual(json.loads(rebound["tondb/config.json"]), config)
            self.assertIn(b"--ip 203.0.113.45:30001", rebound["controller/services/validator.service"])

    def test_archive_validation_rejects_missing_wallet_identity_and_special_entries(self):
        script = subprocess.check_output(["bash", "-c", 'source "$1"; ton_restore_archive_validation_script', "_", str(CLI)], text=True)
        payload = {"tondb/config.json": b'{"addrs":[{"ip":1}]}', "keys/client": b"fixture-key",
                   "tondb/keyring/adnl": b"fixture-key", "controller/initialized.json": b"{}",
                   "controller/mytoncore/mytoncore.db": b"db", "controller/services/validator.service": b"validator",
                   "controller/services/mytoncore.service": b"mytoncore", "controller/mytoncore/wallets/a.pk": b"key",
                   "controller/mytoncore/wallets/a.addr": b"address"}
        for mode in ("good", "missing-address", "missing-keyring", "fifo", "symlink", "traversal"):
            with tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "bundle.tar.gz"
                with tarfile.open(path, "w:gz") as archive:
                    for name, data in payload.items():
                        if mode == "missing-address" and name.endswith(".addr"): continue
                        if mode == "missing-keyring" and name.startswith("tondb/keyring/"): continue
                        info = tarfile.TarInfo(name); info.size = len(data); archive.addfile(info, io.BytesIO(data))
                    if mode in ("fifo", "symlink", "traversal"):
                        info = tarfile.TarInfo("../outside" if mode == "traversal" else "unexpected")
                        info.type = {"fifo": tarfile.FIFOTYPE, "symlink": tarfile.SYMTYPE, "traversal": tarfile.REGTYPE}[mode]
                        info.linkname = "/outside"; archive.addfile(info)
                result = subprocess.run(["python3", "-O", "-c", script, str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, mode == "good", mode + result.stderr)


if __name__ == "__main__":
    unittest.main()
