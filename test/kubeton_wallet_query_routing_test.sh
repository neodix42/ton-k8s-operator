#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

setup_case() {
  source "$repo_root/charts/ton-k8s-operator/kubeton"
  routing_dir="$test_dir/$1"
  mkdir -p "$routing_dir"
  routing_events="$routing_dir/events"
  : >"$routing_events"
  routing_raw="-1:$(printf '%064d' 1)"
  routing_address="$(ton_address_to_non_bounceable "$routing_raw")"
  routing_row="validator_wallet_001"$'\t'"empty"$'\t'"0.000000000"$'\t'"v1"$'\t'"-1"$'\t'"$routing_address"
  routing_config='{"validator":{"zero_state":{"root_hash":"fixture public network identity"}}}'
  routing_https_rc=0 routing_rpc_rc=0 routing_config_rc=0
  WALLET_QUERY_ATTEMPTS=3
  WALLET_QUERY_TIMEOUT_SECONDS=45
  MYTONCTRL_EXEC_TIMEOUT=180s

  read_tonnode_global_config() {
    [[ "$*" == 'unit-ns tonnode-0' ]] || fail "unexpected config identity"
    printf 'config\n' >>"$routing_events"
    printf '%s' "$routing_config"
    return "$routing_config_rc"
  }
  read_tonnode_wallet_version_from_pod() {
    [[ "$*" == "unit-ns tonnode-0 $routing_raw" ]] || fail "unexpected metadata identity"
    printf 'metadata\n' >>"$routing_events"
    printf v1
  }
  python3() {
    # Replace the host process boundary, never execute a real HTTP query.
    [[ "$1" == -c && "$3" == validator_wallet_001 && "$4" == "$routing_raw" ]] || fail "unexpected host query"
    [[ "$5" == 3 && "$6" == 45 && "$7" == --https-only && "$8" == v1 ]] || fail "unexpected host query mode"
    cat >"$routing_dir/config-input"
    [[ "$(cat "$routing_dir/config-input")" == "$routing_config" ]] || fail "host query did not receive active config"
    printf 'https-local\n' >>"$routing_events"
    if (( routing_https_rc == 0 )); then
      printf '%s\n' "$routing_row"
    else
      echo 'HTTPS fixture transport failure' >&2
    fi
    return "$routing_https_rc"
  }
  run_with_timeout() {
    [[ "$1" == 180s ]] || fail "pod query lost its overall timeout"
    shift
    "$@"
  }
  kubectl() {
    # Model only the read-only pod fallback. Every other call fails closed.
    [[ "${1:-}" == -n && "${2:-}" == unit-ns && "${3:-}" == exec && "${4:-}" == tonnode-0 ]] || fail "unexpected Kubernetes call"
    [[ "${5:-}" == -c && "${6:-}" == ton-node && "${7:-}" == -- && "${8:-}" == python3 && "${9:-}" == -c ]] || fail "unexpected pod command"
    [[ "${11:-}" == validator_wallet_001 && "${12:-}" == "$routing_raw" && "${13:-}" == 3 && "${14:-}" == 45 && "${15:-}" == --rpc-only ]] || fail "unexpected pod query mode"
    printf 'rpc-pod\n' >>"$routing_events"
    # Deliberately include valid-looking stdout on failure: it must not win.
    printf '%s\n' "$routing_row"
    if (( routing_rpc_rc != 0 )); then
      echo 'RPC fixture startup timeout' >&2
    fi
    return "$routing_rpc_rc"
  }
}

test_host_https_success_bypasses_pod_network() (
  setup_case host-success
  routing_rpc_rc=1
  read_tonnode_wallet_state_from_pod unit-ns tonnode-0 validator_wallet_001 "$routing_raw" >"$routing_dir/out" 2>"$routing_dir/err"
  [[ "$(cat "$routing_dir/out")" == "$routing_row" ]] || fail "host query lost its result"
  assert_contains https-local "$routing_events"
  assert_not_contains rpc-pod "$routing_events"
  [[ ! -s "$routing_dir/err" ]] || fail "successful host lookup emitted a warning"
)

test_pod_fallback_hides_recovered_https_failure() (
  setup_case rpc-fallback
  routing_https_rc=1
  read_tonnode_wallet_state_from_pod unit-ns tonnode-0 validator_wallet_001 "$routing_raw" >"$routing_dir/out" 2>"$routing_dir/err"
  [[ "$(cat "$routing_dir/out")" == "$routing_row" ]] || fail "pod fallback lost its result"
  assert_contains https-local "$routing_events"
  assert_contains rpc-pod "$routing_events"
  [[ ! -s "$routing_dir/err" ]] || fail "recovered HTTPS failure emitted a warning"
)

test_both_failures_retain_causes_and_reject_partial_stdout() (
  setup_case both-fail
  routing_https_rc=1 routing_rpc_rc=1
  if read_tonnode_wallet_state_from_pod unit-ns tonnode-0 validator_wallet_001 "$routing_raw" >"$routing_dir/out" 2>"$routing_dir/err"; then
    fail "accepted failed query output as a live balance"
  fi
  [[ ! -s "$routing_dir/out" ]] || fail "failed query leaked a successful-looking wallet row"
  assert_contains '[wallet unit-ns/tonnode-0]' "$routing_dir/err"
  assert_contains 'HTTPS fixture transport failure' "$routing_dir/err"
  assert_contains 'RPC fixture startup timeout' "$routing_dir/err"
)

test_unreadable_config_uses_pod_fallback() (
  setup_case missing-config
  routing_config_rc=1
  read_tonnode_wallet_state_from_pod unit-ns tonnode-0 validator_wallet_001 "$routing_raw" >"$routing_dir/out" 2>"$routing_dir/err"
  [[ "$(cat "$routing_dir/out")" == "$routing_row" ]] || fail "unreadable config prevented pod fallback"
  assert_not_contains https-local "$routing_events"
  assert_not_contains metadata "$routing_events"
  assert_contains rpc-pod "$routing_events"
  [[ ! -s "$routing_dir/err" ]] || fail "recovered config failure emitted a warning"
)

test_missing_prerequisite_exit_code_is_preserved() (
  setup_case missing-prerequisite
  routing_https_rc=1 routing_rpc_rc=78
  local rc=0
  read_tonnode_wallet_state_from_pod unit-ns tonnode-0 validator_wallet_001 "$routing_raw" >"$routing_dir/out" 2>"$routing_dir/err" || rc=$?
  [[ "$rc" == 78 ]] || fail "lost prerequisite failure exit code"
  [[ ! -s "$routing_dir/out" ]] || fail "prerequisite failure leaked a wallet row"
)

test_host_https_success_bypasses_pod_network
test_pod_fallback_hides_recovered_https_failure
test_both_failures_retain_causes_and_reject_partial_stdout
test_unreadable_config_uses_pod_fallback
test_missing_prerequisite_exit_code_is_preserved
echo 'kubeton wallet host/pod query routing tests passed (5 cases)'
