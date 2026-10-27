#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset MAIN_WALLET_POD_TIMEOUT MAIN_WALLET_CONFIRM_TIMEOUT_SEC MAIN_WALLET_HTTP_MIN_INTERVAL_MS
unset MAIN_WALLET_REBROADCAST_DELAY_SEC MAIN_WALLET_REBROADCAST_ATTEMPTS
source "$repo_root/charts/ton-k8s-operator/kubeton"

fail() { echo "test failure: $*" >&2; exit 1; }
assert_budget() {
  local expected="$1" actual
  shift
  actual="$(main_wallet_timeout_seconds "$@")"
  [[ "$actual" == "$expected" ]] || fail "wallet timeout '$*' returned $actual; expected $expected"
}

[[ "$MAIN_WALLET_CONFIRM_TIMEOUT_SEC" == 180 ]] || fail 'default confirmation budget is not 180 seconds'
[[ "$MAIN_WALLET_HTTP_MIN_INTERVAL_MS" == 1100 ]] || fail 'default anonymous API pacing was not configured'
[[ "$MAIN_WALLET_REBROADCAST_DELAY_SEC" == 10 && "$MAIN_WALLET_REBROADCAST_ATTEMPTS" == 3 ]] || fail 'default rebroadcast settings are inconsistent'
assert_budget 900
assert_budget 900 show 5
assert_budget 900 deploy 5
assert_budget 900 send 1
assert_budget 900 send 0
assert_budget 1560 send 5
assert_budget 5160 send 20
MAIN_WALLET_CONFIRM_TIMEOUT_SEC=300
assert_budget 2280 send 5
MAIN_WALLET_CONFIRM_TIMEOUT_SEC=60
assert_budget 900 send 5
MAIN_WALLET_CONFIRM_TIMEOUT_SEC=invalid
assert_budget 1560 send 5
MAIN_WALLET_POD_TIMEOUT=900s
assert_budget 900 send 5
MAIN_WALLET_POD_TIMEOUT=1800
assert_budget 1800 send 20
MAIN_WALLET_POD_TIMEOUT=30s
assert_budget 30 send 20
MAIN_WALLET_POD_TIMEOUT=invalid
assert_budget 900 send 20
MAIN_WALLET_POD_TIMEOUT=''
assert_budget 1560 send 5
echo 'kubeton main-wallet timeout tests passed (18 scenarios).'
