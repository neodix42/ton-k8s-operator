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
from urllib.parse import parse_qs, urlsplit

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

    @classmethod
    def all_panels(cls, dashboard):
        """Collapsed Grafana rows store their queries in nested panels."""
        for panel in dashboard.get("panels", []):
            yield panel
            yield from cls.all_panels(panel)

    @classmethod
    def all_targets(cls, dashboard):
        return [target for panel in cls.all_panels(dashboard)
                for target in panel.get("targets", [])]

    @staticmethod
    def metric_selectors(expression):
        # Grafana template interpolation braces are not PromQL selector braces.
        untemplated = re.sub(r"\$\{[^}]+\}", "TEMPLATE", expression)
        return re.findall(r"\b(ton_[a-zA-Z0-9_]+)\{([^}]*)\}", untemplated)

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
        panels = list(self.all_panels(dashboard))
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
        for panel in self.all_panels(dashboard):
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
        for panel in self.all_panels(dashboard):
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
        targets = self.all_targets(self.dashboard())
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
                if "$__rate_interval" not in expression:
                    self.assertIn("[${window}s]", expression)
                    self.assertIn("[1m]", expression,
                                  "10s windows cannot estimate a rate with 15s scrapes")
                    compact = re.sub(r"\s+", "", expression)
                    self.assertIn("vector(${window})>=60", compact)
                    self.assertIn("vector(${window})<60", compact)
        self.assertNotRegex(combined, r"ton_(?:celldb|archive_db|memory|filesystem)_",
                            "the native TON exporter does not expose OS or database-size families")

    def test_requested_recent_ranges_keep_dashboard_filters(self):
        dashboard = self.dashboard()
        links = {link["title"]: link for link in dashboard.get("links", [])}
        for duration in ("1h", "2h", "6h", "1d", "1w", "30d", "90d", "180d", "365d"):
            with self.subTest(duration=duration):
                self.assertIn(duration, links, "requested recent range is missing")
                link = links[duration]
                query = parse_qs(urlsplit(link["url"]).query)
                self.assertEqual(query.get("from"), ["now-" + duration])
                self.assertEqual(query.get("to"), ["now"])
                self.assertTrue(link.get("includeVars"),
                                "changing the range must preserve the selected nodes and datasource")

    def test_recent_range_links_follow_a_custom_dashboard_uid(self):
        self.fixture.env["GRAFANA_DASHBOARD_UID"] = "custom-ton-fleet"
        dashboard = self.dashboard()
        self.assertTrue(dashboard["links"])
        for link in dashboard["links"]:
            self.assertEqual(urlsplit(link["url"]).path, "/d/custom-ton-fleet",
                             "changing the range must not navigate to an unprovisioned default UID")
            self.assertFalse(link.get("keepTime", False),
                             "the old time range must not override the clicked recent range")

    def test_window_choices_use_safe_scrape_ranges(self):
        dashboard = self.dashboard()
        variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
        window = variables["window"]
        self.assertEqual(window["type"], "custom")
        self.assertEqual(window["label"], "Window size")
        self.assertFalse(window.get("multi", False))
        self.assertEqual(str(window["current"]["value"]), "60")
        choices = {option["text"]: str(option["value"]) for option in window["options"]}
        self.assertEqual(choices, {"10s": "10", "1m": "60", "5m": "300",
                                   "15m": "900", "1h": "3600"})
        session_targets = [target for target in self.all_targets(dashboard)
                           if "[${window}s]" in target["expr"]]
        self.assertTrue(session_targets, "Window size must actually change the new statistics queries")
        for target in session_targets:
            self.assertEqual(target.get("interval"), "15s",
                             "a selected 10s window must not lower the actual 15s scrape minimum")
            compact = re.sub(r"\s+", "", target["expr"])
            self.assertIn("[1m]", compact)
            self.assertIn("vector(${window})>=60", compact)
            self.assertIn("vector(${window})<60", compact)

    def test_native_session_workload_queue_and_cache_metrics_are_available(self):
        dashboard = self.dashboard()
        panels = list(self.all_panels(dashboard))
        rows = {panel["title"] for panel in panels if panel["type"] == "row"}
        self.assertTrue({"Block production and workload", "Message queues and overload",
                         "Collation and validation time", "Storage-stat cache"} <= rows)
        expressions = "\n".join(target["expr"] for target in self.all_targets(dashboard))
        for family in ("ton_collated_blocks_total", "ton_collation_transactions_total",
                       "ton_collation_gas_total", "ton_collation_block_bytes_total",
                       "ton_collation_collated_data_bytes_total", "ton_collation_ext_messages_offered_total",
                       "ton_collation_out_queue_size", "ton_collation_out_queue_cleaned_total",
                       "ton_collation_out_queue_processed_total", "ton_collation_out_queue_skipped_total",
                       "ton_collation_want_split_total", "ton_collation_overload_total",
                       "ton_collation_storage_cache_lookups_total", "ton_collation_storage_cache_cells_total",
                       "ton_collation_elapsed_seconds_total", "ton_block_processing_seconds_total"):
            with self.subTest(family=family):
                self.assertIn(family + "{", expressions)
        self.assertNotRegex(expressions, r"ton_(?:liteserver_tps|session_tps|test_runs|load_fraction|.*_estimate)(?:_|\{)")
        for panel in panels:
            if panel.get("targets"):
                self.assertNotIn("LiteServer", panel["title"],
                                 "native collator measurements are not LiteServer chain statistics")
                self.assertNotRegex(panel["title"].lower(), r"(?:test runs|size estimate|load fractions)")
                self.assertNotIn("or vector(0)", " ".join(target["expr"] for target in panel["targets"]),
                                 "an absent exporter family must remain No data")

    def test_first_slot_filters_only_apply_to_supported_metric_families(self):
        dashboard = self.dashboard()
        variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
        self.assertFalse(variables["chain"].get("multi", False))
        self.assertFalse(variables["first"].get("multi", False))
        for name, all_value, choices in (("chain", "master|shard", {"master", "shard"}),
                                          ("first", "0|1", {"0", "1"})):
            variable = variables[name]
            self.assertTrue(variable["includeAll"])
            self.assertEqual(variable["allValue"], all_value,
                             "All must use Grafana's unescaped regex override")
            self.assertEqual({str(option["value"]) for option in variable["options"]}
                             - {"$__all"}, choices)
            self.assertEqual(variable["current"]["value"], "$__all")
        allowed = {"ton_collated_blocks_total", "ton_collation_transactions_total",
                   "ton_collation_elapsed_seconds_total"}
        filtered = set()
        for target in self.all_targets(dashboard):
            expression = target["expr"]
            selectors = self.metric_selectors(expression)
            for family, labels in selectors:
                if re.search(r"(?:^|,)\s*first\s*=", labels):
                    self.assertIn(family, allowed,
                                  f"{family} does not expose a first-in-window label")
                    filtered.add(family)
            if "/" in expression and any(family in {"ton_collation_transactions_total",
                                                      "ton_collation_elapsed_seconds_total"}
                                         for family, _labels in selectors):
                first_filters = {re.search(r'first\s*=~?\s*"[^"]*"', labels)[0]
                                 for family, labels in selectors if family in allowed
                                 and re.search(r'first\s*=~?\s*"[^"]*"', labels)}
                self.assertEqual(len(first_filters), 1,
                                 "per-block numerator and denominator must select the same window population")
                for family, labels in selectors:
                    if family in allowed:
                        self.assertRegex(labels, r'first\s*=~?\s*"',
                                         "a filtered numerator cannot be divided by all blocks")
        self.assertEqual(filtered, allowed)

    def test_workload_averages_use_successful_blocks_without_first_filter_leakage(self):
        unsplit = {"ton_collation_gas_total", "ton_collation_block_bytes_total",
                   "ton_collation_collated_data_bytes_total", "ton_collation_ext_messages_offered_total",
                   "ton_collation_out_queue_cleaned_total", "ton_collation_out_queue_processed_total",
                   "ton_collation_out_queue_skipped_total"}
        checked = set()
        for target in self.all_targets(self.dashboard()):
            selectors = self.metric_selectors(target["expr"])
            families = {family for family, _labels in selectors}
            if not (families & unsplit) or "ton_collated_blocks_total" not in families:
                continue
            checked.update(families & unsplit)
            for family, labels in selectors:
                self.assertNotRegex(labels, r"(?:^|,)\s*first\s*=",
                                    "unsplit workload must use an unsplit block denominator")
                if family == "ton_collated_blocks_total":
                    self.assertIn('result="ok"', labels,
                                  "workload counters count only successful final candidates")
            self.assertNotIn("clamp_min", target["expr"],
                             "clamping the block rate to 1 distorts per-block averages at low activity")
        self.assertEqual(checked, unsplit)

    def test_per_block_charts_omit_zero_activity_instead_of_dividing_by_zero(self):
        checked = 0
        for target in self.all_targets(self.dashboard()):
            expression = target["expr"]
            if "[${window}s]" not in expression or "/" not in expression:
                continue
            selectors = self.metric_selectors(expression)
            if not any(family in {"ton_collated_blocks_total", "ton_validated_blocks_total"}
                       for family, _labels in selectors):
                continue
            checked += 1
            self.assertRegex(expression, r">\s*0\s*\)\s*$",
                             "a validator with no successful blocks must produce No data, not infinity")
        self.assertGreater(checked, 10, "block-normalized workload and timing charts are missing")

    def test_axis_ratios_disambiguate_group_left_from_the_denominator(self):
        # Without the explicit (), Prometheus parses the following parenthesized
        # denominator as group_left's label list and rejects the expression.
        axis_metrics = {"ton_collation_overload_total", "ton_collation_ext_messages_total",
                        "ton_collation_storage_cache_lookups_total",
                        "ton_collation_storage_cache_cells_total"}
        checked = set()
        for target in self.all_targets(self.dashboard()):
            expression = target["expr"]
            families = {family for family, _labels in self.metric_selectors(expression)}
            if "ton_collated_blocks_total" not in families or not (families & axis_metrics):
                continue
            checked.update(families & axis_metrics)
            self.assertRegex(expression, r"\bgroup_left\s*\(\s*\)\s*\(",
                             "per-outcome/reason ratios need an explicit empty group_left label list")
        self.assertEqual(checked, axis_metrics)

    def test_cache_hit_rate_excludes_small_uncacheable_accounts(self):
        panels = {panel["title"]: panel for panel in self.all_panels(self.dashboard())}
        target = panels["Storage-stat eligible lookup hit rate"]["targets"][0]
        selectors = self.metric_selectors(target["expr"])
        outcomes = {re.search(r'outcome\s*=~?\s*"([^"]+)"', labels)[1]
                    for family, labels in selectors
                    if family == "ton_collation_storage_cache_lookups_total"}
        self.assertEqual(outcomes, {"hit", "hit|miss"},
                         "small accounts are never cached and must not lower eligible cache effectiveness")
        self.assertRegex(target["expr"], r">\s*0\s*\)\s*$")

    def test_test_runs_are_real_tagged_grafana_annotations(self):
        annotations = self.dashboard()["annotations"]["list"]
        test_runs = next(annotation for annotation in annotations if annotation["name"] == "Test runs")
        self.assertTrue(test_runs["enable"])
        self.assertEqual(test_runs["datasource"]["type"], "grafana")
        self.assertEqual(test_runs["target"]["type"], "tags")
        self.assertEqual(test_runs["target"]["tags"], ["ton-run"],
                         "test markers must come from explicitly recorded runs")

    def test_timing_charts_use_actual_operation_clocks(self):
        clocks = set()
        for target in self.all_targets(self.dashboard()):
            for family, labels in self.metric_selectors(target["expr"]):
                if family != "ton_block_processing_seconds_total":
                    continue
                self.assertIn('phase="total"', labels)
                self.assertIn('result="ok"', labels)
                self.assertNotIn("first=", labels,
                                 "timing counters have no first-in-window axis")
                operation = re.search(r'operation="([^"]+)"', labels)
                clock = re.search(r'clock="([^"]+)"', labels)
                self.assertIsNotNone(operation)
                self.assertIsNotNone(clock)
                clocks.add((operation[1], clock[1]))
        self.assertTrue({("collate", "real"), ("collate", "cpu"),
                         ("validate", "real"), ("validate", "cpu")} <= clocks)

    def test_collated_tps_is_per_node_and_out_queue_is_not_claimed_per_shard(self):
        for panel in self.all_panels(self.dashboard()):
            for target in panel.get("targets", []):
                expression = target["expr"]
                if "ton_collation_transactions_total{" in expression:
                    groups = re.findall(r"\bsum\s+by\s*\(([^)]*)\)", expression)
                    self.assertTrue(groups)
                    self.assertTrue(all("instance" in {label.strip() for label in group.split(",")}
                                        for group in groups),
                                    "candidate transaction curves must retain node identity")
                if "ton_collation_out_queue_size{" in expression:
                    self.assertNotIn("per shard", panel["title"].lower())
                    self.assertNotIn("{{shard}}", target.get("legendFormat", ""))
                    for family, labels in self.metric_selectors(expression):
                        if family == "ton_collation_out_queue_size":
                            self.assertNotRegex(labels, r"(?:^|,)\s*shard\s*=",
                                                "queue gauge is last collation per chain, not per shard")

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
