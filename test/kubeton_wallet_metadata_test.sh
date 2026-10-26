#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() {
  if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi
}

# Public synthetic identities only. No wallet private files or external clients
# are used; the actual pod Python executes against these local JSON fixtures.
python3 - "$test_dir" <<'PY'
import base64
import binascii
import json
import pathlib
import sys

folder = pathlib.Path(sys.argv[1])
identities = {}
versions = {}
for workchain, account_byte, version in [(-1, 0, "v1"), (0, 255, "v3R2"), (1, 124, "v4._-R2")]:
    account = bytes([account_byte]) + bytes(range(31))
    raw = f"{workchain}:{account.hex()}"
    identities[str(workchain)] = raw
    for tag, value in [(0x11, version), (0x51, "wrong-nonbounceable"), (0x91, "wrong-testnet")]:
        body = bytes([tag, workchain & 255]) + account
        key = base64.urlsafe_b64encode(body + binascii.crc_hqx(body, 0).to_bytes(2, "big")).decode()
        versions[key] = value
(folder / "valid.db").write_text(json.dumps({"walletsVersionList": versions}))
(folder / "identities.json").write_text(json.dumps(identities))
PY

raw_identity() {
  python3 - "$test_dir/identities.json" "$1" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())[sys.argv[2]])
PY
}

setup_case() {
  source "$kubeton"
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir"
  database="$case_dir/mytoncore.db"
  cp "$test_dir/valid.db" "$database"
  events="$case_dir/events"
  : >"$events"
  metadata_rc=0
  fixture_raw="$(raw_identity -1)"
  live_mode=failed
  address_mode=available
  run_with_timeout() { shift; "$@"; }
  kubectl() {
    if [[ $# != 11 || "$1" != -n || "$2" != unit-ns || "$3" != exec || "$4" != tonnode-0 ||
          "$5" != -c || "$6" != ton-node || "$7" != -- || "$8" != python3 || "$9" != -c ]]; then
      printf 'unexpected kubectl operation\n' >>"$events"
      return 90
    fi
    local script="${10}" raw="${11}"
    # Enforce that metadata code opens only its fixed JSON file. No imported
    # controller, subprocess, network call, or wallet directory is allowed.
    python3 - "$script" <<'PY'
import ast
import sys

tree = ast.parse(sys.argv[1])
imports = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
assert imports == {"base64", "binascii", "json", "pathlib", "re", "sys"}, imports
assert not any(isinstance(node, ast.ImportFrom) for node in ast.walk(tree))
paths = [node.args[0].value for node in ast.walk(tree)
         if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
         and isinstance(node.func.value, ast.Name) and node.func.value.id == "pathlib"
         and node.func.attr == "Path" and len(node.args) == 1 and isinstance(node.args[0], ast.Constant)]
assert paths == ["/var/ton-work/controller/mytoncore/mytoncore.db"], paths
assert ".pk" not in sys.argv[1] and "wallets/" not in sys.argv[1]
PY
    printf 'metadata %s\n' "$raw" >>"$events"
    script="${script//\/var\/ton-work\/controller\/mytoncore\/mytoncore.db/$database}"
    python3 -c "$script" "$raw" || return "$?"
    return "$metadata_rc"
  }
  list_ton_pods() { printf 'unit-ns\ttonnode-0\tworker-0\n'; }
  resolve_tonnode_wallet_row_from_pod() {
    printf 'state\n' >>"$events"
    [[ "$live_mode" == available ]] || return 1
    printf '%s\tactive\t12.000000000\tv9\t-1\t%s\n' "$3" "$(ton_address_to_non_bounceable "$fixture_raw")"
  }
  read_tonnode_wallet_address_file_from_pod() {
    printf 'address\n' >>"$events"
    [[ "$address_mode" == available ]] || return 1
    printf '%s' "$fixture_raw"
  }
}

test_metadata_selects_bounceable_account_key() (
  setup_case correct-identity
  local workchain expected actual
  for workchain in -1 0 1; do
    case "$workchain" in
      -1) expected=v1 ;;
      0) expected=v3R2 ;;
      1) expected=v4._-R2 ;;
    esac
    actual="$(read_tonnode_wallet_version_from_pod unit-ns tonnode-0 "$(raw_identity "$workchain")")"
    [[ "$actual" == "$expected" ]] || fail "incorrect static version for workchain $workchain: $actual"
  done
  assert_not_contains unexpected "$events"
)

