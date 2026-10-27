#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

# Exercise fleet planning and accounting separately from the per-pod transfer
# boundary. Only synthetic public addresses and return codes are used here.
run_fleet_case() (
  source "$kubeton"
  local mode="$1" case_dir="$test_dir/$1" destination
  mkdir -p "$case_dir"
  : >"$case_dir/events"
  destination="$(ton_address_to_non_bounceable "0:$(printf '%064d' 99)")"
  confirm_or_exit() { printf 'confirm %s\n' "$1" >>"$case_dir/events"; }
  resolve_main_wallet_receive_address() {
    [[ "$*" == 'mainnet main-wallet' ]] || fail 'wrong collection network or main wallet'
    printf '%s' "$destination"
  }
  list_ton_pods() {
    local index
    for index in {0..4}; do printf 'unit-ns\ttonnode-%s\tworker-%s\n' "$index" "$index"; done
  }
  resolve_tonnode_pod_row_by_name() {
    [[ "$1" =~ ^tonnode-[0-4]$ ]] || return 1
    printf 'unit-ns\t%s\tworker-%s\n' "$1" "${1##*-}"
  }
  resolve_tonnode_wallet_row_from_pod() {
    local index="${2##*-}" status=active balance=0.756407580 raw
    raw="-1:$(printf '%064d' "$((index + 1))")"
    [[ "$mode" != mixed-empty && "$mode" != pending-empty || "$index" != 0 ]] || { status=empty; balance=0; }
    [[ "$mode" != unavailable-before-send || "$index" != 4 ]] || return 1
    printf '%s\t%s\t%s\tv1\t-1\t%s\n' "$3" "$status" "$balance" "$(ton_address_to_non_bounceable "$raw")"
  }
  read_tonnode_collect_operation_from_pod() {
    local marker="kubeton-collect:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    printf 'inspect %s\n' "$2" >>"$case_dir/events"
    if [[ "$mode" == pending-empty && "$2" == tonnode-0 || "$mode" == numeric-recovery && "$2" == tonnode-1 ]]; then
      printf '{"pending":true,"marker":"%s","observed_marker":"%s"}\n' "$marker" "$marker"
      return 0
    fi
    if [[ "$mode" == numeric-recovery && "$2" == tonnode-0 ]]; then
      printf '{"pending":false,"receipt":{"lt":"123"},"marker":"%s","observed_marker":"%s"}\n' "$marker" "$marker"
      return 2
    fi
    if [[ "$mode" == conflicting-pending && "$2" == tonnode-3 ]]; then
      echo 'Synthetic different collection is already pending' >&2
      return 1
    fi
    printf '{"observed_marker":null}\n'
    return 3
  }
  collect_tonnode_wallet_in_pod() {
    [[ "$1" == unit-ns && "$2" =~ ^tonnode-[0-4]$ && "$3" == validator_wallet_001 && "$4" == "$destination" ]] || fail 'collection changed the source or destination'
    local expected=alld
    [[ "$mode" != numeric && "$mode" != numeric-recovery ]] || expected=0.25
    [[ "$5" == "$expected" ]] || fail 'collection changed the requested amount'
    [[ $# == 9 ]] || fail 'collection did not pass the verified source, balance, network and journal observation to its receipt verifier'
    local expected_source="-1:$(printf '%064d' "$((${2##*-} + 1))")"
    local expected_balance=0.756407580
    [[ "$mode" != pending-empty || "$2" != tonnode-0 ]] || expected_balance=0
    [[ "$(ton_address_to_hex "$6")" == "$expected_source" && "$7" == "$expected_balance" && "$8" == mainnet ]] || fail 'collection receipt verifier received the wrong source identity or verified balance'
    local expected_operation=fresh:none
    [[ "$mode" != pending-empty || "$2" != tonnode-0 ]] || expected_operation=resume:kubeton-collect:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [[ "$mode" != numeric-recovery || "$2" != tonnode-1 ]] || expected_operation=resume:kubeton-collect:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [[ "$9" == "$expected_operation" ]] || fail 'collection did not preserve the observed pending/fresh journal state'
    printf 'submit %s %s\n' "$2" "$5" >>"$case_dir/events"
    if [[ "$mode" == partial && "$2" == tonnode-2 ]]; then
      echo 'Synthetic receipt remained unconfirmed' >&2
      return 1
    fi
    if [[ "$mode" == genuine-rejection ]]; then
      echo 'Synthetic signing key does not match the source address' >&2
      return 7
    fi
    echo "[wallet] Synthetic receipt confirmed for $2."
  }
  if [[ "$mode" == numeric || "$mode" == numeric-recovery ]]; then
    run_wallet_collect mainnet main-wallet 0.25
  elif [[ "$mode" == selected ]]; then
    run_wallet_collect mainnet main-wallet tonnode-3
  else
    run_wallet_collect mainnet main-wallet
  fi
)

check_fleet_case() {
  local mode="$1" expected="$2" rc=0
  run_fleet_case "$mode" >"$test_dir/$mode.out" 2>&1 || rc=$?
  if [[ "$expected" == success ]]; then
    [[ "$rc" == 0 ]] || { cat "$test_dir/$mode.out" >&2; fail "$mode unexpectedly failed"; }
  else
    [[ "$rc" != 0 ]] || { cat "$test_dir/$mode.out" >&2; fail "$mode incorrectly reported success"; }
  fi
}

check_fleet_case all-confirmed success
assert_contains '5/5' "$test_dir/all-confirmed.out"
[[ "$(grep -c '^submit ' "$test_dir/all-confirmed/events")" == 5 ]] || fail 'full collection did not attempt each wallet exactly once'

check_fleet_case partial failure
assert_contains '4/5' "$test_dir/partial.out"
assert_contains 'Synthetic receipt remained unconfirmed' "$test_dir/partial.out"
[[ "$(grep -c '^submit ' "$test_dir/partial/events")" == 5 ]] || fail 'partial failure caused a transfer retry or skipped a peer'

check_fleet_case numeric success
assert_contains '5/5' "$test_dir/numeric.out"
[[ "$(grep -c '^submit .* 0.25$' "$test_dir/numeric/events")" == 5 ]] || fail 'numeric collection amount changed'

check_fleet_case mixed-empty success
assert_contains '4/4' "$test_dir/mixed-empty.out"
assert_not_contains 'submit tonnode-0 ' "$test_dir/mixed-empty/events"

check_fleet_case unavailable-before-send failure
assert_not_contains 'submit ' "$test_dir/unavailable-before-send/events"
assert_not_contains 'confirm ' "$test_dir/unavailable-before-send/events"

check_fleet_case genuine-rejection failure
assert_contains '0/5' "$test_dir/genuine-rejection.out"
assert_contains 'Synthetic signing key does not match the source address' "$test_dir/genuine-rejection.out"
[[ "$(grep -c '^submit ' "$test_dir/genuine-rejection/events")" == 5 ]] || fail 'a genuine rejection caused a fresh transfer retry'

check_fleet_case selected success
assert_contains '1/1' "$test_dir/selected.out"
[[ "$(grep -c '^submit ' "$test_dir/selected/events")" == 1 ]] || fail 'selected-node collection submitted a peer wallet'
assert_contains 'submit tonnode-3 alld' "$test_dir/selected/events"

check_fleet_case pending-empty success
assert_contains 'submit tonnode-0 alld' "$test_dir/pending-empty/events"
assert_contains '5/5' "$test_dir/pending-empty.out"

check_fleet_case numeric-recovery success
assert_not_contains 'submit tonnode-0 ' "$test_dir/numeric-recovery/events"
assert_contains 'submit tonnode-1 0.25' "$test_dir/numeric-recovery/events"
[[ "$(grep -c '^submit ' "$test_dir/numeric-recovery/events")" == 4 ]] || fail 'numeric batch recovery repeated an already confirmed peer payment'

check_fleet_case conflicting-pending failure
assert_contains 'Synthetic different collection is already pending' "$test_dir/conflicting-pending.out"
assert_not_contains 'submit ' "$test_dir/conflicting-pending/events"
assert_not_contains 'confirm ' "$test_dir/conflicting-pending/events"

echo 'kubeton wallet collection tests passed (10 fleet scenarios).'
