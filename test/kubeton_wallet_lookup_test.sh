#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() {
  if ! grep -Fq -- "$1" "$2"; then
    fail "expected '$1' in $2"
  fi
}
assert_not_contains() {
  if grep -Fq -- "$1" "$2"; then
    fail "unexpected '$1' in $2"
  fi
}

# All fixtures are public account identities made from synthetic bytes. No
# private key files are created or read, and no real Kubernetes client is run.
python3 - "$test_dir" <<'PY'
import base64
import binascii
import json
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
expected = {}
for index, workchain in enumerate((-1, -1, 0, 1, -1)):
    account = bytes([0, 124, 10, 13, 255, index] + list(range(26)))
    pod = f"tonnode-{index}"
    directory = root / "fixtures" / pod
    directory.mkdir(parents=True)
    (directory / "validator_wallet_001.addr").write_bytes(account + struct.pack(">i", workchain))
    values = {"raw": f"{workchain}:{account.hex()}", "workchain": str(workchain)}
    for label, tag in (("mainnet", 0x51), ("testnet", 0xd1), ("bounceable", 0x11)):
        body = bytes([tag, workchain & 0xff]) + account
        values[label] = base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode()
    decoded = base64.urlsafe_b64decode(values["mainnet"])
    values["bad_crc"] = base64.urlsafe_b64encode(decoded[:-1] + bytes([decoded[-1] ^ 1])).decode()
    (directory / "wl.out").write_text(
        "Name Status Balance Ver Wch Address\n"
        f"validator_wallet_001 active {index + 20}.5 v3 {workchain} {values['mainnet']}\n"
    )
    expected[pod] = values
(root / "expected.json").write_text(json.dumps(expected))
PY

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/mytonctrl" <<'MOCK_MYTONCTRL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--cmd wl' ]] || exit 90
cat "$FIXTURE_POD_DIR/wl.out"
if [[ -f "$FIXTURE_POD_DIR/wl.rc" ]]; then
  exit "$(cat "$FIXTURE_POD_DIR/wl.rc")"
fi
MOCK_MYTONCTRL
chmod +x "$test_dir/bin/mytonctrl"

expected_value() {
  python3 - "$test_dir/expected.json" "$1" "$2" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())[sys.argv[2]][sys.argv[3]])
PY
}

setup_case() {
  source "$kubeton"
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir"
  cp -R "$test_dir/fixtures" "$case_dir/pods"
  mock_events="$case_dir/events"
  : >"$mock_events"
  inventory_mode=normal
  STATUS_EXEC_TIMEOUT=2s
  MYTONCTRL_EXEC_TIMEOUT=91s
  # These fixtures exercise the compatibility wl path; the dedicated Python
  # state-query tests cover the preferred targeted lite-client reader.
  read_tonnode_wallet_state_from_pod() { return 78; }
  # Static version metadata has its own JSON-only reader regression suite.
  read_tonnode_wallet_version_from_pod() { return 1; }
  run_with_timeout() {
    printf 'timeout %s\n' "$1" >>"$mock_events"
    shift
    "$@"
  }
  list_ton_pods() {
    printf 'inventory\n' >>"$mock_events"
    [[ "$inventory_mode" != empty ]] || return 0
    if [[ "$inventory_mode" == partial-failure ]]; then
      printf 'unit-ns\ttonnode-0\tworker-0\n'
      return 1
    fi
    local index
    for index in 0 1 2 3 4; do
      printf 'unit-ns\ttonnode-%s\tworker-%s\n' "$index" "$index"
    done
  }
  resolve_tonnode_pod_row_by_name() {
    if [[ "$1" =~ ^tonnode-([0-4])$ ]]; then
      printf 'unit-ns\t%s\tworker-%s\n' "$1" "${BASH_REMATCH[1]}"
    else
      return 1
    fi
  }
  kubectl() {
    if [[ "${1:-}" != -n || "${2:-}" != unit-ns || "${3:-}" != exec ||
          "${5:-}" != -c || "${6:-}" != ton-node || "${7:-}" != -- ||
          "${8:-}" != bash || ! "${4:-}" =~ ^tonnode-[0-4]$ ]]; then
      printf 'unexpected kubectl operation\n' >>"$mock_events"
      return 90
    fi
    local fixture_pod="$4" fixture_script="${10:-}"
    local fixture_directory="$case_dir/pods/$fixture_pod" operation fixture_rc=0
    [[ "${9:-}" == -c || "${9:-}" == -lc ]] || return 90
    if [[ "$fixture_script" == *'addr_file='* && "$fixture_script" != *'pk_file='* ]]; then
      operation=addr
      if [[ -f "$fixture_directory/addr.rc" ]]; then
        fixture_rc="$(cat "$fixture_directory/addr.rc")"
      fi
    elif [[ "$fixture_script" == *'mytonctrl --cmd wl'* && "$fixture_script" != *'pk_file='* ]]; then
      operation=wl
    else
      printf 'unexpected pod script\n' >>"$mock_events"
      return 90
    fi
    printf '%s %s\n' "$operation" "$fixture_pod" >>"$mock_events"
    shift 10
    fixture_script="${fixture_script//\/var\/ton-work\/controller\/mytoncore\/wallets/$fixture_directory}"
    PATH="$test_dir/bin:$PATH" FIXTURE_POD_DIR="$fixture_directory" \
      bash --noprofile --norc -c "$fixture_script" "$@" || return "$?"
    return "$fixture_rc"
  }
}

