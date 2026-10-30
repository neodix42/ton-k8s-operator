#!/usr/bin/env python3
"""Exercise production StorageClass queries with the actual kubectl renderer.

An isolated HTTP fixture serves only discovery and StorageClass LIST responses.
The real kubectl receives an explicit loopback server and empty kubeconfig;
no real cluster, credentials, Helm release or filesystem storage is used.
"""

import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import urlsplit


REPO = Path(__file__).resolve().parents[1]
KUBETON = REPO / "charts/ton-k8s-operator/kubeton"
REAL_KUBECTL = shutil.which("kubectl")
STABLE_DEFAULT = "storageclass.kubernetes.io/is-default-class"
BETA_DEFAULT = "storageclass.beta.kubernetes.io/is-default-class"


def storage_class(name, provisioner="driver.longhorn.io", annotations=None):
    metadata = {"name": name}
    if annotations is not None:
        metadata["annotations"] = annotations
    return {
        "apiVersion": "storage.k8s.io/v1",
        "kind": "StorageClass",
        "metadata": metadata,
        "provisioner": provisioner,
    }


class StorageClassQueryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if REAL_KUBECTL is None:
            raise RuntimeError("kubectl is required to test its actual Go template renderer")
        cls.items = []
        cls.denied = False
        cls.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                cls.requests.append(self.path)
                path = urlsplit(self.path).path.rstrip("/")
                code = 200
                if path == "/api":
                    data = {"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]}
                elif path == "/api/v1":
                    data = {"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "v1", "resources": []}
                elif path == "/apis":
                    version = {"groupVersion": "storage.k8s.io/v1", "version": "v1"}
                    data = {
                        "kind": "APIGroupList", "apiVersion": "v1",
                        "groups": [{"name": "storage.k8s.io", "versions": [version], "preferredVersion": version}],
                    }
                elif path == "/apis/storage.k8s.io/v1":
                    data = {
                        "kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "storage.k8s.io/v1",
                        "resources": [{"name": "storageclasses", "singularName": "storageclass", "namespaced": False,
                                       "kind": "StorageClass", "verbs": ["get", "list"]}],
                    }
                elif path == "/apis/storage.k8s.io/v1/storageclasses":
                    if cls.denied:
                        code = 403
                        data = {"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "Forbidden",
                                "message": "storageclasses.storage.k8s.io is forbidden: fixture access denied", "code": code}
                    else:
                        data = {"apiVersion": "storage.k8s.io/v1", "kind": "StorageClassList", "items": cls.items}
                else:
                    code = 404
                    data = {"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "NotFound", "code": code}
                body = json.dumps(data).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        type(self).items = []
        type(self).denied = False
        type(self).requests = []

    def query(self, function, *arguments):
        env = os.environ.copy()
        env["TEST_REAL_KUBECTL"] = REAL_KUBECTL
        env["TEST_STORAGE_API"] = f"http://127.0.0.1:{self.server.server_port}"
        with tempfile.TemporaryDirectory() as cache:
            env["TEST_STORAGE_CACHE"] = cache
            result = subprocess.run(
                ["bash", "-c", '''
set -euo pipefail
source "$1"
kubectl() {
  command "$TEST_REAL_KUBECTL" --kubeconfig=/dev/null --server="$TEST_STORAGE_API" \
    --cache-dir="$TEST_STORAGE_CACHE" --request-timeout=3s "$@"
}
"$2" "${@:3}"
''', "_", str(KUBETON), function, *arguments],
                env=env, capture_output=True, text=True, timeout=15,
            )
        self.assertTrue(any(urlsplit(path).path == "/apis/storage.k8s.io/v1/storageclasses" for path in self.requests),
                        "production query did not reach the isolated StorageClass API")
        return result

    def assert_selection(self, expected, configured="", function="resolve_victoria_logs_backend_storage"):
        args = () if function == "node_check_autodetect_storage_class" else (configured,)
        result = self.query(function, *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)
        self.assertNotIn("index of untyped nil", result.stderr)

    def test_fresh_longhorn_inventory_with_absent_empty_and_unrelated_annotations(self):
        null_annotations = storage_class("null-annotations")
        null_annotations["metadata"]["annotations"] = None
        type(self).items = [
            storage_class("local-path", "rancher.io/local-path", {STABLE_DEFAULT: "true"}),
            storage_class("longhorn"),
            storage_class("longhorn-static"),
            storage_class("encrypted-sc", annotations={}),
            storage_class("other", annotations={"example.org/note": "unrelated"}),
            null_annotations,
        ]
        self.assert_selection("longhorn\tdriver.longhorn.io")

    def test_explicit_class_wins_over_longhorn_and_default(self):
        type(self).items = [storage_class("longhorn"), storage_class("premium-rwo", "pd.csi.storage.gke.io", {STABLE_DEFAULT: "true"})]
        self.assert_selection("premium-rwo\tpd.csi.storage.gke.io", "premium-rwo")

    def test_explicit_class_without_annotations(self):
        type(self).items = [storage_class("custom-log-store")]
        self.assert_selection("custom-log-store\tdriver.longhorn.io", "custom-log-store")

    def test_stable_and_legacy_default_annotations(self):
        for annotation in (STABLE_DEFAULT, BETA_DEFAULT):
            with self.subTest(annotation=annotation):
                type(self).items = [storage_class("unannotated"), storage_class("premium-rwo", "pd.csi.storage.gke.io", {annotation: "true"})]
                self.assert_selection("premium-rwo\tpd.csi.storage.gke.io")

    def test_both_default_annotations_count_class_once(self):
        type(self).items = [storage_class("default", annotations={STABLE_DEFAULT: "true", BETA_DEFAULT: "true"})]
        self.assert_selection("default\tdriver.longhorn.io")

    def test_unresolved_storage_stays_an_error(self):
        fixtures = [
            ([], "", "found 0"),
            ([storage_class("unannotated"), storage_class("empty", annotations={})], "", "found 0"),
            ([storage_class("a", annotations={STABLE_DEFAULT: "true"}), storage_class("b", annotations={BETA_DEFAULT: "true"})], "", "found 2"),
            ([storage_class("longhorn")], "missing", "'missing' is missing"),
            ([storage_class("bad", provisioner="")], "bad", "no readable provisioner"),
        ]
        for items, configured, diagnostic in fixtures:
            with self.subTest(diagnostic=diagnostic, configured=configured):
                type(self).items = items
                result = self.query("resolve_victoria_logs_backend_storage", configured)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(diagnostic, result.stderr)

    def test_api_error_preserves_underlying_diagnostic_for_both_callers(self):
        type(self).denied = True
        for function, args in (("resolve_victoria_logs_backend_storage", ("",)), ("node_check_autodetect_storage_class", ())):
            with self.subTest(function=function):
                result = self.query(function, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("fixture access denied", result.stderr)
                self.assertIn("Error: cannot", result.stderr)

    def test_ton_preflight_retains_local_class_preference(self):
        type(self).items = [storage_class("longhorn"), storage_class("longhorn-static"), storage_class("local-path", "rancher.io/local-path", {})]
        self.assert_selection("local-path", function="node_check_autodetect_storage_class")

    def test_ton_preflight_can_read_legacy_default_and_missing_annotations(self):
        type(self).items = [storage_class("aaa-unannotated"), storage_class("premium-rwo", "pd.csi.storage.gke.io", {BETA_DEFAULT: "true"})]
        self.assert_selection("premium-rwo\n", function="node_check_autodetect_storage_class")


if __name__ == "__main__":
    unittest.main(verbosity=2)
