#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }

# Exercise the real send/deploy/polling functions. Only Fift and the RPC/HTTP
# process boundaries are synthetic. No real wallet, signing key or network is
# used, and every unexpected external operation fails closed.
setup_case() {
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  case_dir="$test_dir/$1"
  MAIN_WALLET_DIR="$case_dir/wallets"
  MAIN_WALLET_BUNDLE_DIR="$case_dir/bundle"
  SMARTCONT_DIR="$case_dir/smartcont"
  mkdir -p "$MAIN_WALLET_DIR" "$MAIN_WALLET_BUNDLE_DIR" "$SMARTCONT_DIR"
  events="$case_dir/events"
  : >"$events"
  WALLET_NETWORK=mainnet
  TONCENTER_URL=https://toncenter.com
  MODE=liteserver
  MAIN_WALLET_SEND_RETRY_ATTEMPTS=1
  MAIN_WALLET_LITESERVER_SEND_ATTEMPTS=1
  MAIN_WALLET_TONCENTER_SEND_ATTEMPTS=1
  MAIN_WALLET_SEND_RETRY_DELAY_SEC=0
  MAIN_WALLET_MULTI_SEND_PAUSE_SEC=0
  MAIN_WALLET_CONFIRM_ATTEMPTS=2
  MAIN_WALLET_CONFIRM_DELAY_SEC=0
  MAIN_WALLET_HTTP_MIN_INTERVAL_MS=0
  MAIN_WALLET_REBROADCAST_DELAY_SEC=0
  MAIN_WALLET_REBROADCAST_ATTEMPTS=1
  MAIN_WALLET_TRANSFER_VALIDITY_SEC=180
  MAIN_WALLET_VERBOSE=false
  fixture_source="0:$(printf '%064d' 1)"
  fixture_first="-1:$(printf '%064d' 2)"
  fixture_second="-1:$(printf '%064d' 3)"
  printf '%s\n' "$fixture_source" >"$MAIN_WALLET_DIR/savings.addr"
  printf 'synthetic signing-key placeholder\n' >"$MAIN_WALLET_DIR/savings.pk"
  printf 'stale synthetic deployment BOC, must never be reused\n' >"$MAIN_WALLET_DIR/savings-query.boc"
  printf 'wallet_name=savings\nworkchain=0\nwallet_id=42\nnetwork=mainnet\nwallet_version=v3\nwallet_address=%s\n' \
    "$fixture_source" >"$MAIN_WALLET_DIR/savings.wallet.meta"
  printf 'synthetic v3 Fift script\n' >"$SMARTCONT_DIR/wallet-v3.fif"
  printf 'synthetic v3 StateInit script\n' >"$SMARTCONT_DIR/new-wallet-v3.fif"
  # An incompatible old script is present to catch accidental fallback.
  printf 'synthetic legacy script, must never be selected\n' >"$SMARTCONT_DIR/wallet.fif"
  printf active >"$case_dir/status"
  printf 7 >"$case_dir/seqno"
  printf 10000007883 >"$case_dir/balance"
  printf accept >"$case_dir/behavior"
  printf accept >"$case_dir/deployment"
  printf 0 >"$case_dir/fift-rc"
  printf 0 >"$case_dir/fift-init-rc"
  printf 0 >"$case_dir/fift-init-mutate-key"
  printf '%s\n' "$fixture_source" >"$case_dir/fift-init-address"
  export MAIN_WALLET_TEST_CASE="$case_dir"

  cat >"$case_dir/fake-fift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case_dir="$MAIN_WALLET_TEST_CASE"
if [[ $# == 5 && "$1" == -s && "$2" == */new-wallet-v3.fif ]]; then
  [[ "$3" == 0 && "$4" == 42 && "$5" == "$PWD/wallet" && "$PWD" != "$case_dir/wallets" ]] || { echo 'incorrect init workchain/subwallet identity or isolation' >&2; exit 90; }
  [[ -f "$5.pk" ]] && cmp "$case_dir/wallets/savings.pk" "$5.pk" || { echo 'init did not reuse the original signing key' >&2; exit 89; }
  printf 'fift-init\n' >>"$case_dir/events"
  printf 'synthetic Fift diagnostic containing private fixture text\n'
  rc="$(cat "$case_dir/fift-init-rc")"
  (( rc == 0 )) || exit "$rc"
  cp "$case_dir/fift-init-address" "$5.addr"
  [[ "$(cat "$case_dir/fift-init-mutate-key")" != 1 ]] || printf 'unexpected replacement key\n' >"$5.pk"
  printf 'deployment|%s\n' "$(cat "$case_dir/fift-init-address")" >"$5-query.boc"
  exit 0
fi
[[ $# -ge 8 ]] || { echo 'unexpected Fift argument count' >&2; exit 91; }
[[ "$1" == -s && "$2" == "$case_dir/smartcont/wallet-v3.fif" ]] || { echo 'unexpected wallet signing script' >&2; exit 92; }
[[ "$3" == "$case_dir/wallets/savings" && "$5" == 42 ]] || { echo 'incorrect source wallet identity' >&2; exit 93; }
seqno="$6"; destination="$4"; amount="$7"; output="$8"; bounce=""; validity=""
shift 8
while (( $# > 0 )); do
  case "$1" in
    -n) [[ -z "$bounce" ]] || exit 94; bounce=-n; shift ;;
    -t) [[ "${2:-}" == 180 && -z "$validity" ]] || exit 94; validity="$2"; shift 2 ;;
    *) echo 'unexpected transfer signing option' >&2; exit 94 ;;
  esac
done
[[ "$validity" == 180 ]] || { echo 'transfer expiry must cover bounded fallback attempts' >&2; exit 94; }
printf 'fift %s %s %s %s\n' "$seqno" "$destination" "$amount" "$bounce" >>"$case_dir/events"
if [[ -e "$case_dir/noisy-signing" ]]; then
  printf 'signing message: x{SYNTHETIC_SIGNING_DUMP}\nB5EE9C72_SYNTHETIC_BOC_DUMP\n'
fi
rc="$(cat "$case_dir/fift-rc")"
if (( rc != 0 )); then
  printf 'Fift synthetic signing error: rejected transfer fixture\n' >&2
  exit "$rc"
fi
printf 'transfer|%s|%s|%s\n' "$seqno" "$destination" "$amount" >"$output.boc"
SH
  chmod +x "$case_dir/fake-fift"
  resolve_fift_bin() { printf '%s/fake-fift' "$case_dir"; }
  curl() { printf 'unexpected HTTP operation\n' >>"$events"; return 95; }
  sleep() { fail 'test attempted a real confirmation/retry delay'; }
  run_liteclient_query() {
    local query="$1" status seqno boc behavior
    status="$(cat "$case_dir/status")"
    seqno="$(cat "$case_dir/seqno")"
    case "$query" in
      "getaccount $fixture_source")
        printf 'account %s %s\n' "$status" "$seqno" >>"$events"
        case "$status" in
          active|uninit|frozen)
            printf 'account state is (account\n balance:(currencies grams:(nanograms amount:(var_uint value:%s)))\n state:account_%s' \
              "$(cat "$case_dir/balance")" "$status"
            [[ "$status" != active ]] || printf '\n data:x{%08X0000002A}' "$seqno"
            printf ')\n'
            ;;
          nonexist) printf 'account state is empty\n' ;;
          unknown) printf 'synthetic RPC failure\n' >&2; return 96 ;;
          *) fail "unrecognized fixture status $status" ;;
        esac
        ;;
      "runmethod $fixture_source seqno")
        printf 'seqno %s %s\n' "$status" "$seqno" >>"$events"
        [[ "$status" == active ]] || return 97
        printf 'result: [ %s ]\n' "$seqno"
        ;;
      sendfile\ *)
        boc="${query#sendfile }"
        [[ -s "$boc" ]] || fail 'broadcast a missing/empty BOC'
        if [[ -f "$case_dir/noisy-rpc-failures" ]]; then
          local invocation=0
          printf '%s' "${WALLET_SEND_DIAGNOSTICS_FILE:-}" >"$case_dir/observed-diag-path"
          [[ ! -e "$case_dir/noisy-rpc-count" ]] || invocation="$(cat "$case_dir/noisy-rpc-count")"
          invocation=$((invocation + 1))
          printf '%s' "$invocation" >"$case_dir/noisy-rpc-count"
          printf 'rpc-attempt %s\n' "$invocation" >>"$events"
          printf '[ 3][ext-client] SYNTHETIC_RAW_RPC_DEBUG\n'
          if (( invocation == 1 )); then
            printf '[error] liteserver error: [Error : -503 : synthetic RPC timeout]\n' >&2
          else
            printf '[error] PosixError : synthetic Connection refused : 111\n' >&2
          fi
          return 99
        fi
        if [[ -f "$case_dir/noisy-rpc-ack" ]]; then
          printf '[ 3][ext-client] SYNTHETIC_RAW_RPC_DEBUG\n'
        fi
        if [[ "$(head -c 11 "$boc")" == 'deployment|' ]]; then
          [[ "$(cat "$boc")" == "deployment|$fixture_source" ]] || fail 'broadcast StateInit for the wrong account'
          printf 'deploy\n' >>"$events"
          behavior="$(cat "$case_dir/deployment")"
          [[ "$behavior" != reject ]] || return 98
          if [[ "$behavior" == accept ]]; then
            printf active >"$case_dir/status"
            printf 1 >"$case_dir/seqno"
          fi
        else
          [[ "$(cat "$boc")" == transfer\|"$seqno"\|* ]] || fail 'broadcast a transfer with an unconfirmed sequence number'
          [[ "$status" == active ]] || fail 'attempted a transfer before deployment'
          assert_contains "transfer|$seqno|" "$boc"
          printf 'broadcast %s\n' "$seqno" >>"$events"
          if [[ -f "$case_dir/no-ack-at" && "$seqno" == "$(cat "$case_dir/no-ack-at")" ]]; then
            printf 'zerostate set to fixture\nBLK#1 = public block fixture\n'
            return 0
          fi
          behavior="$(cat "$case_dir/behavior")"
          [[ ! -f "$case_dir/behavior-$seqno" ]] || behavior="$(cat "$case_dir/behavior-$seqno")"
          if [[ "$behavior" == accept-rebroadcast ]]; then
            if [[ -f "$case_dir/signed-$seqno.boc" ]]; then
              cmp "$case_dir/signed-$seqno.boc" "$boc" || fail 'rebroadcast changed the signed message bytes'
              printf '%s' "$((seqno + 1))" >"$case_dir/seqno"
              touch "$case_dir/paid-$seqno"
            else
              cp "$boc" "$case_dir/signed-$seqno.boc"
            fi
          fi
          [[ "$behavior" != reject ]] || return 99
          if [[ "$behavior" == accept ]]; then
            printf '%s' "$((seqno + 1))" >"$case_dir/seqno"
            touch "$case_dir/paid-$seqno"
          fi
          [[ "$behavior" != concurrent ]] || printf '%s' "$((seqno + 2))" >"$case_dir/seqno"
          if [[ "$behavior" == consumed-no-payment ]]; then
            printf '%s' "$((seqno + 1))" >"$case_dir/seqno"
            touch "$case_dir/consumed-$seqno"
          fi
          if [[ "$behavior" == lost-ack ]]; then
            printf '%s' "$((seqno + 1))" >"$case_dir/seqno"
            touch "$case_dir/paid-$seqno"
            return 99
          fi
        fi
        printf 'external message status is 1\n'
        ;;
      *) fail "unexpected lite-client operation: $query" ;;
    esac
  }
  # The transfer orchestration tests use textual synthetic BOCs. Independent
  # receipt tests exercise real message hashing and transaction JSON. Here a
  # digest identifies the exact fixture message across retries and restarts.
  wallet_message_body_hash() {
    local hash key
    hash="$(python3 - "$1" <<'PY'
import base64, hashlib, pathlib, sys
print(base64.b64encode(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())
PY
    )"
    key="$(printf '%s' "$hash" | tr '/+' '_-' | tr -d '=')"
    cp "$1" "$case_dir/receipt-$key.boc"
    printf '%s' "$hash"
  }
  wallet_transaction_receipt() {
    local source="$1" hash="$2" destination="$3" amount_nano="$4" key kind seqno actual_destination actual_amount
    [[ "$source" == "$fixture_source" ]] || fail 'receipt queried the wrong source account'
    key="$(printf '%s' "$hash" | tr '/+' '_-' | tr -d '=')"
    [[ -f "$case_dir/receipt-$key.boc" ]] || fail 'receipt queried an unsigned fixture message'
    IFS='|' read -r kind seqno actual_destination actual_amount <"$case_dir/receipt-$key.boc"
    [[ "$kind" == transfer && "$destination" == "$actual_destination" && "$amount_nano" == "$(gram_amount_to_nano "$actual_amount")" ]] \
      || fail 'receipt query changed the signed payment identity'
    printf 'receipt %s\n' "$seqno" >>"$events"
    [[ ! -f "$case_dir/receipt-unavailable" ]] || return 1
    [[ ! -f "$case_dir/consumed-$seqno" ]] || return 11
    if [[ -f "$case_dir/paid-$seqno" ]]; then
      printf 'receipt-confirmed %s\n' "$seqno" >>"$events"
      printf '%s\t%s' "$((1000 + seqno))" "$hash"
      return 0
    fi
    return 10
  }
}