assert_balance_rows() {
  python3 - "$test_dir/expected.json" "$1" "${2:-}" "${3:-}" "${4:-}" <<'PY'
import json
import pathlib
import sys

expected = json.loads(pathlib.Path(sys.argv[1]).read_text())
unknown = set(filter(None, sys.argv[3].split(",")))
missing_address = set(filter(None, sys.argv[4].split(",")))
selection = set(filter(None, sys.argv[5].split(","))) or set(expected)
actual = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells[0] != "unit-ns":
        continue
    assert len(cells) == 8, ("malformed balance row", cells)
    namespace, pod, name, state, balance, version, workchain, address = cells
    assert pod not in actual, ("duplicate pod", pod)
    actual[pod] = cells
    assert name == "validator_wallet_001", (pod, "wallet name", name)
    if pod in unknown:
        assert (state, balance, version) == ("unknown", "unknown", "unknown"), (pod, cells)
    else:
        assert (state, balance, version) == ("active", f"{20 + int(pod[-1])}.5", "v3"), (pod, cells)
    if pod in missing_address:
        assert address == "unknown" and workchain == "unknown", (pod, cells)
    else:
        assert address == expected[pod]["mainnet"], (pod, "address", address)
        assert workchain == expected[pod]["workchain"], (pod, "workchain", workchain)
assert actual.keys() == selection, ("wallet set differs", sorted(actual), sorted(selection))
PY
}

test_nonbounce_address_encoding() (
  source "$kubeton"
  local index pod raw network actual expected
  for index in 0 1 2 3 4; do
    pod="tonnode-$index"
    raw="$(expected_value "$pod" raw)"
    for network in mainnet testnet; do
      actual="$(ton_address_to_non_bounceable "$raw" "$network")"
      expected="$(expected_value "$pod" "$network")"
      [[ "$actual" == "$expected" ]] || fail "incorrect $network friendly address for $pod"
      [[ "$(ton_address_to_hex "$actual")" == "$raw" ]] || fail "friendly conversion changed account/workchain"
    done
    [[ "$(ton_address_to_non_bounceable "$raw")" == "$(expected_value "$pod" mainnet)" ]] \
      || fail "default conversion must use mainnet"
  done
  local account
  account="$(printf '%064d' 0)"
  for raw in "-128:$account" "127:$account"; do
    actual="$(ton_address_to_non_bounceable "$raw")"
    [[ "$(ton_address_to_hex "$actual")" == "$raw" ]] || fail "signed-byte boundary conversion failed"
  done
  for raw in '' not-an-address "0:abc" "128:$account" "-129:$account"; do
    if ton_address_to_non_bounceable "$raw" >"$test_dir/invalid-address.out" 2>&1; then
      fail "converted malformed or unsupported raw address '$raw'"
    fi
  done
  if ton_address_to_non_bounceable "0:$account" unknown >"$test_dir/invalid-network.out" 2>&1; then
    fail "converted address with unknown network"
  fi
)

test_local_identity_bypasses_live_query() (
  setup_case local-identity
  local index pod actual network
  for index in 0 1 2 3 4; do
    pod="tonnode-$index"
    printf 124 >"$case_dir/pods/$pod/wl.rc"
    for network in mainnet testnet; do
      actual="$(resolve_tonnode_wallet_address_from_pod unit-ns "$pod" validator_wallet_001 "$network")"
      [[ "$actual" == "$(expected_value "$pod" "$network")" ]] || fail "local identity lookup failed for $pod"
    done
  done
  assert_contains 'addr tonnode-0' "$mock_events"
  assert_not_contains 'wl tonnode-' "$mock_events"
  assert_not_contains unexpected "$mock_events"
)

