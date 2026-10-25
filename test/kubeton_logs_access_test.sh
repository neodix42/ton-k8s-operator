#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { ! grep -Fq -- "$1" "$2" || fail "unexpected '$1' in $2"; }

(
  source "$kubeton"
  run_with_timeout() { shift; "$@"; }
  banner_mode=backend
  kubectl() {
    case "$1/$2" in
      get/services)
        if [[ "$5" == app.kubernetes.io/name=vmauth ]]; then
          [[ "$banner_mode" == backend ]] || printf 'auth-ns\tcustom-stack\n'
        else
          printf 'private-logs\tcustom-backend\t19428\n'
        fi
        ;;
      get/configmaps)
        [[ "$banner_mode" != auth ]] || printf 'auth-ns\tcustom-stack\n'
        ;;
      -n/auth-ns)
        if [[ "$3/$4/$5" == get/vmuser/custom-stack ]]; then
          printf 'http://custom-backend.private-logs.svc:19428\t/select/.*\n'
        elif [[ "$3/$4/$5" == get/service/vmauth-custom-stack ]]; then
          printf 18427
        else
          fail 'banner queried credentials or changed a resource'
        fi
        ;;
      *) fail 'banner queried credentials or changed a resource' ;;
    esac
  }
  print_logs_victoria_logs_info >"$test_dir/backend-banner"
  assert_contains 'in-cluster only): http://custom-backend.private-logs.svc:19428/select/vmui/' "$test_dir/backend-banner"
  assert_contains 'port-forward --address 127.0.0.1 service/custom-backend 19428:19428' "$test_dir/backend-banner"
  assert_contains './kubeton logs expose' "$test_dir/backend-banner"
  assert_not_contains 'SSH' "$test_dir/backend-banner"
  assert_not_contains 'http://203.0.113.27' "$test_dir/backend-banner"

  banner_mode=auth
  print_logs_victoria_logs_info >"$test_dir/auth-banner"
  assert_contains 'VMAuth credentials' "$test_dir/auth-banner"
  assert_contains 'port-forward --address 127.0.0.1 service/vmauth-custom-stack 18427:18427' "$test_dir/auth-banner"
  assert_contains './kubeton logs expose' "$test_dir/auth-banner"
  assert_not_contains 'SSH' "$test_dir/auth-banner"
  assert_not_contains 'http://203.0.113.27' "$test_dir/auth-banner"

  banner_mode=auth-no-state
  print_logs_victoria_logs_info >"$test_dir/auth-no-state-banner"
  assert_contains 'VMAuth credentials' "$test_dir/auth-no-state-banner"
  assert_contains 'service/vmauth-custom-stack 18427:18427' "$test_dir/auth-no-state-banner"

  require_bin() { :; }
  resolve_logs_public_host() { printf 203.0.113.10; }
  forward_fails=false
  ensure_victoria_metrics_port_forward() {
    [[ "$forward_fails" == false ]] || return 1
    printf '%s\n' "$*" >"$test_dir/public-forward"
    printf '%s\t%s\t%s\t1234\t/tmp/synthetic-forward.log\n' "$1" "$2" "$3"
  }
  run_logs expose >"$test_dir/exposed"
  [[ "$(cat "$test_dir/public-forward")" == 'auth-ns vmauth-custom-stack 8427 18427 0.0.0.0' ]] \
    || fail 'expose did not forward the authenticated service on all interfaces'
  assert_contains 'now exposed externally: http://203.0.113.10:8427/select/vmui/' "$test_dir/exposed"
  assert_contains 'Credentials Secret: auth-ns/vmuser-custom-stack' "$test_dir/exposed"
  assert_not_contains 'custom-backend' "$test_dir/exposed"
  assert_not_contains 'SSH' "$test_dir/exposed"

  resolve_logs_public_host() { fail 'explicit public host must skip IP lookup'; }
  run_logs expose --public-host logs.example.com --port 19427 >"$test_dir/exposed-custom"
  [[ "$(cat "$test_dir/public-forward")" == 'auth-ns vmauth-custom-stack 19427 18427 0.0.0.0' ]] \
    || fail 'custom listen port was not used'
  assert_contains 'http://logs.example.com:19427/select/vmui/' "$test_dir/exposed-custom"

  for args in '--port 0' '--port 65536' '--port bad' '--port' '--unexpected' '--public-host http://example.com' '--public-host localhost' '--public-host 2001:db8::10'; do
    if run_logs expose $args >"$test_dir/invalid" 2>&1; then
      fail "expose accepted invalid arguments: $args"
    fi
    assert_not_contains 'now exposed externally' "$test_dir/invalid"
  done
  forward_fails=true
  if run_logs expose --public-host logs.example.com >"$test_dir/forward-failed" 2>&1; then
    fail 'expose ignored a failed port-forward'
  fi
  assert_not_contains 'now exposed externally' "$test_dir/forward-failed"
  forward_fails=false
  banner_mode=backend
  ensure_logs_dashboard_auth() { return 1; }
  if run_logs expose --public-host logs.example.com >"$test_dir/no-auth" 2>&1; then
    fail 'expose published the unauthenticated backend'
  fi
  assert_contains 'no public port-forward was started' "$test_dir/no-auth"
  assert_not_contains 'now exposed externally' "$test_dir/no-auth"
)

