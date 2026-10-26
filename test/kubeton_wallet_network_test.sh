#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Network identities are the official zero-state tuples. The extra config
# fields distinguish the node's actual file from endpoint-generated defaults.
mainnet_config='{"@type":"config.global","dht":{},"liteservers":[],"validator":{"zero_state":{"workchain":-1,"shard":-9223372036854775808,"seqno":0,"root_hash":"F6OpKZKqvqeFp6CQmFomXNMfMj2EnaUSOXN+Mh+wVWk=","file_hash":"XplPz01CXAps5qeSWUtxcyBfdAo5zVb1N979KLSKD24="}},"test_source":"active mainnet node"}'
testnet_config='{"@type":"config.global","dht":{},"liteservers":[],"validator":{"zero_state":{"workchain":-1,"shard":-9223372036854775808,"seqno":0,"root_hash":"gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=","file_hash":"Z+IKwYS54DmmJmesw/nAD5DzWadnOCMzee+kdgSYDOg="}},"test_source":"active testnet node"}'

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

# Every cluster boundary is replaced below. Unknown calls fail instead of
# accidentally using the caller's cluster, network, credentials or wallets.
setup_case() {
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir"
  events="$case_dir/events"
  manifest="$case_dir/pod.yaml"
  : >"$events"
  source "$kubeton"
  production_resolve_wallet_fleet_config="$(declare -f resolve_wallet_fleet_config)"
  TON_NAMESPACE=test-ns
  MAIN_WALLET_TARGET_WALLET_NAME=validator_wallet_001
  MAIN_WALLET_GLOBAL_CONFIG_URL=https://unrelated.invalid/ignored-global.json
  MAIN_WALLET_TONCENTER_URL=https://unrelated.invalid/ignored-toncenter
  fixture_destination_address="0:$(printf '%064d' 1)"
  fixture_second_address="0:$(printf '%064d' 2)"
  inference_mode=testnet

  record() {
    printf '%s' "$1" >>"$events"
    shift
    printf ' <%s>' "$@" >>"$events"
    printf '\n' >>"$events"
  }
  kubectl() {
    if [[ "$*" == '-n test-ns apply -f -' ]]; then
      record mutation apply
      cat >"$manifest"
    elif [[ "$*" == '-n test-ns logs '* ]]; then
      record logs
    elif [[ "$*" == '-n test-ns delete pod '* ]]; then
      record mutation delete
    else
      record unexpected-kubectl "$@"
      echo "unexpected mocked kubectl call: $*" >&2
      return 91
    fi
  }
  curl() { record unexpected-network "$@"; return 92; }
  confirm_or_exit() { record confirmation "$@"; }
  should_bootstrap_baremetal() { return 1; }
  validate_external_key_prereqs() { record key-prereqs; }
  ensure_namespace() { record mutation namespace "$@"; }
  ensure_main_wallet_helper_slot() { record helper-slot "$@"; }
  ensure_main_wallet_script_configmap() { record mutation configmap "$@"; }
  ensure_main_wallet_bundle_pvc() { record mutation pvc "$@"; }
  main_wallet_bundle_storage_class() { printf '%s' test-storage; }
  ensure_main_wallet_longhorn_ready() { :; }
  main_wallet_pod_longhorn_csi_affinity_yaml() { :; }
  resolve_main_wallet_image() { printf '%s' test-wallet-image; }
  main_wallet_timeout_seconds() { printf '%s' 20; }
  wait_main_wallet_pod_completion() { record helper-complete "$@"; }
  list_ton_pods() {
    printf 'test-ns\ttonnode-0\tworker-0\ntest-ns\ttonnode-1\tworker-1\n'
  }
  resolve_tonnode_pod_row_by_name() {
    case "$1" in
      tonnode-0|test-ns/tonnode-0) printf 'test-ns\ttonnode-0\tworker-0\n' ;;
      tonnode-1|test-ns/tonnode-1) printf 'test-ns\ttonnode-1\tworker-1\n' ;;
      *) return 1 ;;
    esac
  }
  resolve_tonnode_wallet_address_from_pod() {
    record wallet-address "$@"
    if [[ "$2" == tonnode-0 ]]; then
      printf '%s' "$fixture_destination_address"
    else
      printf '%s' "$fixture_second_address"
    fi
  }
  run_wallet_activate() { record activate "$@"; }
  run_wallet_balance_show() { record balance "$@"; }
  run_wallet_export_tonnode() { record export-tonnode "$@"; }
  resolve_main_wallet_receive_address() {
    record main-address "$@"
    printf '%s' "$fixture_destination_address"
  }
  resolve_tonnode_wallet_row_from_pod() {
    printf '%s\tactive\t25\tv3\t0\t%s\n' "$3" "$fixture_second_address"
  }
  collect_tonnode_wallet_in_pod() { record mutation-collect "$@"; }
  resolve_wallet_fleet_config() {
    record detect-network
    case "$inference_mode" in
      mainnet)
        KUBETON_WALLET_NETWORK=mainnet
        KUBETON_WALLET_GLOBAL_CONFIG_JSON="$mainnet_config"
        ;;
      testnet)
        KUBETON_WALLET_NETWORK=testnet
        KUBETON_WALLET_GLOBAL_CONFIG_JSON="$testnet_config"
        ;;
      *)
        echo "Error: test network detection unavailable" >&2
        return 1
        ;;
    esac
  }
}