test_send_previews_all_five_local_identities() (
  setup_case send-local-identities
  MAIN_WALLET_TARGET_WALLET_NAME=validator_wallet_001
  resolve_wallet_fleet_config() {
    KUBETON_WALLET_NETWORK=mainnet
    KUBETON_WALLET_GLOBAL_CONFIG_JSON='{}'
  }
  # Stop at the preview confirmation. Nothing can create a helper pod or sign
  # a transfer, even if the command incorrectly continues after the preview.
  ensure_namespace() { fail "send preview tried to modify a namespace"; }
  should_bootstrap_baremetal() { return 1; }
  validate_external_key_prereqs() { fail "send preview continued past confirmation"; }
  confirm_or_exit() {
    printf 'confirmation %s\n' "$*" >>"$mock_events"
    exit 93
  }
  local index rc=0
  for index in 0 1 2 3 4; do
    printf 124 >"$case_dir/pods/tonnode-$index/wl.rc"
  done
  (run_wallet send main-wallet 10.) >"$case_dir/out" 2>"$case_dir/err" || rc=$?
  [[ "$rc" == 93 ]] || fail "send did not stop at the mocked preview confirmation (rc=$rc)"
  python3 - "$test_dir/expected.json" "$case_dir/out" <<'PY'
import json
import pathlib
import sys
expected = json.loads(pathlib.Path(sys.argv[1]).read_text())
actual = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells[0] != "unit-ns":
        continue
    assert len(cells) == 5, ("malformed send preview", cells)
    namespace, pod, name, address, amount = cells
    assert name == "validator_wallet_001", (pod, name)
    assert address == expected[pod]["mainnet"], (pod, address)
    assert amount == "2.000000000", (pod, "incorrect equal share", amount)
    assert pod not in actual, ("duplicate recipient", pod)
    actual[pod] = address
assert actual.keys() == expected.keys(), ("send recipient set differs", sorted(actual), sorted(expected))
PY
  assert_contains '(5 total)' "$mock_events"
  assert_not_contains 'wl tonnode-' "$mock_events"
  assert_not_contains unexpected "$mock_events"
)

test_legacy_address_file() (
  setup_case legacy-file
  head -c 32 "$case_dir/pods/tonnode-2/validator_wallet_001.addr" >"$case_dir/legacy.addr"
  mv "$case_dir/legacy.addr" "$case_dir/pods/tonnode-2/validator_wallet_001.addr"
  [[ "$(resolve_tonnode_wallet_address_from_pod unit-ns tonnode-2 validator_wallet_001)" == \
     "$(expected_value tonnode-2 mainnet)" ]] || fail "legacy 32-byte identity lookup failed"
  assert_not_contains 'wl tonnode-' "$mock_events"
)

test_wl_fallback() (
  setup_case wl-fallback
  rm "$case_dir/pods/tonnode-1/validator_wallet_001.addr"
  [[ "$(resolve_tonnode_wallet_address_from_pod unit-ns tonnode-1 validator_wallet_001)" == \
     "$(expected_value tonnode-1 mainnet)" ]] || fail "valid wl fallback did not resolve"
  assert_contains 'wl tonnode-1' "$mock_events"
  assert_contains 'timeout 91s' "$mock_events"
)

test_targeted_state_takes_precedence_over_wl() (
  setup_case preferred-state
  read_tonnode_wallet_state_from_pod() {
    [[ "$1" == unit-ns && "$2" == tonnode-2 && "$3" == validator_wallet_001 ]] \
      || fail "targeted query received the wrong wallet"
    [[ "$4" == "$(expected_value tonnode-2 raw)" ]] || fail "query received the wrong public account"
    printf 'state %s\n' "$2" >>"$mock_events"
    printf '%s\tactive\t7.500000000\tv1\t0\t%s\n' "$3" "$(expected_value tonnode-2 mainnet)"
  }
  local actual
  actual="$(resolve_tonnode_wallet_row_from_pod unit-ns tonnode-2 validator_wallet_001)"
  [[ "$actual" == $'validator_wallet_001\tactive\t7.500000000\tv1\t0\t'"$(expected_value tonnode-2 mainnet)" ]] \
    || fail "targeted account state was replaced by wl data"
  assert_contains 'state tonnode-2' "$mock_events"
  assert_not_contains 'wl tonnode-' "$mock_events"
)

