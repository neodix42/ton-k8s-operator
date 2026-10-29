#!/usr/bin/env python3
"""Exercise dashboard credentials, generated resources, and real HTTP login checks."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "charts/ton-k8s-operator/kubeton"
USERNAME = "fixture-admin"
PASSWORD = "fixture-secret-'\"\\:$()[]!;?|#"
AUTH = "Basic " + base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()


KUBECTL = r'''
import base64, json, os, pathlib, re, sys, time
root = pathlib.Path(os.environ["DASHBOARD_STATE"])
args = sys.argv[1:]
namespace = "default"
if args[:1] in (["-n"], ["--namespace"]):
    namespace, args = args[1], args[2:]
def scalar(value):
    value = value.strip()
    if value.startswith("'"): return value[1:-1].replace("''", "'")
    if value.startswith('"'): return json.loads(value)
    return value
def store(document):
    if document.lstrip().startswith("{"): obj = json.loads(document)
    else:
        kind = re.search(r"^kind: (.+)$", document, re.M)
        if not kind or kind[1] != "Secret": return
        metadata = re.search(r"^metadata:\n((?:[ \t].*\n)*)", document, re.M)
        name = re.search(r"^  name: (.+)$", metadata[1], re.M)[1]
        obj = {"kind": "Secret", "metadata": {"name": scalar(name)}, "data": {}}
        for section in ("data", "stringData"):
            block = re.search(r"^" + section + r":\n((?:[ \t].*(?:\n|$))*)", document, re.M)
            if not block: continue
            lines = block[1].splitlines()
            i = 0
            while i < len(lines):
                match = re.match(r"^  ([\w.-]+):(?: (.*))?$", lines[i])
                if not match: i += 1; continue
                key, value = match[1], match[2] or ""
                i += 1
                if value in ("|", "|-", "|+"):
                    content = []
                    while i < len(lines) and lines[i].startswith("    "):
                        content.append(lines[i][4:]); i += 1
                    value = "\n".join(content) + ("" if value == "|-" else "\n")
                else: value = scalar(value)
                obj["data"][key] = (base64.b64encode(value.encode()).decode()
                                       if section == "stringData" else value)
    if obj.get("kind") != "Secret": return
    for key, value in obj.pop("stringData", {}).items():
        obj.setdefault("data", {})[key] = base64.b64encode(value.encode()).decode()
    name = obj["metadata"]["name"]
    path = root / f"{namespace}__{name}.json"
    previous = json.loads(path.read_text()) if path.exists() else {}
    revision = int(previous.get("metadata", {}).get("resourceVersion", "0"))
    if obj.get("data") != previous.get("data"): revision += 1
    obj["metadata"]["resourceVersion"] = str(revision)
    path.write_text(json.dumps(obj))
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps({"namespace": namespace, "args": args}) + "\n")
if args[:2] == ["get", "secret"]:
    if os.environ.get("DASHBOARD_READ_ERROR"):
        print("Error from server (Forbidden): cannot read secrets", file=sys.stderr); sys.exit(1)
    name = args[2]
    path = root / f"{namespace}__{name}.json"
    if not path.exists():
        if "--ignore-not-found" in args or "--ignore-not-found=true" in args: sys.exit(0)
        print("Error from server (NotFound): secrets not found", file=sys.stderr); sys.exit(1)
    obj = json.loads(path.read_text())
    query = next((a for a in args if a.startswith("jsonpath=")), None)
    if query:
        match = re.search(r"\.data\.([^}]+)", query)
        if match: print(obj.get("data", {}).get(match[1], ""), end="")
        else: raise AssertionError("unsupported fixture jsonpath " + query)
    elif "json" in args: print(json.dumps(obj))
elif args[:1] == ["apply"]:
    document = sys.stdin.read()
    number = len(list(root.glob("apply-*.yaml")))
    (root / f"apply-{number}.yaml").write_text(document)
    for part in re.split(r"^---\s*$", document, flags=re.M): store(part)
elif args[:2] == ["rollout", "status"]:
    if os.environ.get("DASHBOARD_ROLLOUT_ERROR"): sys.exit(1)
elif args[:1] == ["port-forward"]:
    (root / f"forward-{os.getpid()}.pid").write_text(str(os.getpid()))
    print("Forwarding from fixture", flush=True)
    time.sleep(60)
elif args[:2] == ["get", "namespace"]: pass
else: raise AssertionError("Unexpected kubectl request: " + str(args))
'''


class LoginServer:
    def __init__(self, anonymous=401, authenticated=200):
        self.requests = []
        self.config_headers = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                authorization = self.headers.get("Authorization")
                fixture.requests.append((self.path, authorization))
                fixture.config_headers.append(self.headers.get("X-Curlrc-Must-Not-Be-Read"))
                status = authenticated if authorization == AUTH else anonymous
                self.send_response(status)
                if status == 401:
                    self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
                if status == 302:
                    self.send_header("Location", "/unexpected-redirect")
                self.end_headers()
                self.wfile.write(b"private-response-must-not-be-printed")

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


class DashboardAuthenticationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.addCleanup(self.cleanup_forwards)
        bindir = self.root / "bin"
        bindir.mkdir()
        kubectl = bindir / "kubectl"
        kubectl.write_text("#!/usr/bin/env python3\n" + KUBECTL)
        kubectl.chmod(0o755)
        real_curl = shutil.which("curl")
        if real_curl:
            curl = bindir / "curl"
            curl.write_text(
                "#!/usr/bin/env python3\n"
                "import hashlib, json, os, pathlib, sys\n"
                "path = pathlib.Path(os.environ['DASHBOARD_STATE']) / 'curl.jsonl'\n"
                "with path.open('a') as output:\n"
                "    output.write(json.dumps({'argv': sys.argv[1:], 'environment': "
                "[hashlib.sha256(v.encode()).hexdigest() for v in os.environ.values()]}) + '\\n')\n"
                f"os.execv({real_curl!r}, [{real_curl!r}, *sys.argv[1:]])\n")
            curl.chmod(0o755)
        self.env = dict(os.environ, DASHBOARD_STATE=str(self.root),
                        PATH=str(bindir) + os.pathsep + os.environ["PATH"])
        # A developer's credential overrides must not influence the fixtures.
        for name in ("GRAFANA_ADMIN_USER", "GRAFANA_ADMIN_PASSWORD", "PROMETHEUS_ADMIN_USER",
                     "PROMETHEUS_ADMIN_PASSWORD", "GRAFANA_ADMIN_SECRET_NAME", "PROMETHEUS_ADMIN_SECRET_NAME"):
            self.env.pop(name, None)
        self.env.update(PROMETHEUS_PORT="9090", PROMETHEUS_LOCAL_PORT_BASE="9090",
                        GRAFANA_PORT="3000", GRAFANA_LOCAL_PORT_BASE="3000",
                        PROMETHEUS_PORT_FORWARD_DIR=str(self.root / "prometheus-forwards"),
                        GRAFANA_PORT_FORWARD_DIR=str(self.root / "grafana-forwards"))

    def run_cli(self, script, *, check=True):
        result = subprocess.run(["bash", "-s", "--", str(CLI)],
                                input='source "$1"\n' + script,
                                capture_output=True, text=True, env=self.env, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def put_secret(self, namespace, name, data):
        encoded = {key: base64.b64encode(value.encode()).decode() for key, value in data.items()}
        (self.root / f"{namespace}__{name}.json").write_text(json.dumps({
            "kind": "Secret", "metadata": {"name": name, "resourceVersion": "1"}, "data": encoded}))

    def get_secret(self, namespace, name):
        obj = json.loads((self.root / f"{namespace}__{name}.json").read_text())
        return {key: base64.b64decode(value).decode() for key, value in obj["data"].items()}

    def manifests(self):
        return "\n---\n".join(path.read_text() for path in sorted(self.root.glob("apply-*.yaml")))

    def cleanup_forwards(self):
        for path in self.root.glob("forward-*.pid"):
            try:
                os.kill(int(path.read_text()), 15)
            except ProcessLookupError:
                pass

    def test_prometheus_credentials_are_random_hashed_and_reused(self):
        first = self.run_cli("ensure_prometheus_admin_secret fixture-ns kubeton-prometheus-admin\n")
        username, password = first.stdout.rstrip("\n").split("\t")
        self.assertEqual(username, "admin")
        self.assertGreaterEqual(len(password), 24)
        self.assertNotEqual(password, "admin")
        secret = self.get_secret("fixture-ns", "kubeton-prometheus-admin")
        self.assertEqual(secret["admin-password"], password)
        self.assertEqual(secret["admin-user"], username)
        web_config = secret["web-config.yml"]
        self.assertIn("basic_auth_users:", web_config)
        self.assertNotIn(password, web_config)
        hashed = re.search(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", web_config)
        self.assertIsNotNone(hashed, "Prometheus web config needs a bcrypt hash")
        try:
            import bcrypt
        except ImportError:
            pass
        else:
            self.assertTrue(bcrypt.checkpw(password.encode(), hashed[0].encode()))
        before = self.manifests()
        second = self.run_cli("ensure_prometheus_admin_secret fixture-ns kubeton-prometheus-admin\n")
        self.assertEqual(second.stdout, first.stdout, "a repeated start rotated login credentials")
        self.assertEqual(self.manifests(), before, "existing credentials were unnecessarily rewritten")

    def test_grafana_credentials_are_random_and_reused(self):
        first = self.run_cli("ensure_grafana_admin_secret fixture-ns kubeton-grafana-admin\n")
        username, password = first.stdout.rstrip("\n").split("\t")
        self.assertEqual(username, "admin")
        self.assertGreaterEqual(len(password), 24)
        self.assertNotEqual(password, "admin")
        self.assertEqual(self.get_secret("fixture-ns", "kubeton-grafana-admin")["admin-password"], password)
        before = self.manifests()
        second = self.run_cli("ensure_grafana_admin_secret fixture-ns kubeton-grafana-admin\n")
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(self.manifests(), before)

    def test_existing_credentials_preserve_password_punctuation(self):
        self.put_secret("fixture-ns", "kubeton-grafana-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD})
        result = self.run_cli("ensure_grafana_admin_secret fixture-ns kubeton-grafana-admin\n")
        self.assertEqual(result.stdout, USERNAME + "\t" + PASSWORD + "\n")
        self.assertEqual(self.manifests(), "")

    def test_explicit_prometheus_password_survives_hashing_and_secret_encoding(self):
        password = "  " + PASSWORD + "  "
        self.env.update(PROMETHEUS_ADMIN_USER=USERNAME, PROMETHEUS_ADMIN_PASSWORD=password)
        result = self.run_cli("ensure_prometheus_admin_secret fixture-ns kubeton-prometheus-admin\n")
        self.assertEqual(result.stdout, USERNAME + "\t" + password + "\n")
        secret = self.get_secret("fixture-ns", "kubeton-prometheus-admin")
        self.assertEqual(secret["admin-password"], password)
        hashed = re.search(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", secret["web-config.yml"])
        self.assertIsNotNone(hashed)
        try:
            import bcrypt
        except ImportError:
            pass
        else:
            self.assertTrue(bcrypt.checkpw(password.encode(), hashed[0].encode()))

    def test_prometheus_hash_generation_works_without_python_bcrypt(self):
        import ctypes.util
        if not ctypes.util.find_library("crypt"):
            self.skipTest("libcrypt is unavailable on this platform")
        # -S excludes optional site packages, reproducing plain Python 3.13+
        # where neither the removed crypt module nor bcrypt is available.
        wrapper = self.root / "bin" / "python3"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(shutil.which("python3")) + ' -S "$@"\n')
        wrapper.chmod(0o755)
        result = self.run_cli("ensure_prometheus_admin_secret fixture-ns kubeton-prometheus-admin\n")
        self.assertTrue(result.stdout)
        secret = self.get_secret("fixture-ns", "kubeton-prometheus-admin")
        hashed = re.search(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", secret["web-config.yml"])
        self.assertIsNotNone(hashed)

    def test_unreadable_credentials_fail_without_replacement(self):
        self.env["DASHBOARD_READ_ERROR"] = "yes"
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product):
                result = self.run_cli(f"ensure_{product}_admin_secret fixture-ns fixture-secret\n", check=False)
                self.assertNotEqual(result.returncode, 0, "an API read failure was treated as a missing Secret")
                self.assertEqual(self.manifests(), "", "read failure replaced login credentials")

    def test_incomplete_existing_grafana_secret_is_not_replaced(self):
        self.put_secret("fixture-ns", "kubeton-grafana-admin", {"admin-user": USERNAME})
        result = self.run_cli("ensure_grafana_admin_secret fixture-ns kubeton-grafana-admin\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.manifests(), "", "malformed Secret caused password rotation")

    def test_prometheus_deployment_uses_web_auth_secret_and_safe_probes(self):
        result = self.run_cli(
            'targets="$(build_prometheus_static_targets_yaml 10.1.2.3:9777)"\n'
            'ensure_exporter_prometheus_stack fixture-ns tonnode 9777 "$targets"\n')
        self.assertIn("kubeton-prometheus-tonnode", result.stdout)
        manifest = self.manifests()
        self.assertIn("--web.config.file=", manifest)
        self.assertIn("kubeton-prometheus-admin", manifest)
        self.assertIn("web-config.yml", manifest)
        self.assertIn("secretName:", manifest)
        self.assertNotIn("Authorization:", manifest, "Kubernetes probes must not embed a plaintext login")
        self.assertNotIn("httpGet:", manifest, "authenticated Prometheus must not have anonymous HTTP probes")
        self.assertNotIn("auth-checksum:", manifest, "a Pod annotation must not expose password-derived data")

    def test_grafana_provisions_authenticated_datasources_from_secrets(self):
        self.put_secret("fixture-ns", "kubeton-prometheus-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD})
        result = self.run_cli(
            'datasources="$(build_grafana_datasources_yaml '
            "$'fixture-ns\\tkubeton-prometheus-tonnode\\tkubeton-prometheus-tonnode\\t9777')\"\n"
            'ensure_grafana_stack fixture-ns "$datasources" "apiVersion: 1" \'{"panels": []}\'\n')
        self.assertIn("kubeton-grafana", result.stdout)
        manifest = self.manifests()
        datasource = next(part for part in re.split(r"^---\s*$", manifest, flags=re.M)
                          if "name: kubeton-grafana-datasources\n" in part)
        self.assertIn("kind: Secret", datasource)
        self.assertNotIn("kind: ConfigMap", datasource)
        stored = self.get_secret("fixture-ns", "kubeton-grafana-datasources")["datasources.yaml"]
        self.assertIn("basicAuth: true", stored)
        self.assertIn(USERNAME, stored)
        self.assertIn("basicAuthPassword:", stored)
        self.assertIn("secureJsonData:", stored)
        provisioned_password = json.loads(re.search(r"basicAuthPassword: (.+)", stored)[1])
        self.assertEqual(provisioned_password.replace("$$", "$"), PASSWORD,
                         "Grafana provisioning would expand a literal password dollar sign")
        self.assertIn("GF_AUTH_ANONYMOUS_ENABLED", manifest)
        self.assertRegex(manifest, r'GF_AUTH_ANONYMOUS_ENABLED\n\s+value: "false"')
        self.assertRegex(manifest, r"name: datasources\n\s+secret:\n\s+secretName: kubeton-grafana-datasources")
        annotations = re.search(r"      annotations:\n((?:        .*\n)*)", manifest)[1]
        for value in (PASSWORD, f"{USERNAME}\t{PASSWORD}"):
            self.assertNotIn(hashlib.sha256(value.encode()).hexdigest(), annotations,
                             "a publicly readable Pod annotation contains a password-derived hash")
        datasource_checksum = subprocess.run(["cksum"], input=stored, text=True,
                                             capture_output=True, check=True).stdout.split()[0]
        self.assertNotIn(datasource_checksum, annotations,
                         "a Pod annotation exposes a cheap password-derived checksum")
        self.assertRegex(annotations, r'ton\.ton\.org/auth-checksum: "1"')
        self.assertRegex(annotations, r'ton\.ton\.org/datasources-checksum: "1"')
        for document in re.split(r"^---\s*$", manifest, flags=re.M):
            if "kind: ConfigMap" in document:
                self.assertNotIn(PASSWORD, document)
                self.assertNotIn("basicAuthPassword", document)

    def test_datasource_setup_fails_if_prometheus_credentials_are_missing(self):
        result = self.run_cli('build_grafana_datasources_yaml '
                              "$'fixture-ns\\tkubeton-prometheus-tonnode\\tdeployment\\t9777'\n", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_grafana_rollout_uses_secret_revisions_without_password_checksums(self):
        self.put_secret("fixture-ns", "kubeton-prometheus-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD})
        script = (
            'datasources="$(build_grafana_datasources_yaml '
            "$'fixture-ns\\tkubeton-prometheus-tonnode\\tdeployment\\t9777')\"\n"
            'ensure_grafana_stack fixture-ns "$datasources" "apiVersion: 1" \'{"panels": []}\'\n')

        def annotations():
            deployment = [part for part in re.split(r"^---\s*$", self.manifests(), flags=re.M)
                          if "kind: Deployment\n" in part and "name: kubeton-grafana\n" in part][-1]
            return re.search(r"      annotations:\n((?:        .*\n)*)", deployment)[1]

        self.run_cli(script)
        initial = annotations()
        self.run_cli(script)
        self.assertEqual(annotations(), initial, "unchanged credentials forced a fresh Grafana rollout")
        self.put_secret("fixture-ns", "kubeton-prometheus-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD + "-rotated"})
        self.run_cli(script)
        changed = annotations()
        self.assertRegex(changed, r'ton\.ton\.org/datasources-checksum: "2"')
        self.assertRegex(changed, r'ton\.ton\.org/auth-checksum: "1"')
        self.assertNotEqual(changed, initial, "changed datasource credentials did not trigger a rollout")

    def probe(self, product, server, seconds=0):
        if shutil.which("curl") is None:
            self.skipTest("curl is required for real HTTP authentication checks")
        result = self.run_cli(f"wait_{product}_http_ready {server.port} {seconds} "
                              f"{shlex.quote(USERNAME)} {shlex.quote(PASSWORD)}\n", check=False)
        output = result.stdout + result.stderr
        for private in (USERNAME, PASSWORD, AUTH, "private-response-must-not-be-printed"):
            self.assertNotIn(private, output, "HTTP login check leaked a credential or response body")
        curl_calls = self.root / "curl.jsonl"
        if curl_calls.exists():
            sensitive = (USERNAME, PASSWORD, AUTH, f"{USERNAME}:{PASSWORD}", AUTH.split(" ", 1)[1])
            for line in curl_calls.read_text().splitlines():
                call = json.loads(line)
                for value in sensitive:
                    self.assertNotIn(value, " ".join(call["argv"]), "curl argv exposed credentials")
                    self.assertNotIn(hashlib.sha256(value.encode()).hexdigest(), call["environment"],
                                     "curl environment exposed credentials")
        expected_path = "/api/user" if product == "grafana" else "/api/v1/status/buildinfo"
        for path, authorization in server.requests:
            self.assertEqual(path, expected_path)
            self.assertIn(authorization, (None, AUTH))
        return result

    def test_authentication_probes_require_401_anonymously_and_200_with_password(self):
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product), LoginServer() as server:
                result = self.probe(product, server)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(any(auth is None for _, auth in server.requests))
                self.assertTrue(any(auth == AUTH for _, auth in server.requests))

    def test_zero_timeout_does_not_skip_anonymous_access_check(self):
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product), LoginServer(anonymous=200) as server:
                result = self.probe(product, server)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(server.requests, "zero timeout bypassed the authentication check")

    def test_rejected_password_does_not_publish_access(self):
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product), LoginServer(authenticated=401) as server:
                result = self.probe(product, server)
                self.assertNotEqual(result.returncode, 0)

    def test_login_check_does_not_follow_redirects(self):
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product), LoginServer(authenticated=302) as server:
                result = self.probe(product, server)
                self.assertNotEqual(result.returncode, 0)

    def test_curlrc_cannot_inject_headers_or_enable_redirects(self):
        curl_home = self.root / "curl-home"
        curl_home.mkdir()
        (curl_home / ".curlrc").write_text(
            'location\nheader = "X-Curlrc-Must-Not-Be-Read: fixture-injection"\n')
        self.env["CURL_HOME"] = str(curl_home)
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product), LoginServer() as server:
                result = self.probe(product, server)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(server.requests)
                self.assertTrue(all(header is None for header in server.config_headers),
                                "a local curlrc injected headers into the login check")
            with self.subTest(product=product, redirect=True), LoginServer(authenticated=302) as server:
                result = self.probe(product, server)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(all(path != "/unexpected-redirect" for path, _ in server.requests))
        for line in (self.root / "curl.jsonl").read_text().splitlines():
            self.assertEqual(json.loads(line)["argv"][0], "--disable",
                             "curl must disable its implicit configuration before reading other arguments")

    def test_start_commands_print_the_dashboard_credentials(self):
        self.put_secret("fixture-ns", "kubeton-prometheus-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD})
        common = '''
require_bin() { :; }
configure_prometheus_for_exporter_targets() {
  local -n output_rows="$1"
  output_rows=($'fixture-ns\\tkubeton-prometheus-tonnode\\tdeployment\\t9777')
}
prometheus_port_forward_address() { printf 127.0.0.1; }
grafana_port_forward_address() { printf 127.0.0.1; }
ensure_prometheus_port_forward() { printf 'fixture-ns\\tkubeton-prometheus-tonnode\\t9090\\t123\\t/tmp/fixture.log\\n'; }
ensure_grafana_port_forward() { printf 'fixture-ns\\tkubeton-grafana\\t3000\\t123\\t/tmp/fixture.log\\n'; }
'''
        result = self.run_cli(common + "run_prometheus_start\n")
        self.assertIn(USERNAME, result.stdout)
        self.assertIn(PASSWORD, result.stdout)
        self.assertIn("http://127.0.0.1:9090", result.stdout)
        self.put_secret("fixture-ns", "kubeton-grafana-admin", {
            "admin-user": USERNAME, "admin-password": PASSWORD})
        result = self.run_cli(common + "GRAFANA_NAMESPACE=fixture-ns\nrun_grafana_start\n")
        self.assertIn(USERNAME, result.stdout)
        self.assertIn(PASSWORD, result.stdout)
        self.assertIn("http://127.0.0.1:3000", result.stdout)

    def test_failed_rollouts_prevent_new_dashboard_listeners(self):
        self.env["DASHBOARD_ROLLOUT_ERROR"] = "yes"
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product):
                self.put_secret("fixture-ns", "kubeton-prometheus-admin", {
                    "admin-user": USERNAME, "admin-password": PASSWORD,
                    "web-config.yml": "basic_auth_users: {}"})
                self.put_secret("fixture-ns", "kubeton-grafana-admin", {
                    "admin-user": USERNAME, "admin-password": PASSWORD})
                script = '''
require_bin() { :; }
cleanup_prometheus_port_forwards() { printf prometheus-cleanup >"$DASHBOARD_STATE/cleanup"; }
cleanup_grafana_port_forwards() { printf grafana-cleanup >"$DASHBOARD_STATE/cleanup"; }
ensure_prometheus_port_forward() { printf unexpected >"$DASHBOARD_STATE/listener"; }
ensure_grafana_port_forward() { printf unexpected >"$DASHBOARD_STATE/listener"; }
GRAFANA_NAMESPACE=fixture-ns
'''
                if product == "prometheus":
                    script += '''
configure_prometheus_for_exporter_targets() {
  local -n rows="$1"
  local row
  row="$(ensure_exporter_prometheus_stack fixture-ns tonnode 9777 '            - "10.1.2.3:9777"')" || return 1
  rows=("$row")
}
'''
                else:
                    script += '''
configure_prometheus_for_exporter_targets() {
  local -n rows="$1"
  rows=($'fixture-ns\\tkubeton-prometheus-tonnode\\tdeployment\\t9777')
}
'''
                result = self.run_cli(script + f"run_{product}_start\n", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "listener").exists(), "a failed rollout started a new listener")
                self.assertNotIn("Background access:", result.stdout)
                self.assertNotIn("Remote access:", result.stdout)

    def test_startup_cleanup_does_not_kill_an_unrelated_process_from_a_stale_pidfile(self):
        def cleanup(process):
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)

        for product in ("prometheus", "grafana"):
            with self.subTest(product=product):
                unrelated = subprocess.Popen(["sleep", "60"])
                self.addCleanup(cleanup, unrelated)
                state_dir = Path(self.env[f"{product.upper()}_PORT_FORWARD_DIR"])
                state_dir.mkdir()
                pidfile = state_dir / f"fixture-ns__kubeton-{product}__19090.pid"
                pidfile.write_text(str(unrelated.pid))
                result = self.run_cli(f'''
configure_prometheus_for_exporter_targets() {{ return 1; }}
run_{product}_start
''', check=False)
                self.assertNotEqual(result.returncode, 0, "a fixture without TON targets unexpectedly started")
                self.assertIsNone(unrelated.poll(), "startup cleanup killed an unrelated process with a reused PID")
                self.assertFalse(pidfile.exists(), "a stale PID file was left for the next startup")

    def test_port_forward_checks_credentials_on_the_actual_bind_host(self):
        for product in ("prometheus", "grafana"):
            self.put_secret("fixture-ns", f"kubeton-{product}-admin", {
                "admin-user": USERNAME, "admin-password": PASSWORD})
            for index, (bind, expected_host) in enumerate((
                    ("0.0.0.0", "127.0.0.1"), ("192.0.2.10", "192.0.2.10"))):
                with self.subTest(product=product, bind=bind):
                    script = f'''
{product.upper()}_PORT_FORWARD_DIR="$DASHBOARD_STATE/state-{product}-{index}"
{product.upper()}_PORT_FORWARD_WAIT_SECONDS=3
wait_{product}_http_ready() {{ printf '%s\\n' "$@" >"$DASHBOARD_STATE/probe"; }}
ensure_{product}_port_forward fixture-ns kubeton-{product} 19090 9090 {shlex.quote(bind)}
'''
                    self.run_cli(script)
                    probe = (self.root / "probe").read_text().splitlines()
                    self.assertEqual(probe, ["19090", "20", USERNAME, PASSWORD, expected_host])

    def test_rejected_authentication_stops_the_forward_and_removes_its_pidfile(self):
        for product in ("prometheus", "grafana"):
            with self.subTest(product=product):
                self.put_secret("fixture-ns", f"kubeton-{product}-admin", {
                    "admin-user": USERNAME, "admin-password": PASSWORD})
                result = self.run_cli(f'''
{product.upper()}_PORT_FORWARD_DIR="$DASHBOARD_STATE/rejected-{product}"
{product.upper()}_PORT_FORWARD_WAIT_SECONDS=3
wait_{product}_http_ready() {{ return 1; }}
ensure_{product}_port_forward fixture-ns kubeton-{product} 19090 9090 0.0.0.0 true
''', check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list((self.root / f"rejected-{product}").glob("*.pid")), [])
                for path in self.root.glob("forward-*.pid"):
                    pid = int(path.read_text())
                    deadline = time.monotonic() + 1
                    while True:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        process = Path(f"/proc/{pid}/stat")
                        if process.exists() and process.read_text().split()[2] == "Z":
                            break  # terminated, awaiting its operating-system reaper
                        self.assertLess(time.monotonic(), deadline,
                                        "failed authentication left the dashboard listener running")
                        time.sleep(0.01)


if __name__ == "__main__":
    unittest.main()
