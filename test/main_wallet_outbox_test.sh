#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/charts/ton-k8s-operator/main-wallet.sh"
test_dir="$(mktemp -d)"
trap 'wallet_outbox_release; rm -r "$test_dir"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
reject() { if "$@" >"$case_dir/rejected.out" 2>"$case_dir/rejected.err"; then fail "unexpected success: $*"; fi; }
source_address="0:$(printf '%064d' 1)"
first="-1:$(printf '%064d' 2)"
second="-1:$(printf '%064d' 3)"
body_hash="$(printf '%064d' 4)"
expiry=1999999999

setup() {
  wallet_outbox_release
  case_dir="$test_dir/$1"
  MAIN_WALLET_BUNDLE_DIR="$case_dir/pvc"
  MAIN_WALLET_DIR="$case_dir/runtime"
  no_bounce_flag=-n
  mkdir -p "$MAIN_WALLET_BUNDLE_DIR" "$MAIN_WALLET_DIR"
  printf 'synthetic signed authorization; no private key\n' > "$MAIN_WALLET_DIR/query.boc"
}
begin() { wallet_outbox_begin savings "$source_address" mainnet 42 4 "$first" "$second"; }
stage() { wallet_outbox_stage 0 7 "$expiry" "$body_hash" "$MAIN_WALLET_DIR/query.boc" "$first" 4000000000; }

test_survives_runtime_loss_and_helper_restart() (
  setup restart
  begin; stage
  before="$(wallet_outbox_pending)"
  IFS=$'\t' read -r seq ttl hash payload destination amount index <<< "$before"
  [[ "$seq" == 7 && "$ttl" == "$expiry" && "$hash" == "$body_hash" && "$destination" == "$first" && "$amount" == 4000000000 && "$index" == 0 ]] || fail 'pending TSV mismatch'
  cmp "$MAIN_WALLET_DIR/query.boc" "$payload" || fail 'persisted BOC changed'
  wallet_outbox_release
  rm -r "$MAIN_WALLET_DIR"
  begin
  [[ "$WALLET_OUTBOX_RESUMED" == true && "$WALLET_OUTBOX_INDEX" == 0 && "$(wallet_outbox_pending)" == "$before" ]] || fail 'lost unresolved exact payload'
)

test_partial_batch_resume_skips_confirmed_recipient() (
  setup partial
  begin; stage; wallet_outbox_confirm 0 transaction-first
  [[ "$WALLET_OUTBOX_INDEX" == 1 && -z "$(wallet_outbox_pending)" ]] || fail 'confirmation did not advance one index'
  wallet_outbox_release; begin
  [[ "$WALLET_OUTBOX_RESUMED" == true && "$WALLET_OUTBOX_INDEX" == 1 ]] || fail 'restarted batch from first recipient'
  wallet_outbox_stage 1 8 "$expiry" "$body_hash" "$MAIN_WALLET_DIR/query.boc" "$second" 4000000000
  wallet_outbox_confirm 1 transaction-second
  wallet_outbox_complete
  [[ "$(jq -r '.confirmed|length' "$WALLET_OUTBOX_DIR/state.json")" == 2 ]] || fail 'missing receipts'
)

test_completed_identical_request_is_a_new_intent() (
  setup completed
  begin; original="$(jq -r '.batch_id' "$WALLET_OUTBOX_DIR/state.json")"
  stage; wallet_outbox_confirm 0 tx-first
  wallet_outbox_stage 1 8 "$expiry" "$body_hash" "$MAIN_WALLET_DIR/query.boc" "$second" 4000000000
  wallet_outbox_confirm 1 tx-second; wallet_outbox_complete
  begin
  [[ "$WALLET_OUTBOX_RESUMED" == false && "$WALLET_OUTBOX_INDEX" == 0 && "$(jq -r '.batch_id' "$WALLET_OUTBOX_DIR/state.json")" != "$original" ]] || fail 'completed payment was permanently deduplicated'
  [[ -f "$WALLET_OUTBOX_DIR/$original/final-state.json" ]] || fail 'completed history missing'
)

test_different_pending_request_is_rejected() (
  setup changed
  begin; stage
  reject wallet_outbox_begin savings "$source_address" mainnet 42 5 "$first" "$second"
  reject wallet_outbox_begin savings "$source_address" mainnet 42 4 "$second" "$first"
  reject wallet_outbox_begin savings "$source_address" testnet 42 4 "$first" "$second"
  no_bounce_flag=''
  reject begin
)

test_unresolved_signed_payload_cannot_be_replaced() (
  setup replacement
  begin; stage
  original="$(wallet_outbox_pending)"
  reject wallet_outbox_stage 0 7 2000000000 "$body_hash" "$MAIN_WALLET_DIR/query.boc" "$first" 4000000000
  printf 'different payload\n' > "$MAIN_WALLET_DIR/query.boc"
  reject stage
  [[ "$(wallet_outbox_pending)" == "$original" ]] || fail 'replaced unresolved authorization'
)