assert_helper_command() {
  python3 - "$manifest" "$@" <<'PY'
import pathlib
import sys
import json

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = lines.index("      command:") + 1
end = lines.index("      env:", start)
actual = [json.loads(line.removeprefix("        - "))
          for line in lines[start:end]]
expected = ["/scripts/main-wallet.sh", "run", *sys.argv[2:]]
assert actual == expected, (actual, expected)
PY
}

assert_helper_env() {
  python3 - "$manifest" "$1" "$2" <<'PY'
import pathlib
import sys
import json

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = lines.index(f"        - name: {sys.argv[2]}")
actual = json.loads(lines[start + 1].removeprefix("          value: "))
assert actual == sys.argv[3], (sys.argv[2], actual, sys.argv[3])
PY
}

assert_no_side_effects() {
  [[ ! -e "$manifest" ]] || fail "helper pod created despite network detection failure"
  assert_not_contains mutation "$events"
  assert_not_contains confirmation "$events"
  assert_not_contains collect "$events"
  assert_not_contains unexpected-kubectl "$events"
  assert_not_contains unexpected-network "$events"
}

test_unchanged_local_commands() (
  setup_case unchanged-local
  inference_mode=unavailable
  run_wallet >"$case_dir/help"
  [[ ! -s "$events" ]] || fail "wallet help performed cluster operations"

  run_wallet create >"$case_dir/create-default"
  assert_helper_command create
  run_wallet create savings >"$case_dir/create-name"
  assert_helper_command create 0 42 savings
  run_wallet create -1 99 savings >"$case_dir/create-legacy"
  assert_helper_command create -1 99 savings
  run_wallet show >"$case_dir/show-all"
  assert_helper_command show
  run_wallet show savings >"$case_dir/show-name"
  assert_helper_command show savings
  run_wallet export savings >"$case_dir/export-main"
  assert_helper_command export savings

  rm -f "$manifest"
  : >"$events"
  run_wallet activate >"$case_dir/activate-all"
  run_wallet activate tonnode-0 reserve >"$case_dir/activate-one"
  run_wallet show balance >"$case_dir/balance-all"
  run_wallet show balance tonnode-0 reserve >"$case_dir/balance-one"
  run_wallet export >"$case_dir/export-all"
  run_wallet export tonnode-0 reserve >"$case_dir/export-one"
  assert_contains 'activate <> <validator_wallet_001>' "$events"
  assert_contains 'activate <tonnode-0> <reserve>' "$events"
  assert_contains 'balance <> <validator_wallet_001>' "$events"
  assert_contains 'balance <tonnode-0> <reserve>' "$events"
  assert_contains 'export-tonnode <> <>' "$events"
  assert_contains 'export-tonnode <tonnode-0> <reserve>' "$events"
  assert_not_contains detect-network "$events"
  assert_no_side_effects
)

