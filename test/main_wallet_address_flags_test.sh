#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

# Synthetic account and private-key bytes only. Python's CRC implementation is
# an independent reference for the Bash encoder's network and bounce flags.
python3 - "$test_dir" <<'PY'
import base64
import binascii
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
account = bytes(range(32))
(root / "account.addr").write_bytes(account + struct.pack(">i", 0))
(root / "account.pk").write_bytes(bytes([0x42]) * 32)
rows = []
for workchain in (0, -1):
    for network in ("mainnet", "testnet"):
        for bounceable in (False, True):
            tag = (0x11 if bounceable else 0x51) | (0x80 if network == "testnet" else 0)
            body = bytes([tag, workchain & 0xff]) + account
            address = base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode()
            rows.append(f"{workchain}\t{network}\t{int(bounceable)}\t{address}\t{workchain}:{account.hex()}")
(root / "addresses.tsv").write_text("\n".join(rows) + "\n")
body = bytes([0xd1, 0]) + bytes([0x77]) * 32
(root / "other-address").write_text(base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode())
PY

fixture_address() {
  awk -F'\t' -v wc="$1" -v network="$2" -v bounceable="$3" \
    '$1 == wc && $2 == network && $3 == bounceable {print $4; exit}' "$test_dir/addresses.tsv"
}

setup_case() {
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$test_dir/$1"
  mkdir -p "$MAIN_WALLET_DIR"
  cp "$test_dir/account.addr" "$MAIN_WALLET_DIR/savings.addr"
  cp "$test_dir/account.pk" "$MAIN_WALLET_DIR/savings.pk"
  fixture_raw="$(wallet_address_file_to_hex "$MAIN_WALLET_DIR/savings.addr")"
  fixture_non_main="$(fixture_address 0 mainnet 0)"
  fixture_bounce_main="$(fixture_address 0 mainnet 1)"
  fixture_non_test="$(fixture_address 0 testnet 0)"
  fixture_bounce_test="$(fixture_address 0 testnet 1)"
  printf 'wallet_name=savings\nworkchain=0\nwallet_id=42\nnetwork=mainnet\nwallet_address=%s\nnon_bounceable=%s\nbounceable=%s\n' \
    "$fixture_raw" "$fixture_non_test" "$fixture_bounce_test" >"$MAIN_WALLET_DIR/savings.wallet.meta"
  WALLET_NETWORK=mainnet
}

test_encoder_preserves_account_and_bounce() (
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  local wc network bounceable address raw target expected actual
  while IFS=$'\t' read -r wc network bounceable address raw; do
    for target in mainnet testnet; do
      expected="$(fixture_address "$wc" "$target" "$bounceable")"
      actual="$(ton_friendly_address_for_network "$address" "$target")"
      [[ "$actual" == "$expected" ]] || fail "incorrect network conversion of $network/$wc/$bounceable to $target"
      [[ "$(ton_address_to_hex "$actual")" == "$raw" ]] || fail "network conversion changed the account"
    done
  done <"$test_dir/addresses.tsv"
  address="$(fixture_address 0 testnet 0)"
  if ton_friendly_address_for_network "$address" unknown >/dev/null; then
    fail "converted an address without a known network"
  fi
  if ton_friendly_address_for_network "${address:0:47}A" mainnet >/dev/null; then
    fail "repaired an invalid checksum"
  fi
  if ton_friendly_address_for_network "0:$(printf '%064d' 0)" mainnet >/dev/null; then
    fail "treated a raw account as validated friendly metadata"
  fi
)