test_targeted_rpc_failure_never_falls_back_to_wl() (
  setup_case targeted-rpc-failure
  read_tonnode_wallet_state_from_pod() {
    # Failed transport may contain valid-looking partial stdout. The caller
    # must discard it and must not trust wl's inferred account state instead.
    printf '%s\tempty\t0.000000000\tv1\t0\t%s\n' "$3" "$(expected_value tonnode-2 mainnet)"
    return 1
  }
  if resolve_tonnode_wallet_row_from_pod unit-ns tonnode-2 validator_wallet_001 \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "targeted RPC failure fell back to successful wl output"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "failed targeted query leaked a wallet row"
  assert_not_contains 'wl tonnode-' "$mock_events"
)

test_targeted_missing_interpreter_allows_wl_compatibility() (
  setup_case missing-interpreter
  read_tonnode_wallet_state_from_pod() { return 127; }
  local actual
  actual="$(resolve_tonnode_wallet_row_from_pod unit-ns tonnode-2 validator_wallet_001)"
  [[ "$actual" == $'validator_wallet_001\tactive\t22.5\tv3\t0\t'"$(expected_value tonnode-2 mainnet)" ]] \
    || fail "missing targeted-query prerequisite did not allow wl compatibility"
  assert_contains 'wl tonnode-2' "$mock_events"
)

test_confirmed_empty_balances_show_all_five_wallets() (
  setup_case confirmed-empty-balances
  read_tonnode_wallet_state_from_pod() {
    printf 'state %s\n' "$2" >>"$mock_events"
    printf '%s\tempty\t0.000000000\tv1\t%s\t%s\n' "$3" "${4%%:*}" \
      "$(ton_address_to_non_bounceable "$4")"
  }
  run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"
  python3 - "$test_dir/expected.json" "$case_dir/out" <<'PY'
import json
import pathlib
import sys
expected = json.loads(pathlib.Path(sys.argv[1]).read_text())
actual = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells[0] != "unit-ns":
        continue
    assert len(cells) == 8, ("malformed balance row", cells)
    namespace, pod, name, state, balance, version, workchain, address = cells
    assert [state, balance, version] == ["empty", "0.000000000", "v1"], (pod, cells)
    assert address == expected[pod]["mainnet"], (pod, address)
    assert workchain == expected[pod]["workchain"], (pod, workchain)
    actual[pod] = address
assert actual.keys() == expected.keys(), ("empty wallet set differs", sorted(actual), sorted(expected))
PY
  [[ ! -s "$case_dir/err" ]] || fail "confirmed empty balance lookup emitted a warning"
  assert_not_contains 'wl tonnode-' "$mock_events"
)

test_invalid_wl_fallback() (
  setup_case invalid-wl
  rm "$case_dir/pods/tonnode-1/validator_wallet_001.addr"
  local address
  for address in "$(expected_value tonnode-1 bad_crc)" not-a-TON-address "$(expected_value tonnode-1 testnet)"; do
    printf 'validator_wallet_001 active 21.5 v3 -1 %s\n' "$address" >"$case_dir/pods/tonnode-1/wl.out"
    if resolve_tonnode_wallet_address_from_pod unit-ns tonnode-1 validator_wallet_001 mainnet \
      >"$case_dir/out" 2>"$case_dir/err"; then
      fail "accepted malformed or test-only mainnet fallback address '$address'"
    fi
  done
)

test_failed_queries_discard_partial_stdout() (
  setup_case failed-query
  printf 124 >"$case_dir/pods/tonnode-1/wl.rc"
  if resolve_tonnode_wallet_row_from_pod unit-ns tonnode-1 validator_wallet_001 \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted valid-looking row from a timed-out query"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "failed query leaked partial balance row"
  assert_contains 'timeout 91s' "$mock_events"
  rm "$case_dir/pods/tonnode-1/validator_wallet_001.addr"
  if resolve_tonnode_wallet_address_from_pod unit-ns tonnode-1 validator_wallet_001 \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted fallback identity from failed live query"
  fi
)

test_failed_file_reads_discard_partial_stdout() (
  setup_case failed-file
  printf 124 >"$case_dir/pods/tonnode-1/addr.rc"
  if read_tonnode_wallet_address_file_from_pod unit-ns tonnode-1 validator_wallet_001 \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted valid-looking identity bytes from failed file read"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "failed file read leaked partial identity"
  [[ "$(resolve_tonnode_wallet_address_from_pod unit-ns tonnode-1 validator_wallet_001)" == \
     "$(expected_value tonnode-1 mainnet)" ]] || fail "failed file read did not allow valid wl fallback"
  assert_contains 'wl tonnode-1' "$mock_events"
  printf 124 >"$case_dir/pods/tonnode-1/wl.rc"
  if resolve_tonnode_wallet_address_from_pod unit-ns tonnode-1 validator_wallet_001 \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted wallet despite both identity sources failing"
  fi
)

