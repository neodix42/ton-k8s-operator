#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/charts/ton-k8s-operator/main-wallet.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }

setup_case() {
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir"
  source "$helper"
  WALLET_NETWORK=mainnet
  MAIN_WALLET_SEND_RETRY_ATTEMPTS=1
  MAIN_WALLET_SEND_RETRY_DELAY_SEC=0
  fixture_address="0:$(printf '%064d' 1)"
  account_output='account state is empty'
  account_rc=0
  method_output='account state is empty (cannot run method seqno)'
  method_rc=1
  : >"$case_dir/queries"

  # Replace the entire RPC boundary. Tests never use a real network, cluster,
  # wallet, global configuration or installed lite-client executable.
  run_liteclient_query() {
    printf '%s\n' "$1" >>"$case_dir/queries"
    case "$1" in
      "getaccount $fixture_address")
        printf '%s\n' "$account_output"
        return "$account_rc"
        ;;
      "runmethod $fixture_address seqno")
        printf '%s\n' "$method_output"
        return "$method_rc"
        ;;
      *) fail "unexpected lite-client query: $1" ;;
    esac
  }
}

assert_value() {
  local expected="$1" function_name="$2" actual
  actual="$("$function_name" "$fixture_address" 2>"$case_dir/stderr")" \
    || fail "$function_name failed; expected $expected"
  [[ "$actual" == "$expected" ]] || fail "$function_name returned '$actual'; expected '$expected'"
}

assert_query_failure() {
  local function_name="$1" actual
  if actual="$("$function_name" "$fixture_address" 2>"$case_dir/stderr")"; then
    fail "$function_name accepted an unsuccessful or unrecognized account response: '$actual'"
  fi
  [[ -z "$actual" ]] || fail "$function_name printed a numeric value despite failing: '$actual'"
}

test_empty_account() (
  setup_case empty
  assert_value 0 wallet_balance_nano
  assert_value 0 wallet_seqno_decimal
)

test_empty_account_crlf() (
  setup_case empty-crlf
  account_output=$'zerostate set to fixture\r\n  account state is empty\r\n'
  assert_value 0 wallet_balance_nano
  assert_value 0 wallet_seqno_decimal
)

test_legacy_empty_account() (
  setup_case legacy-empty
  for account_output in 'state: account_none' 'state:(account_none)' 'account_none$0'; do
    assert_value 0 wallet_balance_nano
    assert_value 0 wallet_seqno_decimal
  done
)

test_funded_uninitialized_account() (
  setup_case funded-uninit
  account_output=$'account state is (account\n balance:(currencies grams:(nanograms amount:(var_uint len:4 value:2500000000)))\n state:account_uninit)'
  assert_value 2500000000 wallet_balance_nano
  assert_value 0 wallet_seqno_decimal
)

test_parenthesized_uninitialized_account() (
  setup_case parenthesized-uninit
  account_output=$'balance: (currencies grams:(nanograms amount:(var_uint value:42)))\n state:(account_uninit)'
  assert_value 42 wallet_balance_nano
  assert_value 0 wallet_seqno_decimal
)

test_deployed_account() (
  setup_case deployed
  account_output=$'account state is (account\n balance:(currencies grams:(nanograms amount:(var_uint value:12345000000)))\n state:(account_active))'
  method_output='result: [ 19 ]'
  method_rc=0
  assert_value 12345000000 wallet_balance_nano
  assert_value 19 wallet_seqno_decimal
)

test_failed_method_uses_successful_account_data() (
  setup_case method-fallback
  method_output='result: [ 900 ]'
  method_rc=1
  account_output=$'state:account_active\n data:(just value:x{000000130000002A})\n library:hme_empty'
  assert_value 19 wallet_seqno_decimal
)

test_malformed_method_uses_successful_account_data() (
  setup_case malformed-method
  method_output='result: error 11'
  method_rc=0
  account_output=$'state:account_active\n data:x{000000130000002A}'
  assert_value 19 wallet_seqno_decimal
)

test_failed_rpc_cannot_mean_empty() (
  setup_case failed-empty
  account_rc=1
  assert_query_failure wallet_balance_nano
  assert_query_failure wallet_seqno_decimal
)

test_failed_rpc_cannot_supply_balance() (
  setup_case failed-balance
  account_output='balance: (currencies grams:(nanograms amount:(var_uint value:2500000000)))'
  account_rc=1
  assert_query_failure wallet_balance_nano
)

test_failed_rpc_cannot_supply_seqno() (
  setup_case failed-seqno
  method_output='result: [ 19 ]'
  method_rc=1
  account_output='RPC request failed'
  account_rc=1
  assert_query_failure wallet_seqno_decimal
)

test_failed_rpc_cannot_supply_account_data() (
  setup_case failed-account-data
  account_output=$'state:account_active\n data:x{000000130000002A}'
  account_rc=1
  assert_query_failure wallet_seqno_decimal
)

test_error_sentence_is_not_an_empty_account() (
  setup_case error-sentence
  account_output='account state is empty (cannot run method seqno)'
  assert_query_failure wallet_balance_nano
  assert_query_failure wallet_seqno_decimal
)

test_unknown_account_remains_unknown() (
  setup_case unknown
  account_output='unrecognized account output'
  assert_query_failure wallet_balance_nano
  assert_query_failure wallet_seqno_decimal
  [[ "$(wallet_show_chain_state fixture "$fixture_address" mainnet 2>"$case_dir/show.stderr")" == $'unknown\tunknown' ]] \
    || fail 'wallet show converted an unresolved query to zero'
)

test_empty_account_show() (
  setup_case empty-show
  [[ "$(wallet_show_chain_state fixture "$fixture_address" mainnet 2>"$case_dir/show.stderr")" == $'0.000000000\t0' ]] \
    || fail 'wallet show did not render an absent account as zero balance and seqno'
  [[ ! -s "$case_dir/show.stderr" ]] || fail 'wallet show warned on a successfully checked empty account'
)

test_balance_retry() (
  setup_case retry-balance
  MAIN_WALLET_SEND_RETRY_ATTEMPTS=2
  run_liteclient_query() {
    [[ "$1" == "getaccount $fixture_address" ]] || fail "unexpected query: $1"
    printf '%s\n' "$1" >>"$case_dir/queries"
    if [[ "$(wc -l <"$case_dir/queries")" -eq 1 ]]; then
      printf 'RPC request failed\n'
      return 1
    fi
    printf 'account state is empty\n'
  }
  assert_value 0 wallet_balance_nano
  [[ "$(wc -l <"$case_dir/queries")" -eq 2 ]] || fail 'balance lookup did not retry a failed RPC'
)

test_empty_account
test_empty_account_crlf
test_legacy_empty_account
test_funded_uninitialized_account
test_parenthesized_uninitialized_account
test_deployed_account
test_failed_method_uses_successful_account_data
test_malformed_method_uses_successful_account_data
test_failed_rpc_cannot_mean_empty
test_failed_rpc_cannot_supply_balance
test_failed_rpc_cannot_supply_seqno
test_failed_rpc_cannot_supply_account_data
test_error_sentence_is_not_an_empty_account
test_unknown_account_remains_unknown
test_empty_account_show
test_balance_retry

echo 'kubeton wallet chain query tests passed (16 cases).'