test_show_repairs_legacy_flags_without_writes() (
  setup_case legacy-show
  cp "$MAIN_WALLET_DIR/savings.wallet.meta" "$test_dir/metadata-before"
  wallet_show_chain_state() { printf '0\t0'; }
  main_wallet_show savings >"$MAIN_WALLET_DIR/show.out"
  assert_contains "$fixture_non_main" "$MAIN_WALLET_DIR/show.out"
  assert_contains "$fixture_bounce_main" "$MAIN_WALLET_DIR/show.out"
  assert_not_contains "$fixture_non_test" "$MAIN_WALLET_DIR/show.out"
  assert_contains "$fixture_raw" "$MAIN_WALLET_DIR/show.out"
  cmp "$test_dir/metadata-before" "$MAIN_WALLET_DIR/savings.wallet.meta" || fail "show changed saved metadata"
  cmp "$test_dir/account.addr" "$MAIN_WALLET_DIR/savings.addr" || fail "show changed account identity"
  cmp "$test_dir/account.pk" "$MAIN_WALLET_DIR/savings.pk" || fail "show changed private-key bytes"

  # Without saved network metadata, only the active fleet decides the flags.
  sed -i '/^network=/d' "$MAIN_WALLET_DIR/savings.wallet.meta"
  main_wallet_show savings >"$MAIN_WALLET_DIR/active-network.out"
  assert_contains "$fixture_non_main" "$MAIN_WALLET_DIR/active-network.out"
  WALLET_NETWORK=testnet
  main_wallet_show savings >"$MAIN_WALLET_DIR/testnet.out"
  assert_contains "$fixture_non_test" "$MAIN_WALLET_DIR/testnet.out"
  assert_contains "$fixture_bounce_test" "$MAIN_WALLET_DIR/testnet.out"
)

test_show_preserves_saved_wallet_version_offline() (
  setup_case version-show
  printf 'wallet_version=v3\n' >>"$MAIN_WALLET_DIR/savings.wallet.meta"
  cp "$MAIN_WALLET_DIR/savings.wallet.meta" "$MAIN_WALLET_DIR/before.meta"
  wallet_show_chain_state() { printf 'unknown\tunknown'; }
  main_wallet_show savings >"$MAIN_WALLET_DIR/show.out"
  awk 'NR == 1 {for (i=1; i<=NF; i++) column[$i]=i; next}
    $(column["wallet-name"]) == "savings" {
      if (!column["wallet-version"] || $(column["wallet-version"]) != "v3") exit 1
      if ($(column["balance"]) != "unknown" || $(column["seqno"]) != "unknown") exit 1
      found=1
    } END {if (!found) exit 1}' "$MAIN_WALLET_DIR/show.out" \
      || fail 'wallet show lost the known local version when live state was unavailable'
  cmp "$MAIN_WALLET_DIR/before.meta" "$MAIN_WALLET_DIR/savings.wallet.meta" \
    || fail 'wallet show changed saved version metadata'
)

test_other_account_metadata_is_not_repaired() (
  setup_case stale-show
  local other
  other="$(cat "$test_dir/other-address")"
  sed -i "s/^non_bounceable=.*/non_bounceable=$other/; s/^bounceable=.*/bounceable=$other/" "$MAIN_WALLET_DIR/savings.wallet.meta"
  wallet_show_chain_state() { printf '0\t0'; }
  main_wallet_show savings >"$MAIN_WALLET_DIR/show.out"
  assert_not_contains "$other" "$MAIN_WALLET_DIR/show.out"
  assert_contains "$fixture_raw" "$MAIN_WALLET_DIR/show.out"
  awk 'NR == 1 {for (i=1; i<=NF; i++) column[$i]=i; next}
    $(column["wallet-name"]) == "savings" {
      if ($(column["non-bounceable"]) != "unknown" || $(column["bounceable"]) != "unknown") exit 1
      found=1
    } END {if (!found) exit 1}' \
    "$MAIN_WALLET_DIR/show.out" || fail "stale metadata gained usable friendly addresses"
)

test_saved_network_guard_is_preserved() (
  setup_case saved-network
  WALLET_NETWORK=testnet
  wallet_balance_nano() { fail "queried mismatched network"; }
  wallet_seqno_decimal() { fail "queried mismatched network"; }
  main_wallet_show savings >"$MAIN_WALLET_DIR/show.out" 2>"$MAIN_WALLET_DIR/show.err"
  assert_contains "$fixture_non_main" "$MAIN_WALLET_DIR/show.out"
  assert_contains 'saved for mainnet' "$MAIN_WALLET_DIR/show.err"
  if require_wallet_network_match savings >"$MAIN_WALLET_DIR/guard.out" 2>&1; then
    fail "normalization bypassed a saved-network mismatch"
  fi
  assert_contains 'saved for mainnet' "$MAIN_WALLET_DIR/guard.out"
  [[ "$(read_meta_value network "$MAIN_WALLET_DIR/savings.wallet.meta")" == mainnet ]] || fail "normalization relabeled saved network"
)

