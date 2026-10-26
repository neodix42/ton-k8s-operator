#!/usr/bin/env python3
"""Scaling admission and recovery tests; every cluster boundary is synthetic."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "charts/ton-k8s-operator/kubeton"


def fixtures(resume=False):
    count = 6 if resume else 5
    selector = {"pool": "ton", "ton.ton.org/kubeton-prereq": "ready"}
    spec = {"nodeSelector": selector, "containers": [{"name": "ton-node", "image": "ton:fixture",
            "resources": {"requests": {"cpu": "16", "memory": "64Gi"}},
            "ports": [{"hostPort": 30001, "protocol": "UDP"}, {"hostPort": 30003, "protocol": "TCP"}]}],
            "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [
                {"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": [f"host-{i}" for i in range(5)]}]}]}}}}
    sts = {"metadata": {"name": "tonnode", "namespace": "unit-ns", "uid": "sts-uid", "resourceVersion": "7",
           "ownerReferences": [{"kind": "TonNode", "uid": "cr-uid", "controller": True}],
           "annotations": {"ton.ton.org/sticky-placement-spec-hash": "a" * 64}},
           "spec": {"replicas": count, "template": {"spec": spec}, "volumeClaimTemplates": [
               {"metadata": {"name": "ton-work"}, "spec": {"storageClassName": "local-path", "resources": {"requests": {"storage": "700Gi"}}}},
               {"metadata": {"name": "keybundle"}, "spec": {"storageClassName": "encrypted-sc", "resources": {"requests": {"storage": "5Gi"}}}}]}}
    cr = {"metadata": {"name": "tonnode", "namespace": "unit-ns", "uid": "cr-uid", "resourceVersion": "9"},
          "spec": {"replicas": count, "nodeSelector": selector, "network": {"hostPortsEnabled": True}}}
    pods = [{"metadata": {"name": f"tonnode-{i}", "namespace": "unit-ns", "uid": f"original-{i}",
             "ownerReferences": [{"kind": "StatefulSet", "uid": "sts-uid", "controller": True}]},
             "spec": {"nodeName": f"worker-{i}"}, "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
            for i in range(5)]
    if resume:
        pods.append({"metadata": {"name": "tonnode-5", "namespace": "unit-ns", "uid": "pending-5",
                     "ownerReferences": [{"kind": "StatefulSet", "uid": "sts-uid", "controller": True}]},
                     "spec": {}, "status": {"phase": "Pending"}})
    nodes = [{"metadata": {"name": f"worker-{i}", "labels": {"kubernetes.io/hostname": f"host-{i}", "pool": "ton",
              **({"ton.ton.org/kubeton-prereq": "ready"} if i < 5 else {})}}} for i in range(6)]
    retained = [{"metadata": {"name": "keybundle-tonnode-5", "uid": "retained-keybundle"},
                 "spec": {"storageClassName": "encrypted-sc", "volumeName": "encrypted-pv", "resources": {"requests": {"storage": "5Gi"}}}}] if resume else []
    volumes = [{"metadata": {"name": "encrypted-pv"}, "spec": {"claimRef": {"uid": "retained-keybundle"}}}] if resume else []
    return {"sts": sts, "cr": cr, "pods": {"items": pods}, "nodes": {"items": nodes}, "pvcs": {"items": retained},
            "pvs": {"items": volumes}, "classes": {"items": [{"metadata": {"name": "local-path"}, "provisioner": "rancher.io/local-path"},
            {"metadata": {"name": "encrypted-sc"}, "provisioner": "driver.longhorn.io"}]}}


FAKE = r'''
import json, os, pathlib, sys
root=pathlib.Path(os.environ["ADD_STATE"]); path=root/"state.json"; state=json.loads(path.read_text())
args=sys.argv[1:]
def record(event):
    with (root/"events").open("a") as target: target.write(event+"\n")
def save(): path.write_text(json.dumps(state))
def pod_ready():
    if not any(p["metadata"]["name"]=="tonnode-5" for p in state["pods"]["items"]):
        state["pods"]["items"].append({"metadata":{"name":"tonnode-5","namespace":"unit-ns","uid":"new-5"},"spec":{"nodeName":"worker-5"},"status":{"phase":"Running"}})
if args[0]=="snapshot":
    for key in ("sts","cr","pods","pvcs","pvs","classes"): sys.stdout.write(json.dumps(state[key])+"\0")
elif args[0]=="replicas": print(state["sts"]["spec"]["replicas"])
elif args[0]=="event": record(" ".join(args[1:]))
elif args[0]=="ready":
    assert state["sts"]["spec"]["replicas"]==6 and state["cr"]["spec"]["replicas"]==6
    assert state["sts"]["spec"]["updateStrategy"]=={"type":"OnDelete"}
    assert all(state["pods"]["items"][i]["metadata"]["uid"]==f"original-{i}" for i in range(5))
    assert state["sts"]["spec"]["template"]["spec"]["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"][0]["matchExpressions"][0]["values"]==[f"host-{i}" for i in range(6)]
    record("ready")
elif args[0]=="kubectl":
    a=args[1:]
    if a[:2]==["label","node"]:
        record("label "+a[2]); key,value=a[3].split("=",1)
        next(n for n in state["nodes"]["items"] if n["metadata"]["name"]==a[2])["metadata"]["labels"][key]=value; save()
    elif a[:2]==["get","node"]: print(json.dumps(next(n for n in state["nodes"]["items"] if n["metadata"]["name"]==a[2])))
    elif a[:2]==["get","nodes"]: print(json.dumps(state["nodes"]))
    elif a[:2]==["-n","ton-k8s-operator-system"] and a[2:4]==["get","pods"]: pass
    elif a[:2]==["-n","unit-ns"]:
        op,kind=a[2:4]
        key={"statefulset":"sts","tonnodes.ton.ton.org":"cr"}.get(kind)
        if op=="get" and key: print(json.dumps(state[key]))
        elif op=="get" and kind=="pod":
            pod=next((p for p in state["pods"]["items"] if p["metadata"]["name"]==a[4]),None)
            if pod: print(pod["spec"].get("nodeName","") if any("jsonpath=" in x for x in a) else json.dumps(pod))
        elif op=="patch" and key:
            assert "--type=json" in a
            if key=="sts" and os.environ["ADD_CASE"]=="patch-failure": sys.exit(1)
            patch=json.loads(a[a.index("-p")+1]); record("patch "+key)
            for item in patch:
                keys=[x.replace("~1","/").replace("~0","~") for x in item["path"].split("/")[1:]]
                target=state[key]
                for part in keys[:-1]: target=target[part]
                if item["op"]=="test": assert target[keys[-1]]==item["value"]
                else: target[keys[-1]]=item["value"]
            state[key]["metadata"]["resourceVersion"]=str(int(state[key]["metadata"]["resourceVersion"])+1)
            if key=="sts" and state["sts"]["spec"]["replicas"]==6 and os.environ["ADD_CASE"]!="resume": pod_ready()
            save()
        elif op=="delete" and kind=="pod":
            assert a[4]=="tonnode-5", "existing validator deleted"
            record("delete tail"); state["pods"]["items"]=[p for p in state["pods"]["items"] if p["metadata"]["name"]!="tonnode-5"]; pod_ready(); save()
        else: raise AssertionError("Unexpected cluster mutation/call: "+str(a))
    else: raise AssertionError("Unexpected cluster mutation/call: "+str(a))
else: raise AssertionError(args)
'''

WRAPPER = r'''
source "$1"
get_single_ton_statefulset() { local -n a="$1" b="$2" c="$3"; a=unit-ns; b=tonnode; c="$(python3 "$ADD_HELPER" replicas)"; }
kubectl() { python3 "$ADD_HELPER" kubectl "$@"; }
ton_add_context() {
  python3 "$ADD_HELPER" snapshot | python3 -c "$(ton_add_context_script)" "$KUBETON_NODE_PREREQ_LABEL_KEY" "$KUBETON_NODE_PREREQ_LABEL_VALUE" "$KUBETON_CHECK_MIN_CPU" "$KUBETON_CHECK_MIN_MEMORY" "$STICKY_ORDINAL_NODE_MAP_ANNOTATION_KEY"
}
admission_count=0
run_node_prerequisite_check() {
  [[ "$1" == 1 && "$2" == pool=ton && "$KUBETON_ADD_MODE" == true ]] || return 91
  [[ "$KUBETON_ADD_CPU_MILLI" == 16000 && "$KUBETON_ADD_MEMORY_BYTES" == 68719476736 && "$KUBETON_ADD_DATA_BYTES" == 751619276800 ]] || return 92
  [[ "${KUBETON_ADD_OCCUPIED_NODES[worker-0]:-}" == 1 && "${KUBETON_ADD_HOST_PORTS[*]}" == 'TCP/30003 UDP/30001' ]] || return 93
  admission_count=$((admission_count+1)); python3 "$ADD_HELPER" event admission "$admission_count"
  [[ "$ADD_CASE" != no-capacity ]] || return 1
  [[ "$ADD_CASE" != capacity-loss || "$admission_count" != 2 ]] || return 1
  KUBETON_NODE_CHECK_COMPATIBLE_NODES=(worker-5)
}
should_bootstrap_baremetal() { return 1; }
validate_external_key_prereqs() { :; }
wait_ton_selected_nodes_longhorn_csi_ready() { [[ "$1" == kubernetes.io/hostname=host-5 ]] || return 94; python3 "$ADD_HELPER" event csi; }
pause_operator_reconcile() { local -n a="$1" b="$2"; a=(operator); b=(1); python3 "$ADD_HELPER" event pause; }
ton_add_resume_operator() { python3 "$ADD_HELPER" event resume; [[ "$ADD_CASE" != resume-failure ]]; }
wait_pod_ready() { [[ "$1 $2" == 'unit-ns tonnode-5' ]] || return 95; python3 "$ADD_HELPER" ready; }
run_add
'''


class AddTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = subprocess.check_output(["bash", "-c", 'source "$1"; ton_add_context_script', "_", str(CLI)], text=True)

    def context(self, data):
        payload = "\0".join(json.dumps(data[key]) for key in ("sts", "cr", "pods", "pvcs", "pvs", "classes"))
        return subprocess.run(["python3", "-c", self.script, "ton.ton.org/kubeton-prereq", "ready", "16", "64Gi", "ton.ton.org/sticky-ordinal-node-map"], input=payload, text=True, capture_output=True)

    def test_uses_live_requirements_and_extra_host(self):
        result = self.context(fixtures())
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual((plan["ordinal"], plan["target"], plan["resume"]), (5, 6, False))
        self.assertEqual(plan["scope"], "pool=ton")
        self.assertEqual(plan["ports"], ["TCP/30003", "UDP/30001"])
        self.assertEqual(plan["data"], 700 * 1024**3)
        self.assertEqual(len(plan["running"]), 5)

    def test_pending_tail_resumes_without_seventh_replica(self):
        result = self.context(fixtures(True))
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual((plan["ordinal"], plan["target"], plan["resume"]), (5, 6, True))

    def test_rejects_old_operator_before_mutations(self):
        data = fixtures()
        data["sts"]["metadata"]["annotations"] = {}
        result = self.context(data)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("upgrade the operator", result.stderr)

    def test_incomplete_prior_replica_is_not_skipped(self):
        data = fixtures(True)
        data["pods"]["items"][2]["status"]["conditions"] = []
        self.assertNotEqual(self.context(data).returncode, 0)

    def test_replica_drift_is_rejected(self):
        data = fixtures()
        data["cr"]["spec"]["replicas"] = 8
        self.assertNotEqual(self.context(data).returncode, 0)

    def test_missing_storageclass_is_rejected(self):
        data = fixtures()
        data["classes"]["items"] = []
        self.assertNotEqual(self.context(data).returncode, 0)

    def test_node_selector_and_retained_volume_constraints(self):
        data = fixtures()
        plan = json.loads(self.context(data).stdout)
        for allowed, labels in [(True, {"pool": "ton", "kubernetes.io/hostname": "host-5"}),
                                (False, {"pool": "other"}),
                                (False, {"pool": "ton", "ton.ton.org/kubeton-prereq": "disabled"})]:
            node = {"metadata": {"name": "worker-5", "labels": labels}}
            result = subprocess.run(["bash", "-c", 'source "$1"; ton_add_node_fits "$2" "$3"', "_", str(CLI), json.dumps(plan), json.dumps(node)], capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, allowed, result.stderr)
        plan["constraints"] = [{"node": "different-worker"}]
        node = data["nodes"]["items"][-1]
        result = subprocess.run(["bash", "-c", 'source "$1"; ton_add_node_fits "$2" "$3"', "_", str(CLI), json.dumps(plan), json.dumps(node)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def flow(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = fixtures(mode == "resume")
            (root / "state.json").write_text(json.dumps(state))
            (root / "events").write_text("")
            helper = root / "fake.py"
            helper.write_text(FAKE)
            env = dict(os.environ, ADD_STATE=directory, ADD_CASE=mode, ADD_HELPER=str(helper))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", WRAPPER, "_", str(CLI)], env=env, text=True, capture_output=True)
            return result, (root / "events").read_text(), json.loads((root / "state.json").read_text())

    def test_fresh_scale_updates_placement_before_wait(self):
        result, events, state = self.flow("fresh")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertLess(events.index("admission 2"), events.index("pause"))
        self.assertLess(events.index("patch sts"), events.index("ready"))
        self.assertIn("resume", events)
        self.assertNotIn("delete", events)
        self.assertEqual(state["cr"]["spec"]["replicas"], 6)

    def test_resumed_tail_only_is_recreated(self):
        result, events, state = self.flow("resume")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(events.count("delete tail"), 1)
        self.assertEqual(state["sts"]["spec"]["replicas"], 6)
        self.assertIn("keeping replicas=6", result.stdout)
        self.assertEqual(state["pvcs"]["items"][0]["metadata"]["uid"], "retained-keybundle")

    def test_capacity_failure_cannot_scale_or_touch_pvcs(self):
        for mode in ("no-capacity", "capacity-loss"):
            result, events, state = self.flow(mode)
            self.assertNotEqual(result.returncode, 0, mode)
            self.assertNotIn("patch", events)
            self.assertNotIn("pause", events)
            self.assertEqual(state["sts"]["spec"]["replicas"], 5)
            self.assertEqual(state["pvcs"]["items"], [])

    def test_operator_resumes_after_patch_failure(self):
        result, events, state = self.flow("patch-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pause", events)
        self.assertIn("resume", events)
        self.assertNotIn("ready", events)

    def test_failed_operator_restore_is_not_reported_as_success(self):
        result, events, state = self.flow("resume-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Added TON replica", result.stdout)
        self.assertGreaterEqual(events.count("resume"), 2)


if __name__ == "__main__":
    unittest.main()