send_two() {
  main_wallet_send savings 8 "$fixture_first" "$fixture_second" -n
}

assert_failed() {
  if "$@" >"$case_dir/out" 2>"$case_dir/err"; then
    fail "unexpected successful send in ${case_dir##*/}"
  fi
  assert_no_send_diagnostics
}

assert_no_send_diagnostics() (
  shopt -s globstar dotglob nullglob
  local -a leftovers=(
    "$MAIN_WALLET_DIR"/**/.send-diagnostics.*
    "$MAIN_WALLET_BUNDLE_DIR"/**/.send-diagnostics.*
  )
  (( ${#leftovers[@]} == 0 )) || fail 'temporary send diagnostics remained after the operation finished'
  if [[ -s "$case_dir/observed-diag-path" ]]; then
    [[ "$(cat "$case_dir/observed-diag-path")" == "$MAIN_WALLET_DIR"/.send-diagnostics.* ]] \
      || fail 'send diagnostics were stored outside the temporary wallet runtime'
  fi
)

assert_transfer_count() {
  local expected="$1" actual
  actual="$(awk '$1 == "fift" {n++} END {print n+0}' "$events")"
  [[ "$actual" == "$expected" ]] || fail "signed $actual transfer(s); expected $expected"
}

test_active_wallet_confirms_each_transfer() (
  setup_case active
  send_two >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 2
  assert_contains "fift 7 $fixture_first 4.000000000 -n" "$events"
  assert_contains "fift 8 $fixture_second 4.000000000 -n" "$events"
  [[ "$(cat "$case_dir/seqno")" == 9 ]] || fail 'successful transfers were not confirmed'
  ! grep -q '^deploy$' "$events" || fail 'redeployed an active wallet'
  awk '$1 == "broadcast" && $2 == 7 {sent=1}
    sent && $1 == "receipt-confirmed" && $2 == 7 {confirmed=1}
    $1 == "fift" && $2 == 8 && !confirmed {exit 1}' "$events" \
    || fail 'signed the next transfer before confirming the previous one'
)

test_funded_uninit_deploys_before_transfer() (
  setup_case funded-uninit
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  cp "$MAIN_WALLET_DIR/savings.pk" "$case_dir/original.pk"
  cp "$MAIN_WALLET_DIR/savings.addr" "$case_dir/original.addr"
  cp "$MAIN_WALLET_DIR/savings-query.boc" "$case_dir/original-query.boc"
  send_two >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 2
  assert_contains deploy "$events"
  assert_contains "fift 1 $fixture_first 4.000000000 -n" "$events"
  assert_contains "fift 2 $fixture_second 4.000000000 -n" "$events"
  awk '$1 == "deploy" {deployed=1}
    $1 == "seqno" && $2 == "active" && $3 == 1 {confirmed=1}
    $1 == "fift" && (!deployed || !confirmed) {exit 1}' "$events" \
    || fail 'transfer preceded deployment confirmation'
  cmp "$case_dir/original.pk" "$MAIN_WALLET_DIR/savings.pk" || fail 'StateInit generation replaced the existing signing key'
  cmp "$case_dir/original.addr" "$MAIN_WALLET_DIR/savings.addr" || fail 'StateInit generation replaced the existing account address'
  cmp "$case_dir/original-query.boc" "$MAIN_WALLET_DIR/savings-query.boc" || fail 'StateInit generation overwrote the saved deployment query'
)

test_rejected_transfer_stops_the_batch() (
  setup_case rejected
  printf reject >"$case_dir/behavior"
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 7 ]] || fail 'a rejected send advanced the fixture state'
  ! grep -Fq -- "$fixture_second" "$events" || fail 'attempted a later recipient after rejection'
)

test_unconfirmed_transfer_stops_the_batch() (
  setup_case unconfirmed
  printf unconfirmed >"$case_dir/behavior"
  assert_failed send_two
  assert_transfer_count 1
  ! grep -Fq -- "$fixture_second" "$events" || fail 'attempted a later recipient before confirmation'
)

test_unconfirmed_deployment_never_transfers() (
  setup_case deployment-unconfirmed
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  printf unconfirmed >"$case_dir/deployment"
  assert_failed send_two
  assert_transfer_count 0
  assert_contains deploy "$events"
)

test_mismatched_deployment_identity_never_transfers() (
  setup_case mismatched-init
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  rm "$MAIN_WALLET_DIR/savings-query.boc"
  printf '%s\n' "$fixture_first" >"$case_dir/fift-init-address"
  assert_failed send_two
  assert_transfer_count 0
  ! grep -q '^deploy$' "$events" || fail 'broadcast StateInit for another wallet address'
)

test_unusable_source_state_never_transfers() (
  local status
  for status in unknown nonexist frozen; do
    setup_case "unusable-$status"
    printf '%s' "$status" >"$case_dir/status"
    assert_failed send_two
    assert_transfer_count 0
    ! grep -q '^deploy$' "$events" || fail "deployed a source in $status state"
  done
)

test_unfunded_uninit_never_deploys() (
  setup_case unfunded
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  printf 0 >"$case_dir/balance"
  assert_failed send_two
  assert_transfer_count 0
  ! grep -q '^deploy$' "$events" || fail 'deployed an unfunded wallet'
)

test_failed_init_generation_never_transfers() (
  setup_case init-failed
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  printf 42 >"$case_dir/fift-init-rc"
  assert_failed send_two
  assert_transfer_count 0
  ! grep -q '^deploy$' "$events" || fail 'broadcast a stale deployment BOC after init generation failed'
)

test_replacement_init_key_is_rejected() (
  setup_case init-replaced-key
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  printf 1 >"$case_dir/fift-init-mutate-key"
  cp "$MAIN_WALLET_DIR/savings.pk" "$case_dir/original.pk"
  assert_failed send_two
  assert_transfer_count 0
  ! grep -q '^deploy$' "$events" || fail 'broadcast StateInit after signing key changed'
  cmp "$case_dir/original.pk" "$MAIN_WALLET_DIR/savings.pk" || fail 'init verification modified the original key'
)

test_legacy_version_is_derived_from_matching_contract() (
  setup_case legacy-version
  sed -i '/^wallet_version=/d' "$MAIN_WALLET_DIR/savings.wallet.meta"
  cp "$MAIN_WALLET_DIR/savings.wallet.meta" "$case_dir/original.meta"
  main_wallet_show savings >"$case_dir/show" 2>"$case_dir/err"
  awk 'NR == 1 {for (i=1; i<=NF; i++) column[$i]=i; next}
    $(column["wallet-name"]) == "savings" {
      if (!column["wallet-version"] || $(column["wallet-version"]) != "v3") exit 1
      found=1
    } END {if (!found) exit 1}' "$case_dir/show" || fail 'legacy wallet version was not verified'
  assert_contains fift-init "$events"
  ! grep -Fq 'private fixture text' "$case_dir/show" "$case_dir/err" || fail 'version lookup printed Fift diagnostic contents'
  cmp "$case_dir/original.meta" "$MAIN_WALLET_DIR/savings.wallet.meta" || fail 'show rewrote legacy wallet metadata'
)

test_wrong_legacy_contract_does_not_gain_version() (
  setup_case legacy-mismatched-version
  sed -i '/^wallet_version=/d' "$MAIN_WALLET_DIR/savings.wallet.meta"
  printf '%s\n' "$fixture_first" >"$case_dir/fift-init-address"
  main_wallet_show savings >"$case_dir/show" 2>"$case_dir/err"
  awk 'NR == 1 {for (i=1; i<=NF; i++) column[$i]=i; next}
    $(column["wallet-name"]) == "savings" {
      if (!column["wallet-version"] || $(column["wallet-version"]) != "unknown") exit 1
      found=1
    } END {if (!found) exit 1}' "$case_dir/show" || fail 'mismatched V3 constructor established the wallet version'
)

test_concurrent_source_sequence_stops_the_batch() (
  setup_case concurrent
  printf concurrent >"$case_dir/behavior"
  assert_failed send_two
  assert_transfer_count 1
  ! grep -Fq -- "$fixture_second" "$events" || fail 'continued while another operation changed the source seqno'
)

test_single_send_requires_confirmation() (
  setup_case single-unconfirmed
  printf unconfirmed >"$case_dir/behavior"
  assert_failed main_wallet_send savings "$fixture_first" 1 -n
  assert_transfer_count 1
)

test_lost_acknowledgement_stops_before_later_recipients() (
  setup_case lost-ack
  printf lost-ack >"$case_dir/behavior"
  # The chain advanced, but no matching payment receipt can be obtained. A
  # bare seqno change must not establish that this destination was paid.
  touch "$case_dir/receipt-unavailable"
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'fixture did not model on-chain acceptance with a lost acknowledgement'
  ! grep -Fq -- "$fixture_second" "$events" || fail 'continued after an ambiguous accepted send'
  assert_contains 'persistent outgoing batch was retained' "$case_dir/err"
)

test_invalid_arguments_cannot_trigger_deployment() (
  setup_case invalid-arguments
  printf uninit >"$case_dir/status"
  printf 0 >"$case_dir/seqno"
  assert_failed main_wallet_send savings 8 "$fixture_first" invalid-destination
  assert_failed main_wallet_send savings "$fixture_first" 1.0000000001
  assert_failed main_wallet_send savings "$fixture_first" 0
  assert_transfer_count 0
  ! grep -q '^fift-init$\|^deploy$\|^account ' "$events" || fail 'invalid arguments reached source deployment preflight'
)

test_fift_failure_never_broadcasts_stale_boc() (
  setup_case fift-failed
  printf 42 >"$case_dir/fift-rc"
  printf 'stale transfer payload must never be sent\n' >"$MAIN_WALLET_DIR/savings-send-7.boc"
  assert_failed send_two
  assert_transfer_count 1
  ! grep -q '^broadcast ' "$events" || fail 'broadcast after Fift failed'
)

setup_transport_case() {
  setup_case "$1"
  transport_boc="$case_dir/transport.boc"
  printf 'synthetic unsigned message fixture\n' >"$transport_boc"
  transport_output=$'zerostate set to fixture\nBLK#1 = public chain block fixture\nBLK#2 = public zero state fixture'
  transport_rc=0
  transport_stderr=0
  transport_api_rc=0
  transport_http_code=200
  transport_api_response='{"ok":true,"result":{"@type":"ok"}}'
  run_liteclient_query() {
    [[ "$1" == "sendfile $transport_boc" ]] || fail 'unexpected transport RPC'
    printf 'transport-rpc\n' >>"$events"
    if [[ "$transport_stderr" == 1 ]]; then
      printf '%s\n' "$transport_output" >&2
    else
      printf '%s\n' "$transport_output"
    fi
    return "$transport_rc"
  }
  curl() {
    local endpoint="" method="" payload="" write_code=0 argument
    while (( $# > 0 )); do
      argument="$1"
      shift
      case "$argument" in
        -sS) ;;
        --connect-timeout) [[ "${1:-}" =~ ^[1-5]$ ]] || fail 'unexpected transport connection timeout'; shift ;;
        --max-time) [[ "${1:-}" =~ ^[1-9][0-9]?$ ]] && (( $1 <= 15 )) || fail 'unbounded transport request'; shift ;;
        -w) [[ "${1:-}" == $'\n%{http_code}' ]] || fail 'unexpected HTTP response framing'; write_code=1; shift ;;
        -H) [[ "${1:-}" == 'Content-Type: application/json' ]] || fail 'unexpected transport HTTP header'; shift ;;
        --request) method="${1:-}"; shift ;;
        --data) payload="${1:-}"; shift ;;
        https://toncenter.com/api/v2/sendBoc) endpoint="$argument" ;;
        *) fail "unexpected transport HTTP operation: $argument" ;;
      esac
    done
    [[ "$endpoint" == https://toncenter.com/api/v2/sendBoc && "$method" == POST && "$write_code" == 1 ]] \
      || fail 'unexpected TONCenter fallback request'
    [[ "$(printf '%s' "$payload" | jq -er '.boc')" == "$(base64 -w0 "$transport_boc")" ]] \
      || fail 'fallback changed the signed BOC payload'
    printf 'transport-https\n' >>"$events"
    printf '%s\n%s' "$transport_api_response" "$transport_http_code"
    return "$transport_api_rc"
  }
}

