#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }

run_case() (
  source "$kubeton"
  local mode="$1" events="$2" fixture_address
  fixture_address="0:$(printf '%064d' 1)"
  : >"$events"
  record() { printf '%s\n' "$*" >>"$events"; }
  require_bin() { :; }
  get_single_ton_statefulset() {
    local -n a="$1" b="$2" c="$3"
    a=test-ns b=tonnode c=2
  }
  # Keep the real confirmation reader, including its default-deny behavior.
  eval "$(declare -f confirm_or_exit | sed '1s/confirm_or_exit/real_confirm_or_exit/')"
  confirm_or_exit() { record "prompt $1"; real_confirm_or_exit "$@"; }
  list_tonnode_wallet_names_from_pod() {
    [[ "$*" == 'test-ns tonnode-1 true' ]] || return 90
    record inventory
    case "$mode" in
      list-error) return 1 ;;
      no-wallets) return 0 ;;
      *) printf 'validator_wallet_001\nsavings\n' ;;
    esac
  }
  read_tonnode_wallet_address_file_from_pod() {
    [[ "$1 $2" == 'test-ns tonnode-1' ]] || return 91
    [[ "$mode" != missing-address ]] || return 1
    printf '%s' "$fixture_address"
  }
  read_tonnode_wallet_state_from_pod() {
    [[ "$1 $2" == 'test-ns tonnode-1' ]] || return 92
    record "wallet $3"
    local state=empty balance=0.000000000
    if [[ "$3" == savings ]]; then
      case "$mode" in
        funded|decline-funded|mixed) state=active balance=3.250000000 ;;
        nanoton) state=active balance=0.000000001 ;;
        active-zero) state=active ;;
        unknown|decline-unknown) return 1 ;;
        invalid-balance) balance=invalid ;;
      esac
    elif [[ "$mode" == mixed ]]; then
      return 1
    fi
    printf '%s\t%s\t%s\tv1\t0\t%s\n' "$3" "$state" "$balance" "$fixture_address"
  }
  wait_pod_gone() { record 'mutation wait'; }
  kubectl() {
    case "$*" in
      '-n test-ns get statefulset tonnode -o jsonpath={.spec.replicas}')
        if [[ "$mode" == count-change && -f "$events.replica-read" ]]; then
          printf 3
        else
          touch "$events.replica-read"
          printf 2
        fi
        ;;
      '-n test-ns get statefulset tonnode -o jsonpath={.metadata.uid}') printf sts-original ;;
      '-n test-ns get pod tonnode-1 --ignore-not-found -o jsonpath={.metadata.uid}')
        if [[ "$mode" == pod-change && -f "$events.pod-read" ]]; then
          printf pod-replaced
        else
          touch "$events.pod-read"
          printf pod-original
        fi
        ;;
      '-n test-ns get pvc '*" -o jsonpath={.spec.volumeName}") printf 'pv-%s' "$5" ;;
      '-n test-ns get tonnodes.ton.ton.org tonnode') return 0 ;;
      '-n test-ns patch tonnodes.ton.ton.org tonnode '*) record 'mutation scale' ;;
      '-n test-ns delete pvc '*) record "mutation $*" ;;
      'delete pv '*|'-n longhorn-system delete volumes.longhorn.io '*) record "mutation $*" ;;
      *) echo "Unexpected cluster operation: $*" >&2; return 93 ;;
    esac
  }
  run_del
)