(
  source "$kubeton"
  curl() {
    [[ "$*" == '-4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org' ]] \
      || fail 'unexpected public address discovery request'
    printf '%s' "$fixture_ip"
  }
  fixture_ip=203.0.113.10
  [[ "$(resolve_logs_public_host)" == "$fixture_ip" ]] || fail 'public IP lookup failed'
  for fixture_ip in unavailable 999.999.999.999 '<html>error</html>'; do
    if resolve_logs_public_host >"$test_dir/bad-ip"; then
      fail 'invalid public IP lookup result was accepted'
    fi
  done
)

(
  unset VICTORIA_METRICS_NODEPORT_ENABLED
  source "$kubeton"
  cluster_is_baremetal() { return 0; }
  cluster_is_k3d() { return 1; }
  VICTORIA_METRICS_PORT_FORWARD_ADDRESS=''
  VICTORIA_LOGS_PORT_FORWARD_ADDRESS=''
  [[ "$(victoria_metrics_port_forward_address)" == 127.0.0.1 ]] || fail 'VMAuth default exposes HTTP beyond loopback'
  [[ "$(victoria_logs_port_forward_address)" == 127.0.0.1 ]] || fail 'backend default exposes HTTP beyond loopback'
  VICTORIA_METRICS_PORT_FORWARD_ADDRESS=192.0.2.10
  VICTORIA_LOGS_PORT_FORWARD_ADDRESS=192.0.2.11
  [[ "$(victoria_metrics_port_forward_address)" == 192.0.2.10 ]] || fail 'explicit VMAuth bind override lost'
  [[ "$(victoria_logs_port_forward_address)" == 192.0.2.11 ]] || fail 'explicit backend bind override lost'

  ensure_victoria_metrics_nodeport_access() { printf '%s\n' "$*" >>"$test_dir/nodeport-calls"; }
  [[ "$VICTORIA_METRICS_NODEPORT_ENABLED" == false ]] || fail 'NodePort fallback must default off'
  ensure_victoria_metrics_nodeport_access_if_enabled metrics stack 8427 >"$test_dir/nodeport-disabled"
  [[ ! -e "$test_dir/nodeport-calls" ]] || fail 'default fallback published a NodePort'
  VICTORIA_METRICS_NODEPORT_ENABLED=true
  ensure_victoria_metrics_nodeport_access_if_enabled metrics stack 8427
  [[ "$(cat "$test_dir/nodeport-calls")" == 'metrics stack 8427' ]] || fail 'explicit NodePort opt-in lost'
)

