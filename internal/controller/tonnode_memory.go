package controller

import (
	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/utils/ptr"
)

func desiredSecretMemoryVolumes(node *tonv1alpha1.TonNode) []corev1.Volume {
	spec := node.Spec.KeyManagement.InMemory
	volumes := make([]corev1.Volume, 0, 4)
	for _, item := range []struct{ name, size, fallback string }{
		{controllerTmpfsVolume, spec.ControllerSizeLimit, "512Mi"},
		{keyringTmpfsVolume, spec.KeyringSizeLimit, "128Mi"},
		{secretScratchVolume, spec.StagingSizeLimit, "2Gi"},
		{runtimeRunVolume, spec.StagingSizeLimit, "2Gi"},
	} {
		volumes = append(volumes, corev1.Volume{Name: item.name, VolumeSource: corev1.VolumeSource{
			EmptyDir: &corev1.EmptyDirVolumeSource{Medium: corev1.StorageMediumMemory,
				SizeLimit: ptr.To(parseQuantityOrDefault(item.size, item.fallback))},
		}})
	}
	return volumes
}

// Check every plaintext staging operation. A missing mount or unexpected image
// must fail rather than silently falling back to a node's writable layer.
const keyMemoryGuardScript = `
set -eu
ulimit -c 0
for secret_path in /tmp /var/ton-work/keys /var/ton-work/controller /var/ton-work/controller/mytoncore/wallets /var/ton-work/db/keyring; do
  mkdir -p "$secret_path"
  if [ -L "$secret_path" ] || [ "$(stat -f -c %T "$secret_path")" != tmpfs ]; then
    echo "Refusing plaintext key operation: required memory mount is absent: $secret_path" >&2
    exit 1
  fi
done
export TMPDIR=/tmp
if ! awk 'NR > 1 { used = 1 } END { exit used }' /proc/swaps; then
  echo "Refusing in-memory secrets on a worker with swap enabled; disable swap before restarting this Pod" >&2
  exit 1
fi
`

const validateKeyArchiveScript = `
validate_key_archive() {
python3 - "$1" <<'KEY_ARCHIVE_PY'
import pathlib
import sys
import tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    for member in archive:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
            sys.exit('Unsafe encrypted bundle member; plaintext state was preserved')
KEY_ARCHIVE_PY
}
`

const requestSecretCheckpointScript = `
set -eu
ulimit -c 0
request_id=$(cat /proc/sys/kernel/random/uuid)
test -d /tmp/key-backup.requests && test -d /tmp/key-backup.acks
: > "/tmp/key-backup.requests/$request_id"
trap 'rm -f "/tmp/key-backup.requests/$request_id" "/tmp/key-backup.acks/$request_id"' EXIT
for attempt in $(seq 1 60); do
  # A sidecar preStop can complete the final flush before its polling loop
  # sees this request. Only the shutdown caller uses this script.
  if [ -f /tmp/key-runtime.quiesced ] && [ -s /tmp/key-backup.shutdown.done ]; then
    exit 0
  fi
  if [ -s "/tmp/key-backup.acks/$request_id" ]; then
    test "$(cat "/tmp/key-backup.acks/$request_id")" = ok
    exit $?
  fi
  sleep 1
done
echo "Encrypted secret checkpoint did not finish before shutdown" >&2
exit 1
`

const secretStateFingerprintScript = `
secret_state_fingerprint() {
  python3 - "${1:-$KEYS_DIR}" "${2:-$CONTROLLER_DIR}" "${3:-$DB_KEYRING_DIR}" "${4:-$DB_CONFIG_FILE}" <<'FINGERPRINT_PY'
import hashlib
import os
import pathlib
import sys
digest = hashlib.sha256()
def include(path, label):
    if path.is_symlink():
        raise ValueError('Symlink in secret state; refusing encrypted checkpoint')
    if path.is_dir():
        for child in sorted(path.iterdir()):
            include(child, label + '/' + child.name)
    elif path.is_file():
        if path.name == '.container.lock' or path.name.endswith('.log'):
            return
        digest.update(label.encode() + b'\0')
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1048576), b''):
                digest.update(block)
        digest.update(b'\0')
    else:
        raise ValueError('Unsupported file in secret state; refusing encrypted checkpoint')
for index, name in enumerate(sys.argv[1:]):
    path = pathlib.Path(name)
    if path.exists() or path.is_symlink():
        include(path, str(index))
print(digest.hexdigest())
FINGERPRINT_PY
}
`

