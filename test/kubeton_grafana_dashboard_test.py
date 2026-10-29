#!/usr/bin/env python3
"""Exercise the generated TON dashboard and its Grafana provisioning contract."""

import hashlib
import http.server
import json
import re
import shlex
import sys
import threading
import unittest

sys.dont_write_bytecode = True
import kubeton_dashboard_auth_test as auth


class DashboardServer:
    def __init__(self, *, uid="kubeton-ton-overview", panels=None, status=200, malformed=False):
        self.requests = []
        fixture = self
        payload = {"dashboard": {"uid": uid, "panels": [{"id": 1}] if panels is None else panels},
                   "meta": {"fixture": "private-dashboard-response-must-not-be-printed"}}
        body = b"not-json" if malformed else json.dumps(payload).encode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                authorization = self.headers.get("Authorization")
                fixture.requests.append((self.path, authorization))
                self.send_response(status if authorization == auth.AUTH else 401)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def port(self):
        return self.server.server_address[1]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class GrafanaDashboardTest(unittest.TestCase):
    def setUp(self):
        # Reuse the API fixture, without inheriting (and repeating) its login tests.
        self.fixture = auth.DashboardAuthenticationTest(methodName="runTest")
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.fixture.env.pop("GRAFANA_DASHBOARD_UID", None)
        self.fixture.env.pop("GRAFANA_DASHBOARD_TITLE", None)
        for namespace in ("fixture-ns", "other-ns"):
            self.fixture.put_secret(namespace, "kubeton-prometheus-admin", {
                "admin-user": auth.USERNAME, "admin-password": auth.PASSWORD})

    def run_cli(self, script):
        return self.fixture.run_cli(script).stdout

    def dashboard(self, *, title=None):
        if title is not None:
            self.fixture.env["GRAFANA_DASHBOARD_TITLE"] = title
        return json.loads(self.run_cli(
            "build_grafana_ton_overview_dashboard_json "
            "kubeton-prometheus-fixture-ns-kubeton-prometheus-tonnode\n"))

    @staticmethod
    def parse_datasources(document):
        result = []
        current = None
        for line in document.splitlines():
            if line.startswith("  - name:"):
                current = {"name": json.loads(line.split(":", 1)[1].strip())}
                result.append(current)
            elif current is not None:
                match = re.match(r"^    ([A-Za-z]+): (.+)$", line)
                if match:
                    value = match[2]
                    current[match[1]] = json.loads(value) if value.startswith('"') else value
        return result

    def test_datasource_uids_are_stable_across_service_order_and_namespaces(self):
        rows = ["fixture-ns\tkubeton-prometheus-tonnode\tdeployment\t9777",
                "other-ns\tkubeton-prometheus-tonnode\tdeployment\t9777"]
        outputs = [self.run_cli("build_grafana_datasources_yaml " +
                                " ".join(shlex.quote(row) for row in order) + "\n")
                   for order in (rows, list(reversed(rows)))]
        parsed = [self.parse_datasources(output) for output in outputs]
        identities = [{source["name"]: source["uid"] for source in sources}
                      for sources in parsed]
        self.assertEqual(identities[0], identities[1],
                         "dashboard datasource references must survive discovery reordering")
        self.assertEqual(len(set(identities[0].values())), 2,
                         "same-named services in different namespaces collided")
        for sources in parsed:
            self.assertEqual([source["isDefault"] for source in sources], ["true", "false"])
            for source in sources:
                self.assertRegex(source["uid"], r"^[A-Za-z0-9_-]{1,40}$")
                expected_uid = "P" + hashlib.sha256(source["name"].encode()).hexdigest()[:16].upper()
                self.assertEqual(source["uid"], expected_uid,
                                 "existing Grafana 11.2.2 datasource identities must be preserved")
                self.assertEqual(source["type"], "prometheus")
                self.assertEqual(source["basicAuth"], "true")

    def test_dashboard_is_valid_with_unique_panels_and_escaped_custom_title(self):
        title = 'TON "validators" — first line\nsecond line $HOME'
        dashboard = self.dashboard(title=title)
        self.assertEqual(dashboard["title"], title)
        self.assertEqual(dashboard["uid"], "kubeton-ton-overview")
        self.assertTrue(dashboard["refresh"], "fleet status should refresh automatically")
        panels = dashboard["panels"]
        self.assertGreater(len(panels), 3,
                           "the old starter dashboard only described Prometheus scraping")
        panel_ids = [panel["id"] for panel in panels]
        self.assertEqual(len(panel_ids), len(set(panel_ids)))
        for panel in panels:
            self.assertTrue(panel["title"])
            self.assertGreater(panel["gridPos"]["h"], 0)
            self.assertGreater(panel["gridPos"]["w"], 0)
            references = [target["refId"] for target in panel.get("targets", [])]
            self.assertEqual(len(references), len(set(references)))

    def test_dashboard_selects_provisioned_prometheus_by_uid(self):
        row = "fixture-ns\tkubeton-prometheus-tonnode\tdeployment\t9777"
        sources = self.parse_datasources(self.run_cli(
            "build_grafana_datasources_yaml " + shlex.quote(row) + "\n"))
        dashboard = self.dashboard()
        variables = dashboard["templating"]["list"]
        datasource = next(variable for variable in variables if variable["type"] == "datasource")
        self.assertEqual(datasource["query"], "prometheus")
        self.assertEqual(datasource["current"]["value"], sources[0]["uid"],
                         "Grafana's datasource dropdown requires its provisioned UID")
        variable_name = datasource["name"]
        variable_refs = {"$" + variable_name, "${" + variable_name + "}"}
        for panel in dashboard["panels"]:
            if not panel.get("targets"):
                continue
            self.assertEqual(panel["datasource"]["type"], "prometheus")
            self.assertIn(panel["datasource"]["uid"], variable_refs)

    def test_dashboard_filters_jobs_and_nodes_in_each_panel(self):
        dashboard = self.dashboard()
        variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
        for name in ("job", "instance"):
            variable = variables[name]
            self.assertEqual(variable["type"], "query")
            self.assertTrue(variable["multi"], f"{name} must support comparing multiple targets")
            self.assertTrue(variable["includeAll"], f"{name} must support the whole fleet")
            self.assertIn("${datasource}", variable["datasource"]["uid"])
        job_query = json.dumps(variables["job"]["query"])
        self.assertIn("ton-exporter-", job_query,
                      "the dashboard must exclude unrelated Prometheus scrape jobs")
        self.assertIsNotNone(re.fullmatch(variables["job"]["allValue"], "ton-exporter-tonnode"))
        self.assertIsNone(re.fullmatch(variables["job"]["allValue"], "prometheus"),
                          "All TON jobs must not include Prometheus or other exporters")
        instance_query = json.dumps(variables["instance"]["query"])
        self.assertIn("${job:regex}", instance_query)
        for panel in dashboard["panels"]:
            for target in panel.get("targets", []):
                expression = target["expr"]
                self.assertIn('${job:regex}', expression,
                              f"{panel['title']} ignores the chosen scrape job")
                self.assertIn('${instance:regex}', expression,
                              f"{panel['title']} ignores the chosen TON node")

    def test_dashboard_identity_is_preserved_across_provisioning_updates(self):
        first = self.dashboard()
        second = self.dashboard()
        self.assertEqual(first, second,
                         "restarting Grafana should not create a new dashboard or new panel identities")
        self.fixture.env["GRAFANA_DASHBOARD_UID"] = "custom-ton-fleet"
        self.assertEqual(self.dashboard()["uid"], "custom-ton-fleet")

    def test_native_ton_queries_cover_sync_and_node_activity(self):
        # Families verified in TON v2026.10/metrics/METRICS.md, the shipped image.
        targets = [target for panel in self.dashboard()["panels"]
                   for target in panel.get("targets", [])]
        expressions = [target["expr"] for target in targets]
        combined = "\n".join(expressions)
        for metric in ("ton_masterchain_seqno", "ton_masterchain_block_age_seconds",
                       "ton_shardclient_seqno", "ton_adnl_wire_bytes_total",
                       "ton_actor_worker_busy_ticks_total", "ton_mempool_ext_messages"):
            self.assertIn(metric, combined,
                          "the default dashboard must display native TON statistics, not only scrape health")
        for expression in expressions:
            if "_total" in expression or "_bucket" in expression:
                self.assertIn("rate(", expression, "cumulative counters should be shown as rates")
                self.assertIn("$__rate_interval", expression)
        self.assertNotRegex(combined, r"ton_(?:celldb|archive_db|memory|filesystem)_",
                            "the native TON exporter does not expose OS or database-size families")

    def test_default_home_and_provider_resolve_to_the_mounted_dashboard(self):
        row = "fixture-ns\tkubeton-prometheus-tonnode\tdeployment\t9777"
        self.run_cli('datasources="$(build_grafana_datasources_yaml ' + shlex.quote(row) + ')"\n'
                     'providers="$(build_grafana_dashboards_provisioning_yaml)"\n'
                     'dashboard="$(build_grafana_ton_overview_dashboard_json '
                     'kubeton-prometheus-fixture-ns-kubeton-prometheus-tonnode)"\n'
                     'ensure_grafana_stack fixture-ns "$datasources" "$providers" "$dashboard"\n')
        manifest = self.fixture.manifests()
        home = re.search(r"name: GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH\n\s+value: ([^\n]+)",
                         manifest)
        self.assertIsNotNone(home, "login should open the preinstalled TON dashboard")
        home_path = home[1].strip().strip('"')
        self.assertEqual(home_path, "/var/lib/grafana/dashboards/kubeton/ton-overview.json")
        self.assertIn("path: /var/lib/grafana/dashboards/kubeton", manifest)
        self.assertIn("mountPath: /var/lib/grafana/dashboards/kubeton", manifest)
        self.assertIn("ton-overview.json: |", manifest)
        self.assertRegex(manifest, r'GF_AUTH_ANONYMOUS_ENABLED\n\s+value: "false"')
        self.assertRegex(manifest, r"name: datasources\n\s+secret:\n\s+secretName: kubeton-grafana-datasources")
        for document in re.split(r"^---\s*$", manifest, flags=re.M):
            if "kind: ConfigMap" in document:
                self.assertNotIn(auth.PASSWORD, document)
                self.assertNotIn("basicAuthPassword", document)

    def test_start_prints_a_direct_ton_dashboard_link(self):
        self.fixture.put_secret("fixture-ns", "kubeton-grafana-admin", {
            "admin-user": auth.USERNAME, "admin-password": auth.PASSWORD})
        output = self.run_cli('''
require_bin() { :; }
configure_prometheus_for_exporter_targets() {
  local -n output_rows="$1"
  output_rows=($'fixture-ns\\tkubeton-prometheus-tonnode\\tdeployment\\t9777')
}
grafana_port_forward_address() { printf 127.0.0.1; }
ensure_grafana_port_forward() { printf 'fixture-ns\\tkubeton-grafana\\t3000\\t123\\t/tmp/fixture.log\\n'; }
wait_grafana_dashboard_ready() { :; }
GRAFANA_NAMESPACE=fixture-ns
run_grafana_start
''')
        self.assertRegex(output, r"http://127\.0\.0\.1:3000/d/kubeton-ton-overview(?:[/ ?\n]|$)")
        self.assertIn(auth.USERNAME, output)
        self.assertIn(auth.PASSWORD, output)

    def wait_for_dashboard(self, server, *, check=True):
        return self.fixture.run_cli("wait_grafana_dashboard_ready " + " ".join(
            shlex.quote(value) for value in (str(server.port), "1", auth.USERNAME, auth.PASSWORD,
                                            "kubeton-ton-overview")) + "\n", check=check)

    def test_dashboard_is_verified_through_authenticated_grafana_api(self):
        with DashboardServer() as server:
            result = self.wait_for_dashboard(server)
        self.assertTrue(server.requests, "readiness must query Grafana, rather than assume file mount succeeded")
        self.assertTrue(all(request == ("/api/dashboards/uid/kubeton-ton-overview", auth.AUTH)
                            for request in server.requests))
        self.assertNotIn(auth.PASSWORD, result.stdout + result.stderr)
        self.assertNotIn("private-dashboard-response", result.stdout + result.stderr)

    def test_dashboard_readiness_rejects_unprovisioned_and_invalid_responses(self):
        for options in ({"status": 404}, {"uid": "wrong-dashboard"}, {"panels": []}, {"malformed": True}):
            with self.subTest(options=options), DashboardServer(**options) as server:
                result = self.wait_for_dashboard(server, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(auth.PASSWORD, result.stdout + result.stderr)
                self.assertNotIn("private-dashboard-response", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