test_metadata_rejects_missing_or_invalid_versions() (
  setup_case invalid-metadata
  python3 - "$case_dir" "$test_dir/valid.db" <<'PY'
import json
import pathlib
import sys

folder = pathlib.Path(sys.argv[1])
versions = json.loads(pathlib.Path(sys.argv[2]).read_text())["walletsVersionList"]
key = next(iter(versions))
fixtures = {
    "missing-version": {"walletsVersionList": {}},
    "missing-list": {},
    "null-list": {"walletsVersionList": None},
    "array-list": {"walletsVersionList": []},
    "scalar-list": {"walletsVersionList": "v1"},
    "array-db": [],
    "null-db": None,
}
for name, value in [("integer", 1), ("null", None), ("array", ["v1"]), ("empty", ""),
                    ("whitespace", "v1 injected"), ("newline", "v1\n"), ("slash", "../v1"),
                    ("too-long", "v" * 33)]:
    fixtures[name] = {"walletsVersionList": {key: value}}
for name, value in fixtures.items():
    (folder / f"{name}.fixture").write_text(json.dumps(value))
(folder / "malformed.fixture").write_text("{")
PY
  local fixture
  for fixture in "$case_dir/"*.fixture; do
    cp "$fixture" "$database"
    if read_tonnode_wallet_version_from_pod unit-ns tonnode-0 "$fixture_raw" >"$case_dir/out" 2>"$case_dir/err"; then
      fail "accepted invalid metadata fixture $fixture"
    fi
    [[ ! -s "$case_dir/out" ]] || fail "invalid metadata leaked stdout"
  done
  rm "$database"
  if read_tonnode_wallet_version_from_pod unit-ns tonnode-0 "$fixture_raw" >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted missing metadata database"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "missing database leaked stdout"
)

test_metadata_discards_failed_read_stdout() (
  setup_case failed-read
  metadata_rc=124
  if read_tonnode_wallet_version_from_pod unit-ns tonnode-0 "$fixture_raw" >"$case_dir/out" 2>"$case_dir/err"; then
    fail "accepted valid-looking output from a failed pod metadata read"
  fi
  [[ ! -s "$case_dir/out" ]] || fail "failed read leaked a version"
)

test_metadata_validates_raw_input() (
  setup_case invalid-identity
  local raw account
  account="${fixture_raw#*:}"
  for raw in '' 'not-an-address' '0:abc' "128:$account" "-129:$account"; do
    if read_tonnode_wallet_version_from_pod unit-ns tonnode-0 "$raw" >"$case_dir/out" 2>"$case_dir/err"; then
      fail "accepted invalid metadata identity '$raw'"
    fi
    [[ ! -s "$case_dir/out" ]] || fail "invalid identity leaked a version"
  done
)

test_failed_live_balance_keeps_static_version() (
  setup_case balance-fallback
  run_wallet_balance_show >"$case_dir/out" 2>"$case_dir/err"
  python3 - "$case_dir/out" "$fixture_raw" <<'PY'
import pathlib
import sys

rows = [[cell.strip() for cell in line.strip().strip("|").split("|")]
        for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.startswith("| unit-ns")]
assert len(rows) == 1, rows
namespace, pod, name, state, balance, version, workchain, address = rows[0]
assert [state, balance, version, workchain] == ["unknown", "unknown", "v1", "-1"], rows
assert len(address) == 48 and address.startswith("Uf"), address
PY
  assert_contains 'live balance unavailable' "$case_dir/err"
  [[ "$(grep -c '^metadata ' "$events")" == 1 ]] || fail "static version read repeated"
  assert_not_contains unexpected "$events"

  rm "$database"
  run_wallet_balance_show >"$case_dir/missing-metadata" 2>"$case_dir/err"
  assert_contains '| unknown | unknown | unknown |' "$case_dir/missing-metadata"
)

test_metadata_is_only_used_for_failed_balance_with_local_identity() (
  setup_case fallback-boundaries
  live_mode=available
  run_wallet_balance_show >"$case_dir/live" 2>"$case_dir/err"
  assert_contains '12.000000000' "$case_dir/live"
  assert_contains 'v9' "$case_dir/live"
  assert_not_contains metadata "$events"
  assert_not_contains address "$events"

  : >"$events"
  live_mode=failed
  address_mode=unavailable
  run_wallet_balance_show >"$case_dir/no-identity" 2>"$case_dir/err"
  assert_not_contains metadata "$events"
  assert_contains '| unknown | unknown | unknown | unknown | unknown' "$case_dir/no-identity"
)

test_metadata_selects_bounceable_account_key
test_metadata_rejects_missing_or_invalid_versions
test_metadata_discards_failed_read_stdout
test_metadata_validates_raw_input
test_failed_live_balance_keeps_static_version
test_metadata_is_only_used_for_failed_balance_with_local_identity

echo "kubeton wallet static metadata tests passed"
