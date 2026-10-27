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
  # Fail closed if an HTTPS fallback is added or used. Dedicated cases below
  # replace this with exact public API response fixtures.
  curl() { return 91; }

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

setup_http_case() {
  setup_case "$1"
  TONCENTER_URL=https://toncenter.com
  TONCENTER_API_KEY=""
  account_rc=1
  method_rc=1
  api_rc=0
  api_response='{"ok":true,"result":{"wallet":false,"account_state":"uninitialized","balance":"10000007883"}}'
  curl() {
    local got_address=0 got_get=0 endpoint="" argument
    while (( $# > 0 )); do
      argument="$1"
      shift
      case "$argument" in
        -fsS) ;;
        --connect-timeout|--max-time)
          [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || fail 'unbounded API request'
          shift
          ;;
        --get) got_get=1 ;;
        --data-urlencode)
          [[ "${1:-}" == "address=$fixture_address" ]] || fail 'wrong account in API query'
          got_address=1
          shift
          ;;
        -H)
          [[ "${1:-}" == 'X-API-Key: synthetic-query-token' ]] || fail 'unexpected API header'
          shift
          ;;
        https://toncenter.com/api/v2/getWalletInformation|https://testnet.toncenter.com/api/v2/getWalletInformation)
          endpoint="$argument"
          ;;
        *) fail "unexpected HTTP operation: $argument" ;;
      esac
    done
    [[ "$got_get" == 1 && "$got_address" == 1 && -n "$endpoint" ]] || fail 'unexpected API request shape'
    printf 'https %s\n' "$endpoint" >>"$case_dir/queries"
    printf '%s\n' "$api_response"
    return "$api_rc"
  }
}

test_funded_uninit_https_fallback() (
  setup_http_case https-uninit
  assert_value 10000007883 wallet_balance_nano
  assert_value 0 wallet_seqno_decimal
  [[ "$(wallet_account_status "$fixture_address")" == uninit ]] || fail 'HTTPS did not identify funded undeployed wallet'
  [[ "$(wallet_show_chain_state fixture "$fixture_address" mainnet 2>"$case_dir/show.stderr")" == $'10.000007883\t0' ]] \
    || fail 'wallet show did not render a funded undeployed account consistently'
  [[ ! -s "$case_dir/show.stderr" ]] || fail 'wallet show warned despite successful HTTPS account state'
)

test_active_https_seqno_fallback() (
  setup_http_case https-active
  api_response='{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"10000000000","seqno":19,"wallet_type":"wallet v3 r2"}}'
  assert_value 10000000000 wallet_balance_nano
  assert_value 19 wallet_seqno_decimal
  [[ "$(wallet_account_status "$fixture_address")" == active ]] || fail 'HTTPS lost deployed state'
)

test_failed_https_cannot_supply_account_state() (
  setup_http_case https-failed
  # Valid-looking data printed by an unsuccessful process cannot establish 0.
  api_rc=28
  assert_query_failure wallet_balance_nano
  assert_query_failure wallet_seqno_decimal
  if wallet_account_status "$fixture_address" >"$case_dir/status" 2>/dev/null; then
    fail 'failed HTTPS established an account state'
  fi
)

test_invalid_https_account_payload_is_not_zero() (
  setup_http_case https-invalid
  for api_response in \
    '{"ok":false,"result":{"account_state":"uninitialized","balance":"10000007883"}}' \
    '{"ok":true,"result":{"account_state":"uninitialized"}}' \
    '{"ok":true,"result":{"account_state":"unexpected","balance":"0"}}' \
    '{"ok":true,"result":{"account_state":"uninitialized","balance":"unknown"}}' \
    '{"ok":true,"result":{"account_state":"uninitialized","balance":"-1"}}' \
    'not JSON'; do
    assert_query_failure wallet_balance_nano
    assert_query_failure wallet_seqno_decimal
  done
)

test_invalid_active_https_seqno_is_unknown() (
  setup_http_case https-invalid-seqno
  for api_response in \
    '{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"42"}}' \
    '{"ok":true,"result":{"wallet":false,"account_state":"active","balance":"42","seqno":0}}' \
    '{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"42","seqno":-1}}' \
    '{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"42","seqno":1.5}}' \
    '{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"42","seqno":4294967296}}'; do
    assert_query_failure wallet_seqno_decimal
  done
)

test_frozen_https_is_not_undeployed() (
  setup_http_case https-frozen
  api_response='{"ok":true,"result":{"wallet":false,"account_state":"frozen","balance":"10000007883"}}'
  [[ "$(wallet_account_status "$fixture_address")" == frozen ]] || fail 'HTTPS lost frozen state'
  assert_value 10000007883 wallet_balance_nano
  assert_query_failure wallet_seqno_decimal
)

test_https_uses_active_network_only() (
  setup_http_case https-network
  local endpoint
  for endpoint in https://testnet.toncenter.com https://unrelated.invalid; do
    TONCENTER_URL="$endpoint"
    if wallet_toncenter_information "$fixture_address" >"$case_dir/out" 2>/dev/null; then
      fail 'queried an unrelated or mismatched HTTPS endpoint'
    fi
    [[ ! -s "$case_dir/queries" ]] || fail 'mismatched endpoint reached HTTP'
  done
  WALLET_NETWORK=testnet
  TONCENTER_URL=https://testnet.toncenter.com
  TONCENTER_API_KEY=synthetic-query-token
  [[ "$(wallet_toncenter_information "$fixture_address")" == $'uninit\t10000007883\t0' ]] \
    || fail 'matching testnet query did not parse its account state'
  grep -Fq 'https https://testnet.toncenter.com/api/v2/getWalletInformation' "$case_dir/queries" \
    || fail 'testnet query used a different endpoint'
)

test_seqno_stack_requires_exact_uint32() (
  setup_case seqno-stack
  local response actual
  for response in \
    'result: [ 7 9 ]' \
    'result: [ 7oops ]' \
    'result: [ 7' \
    'result: [ -1 ]' \
    'result: [ 4294967296 ]' \
    'result: [ 0x100000000 ]' \
    'result: [ 3.5 ]'; do
    if actual="$(parse_seqno_from_runmethod_output "$response")"; then
      fail "accepted malformed seqno stack '$response' as '$actual'"
    fi
  done
  [[ "$(parse_seqno_from_runmethod_output 'result: [ 4294967295 ]')" == 4294967295 ]] \
    || fail 'valid maximum seqno was rejected'
  [[ "$(parse_seqno_from_runmethod_output 'result: [ 0xFFFFFFFF ]')" == 4294967295 ]] \
    || fail 'valid hex seqno was rejected'
  [[ "$(parse_seqno_from_runmethod_output $'result: [\n  19\n]')" == 19 ]] \
    || fail 'valid multiline seqno stack was rejected'
)

test_frozen_account_data_cannot_supply_seqno() (
  setup_case frozen-data
  account_output=$'state:account_frozen\n data:x{000000130000002A}'
  assert_query_failure wallet_seqno_decimal
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
test_funded_uninit_https_fallback
test_active_https_seqno_fallback
test_failed_https_cannot_supply_account_state
test_invalid_https_account_payload_is_not_zero
test_invalid_active_https_seqno_is_unknown
test_frozen_https_is_not_undeployed
test_https_uses_active_network_only
test_seqno_stack_requires_exact_uint32
test_frozen_account_data_cannot_supply_seqno

echo 'kubeton wallet chain query tests passed (25 cases).'
