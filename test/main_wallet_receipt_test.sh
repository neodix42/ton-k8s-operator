#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
fail() { echo "test failure: $*" >&2; exit 1; }

# All accounts, hashes, API replies and Fift process output are synthetic.
# The API boundary refuses every unrecognized method or parameter; no real
# node, signing key, wallet or network is used by this regression suite.
python3 - "$test_dir" <<'PY'
import base64
import binascii
import copy
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
source = "0:" + "01" * 32
destination = "-1:" + "02" * 32
other = "-1:" + "03" * 32
body_hash = base64.b64encode(hashlib.sha256(b"synthetic body").digest()).decode()
tx_hash = base64.b64encode(hashlib.sha256(b"synthetic transaction").digest()).decode()
root_hash = base64.b64encode(hashlib.sha256(b"synthetic block root").digest()).decode()
file_hash = base64.b64encode(hashlib.sha256(b"synthetic block file").digest()).decode()

def friendly(raw):
    wc, account = raw.split(":")
    data = bytes([0x11, int(wc) & 0xff]) + bytes.fromhex(account)
    return base64.urlsafe_b64encode(data + binascii.crc_hqx(data, 0).to_bytes(2, "big")).decode()

(root / "fixture.tsv").write_text("\t".join([source, destination, other, body_hash, tx_hash, root_hash, file_hash]))
transaction = {
    "transaction_id": {"lt": "123456789000001", "hash": tx_hash},
    "in_msg": {"source": "", "destination": friendly(source), "body_hash": body_hash},
    "out_msgs": [{"source": friendly(source), "destination": friendly(destination), "value": "1600000000"}],
}

def receipt(name, change):
    value = copy.deepcopy(transaction)
    change(value)
    (root / (name + ".json")).write_text(json.dumps({"ok": True, "result": [value]}))

receipt("paid", lambda t: None)
receipt("wrong-body", lambda t: t["in_msg"].update(body_hash=file_hash))
receipt("internal-message", lambda t: t["in_msg"].update(source=source))
receipt("wrong-inbound-account", lambda t: t["in_msg"].update(destination=other))
receipt("wrong-destination", lambda t: t["out_msgs"][0].update(destination=other))
receipt("wrong-source", lambda t: t["out_msgs"][0].update(source=other))
receipt("wrong-amount", lambda t: t["out_msgs"][0].update(value="1600000001"))
receipt("no-payment", lambda t: t.update(out_msgs=[]))
receipt("aborted", lambda t: t.update(aborted=True))
receipt("missing-output", lambda t: t.pop("out_msgs"))
receipt("bad-output-address", lambda t: t["out_msgs"][0].update(destination="not an address"))
receipt("bad-output-value", lambda t: t["out_msgs"][0].update(value="not an amount"))
receipt("bad-transaction-hash", lambda t: t["transaction_id"].update(hash="not a hash"))
receipt("bad-logical-time", lambda t: t["transaction_id"].update(lt="not a logical time"))
(root / "pending.json").write_text(json.dumps({"ok": True, "result": []}))
(root / "api-error.json").write_text(json.dumps({"ok": False, "result": []}))
(root / "malformed.json").write_text('{"ok":true,')
(root / "json-stream.json").write_text('{"ok":false}\n' + (root / "paid.json").read_text())

block = {"workchain": -1, "shard": "-9223372036854775808", "seqno": 123, "root_hash": root_hash, "file_hash": file_hash}
(root / "masterchain.json").write_text(json.dumps({"ok": True, "result": {"last": block}}))
(root / "header.json").write_text(json.dumps({"ok": True, "result": {"id": block, "gen_utime": 3000}}))
(root / "wallet.json").write_text(json.dumps({"ok": True, "result": {"wallet": True, "account_state": "active", "seqno": 7}}))

for name, path, change in [
    ("wrong-masterchain", "masterchain", lambda v: v["result"]["last"].update(workchain=0)),
    ("wrong-header-seqno", "header", lambda v: v["result"]["id"].update(seqno=124)),
    ("wrong-header-hash", "header", lambda v: v["result"]["id"].update(root_hash=tx_hash)),
    ("stale-header", "header", lambda v: v["result"].update(gen_utime=2000)),
    ("inside-margin", "header", lambda v: v["result"].update(gen_utime=2010)),
    ("advanced-wallet", "wallet", lambda v: v["result"].update(seqno=8)),
    ("wrong-wallet-state", "wallet", lambda v: v["result"].update(account_state="frozen")),
    ("not-wallet", "wallet", lambda v: v["result"].update(wallet=False)),
]:
    value = json.loads((root / (path + ".json")).read_text())
    change(value)
    (root / (name + ".json")).write_text(json.dumps(value))
PY