test_networkless_deploy() (
  setup_case deploy
  run_wallet deploy savings >"$case_dir/output"
  assert_helper_command deploy savings
  assert_helper_env WALLET_NETWORK testnet
  assert_helper_env GLOBAL_CONFIG_JSON "$testnet_config"
  assert_helper_env TONCENTER_URL https://testnet.toncenter.com
  assert_not_contains 'unrelated.invalid' "$manifest"

  run_wallet deploy >"$case_dir/deploy-all"
  assert_helper_command deploy
  assert_contains 'ALL wallets on testnet' "$events"

  testnet_config="$(printf '%s' "$testnet_config" | python3 -m json.tool)"
  run_wallet deploy savings >"$case_dir/pretty-config"
  assert_helper_env GLOBAL_CONFIG_JSON "$testnet_config"

  inference_mode=mainnet
  run_wallet deploy savings >"$case_dir/mainnet"
  assert_helper_env WALLET_NETWORK mainnet
  assert_helper_env GLOBAL_CONFIG_JSON "$mainnet_config"
  assert_helper_env TONCENTER_URL https://toncenter.com
)

test_networkless_send_forms() (
  setup_case send
  local flag
  for flag in '' -n; do
    local -a flags=()
    [[ -z "$flag" ]] || flags+=("$flag")

    run_wallet send savings "$fixture_destination_address" 3.5 "${flags[@]}" >"$case_dir/direct${flag}"
    assert_helper_command send savings "$fixture_destination_address" 3.5 "${flags[@]}"
    assert_helper_env WALLET_NETWORK testnet
    assert_helper_env GLOBAL_CONFIG_JSON "$testnet_config"

    run_wallet send savings tonnode-0 3.5 "${flags[@]}" >"$case_dir/pod${flag}"
    assert_helper_command send savings "$fixture_destination_address" 3.5 "${flags[@]}"
    assert_contains 'wallet-address <test-ns> <tonnode-0> <validator_wallet_001> <testnet>' "$events"

    run_wallet send savings tonnode-0 reserve 3.5 "${flags[@]}" >"$case_dir/named${flag}"
    assert_helper_command send savings "$fixture_destination_address" 3.5 "${flags[@]}"
    assert_contains 'wallet-address <test-ns> <tonnode-0> <reserve>' "$events"

    run_wallet send savings 10. "${flags[@]}" >"$case_dir/split${flag}"
    assert_helper_command send savings 10. "$fixture_destination_address" "$fixture_second_address" "${flags[@]}"
    assert_contains "send '5.000000000' from 'savings' on testnet" "$events"
    assert_contains '(2 total)' "$events"
    assert_contains "$fixture_destination_address" "$case_dir/split${flag}"
    assert_contains "$fixture_second_address" "$case_dir/split${flag}"
  done
)

test_send_requires_complete_inventory() (
  setup_case send-inventory-errors
  local mode
  list_ton_pods() {
    case "$mode" in
      failed) return 1 ;;
      partial-error) printf 'test-ns\ttonnode-0\tworker-0\n'; return 1 ;;
      empty) return 0 ;;
      malformed) printf 'test-ns\ttonnode-0\tworker-0\nincomplete-row\n' ;;
    esac
  }
  for mode in failed partial-error empty malformed; do
    : >"$events"
    if run_wallet send savings 10. >"$case_dir/$mode" 2>&1; then
      fail "send accepted $mode recipient inventory"
    fi
    assert_contains 'Error:' "$case_dir/$mode"
    assert_not_contains skipping "$case_dir/$mode"
    assert_no_side_effects
    if [[ "$mode" == failed || "$mode" == partial-error ]]; then
      assert_not_contains wallet-address "$events"
    fi
  done
)

test_send_requires_every_wallet_address() (
  setup_case send-wallet-errors
  local mode
  resolve_tonnode_wallet_address_from_pod() {
    record wallet-address "$@"
    if [[ "$2" == tonnode-0 ]]; then
      printf '%s' "$fixture_destination_address"
      return 0
    fi
    case "$mode" in
      empty) return 0 ;;
      failed) return 1 ;;
      partial-error) printf '%s' "$fixture_second_address"; return 1 ;;
    esac
  }
  for mode in empty failed partial-error; do
    : >"$events"
    if run_wallet send savings 10. >"$case_dir/$mode" 2>&1; then
      fail "send accepted $mode address lookup for a recipient"
    fi
    assert_contains "cannot resolve wallet 'validator_wallet_001' in test-ns/tonnode-1" "$case_dir/$mode"
    assert_not_contains skipping "$case_dir/$mode"
    assert_contains 'wallet-address <test-ns> <tonnode-0>' "$events"
    assert_contains 'wallet-address <test-ns> <tonnode-1>' "$events"
    assert_no_side_effects
  done
)