test_recovers_commit_between_entry_and_state_publication() (
  setup publication-crash
  begin
  eval "$(declare -f wallet_outbox_atomic_json | sed '1s/wallet_outbox_atomic_json/original_atomic_json/')"
  wallet_outbox_atomic_json() { return 1; }
  reject stage
  [[ "$(jq -r '.pending' "$WALLET_OUTBOX_DIR/state.json")" == null ]] || fail 'fault did not precede state publication'
  eval "$(declare -f original_atomic_json | sed '1s/original_atomic_json/wallet_outbox_atomic_json/')"
  wallet_outbox_release; begin
  pending="$(wallet_outbox_pending)"
  [[ "$pending" == 7$'\t'* && "$WALLET_OUTBOX_INDEX" == 0 ]] || fail 'did not recover already committed payload'
)

test_confirmation_failure_keeps_pending_exact_payload() (
  setup confirm-crash
  begin; stage
  original="$(wallet_outbox_pending)"
  eval "$(declare -f wallet_outbox_atomic_json | sed '1s/wallet_outbox_atomic_json/original_atomic_json/')"
  wallet_outbox_atomic_json() { return 1; }
  reject wallet_outbox_confirm 0 transaction-first
  eval "$(declare -f original_atomic_json | sed '1s/original_atomic_json/wallet_outbox_atomic_json/')"
  wallet_outbox_release; begin
  [[ "$(wallet_outbox_pending)" == "$original" ]] || fail 'failed confirmation changed pending identity'
  wallet_outbox_confirm 0 transaction-first
  wallet_outbox_confirm 0 transaction-first
  reject wallet_outbox_confirm 0 conflicting-transaction
  [[ "$WALLET_OUTBOX_INDEX" == 1 ]] || fail 'confirmation repeated or lost'
)

test_corruption_is_not_treated_as_an_unpaid_new_request() (
  setup corrupt
  begin; stage
  payload="$(wallet_outbox_pending | cut -f4)"
  printf 'tampered\n' >> "$payload"
  reject wallet_outbox_pending
  reject begin
)

test_cannot_complete_with_unconfirmed_recipients() (
  setup incomplete
  begin
  reject wallet_outbox_complete
  stage; reject wallet_outbox_complete
  wallet_outbox_confirm 0 tx-first; reject wallet_outbox_complete
)

test_plan_and_payload_are_private_and_contain_no_key_material() (
  setup permissions
  begin; stage
  payload="$(wallet_outbox_pending | cut -f4)"
  [[ "$(stat -c '%a' "$WALLET_OUTBOX_DIR")" == 700 && "$(stat -c '%a' "$WALLET_OUTBOX_DIR/state.json")" == 600 && "$(stat -c '%a' "$payload")" == 600 ]] || fail 'outgoing permissions are too broad'
  ! grep -Eq 'private_key|VAULT_TOKEN|wrapped_key' "$WALLET_OUTBOX_DIR/state.json" || fail 'journal contains key material'
)

test_missing_flock_fails_before_creating_a_journal() (
  setup dependency
  require_bin() { [[ "$1" != flock ]]; }
  reject begin
  [[ ! -e "$MAIN_WALLET_BUNDLE_DIR/.outbox" ]] || fail 'created outgoing state without locking capability'
)

test_wallet_alias_cannot_bypass_unresolved_source_batch() (
  setup alias
  begin; stage; wallet_outbox_release
  reject wallet_outbox_begin alias "$source_address" mainnet 42 4 "$first" "$second"
)

test_kernel_lock_blocks_another_helper_and_releases_after_death() (
  setup locking
  mkfifo "$case_dir/control"
  bash -euo pipefail -c '
    source "$1"
    MAIN_WALLET_BUNDLE_DIR="$2"
    no_bounce_flag=-n
    wallet_outbox_begin savings "$3" mainnet 42 4 "$4" "$5"
    exec 3<>"$6/control"
    : > "$6/locked"
    read -r -t 20 <&3 || true
  ' _ "$repo_root/charts/ton-k8s-operator/main-wallet.sh" "$MAIN_WALLET_BUNDLE_DIR" "$source_address" "$first" "$second" "$case_dir" &
  holder=$!
  trap 'kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true' EXIT
  deadline=$((SECONDS+5))
  while [[ ! -f "$case_dir/locked" ]] && (( SECONDS < deadline )); do sleep 0.05; done
  [[ -f "$case_dir/locked" ]] || fail 'lock holder never became ready'
  reject wallet_outbox_begin alias "$source_address" mainnet 42 4 "$first" "$second"
  grep -Fq 'source wallet outgoing lock' "$case_dir/rejected.err" || fail 'concurrent alias did not contend on source lock'
  kill "$holder"; wait "$holder" 2>/dev/null || true
  begin
  [[ "$WALLET_OUTBOX_RESUMED" == true ]] || fail 'kernel did not release lock after helper termination'
  trap - EXIT
)

