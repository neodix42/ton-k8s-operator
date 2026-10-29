#!/usr/bin/env python3
"""Dashboard stop/resume integration with a private fake Kubernetes API."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "charts/ton-k8s-operator/kubeton"
PAUSE = "ton.ton.org/kubeton-dashboard-paused-replicas"

FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['DASHBOARD_TEST_ROOT'])
state = json.loads((root/'state').read_text())
args = sys.argv[1:]
with (root/'events').open('a') as out: out.write(json.dumps(args)+'\n')
ns = None
if args[:1] == ['-n']: ns, args = args[1], args[2:]
def fail(message): print(message, file=sys.stderr); sys.exit(1)
def save(): (root/'state').write_text(json.dumps(state))
if args[:2] == ['get','deployments']:
    if state.get('inventory_error'): fail('synthetic inventory error')
    selector = args[args.index('-l')+1]
    assert 'app.kubernetes.io/managed-by=kubeton' in selector
    assert 'kubeton-prometheus' in selector and 'kubeton-grafana' in selector
    for item in state['deployments']:
        if item.get('owner') != 'kubeton': continue
        print('|'.join(str(item.get(k,'')) for k in ['ns','name','replicas','saved','uid','version','component']))
elif args[:2] == ['patch','deployment']:
    item = next(i for i in state['deployments'] if i['ns']==ns and i['name']==args[2])
    if state.get('patch_error') == item['name']: fail('synthetic patch denied')
    body = json.loads(args[args.index('-p')+1])
    if '--type=merge' in args:
        assert body['metadata']['uid'] == item['uid']
        assert body['metadata']['resourceVersion'] == item['version']
        item['replicas'] = body['spec']['replicas']
        annotations = body['metadata'].get('annotations',{})
        if annotations: item['saved'] = annotations['ton.ton.org/kubeton-dashboard-paused-replicas']
    else:
        assert '--type=json' in args and len(body)==4
        assert body[0]['value'] == item['uid']
        assert body[1]['value'] == item['replicas']
        assert body[2]['value'] == item['saved']
        assert body[3]['op'] == 'remove'
        if state.get('ack_error'): fail('synthetic concurrent edit')
        item.pop('saved',None)
    item['version'] = str(int(item['version'])+1)
    save()
elif args[:2] == ['rollout','status']:
    name = args[2].split('/',1)[1]
    if state.get('rollout_error') == name: fail('synthetic rollout timeout')
elif args[:2] == ['get','pods']:
    selector = args[args.index('-l')+1]
    assert 'managed-by' not in selector, 'older Pods lack this label'
    component = selector.split(',')[0].split('=',1)[1]
    for item in state['deployments']:
        if item['ns']==ns and item['component']==component and item.get('owner')=='kubeton':
            if component=='kubeton-prometheus' and 'instance='+item['name'] not in selector: continue
            print(item['name']+'-legacy-pod')
elif args[:2] == ['wait','--for=delete']:
    if state.get('wait_error'): fail('synthetic Pod termination timeout')
else: fail('unexpected Kubernetes mutation: '+repr(args))
'''


def deployment(component, replicas=1, ns="monitoring", owner="kubeton", saved=None):
    item = dict(ns=ns, name=component, replicas=replicas, uid=component+"-uid", version="1",
                component=component, owner=owner)
    if saved is not None:
        item["saved"] = saved
    return item


class DashboardLifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        binary = self.root / "kubectl"
        binary.write_text(FAKE)
        binary.chmod(0o755)
        self.state = {"deployments": [deployment("kubeton-prometheus"), deployment("kubeton-grafana", 2)],
                      "secrets": {"prometheus-admin": "synthetic-stable-password", "grafana-admin": "synthetic-stable-password"},
                      "config": {"dashboards": "existing-provisioned-dashboard"}}
        self.write()

    def write(self):
        (self.root / "state").write_text(json.dumps(self.state))

    def run_cli(self, function):
        body = '''source "$1"
require_bin() { :; }
list_ton_statefulsets() { [[ "$DASHBOARD_TEST_TON_INVENTORY_ERROR" != true ]]; }
if [[ "$DASHBOARD_TEST_TON_BACKUP_ERROR" == true ]]; then
  SKIP_STOP_KEY_BACKUP=false
  run_stop_backup() { return 1; }
fi
cleanup_prometheus_port_forwards() { printf 'prometheus-forward-closed\n' >>"$DASHBOARD_TEST_ROOT/forwards"; }
cleanup_grafana_port_forwards() { printf 'grafana-forward-closed\n' >>"$DASHBOARD_TEST_ROOT/forwards"; }
"$2" || exit $?
'''
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", body, "_", str(CLI), function],
                                env=dict(os.environ, DASHBOARD_TEST_ROOT=str(self.root),
                                         DASHBOARD_TEST_TON_INVENTORY_ERROR=str(self.state.get("ton_inventory_error", False)).lower(),
                                         DASHBOARD_TEST_TON_BACKUP_ERROR=str(self.state.get("ton_backup_error", False)).lower(),
                                         PATH=str(self.root)+os.pathsep+os.environ["PATH"]),
                                capture_output=True, text=True, timeout=10)
        self.state = json.loads((self.root / "state").read_text())
        return result

    def test_stop_pauses_dashboards_even_without_ton_fleet(self):
        before = copy.deepcopy(self.state)
        result = self.run_cli("run_stop")
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual([x["replicas"] for x in self.state["deployments"]], [0, 0])
        self.assertEqual([x["saved"] for x in self.state["deployments"]], ["1", "2"])
        self.assertEqual(before["secrets"], self.state["secrets"])
        self.assertEqual(before["config"], self.state["config"])
        self.assertEqual(len((self.root / "forwards").read_text().splitlines()), 2)
        events = (self.root / "events").read_text()
        self.assertIn('"wait", "--for=delete"', events)
        self.assertNotIn('"delete"', events)

    def test_failed_ton_inventory_prevents_false_stop_success(self):
        self.state["ton_inventory_error"] = True
        self.write()
        result = self.run_cli("run_stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[stop] Paused", result.stdout)
        self.assertEqual([x["replicas"] for x in self.state["deployments"]], [1, 2])

    def test_failed_ton_backup_prevents_stopping_the_fleet(self):
        self.state["ton_backup_error"] = True
        self.write()
        result = self.run_cli("run_stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[stop] Paused", result.stdout)
        self.assertEqual([x["replicas"] for x in self.state["deployments"]], [1, 2])

    def test_repeated_stop_preserves_original_replicas_then_resume(self):
        for _ in range(2):
            result = self.run_cli("stop_managed_dashboard_workloads")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x["saved"] for x in self.state["deployments"]], ["1", "2"])
        result = self.run_cli("resume_stopped_dashboard_workloads")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x["replicas"] for x in self.state["deployments"]], [1, 2])
        self.assertTrue(all("saved" not in x for x in self.state["deployments"]))

    def test_stop_and_resume_leave_unowned_dashboards_unchanged(self):
        foreign = deployment("kubeton-prometheus", 3, ns="shared", owner="external")
        self.state["deployments"].append(foreign)
        self.write()
        self.assertEqual(self.run_cli("stop_managed_dashboard_workloads").returncode, 0)
        self.assertEqual(self.run_cli("resume_stopped_dashboard_workloads").returncode, 0)
        self.assertEqual(self.state["deployments"][-1], foreign)

    def test_zero_replicas_without_pause_marker_stays_disabled(self):
        self.state["deployments"] = [deployment("kubeton-grafana", 0)]
        self.write()
        self.assertEqual(self.run_cli("stop_managed_dashboard_workloads").returncode, 0)
        self.assertEqual(self.run_cli("resume_stopped_dashboard_workloads").returncode, 0)
        self.assertEqual(self.state["deployments"][0]["replicas"], 0)
        self.assertNotIn("saved", self.state["deployments"][0])

    def test_resume_does_not_install_dashboards(self):
        result = self.run_cli("resume_stopped_dashboard_workloads")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = (self.root / "events").read_text()
        self.assertNotIn('"patch"', events)
        self.assertNotIn('"apply"', events)

    def test_inventory_errors_fail_closed(self):
        self.state["inventory_error"] = True
        self.write()
        for action in ("stop_managed_dashboard_workloads", "resume_stopped_dashboard_workloads"):
            result = self.run_cli(action)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual([x["replicas"] for x in self.state["deployments"]], [1, 2])

    def test_patch_failure_is_reported_and_other_dashboard_still_paused(self):
        self.state["patch_error"] = "kubeton-prometheus"
        self.write()
        result = self.run_cli("stop_managed_dashboard_workloads")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[stop] Paused", result.stdout)
        self.assertEqual([x["replicas"] for x in self.state["deployments"]], [1, 0])

    def test_pods_still_terminating_prevent_success(self):
        self.state["wait_error"] = True
        self.write()
        result = self.run_cli("stop_managed_dashboard_workloads")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[stop] Paused", result.stdout)
        self.assertTrue(all("saved" in x for x in self.state["deployments"]))

    def test_failed_resume_retains_marker_and_retries_successfully(self):
        self.assertEqual(self.run_cli("stop_managed_dashboard_workloads").returncode, 0)
        self.state["rollout_error"] = "kubeton-grafana"
        self.write()
        self.assertNotEqual(self.run_cli("resume_stopped_dashboard_workloads").returncode, 0)
        self.assertEqual(self.state["deployments"][1]["saved"], "2")
        self.state.pop("rollout_error")
        self.write()
        self.assertEqual(self.run_cli("resume_stopped_dashboard_workloads").returncode, 0)
        self.assertNotIn("saved", self.state["deployments"][1])

    def test_concurrent_edit_does_not_discard_resume_state(self):
        self.assertEqual(self.run_cli("stop_managed_dashboard_workloads").returncode, 0)
        self.state["ack_error"] = True
        self.write()
        self.assertNotEqual(self.run_cli("resume_stopped_dashboard_workloads").returncode, 0)
        self.assertTrue(all("saved" in x for x in self.state["deployments"]))


if __name__ == "__main__":
    unittest.main()