// Read the underlying PVC through a separate mount. Never remove an existing
// identity until its encrypted replacement has passed an actual decrypt.
const keyMigrationPrepareScript = keyBundlePublicationScript + keyMemoryGuardScript + keyBackupFunctionsScript + `
MIGRATION_SOURCE=/mnt/ton-work
MIGRATION_PENDING=false
for source_name in controller keys db/keyring; do
  [ ! -L "$MIGRATION_SOURCE/$source_name" ] || { echo "Unsafe legacy secret path; original data preserved" >&2; exit 1; }
done
if [ -d "$MIGRATION_SOURCE/controller" ] && [ -n "$(find "$MIGRATION_SOURCE/controller" -mindepth 1 -print -quit)" ]; then
  MIGRATION_PENDING=true
fi
for source_name in keys db/keyring; do
  if [ -d "$MIGRATION_SOURCE/$source_name" ] && [ -n "$(find "$MIGRATION_SOURCE/$source_name" -mindepth 1 -print -quit)" ]; then
    MIGRATION_PENDING=true
  fi
done
if [ -f "$BUNDLE_DIR/.historical-plaintext-exposure" ]; then
  # Cleanup can be interrupted after some originals have already been removed.
  # Never replace the verified snapshot with those incomplete remnants.
  recover_key_bundle_publication
  if ! bundle_present; then
    echo "Historical plaintext migration marker exists but encrypted bundle is missing; original data preserved" >&2
    exit 1
  fi
elif [ "$MIGRATION_PENDING" = true ] && [ ! -f "$BUNDLE_DIR/.restore-controller-state" ]; then
  recover_key_bundle_publication
  if bundle_present; then
    # Previous managed Pods already kept wallets and console keys in RAM.
    # Their only durable copies are in this bundle. Verify and seed them before
    # overlaying the newer controller settings from the old persistent layout.
    (
      _KEY_MIGRATION_SEED=1
` + keyRestoreScript + `
    )
  fi
  python3 - "$MIGRATION_SOURCE" "$CONTROLLER_DIR" "$KEYS_DIR" "$DB_KEYRING_DIR" <<'MERGE_LEGACY_PY'
import filecmp
import pathlib
import shutil
import sys
source, controller, keys, keyring = map(pathlib.Path, sys.argv[1:])
def merge(old, new, preserve=False, skip_wallets=False):
    if not old.exists():
        return
    if old.is_symlink():
        raise ValueError('Unsafe legacy secret path; original data preserved')
    if old.is_dir():
        new.mkdir(parents=True, exist_ok=True)
        for child in old.iterdir():
            if skip_wallets and child == source / 'controller/mytoncore/wallets':
                continue
            merge(child, new / child.name, preserve, skip_wallets)
    elif old.is_file():
        if preserve and new.exists():
            if not new.is_file() or not filecmp.cmp(old, new, shallow=False):
                raise ValueError('Conflicting legacy and encrypted identity files; originals preserved. Select a verified recovery bundle explicitly.')
        else:
            shutil.copy2(old, new)
    else:
        raise ValueError('Unsupported legacy secret file; original data preserved')
merge(source / 'controller', controller, skip_wallets=True)
# Initialization markers belong to the current persistent controller state,
# not to the older bundle used only to seed its memory-backed private files.
for marker in ('.initializing', 'initialized.json'):
    if (source / 'controller').is_dir() and not (source / 'controller' / marker).exists():
        (controller / marker).unlink(missing_ok=True)
merge(source / 'controller/mytoncore/wallets', controller / 'mytoncore/wallets', preserve=True)
merge(source / 'keys', keys, preserve=True)
merge(source / 'db/keyring', keyring, preserve=True)
MERGE_LEGACY_PY
  if [ ! -s "$DB_CONFIG_FILE" ] && [ -s "$MIGRATION_SOURCE/db/config.json" ]; then
    cp -a "$MIGRATION_SOURCE/db/config.json" "$DB_CONFIG_FILE"
  fi
  if ! perform_backup; then
    echo "Cannot encrypt complete existing controller identity; original plaintext was preserved. Complete initialization with the previous operator before retrying." >&2
    exit 1
  fi
  echo "Existing controller and keyring copied to memory and encrypted; verifying restore before cleanup"
fi
`

