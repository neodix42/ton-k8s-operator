#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
memory_root="$(mktemp -d /dev/shm/kubeton-main-wallet-memory.XXXXXX)"
disk_root="$(mktemp -d "$repo_root/.main-wallet-memory-test.XXXXXX")"
trap 'rm -rf "$memory_root" "$disk_root"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
# The development host may use swap. Replace only the read-only proc source
# in this sourced test copy; production has no switch to bypass its check.
printf 'Filename Type Size Used Priority\n' >"$memory_root/proc-swaps"
source <(sed "s|/proc/swaps|$memory_root/proc-swaps|g" "$repo_root/charts/ton-k8s-operator/main-wallet.sh")

MAIN_WALLET_DIR="$memory_root/runtime"
MAIN_WALLET_BUNDLE_DIR="$disk_root/bundle"
mkdir -p "$MAIN_WALLET_DIR" "$MAIN_WALLET_BUNDLE_DIR/.outbox" "$disk_root/forbidden"
export TMPDIR="$disk_root/forbidden"
printf 'synthetic wallet private-key fixture\n' >"$MAIN_WALLET_DIR/savings.pk"
printf 'synthetic address\n' >"$MAIN_WALLET_DIR/savings.addr"
printf 'durable public payment journal\n' >"$MAIN_WALLET_BUNDLE_DIR/.outbox/state"

# Only Vault's network boundary is mocked. Encryption, compression, filesystem
# type checks and cleanup run for real; all synthetic plaintext lives on tmpfs.
vault_encrypt_data_key() {
  printf '%s' "$1" >"$memory_root/data-key"
  printf 'synthetic-wrapped-key'
}
vault_decrypt_data_key() {
  [[ "$1" == synthetic-wrapped-key && "$2" == passphrase-b64-v1 ]] || return 1
  cat "$memory_root/data-key"
}
mktemp() {
  printf '%s\n' "$*" >>"$memory_root/staging-paths"
  command mktemp "$@"
}

main_wallet_require_memory_runtime
scratch="$(main_wallet_scratch_directory)"
printf 'stale diagnostic fixture; exclude from exported signing-key archive\n' >"$scratch/stale"
backup_bundle
[[ -s "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE" ]] || fail 'encrypted bundle missing'
[[ -s "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_META_FILE" ]] || fail 'wrapped key metadata missing'
DATA_KEY_B64="$(cat "$memory_root/data-key")"; export DATA_KEY_B64
openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -pass env:DATA_KEY_B64 \
  -in "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE" -out "$memory_root/check.tar.gz"
tar -tzf "$memory_root/check.tar.gz" >"$memory_root/archive-members"
grep -Fxq './savings.pk' "$memory_root/archive-members" || fail 'backup omitted wallet'
if grep -Fq '.scratch' "$memory_root/archive-members"; then fail 'backup recursively archived plaintext staging'; fi
if grep -Rq 'synthetic wallet private-key fixture' "$MAIN_WALLET_BUNDLE_DIR"; then fail 'plaintext key reached durable bundle storage'; fi

printf 'stale runtime wallet\n' >"$MAIN_WALLET_DIR/savings.pk"
printf 'stale wallet must disappear\n' >"$MAIN_WALLET_DIR/obsolete.pk"
restore_bundle
[[ "$(cat "$MAIN_WALLET_DIR/savings.pk")" == 'synthetic wallet private-key fixture' ]] || fail 'restored key changed'
[[ ! -e "$MAIN_WALLET_DIR/obsolete.pk" ]] || fail 'restore retained stale wallet'
[[ "$(cat "$MAIN_WALLET_BUNDLE_DIR/.outbox/state")" == 'durable public payment journal' ]] || fail 'restore changed durable outbox'

# A failed decrypt/extract must remove any partially written plaintext and
# preserve the currently running wallet rather than continuing the action.
cp "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE" "$memory_root/saved.enc"
printf 'corrupt encrypted bundle\n' >"$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE"
if restore_bundle >"$memory_root/corrupt.out" 2>&1; then fail 'corrupt bundle restored successfully'; fi
[[ "$(cat "$MAIN_WALLET_DIR/savings.pk")" == 'synthetic wallet private-key fixture' ]] || fail 'failed restore replaced live key'
cp "$memory_root/saved.enc" "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE"
if find "$scratch" -mindepth 1 -maxdepth 1 -name 'work.*' | read -r _; then fail 'plaintext staging remained after backup/restore'; fi