test_send_rejects_invalid_pod_addresses() (
  setup_case send-invalid-addresses
  local friendly_testnet invalid_checksum mode destination
  friendly_testnet="$(python3 - "$fixture_second_address" <<'PY'
import base64
import binascii
import sys

workchain, account = sys.argv[1].split(":")
body = bytes([0xD1, int(workchain) & 0xff]) + bytes.fromhex(account)
print(base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode())
PY
)"
  invalid_checksum="${friendly_testnet:0:47}A"
  [[ "$invalid_checksum" != "$friendly_testnet" ]] || invalid_checksum="${friendly_testnet:0:47}B"
  resolve_tonnode_wallet_address_from_pod() {
    record wallet-address "$@"
    if [[ "$2" == tonnode-0 ]]; then
      printf '%s' "$fixture_destination_address"
    else
      printf '%s' "$destination"
    fi
  }
  for mode in malformed bad-checksum wrong-network; do
    inference_mode=testnet
    case "$mode" in
      malformed) destination='0:invalid-address' ;;
      bad-checksum) destination="$invalid_checksum" ;;
      wrong-network) inference_mode=mainnet; destination="$friendly_testnet" ;;
    esac
    for target in all selected; do
      : >"$events"
      local -a args=(savings 10.)
      [[ "$target" != selected ]] || args=(savings tonnode-1 10.)
      if run_wallet send "${args[@]}" >"$case_dir/$mode-$target" 2>&1; then
        fail "send accepted $mode address for $target recipients"
      fi
      assert_contains "wallet 'validator_wallet_001' in test-ns/tonnode-1 has an invalid destination address" "$case_dir/$mode-$target"
      assert_no_side_effects
    done
  done
)

test_invalid_no_bounce_positions() (
  setup_case no-bounce-errors
  local -a args
  for position in prefix middle repeated; do
    case "$position" in
      prefix) args=(-n savings "$fixture_destination_address" 1) ;;
      middle) args=(savings "$fixture_destination_address" -n 1) ;;
      repeated) args=(savings "$fixture_destination_address" 1 -n -n) ;;
    esac
    if run_wallet send "${args[@]}" >"$case_dir/$position" 2>&1; then
      fail "accepted a misplaced/repeated no-bounce flag"
    fi
    assert_contains "'-n' must be the last optional argument" "$case_dir/$position"
    assert_no_side_effects
  done
)

test_networkless_collect_forms() (
  setup_case collect
  run_wallet collect treasury >"$case_dir/default"
  assert_contains 'main-address <testnet> <treasury>' "$events"
  assert_contains "collect <test-ns> <tonnode-0> <validator_wallet_001> <$fixture_destination_address> <alld>" "$events"
  assert_contains "collect <test-ns> <tonnode-1> <validator_wallet_001> <$fixture_destination_address> <alld>" "$events"

  : >"$events"
  run_wallet collect treasury 7.5 >"$case_dir/all-amount"
  assert_contains "collect <test-ns> <tonnode-0> <validator_wallet_001> <$fixture_destination_address> <7.5>" "$events"
  run_wallet collect treasury tonnode-0 >"$case_dir/one-default"
  assert_contains "collect <test-ns> <tonnode-0> <validator_wallet_001> <$fixture_destination_address> <alld>" "$events"
  run_wallet collect treasury tonnode-0 4. >"$case_dir/one-amount"
  assert_contains "collect <test-ns> <tonnode-0> <validator_wallet_001> <$fixture_destination_address> <4.>" "$events"
  run_wallet collect treasury tonnode-0 reserve >"$case_dir/one-wallet"
  assert_contains "collect <test-ns> <tonnode-0> <reserve> <$fixture_destination_address> <alld>" "$events"
  run_wallet collect treasury tonnode-0 reserve 2.5 >"$case_dir/one-wallet-amount"
  assert_contains "collect <test-ns> <tonnode-0> <reserve> <$fixture_destination_address> <2.5>" "$events"
  [[ ! -e "$manifest" ]] || fail "collect unexpectedly created a wallet helper"
)

test_legacy_matching_network() (
  setup_case legacy-matching
  run_wallet deploy testnet savings >"$case_dir/deploy"
  assert_helper_command deploy savings
  run_wallet send testnet savings "$fixture_destination_address" 1 -n >"$case_dir/send"
  assert_helper_command send savings "$fixture_destination_address" 1 -n
  run_wallet collect testnet treasury tonnode-0 reserve 2 >"$case_dir/collect"
  assert_contains 'main-address <testnet> <treasury>' "$events"
)