test_liteclient_zero_exit_without_ack_uses_api_fallback() (
  setup_transport_case missing-ack
  send_boc_payload "$transport_boc" auto >"$case_dir/out" 2>"$case_dir/err"
  assert_contains transport-rpc "$events"
  assert_contains transport-https "$events"
)

test_liteclient_zero_exit_without_ack_fails_in_liteserver_mode() (
  setup_transport_case missing-ack-liteserver
  assert_failed send_boc_payload "$transport_boc" liteserver
  ! grep -q '^transport-https$' "$events" || fail 'liteserver-only mode invoked the API'
)

test_positive_external_message_ack_is_required() (
  setup_transport_case acknowledged
  transport_output+=$'\nexternal message status is 1'
  send_boc_payload "$transport_boc" auto >"$case_dir/out" 2>"$case_dir/err"
  ! grep -q '^transport-https$' "$events" || fail 'acknowledged liteserver send unnecessarily fell back'
)

test_positive_external_message_ack_on_stderr_is_supported() (
  setup_transport_case acknowledged-stderr
  transport_output+=$'\nexternal message status is 1'
  transport_stderr=1
  send_boc_payload "$transport_boc" auto >"$case_dir/out" 2>"$case_dir/err"
  ! grep -q '^transport-https$' "$events" || fail 'stderr acknowledgement was lost'
)

