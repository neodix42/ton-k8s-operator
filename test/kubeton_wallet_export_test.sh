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

# All account hashes and key bytes below are synthetic test data. Fift stores
# .addr as a 32-byte account hash followed by a signed, big-endian int32
# workchain; the historical 32-byte form implies workchain zero.
python3 - "$test_dir" <<'PY'
import base64
import binascii
import json
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
hashes = {
    "binary_zero": bytes([0, 124, 65, 10, 13, 9, 255, 128] + list(range(24))),
    "binary_minus_one": bytes(range(32)),
    "binary_plus_one": bytes(reversed(range(32))),
    "binary_printable": b"|ABCDEFGHIJKLMNOPQRSTUVWXYZ01234",
    "binary_legacy": bytes([0, 124, 65, 255] * 8),
    "text_raw": bytes([17] * 32),
    "text_friendly": bytes([34] * 32),
    "wl_text": bytes([51] * 32),
    "stale_wl": bytes([102] * 32),
    "wl_missing_file": bytes([136] * 32),
    "bad_crc": bytes([68] * 32),
    "bad_tag": bytes([85] * 32),
    "binary_second_pod": bytes([0, 124, 65, 10] * 8),
}
for tag in (0x11, 0x51, 0x91, 0xd1):
    for wc in (0, -1):
        hashes[f"wl_tag_{tag:02x}_{'minus1' if wc == -1 else 'zero'}"] = bytes([tag] * 32)
assert all(len(value) == 32 for value in hashes.values())

def raw_address(account, wc):
    return f"{wc}:{account.hex()}"

def friendly_address(account, wc, tag=0x51):
    body = bytes([tag, wc & 0xff]) + account
    checksum = binascii.crc_hqx(body, 0).to_bytes(2, "big")
    return base64.urlsafe_b64encode(body + checksum).decode()

expected = {}
for index, (name, account) in enumerate(hashes.items()):
    pod = "tonnode-1" if name == "binary_second_pod" else "tonnode-0"
    directory = root / "pods" / pod
    directory.mkdir(parents=True, exist_ok=True)
    wc = -1 if name in ("binary_minus_one", "binary_printable", "binary_second_pod") else 0
    if name == "binary_plus_one":
        wc = 1
    if name.startswith("wl_tag_"):
        wc = -1 if name.endswith("minus1") else 0
    raw = raw_address(account, wc)
    display = raw
    key = bytes([index + 1] * 32)
    (directory / f"{name}.pk").write_bytes(key)
    if name == "text_raw":
        (directory / f"{name}.addr").write_text(raw + "\r\n")
    elif name == "text_friendly":
        display = friendly_address(account, wc)
        (directory / f"{name}.addr").write_text(display + "\n")
    elif name == "wl_text":
        display = friendly_address(account, wc)
        (directory / f"{name}.addr").write_bytes(account + struct.pack(">i", wc))
    elif name == "wl_missing_file":
        display = friendly_address(account, wc)
    elif name.startswith("wl_tag_"):
        display = friendly_address(account, wc, int(name.split("_")[2], 16))
        (directory / f"{name}.addr").write_bytes(account + struct.pack(">i", wc))
    elif name == "binary_legacy":
        (directory / f"{name}.addr").write_bytes(account)
    else:
        (directory / f"{name}.addr").write_bytes(account + struct.pack(">i", wc))
    expected[f"{pod}/{name}"] = {"address": display, "hex": raw, "key": key.hex()}
    if name == "text_friendly":
        expected[f"{pod}/{name}"]["pod_address"] = raw

header = "Name Status Balance Ver Wch Address\n"
pod_zero_lines = [header]
for name in hashes:
    if name == "binary_second_pod":
        continue
    if name == "stale_wl":
        # A valid wl address for a different account must not override .addr.
        address = friendly_address(bytes([119] * 32), 0)
    elif name.startswith("wl_"):
        address = expected[f"tonnode-0/{name}"]["address"]
    elif name == "bad_crc":
        body = base64.urlsafe_b64decode(friendly_address(hashes[name], 0))
        address = base64.urlsafe_b64encode(body[:-1] + bytes([body[-1] ^ 1])).decode()
        (root / "bad-crc.txt").write_text(address)
    elif name == "bad_tag":
        address = friendly_address(hashes[name], 0, 0x01)
        (root / "bad-tag.txt").write_text(address)
    else:
        # Nonempty garbage formerly suppressed the valid .addr fallback.
        address = "|not-a-TON-address|"
    pod_zero_lines.append(f"{name} active 4.25 v3 0 {address}\n")
