#!/usr/bin/env bash
set -euo pipefail

# This optional integration test runs real Fift from the published TON image.
# It generates fresh synthetic keys on container tmpfs and replaces only the
# RPC/HTTP boundaries. The container cannot reach any network or write the repo.
if [[ "${KUBETON_WALLET_RUNTIME_TEST_CONTAINER:-}" != 1 ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  image="${TON_RUNTIME_TEST_IMAGE:-ghcr.io/ton-blockchain/ton:v2026.10-amd64}"
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required for test-main-wallet-runtime.' >&2; exit 1; }
  exec docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=64m \
    --tmpfs /var/main-wallet/runtime:rw,nosuid,nodev,size=64m \
    --tmpfs /var/main-wallet/bundle:rw,nosuid,nodev,size=64m \
    --mount "type=bind,source=${repo_root},target=/repo,readonly" \
    --env KUBETON_WALLET_RUNTIME_TEST_CONTAINER=1 \
    --entrypoint bash "$image" /repo/test/main_wallet_runtime_test.sh
fi

source /repo/charts/ton-k8s-operator/main-wallet.sh
for dependency in bash curl jq openssl base64 sha256sum flock sync tar mktemp fift lite-client; do
  command -v "$dependency" >/dev/null 2>&1 || { echo "Runtime dependency missing: $dependency" >&2; exit 1; }
done
test_root="$(mktemp -d /tmp/kubeton-wallet-runtime.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
MAIN_WALLET_DIR=/var/main-wallet/runtime
MAIN_WALLET_BUNDLE_DIR=/var/main-wallet/bundle
WALLET_NETWORK=mainnet
TONCENTER_URL=https://toncenter.com
TONCENTER_API_KEY=''
MODE=auto
GLOBAL_CONFIG_JSON='{}'
MAIN_WALLET_HTTP_MIN_INTERVAL_MS=0
MAIN_WALLET_REBROADCAST_DELAY_SEC=0
MAIN_WALLET_REBROADCAST_ATTEMPTS=2
MAIN_WALLET_CONFIRM_ATTEMPTS=4
MAIN_WALLET_CONFIRM_DELAY_SEC=0
MAIN_WALLET_MULTI_SEND_PAUSE_SEC=0
MAIN_WALLET_SEND_RETRY_DELAY_SEC=0
export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont
mkdir -p "$MAIN_WALLET_DIR" "$MAIN_WALLET_BUNDLE_DIR"
main_wallet_create 0 42 offline-check >"$test_root/create.log" 2>&1
fixture_source="$(resolve_wallet_address_by_name offline-check)"
fixture_first="-1:$(printf '%064d' 2)"
fixture_second="-1:$(printf '%064d' 3)"
printf 7 >"$test_root/seqno"
printf '{"ok":true,"result":[]}' >"$test_root/receipts.json"
: >"$test_root/transport-events"

fail_runtime() { echo "Runtime test failure: $*" >&2; return 1; }

fake_accept_payload() {
  local input="$1" pending seq expiry body path dest amount index actual_body txhash receipt updated
  pending="$(wallet_outbox_pending)" || return 1
  IFS=$'\t' read -r seq expiry body path dest amount index <<<"$pending"
  cmp -s "$input" "$path" || { fail_runtime 'rebroadcast differs from the durably saved signed bytes'; return 1; }
  actual_body="$(wallet_message_body_hash "$input")" || return 1
  [[ "$actual_body" == "$body" ]] || { fail_runtime 'real Fift body hash differs from the outgoing journal'; return 1; }
  txhash="$(printf 'synthetic transaction %s' "$seq" | openssl dgst -sha256 -binary | base64 -w0)" || return 1
  receipt="$(jq -nc --arg source "$fixture_source" --arg destination "$dest" --arg value "$amount" \
    --arg hash "$body" --arg tx "$txhash" --arg lt "10000000000000$seq" \
    '{transaction_id:{lt:$lt,hash:$tx},in_msg:{source:"",destination:$source,body_hash:$hash},out_msgs:[{source:$source,destination:$destination,value:$value}]}')" || return 1
  updated="$(jq --argjson receipt "$receipt" '.result=[$receipt]+.result' "$test_root/receipts.json")" || return 1
  printf '%s' "$updated" >"$test_root/receipts.json" || return 1
  printf '%s' "$((10#$seq + 1))" >"$test_root/seqno"
}

run_liteclient_query() {
  local query="$1" input pending seq rest
  [[ "$query" == sendfile\ * ]] || { fail_runtime "unexpected RPC: $query"; return 1; }
  input="${query#sendfile }"
  pending="$(wallet_outbox_pending)" || return 1
  IFS=$'\t' read -r seq rest <<<"$pending"
  printf 'lite %s\n' "$seq" >>"$test_root/transport-events"
  if [[ "$seq" == 8 ]]; then
    # The second recipient must not be signed until the first exact receipt
    # has advanced the journal; an ACK alone cannot unlock this transition.
    wallet_outbox_read_state | jq -e '.next==1 and .confirmed[0].seqno=="7"' >/dev/null || return 1
    fake_accept_payload "$input" || return 1
  fi
  # The first server ACKs but does not include the request. Only the later
  # HTTPS rebroadcast below makes its exact payment receipt observable.
  printf 'external message status is 1\n'
}

curl() {
  local endpoint='' payload='' headers='' write_format='' parameter pending seq rest
  while (( $# > 0 )); do
    case "$1" in
      -fsS|-sS|--get) shift ;;
      --connect-timeout|--max-time|-H|--request) shift 2 ;;
      --dump-header) headers="$2"; shift 2 ;;
      -w) write_format="$2"; shift 2 ;;
      --data) payload="$2"; shift 2 ;;
      --data-urlencode)
        parameter="$2"
        case "$parameter" in
          "address=$fixture_source"|limit=100) ;;
          *) fail_runtime "unexpected API parameter: $parameter"; return 1 ;;
        esac
        shift 2 ;;
      https://toncenter.com/api/v2/*) endpoint="$1"; shift ;;
      *) fail_runtime "unexpected curl argument: $1"; return 1 ;;
    esac
  done
  [[ -z "$headers" ]] || printf 'HTTP/2 200\r\n\r\n' >"$headers"
  case "$endpoint" in
    */getWalletInformation)
      jq -nc --argjson seq "$(cat "$test_root/seqno")" \
        '{ok:true,result:{wallet:true,account_state:"active",balance:"10000000000",seqno:$seq,wallet_type:"wallet v3 r2"}}'
      ;;
    */getTransactions) cat "$test_root/receipts.json" ;;
    */sendBoc)
      [[ -n "$payload" && -n "$write_format" ]] || return 1
      printf '%s' "$payload" | jq -er '.boc' | base64 -d >"$test_root/rebroadcast.boc" || return 1
      pending="$(wallet_outbox_pending)" || return 1
      IFS=$'\t' read -r seq rest <<<"$pending"
      printf 'https %s\n' "$seq" >>"$test_root/transport-events"
      fake_accept_payload "$test_root/rebroadcast.boc" || return 1
      printf '{"ok":true,"result":{"@type":"ok"}}\n200'
      ;;
    *) fail_runtime "unexpected API endpoint: $endpoint"; return 1 ;;
  esac
}

if ! main_wallet_send offline-check 0.02 "$fixture_first" "$fixture_second" -n >"$test_root/dryrun.log" 2>&1; then
  tail -n 15 "$test_root/dryrun.log" >&2
  exit 1
fi
[[ "$(cat "$test_root/transport-events")" == $'lite 7\nhttps 7\nlite 8' ]] || { fail_runtime 'unexpected transport or sequence progression'; exit 1; }
[[ "$(cat "$test_root/seqno")" == 9 ]] || { fail_runtime 'source counter did not advance exactly twice'; exit 1; }
jq -e '.complete==true and .next==2 and [.confirmed[].seqno]==["7","8"] and (.confirmed|length)==2 and .pending==null' \
  "$MAIN_WALLET_BUNDLE_DIR/.outbox/offline-check/state.json" >/dev/null
echo 'TON runtime test passed: real Fift signing, ACK without inclusion, identical BOC rebroadcast, exact receipts, and ordered payments. Container networking disabled; RPC/HTTP mocked.'
