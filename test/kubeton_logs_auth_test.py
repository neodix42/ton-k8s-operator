#!/usr/bin/env python3
"""Verify dashboard authentication with local HTTP servers and the real curl."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import threading
import unittest


REPO = Path(__file__).resolve().parents[1]
KUBETON = REPO / "charts/ton-k8s-operator/kubeton"
USERNAME = "fixture-dashboard-user"
PASSWORD = "  fixture-secret-'\"\\:$()[]!;?|#  "
TOKEN = base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()
AUTHORIZATION = f"Basic {TOKEN}"
RESPONSE_BODY = "dashboard-response-body-must-stay-private"


class DashboardServer:
    def __init__(self, anonymous_status=401, authenticated_status=200, transient=0):
        self.anonymous_status = anonymous_status
        self.authenticated_status = authenticated_status
        self.transient = transient
        self.requests = []
        self.authenticated_requests = 0
        self.lock = threading.Lock()
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                authorization = self.headers.get("Authorization")
                with fixture.lock:
                    fixture.requests.append((self.path, authorization))
                    if authorization == AUTHORIZATION:
                        fixture.authenticated_requests += 1
                        status = (401 if fixture.authenticated_requests <= fixture.transient
                                  else fixture.authenticated_status)
                    elif authorization:
                        status = 401
                    else:
                        status = fixture.anonymous_status
                self.send_response(status)
                self.send_header("Content-Length", str(len(RESPONSE_BODY)))
                if status == 401:
                    self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
                if status == 302:
                    self.send_header("Location", "/redirect-must-not-be-followed")
                self.end_headers()
                self.wfile.write(RESPONSE_BODY.encode())

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    @property
    def port(self):
        return self.server.server_address[1]


class LogsAuthenticationTest(unittest.TestCase):
    def setUp(self):
        self.real_curl = shutil.which("curl")
        if self.real_curl is None:
            self.skipTest("curl is required")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.arguments = self.root / "curl-arguments.jsonl"
        bindir = self.root / "bin"
        bindir.mkdir()
        wrapper = bindir / "curl"
        # Only hashes of environment values are recorded; the real process keeps
        # stdin unchanged, so curl must actually parse the supplied config.
        wrapper.write_text(
            "#!/usr/bin/env python3\n"
            "import hashlib, json, os, sys\n"
            "digests = [hashlib.sha256(value.encode()).hexdigest() "
            "for value in os.environ.values()]\n"
            f"with open({str(self.arguments)!r}, 'a') as output:\n"
            "    output.write(json.dumps({'argv': sys.argv[1:], "
            "'environment_digests': digests}) + '\\n')\n"
            f"os.execv({self.real_curl!r}, [{self.real_curl!r}, *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"])

    def verify(self, server, *, timeout=1, credentials=True, real_resolver=False):
        if credentials:
            resolution = "printf '%s\\t%s\\t%s\\n' " + " ".join(
                shlex.quote(value) for value in ("vmuser-fixture", USERNAME, PASSWORD)
            )
        else:
            resolution = "return 1"
        resolution_function = (
            "resolve_victoria_metrics_credentials() {\n"
            '  [[ "$1" == fixture-ns && "$2" == fixture-stack '
            '&& "$3" == "" && "$4" == "" ]] || return 1\n'
            f"  {resolution}\n"
            "}\n"
        )
        if real_resolver:
            encoded_username = base64.b64encode(USERNAME.encode()).decode()
            encoded_password = base64.b64encode(PASSWORD.encode()).decode()
            resolution_function = (
                'kubectl() {\n'
                '  [[ "$1" == -n && "$2" == fixture-ns && "$3" == get '
                '&& "$4" == secret && "$5" == vmuser-fixture-stack ]] || return 1\n'
                '  case "${7:-}" in\n'
                f"    'jsonpath={{.data.username}}') printf '%s' {shlex.quote(encoded_username)} ;;\n"
                f"    'jsonpath={{.data.password}}') printf '%s' {shlex.quote(encoded_password)} ;;\n"
                '    "") return 0 ;;\n'
                '    *) return 1 ;;\n'
                '  esac\n'
                '}\n'
            )
        script = (
            'source "$1"\n'
            + resolution_function
            + f"VICTORIA_METRICS_PORT_FORWARD_VERIFY_SECONDS={timeout}\n"
            'verify_logs_dashboard_auth fixture-ns fixture-stack "$2"\n'
        )
        result = subprocess.run(
            ["bash", "-s", "--", str(KUBETON), str(server.port)],
            input=script, capture_output=True, text=True, env=self.env, timeout=15,
        )
        output = result.stdout + result.stderr
        for secret in (USERNAME, PASSWORD, TOKEN, AUTHORIZATION, RESPONSE_BODY):
            self.assertNotIn(secret, output, "authentication data or response body leaked")
        calls = ([json.loads(line) for line in self.arguments.read_text().splitlines()]
                 if self.arguments.exists() else [])
        secret_digests = {
            hashlib.sha256(value.encode()).hexdigest()
            for value in (USERNAME, PASSWORD, TOKEN, AUTHORIZATION,
                          f"{USERNAME}:{PASSWORD}")
        }
        for call in calls:
            arguments = call["argv"]
            for secret in (USERNAME, PASSWORD, TOKEN, AUTHORIZATION):
                self.assertNotIn(secret, " ".join(arguments), "curl argv exposed credentials")
            self.assertTrue(secret_digests.isdisjoint(call["environment_digests"]),
                            "curl environment exposed credentials")
            self.assertNotIn("--location", arguments, "authentication must not follow redirects")
            self.assertNotIn("-L", arguments, "authentication must not follow redirects")
        for path, authorization in server.requests:
            self.assertEqual(path, "/select/vmui/", "unexpected redirect or URL credential")
            if authorization:
                self.assertEqual(authorization, AUTHORIZATION,
                                 "credential punctuation or surrounding spaces changed")
        if server.authenticated_requests:
            self.assertTrue(any(
                any(argument in ("--config", "-K") and index + 1 < len(call["argv"])
                    and call["argv"][index + 1] == "-"
                    for index, argument in enumerate(call["argv"]))
                for call in calls
            ), "credential header must be supplied through curl config on stdin")
        return result, calls

    def test_success_preserves_password_spaces_and_punctuation(self):
        with DashboardServer() as server:
            result, calls = self.verify(server)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertGreaterEqual(len(calls), 2)
            self.assertTrue(any(authorization is None for _, authorization in server.requests))
            self.assertGreaterEqual(server.authenticated_requests, 1)

    def test_transient_auth_rejection_is_retried(self):
        with DashboardServer(transient=1) as server:
            result, _ = self.verify(server, timeout=2)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertGreaterEqual(server.authenticated_requests, 2)

    def test_real_secret_resolver_preserves_password_spaces(self):
        with DashboardServer() as server:
            result, _ = self.verify(server, real_resolver=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertGreaterEqual(server.authenticated_requests, 1)

    def test_persistent_auth_rejection_has_distinct_status(self):
        with DashboardServer(authenticated_status=401) as server:
            result, _ = self.verify(server)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertGreaterEqual(server.authenticated_requests, 1)

    def test_forbidden_credentials_have_distinct_status(self):
        with DashboardServer(anonymous_status=403, authenticated_status=403) as server:
            result, _ = self.verify(server)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_backend_gateway_failure_is_not_reported_as_bad_credentials(self):
        with DashboardServer(authenticated_status=502) as server:
            result, _ = self.verify(server)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_anonymous_dashboard_is_rejected(self):
        with DashboardServer(anonymous_status=200) as server:
            result, _ = self.verify(server)
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_authentication_redirect_is_not_followed(self):
        with DashboardServer(authenticated_status=302) as server:
            result, _ = self.verify(server)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_missing_credentials_fail_before_http_probe(self):
        with DashboardServer() as server:
            result, calls = self.verify(server, credentials=False)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(calls, [])
            self.assertEqual(server.requests, [])

    def test_zero_timeout_uses_default_instead_of_skipping_probe(self):
        with DashboardServer() as server:
            result, _ = self.verify(server, timeout=0)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertGreaterEqual(server.authenticated_requests, 1)


if __name__ == "__main__":
    unittest.main()