test_unsuccessful_external_message_status_uses_api_fallback() (
  local status
  for status in 0 -1 10; do
    setup_transport_case "negative-status-$status"
    transport_output+=$'\nexternal message status is '"$status"
    send_boc_payload "$transport_boc" auto >"$case_dir/out" 2>"$case_dir/err"
    assert_contains transport-https "$events"
  done
)

test_failed_rpc_with_ack_is_not_successful_transport() (
  setup_transport_case rpc-failure-with-ack
  transport_output+=$'\nexternal message status is 1'
  transport_rc=1
  send_boc_payload "$transport_boc" auto >"$case_dir/out" 2>"$case_dir/err"
  assert_contains transport-https "$events"
)

test_missing_rpc_ack_and_rejected_api_is_failure() (
  setup_transport_case both-rejected
  transport_api_response='{"ok":false,"error":"synthetic external message rejection"}'
  transport_http_code=500
  assert_failed send_boc_payload "$transport_boc" auto
  assert_contains transport-https "$events"
)

test_batch_recovers_missing_second_ack_via_api_before_next_recipient() (
  setup_case missing-second-ack
  MODE=auto
  printf 8 >"$case_dir/no-ack-at"
  fixture_third="-1:$(printf '%064d' 4)"
  curl() {
    local -a arguments=("$@")
    local payload="" i decoded
    [[ "${arguments[-1]}" == https://toncenter.com/api/v2/sendBoc ]] || fail 'unexpected batch HTTP endpoint'
    for ((i=0; i<${#arguments[@]}; i++)); do
      if [[ "${arguments[$i]}" == --data ]]; then payload="${arguments[$((i+1))]}"; fi
    done
    [[ -n "$payload" ]] || fail 'missing API fallback BOC'
    decoded="$(printf '%s' "$payload" | jq -er .boc | base64 -d)"
    [[ "$decoded" == "transfer|8|$fixture_second|3.000000000" && "$(cat "$case_dir/seqno")" == 8 ]] \
      || fail 'fallback resent the wrong recipient/sequence or changed its amount'
    printf 'api-broadcast 8\n' >>"$events"
    printf 9 >"$case_dir/seqno"
    touch "$case_dir/paid-8"
    printf '{"ok":true,"result":{"@type":"ok"}}\n200'
  }
  main_wallet_send savings 9 "$fixture_first" "$fixture_second" "$fixture_third" -n >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 3
  assert_contains 'api-broadcast 8' "$events"
  assert_contains "fift 9 $fixture_third 3.000000000 -n" "$events"
  [[ "$(cat "$case_dir/seqno")" == 10 ]] || fail 'did not confirm every recipient after API fallback'
  awk '$1 == "api-broadcast" && $2 == 8 {fallback=1}
    fallback && $1 == "receipt-confirmed" && $2 == 8 {confirmed=1}
    $1 == "fift" && $2 == 9 && !confirmed {exit 1}' "$events" \
      || fail 'sent the next recipient before API fallback was confirmed'
)

test_actual_liteclient_invocation_keeps_send_acknowledgement_visible() (
  setup_case invocation-verbosity
  # Restore the real subprocess wrapper; intercept only the executable itself.
  source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
  GLOBAL_CONFIG_JSON='{"synthetic_active_network_config":true}'
  cat >"$case_dir/fake-lite-client" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 8 && "$1" == -C && -r "$2" && "$3" == -v && "$5" == -t && "$6" == 15 && "$7" == -c ]] || exit 91
[[ "$(cat "$2")" == '{"synthetic_active_network_config":true}' ]] || exit 92
printf 'lite-client %s %s\n' "$4" "$8" >>"$MAIN_WALLET_TEST_CASE/events"
case "$8" in
  sendfile\ *) [[ "$4" == 3 ]] || exit 93; printf 'external message status is 1\n' >&2 ;;
  runmethod\ *) [[ "$4" == 0 ]] || exit 94; printf 'result: [ 7 ]\n' ;;
  *) exit 95 ;;
esac
SH
  chmod +x "$case_dir/fake-lite-client"
  resolve_lite_client_bin() { printf '%s/fake-lite-client' "$case_dir"; }
  send_boc_liteserver "$MAIN_WALLET_DIR/savings-query.boc" >"$case_dir/out" 2>"$case_dir/err"
  [[ "$(run_liteclient_query "runmethod $fixture_source seqno")" == 'result: [ 7 ]' ]] \
    || fail 'read query subprocess failed'
  assert_contains "lite-client 3 sendfile $MAIN_WALLET_DIR/savings-query.boc" "$events"
  assert_contains "lite-client 0 runmethod $fixture_source seqno" "$events"
)