setup_case() {
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  MAIN_WALLET_DIR="$test_dir/runtime"
  mkdir -p "$MAIN_WALLET_DIR"
  IFS=$'\t' read -r fixture_source fixture_destination fixture_other fixture_body fixture_tx fixture_root fixture_file < <(cat "$test_dir/fixture.tsv"; printf '\n')
  WALLET_NETWORK=mainnet
  TONCENTER_URL=https://toncenter.com
  receipt_response=paid
  masterchain_response=masterchain
  header_response=header
  wallet_response=wallet
  rpc_fail=""
  : >"$test_dir/queries"
  curl() { fail "unexpected network call: $*"; }
  wallet_toncenter_get() {
    printf '%s\n' "$*" >>"$test_dir/queries"
    [[ "$1" != "$rpc_fail" ]] || return 91
    case "$1" in
      getTransactions)
        [[ "$*" == "getTransactions address=$fixture_source limit=100" ]] || fail "unexpected receipt parameters: $*"
        cat "$test_dir/$receipt_response.json"
        ;;
      getMasterchainInfo)
        [[ $# == 1 ]] || fail "unexpected masterchain parameters"
        cat "$test_dir/$masterchain_response.json"
        ;;
      getBlockHeader)
        [[ "$*" == "getBlockHeader workchain=-1 shard=-9223372036854775808 seqno=123 root_hash=$fixture_root file_hash=$fixture_file" ]] || fail "block header was not pinned: $*"
        cat "$test_dir/$header_response.json"
        ;;
      getWalletInformation)
        [[ "$*" == "getWalletInformation address=$fixture_source seqno=123" ]] || fail "wallet query was not pinned: $*"
        cat "$test_dir/$wallet_response.json"
        ;;
      *) fail "unexpected API method: $*" ;;
    esac
  }
}

assert_receipt() {
  local expected="$1" actual="" rc=0
  actual="$(wallet_transaction_receipt "$fixture_source" "$fixture_body" "$fixture_destination" 1600000000 2>"$test_dir/receipt.stderr")" || rc=$?
  [[ "$rc" == "$expected" ]] || fail "receipt $receipt_response returned $rc; expected $expected"
  if [[ "$expected" == 0 ]]; then
    [[ "$actual" == 123456789000001$'\t'"$fixture_tx" ]] || fail 'receipt did not return exact transaction identity'
  else
    [[ -z "$actual" ]] || fail 'unconfirmed receipt printed a transaction identity'
  fi
}

test_receipts() (
  setup_case
  assert_receipt 0
  local response
  for response in pending wrong-body internal-message; do receipt_response="$response"; assert_receipt 10; done
  for response in wrong-destination wrong-source wrong-amount no-payment aborted; do receipt_response="$response"; assert_receipt 11; done
  for response in wrong-inbound-account missing-output bad-output-address bad-output-value bad-transaction-hash bad-logical-time api-error malformed json-stream; do receipt_response="$response"; assert_receipt 1; done
  receipt_response=paid
  rpc_fail=getTransactions
  assert_receipt 1
)

test_network_guard() (
  setup_case
  WALLET_NETWORK=testnet
  assert_receipt 1
  [[ ! -s "$test_dir/queries" ]] || fail 'mismatched network reached the API'
)

test_expiry_snapshot() (
  setup_case
  [[ "$(wallet_expired_message_unconsumed "$fixture_source" 7 2000)" == '{"masterchain_seqno":123,"gen_utime":3000,"wallet_seqno":7}' ]] || fail 'unchanged counter in a post-expiry snapshot was rejected'
  local response
  for response in stale-header inside-margin wrong-header-seqno wrong-header-hash; do
    header_response="$response"
    if wallet_expired_message_unconsumed "$fixture_source" 7 2000 >/dev/null; then fail "accepted $response"; fi
  done
  header_response=header
  for response in advanced-wallet wrong-wallet-state not-wallet; do
    wallet_response="$response"
    if wallet_expired_message_unconsumed "$fixture_source" 7 2000 >/dev/null; then fail "accepted $response"; fi
  done
  wallet_response=wallet
  masterchain_response=wrong-masterchain
  if wallet_expired_message_unconsumed "$fixture_source" 7 2000 >/dev/null; then fail 'accepted a non-masterchain clock'; fi
  masterchain_response=masterchain
  for response in getMasterchainInfo getBlockHeader getWalletInformation; do
    rpc_fail="$response"
    if wallet_expired_message_unconsumed "$fixture_source" 7 2000 >/dev/null; then fail "accepted RPC error from $response"; fi
  done
)

test_fift_boundary() (
  setup_case
  printf 'synthetic BOC placeholder' >"$test_dir/synthetic.boc"
  cat >"$test_dir/fake-fift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && "$1" == -s && -s "$2" && -s "$3" ]]
grep -Fq 'hashu 256 u>B B>base64 type cr' "$2"
[[ "${RECEIPT_FIFT_FAIL:-0}" == 0 ]] || exit 1
printf '%s' "$RECEIPT_FIFT_HASH"
SH
  chmod +x "$test_dir/fake-fift"
  resolve_fift_bin() { printf '%s/fake-fift' "$test_dir"; }
  export RECEIPT_FIFT_HASH="$fixture_body" RECEIPT_FIFT_FAIL=0
  [[ "$(wallet_message_body_hash "$test_dir/synthetic.boc")" == "$fixture_body" ]] || fail 'body hash was not returned'
  RECEIPT_FIFT_FAIL=1
  if wallet_message_body_hash "$test_dir/synthetic.boc" >/dev/null; then fail 'accepted a failed Fift execution'; fi
  RECEIPT_FIFT_FAIL=0 RECEIPT_FIFT_HASH=malformed
  if wallet_message_body_hash "$test_dir/synthetic.boc" >/dev/null; then fail 'accepted malformed hash output'; fi
  [[ -z "$(find "$MAIN_WALLET_DIR" -name '.wallet-body-hash.*' -print -quit)" ]] || fail 'temporary Fift script was retained'
)

test_receipts
test_network_guard
test_expiry_snapshot
test_fift_boundary
echo 'main wallet receipt tests passed (35 scenarios).'