test_network_mismatch_or_failure() (
  setup_case network-errors
  local action mode
  local -a args
  for mode in mismatch unavailable; do
    if [[ "$mode" == mismatch ]]; then inference_mode=testnet; else inference_mode=unavailable; fi
    for action in deploy send collect; do
      case "$action" in
        deploy) args=(savings) ;;
        send) args=(savings "$fixture_destination_address" 1) ;;
        collect) args=(treasury) ;;
      esac
      [[ "$mode" != mismatch ]] || args=(mainnet "${args[@]}")
      : >"$events"
      if run_wallet "$action" "${args[@]}" >"$case_dir/$mode-$action" 2>&1; then
        fail "$action succeeded with $mode network"
      fi
      assert_no_side_effects
    done
  done
)

test_global_config_classification() (
  source "$kubeton"
  [[ "$(printf '%s' "$mainnet_config" | wallet_network_from_global_config)" == mainnet ]] \
    || fail "official mainnet zero state was not recognized"
  [[ "$(printf '%s' "$testnet_config" | wallet_network_from_global_config)" == testnet ]] \
    || fail "official testnet zero state was not recognized"

  mkdir -p "$test_dir/invalid-configs"
  python3 - "$test_dir/invalid-configs" "$mainnet_config" "$testnet_config" <<'PY'
import copy
import json
import pathlib
import sys

folder = pathlib.Path(sys.argv[1])
base = json.loads(sys.argv[2])
testnet = json.loads(sys.argv[3])
for field, bad in [
    ("root_hash", "unknown-root"),
    ("file_hash", testnet["validator"]["zero_state"]["file_hash"]),
    ("workchain", 0),
    ("shard", 1),
    ("seqno", 1),
]:
    config = copy.deepcopy(base)
    config["validator"]["zero_state"][field] = bad
    (folder / f"{field}.json").write_text(json.dumps(config))
for name, raw in [
    ("malformed", "{"),
    ("empty", ""),
    ("array", "[]"),
    ("missing", '{"validator":{}}'),
    ("null", '{"validator":{"zero_state":null}}'),
    ("scalar", '{"validator":{"zero_state":"mainnet"}}'),
]:
    (folder / f"{name}.json").write_text(raw)
PY
  local fixture
  for fixture in "$test_dir/invalid-configs/"*.json; do
    if wallet_network_from_global_config <"$fixture" >"$test_dir/classifier.out" 2>&1; then
      fail "accepted invalid/unknown network config $fixture"
    fi
  done
)

test_runtime_config_reader() (
  source "$kubeton"
  local calls="$test_dir/runtime-config-reader.calls"
  : >"$calls"
  run_with_timeout() { shift; "$@"; }
  kubectl() {
    printf '%s\n' "$*" >>"$calls"
    [[ "$*" == '-n test-ns exec tonnode-0 -c ton-node -- cat /var/ton-work/controller/global.config.json' ]] \
      || fail "network reader used something other than the active node config"
    printf '%s' "$testnet_config"
  }
  [[ "$(read_tonnode_global_config test-ns tonnode-0)" == "$testnet_config" ]] \
    || fail "runtime config reader changed node JSON"
  assert_contains '/var/ton-work/controller/global.config.json' "$calls"
)

test_fleet_config_detection() (
  setup_case fleet-detection
  eval "$production_resolve_wallet_fleet_config"
  read_tonnode_global_config() {
    record network-read "$@"
    case "$2" in
      tonnode-0) printf '%s' "$testnet_config" ;;
      tonnode-1) printf '%s' "${testnet_config/active testnet node/second node same network}" ;;
      *) return 1 ;;
    esac
  }
  resolve_wallet_fleet_config
  [[ "$KUBETON_WALLET_NETWORK" == testnet ]] || fail "fleet network was not detected"
  [[ "$KUBETON_WALLET_GLOBAL_CONFIG_JSON" == "$testnet_config" ]] \
    || fail "fleet detection did not preserve an active node config"
  assert_contains 'network-read <test-ns> <tonnode-0>' "$events"
  assert_contains 'network-read <test-ns> <tonnode-1>' "$events"
  assert_no_side_effects

  run_wallet deploy savings >"$case_dir/deploy"
  assert_helper_env WALLET_NETWORK testnet
  assert_helper_env GLOBAL_CONFIG_JSON "$testnet_config"
)