test_acknowledged_but_not_included_transfer_rebroadcasts_identical_boc() (
  setup_case acknowledged-not-included
  MODE=auto
  MAIN_WALLET_CONFIRM_ATTEMPTS=5
  MAIN_WALLET_CONFIRM_DELAY_SEC=0
  MAIN_WALLET_REBROADCAST_DELAY_SEC=0
  MAIN_WALLET_REBROADCAST_ATTEMPTS=2
  printf accept-rebroadcast >"$case_dir/behavior"
  curl() {
    local -a arguments=("$@")
    local payload="" i decoded
    [[ "${arguments[-1]}" != https://toncenter.com/api/v2/getWalletInformation ]] || return 95
    [[ "${arguments[-1]}" == https://toncenter.com/api/v2/sendBoc ]] || fail 'unexpected confirmation HTTP endpoint'
    for ((i=0; i<${#arguments[@]}; i++)); do
      if [[ "${arguments[$i]}" == --data ]]; then payload="${arguments[$((i+1))]}"; fi
    done
    [[ -n "$payload" && -f "$case_dir/signed-7.boc" ]] || fail 'rebroadcast missing the original signed payload'
    decoded="$(printf '%s' "$payload" | jq -er .boc | base64 -d)"
    [[ "$decoded" == "$(cat "$case_dir/signed-7.boc")" ]] || fail 'API rebroadcast changed the signed message'
    [[ "$(cat "$case_dir/seqno")" == 7 ]] || fail 'rebroadcast after an already confirmed payment'
    printf 'api-broadcast 7\n' >>"$events"
    printf 8 >"$case_dir/seqno"
    touch "$case_dir/paid-7"
    printf '{"ok":true,"result":{"@type":"ok"}}\n200'
  }
  main_wallet_send savings "$fixture_first" 1 -n >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 1
  [[ "$(awk '($1 == "broadcast" || $1 == "api-broadcast") && $2 == 7 {n++} END {print n+0}' "$events")" == 2 ]] \
    || fail 'an acknowledged but unconfirmed message was not rebroadcast exactly once'
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'rebroadcasted transfer was not included'
  assert_contains 'receipt 7' "$events"
)

test_matching_receipt_resolves_lost_ack_without_resigning() (
  setup_case lost-ack-receipt
  printf lost-ack >"$case_dir/behavior"
  main_wallet_send savings "$fixture_first" 1 -n >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 1
  [[ "$(awk '$1 == "broadcast" && $2 == 7 {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'rebroadcast a payment already identified by its exact receipt'
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'fixture did not accept the original ambiguous submission'
  assert_contains 'receipt 7' "$events"
)

test_partial_batch_retry_resumes_pending_payload_without_repaying_first() (
  setup_case partial-resume
  printf unconfirmed >"$case_dir/behavior-8"
  assert_failed send_two
  assert_transfer_count 2
  local journal="$MAIN_WALLET_BUNDLE_DIR/.outbox/savings/state.json" pending
  [[ "$(jq -r .next "$journal")" == 1 ]] || fail 'first confirmed recipient was not journaled'
  pending="$(jq -er .pending.path "$journal")"
  cp "$pending" "$case_dir/original-pending.boc"
  wallet_outbox_release
  MODE=auto
  curl() {
    local -a arguments=("$@")
    local payload="" i decoded
    [[ "${arguments[-1]}" != https://toncenter.com/api/v2/getWalletInformation ]] || return 95
    [[ "${arguments[-1]}" == https://toncenter.com/api/v2/sendBoc ]] || fail 'unexpected resume HTTP endpoint'
    for ((i=0; i<${#arguments[@]}; i++)); do
      if [[ "${arguments[$i]}" == --data ]]; then payload="${arguments[$((i+1))]}"; fi
    done
    decoded="$(printf '%s' "$payload" | jq -er .boc | base64 -d)"
    [[ "$decoded" == "$(cat "$case_dir/original-pending.boc")" && "$decoded" == "transfer|8|$fixture_second|4.000000000" ]] \
      || fail 'resumed batch changed the pending authorization'
    [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'resumed an already paid destination'
    printf 'api-broadcast 8\n' >>"$events"
    printf 9 >"$case_dir/seqno"
    touch "$case_dir/paid-8"
    printf '{"ok":true,"result":{"@type":"ok"}}\n200'
  }
  send_two >"$case_dir/resume.out" 2>"$case_dir/resume.err"
  assert_transfer_count 2
  [[ "$(awk '$1 == "broadcast" && $2 == 7 {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'resumed batch repaid its first confirmed recipient'
  [[ "$(jq -r '.complete and (.confirmed|length == 2)' "$journal")" == true ]] \
    || fail 'resumed batch did not durably confirm both recipients'
)

test_changed_unfinished_batch_is_rejected_without_new_payment() (
  setup_case changed-resume
  printf unconfirmed >"$case_dir/behavior"
  assert_failed send_two
  local before
  before="$(awk '$1 == "broadcast" {n++} END {print n+0}' "$events")"
  assert_failed main_wallet_send savings "$fixture_second" 5 -n
  assert_transfer_count 1
  [[ "$(awk '$1 == "broadcast" {n++} END {print n+0}' "$events")" == "$before" ]] \
    || fail 'changed batch submitted another payment'
)

test_corrupted_pending_payload_cannot_be_resent_or_resigned() (
  setup_case corrupt-resume
  printf unconfirmed >"$case_dir/behavior"
  assert_failed send_two
  local journal="$MAIN_WALLET_BUNDLE_DIR/.outbox/savings/state.json" before pending
  before="$(awk '$1 == "broadcast" {n++} END {print n+0}' "$events")"
  pending="$(jq -er .pending.path "$journal")"
  printf 'corruption\n' >>"$pending"
  wallet_outbox_release
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(awk '$1 == "broadcast" {n++} END {print n+0}' "$events")" == "$before" ]] \
    || fail 'resent corrupted pending authorization'
)

test_late_matching_receipt_resumes_without_duplicate_payment() (
  setup_case late-receipt-resume
  printf lost-ack >"$case_dir/behavior"
  touch "$case_dir/receipt-unavailable"
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'fixture did not model the initially ambiguous payment'
  wallet_outbox_release
  rm "$case_dir/receipt-unavailable"
  send_two >"$case_dir/resume.out" 2>"$case_dir/resume.err"
  assert_transfer_count 2
  [[ "$(awk '$1 == "broadcast" && $2 == 7 {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'late receipt recovery repaid its already confirmed destination'
  [[ "$(cat "$case_dir/seqno")" == 9 ]] || fail 'late receipt recovery did not finish the remaining recipient'
)

test_consumed_request_without_outgoing_payment_is_not_counted_as_paid() (
  setup_case consumed-without-payment
  printf consumed-no-payment >"$case_dir/behavior"
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'fixture did not model a consumed external request'
  local journal="$MAIN_WALLET_BUNDLE_DIR/.outbox/savings/state.json"
  [[ "$(jq -r .next "$journal")" == 0 ]] || fail 'seqno advance without outgoing payment was marked paid'
  assert_contains 'consumed without emitting the approved payment' "$case_dir/err"
  assert_failed send_two
  assert_transfer_count 1
  [[ "$(awk '$1 == "broadcast" && $2 == 7 {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'repeated an already consumed request'
  ! grep -Fq -- "$fixture_second" "$events" || fail 'attempted the next recipient after failed outgoing payment'
)

test_next_recipient_uses_receipt_floor_despite_cached_https_seqno() (
  setup_case cached-counter-after-receipt
  curl() {
    local -a arguments=("$@")
    [[ "${arguments[-1]}" == https://toncenter.com/api/v2/getWalletInformation ]] || fail 'unexpected cached-counter HTTP endpoint'
    printf 'http-seqno 7 chain-seqno %s\n' "$(cat "$case_dir/seqno")" >>"$events"
    printf '{"ok":true,"result":{"wallet":true,"account_state":"active","balance":"10000007883","seqno":7}}'
  }
  send_two >"$case_dir/out" 2>"$case_dir/err"
  assert_transfer_count 2
  assert_contains "fift 7 $fixture_first 4.000000000 -n" "$events"
  assert_contains "fift 8 $fixture_second 4.000000000 -n" "$events"
  assert_contains 'http-seqno 7 chain-seqno 8' "$events"
  [[ "$(cat "$case_dir/seqno")" == 9 ]] || fail 'cached account counter caused reuse of a consumed sequence number'
)

test_invalid_send_mode_cannot_sign_stage_or_broadcast() (
  local mode
  for mode in invalid dry-run; do
    setup_case "invalid-mode-$mode"
    MODE="$mode"
    assert_failed send_two
    assert_transfer_count 0
    [[ ! -e "$MAIN_WALLET_BUNDLE_DIR/.outbox/savings/state.json" ]] || fail 'invalid mode created a persistent payment plan'
    ! grep -q '^broadcast \|^api-broadcast \|^fift-init$' "$events" || fail 'invalid mode submitted a message'
  done
)

test_pending_corruption_during_confirmation_never_rebroadcasts() (
  local timing original
  for timing in before-receipt during-receipt; do
    setup_case "confirmation-corruption-$timing"
    printf unconfirmed >"$case_dir/behavior"
    if [[ "$timing" == before-receipt ]]; then
      original="$(declare -f wallet_outbox_receipts)"
      eval "${original/wallet_outbox_receipts ()/fixture_outbox_receipts ()}"
      wallet_outbox_receipts() {
        local pending
        pending="$(jq -er .pending.path "$WALLET_OUTBOX_DIR/state.json")" || return 1
        printf 'corruption after initial broadcast\n' >>"$pending"
        fixture_outbox_receipts
      }
    else
      original="$(declare -f wallet_transaction_receipt)"
      eval "${original/wallet_transaction_receipt ()/fixture_payment_receipt ()}"
      wallet_transaction_receipt() {
        local pending result rc=0
        result="$(fixture_payment_receipt "$@")" || rc=$?
        pending="$(jq -er .pending.path "$WALLET_OUTBOX_DIR/state.json")" || return 1
        printf 'corruption during receipt query\n' >>"$pending"
        [[ -z "$result" ]] || printf '%s' "$result"
        return "$rc"
      }
    fi
    assert_failed send_two
    assert_transfer_count 1
    [[ "$(awk '$1 == "broadcast" && $2 == 7 {n++} END {print n+0}' "$events")" == 1 ]] \
      || fail 'rebroadcast a pending BOC after its checksum changed during confirmation'
    ! grep -Fq -- "$fixture_second" "$events" || fail 'corrupted pending authorization reached a later recipient'
  done
)

test_mismatched_api_network_never_signs_or_broadcasts() (
  local endpoint
  for endpoint in https://testnet.toncenter.com https://other.invalid https://toncenter.com.invalid; do
    setup_case "wrong-api-${endpoint##*/}"
    TONCENTER_URL="$endpoint"
    MODE=auto
    assert_failed send_two
    assert_transfer_count 0
    [[ ! -e "$MAIN_WALLET_BUNDLE_DIR/.outbox/savings/state.json" ]] || fail 'mismatched network created an outgoing plan'
    ! grep -q '^broadcast \|^api-broadcast \|^fift-init$' "$events" || fail 'mismatched API network submitted a message'
  done
)

test_direct_api_transport_rejects_wrong_network() (
  setup_transport_case wrong-api-direct
  TONCENTER_URL=https://testnet.toncenter.com
  assert_failed send_boc_toncenter_once "$transport_boc"
  ! grep -q '^transport-https$' "$events" || fail 'direct API transport broadcast to another network'
)

setup_noisy_send_case() {
  setup_case "$1"
  MODE=auto
  MAIN_WALLET_LITESERVER_SEND_ATTEMPTS=2
  MAIN_WALLET_REBROADCAST_ATTEMPTS=0
  touch "$case_dir/noisy-signing" "$case_dir/noisy-rpc-failures"
  printf accept >"$case_dir/noisy-api-behavior"
  curl() {
    local -a arguments=("$@")
    local payload="" decoded i
    # Read queries deliberately use the fixture's lite-client boundary.
    [[ "${arguments[-1]}" == https://toncenter.com/api/v2/sendBoc ]] || return 95
    for ((i=0; i<${#arguments[@]}; i++)); do
      if [[ "${arguments[$i]}" == --data ]]; then payload="${arguments[$((i+1))]}"; fi
    done
    decoded="$(printf '%s' "$payload" | jq -er .boc | base64 -d)"
    [[ "$decoded" == "transfer|7|$fixture_first|1" ]] \
      || fail 'noisy transport fallback changed the original signed payment'
    printf 'api-attempt\n' >>"$events"
    if [[ "$(cat "$case_dir/noisy-api-behavior")" == reject ]]; then
      printf '{"ok":false,"error":"synthetic API provider rejection"}\n500'
      return 0
    fi
    printf 8 >"$case_dir/seqno"
    touch "$case_dir/paid-7"
    printf '{"ok":true,"result":{"@type":"ok"},"diagnostic":"SYNTHETIC_RAW_API_JSON"}\n200'
  }
}

assert_quiet_confirmed_send() {
  local output
  assert_no_send_diagnostics
  for output in "$case_dir/out" "$case_dir/err"; do
    ! grep -Eq 'Error:|Warning:|\[error\]|SYNTHETIC_RAW_|SYNTHETIC_SIGNING_DUMP|B5EE9C72_SYNTHETIC_BOC_DUMP|external message status is' "$output" \
      || fail "confirmed send printed raw diagnostics or recovered errors in $output"
  done
  cat "$case_dir/out" "$case_dir/err" >"$case_dir/combined"
  assert_contains 'All 1 outgoing payments confirmed.' "$case_dir/combined"
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 8 ]] || fail 'quiet output changed the confirmed chain state'
}

test_recovered_provider_failures_are_quiet_after_payment_confirmation() (
  setup_noisy_send_case quiet-provider-fallback
  main_wallet_send savings "$fixture_first" 1 >"$case_dir/out" 2>"$case_dir/err"
  assert_quiet_confirmed_send
  [[ "$(awk '$1 == "rpc-attempt" {n++} END {print n+0}' "$events")" == 2 ]] \
    || fail 'quiet fallback changed the two lite-server attempts'
  [[ "$(awk '$1 == "api-attempt" {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'quiet fallback changed the successful API attempt'
)

test_successful_lite_server_send_hides_signing_and_ack_dumps() (
  setup_case quiet-ack-success
  touch "$case_dir/noisy-signing" "$case_dir/noisy-rpc-ack"
  MAIN_WALLET_REBROADCAST_ATTEMPTS=0
  main_wallet_send savings "$fixture_first" 1 >"$case_dir/out" 2>"$case_dir/err"
  assert_quiet_confirmed_send
  [[ "$(awk '$1 == "broadcast" {n++} END {print n+0}' "$events")" == 1 ]] \
    || fail 'quiet success changed the single lite-server submission'
)

test_unresolved_provider_failures_keep_the_original_causes() (
  setup_noisy_send_case noisy-final-provider-failure
  printf reject >"$case_dir/noisy-api-behavior"
  assert_failed main_wallet_send savings "$fixture_first" 1
  cat "$case_dir/out" "$case_dir/err" >"$case_dir/combined"
  assert_contains 'synthetic RPC timeout' "$case_dir/combined"
  assert_contains 'synthetic Connection refused' "$case_dir/combined"
  assert_contains 'synthetic API provider rejection' "$case_dir/combined"
  assert_contains 'no exact outgoing-payment receipt' "$case_dir/combined"
  assert_transfer_count 1
  [[ "$(cat "$case_dir/seqno")" == 7 ]] || fail 'failed providers advanced the source sequence'
)

test_ack_without_receipt_still_fails_with_diagnostics() (
  setup_case noisy-ack-unconfirmed
  touch "$case_dir/noisy-signing" "$case_dir/noisy-rpc-ack"
  printf unconfirmed >"$case_dir/behavior"
  MAIN_WALLET_REBROADCAST_ATTEMPTS=0
  assert_failed main_wallet_send savings "$fixture_first" 1
  cat "$case_dir/out" "$case_dir/err" >"$case_dir/combined"
  assert_contains 'SYNTHETIC_RAW_RPC_DEBUG' "$case_dir/combined"
  assert_contains 'external message status is 1' "$case_dir/combined"
  assert_contains 'no exact outgoing-payment receipt' "$case_dir/combined"
  ! grep -Fq 'All 1 outgoing payments confirmed.' "$case_dir/combined" || fail 'ACK-only send was reported as paid'
  assert_transfer_count 1
)

test_signing_failure_preserves_its_diagnostic_cause() (
  setup_case noisy-signing-failure
  touch "$case_dir/noisy-signing"
  printf 42 >"$case_dir/fift-rc"
  assert_failed main_wallet_send savings "$fixture_first" 1
  cat "$case_dir/out" "$case_dir/err" >"$case_dir/combined"
  assert_contains 'Fift synthetic signing error: rejected transfer fixture' "$case_dir/combined"
  assert_contains 'no BOC was submitted' "$case_dir/combined"
  ! grep -q '^broadcast \|^api-attempt$' "$events" || fail 'signing failure broadcast a transfer'
)

test_verbose_send_preserves_signing_and_provider_details() (
  setup_noisy_send_case verbose-provider-fallback
  MAIN_WALLET_VERBOSE=true
  main_wallet_send savings "$fixture_first" 1 >"$case_dir/out" 2>"$case_dir/err"
  cat "$case_dir/out" "$case_dir/err" >"$case_dir/combined"
  assert_contains 'SYNTHETIC_SIGNING_DUMP' "$case_dir/combined"
  assert_contains 'B5EE9C72_SYNTHETIC_BOC_DUMP' "$case_dir/combined"
  assert_contains 'SYNTHETIC_RAW_RPC_DEBUG' "$case_dir/combined"
  assert_contains 'synthetic RPC timeout' "$case_dir/combined"
  assert_contains 'synthetic Connection refused' "$case_dir/combined"
  assert_contains 'SYNTHETIC_RAW_API_JSON' "$case_dir/combined"
  assert_contains 'All 1 outgoing payments confirmed.' "$case_dir/combined"
  assert_transfer_count 1
)

test_active_wallet_confirms_each_transfer
test_funded_uninit_deploys_before_transfer
test_rejected_transfer_stops_the_batch
test_unconfirmed_transfer_stops_the_batch
test_unconfirmed_deployment_never_transfers
test_mismatched_deployment_identity_never_transfers
test_unusable_source_state_never_transfers
test_unfunded_uninit_never_deploys
test_failed_init_generation_never_transfers
test_replacement_init_key_is_rejected
test_legacy_version_is_derived_from_matching_contract
test_wrong_legacy_contract_does_not_gain_version
test_concurrent_source_sequence_stops_the_batch
test_single_send_requires_confirmation
test_lost_acknowledgement_stops_before_later_recipients
test_invalid_arguments_cannot_trigger_deployment
test_fift_failure_never_broadcasts_stale_boc
test_liteclient_zero_exit_without_ack_uses_api_fallback
test_liteclient_zero_exit_without_ack_fails_in_liteserver_mode
test_positive_external_message_ack_is_required
test_positive_external_message_ack_on_stderr_is_supported
test_unsuccessful_external_message_status_uses_api_fallback
test_failed_rpc_with_ack_is_not_successful_transport
test_missing_rpc_ack_and_rejected_api_is_failure
test_batch_recovers_missing_second_ack_via_api_before_next_recipient
test_actual_liteclient_invocation_keeps_send_acknowledgement_visible
test_acknowledged_but_not_included_transfer_rebroadcasts_identical_boc
test_matching_receipt_resolves_lost_ack_without_resigning
test_partial_batch_retry_resumes_pending_payload_without_repaying_first
test_changed_unfinished_batch_is_rejected_without_new_payment
test_corrupted_pending_payload_cannot_be_resent_or_resigned
test_late_matching_receipt_resumes_without_duplicate_payment
test_consumed_request_without_outgoing_payment_is_not_counted_as_paid
test_next_recipient_uses_receipt_floor_despite_cached_https_seqno
test_invalid_send_mode_cannot_sign_stage_or_broadcast
test_pending_corruption_during_confirmation_never_rebroadcasts

test_mismatched_api_network_never_signs_or_broadcasts
test_direct_api_transport_rejects_wrong_network
test_recovered_provider_failures_are_quiet_after_payment_confirmation
test_successful_lite_server_send_hides_signing_and_ack_dumps
test_unresolved_provider_failures_keep_the_original_causes
test_ack_without_receipt_still_fails_with_diagnostics
test_signing_failure_preserves_its_diagnostic_cause
test_verbose_send_preserves_signing_and_provider_details

echo 'main wallet send tests passed (52 scenarios).'