test_deployment_hints_use_matching_network_forms() (
  setup_case deployment-hints
  print_wallet_deploy_failure_hint savings 2>"$MAIN_WALLET_DIR/hints.out"
  assert_contains "$fixture_non_main" "$MAIN_WALLET_DIR/hints.out"
  assert_contains "$fixture_bounce_main" "$MAIN_WALLET_DIR/hints.out"
  assert_not_contains "$fixture_non_test" "$MAIN_WALLET_DIR/hints.out"
  local other
  other="$(cat "$test_dir/other-address")"
  sed -i "s/^non_bounceable=.*/non_bounceable=$other/; s/^bounceable=.*/bounceable=$other/" "$MAIN_WALLET_DIR/savings.wallet.meta"
  print_wallet_deploy_failure_hint savings 2>"$MAIN_WALLET_DIR/stale-hints.out"
  assert_not_contains "$other" "$MAIN_WALLET_DIR/stale-hints.out"
  assert_contains "$fixture_raw" "$MAIN_WALLET_DIR/stale-hints.out"
)

test_create_prints_and_saves_active_network() (
  setup_case create
  printf 'synthetic Fift fixture\n' >"$MAIN_WALLET_DIR/source-wallet.fif"
  cat >"$MAIN_WALLET_DIR/fake-fift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
wallet_name="${@: -1}"
cp "$FAKE_FIFT_FIXTURES/account.addr" "$wallet_name.addr"
[[ -f "$wallet_name.pk" ]] || cp "$FAKE_FIFT_FIXTURES/account.pk" "$wallet_name.pk"
printf 'new wallet address = %s\nNon-bounceable address (for init): %s\nBounceable address (for later access): %s\n' \
  "$FAKE_FIFT_RAW" "$FAKE_FIFT_NON" "$FAKE_FIFT_BOUNCE"
SH
  chmod +x "$MAIN_WALLET_DIR/fake-fift"
  resolve_new_wallet_fif() { printf '%s/source-wallet.fif' "$MAIN_WALLET_DIR"; }
  resolve_fift_bin() { printf '%s/fake-fift' "$MAIN_WALLET_DIR"; }
  export FAKE_FIFT_FIXTURES="$test_dir" FAKE_FIFT_RAW="$fixture_raw"
  export FAKE_FIFT_NON="$fixture_non_test" FAKE_FIFT_BOUNCE="$fixture_bounce_test"
  main_wallet_create 0 42 savings >"$MAIN_WALLET_DIR/create.out"
  assert_contains "$fixture_non_main" "$MAIN_WALLET_DIR/create.out"
  assert_contains "$fixture_bounce_main" "$MAIN_WALLET_DIR/create.out"
  assert_not_contains "$fixture_non_test" "$MAIN_WALLET_DIR/create.out"
  [[ "$(read_meta_value non_bounceable "$MAIN_WALLET_DIR/savings.wallet.meta")" == "$fixture_non_main" ]] || fail "create saved test-only mainnet metadata"
  [[ "$(read_meta_value wallet_id "$MAIN_WALLET_DIR/savings.wallet.meta")" == 42 ]] || fail "create changed subwallet ID"
  [[ "$(read_meta_value wallet_version "$MAIN_WALLET_DIR/savings.wallet.meta")" == v3 ]] || fail "create did not save its Fift wallet version"
  cmp "$test_dir/account.addr" "$MAIN_WALLET_DIR/savings.addr" || fail "create changed raw account bytes"
  cmp "$test_dir/account.pk" "$MAIN_WALLET_DIR/savings.pk" || fail "create changed existing private-key bytes"
  WALLET_NETWORK=testnet
  main_wallet_create 0 42 test-wallet >"$MAIN_WALLET_DIR/test-create.out"
  assert_contains "$fixture_non_test" "$MAIN_WALLET_DIR/test-create.out"
  [[ "$(read_meta_value network "$MAIN_WALLET_DIR/test-wallet.wallet.meta")" == testnet ]] || fail "create did not retain testnet"
)

test_encoder_preserves_account_and_bounce
test_show_repairs_legacy_flags_without_writes
test_show_preserves_saved_wallet_version_offline
test_other_account_metadata_is_not_repaired
test_saved_network_guard_is_preserved
test_deployment_hints_use_matching_network_forms
test_create_prints_and_saves_active_network
echo "main wallet address flag tests passed"