test_runtime_config_failures_prevent_transactions() (
  setup_case runtime-config-errors
  eval "$production_resolve_wallet_fleet_config"
  list_ton_pods() {
    [[ "$inference_mode" != no-pods ]] || return 0
    printf 'test-ns\ttonnode-0\tworker-0\ntest-ns\ttonnode-1\tworker-1\n'
  }
  read_tonnode_global_config() {
    record network-read "$@"
    if [[ "$2" == tonnode-0 ]]; then
      printf '%s' "$testnet_config"
      return 0
    fi
    case "$inference_mode" in
      mixed) printf '%s' "$mainnet_config" ;;
      unreadable) return 1 ;;
      unknown) printf '%s' "${testnet_config/gj+B8wb\/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=/unknown}" ;;
      malformed) printf '{' ;;
      *) return 1 ;;
    esac
  }

  local mode action
  local -a args
  for mode in mixed unreadable unknown malformed no-pods; do
    inference_mode="$mode"
    for action in deploy send collect; do
      case "$action" in
        deploy) args=(savings) ;;
        send) args=(savings tonnode-0 1) ;;
        collect) args=(treasury tonnode-0) ;;
      esac
      : >"$events"
      if run_wallet "$action" "${args[@]}" >"$case_dir/$mode-$action" 2>&1; then
        fail "$action succeeded with $mode node configuration"
      fi
      assert_contains 'Error:' "$case_dir/$mode-$action"
      assert_no_side_effects
      if [[ "$mode" != no-pods ]]; then
        # Even a selected target cannot hide conflicting/unreadable other nodes.
        assert_contains 'network-read <test-ns> <tonnode-1>' "$events"
      fi
    done
  done
)

setup_main_wallet_case() {
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir/wallets"
  events="$case_dir/events"
  : >"$events"
  export TMPDIR="$case_dir"
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$case_dir/wallets"
  WALLET_NETWORK=testnet
  GLOBAL_CONFIG_JSON="$testnet_config"
  GLOBAL_CONFIG_URL=/active/node/global.config.json
  fixture_wallet_address="0:$(printf '%064d' 3)"
  record() {
    printf '%s' "$1" >>"$events"
    shift
    printf ' <%s>' "$@" >>"$events"
    printf '\n' >>"$events"
  }
  curl() { record unexpected-network "$@"; return 92; }
  deploy_boc_with_mode() { record deploy-boc "$@"; }
  record_wallet_deploy_network() { record save-network "$@"; }
  resolve_wallet_address_by_name() { record resolve-source "$@"; printf '%s' "$fixture_wallet_address"; }
  resolve_wallet_subwallet_id_by_name() { record subwallet-id "$@"; printf 42; }
  wallet_seqno_decimal() { record seqno "$@"; printf 9; }
  send_single_transfer() { record send-transfer "$@"; }
  write_wallet_fixture() {
    printf 'wallet_name=%s\nnetwork=%s\nwallet_address=%s\n' "$1" "$2" "$fixture_wallet_address" \
      >"$MAIN_WALLET_DIR/$1.wallet.meta"
    printf 'fake BOC, never submitted\n' >"$MAIN_WALLET_DIR/$1-query.boc"
  }
}

test_main_wallet_transaction_network_guards() (
  setup_main_wallet_case helper-transaction-guards
  write_wallet_fixture savings mainnet
  if main_wallet_deploy savings >"$case_dir/deploy" 2>&1; then
    fail "helper deployed a wallet saved for another network"
  fi
  if main_wallet_send savings "$fixture_wallet_address" 1 >"$case_dir/send" 2>&1; then
    fail "helper sent from a wallet saved for another network"
  fi
  [[ ! -s "$events" ]] || fail "mismatched wallet reached deployment, seqno lookup or transfer"
  assert_contains 'saved for mainnet' "$case_dir/deploy"
  assert_contains 'saved for mainnet' "$case_dir/send"

  # A matching first wallet must not be deployed before a later mismatch is found.
  write_wallet_fixture a-matching testnet
  if main_wallet_deploy >"$case_dir/deploy-all" 2>&1; then
    fail "helper deployed a mixed-network wallet collection"
  fi
  [[ ! -s "$events" ]] || fail "deploy-all submitted BOCs before completing network preflight"

  WALLET_NETWORK=""
  if main_wallet_send a-matching "$fixture_wallet_address" 1 >"$case_dir/no-active" 2>&1; then
    fail "helper sent without an active network"
  fi
  [[ ! -s "$events" ]] || fail "missing active network reached seqno lookup or transfer"

  WALLET_NETWORK=testnet
  write_wallet_fixture savings testnet
  main_wallet_deploy >"$case_dir/deploy-matching"
  assert_contains 'deploy-boc <a-matching>' "$events"
  assert_contains 'deploy-boc <savings>' "$events"
  : >"$events"
  main_wallet_send savings "$fixture_wallet_address" 1 -n >"$case_dir/send-matching"
  assert_contains 'seqno <' "$events"
  assert_contains "send-transfer <savings> <$fixture_wallet_address> <1> <9> <42> <auto> <-n>" "$events"
)