# Refuse links before replacing a valid encrypted bundle or extracting state.
# A link inside an otherwise memory-backed wallet must not redirect a later
# signer to a disk path.
ln -s "$disk_root/forbidden" "$MAIN_WALLET_DIR/unsafe-link"
if backup_bundle >"$memory_root/link-backup.out" 2>&1; then fail 'backup accepted a link'; fi
cmp -s "$memory_root/saved.enc" "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE" || fail 'unsafe backup replaced valid ciphertext'
mkdir "$memory_root/unsafe-archive"
ln -s "$disk_root/forbidden" "$memory_root/unsafe-archive/escape"
tar -czf "$memory_root/unsafe.tar.gz" -C "$memory_root/unsafe-archive" .
openssl enc -aes-256-cbc -pbkdf2 -md sha256 -pass env:DATA_KEY_B64 \
  -in "$memory_root/unsafe.tar.gz" -out "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE"
if restore_bundle >"$memory_root/link-restore.out" 2>&1; then fail 'restore accepted a link'; fi
[[ "$(cat "$MAIN_WALLET_DIR/savings.pk")" == 'synthetic wallet private-key fixture' ]] || fail 'unsafe archive changed live wallet'
[[ ! -e "$MAIN_WALLET_DIR/escape" ]] || fail 'unsafe archive was extracted'
rm "$MAIN_WALLET_DIR/unsafe-link"
cp "$memory_root/saved.enc" "$MAIN_WALLET_BUNDLE_DIR/$MAIN_WALLET_BUNDLE_FILE"

# Every generic scratch helper must ignore TMPDIR and choose the runtime
# explicitly; the durable public outbox intentionally keeps its own paths.
temporary="$(main_wallet_temporary_file)"
[[ "$temporary" == "$scratch"/file.* ]] || fail 'temporary file escaped runtime'
rm "$temporary"
[[ -z "$(find "$disk_root/forbidden" -mindepth 1 -print -quit)" ]] || fail 'TMPDIR fallback wrote to disk'
while IFS= read -r invocation; do
  [[ "$invocation" == "$scratch"/file.* || "$invocation" == "-d $scratch"/work.* ]] || fail "unsafe temporary path: $invocation"
done <"$memory_root/staging-paths"

# An ordinary filesystem, even one selected through a runtime override, must
# fail before decryption, key generation, or a caller-provided action can run.
original_runtime="$MAIN_WALLET_DIR"
MAIN_WALLET_DIR="$disk_root/unsafe-runtime"
run_action() { touch "$disk_root/action-ran"; }
if run_with_persistence create >"$memory_root/non-memory.out" 2>&1; then fail 'accepted disk-backed runtime'; fi
grep -Fq 'not tmpfs' "$memory_root/non-memory.out" || fail 'missing memory-runtime error'
[[ ! -e "$disk_root/action-ran" ]] || fail 'generated keys before validating runtime'
if backup_bundle >"$memory_root/non-memory-backup.out" 2>&1; then fail 'backup accepted disk-backed runtime'; fi
MAIN_WALLET_DIR="$memory_root/linked-runtime"
ln -s "$original_runtime" "$MAIN_WALLET_DIR"
if main_wallet_require_memory_runtime >"$memory_root/symlink.out" 2>&1; then fail 'accepted symlink runtime'; fi
MAIN_WALLET_DIR="$original_runtime"
printf 'Filename Type Size Used Priority\n/synthetic-swap file 1024 0 -2\n' >"$memory_root/proc-swaps"
if main_wallet_require_memory_runtime >"$memory_root/swap.out" 2>&1; then fail 'accepted swap-enabled worker'; fi
grep -Fq 'swap disabled' "$memory_root/swap.out" || fail 'missing swap error'
printf 'Filename Type Size Used Priority\n' >"$memory_root/proc-swaps"
rm -rf "$scratch"
ln -s "$disk_root/forbidden" "$scratch"
if backup_bundle >"$memory_root/scratch-symlink.out" 2>&1; then fail 'accepted scratch symlink to disk'; fi
[[ -z "$(find "$disk_root/forbidden" -mindepth 1 -print -quit)" ]] || fail 'scratch symlink wrote to disk'

echo 'Main-wallet memory tests passed: tmpfs-only staging, real encrypted round-trip, cleanup, no TMPDIR fallback, disk/symlink/swap refusal, and durable outbox preserved.'
