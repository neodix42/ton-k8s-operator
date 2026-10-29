#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }

test_start_lifecycle() (
  source "$kubeton"
  local mode="$1" events="$test_dir/start-$1.events"
  : >"$events"
  record() { printf '%s\n' "$1" >>"$events"; }
  require_bin() { :; }
  kubectl() { fail "unexpected kubectl call: $*"; }
  KUBETON_SKIP_NODE_PREREQ_CHECK=true
  KUBETON_START_WAIT_FOR_BOOTSTRAP=false
  KUBETON_START_VICTORIA_LOGS_ENABLED=true
  VICTORIA_LOGS_ENABLED=true
  resolve_ton_replicas_from_values_file() { printf 1; }
  should_bootstrap_baremetal() { return 1; }
  longhorn_manager_exists() { return 1; }
  storage_class_is_longhorn() { return 1; }
  prepare_node_prerequisites_for_workload() {
    KUBETON_VICTORIA_LOGS_ELIGIBLE_NODES=(node-a)
    KUBETON_NODE_CHECK_TON_SELECTOR=""
    record preflight
  }
  fleet_has_stop_annotations() { return 1; }
  ensure_ton_storage_class_available() { :; }
  append_ton_storage_overrides() { :; }
  should_use_sequential_ton_start() { return 1; }
  validate_external_key_prereqs() { :; }
  ensure_start_victoria_logs() {
    record logging
    KUBETON_VICTORIA_LOGS_APPLIED_NODES=node-a
    [[ "$mode" != logs-fail ]]
  }
  ensure_start_victoria_metrics() {
    [[ "$1" == true ]] || fail 'start did not reuse verified logging'
    record metrics
    [[ "$mode" != metrics-fail ]]
  }
  restrict_existing_victoria_logs_after_failed_preflight() { record restrict; }
  delete_stale_ton_pvcs_before_fresh_start() { record cleanup; }
  verify_start_victoria_logs_collection_ready() { record coverage; }
  ensure_tonnode_crd_schema() { :; }
  append_helm_force_conflicts_if_supported() { :; }
  helm() { record fleet; }
  repair_pending_ton_placement_after_start() { :; }
  ensure_victoria_metrics_scrape_resources() { record scrape; }
  resume_stopped_dashboard_workloads() { record dashboards; }

  local rc=0
  run_start >"$test_dir/start-$mode.out" 2>&1 || rc=$?
  if [[ "$mode" == ready ]]; then
    [[ "$rc" == 0 ]] || fail 'automatic observability start failed'
    [[ "$(cat "$events")" == $'preflight\nlogging\nmetrics\ncleanup\ncoverage\nfleet\nscrape\ndashboards' ]] \
      || fail 'logging/metrics/fleet/scrape order changed'
  else
    [[ "$rc" != 0 ]] || fail "start ignored $mode"
    if grep -Eq '^(cleanup|fleet|scrape)$' "$events"; then
      fail 'failed observability setup allowed TON mutation'
    fi
  fi
)

test_metrics_reuses_ready_logs() (
  source "$kubeton"
  local mode="$1" events="$test_dir/metrics-$1.events" output="$test_dir/metrics-$1.out"
  : >"$events"
  record() { printf '%s\n' "$1" >>"$events"; }
  require_bin() { :; }
  kubectl() { fail "unexpected kubectl call: $*"; }
  VICTORIA_LOGS_ENABLED=true
  KUBETON_START_VICTORIA_LOGS_ENABLED=true
  KUBETON_VICTORIA_LOGS_ELIGIBLE_NODES=(node-a)
  KUBETON_VICTORIA_LOGS_APPLIED_NODES=node-a
  [[ "$mode" != stale ]] || KUBETON_VICTORIA_LOGS_APPLIED_NODES=node-b
  cleanup_victoria_logs_port_forwards() { :; }
  run_node_prerequisite_check_readonly() { fail 'setup repeated the node preflight'; }
  ensure_victoria_logs_stack() { fail 'metrics setup repeated the logging rollout'; }
  ensure_victoria_metrics_operator() { record operator; printf 'v1\thttps://example.invalid/operator.yaml\n'; }
  ensure_victoria_metrics_stack() {
    [[ "$6" == http://kubeton-vlogs-access-kubeton-vlogs.vm.svc:9428 ]] \
      || fail 'VMAuth was not routed to the logging backend'
    record stack
    [[ "$mode" != stack-fail ]]
  }
  ensure_victoria_metrics_scrape_resources() { record scrape; }
  write_victoria_metrics_state() { record state; }
  resolve_victoria_metrics_auth_service_name() { printf vmauth-kubeton; }
  resolve_victoria_metrics_credentials() { printf 'vmuser-kubeton\tkubeton\tsynthetic-password\n'; }
  start_victoria_metrics_auth_port_forward() {
    [[ "$5" == 127.0.0.1 ]] || fail 'metrics access was publicly bound'
    record access
    printf 'vm\tvmauth-kubeton\t8427\t123\t/tmp/synthetic-forward.log\n'
  }

  local rc=0
  ensure_start_victoria_metrics true >"$output" 2>&1 || rc=$?
  if [[ "$mode" == ready ]]; then
    [[ "$rc" == 0 ]] || { cat "$output" >&2; fail 'metrics setup failed'; }
    [[ "$(cat "$events")" == $'operator\nstack\nscrape\nstate\naccess' ]] || fail 'metrics resources missing'
    grep -Fq 'Credentials secret: vm/vmuser-kubeton' "$output" || fail 'credentials location missing'
    ! grep -Fq synthetic-password "$output" || fail 'automatic start printed the password'
  else
    [[ "$rc" != 0 ]] || fail "metrics setup ignored $mode"
    ! grep -Eq '^(state|access)$' "$events" || fail 'failed metrics setup published access'
  fi
)

test_start_lifecycle ready
test_start_lifecycle logs-fail
test_start_lifecycle metrics-fail
test_metrics_reuses_ready_logs ready
test_metrics_reuses_ready_logs stale
test_metrics_reuses_ready_logs stack-fail

source "$kubeton"
usage >"$test_dir/help"
! grep -Fq 'victoria-metrics install' "$test_dir/help" || fail 'obsolete install command is advertised'
! grep -Fq 'victoria-metrics uninstall' "$test_dir/help" || fail 'obsolete uninstall command is advertised'
for action in install uninstall; do
  if ( main victoria-metrics "$action" ) >"$test_dir/removed-$action" 2>&1; then
    fail 'removed observability command is still dispatched'
  fi
done

echo 'kubeton automatic observability checks: PASS'