test_main_wallet_show_network_and_config() (
  setup_main_wallet_case helper-show
  write_wallet_fixture savings testnet
  GLOBAL_CONFIG_JSON="$(printf '%s' "$testnet_config" | python3 -m json.tool)"
  printf '%s' "$GLOBAL_CONFIG_JSON" >"$case_dir/expected-config.json"
  wallet_balance_nano() {
    local config_row config_path temporary_path
    config_row="$(resolve_local_global_config_path)" || return 1
    IFS=$'\t' read -r config_path temporary_path <<<"$config_row"
    cmp "$case_dir/expected-config.json" "$config_path" || return 1
    record balance "$WALLET_NETWORK" "$GLOBAL_CONFIG_URL" "$@"
    [[ -z "$temporary_path" ]] || rm -f "$temporary_path"
    printf 2500000000
  }
  main_wallet_show savings >"$case_dir/matching"
  assert_contains 'savings' "$case_dir/matching"
  assert_contains '2.500000000' "$case_dir/matching"
  assert_contains 'balance <testnet> </active/node/global.config.json>' "$events"
  assert_contains 'seqno <' "$events"
  assert_not_contains unexpected-network "$events"

  : >"$events"
  write_wallet_fixture savings mainnet
  main_wallet_show savings >"$case_dir/mismatch" 2>"$case_dir/mismatch.stderr"
  assert_contains 'savings' "$case_dir/mismatch"
  assert_contains 'unknown' "$case_dir/mismatch"
  assert_contains 'active fleet uses testnet' "$case_dir/mismatch.stderr"
  assert_not_contains 'balance <' "$events"
  assert_not_contains 'seqno <' "$events"
  assert_not_contains unexpected-network "$events"

  : >"$events"
  WALLET_NETWORK=""
  main_wallet_show savings >"$case_dir/offline"
  assert_contains 'savings' "$case_dir/offline"
  assert_contains 'unknown' "$case_dir/offline"
  assert_not_contains 'balance <' "$events"
  assert_not_contains 'seqno <' "$events"
  assert_not_contains unexpected-network "$events"
)

test_collect_receive_address_from_real_show_table() (
  setup_main_wallet_case collect-real-show-table
  write_wallet_fixture savings testnet
  IFS=$'\t' read -r fixture_receive_address fixture_bounceable_address < <(python3 - "$fixture_wallet_address" <<'PY'
import base64
import binascii
import sys

workchain, account = sys.argv[1].split(":")
addresses = []
for tag in (0xD1, 0x91):
    body = bytes([tag, int(workchain) & 0xff]) + bytes.fromhex(account)
    addresses.append(base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode())
print("\t".join(addresses))
PY
)
  printf 'workchain=0\nwallet_id=42\nnon_bounceable=%s\nbounceable=%s\n' \
    "$fixture_receive_address" "$fixture_bounceable_address" >>"$MAIN_WALLET_DIR/savings.wallet.meta"
  wallet_balance_nano() { printf 2500000000; }
  fixture_show_table="$(main_wallet_show savings)"
  assert_contains 'wallet-address' <(printf '%s\n' "$fixture_show_table")

  source "$kubeton"
  run_wallet() {
    [[ "$*" == 'show savings' ]] || fail "unexpected nested wallet operation: $*"
    printf '[wallet] Using testnet from the active node config.\n%s\n' "$fixture_show_table"
  }
  [[ "$(resolve_main_wallet_receive_address testnet savings)" == "$fixture_receive_address" ]] \
    || fail "collect did not select the non-bounceable address from the actual nine-column show table"

  # The raw wallet address is column seven; network and balance are not addresses.
  sed -i 's/^non_bounceable=.*/non_bounceable=unknown/' "$MAIN_WALLET_DIR/savings.wallet.meta"
  fixture_show_table="$(main_wallet_show savings)"
  [[ "$(resolve_main_wallet_receive_address testnet savings)" == "$fixture_wallet_address" ]] \
    || fail "collect did not fall back to the raw wallet address"

  if resolve_main_wallet_receive_address mainnet savings >"$case_dir/mismatch" 2>&1; then
    fail "collect accepted a main wallet saved for another network"
  fi
  assert_contains 'saved for testnet' "$case_dir/mismatch"
)