(
  source "$kubeton"
  OP_NAMESPACE=operator-custom
  LONGHORN_NAMESPACE=storage-custom
  kubectl() { fail 'collector configuration test must not touch a cluster'; }
  run_with_timeout() { shift; "$@"; }
  victoria_logs_resolve_allowed_nodes() { local -n result="$3"; result=(worker-a); }
  victoria_logs_validate_ton_nodes_covered() { :; }
  build_victoria_logs_collector_affinity_values_file() { mktemp "$test_dir/affinity.XXXXXX"; }
  helm() { printf '%s\0' "$@" >"$test_dir/collector-command"; }
  install_victoria_logs_collector_release logs collector chart 0.3.7 http://backend:9428 60 '' >"$test_dir/collector-output" 2>&1
  victoria_logs_collector_exclude_filter >"$test_dir/exclude-filter"
)

python3 - "$test_dir" <<'PY'
import ast
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
args = (root / "collector-command").read_bytes().decode().split("\0")[:-1]
exclude = (root / "exclude-filter").read_text()
assert "collector.excludeFilter=" + exclude in args, "collector omitted its filter"
for flag in ("includePodLabels", "includePodAnnotations", "includeNodeLabels", "includeNodeAnnotations"):
    assert f"collector.{flag}=false" in args, f"collector copies arbitrary metadata: {flag}"

# Exercise the generated metadata policy against independent workload cases.
# Only equality/regexp leaves and boolean operations occur in this LogsQL
# filter. The pinned collector's parser is also checked during integration.
leaf = re.compile(r'("(?:[^"\\]|\\.)*"):(=|~)("(?:[^"\\]|\\.)*"|%\{HOSTNAME\})')
def excluded(metadata):
    def replace(match):
        field = json.loads(match[1])
        value = "collector-self" if match[3] == "%{HOSTNAME}" else json.loads(match[3])
        actual = metadata.get(field, "")
        return str(actual == value if match[2] == "=" else re.search(value, actual) is not None)
    expression = leaf.sub(replace, exclude)
    tree = ast.parse(expression, mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.Constant, ast.And, ast.Or, ast.Not)
    assert all(isinstance(node, allowed) for node in ast.walk(tree)), expression
    return eval(compile(tree, "<metadata-policy>", "eval"), {"__builtins__": {}}, {})

def pod(app, container, namespace="default", **extra):
    values = {
        "kubernetes.pod_name": "example-pod",
        "kubernetes.pod_namespace": namespace,
        "kubernetes.container_name": container,
        "kubernetes.pod_labels.app.kubernetes.io/name": app,
    }
    values.update(extra)
    return values

ton_labels = {"kubernetes.pod_labels.app.kubernetes.io/managed-by": "ton-k8s-operator"}
for container in ("ton-node", "prepare-persistent-layout", "stage-ton-exporter", "export-ton-binaries"):
    assert not excluded(pod("ton-node", container, **ton_labels)), container
for container in ("key-restore", "key-backup", "bootstrap-config", "unknown-secret-sidecar"):
    assert excluded(pod("ton-node", container, **ton_labels)), container
assert excluded(pod("ton-node", "ton-node")), "unowned workload was collected"
for app, container in (("kubeton-main-wallet", "main-wallet"), ("kubeton-fleet-tools", "tools"), ("vault", "vault"), ("customer-app", "app")):
    assert excluded(pod(app, container)), app
for container in ("backup", "restore", "debugger"):
    assert excluded(pod("", container)), container
operator = pod("custom-operator", "manager", "operator-custom", **{"kubernetes.pod_labels.control-plane": "controller-manager"})
assert not excluded(operator)
assert excluded(dict(operator, **{"kubernetes.pod_namespace": "other-namespace"}))
storage = pod("", "longhorn-manager", "storage-custom", **{"kubernetes.pod_labels.app": "longhorn-manager"})
assert not excluded(storage)
assert excluded(dict(storage, **{"kubernetes.pod_namespace": "other-namespace"}))
assert excluded(dict(storage, **{"kubernetes.pod_labels.app": "unreviewed-component"}))
assert excluded(dict(storage, **{"kubernetes.container_name": "secret-sidecar"}))
assert excluded(pod("ton-node", "ton-node", **ton_labels, **{"kubernetes.pod_name": "collector-self"}))
PY

echo 'kubeton logs access/security checks: PASS'