test_balances_keep_all_five_wallets() (
  setup_case partial-balances
  printf 124 >"$case_dir/pods/tonnode-1/wl.rc"
  printf 1 >"$case_dir/pods/tonnode-2/wl.rc"
  : >"$case_dir/pods/tonnode-3/wl.out"
  run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"
  assert_balance_rows "$case_dir/out" tonnode-1,tonnode-2,tonnode-3
  assert_contains tonnode-1 "$case_dir/err"
  assert_contains tonnode-2 "$case_dir/err"
  assert_contains tonnode-3 "$case_dir/err"
  assert_not_contains skipping "$case_dir/err"
  assert_not_contains unexpected "$mock_events"
  [[ "$(grep -c '^wl ' "$mock_events")" == 5 ]] || fail "balance fallback repeated expensive live queries"
)

test_balances_keep_unknown_identity_row() (
  setup_case unknown-identity
  rm "$case_dir/pods/tonnode-2/validator_wallet_001.addr"
  : >"$case_dir/pods/tonnode-2/wl.out"
  run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"
  assert_balance_rows "$case_dir/out" tonnode-2 tonnode-2
  assert_contains tonnode-2 "$case_dir/err"
)

test_successful_balances_are_unchanged() (
  setup_case successful-balances
  run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"
  assert_balance_rows "$case_dir/out"
  [[ ! -s "$case_dir/err" ]] || fail "successful balance lookup emitted warning"
  assert_not_contains unexpected "$mock_events"
)

test_selected_pod_keeps_unknown_balance() (
  setup_case selected-balance
  printf 124 >"$case_dir/pods/tonnode-3/wl.rc"
  run_wallet_balance_show tonnode-3 >"$case_dir/out" 2>"$case_dir/err"
  assert_balance_rows "$case_dir/out" tonnode-3 '' tonnode-3
  assert_not_contains 'wl tonnode-0' "$mock_events"
  assert_not_contains 'wl tonnode-4' "$mock_events"
)

test_failed_inventory_discards_partial_stdout() (
  setup_case failed-inventory
  inventory_mode=partial-failure
  if run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted partial pod inventory after failed kubectl"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "displayed balances from partial pod inventory"
  [[ -s "$case_dir/err" ]] || fail "failed inventory had no diagnostic"
  assert_not_contains 'wl tonnode-' "$mock_events"
  assert_not_contains 'addr tonnode-' "$mock_events"
)

test_empty_inventory_fails() (
  setup_case empty-inventory
  inventory_mode=empty
  if run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted empty pod inventory"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "empty inventory produced a balance table"
  [[ -s "$case_dir/err" ]] || fail "empty inventory had no diagnostic"
)

test_invalid_wallet_name_fails_before_exec() (
  setup_case invalid-name
  if run_wallet_balance_show '' '../another-wallet' >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted invalid wallet name for balance lookup"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "invalid wallet name produced a balance table"
  assert_not_contains 'wl tonnode-' "$mock_events"
  assert_not_contains 'addr tonnode-' "$mock_events"
  if resolve_tonnode_wallet_address_from_pod unit-ns tonnode-0 '../another-wallet' \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted invalid wallet name for identity lookup"
  fi
  assert_not_contains 'wl tonnode-' "$mock_events"
  assert_not_contains unexpected "$mock_events"
)

tests=(
  test_nonbounce_address_encoding
  test_local_identity_bypasses_live_query
  test_send_previews_all_five_local_identities
  test_legacy_address_file
  test_wl_fallback
  test_targeted_state_takes_precedence_over_wl
  test_targeted_rpc_failure_never_falls_back_to_wl
  test_targeted_missing_interpreter_allows_wl_compatibility
  test_confirmed_empty_balances_show_all_five_wallets
  test_invalid_wl_fallback
  test_failed_queries_discard_partial_stdout
  test_failed_file_reads_discard_partial_stdout
  test_balances_keep_all_five_wallets
  test_balances_keep_unknown_identity_row
  test_successful_balances_are_unchanged
  test_selected_pod_keeps_unknown_balance
  test_failed_inventory_discards_partial_stdout
  test_empty_inventory_fails
  test_invalid_wallet_name_fails_before_exec
)
for test_case in "${tests[@]}"; do
  "$test_case"
done
printf 'kubeton wallet lookup tests passed (%s cases)\n' "${#tests[@]}"