(root / "pods/tonnode-0/wl.txt").write_text("".join(pod_zero_lines))
(root / "pods/tonnode-1/wl.txt").write_text(header)
(root / "expected.json").write_text(json.dumps(expected))

# Explicitly malformed files have neither the binary length nor a text address.
(root / "invalid-short.addr").write_bytes(b"invalid|\x00\xff")
(root / "invalid-long.addr").write_bytes(b"x" * 37)
PY

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/mytonctrl" <<'MOCK_MYTONCTRL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--cmd wl' ]] || exit 90
cat "$FAKE_WL_FILE"
MOCK_MYTONCTRL
chmod +x "$test_dir/bin/mytonctrl"

setup_pod_mock() {
  source "$kubeton"
  mock_events="$test_dir/$1.events"
  : >"$mock_events"
  run_with_timeout() { shift; "$@"; }
  confirm_or_exit() { printf 'confirm\n' >>"$mock_events"; }
  list_ton_pods() {
    printf 'test-ns\ttonnode-0\tworker-0\ntest-ns\ttonnode-1\tworker-1\n'
  }
  resolve_tonnode_pod_row_by_name() {
    case "$1" in
      tonnode-0) printf 'test-ns\ttonnode-0\tworker-0\n' ;;
      tonnode-1) printf 'test-ns\ttonnode-1\tworker-1\n' ;;
      *) return 1 ;;
    esac
  }
  kubectl() {
    # Run only the production read scripts against a temporary fixture tree.
    # Never invoke the real kubectl executable or access actual pod files.
    [[ "${1:-}" == -n && "${2:-}" == test-ns && "${3:-}" == exec ]] \
      || fail "unexpected kubectl operation: $*"
    local fixture_pod="$4"
    [[ "$fixture_pod" == tonnode-0 || "$fixture_pod" == tonnode-1 ]] \
      || fail "unexpected fixture pod: $fixture_pod"
    [[ "${5:-}" == -c && "${6:-}" == ton-node && "${7:-}" == -- && "${8:-}" == bash ]] \
      || fail "unexpected kubectl exec contract: $*"
    [[ "${9:-}" == -c || "${9:-}" == -lc ]] \
      || fail "unexpected pod interpreter flags: ${9:-}"
    local fixture_script="${10}" fixture_directory="$test_dir/pods/$fixture_pod"
    shift 10
    fixture_script="${fixture_script//\/var\/ton-work\/controller\/mytoncore\/wallets/$fixture_directory}"
    printf 'exec %s\n' "$fixture_pod" >>"$mock_events"
    PATH="$test_dir/bin:$PATH" FAKE_WL_FILE="$fixture_directory/wl.txt" \
      bash --noprofile --norc -c "$fixture_script" "$@"
  }
}

assert_pod_export_table() {
  python3 - "$test_dir/expected.json" "$1" "${2:-}" <<'PY'
import json
import pathlib
import sys

expected = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {key: {"address": value.get("pod_address", value["address"]),
                  "hex": value["hex"], "key": value["key"]}
            for key, value in expected.items()}
selected = sys.argv[3]
if selected:
    expected = {key: value for key, value in expected.items() if key == selected}
actual = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if not cells or cells[0] != "test-ns":
        continue
    assert len(cells) == 6, ("malformed export row", cells[1:3], "column count", len(cells))
    namespace, pod, name, address, raw, key = cells
    actual[f"{pod}/{name}"] = {"address": address, "hex": raw, "key": key}
assert actual.keys() == expected.keys(), ("exported wallet set differs", sorted(actual), sorted(expected))
for name, row in expected.items():
    for field, value in row.items():
        assert actual[name][field] == value, (name, field, "value differs")
PY
}

test_export_all_pods() (
  setup_pod_mock export-all
  run_wallet export >"$test_dir/export-all.out" 2>"$test_dir/export-all.err"
  assert_pod_export_table "$test_dir/export-all.out"
  assert_contains 'exec tonnode-0' "$mock_events"
  assert_contains 'exec tonnode-1' "$mock_events"
  assert_contains 'confirm' "$mock_events"
  assert_not_contains '|not-a-TON-address|' "$test_dir/export-all.out"
  assert_not_contains unknown "$test_dir/export-all.out"
)

