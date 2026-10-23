#!/bin/sh
# Executed inside a key-backup container or a migration helper. Recovery keys
# enter/leave over stdin/stdout and are never passed as command arguments.
set -eu
umask 077
bundle_dir="${FLEET_BUNDLE_DIR:-/bundle}"
recovery_dir="${FLEET_RECOVERY_DIR:-/recovery}"

vault_request() {
  operation="$1"
  value="$2"
  : "${VAULT_ADDR:?missing VAULT_ADDR}" "${VAULT_TOKEN:?missing VAULT_TOKEN}" "${VAULT_TRANSIT_KEY:?missing VAULT_TRANSIT_KEY}"
  if [ "$operation" = encrypt ]; then
    value="$(printf %s "$value" | base64 | tr -d '\n')"
    payload="$(printf %s "$value" | jq -Rs '{plaintext:.}')"
  else
    payload="$(printf %s "$value" | jq -Rs '{ciphertext:.}')"
  fi
  printf %s "$payload" | curl -fsS --connect-timeout 15 --max-time 60 \
    -H "X-Vault-Token: ${VAULT_TOKEN}" -H "X-Vault-Namespace: ${VAULT_NAMESPACE:-}" \
    -H 'Content-Type: application/json' --data-binary @- \
    "${VAULT_ADDR%/}/v1/transit/${operation}/${VAULT_TRANSIT_KEY}"
}

case "$1" in
  unwrap)
    wrapped="$(awk -F= '$1 == "wrapped_key" {print substr($0,index($0,"=")+1); exit}')"
    [ -n "$wrapped" ]
    vault_request decrypt "$wrapped" | jq -er '.data.plaintext' | base64 -d
    ;;
  restore)
    read -r data_key
    # Validate before using the key; no secret is placed in the process args.
    key_size="$(printf %s "$data_key" | base64 -d | wc -c | tr -d ' ')"
    [ "$key_size" = 32 ] || [ "$key_size" = 48 ]
    export DATA_KEY_B64="$data_key"
    trap 'rm -f "$recovery_dir/plain.tar.gz" "$recovery_dir/rebound.tar.gz" "$recovery_dir/new.enc" "$recovery_dir/new.meta"' EXIT
    openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -pass env:DATA_KEY_B64 \
      -in "${bundle_dir}/${KEY_BUNDLE_FILE}" -out "$recovery_dir/plain.tar.gz"
    python3 "$recovery_dir/fleet.py" rebind "$recovery_dir/plain.tar.gz" "$recovery_dir/rebound.tar.gz" "$2" "$3"
    wrapped="$(vault_request encrypt "$data_key" | jq -er '.data.ciphertext')"
    verified="$(vault_request decrypt "$wrapped" | jq -er '.data.plaintext' | base64 -d)"
    [ "$verified" = "$data_key" ]
    openssl enc -aes-256-cbc -pbkdf2 -md sha256 -pass env:DATA_KEY_B64 \
      -in "$recovery_dir/rebound.tar.gz" -out "$recovery_dir/new.enc"
    printf 'provider=vault\nwrapped_key=%s\nalgorithm=aes-256-cbc-pbkdf2\ncreated_at=%s\n' \
      "$wrapped" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$recovery_dir/new.meta"
    cp "$recovery_dir/new.enc" "${bundle_dir}/${KEY_BUNDLE_FILE}"
    cp "$recovery_dir/new.meta" "${bundle_dir}/${KEY_BUNDLE_META_FILE}"
    cmp "$recovery_dir/new.enc" "${bundle_dir}/${KEY_BUNDLE_FILE}"
    cmp "$recovery_dir/new.meta" "${bundle_dir}/${KEY_BUNDLE_META_FILE}"
    chmod 600 "${bundle_dir}/${KEY_BUNDLE_FILE}" "${bundle_dir}/${KEY_BUNDLE_META_FILE}"
    touch "$bundle_dir/.restore-controller-state"
    ;;
  *) exit 1 ;;
esac