const keyMigrationCleanupScript = `
if [ "${MIGRATION_PENDING:-false}" = true ]; then
  # The preceding restore unwrapped/decrypted this bundle successfully. Only
  # unlink the known originals now; do not pretend this sanitizes old media.
  date -u +%Y-%m-%dT%H:%M:%SZ > "$BUNDLE_DIR/.historical-plaintext-exposure"
  sync
  for source_name in controller keys db/keyring; do
    [ ! -L "$MIGRATION_SOURCE/$source_name" ] || { echo "Legacy secret path changed; original data preserved" >&2; exit 1; }
    if [ -d "$MIGRATION_SOURCE/$source_name" ]; then
      find "$MIGRATION_SOURCE/$source_name" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
  done
  sync
fi
if [ -f "$BUNDLE_DIR/.historical-plaintext-exposure" ]; then
  echo "SECURITY: legacy live plaintext files were unlinked after encrypted recovery was verified. Historical disk blocks, snapshots and backups were NOT securely erased; retire or sanitize old storage for that assurance." >&2
fi
`

// Shared unwrap code is also used to verify a newly wrapped key before publication.
const keyUnwrapScript = `
vault_decrypt() {
  wrapped="$1"
  need_bin curl
  need_bin jq
  if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_TOKEN:-}" ] || [ -z "${VAULT_TRANSIT_KEY:-}" ]; then
    echo "vault provider requires VAULT_ADDR, VAULT_TOKEN and VAULT_TRANSIT_KEY" >&2
    return 1
  fi

  payload="$(printf '{"ciphertext":"%s"}' "$wrapped")"
  if [ -n "${VAULT_NAMESPACE:-}" ]; then
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  else
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  fi

  printf '%s' "$resp" | jq -r '.data.plaintext' | base64 -d
}

kms_decrypt() {
  wrapped="$1"
  case "${KMS_VENDOR:-}" in
    aws)
      need_bin aws
      if [ -z "${KMS_KEY_ID:-}" ]; then
        echo "kms provider requires KMS_KEY_ID for aws" >&2
        return 1
      fi
      blob_file="$(mktemp)"
      printf '%s' "$wrapped" | base64 -d >"$blob_file"
      plaintext_b64="$(aws kms decrypt --key-id "$KMS_KEY_ID" --ciphertext-blob "fileb://${blob_file}" --query Plaintext --output text)"
      rm -f "$blob_file"
      printf '%s' "$plaintext_b64" | base64 -d
      ;;
    gcp)
      need_bin gcloud
      if [ -z "${KMS_PROJECT_ID:-}" ] || [ -z "${KMS_LOCATION:-}" ] || [ -z "${KMS_KEY_RING:-}" ] || [ -z "${KMS_KEY_ID:-}" ]; then
        echo "gcp kms requires KMS_PROJECT_ID, KMS_LOCATION, KMS_KEY_RING and KMS_KEY_ID" >&2
        return 1
      fi
      cipher_file="$(mktemp)"
      plain_file="$(mktemp)"
      printf '%s' "$wrapped" | base64 -d >"$cipher_file"
      gcloud kms decrypt \
        --project "$KMS_PROJECT_ID" \
        --location "$KMS_LOCATION" \
        --keyring "$KMS_KEY_RING" \
        --key "$KMS_KEY_ID" \
        --ciphertext-file "$cipher_file" \
        --plaintext-file "$plain_file" >/dev/null
      cat "$plain_file"
      rm -f "$cipher_file" "$plain_file"
      ;;
    *)
      echo "unsupported KMS_VENDOR=${KMS_VENDOR:-}" >&2
      return 1
      ;;
  esac
}

unwrap_data_key() {
  wrapped="$1"
  case "${KEY_PROVIDER:-}" in
    vault)
      vault_decrypt "$wrapped"
      ;;
    kms)
      kms_decrypt "$wrapped"
      ;;
    *)
      echo "unsupported KEY_PROVIDER=${KEY_PROVIDER:-}" >&2
      return 1
      ;;
  esac
}
`