test_export_selected_wallets() (
  setup_pod_mock export-selected
  local wallet
  for wallet in binary_zero binary_minus_one binary_plus_one binary_printable binary_legacy text_raw text_friendly wl_text stale_wl wl_missing_file bad_crc bad_tag; do
    run_wallet export tonnode-0 "$wallet" >"$test_dir/selected-$wallet.out" 2>"$test_dir/selected-$wallet.err"
    assert_pod_export_table "$test_dir/selected-$wallet.out" "tonnode-0/$wallet"
  done
  assert_not_contains 'exec tonnode-1' "$mock_events"
)

test_main_wallet_file_decoder() (
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  local wallet actual expected
  for wallet in binary_zero binary_minus_one binary_plus_one binary_printable binary_legacy text_raw text_friendly; do
    actual="$(wallet_address_file_to_hex "$test_dir/pods/tonnode-0/$wallet.addr")"
    expected="$(python3 - "$test_dir/expected.json" "$wallet" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())[f"tonnode-0/{sys.argv[2]}"]["hex"])
PY
)"
    [[ "$actual" == "$expected" ]] || fail "helper decoded $wallet as $actual, expected $expected"
  done
  for fixture in "$test_dir/invalid-short.addr" "$test_dir/invalid-long.addr" "$test_dir/missing.addr"; do
    if wallet_address_file_to_hex "$fixture" >"$test_dir/invalid-decode.out" 2>&1; then
      fail "helper accepted malformed/missing address file $fixture"
    fi
  done
  for fixture in "$test_dir/bad-crc.txt" "$test_dir/bad-tag.txt"; do
    if wallet_address_file_to_hex "$fixture" >"$test_dir/invalid-friendly.out" 2>&1; then
      fail "helper accepted a friendly address with invalid CRC/tag"
    fi
  done
)

test_friendly_address_validation() (
  local source_file fixture_friendly fixture_raw actual
  for source_file in "$kubeton" "$repo_root/charts/ton-k8s-operator/main-wallet.sh"; do
    source "$source_file"
    while IFS=$'\t' read -r fixture_friendly fixture_raw; do
      actual="$(ton_address_to_hex "$fixture_friendly")"
      [[ "$actual" == "$fixture_raw" ]] || fail "friendly tag/workchain decoding failed in $source_file"
    done < <(python3 - "$test_dir/expected.json" <<'PY'
import json
import pathlib
import sys
for name, value in json.loads(pathlib.Path(sys.argv[1]).read_text()).items():
    if name.startswith("tonnode-0/wl_tag_"):
        print(value["address"] + "\t" + value["hex"])
PY
)
    for fixture in "$test_dir/bad-crc.txt" "$test_dir/bad-tag.txt"; do
      if ton_address_to_hex "$(cat "$fixture")" >"$test_dir/invalid-friendly.out" 2>&1; then
        fail "accepted invalid friendly CRC/tag in $source_file"
      fi
    done
  done
)