test_collect_mainnet_legacy_friendly_flags() (
  setup_main_wallet_case collect-mainnet-legacy-flags
  WALLET_NETWORK=mainnet
  write_wallet_fixture savings mainnet
  IFS=$'\t' read -r fixture_test_receive fixture_test_bounceable fixture_main_receive fixture_main_bounceable < <(python3 - "$fixture_wallet_address" <<'PY'
import base64
import binascii
import sys

workchain, account = sys.argv[1].split(":")
addresses = []
for tag in (0xD1, 0x91, 0x51, 0x11):
    body = bytes([tag, int(workchain) & 0xff]) + bytes.fromhex(account)
    addresses.append(base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode())
print("\t".join(addresses))
PY
)
  printf 'workchain=0\nwallet_id=42\nnon_bounceable=%s\nbounceable=%s\n' \
    "$fixture_test_receive" "$fixture_test_bounceable" >>"$MAIN_WALLET_DIR/savings.wallet.meta"
  printf 'synthetic existing private key' >"$MAIN_WALLET_DIR/savings.pk"
  cp "$MAIN_WALLET_DIR/savings.wallet.meta" "$case_dir/original.meta"
  cp "$MAIN_WALLET_DIR/savings.pk" "$case_dir/original.pk"
  cp "$MAIN_WALLET_DIR/savings-query.boc" "$case_dir/original.boc"
  wallet_balance_nano() { printf 0; }
  wallet_seqno_decimal() { printf 0; }
  fixture_show_table="$(main_wallet_show savings)"
  assert_contains "$fixture_main_receive" <(printf '%s\n' "$fixture_show_table")
  assert_contains "$fixture_main_bounceable" <(printf '%s\n' "$fixture_show_table")
  assert_not_contains "$fixture_test_receive" <(printf '%s\n' "$fixture_show_table")
  cmp "$case_dir/original.meta" "$MAIN_WALLET_DIR/savings.wallet.meta" || fail 'show rewrote saved wallet metadata'
  cmp "$case_dir/original.pk" "$MAIN_WALLET_DIR/savings.pk" || fail 'show changed an existing private key'
  cmp "$case_dir/original.boc" "$MAIN_WALLET_DIR/savings-query.boc" || fail 'show changed the deployment message'

  source "$kubeton"
  run_wallet() {
    [[ "$*" == 'show savings' ]] || fail "unexpected nested wallet operation: $*"
    printf '%s\n' "$fixture_show_table"
  }
  [[ "$(resolve_main_wallet_receive_address mainnet savings)" == "$fixture_main_receive" ]] \
    || fail 'collect rejected the mainnet wallet generated with legacy test-only friendly flags'
  if resolve_main_wallet_receive_address testnet savings >"$case_dir/mismatch" 2>&1; then
    fail 'address normalization bypassed the saved mainnet wallet guard'
  fi
  assert_contains 'saved for mainnet' "$case_dir/mismatch"
)

test_unchanged_local_commands
test_networkless_deploy
test_networkless_send_forms
test_send_requires_complete_inventory
test_send_requires_every_wallet_address
test_send_rejects_invalid_pod_addresses
test_invalid_no_bounce_positions
test_networkless_collect_forms
test_legacy_matching_network
test_network_mismatch_or_failure
test_global_config_classification
test_runtime_config_reader
test_fleet_config_detection
test_runtime_config_failures_prevent_transactions
test_main_wallet_transaction_network_guards
test_main_wallet_show_network_and_config
test_collect_receive_address_from_real_show_table
test_collect_mainnet_legacy_friendly_flags

echo "kubeton wallet network tests passed"
