#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() {
  if ! grep -Fq -- "$1" "$2"; then
    cat "$2" >&2
    fail "expected '$1' in $2"
  fi
}
assert_not_contains() {
  if grep -Fq -- "$1" "$2"; then
    cat "$2" >&2
    fail "unexpected '$1' in $2"
  fi
}

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
unexpected() {
  printf 'Unexpected kubectl arguments:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  touch "$LOGS_STATE/unexpected-call"
  exit 91
}

if [[ "${1:-}" == get && "${2:-}" == services ]]; then
  if [[ "${5:-}" == app.kubernetes.io/name=vmauth ]]; then
    [[ $# == 7 && "${3:-}" == -A && "${4:-}" == -l \
      && "${6:-}" == -o && "${7:-}" == jsonpath=* ]] || unexpected "$@"
    case "$LOGS_CASE" in
      auth-match|auth-mismatch|auth-health-only|auth-select-only) printf 'metrics-ns\tmetrics-stack\n' ;;
    esac
    exit 0
  fi
  [[ $# == 7 && "${3:-}" == -A && "${4:-}" == -l \
    && "${5:-}" == app.kubernetes.io/name=kubeton-victoria-logs-access,app.kubernetes.io/managed-by=kubeton \
    && "${6:-}" == -o && "${7:-}" == jsonpath=* ]] || unexpected "$@"
  printf 'discover logs service\n' >>"$LOGS_STATE/events"
  case "$LOGS_CASE" in
    missing-stack) ;;
    discovery-failure) echo 'mock logging Service access denied' >&2; exit 1 ;;
    *) printf 'logs-ns\tlogs-backend\t9428\n' ;;
  esac
  exit 0
fi

if [[ "${1:-}" == get && "${2:-}" == configmaps ]]; then
  [[ $# == 7 && "${3:-}" == -A && "${4:-}" == -l \
    && "${5:-}" == app.kubernetes.io/name=kubeton-victoria-metrics,app.kubernetes.io/managed-by=kubeton \
    && "${6:-}" == -o && "${7:-}" == jsonpath=* ]] || unexpected "$@"
  printf 'discover metrics state\n' >>"$LOGS_STATE/events"
  case "$LOGS_CASE" in
    auth-match|auth-mismatch|auth-health-only|auth-select-only) printf 'metrics-ns\tmetrics-stack\n' ;;
  esac
  exit 0
fi

if [[ "${1:-}" == -n && "${2:-}" == metrics-ns && "${3:-}" == get ]]; then
  [[ $# == 7 && "${6:-}" == -o && "${7:-}" == jsonpath=* ]] || unexpected "$@"
  case "${4:-}/${5:-}" in
    vmuser/metrics-stack)
      printf 'discover VMUser routes\n' >>"$LOGS_STATE/events"
      printf 'http://unrelated.metrics-ns.svc:8428\t/select/.*\n'
      if [[ "$LOGS_CASE" == auth-match ]]; then
        printf 'http://logs-backend.logs-ns.svc:9428/\t/select/.*\n'
      elif [[ "$LOGS_CASE" == auth-health-only ]]; then
        printf 'http://logs-backend.logs-ns.svc:9428/\t/health\n'
      elif [[ "$LOGS_CASE" == auth-select-only ]]; then
        printf 'http://logs-backend.logs-ns.svc:9428/\t/select\n'
      fi
      ;;
    service/vmauth-metrics-stack)
      [[ "$LOGS_CASE" == auth-match ]] || unexpected "$@"
      printf 'discover VMAuth service\n' >>"$LOGS_STATE/events"
      printf '8427'
      ;;
    *) unexpected "$@" ;;
  esac
  exit 0
fi