assert_main_wallet_export_table() {
  python3 - "$test_dir/expected.json" "$1" "$2" <<'PY'
import json
import pathlib
import sys

expected = json.loads(pathlib.Path(sys.argv[1]).read_text())[f"tonnode-0/{sys.argv[3]}"]
rows = [line.split() for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
rows = [row for row in rows if row and row[0] == sys.argv[3]]
assert len(rows) == 1, ("helper export row count", len(rows))
assert len(rows[0]) == 5, "malformed helper export row"
for field, value, actual in zip(
    ("name", "subwallet-id", "address", "hex", "key"),
    (sys.argv[3], "42", expected["address"], expected["hex"], expected["key"]),
    rows[0],
):
    assert actual == value, (sys.argv[3], field, "value differs")
PY
}

test_main_wallet_export_files() (
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$test_dir/pods/tonnode-0"
  local wallet
  for wallet in binary_zero binary_minus_one binary_plus_one binary_printable binary_legacy text_raw text_friendly; do
    main_wallet_export "$wallet" >"$test_dir/helper-$wallet.out"
    assert_main_wallet_export_table "$test_dir/helper-$wallet.out" "$wallet"
  done

  # A malformed file must not win over a valid, previously recorded address.
  cp "$test_dir/invalid-short.addr" "$MAIN_WALLET_DIR/metadata_fallback.addr"
  printf 'synthetic key' >"$MAIN_WALLET_DIR/metadata_fallback.pk"
  fallback_address="0:$(printf '%064d' 42)"
  printf 'wallet_address=%s\nwallet_id=42\n' "$fallback_address" \
    >"$MAIN_WALLET_DIR/metadata_fallback.wallet.meta"
  main_wallet_export metadata_fallback >"$test_dir/helper-metadata.out"
  assert_contains "$fallback_address" "$test_dir/helper-metadata.out"
  assert_not_contains 'invalid|' "$test_dir/helper-metadata.out"
)

test_show_and_collect_ignore_stale_metadata() (
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$test_dir/pods/tonnode-0"
  WALLET_NETWORK=""
  cp "$MAIN_WALLET_DIR/binary_zero.addr" "$MAIN_WALLET_DIR/stale_show.addr"
  cp "$MAIN_WALLET_DIR/binary_zero.pk" "$MAIN_WALLET_DIR/stale_show.pk"
  fixture_file_address="$(wallet_address_file_to_hex "$MAIN_WALLET_DIR/stale_show.addr")"
  python3 - "$MAIN_WALLET_DIR/stale_show.wallet.meta" <<'PY'
import base64
import binascii
import pathlib
import sys

account = bytes([153] * 32)
friendly = []
for tag in (0x51, 0x11):
    body = bytes([tag, 0]) + account
    friendly.append(base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode())
pathlib.Path(sys.argv[1]).write_text(
    "wallet_name=stale_show\nworkchain=0\nwallet_id=42\nnetwork=testnet\n"
    f"wallet_address=0:{account.hex()}\nnon_bounceable={friendly[0]}\nbounceable={friendly[1]}\n"
)
PY
  main_wallet_show stale_show >"$test_dir/stale-show.out"
  main_wallet_export stale_show >"$test_dir/stale-helper-export.out"
  python3 - "$test_dir/stale-show.out" "$test_dir/stale-helper-export.out" "$fixture_file_address" <<'PY'
import pathlib
import sys

show_rows = [line.split() for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
row = next(row for row in show_rows if len(row) == 9 and row[2] == "stale_show")
assert row[6] == sys.argv[3], "show ignored the authoritative .addr account"
assert row[7:] == ["unknown", "unknown"], "show retained another account's friendly metadata"
export_rows = [line.split() for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
row = next(row for row in export_rows if row and row[0] == "stale_show")
assert row[2:4] == [sys.argv[3], sys.argv[3]], "helper export retained stale address metadata"
PY

  # Collect consumes this exact nine-column show table, preferring the
  # non-bounceable column when present. It must fall back to the file account.
  fixture_show_table="$(cat "$test_dir/stale-show.out")"
  source "$kubeton"
  run_wallet() {
    [[ "$*" == 'show stale_show' ]] || fail "unexpected nested wallet command"
    printf '%s\n' "$fixture_show_table"
  }
  fixture_collect_address="$(resolve_main_wallet_receive_address testnet stale_show)"
  [[ "$fixture_collect_address" == "$fixture_file_address" ]] \
    || fail "collect resolved stale friendly metadata instead of the .addr account"
)

test_invalid_file_export_stays_structured() (
  setup_pod_mock invalid-file
  cp "$test_dir/invalid-short.addr" "$test_dir/pods/tonnode-0/invalid.addr"
  printf 'synthetic test key' >"$test_dir/pods/tonnode-0/invalid.pk"
  python3 - "$test_dir/expected.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
expected = json.loads(path.read_text())
expected["tonnode-0/invalid"] = {
    "address": "unknown",
    "hex": "unknown",
    "key": b"synthetic test key".hex(),
}
path.write_text(json.dumps(expected))
PY
  run_wallet export tonnode-0 invalid >"$test_dir/invalid-export.out" 2>"$test_dir/invalid-export.err"
  assert_pod_export_table "$test_dir/invalid-export.out" tonnode-0/invalid
  assert_not_contains 'invalid|' "$test_dir/invalid-export.out"

  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$test_dir/pods/tonnode-0"
  main_wallet_export invalid >"$test_dir/helper-invalid.out"
  assert_main_wallet_export_table "$test_dir/helper-invalid.out" invalid
)

test_export_all_pods
test_export_selected_wallets
test_main_wallet_file_decoder
test_friendly_address_validation
test_main_wallet_export_files
test_show_and_collect_ignore_stale_metadata
test_invalid_file_export_stays_structured

echo "kubeton wallet export tests passed"