test_expiry_keeps_old_counter_and_every_signed_receipt_hash() (
  setup expiration
  begin; stage
  proof="$(jq -nc --argjson time "$((expiry+11))" '{masterchain_seqno:123,gen_utime:$time,wallet_seqno:7}')"
  wallet_outbox_expire 0 "$proof"
  [[ "$WALLET_OUTBOX_INDEX" == 0 && -z "$(wallet_outbox_pending)" && "$(wallet_outbox_retry_seqno)" == 7 ]] || fail 'expiration consumed recipient or forgot old counter'
  [[ "$(wallet_outbox_receipts)" == "$body_hash"$'\t'"$first"$'\t4000000000' ]] || fail 'retired receipt disappeared'
  archive="$(jq -r '.expired[0].archive_directory' "$WALLET_OUTBOX_DIR/state.json")"
  [[ -s "$archive/entry/payload.boc" ]] || fail 'retired signed authorization was not archived'
  replacement_hash="$(printf '%064d' 5)"
  printf 'replacement signed authorization\n' > "$MAIN_WALLET_DIR/query.boc"
  reject wallet_outbox_stage 0 8 "$((expiry+300))" "$replacement_hash" "$MAIN_WALLET_DIR/query.boc" "$first" 4000000000
  wallet_outbox_stage 0 7 "$((expiry+300))" "$replacement_hash" "$MAIN_WALLET_DIR/query.boc" "$first" 4000000000
  [[ "$(wallet_outbox_receipts | wc -l)" == 2 ]] || fail 'did not retain both exact receipt hashes'
  reject wallet_outbox_expire 0 "$proof"
  wallet_outbox_confirm 0 old-attempt-transaction "$body_hash"
  [[ "$(jq -r '.confirmed[0].body_hash' "$WALLET_OUTBOX_DIR/state.json")" == "$body_hash" && "$WALLET_OUTBOX_INDEX" == 1 ]] || fail 'confirmation audit used wrong attempt hash'
)

test_expiration_requires_bound_pinned_counter_and_time() (
  setup expiration-proof
  begin; stage
  original="$(wallet_outbox_pending)"
  reject wallet_outbox_expire 0 '{"masterchain_seqno":123,"gen_utime":2100000000,"wallet_seqno":8}'
  proof="$(jq -nc --argjson time "$((expiry+10))" '{masterchain_seqno:123,gen_utime:$time,wallet_seqno:7}')"
  reject wallet_outbox_expire 0 "$proof"
  reject wallet_outbox_expire 0 '{"gen_utime":2100000000,"wallet_seqno":7}'
  [[ "$(wallet_outbox_pending)" == "$original" ]] || fail 'invalid expiration proof changed pending payload'
)

test_expiration_publication_crash_does_not_resurrect_old_payload() (
  setup expiration-crash
  begin; stage
  proof="$(jq -nc --argjson time "$((expiry+11))" '{masterchain_seqno:123,gen_utime:$time,wallet_seqno:7}')"
  mv() { if [[ "${2:-}" == */expired-*/entry ]]; then return 1; fi; command mv "$@"; }
  reject wallet_outbox_expire 0 "$proof"
  [[ "$(jq -r '.pending' "$WALLET_OUTBOX_DIR/state.json")" == null && "$(jq '.expired|length' "$WALLET_OUTBOX_DIR/state.json")" == 1 ]] || fail 'fault did not occur after expiration journal commit'
  unset -f mv
  wallet_outbox_release
  rm -r "$MAIN_WALLET_DIR"
  begin
  [[ -z "$(wallet_outbox_pending)" && "$(wallet_outbox_retry_seqno)" == 7 && "$WALLET_OUTBOX_INDEX" == 0 ]] || fail 'crash resurrected expired payload or allocated another counter'
  wallet_outbox_confirm 0 delayed-old-receipt "$body_hash"
  [[ "$WALLET_OUTBOX_INDEX" == 1 ]] || fail 'retired receipt could not resolve after crash'
)

test_survives_runtime_loss_and_helper_restart
test_partial_batch_resume_skips_confirmed_recipient
test_completed_identical_request_is_a_new_intent
test_different_pending_request_is_rejected
test_unresolved_signed_payload_cannot_be_replaced
test_recovers_commit_between_entry_and_state_publication
test_confirmation_failure_keeps_pending_exact_payload
test_corruption_is_not_treated_as_an_unpaid_new_request
test_cannot_complete_with_unconfirmed_recipients
test_plan_and_payload_are_private_and_contain_no_key_material
test_missing_flock_fails_before_creating_a_journal
test_wallet_alias_cannot_bypass_unresolved_source_batch
test_kernel_lock_blocks_another_helper_and_releases_after_death
test_expiry_keeps_old_counter_and_every_signed_receipt_hash
test_expiration_requires_bound_pinned_counter_and_time
test_expiration_publication_crash_does_not_resurrect_old_payload
echo 'main wallet outbox tests passed (16 scenarios).'