if [[ "${1:-}" == get && "${2:-}" == pods ]]; then
  [[ "${3:-}" == -A && "${4:-}" == -l && "${5:-}" == app.kubernetes.io/name=ton-node ]] \
    || unexpected "$@"
  printf 'inventory\n' >>"$LOGS_STATE/events"
  case "$LOGS_CASE" in
    empty|empty-selected) ;;
    inventory-failure)
      echo 'mock inventory access denied' >&2
      exit 1
      ;;
    node-filter|node-logs-failure|blackbox-node-filter)
      printf 'alpha\tton-0\tworker-a\nbeta\tton-1\tworker-a\nalpha\tton-2\tworker-aa\ngamma\tton-3\t\n'
      ;;
    *) printf 'alpha\tton-0\tworker-a\nbeta\tton-1\t\n' ;;
  esac
  exit 0
fi

if [[ "${1:-}" == -n && "${3:-}" == logs ]]; then
  [[ $# == 7 && "${5:-}" == -c && "${6:-}" == ton-node && "${7:-}" == --tail=20 ]] \
    || unexpected "$@"
  ns="$2" pod="$4"
  [[ "$ns/$pod" == alpha/ton-0 || "$ns/$pod" == beta/ton-1 ]] \
    || unexpected "$@"
  printf 'logs %s/%s\n' "$ns" "$pod" >>"$LOGS_STATE/events"
  if [[ ( "$LOGS_CASE" == logs-failure || "$LOGS_CASE" == node-logs-failure ) && "$pod" == ton-0 ]]; then
    echo 'mock first pod logs denied' >&2
    exit 17
  fi
  # The mock enforces the server-side bound above and returns exactly the
  # requested final 20 entries from a 30-line log.
  for ((line=11; line<=30; line++)); do
    printf 'fixture %s/%s line %02d\n' "$ns" "$pod" "$line"
  done
  exit 0
fi

unexpected "$@"
MOCK_KUBECTL
chmod +x "$test_dir/bin/kubectl"

run_case() {
  local mode="$1" expected_rc="$2" rc=0
  shift 2
  mkdir -p "$test_dir/$mode"
  : >"$test_dir/$mode/events"
  PATH="$test_dir/bin:$PATH" LOGS_CASE="$mode" LOGS_STATE="$test_dir/$mode" \
    bash -c '
      source "$1"
      shift
      print_logs_victoria_logs_info() { echo "Full logs: VictoriaLogs test endpoint"; }
      main logs "$@"
    ' _ "$kubeton" "$@" >"$test_dir/$mode/output" 2>&1 || rc=$?
  if [[ "$rc" != "$expected_rc" ]]; then
    cat "$test_dir/$mode/output" >&2
    fail "$mode expected exit $expected_rc, got $rc"
  fi
  [[ ! -e "$test_dir/$mode/unexpected-call" ]] || fail "$mode made unexpected kubectl calls"
}

assert_log_lines() {
  local mode="$1" pod="$2" actual line
  # Keep generated files within this case directory even when pod has '/'.
  actual="$test_dir/$mode/${pod//\//_}.lines"
  grep -F "fixture $pod line " "$test_dir/$mode/output" >"$actual" || true
  : >"$actual.expected"
  for ((line=11; line<=30; line++)); do
    printf 'fixture %s line %02d\n' "$pod" "$line" >>"$actual.expected"
  done
  diff -u "$actual.expected" "$actual" || fail "$mode did not show the last 20 log lines for $pod"
}

run_case success 0
[[ "$(head -n 1 "$test_dir/success/output")" == 'Full logs: VictoriaLogs test endpoint' ]] \
  || fail 'full log server information should appear first'
[[ "$(cat "$test_dir/success/events")" == $'inventory\nlogs alpha/ton-0\nlogs beta/ton-1' ]] \
  || fail 'logs should include all discovered pods across namespaces'
grep -E 'alpha/ton-0.*worker-a|worker-a.*alpha/ton-0' "$test_dir/success/output" >/dev/null \
  || fail 'first pod header should identify its namespace and server'
grep -E 'beta/ton-1.*N/A|N/A.*beta/ton-1' "$test_dir/success/output" >/dev/null \
  || fail 'unscheduled pod header should identify its namespace and missing server'
assert_log_lines success alpha/ton-0
assert_log_lines success beta/ton-1

run_case logs-failure 1
[[ "$(cat "$test_dir/logs-failure/events")" == $'inventory\nlogs alpha/ton-0\nlogs beta/ton-1' ]] \
  || fail 'failed log retrieval should not skip later pods'
assert_contains 'mock first pod logs denied' "$test_dir/logs-failure/output"
assert_log_lines logs-failure beta/ton-1
assert_not_contains 'fixture alpha/ton-0' "$test_dir/logs-failure/output"

run_case empty 0
assert_contains 'No TON pods found.' "$test_dir/empty/output"
[[ "$(cat "$test_dir/empty/events")" == inventory ]] || fail 'empty cluster should not fetch pod logs'

run_case inventory-failure 1
assert_contains 'mock inventory access denied' "$test_dir/inventory-failure/output"
assert_not_contains 'No TON pods found.' "$test_dir/inventory-failure/output"
[[ "$(cat "$test_dir/inventory-failure/events")" == inventory ]] \
  || fail 'inventory failure should not fetch pod logs'

run_case node-filter 0 worker-a
[[ "$(head -n 1 "$test_dir/node-filter/output")" == 'Full logs: VictoriaLogs test endpoint' ]] \
  || fail 'filtered logs should start with full log server information'
[[ "$(cat "$test_dir/node-filter/events")" == $'inventory\nlogs alpha/ton-0\nlogs beta/ton-1' ]] \
  || fail 'node filtering should include all matching pods across namespaces, with an exact node name match'
assert_log_lines node-filter alpha/ton-0
assert_log_lines node-filter beta/ton-1
assert_not_contains 'ton-2' "$test_dir/node-filter/output"
assert_not_contains 'ton-3' "$test_dir/node-filter/output"

run_case node-no-match 1 worker-z
assert_contains "No TON pods found on node 'worker-z'." "$test_dir/node-no-match/output"
[[ "$(cat "$test_dir/node-no-match/events")" == inventory ]] \
  || fail 'a node without TON pods should not fetch pod logs'

run_case node-logs-failure 1 worker-a
[[ "$(cat "$test_dir/node-logs-failure/events")" == $'inventory\nlogs alpha/ton-0\nlogs beta/ton-1' ]] \
  || fail 'failed selected pod logs should not skip other matching pods or fetch pods on another node'
assert_contains 'mock first pod logs denied' "$test_dir/node-logs-failure/output"
assert_log_lines node-logs-failure beta/ton-1
assert_not_contains 'fixture alpha/ton-0' "$test_dir/node-logs-failure/output"
assert_not_contains 'ton-2' "$test_dir/node-logs-failure/output"

run_case empty-selected 1 worker-a
assert_contains "No TON pods found on node 'worker-a'." "$test_dir/empty-selected/output"
[[ "$(cat "$test_dir/empty-selected/events")" == inventory ]] \
  || fail 'empty cluster with a selected node should not fetch pod logs'

run_case extra-arguments 1 worker-a worker-b
assert_contains 'kubeton logs [node]' "$test_dir/extra-arguments/output"
[[ ! -s "$test_dir/extra-arguments/events" ]] || fail 'invalid arguments should not access the cluster'

run_case empty-argument 1 ''
assert_contains 'kubeton logs [node]' "$test_dir/empty-argument/output"
[[ ! -s "$test_dir/empty-argument/events" ]] || fail 'an empty node argument should not access the cluster'

run_case invalid-option 1 --unexpected
assert_contains 'kubeton logs [node]' "$test_dir/invalid-option/output"
[[ ! -s "$test_dir/invalid-option/events" ]] || fail 'an invalid option should not access the cluster'

run_blackbox_case() {
  local mode="$1" rc=0
  shift
  mkdir -p "$test_dir/$mode"
  : >"$test_dir/$mode/events"
  PATH="$test_dir/bin:$PATH" LOGS_CASE="$mode" LOGS_STATE="$test_dir/$mode" \
    bash "$kubeton" logs "$@" >"$test_dir/$mode/output" 2>&1 || rc=$?
  if (( rc != 0 )); then
    cat "$test_dir/$mode/output" >&2
    fail "$mode should show pod logs even without a usable logging stack"
  fi
  [[ ! -e "$test_dir/$mode/unexpected-call" ]] || fail "$mode made unexpected kubectl calls"
  [[ "$(head -n 1 "$test_dir/$mode/output")" == *'Full logs can be found on the VictoriaLogs server'* ]] \
    || fail "$mode should start with full log server information"
  assert_log_lines "$mode" alpha/ton-0
  assert_log_lines "$mode" beta/ton-1
}

run_blackbox_case missing-stack
assert_contains 'not found' "$test_dir/missing-stack/output"
assert_not_contains 'after port-forward' "$test_dir/missing-stack/output"

run_blackbox_case discovery-failure
assert_contains 'address unavailable' "$test_dir/discovery-failure/output"
assert_not_contains 'after port-forward' "$test_dir/discovery-failure/output"

run_blackbox_case backend-only
assert_contains 'http://logs-backend.logs-ns.svc:9428/select/vmui/' "$test_dir/backend-only/output"
assert_contains 'kubectl -n logs-ns port-forward --address 127.0.0.1 service/logs-backend 9428:9428' "$test_dir/backend-only/output"
assert_contains 'after port-forward: http://127.0.0.1:9428/select/vmui/' "$test_dir/backend-only/output"

run_blackbox_case auth-match
assert_contains 'http://vmauth-metrics-stack.metrics-ns.svc:8427/select/vmui/' "$test_dir/auth-match/output"
assert_contains 'kubectl -n metrics-ns port-forward --address 127.0.0.1 service/vmauth-metrics-stack 8427:8427' "$test_dir/auth-match/output"
assert_contains 'after port-forward: http://127.0.0.1:8427/select/vmui/' "$test_dir/auth-match/output"
assert_contains 'VMAuth credentials' "$test_dir/auth-match/output"

run_blackbox_case auth-mismatch
assert_contains 'http://logs-backend.logs-ns.svc:9428/select/vmui/' "$test_dir/auth-mismatch/output"
assert_not_contains 'vmauth-metrics-stack' "$test_dir/auth-mismatch/output"
assert_not_contains 'VMAuth credentials' "$test_dir/auth-mismatch/output"

run_blackbox_case auth-health-only
assert_contains 'http://logs-backend.logs-ns.svc:9428/select/vmui/' "$test_dir/auth-health-only/output"
assert_not_contains 'vmauth-metrics-stack' "$test_dir/auth-health-only/output"
assert_not_contains 'VMAuth credentials' "$test_dir/auth-health-only/output"

run_blackbox_case auth-select-only
assert_contains 'http://logs-backend.logs-ns.svc:9428/select/vmui/' "$test_dir/auth-select-only/output"
assert_not_contains 'vmauth-metrics-stack' "$test_dir/auth-select-only/output"
assert_not_contains 'VMAuth credentials' "$test_dir/auth-select-only/output"

run_blackbox_case blackbox-node-filter worker-a
assert_contains 'http://logs-backend.logs-ns.svc:9428/select/vmui/' "$test_dir/blackbox-node-filter/output"
[[ "$(tail -n 3 "$test_dir/blackbox-node-filter/events")" == $'inventory\nlogs alpha/ton-0\nlogs beta/ton-1' ]] \
  || fail 'the CLI entry point should fetch logs only for pods on the requested node'
assert_not_contains 'ton-2' "$test_dir/blackbox-node-filter/output"
assert_not_contains 'ton-3' "$test_dir/blackbox-node-filter/output"

echo 'kubeton logs checks: PASS (19 cases)'