check_case() {
  local mode="$1" answers="$2" expected_rc="$3" prompts="$4"
  local output="$test_dir/$mode.out" events="$test_dir/$mode.events" rc=0
  printf '%s' "$answers" >"$test_dir/answers"
  run_case "$mode" "$events" <"$test_dir/answers" >"$output" 2>&1 || rc=$?
  if [[ "$expected_rc" == success ]]; then
    [[ "$rc" == 0 ]] || { cat "$output" >&2; fail "$mode did not succeed"; }
    assert_contains 'mutation scale' "$events"
    assert_contains 'delete pvc keybundle-tonnode-1' "$events"
    # Every question must precede every destructive operation.
    awk '/^mutation / { changed=1 } /^prompt / && changed { exit 1 }' "$events" || fail 'confirmation happened after mutation'
  else
    [[ "$rc" != 0 ]] || fail "$mode unexpectedly succeeded"
    if grep -q '^mutation ' "$events"; then fail "$mode mutated the cluster after cancellation or stale approval"; fi
  fi
  [[ "$(grep -c '^prompt ' "$events" || true)" == "$prompts" ]] || fail "$mode had an unexpected confirmation count"
}

check_case empty $'y\ny\n' success 2
check_case funded $'y\ny\ny\n' success 3
assert_contains 'wallet validator_wallet_001' "$test_dir/funded.events"
assert_contains 'wallet savings' "$test_dir/funded.events"
assert_contains 'non-empty wallet(s)' "$test_dir/funded.events"
assert_contains '3.250000000' "$test_dir/funded.out"
check_case nanoton $'y\ny\ny\n' success 3
check_case active-zero $'y\ny\ny\n' success 3
check_case unknown $'y\ny\ny\n' success 3
assert_contains 'Unknown does not mean empty' "$test_dir/unknown.out"
check_case invalid-balance $'y\ny\ny\n' success 3
check_case missing-address $'y\ny\ny\n' success 3
check_case list-error $'y\ny\ny\n' success 3
assert_contains 'cannot list wallets' "$test_dir/list-error.out"
check_case no-wallets $'y\ny\n' success 2
check_case mixed $'y\ny\ny\ny\n' success 4
check_case decline-funded $'n\n' failure 1
check_case decline-unknown $'n\n' failure 1
check_case decline-backup $'n\n' failure 1
assert_contains 'current backup' "$test_dir/decline-backup.events"
check_case decline-final $'y\nn\n' failure 2
check_case default-no $'\n' failure 1
check_case eof '' failure 1
check_case count-change $'y\ny\n' failure 2
check_case pod-change $'y\ny\n' failure 2
assert_contains 'changed during confirmation' "$test_dir/pod-change.out"

# Execute the real inventory script against a synthetic wallet directory.
(
  source "$kubeton"
  wallet_fixture="$test_dir/wallets"
  mkdir -p "$wallet_fixture"
  printf 'PRIVATE-CONTENT-MUST-NOT-BE-READ' >"$wallet_fixture/key-wallet.pk"
  touch "$wallet_fixture/key-wallet.addr" "$wallet_fixture/address-only.addr"
  run_with_timeout() { shift; "$@"; }
  kubectl() {
    [[ "$1 $2 $3 $4 $5 $6 $7 $8 $9" == '-n test-ns exec tonnode-1 -c ton-node -- bash -lc' ]] || return 94
    local script="${10}"
    script="${script//\/var\/ton-work\/controller\/mytoncore\/wallets/$wallet_fixture}"
    bash -c "$script" _ "${12}"
  }
  inventory="$(list_tonnode_wallet_names_from_pod test-ns tonnode-1 true)"
  [[ "$inventory" == $'address-only\nkey-wallet' ]] || fail 'strict inventory missed or duplicated a wallet'
  inventory="$(list_tonnode_wallet_names_from_pod test-ns tonnode-1)"
  [[ "$inventory" == key-wallet ]] || fail 'default private-key inventory changed'
  rm -rf "$wallet_fixture"
  if list_tonnode_wallet_names_from_pod test-ns tonnode-1 true; then fail 'missing wallet directory was considered a verified empty inventory'; fi
  kubectl() { return 1; }
  if list_tonnode_wallet_names_from_pod test-ns tonnode-1 true; then fail 'failed exec was considered an empty inventory'; fi
)

echo 'kubeton del checks: PASS (18 deletion flows and strict wallet inventory)'
