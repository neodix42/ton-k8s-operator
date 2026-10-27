#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-auto}"
WALLET_NETWORK="${WALLET_NETWORK:-}"
GLOBAL_CONFIG_URL="${GLOBAL_CONFIG_URL-https://ton.org/global.config.json}"
GLOBAL_CONFIG_JSON="${GLOBAL_CONFIG_JSON:-}"
TONCENTER_URL="${TONCENTER_URL:-https://testnet.toncenter.com}"
TONCENTER_API_KEY="${TONCENTER_API_KEY:-}"

MAIN_WALLET_DIR="${MAIN_WALLET_DIR:-/var/main-wallet/runtime}"
MAIN_WALLET_BUNDLE_DIR="${MAIN_WALLET_BUNDLE_DIR:-/var/main-wallet/bundle}"
MAIN_WALLET_BUNDLE_FILE="${MAIN_WALLET_BUNDLE_FILE:-main-wallet.bundle.enc}"
MAIN_WALLET_BUNDLE_META_FILE="${MAIN_WALLET_BUNDLE_META_FILE:-main-wallet.bundle.meta}"
MAIN_WALLET_NAME_DEFAULT="${MAIN_WALLET_NAME_DEFAULT:-main-wallet}"
SMARTCONT_DIR="${SMARTCONT_DIR:-/usr/share/ton/smartcont}"
MAIN_WALLET_SEND_RETRY_ATTEMPTS="${MAIN_WALLET_SEND_RETRY_ATTEMPTS:-2}"
MAIN_WALLET_LITESERVER_SEND_ATTEMPTS="${MAIN_WALLET_LITESERVER_SEND_ATTEMPTS:-$MAIN_WALLET_SEND_RETRY_ATTEMPTS}"
MAIN_WALLET_TONCENTER_SEND_ATTEMPTS="${MAIN_WALLET_TONCENTER_SEND_ATTEMPTS:-$MAIN_WALLET_SEND_RETRY_ATTEMPTS}"
MAIN_WALLET_SEND_RETRY_DELAY_SEC="${MAIN_WALLET_SEND_RETRY_DELAY_SEC:-3}"
MAIN_WALLET_MULTI_SEND_PAUSE_SEC="${MAIN_WALLET_MULTI_SEND_PAUSE_SEC:-3}"
MAIN_WALLET_CONFIRM_ATTEMPTS="${MAIN_WALLET_CONFIRM_ATTEMPTS:-30}"
MAIN_WALLET_CONFIRM_DELAY_SEC="${MAIN_WALLET_CONFIRM_DELAY_SEC:-2}"
MAIN_WALLET_CONFIRM_TIMEOUT_SEC="${MAIN_WALLET_CONFIRM_TIMEOUT_SEC:-180}"
MAIN_WALLET_HTTP_MIN_INTERVAL_MS="${MAIN_WALLET_HTTP_MIN_INTERVAL_MS:-1100}"
MAIN_WALLET_REBROADCAST_DELAY_SEC="${MAIN_WALLET_REBROADCAST_DELAY_SEC:-10}"
MAIN_WALLET_REBROADCAST_ATTEMPTS="${MAIN_WALLET_REBROADCAST_ATTEMPTS:-3}"
MAIN_WALLET_VERBOSE="${MAIN_WALLET_VERBOSE:-false}"

usage() {
  cat <<'EOF'
Usage:
  main-wallet.sh create [workchain] [subwallet-id] [wallet-name]
  main-wallet.sh deploy [wallet-name]
  main-wallet.sh send [from-wallet-name] [to-address] [amount] [-n]
  main-wallet.sh send [from-wallet-name] [amount] [to-address...] [-n]
  main-wallet.sh show [wallet-name]
  main-wallet.sh export <wallet-name>
  main-wallet.sh run <create|deploy|send|show|export> [args...]

Required env for deploy/send and balance queries:
  WALLET_NETWORK=mainnet|testnet (detected from the active fleet by kubeton)
  MODE=auto|liteserver|toncenter
  GLOBAL_CONFIG_URL=<active global config URL or file>
  GLOBAL_CONFIG_JSON=<optional exact active config contents>
  TONCENTER_URL=<API URL for the active network>

Required env for encrypted persistence:
  KEY_PROVIDER=vault
  VAULT_ADDR
  VAULT_TOKEN
  VAULT_TRANSIT_KEY
EOF
}

trim_whitespace() {
  printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

wallet_send_verbose_enabled() {
  case "${MAIN_WALLET_VERBOSE,,}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

wallet_send_progress() {
  if [[ -n "${WALLET_SEND_PROGRESS_FD:-}" ]]; then
    printf '%s\n' "$*" >&"$WALLET_SEND_PROGRESS_FD"
  else
    printf '%s\n' "$*" >&2
  fi
}

# Calls carrying receipt/seqno data must preserve stdout. Calls whose entire
# output is diagnostic run directly, preserving their mutable shell state.
wallet_send_diagnostics_run() {
  local capture="$1"
  shift
  if wallet_send_verbose_enabled || [[ -z "${WALLET_SEND_DIAGNOSTICS_FILE:-}" ]]; then
    if [[ "$capture" == all ]]; then "$@" >&2; else "$@"; fi
  elif [[ "$capture" == all ]]; then
    "$@" >>"$WALLET_SEND_DIAGNOSTICS_FILE" 2>&1
  else
    "$@" 2>>"$WALLET_SEND_DIAGNOSTICS_FILE"
  fi
}

wallet_send_diagnostics_finish() {
  local rc="$1"
  # Command substitutions must not remove their parent's diagnostic buffer.
  [[ "$BASHPID" == "${WALLET_SEND_DIAGNOSTICS_OWNER:-}" ]] || return 0
  if [[ -n "${WALLET_SEND_DIAGNOSTICS_FILE:-}" ]]; then
    if (( rc != 0 )) && [[ -s "$WALLET_SEND_DIAGNOSTICS_FILE" ]]; then
      wallet_send_progress '[wallet] Send diagnostics for the unconfirmed or failed operation:'
      cat "$WALLET_SEND_DIAGNOSTICS_FILE" >&2
    fi
    rm -f "$WALLET_SEND_DIAGNOSTICS_FILE"
  fi
}

main_wallet_send_retry_attempts() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_SEND_RETRY_ATTEMPTS:-2}")"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "2"
}

main_wallet_liteserver_send_attempts() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_LITESERVER_SEND_ATTEMPTS:-$(main_wallet_send_retry_attempts)}")"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "2"
}

main_wallet_toncenter_send_attempts() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_TONCENTER_SEND_ATTEMPTS:-$(main_wallet_send_retry_attempts)}")"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "2"
}

main_wallet_send_retry_delay_seconds() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_SEND_RETRY_DELAY_SEC:-3}")"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "2"
}

main_wallet_multi_send_pause_seconds() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_MULTI_SEND_PAUSE_SEC:-3}")"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "3"
}

main_wallet_confirm_attempts() {
  if [[ "${MAIN_WALLET_CONFIRM_ATTEMPTS:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$MAIN_WALLET_CONFIRM_ATTEMPTS"
  else
    printf '%s' 30
  fi
}

main_wallet_confirm_delay_seconds() {
  if [[ "${MAIN_WALLET_CONFIRM_DELAY_SEC:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$MAIN_WALLET_CONFIRM_DELAY_SEC"
  else
    printf '%s' 2
  fi
}

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command not found: $bin" >&2
    exit 1
  fi
}

read_meta_value() {
  local key="$1"
  local meta_file="$2"
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$meta_file"
}

write_meta_value() {
  local key="$1"
  local value="$2"
  local meta_file="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  if [[ -f "$meta_file" ]]; then
    awk -F= -v wanted="$key" -v replacement="$value" '
      $1 == wanted {
        if (!updated) {
          print wanted "=" replacement
          updated = 1
        }
        next
      }
      { print }
      END {
        if (!updated) {
          print wanted "=" replacement
        }
      }
    ' "$meta_file" > "$tmp_file"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp_file"
  fi
  mv -f "$tmp_file" "$meta_file"
  chmod 600 "$meta_file"
}

normalize_wallet_network_name() {
  local raw

  raw="$(trim_whitespace "${1:-}")"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    mainnet|main)
      printf '%s' "mainnet"
      ;;
    testnet|test)
      printf '%s' "testnet"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_current_wallet_network() {
  # Only the network checked against the active fleet config is authoritative.
  # Saved wallet metadata and default URLs cannot identify the running chain.
  normalize_wallet_network_name "${WALLET_NETWORK:-}"
}

require_wallet_network_match() {
  local wallet_name="$1"
  local meta_file="${MAIN_WALLET_DIR}/${wallet_name}.wallet.meta"
  local active_network saved_network saved_raw

  active_network="$(resolve_current_wallet_network || true)"
  if [[ -z "$active_network" ]]; then
    echo "Error: cannot determine the active fleet network for wallet '${wallet_name}'." >&2
    return 1
  fi
  [[ -f "$meta_file" ]] || return 0
  saved_raw="$(trim_whitespace "$(read_meta_value network "$meta_file")")"
  [[ -n "$saved_raw" && "$saved_raw" != unknown ]] || return 0
  saved_network="$(normalize_wallet_network_name "$saved_raw" || true)"
  if [[ -z "$saved_network" ]]; then
    echo "Error: wallet '${wallet_name}' has an unrecognized saved network '${saved_raw}'." >&2
    return 1
  fi
  if [[ "$saved_network" != "$active_network" ]]; then
    echo "Error: wallet '${wallet_name}' is saved for ${saved_network}, but the active fleet uses ${active_network}." >&2
    return 1
  fi
}

extract_json_string() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

file_bytes_to_hex() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    return 1
  fi
  if ! command -v od >/dev/null 2>&1; then
    return 1
  fi
  LC_ALL=C od -An -tx1 -v "$file" | tr -d ' \n'
}

ton_address_to_hex() {
  local address normalized decoded_hex wc_hex wc_dec account_hex
  local crc=0 byte_offset bit byte_value

  address="$(trim_whitespace "${1:-}")"
  if [[ "$address" =~ ^(-?[0-9]+):([0-9A-Fa-f]{64})$ ]]; then
    printf '%s:%s' "${BASH_REMATCH[1]}" "$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
    return 0
  fi
  if ! [[ "$address" =~ ^[A-Za-z0-9_-]{48}$ ]]; then
    return 1
  fi
  if ! command -v base64 >/dev/null 2>&1 || ! command -v od >/dev/null 2>&1; then
    return 1
  fi

  normalized="${address//-/+}"
  normalized="${normalized//_/\/}"
  while (( ${#normalized} % 4 != 0 )); do
    normalized="${normalized}="
  done

  decoded_hex="$(printf '%s' "$normalized" | base64 -d 2>/dev/null | od -An -tx1 -v 2>/dev/null | tr -d ' \n')" || return 1
  if [[ ${#decoded_hex} -ne 72 ]]; then
    return 1
  fi
  case "${decoded_hex:0:2}" in
    11|51|91|d1) ;;
    *) return 1 ;;
  esac
  # Friendly TON addresses carry a CRC16-XMODEM over the tag, workchain,
  # and 32-byte account. Do not present damaged metadata as a valid address.
  for ((byte_offset=0; byte_offset<68; byte_offset+=2)); do
    byte_value=$((16#${decoded_hex:byte_offset:2}))
    crc=$((crc ^ (byte_value << 8)))
    for ((bit=0; bit<8; bit++)); do
      if (( crc & 0x8000 )); then
        crc=$((((crc << 1) ^ 0x1021) & 0xffff))
      else
        crc=$(((crc << 1) & 0xffff))
      fi
    done
  done
  [[ "$(printf '%04x' "$crc")" == "${decoded_hex:68:4}" ]] || return 1
  wc_hex="${decoded_hex:2:2}"
  account_hex="${decoded_hex:4:64}"
  if ! [[ "$wc_hex" =~ ^[0-9A-Fa-f]{2}$ && "$account_hex" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    return 1
  fi

  wc_dec=$((16#$wc_hex))
  if (( wc_dec >= 128 )); then
    wc_dec=$((wc_dec - 256))
  fi
  printf '%s:%s' "$wc_dec" "$account_hex"
}

ton_friendly_address_for_network() {
  local address="${1:-}" network decoded_hex tag body_hex crc=0 byte_offset bit byte_value

  network="$(normalize_wallet_network_name "${2:-}")" || return 1
  address="$(trim_whitespace "$address")"
  [[ "$address" =~ ^[A-Za-z0-9_-]{48}$ ]] || return 1
  # Validate the original checksum before changing its presentation flags.
  ton_address_to_hex "$address" >/dev/null || return 1
  decoded_hex="$(printf '%s' "${address//-/+}" | tr '_' '/' | base64 -d 2>/dev/null | od -An -tx1 -v | tr -d ' \n')" || return 1
  tag=$((16#${decoded_hex:0:2} & 0x7f))
  [[ "$network" != testnet ]] || tag=$((tag | 0x80))
  body_hex="$(printf '%02x' "$tag")${decoded_hex:2:66}"
  for ((byte_offset=0; byte_offset<68; byte_offset+=2)); do
    byte_value=$((16#${body_hex:byte_offset:2}))
    crc=$((crc ^ (byte_value << 8)))
    for ((bit=0; bit<8; bit++)); do
      if (( crc & 0x8000 )); then
        crc=$((((crc << 1) ^ 0x1021) & 0xffff))
      else
        crc=$(((crc << 1) & 0xffff))
      fi
    done
  done
  printf '%b' "$(printf '%s%04x' "$body_hex" "$crc" | sed 's/../\\x&/g')" \
    | base64 | tr '+/' '-_' | tr -d '\r\n'
}

wallet_matching_friendly_address() {
  local candidate="${1:-}" wallet_address="${2:-}" network="${3:-}"
  local candidate_hex

  [[ "$candidate" =~ ^[A-Za-z0-9_-]{48}$ && -n "$wallet_address" ]] || return 1
  candidate_hex="$(ton_address_to_hex "$candidate")" || return 1
  [[ "$candidate_hex" == "$wallet_address" ]] || return 1
  if [[ -n "$network" && "$network" != unknown ]]; then
    ton_friendly_address_for_network "$candidate" "$network"
  else
    printf '%s' "$candidate"
  fi
}

wallet_address_file_text() {
  local file="$1" candidate nontext_bytes

  [[ -r "$file" && -s "$file" ]] || return 1
  # Validate before putting file contents in a Bash variable: .addr usually
  # contains binary data, including NUL bytes and arbitrary printable bytes.
  nontext_bytes="$(LC_ALL=C tr -d '\11\12\15\40-\176' <"$file" | wc -c)"
  (( nontext_bytes == 0 )) || return 1
  candidate="$(trim_whitespace "$(cat "$file")")"
  ton_address_to_hex "$candidate" >/dev/null || return 1
  printf '%s' "$candidate"
}

wallet_address_file_to_hex() {
  local file="$1" data_hex account_hex wc_hex wc_dec candidate

  data_hex="$(file_bytes_to_hex "$file")" || return 1
  # Fift TonUtil.fif save-address writes the 256-bit account followed by a
  # signed 32-bit big-endian workchain. load-address also accepts the legacy
  # account-only format, whose workchain is zero.
  case "${#data_hex}" in
    64)
      printf '0:%s' "$data_hex"
      return 0
      ;;
    72)
      account_hex="${data_hex:0:64}"
      wc_hex="${data_hex:64:8}"
      wc_dec=$((16#$wc_hex))
      if (( wc_dec >= 2147483648 )); then
        wc_dec=$((wc_dec - 4294967296))
      fi
      printf '%s:%s' "$wc_dec" "$account_hex"
      return 0
      ;;
  esac
  candidate="$(wallet_address_file_text "$file")" || return 1
  ton_address_to_hex "$candidate"
}

vault_encrypt_data_key() {
  local data_key_b64="$1"
  local payload response wrapped plaintext

  require_bin curl
  if [[ "${KEY_PROVIDER:-}" != "vault" ]]; then
    echo "Error: KEY_PROVIDER must be 'vault' for main wallet persistence." >&2
    return 1
  fi
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" || -z "${VAULT_TRANSIT_KEY:-}" ]]; then
    echo "Error: vault provider requires VAULT_ADDR, VAULT_TOKEN and VAULT_TRANSIT_KEY." >&2
    return 1
  fi

  # Vault transit expects plaintext to be base64-encoded bytes.
  plaintext="$(printf '%s' "$data_key_b64" | base64 | tr -d '\r\n')"
  payload="$(printf '{"plaintext":"%s"}' "$plaintext")"
  if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    response="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/encrypt/${VAULT_TRANSIT_KEY}")"
  else
    response="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/encrypt/${VAULT_TRANSIT_KEY}")"
  fi

  wrapped="$(printf '%s' "$response" | extract_json_string "ciphertext")"
  wrapped="$(trim_whitespace "$wrapped")"
  if [[ -z "$wrapped" ]]; then
    echo "Error: failed to parse ciphertext from Vault transit encrypt response." >&2
    return 1
  fi
  printf '%s' "$wrapped"
}

vault_decrypt_data_key() {
  local wrapped="$1"
  local key_encoding="${2:-legacy-direct}"
  local payload response plaintext_b64 decoded

  require_bin curl
  require_bin base64
  require_bin jq
  if [[ "${KEY_PROVIDER:-}" != "vault" ]]; then
    echo "Error: KEY_PROVIDER must be 'vault' for main wallet persistence." >&2
    return 1
  fi
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" || -z "${VAULT_TRANSIT_KEY:-}" ]]; then
    echo "Error: vault provider requires VAULT_ADDR, VAULT_TOKEN and VAULT_TRANSIT_KEY." >&2
    return 1
  fi

  payload="$(printf '{"ciphertext":"%s"}' "$wrapped")"
  if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    response="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  else
    response="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  fi

  plaintext_b64="$(printf '%s' "$response" | extract_json_string "plaintext")"
  plaintext_b64="$(trim_whitespace "$plaintext_b64")"
  if [[ -z "$plaintext_b64" ]]; then
    echo "Error: failed to parse plaintext from Vault transit decrypt response." >&2
    return 1
  fi
  case "$key_encoding" in
    legacy-direct)
      # Backward compatibility for bundles created by the initial buggy flow.
      printf '%s' "$plaintext_b64"
      ;;
    passphrase-b64-v1)
      decoded="$(printf '%s' "$plaintext_b64" | base64 -d 2>/dev/null || true)"
      decoded="$(trim_whitespace "$decoded")"
      if [[ -z "$decoded" ]]; then
        echo "Error: failed to decode Vault plaintext for key_encoding=${key_encoding}." >&2
        return 1
      fi
      printf '%s' "$decoded"
      ;;
    *)
      echo "Error: unsupported wrapped key encoding '${key_encoding}'." >&2
      return 1
      ;;
  esac
}

restore_bundle() {
  local bundle_file="${MAIN_WALLET_BUNDLE_DIR}/${MAIN_WALLET_BUNDLE_FILE}"
  local meta_file="${MAIN_WALLET_BUNDLE_DIR}/${MAIN_WALLET_BUNDLE_META_FILE}"
  local wrapped_key wrapped_key_encoding data_key_b64 tmp_dir

  mkdir -p "$MAIN_WALLET_DIR" "$MAIN_WALLET_BUNDLE_DIR"
  if [[ ! -s "$bundle_file" || ! -s "$meta_file" ]]; then
    return 0
  fi

  require_bin tar
  require_bin openssl
  require_bin mktemp

  wrapped_key="$(read_meta_value wrapped_key "$meta_file")"
  wrapped_key="$(trim_whitespace "$wrapped_key")"
  if [[ -z "$wrapped_key" ]]; then
    echo "Error: ${meta_file} is missing wrapped_key." >&2
    return 1
  fi

  wrapped_key_encoding="$(read_meta_value wrapped_key_encoding "$meta_file")"
  wrapped_key_encoding="$(trim_whitespace "$wrapped_key_encoding")"
  if [[ -z "$wrapped_key_encoding" ]]; then
    wrapped_key_encoding="legacy-direct"
  fi

  data_key_b64="$(vault_decrypt_data_key "$wrapped_key" "$wrapped_key_encoding")"
  data_key_b64="$(trim_whitespace "$data_key_b64")"
  if [[ -z "$data_key_b64" ]]; then
    echo "Error: failed to unwrap bundle data key." >&2
    return 1
  fi
  export DATA_KEY_B64="$data_key_b64"

  tmp_dir="$(mktemp -d)"

  openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 \
    -pass env:DATA_KEY_B64 \
    -in "$bundle_file" \
    -out "$tmp_dir/main-wallet.tar.gz"

  mkdir -p "$tmp_dir/unpacked"
  tar -xzf "$tmp_dir/main-wallet.tar.gz" -C "$tmp_dir/unpacked"

  find "$MAIN_WALLET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
  cp -a "$tmp_dir/unpacked/." "$MAIN_WALLET_DIR/"
  rm -rf "$tmp_dir"
}

backup_bundle() {
  local bundle_file="${MAIN_WALLET_BUNDLE_DIR}/${MAIN_WALLET_BUNDLE_FILE}"
  local meta_file="${MAIN_WALLET_BUNDLE_DIR}/${MAIN_WALLET_BUNDLE_META_FILE}"
  local data_key_b64 wrapped_key tmp_dir

  mkdir -p "$MAIN_WALLET_DIR" "$MAIN_WALLET_BUNDLE_DIR"
  require_bin tar
  require_bin openssl
  require_bin mktemp

  tmp_dir="$(mktemp -d)"

  tar -czf "$tmp_dir/main-wallet.tar.gz" -C "$MAIN_WALLET_DIR" .
  data_key_b64="$(openssl rand -base64 32 | tr -d '\r\n')"
  if [[ -z "$data_key_b64" ]]; then
    echo "Error: failed to generate random data key." >&2
    return 1
  fi
  export DATA_KEY_B64="$data_key_b64"

  openssl enc -aes-256-cbc -pbkdf2 -md sha256 \
    -pass env:DATA_KEY_B64 \
    -in "$tmp_dir/main-wallet.tar.gz" \
    -out "$tmp_dir/main-wallet.bundle.enc"

  wrapped_key="$(vault_encrypt_data_key "$data_key_b64")"
  wrapped_key="$(trim_whitespace "$wrapped_key")"
  if [[ -z "$wrapped_key" ]]; then
    echo "Error: failed to wrap data key with Vault." >&2
    return 1
  fi

  cp -f "$tmp_dir/main-wallet.bundle.enc" "$bundle_file"
  chmod 600 "$bundle_file"
  {
    echo "provider=${KEY_PROVIDER:-vault}"
    echo "wrapped_key_encoding=passphrase-b64-v1"
    echo "wrapped_key=${wrapped_key}"
  } > "$tmp_dir/main-wallet.bundle.meta"
  cp -f "$tmp_dir/main-wallet.bundle.meta" "$meta_file"
  chmod 600 "$meta_file"
  rm -rf "$tmp_dir"
}

resolve_new_wallet_fif() {
  local candidate
  for candidate in \
    "$MAIN_WALLET_DIR/new-wallet-v3.fif" \
    "${SMARTCONT_DIR}/new-wallet-v3.fif"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_wallet_fif() {
  local candidate
  for candidate in \
    "$MAIN_WALLET_DIR/wallet-v3.fif" \
    "${SMARTCONT_DIR}/wallet-v3.fif"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_lite_client_bin() {
  local candidate
  for candidate in /usr/local/bin/lite-client /usr/bin/lite-client lite-client; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_fift_bin() {
  local candidate
  for candidate in /usr/local/bin/fift /usr/bin/fift fift; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

toncenter_endpoint() {
  printf '%s' "${TONCENTER_URL%/}/api/v2/sendBoc"
}

send_boc_toncenter_once() {
  local boc_file="$1"
  local boc_b64 http_response http_code response timeout connect curl_args=()

  require_bin curl
  require_bin base64
  if [[ -z "$TONCENTER_URL" ]]; then
    echo "Error: TONCENTER_URL is empty." >&2
    return 1
  fi
  wallet_toncenter_base >/dev/null || {
    echo 'Error: refusing to broadcast through a TONCenter endpoint that does not match the active wallet network.' >&2
    return 1
  }
  if [[ -n "$TONCENTER_API_KEY" ]]; then
    curl_args+=(-H "X-API-Key: ${TONCENTER_API_KEY}")
  fi

  boc_b64="$(base64 -w0 "$boc_file" 2>/dev/null || base64 < "$boc_file" | tr -d '\r\n')"
  wallet_http_pace || return 1
  timeout="$(wallet_request_timeout 15)" || return 1
  connect="$timeout"; (( connect <= 5 )) || connect=5
  if http_response="$(curl -sS \
    --connect-timeout "$connect" --max-time "$timeout" \
    -w $'\n%{http_code}' \
    "${curl_args[@]}" \
    -H "Content-Type: application/json" \
    --request POST \
    --data "{\"boc\":\"${boc_b64}\"}" \
    "$(toncenter_endpoint)")"; then
    :
  else
    local curl_rc=$?
    echo "Error: TONCenter sendBoc request failed with curl exit code ${curl_rc}." >&2
    return "$curl_rc"
  fi

  http_code="${http_response##*$'\n'}"
  response="${http_response%$'\n'*}"

  printf '%s\n' "$response"
  if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "Error: TONCenter sendBoc returned HTTP ${http_code}." >&2
    return 1
  fi
  if ! printf '%s' "$response" | jq -es 'length == 1 and (.[0] | type == "object" and .ok == true)' >/dev/null 2>&1; then
    echo "Error: TONCenter sendBoc request did not return ok=true." >&2
    return 1
  fi
}

send_boc_toncenter() {
  local boc_file="$1"
  local attempts delay attempt rc=1

  attempts="$(main_wallet_toncenter_send_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    echo "Sending BOC via TONCenter $(toncenter_endpoint) (attempt ${attempt}/${attempts}) ..." >&2
    if send_boc_toncenter_once "$boc_file"; then
      return 0
    else
      rc=$?
    fi
    if (( attempt < attempts )); then
      echo "Warning: TONCenter sendBoc failed (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        wallet_bounded_sleep "$delay" || break
      fi
    fi
  done

  echo "Error: TONCenter sendBoc failed after ${attempts} attempt(s)." >&2
  return "$rc"
}

resolve_local_global_config_path() {
  local global_config_source global_config_path temp_config_file=""

  if [[ -n "$GLOBAL_CONFIG_JSON" ]]; then
    # Config files in a TON pod may use paths that do not exist in this helper
    # pod. Use the exact active config bytes copied by the host CLI.
    temp_config_file="$(mktemp)"
    printf '%s' "$GLOBAL_CONFIG_JSON" >"$temp_config_file"
    printf '%s\t%s' "$temp_config_file" "$temp_config_file"
    return 0
  fi

  if [[ -z "$GLOBAL_CONFIG_URL" ]]; then
    echo "Error: GLOBAL_CONFIG_URL is empty." >&2
    return 1
  fi
  global_config_source="$(trim_whitespace "$GLOBAL_CONFIG_URL")"
  if [[ "$global_config_source" =~ ^https?:// ]]; then
    require_bin curl
    require_bin mktemp
    temp_config_file="$(mktemp)"
    local timeout
    timeout="$(wallet_request_timeout 15)" || { rm -f "$temp_config_file"; return 1; }
    if ! curl -fsSL --connect-timeout "$timeout" --max-time "$timeout" "$global_config_source" -o "$temp_config_file"; then
      rm -f "$temp_config_file"
      echo "Error: failed to download global config from ${global_config_source}" >&2
      return 1
    fi
    if [[ ! -s "$temp_config_file" ]]; then
      rm -f "$temp_config_file"
      echo "Error: downloaded global config is empty: ${global_config_source}" >&2
      return 1
    fi
    printf '%s\t%s' "$temp_config_file" "$temp_config_file"
    return 0
  fi

  global_config_path="${global_config_source#file://}"
  if [[ ! -r "$global_config_path" ]]; then
    echo "Error: global config file is not readable: ${global_config_path}" >&2
    return 1
  fi
  printf '%s\t' "$global_config_path"
}

warn_liteserver_toncenter_network_mismatch() {
  local network toncenter_lower toncenter_network=""

  network="$(resolve_current_wallet_network || true)"
  toncenter_lower="$(printf '%s' "$TONCENTER_URL" | tr '[:upper:]' '[:lower:]')"
  if [[ "$toncenter_lower" == https://testnet.toncenter.com || "$toncenter_lower" == https://testnet.toncenter.com/* ]]; then
    toncenter_network=testnet
  elif [[ "$toncenter_lower" == https://toncenter.com || "$toncenter_lower" == https://toncenter.com/* ]]; then
    toncenter_network=mainnet
  fi
  if [[ -n "$network" && -n "$toncenter_network" && "$network" != "$toncenter_network" ]]; then
    echo "Warning: the active fleet uses ${network}, but TONCENTER_URL=${TONCENTER_URL} uses ${toncenter_network}." >&2
    echo "Warning: configure TONCenter for the active fleet network before using the API fallback." >&2
  fi
}

run_liteclient_query() {
  local query="$1"
  local lite_client_bin
  local config_row config_path temp_config_path rc=0 verbosity=0 timeout

  lite_client_bin="$(resolve_lite_client_bin || true)"
  lite_client_bin="$(trim_whitespace "$lite_client_bin")"
  if [[ -z "$lite_client_bin" ]]; then
    echo "Error: lite-client binary not found." >&2
    return 1
  fi

  config_row="$(resolve_local_global_config_path || true)"
  config_row="$(trim_whitespace "$config_row")"
  if [[ -z "$config_row" ]]; then
    return 1
  fi
  IFS=$'\t' read -r config_path temp_config_path <<<"$config_row"
  config_path="$(trim_whitespace "$config_path")"
  temp_config_path="$(trim_whitespace "$temp_config_path")"
  if [[ -z "$config_path" ]]; then
    echo "Error: failed to resolve lite-client config file path." >&2
    return 1
  fi

  # sendfile reports the server acknowledgement at INFO level. Its exit code
  # alone can be zero after an RPC error, so keep this acknowledgement visible.
  [[ "$query" != sendfile\ * ]] || verbosity=3

  # Bound each batch query as well as the confirmation loop. An unreachable
  # liteserver must not keep a wallet helper alive indefinitely.
  if ! timeout="$(wallet_request_timeout 15)"; then
    [[ -z "$temp_config_path" ]] || rm -f "$temp_config_path"
    return 1
  fi
  if "$lite_client_bin" -C "$config_path" -v "$verbosity" -t "$timeout" -c "$query"; then
    rc=0
  else
    rc=$?
  fi
  if [[ -n "$temp_config_path" ]]; then
    rm -f "$temp_config_path"
  fi
  return "$rc"
}

send_boc_liteserver() {
  local boc_file="$1"
  local attempts delay attempt rc=1 output

  attempts="$(main_wallet_liteserver_send_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    echo "Sending BOC via lite-server config ${GLOBAL_CONFIG_URL} (attempt ${attempt}/${attempts}) ..." >&2
    if output="$(run_liteclient_query "sendfile $boc_file" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    [[ -z "$output" ]] || printf '%s\n' "$output"
    if (( rc == 0 )) && printf '%s\n' "${output//$'\r'/}" | grep -Eq 'external message status is 1[[:space:]]*$'; then
      return 0
    fi
    if (( rc == 0 )); then
      rc=1
      echo "Warning: lite-client exited without a successful external-message acknowledgement; submission is unconfirmed." >&2
    fi
    if (( attempt < attempts )); then
      echo "Warning: lite-client sendfile failed (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        wallet_bounded_sleep "$delay" || break
      fi
    fi
  done

  echo "Error: lite-client sendfile failed after ${attempts} attempt(s)." >&2
  return "$rc"
}

send_boc_payload() {
  local boc_file="$1"
  local normalized_mode="$2"
  local liteserver_rc=0
  local toncenter_rc=0

  case "$normalized_mode" in
    auto|fallback|both)
      warn_liteserver_toncenter_network_mismatch
      send_boc_liteserver "$boc_file" && return 0
      liteserver_rc=$?
      if [[ -n "${WALLET_SEND_PROGRESS_FD:-}" ]]; then
        wallet_send_progress '[wallet] Lite-server submission unavailable; using TONCenter fallback.'
      fi
      echo "Warning: lite-server BOC send failed; trying TONCenter fallback." >&2
      send_boc_toncenter "$boc_file" && return 0
      toncenter_rc=$?
      echo "Error: BOC send failed via lite-server and TONCenter." >&2
      return "$toncenter_rc"
      ;;
    liteserver)
      warn_liteserver_toncenter_network_mismatch
      send_boc_liteserver "$boc_file" || liteserver_rc=$?
      return "$liteserver_rc"
      ;;
    toncenter)
      send_boc_toncenter "$boc_file" || toncenter_rc=$?
      return "$toncenter_rc"
      ;;
    *)
      echo "Error: unsupported MODE=${MODE}. Use auto, liteserver, or toncenter." >&2
      return 1
      ;;
  esac
}

print_wallet_deploy_failure_hint() {
  local wallet_name="$1"
  local meta_file="${MAIN_WALLET_DIR}/${wallet_name}.wallet.meta"
  local non_bounceable bounceable wallet_address network

  non_bounceable=""
  bounceable=""
  wallet_address="$(resolve_wallet_address_by_name "$wallet_name" || true)"
  if [[ -f "$meta_file" ]]; then
    network="$(normalize_wallet_network_name "$(read_meta_value network "$meta_file")" || true)"
    [[ -n "$network" ]] || network="$(resolve_current_wallet_network || true)"
    non_bounceable="$(trim_whitespace "$(read_meta_value non_bounceable "$meta_file")")"
    bounceable="$(trim_whitespace "$(read_meta_value bounceable "$meta_file")")"
    non_bounceable="$(wallet_matching_friendly_address "$non_bounceable" "$wallet_address" "$network" || true)"
    bounceable="$(wallet_matching_friendly_address "$bounceable" "$wallet_address" "$network" || true)"
  fi

  echo "Hint: wallet deployment sends an external init message; it does not fund the wallet." >&2
  echo "Hint: an inactive/unfunded wallet usually rejects deploy because gas must be paid from the wallet balance." >&2
  if [[ -n "$non_bounceable" && "$non_bounceable" != "unknown" ]]; then
    echo "Hint: first send funds to the non-bounceable init address: ${non_bounceable}" >&2
  elif [[ -n "$wallet_address" && "$wallet_address" != "unknown" ]]; then
    echo "Hint: first fund wallet address ${wallet_address}; use the non-bounceable form for initial funding if available." >&2
  fi
  if [[ -n "$bounceable" && "$bounceable" != "unknown" ]]; then
    echo "Hint: after deployment, use the bounceable address: ${bounceable}" >&2
  fi
  echo "Hint: rerun 'kubeton wallet deploy ${wallet_name}' after the funding transaction is visible on-chain." >&2
}

deploy_boc_with_mode() {
  local wallet_name="$1"
  local boc_file="$2"
  local normalized_mode="$3"
  local rc=0

  echo "Deploying wallet '${wallet_name}' using BOC '${boc_file##*/}' ..."
  send_boc_payload "$boc_file" "$normalized_mode" || rc=$?

  if (( rc != 0 )); then
    print_wallet_deploy_failure_hint "$wallet_name"
    return "$rc"
  fi
  return 0
}

record_wallet_deploy_network() {
  local wallet_name="$1"
  local meta_file="${MAIN_WALLET_DIR}/${wallet_name}.wallet.meta"
  local network

  if [[ ! -f "$meta_file" ]]; then
    echo "Warning: wallet metadata file not found for '${wallet_name}'; cannot record deployment network." >&2
    return 0
  fi

  network="$(resolve_current_wallet_network || true)"
  network="$(trim_whitespace "$network")"
  if [[ -z "$network" ]]; then
    echo "Warning: cannot infer deployment network for '${wallet_name}'; wallet show will not query balance/seqno." >&2
    return 0
  fi

  write_meta_value network "$network" "$meta_file"
}

main_wallet_create() {
  local workchain="${1:-0}"
  local subwallet_id="${2:-42}"
  local wallet_name="${3:-$MAIN_WALLET_NAME_DEFAULT}"
  local wallet_fif tmp_wallet_fif fift_bin

  if ! wallet_fif="$(resolve_new_wallet_fif)"; then
    echo "Error: new-wallet-v3.fif not found in ${SMARTCONT_DIR}." >&2
    return 1
  fi
  fift_bin="$(resolve_fift_bin || true)"
  fift_bin="$(trim_whitespace "$fift_bin")"
  if [[ -z "$fift_bin" ]]; then
    echo "Error: fift binary not found." >&2
    return 1
  fi

  mkdir -p "$MAIN_WALLET_DIR"
  tmp_wallet_fif="${MAIN_WALLET_DIR}/new-wallet-v3.fif"
  if [[ "$wallet_fif" != "$tmp_wallet_fif" ]]; then
    cp -f "$wallet_fif" "$tmp_wallet_fif"
  fi

  local create_log
  local wallet_address non_bounceable bounceable meta_file network
  create_log="$(mktemp)"

  if ! (
    cd "$MAIN_WALLET_DIR" || exit 1
    export FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}"
    "$fift_bin" -s "./new-wallet-v3.fif" "$workchain" "$subwallet_id" "$wallet_name" >"$create_log" 2>&1
  ); then
    cat "$create_log"
    rm -f "$create_log"
    return 1
  fi

  wallet_address="$(sed -n 's/^new wallet address = \([^[:space:]]*\).*/\1/p' "$create_log" | tail -n1)"
  non_bounceable="$(sed -n 's/^Non-bounceable address (for init):[[:space:]]*\(.*\)$/\1/p' "$create_log" | tail -n1)"
  bounceable="$(sed -n 's/^Bounceable address (for later access):[[:space:]]*\(.*\)$/\1/p' "$create_log" | tail -n1)"
  wallet_address="$(ton_address_to_hex "$wallet_address" || true)"
  if [[ -s "$MAIN_WALLET_DIR/${wallet_name}.addr" ]]; then
    local file_address
    file_address="$(wallet_address_file_to_hex "$MAIN_WALLET_DIR/${wallet_name}.addr" || true)"
    [[ -z "$file_address" ]] || wallet_address="$file_address"
  fi
  network="$(resolve_current_wallet_network || true)"
  # Upstream new-wallet-v3.fif prints 7/6 .Addr, which always sets the
  # test-only flag. Match the saved account before using the active network.
  non_bounceable="$(wallet_matching_friendly_address "$non_bounceable" "$wallet_address" "$network" || true)"
  bounceable="$(wallet_matching_friendly_address "$bounceable" "$wallet_address" "$network" || true)"
  awk -v non_bounceable="${non_bounceable:-unknown}" -v bounceable="${bounceable:-unknown}" '
    /^Non-bounceable address \(for init\):/ { print "Non-bounceable address (for init): " non_bounceable; next }
    /^Bounceable address \(for later access\):/ { print "Bounceable address (for later access): " bounceable; next }
    { print }
  ' "$create_log"
  rm -f "$create_log"

  meta_file="$MAIN_WALLET_DIR/${wallet_name}.wallet.meta"
  {
    echo "wallet_name=${wallet_name}"
    echo "workchain=${workchain}"
    echo "wallet_id=${subwallet_id}"
    echo "wallet_version=v3"
    echo "wallet_address=${wallet_address}"
    echo "non_bounceable=${non_bounceable}"
    echo "bounceable=${bounceable}"
    [[ -z "$network" ]] || echo "network=${network}"
  } > "$meta_file"
  chmod 600 "$meta_file"
}

wallet_show_chain_state() {
  local wallet_name="$1"
  local wallet_address="$2"
  local wallet_network="$3"
  local active_network query_address balance_nano balance seqno

  balance="unknown"
  seqno="unknown"
  wallet_network="$(normalize_wallet_network_name "$wallet_network" 2>/dev/null || true)"
  active_network="$(resolve_current_wallet_network || true)"
  query_address="$(ton_address_to_hex "$wallet_address" 2>/dev/null || true)"
  query_address="$(trim_whitespace "$query_address")"
  if [[ -z "$active_network" || ! "$query_address" =~ ^-?[0-9]+:[0-9A-Fa-f]{64}$ ]]; then
    printf '%s\t%s' "$balance" "$seqno"
    return 0
  fi

  if [[ -n "$wallet_network" && "$wallet_network" != "$active_network" ]]; then
    echo "Warning: wallet '${wallet_name}' is saved for ${wallet_network}, but the active fleet uses ${active_network}; balance and seqno are unknown." >&2
    printf '%s\t%s' "$balance" "$seqno"
    return 0
  fi
  wallet_network="$active_network"

  balance_nano="$(wallet_balance_nano "$query_address" 2>/dev/null || true)"
  balance_nano="$(trim_whitespace "$balance_nano")"
  if [[ "$balance_nano" =~ ^[0-9]+$ ]]; then
    balance="$(nano_to_gram_amount "$balance_nano" || true)"
    balance="$(trim_whitespace "$balance")"
    [[ -z "$balance" ]] && balance="unknown"
  else
    echo "Warning: failed to resolve balance for wallet '${wallet_name}' on ${wallet_network}; showing unknown." >&2
  fi

  seqno="$(wallet_seqno_decimal "$query_address" 2>/dev/null || true)"
  seqno="$(trim_whitespace "$seqno")"
  if ! [[ "$seqno" =~ ^[0-9]+$ ]]; then
    echo "Warning: failed to resolve seqno for wallet '${wallet_name}' on ${wallet_network}; showing unknown." >&2
    seqno="unknown"
  fi

  printf '%s\t%s' "$balance" "$seqno"
}

main_wallet_show() {
  local filter_wallet_name="${1:-}"
  if (( $# > 1 )); then
    echo "Error: usage: main-wallet.sh show [wallet-name]" >&2
    return 1
  fi
  filter_wallet_name="$(trim_whitespace "$filter_wallet_name")"

  local -a rows=()
  local meta_file addr_file wallet_name
  local workchain wallet_id wallet_version wallet_address non_bounceable bounceable network balance seqno chain_state

  mkdir -p "$MAIN_WALLET_DIR"

  shopt -s nullglob
  for meta_file in "$MAIN_WALLET_DIR"/*.wallet.meta; do
    wallet_name="$(read_meta_value wallet_name "$meta_file")"
    wallet_name="$(trim_whitespace "$wallet_name")"
    if [[ -z "$wallet_name" ]]; then
      wallet_name="${meta_file##*/}"
      wallet_name="${wallet_name%.wallet.meta}"
    fi
    if [[ -n "$filter_wallet_name" && "$wallet_name" != "$filter_wallet_name" ]]; then
      continue
    fi

    workchain="$(trim_whitespace "$(read_meta_value workchain "$meta_file")")"
    wallet_id="$(trim_whitespace "$(read_meta_value wallet_id "$meta_file")")"
    wallet_version="$(main_wallet_version_by_name "$wallet_name")"
    wallet_address="$(resolve_wallet_address_by_name "$wallet_name" || true)"
    non_bounceable="$(trim_whitespace "$(read_meta_value non_bounceable "$meta_file")")"
    bounceable="$(trim_whitespace "$(read_meta_value bounceable "$meta_file")")"
    network="$(normalize_wallet_network_name "$(read_meta_value network "$meta_file")" 2>/dev/null || true)"
    network="$(trim_whitespace "$network")"
    if [[ -z "$network" ]]; then
      network="$(resolve_current_wallet_network || true)"
      [[ -n "$network" ]] || network=unknown
    fi
    # The .addr account is authoritative. Correct only presentation flags on
    # valid metadata for that account; retain genuine saved-network guards.
    non_bounceable="$(wallet_matching_friendly_address "$non_bounceable" "$wallet_address" "$network" || true)"
    bounceable="$(wallet_matching_friendly_address "$bounceable" "$wallet_address" "$network" || true)"

    [[ -z "$workchain" ]] && workchain="unknown"
    [[ -z "$wallet_id" ]] && wallet_id="unknown"
    [[ -z "$wallet_address" ]] && wallet_address="unknown"
    [[ -z "$non_bounceable" ]] && non_bounceable="unknown"
    [[ -z "$bounceable" ]] && bounceable="unknown"
    chain_state="$(wallet_show_chain_state "$wallet_name" "$wallet_address" "$network" || true)"
    IFS=$'\t' read -r balance seqno <<<"$chain_state"
    [[ -z "$balance" ]] && balance="unknown"
    [[ -z "$seqno" ]] && seqno="unknown"

    rows+=("${workchain}"$'\t'"${wallet_id}"$'\t'"${wallet_name}"$'\t'"${network}"$'\t'"${balance}"$'\t'"${seqno}"$'\t'"${wallet_version}"$'\t'"${wallet_address}"$'\t'"${non_bounceable}"$'\t'"${bounceable}")
  done

  for addr_file in "$MAIN_WALLET_DIR"/*.addr; do
    wallet_name="${addr_file##*/}"
    wallet_name="${wallet_name%.addr}"
    if [[ -n "$filter_wallet_name" && "$wallet_name" != "$filter_wallet_name" ]]; then
      continue
    fi
    if [[ -f "$MAIN_WALLET_DIR/${wallet_name}.wallet.meta" ]]; then
      continue
    fi
    wallet_address="$(wallet_address_file_to_hex "$addr_file" || true)"
    [[ -n "$wallet_address" ]] || wallet_address=unknown
    workchain="unknown"
    if [[ "$wallet_address" == *:* ]]; then
      workchain="$(trim_whitespace "${wallet_address%%:*}")"
      [[ -z "$workchain" ]] && workchain="unknown"
    fi
    network="$(resolve_current_wallet_network || true)"
    [[ -n "$network" ]] || network=unknown
    wallet_version="$(main_wallet_version_by_name "$wallet_name")"
    chain_state="$(wallet_show_chain_state "$wallet_name" "$wallet_address" "$network" || true)"
    IFS=$'\t' read -r balance seqno <<<"$chain_state"
    rows+=("${workchain}"$'\t'"unknown"$'\t'"${wallet_name}"$'\t'"${network}"$'\t'"${balance:-unknown}"$'\t'"${seqno:-unknown}"$'\t'"${wallet_version}"$'\t'"${wallet_address:-unknown}"$'\t'"unknown"$'\t'"unknown")
  done
  shopt -u nullglob

  if [[ ${#rows[@]} -eq 0 ]]; then
    if [[ -n "$filter_wallet_name" ]]; then
      echo "No wallet found with name '${filter_wallet_name}'."
      return 0
    fi
    echo "No wallets found."
    return 0
  fi

  {
    echo -e "workchain\twallet-id\twallet-name\tnetwork\tbalance\tseqno\twallet-version\twallet-address\tnon-bounceable\tbounceable"
    printf '%s\n' "${rows[@]}" | sort
  } | awk -F'\t' '
    {
      if (NF > max_nf) max_nf = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > width[i]) width[i] = length($i)
      }
      rows = NR
    }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        for (i = 1; i <= max_nf; i++) {
          val = cell[r, i]
          fmt = "%-" width[i] "s"
          if (i == 1) line = sprintf(fmt, val)
          else line = line "  " sprintf(fmt, val)
        }
        print line
      }
    }
  '
}

main_wallet_export() {
  local wallet_name="${1:-}"
  local pk_file addr_file meta_file candidate candidate_hex address address_hex private_key_hex
  local subwallet_id
  local -a candidates=()

  if (( $# != 1 )); then
    echo "Error: usage: main-wallet.sh export <wallet-name>" >&2
    return 1
  fi
  wallet_name="$(trim_whitespace "$wallet_name")"
  if ! [[ "$wallet_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: invalid wallet name '${wallet_name}'." >&2
    return 1
  fi

  pk_file="${MAIN_WALLET_DIR}/${wallet_name}.pk"
  addr_file="${MAIN_WALLET_DIR}/${wallet_name}.addr"
  meta_file="${MAIN_WALLET_DIR}/${wallet_name}.wallet.meta"
  if [[ ! -r "$pk_file" ]]; then
    echo "Error: private key file not found or not readable for '${wallet_name}' (expected ${pk_file})." >&2
    return 1
  fi

  address_hex="$(wallet_address_file_to_hex "$addr_file" || true)"
  address="${address_hex:-unknown}"
  address_hex="${address_hex:-unknown}"
  if [[ -s "$addr_file" ]]; then
    candidate="$(wallet_address_file_text "$addr_file" || true)"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
  fi
  if [[ -s "$meta_file" ]]; then
    candidate="$(trim_whitespace "$(read_meta_value wallet_address "$meta_file")")"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
    candidate="$(trim_whitespace "$(read_meta_value non_bounceable "$meta_file")")"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
    candidate="$(trim_whitespace "$(read_meta_value bounceable "$meta_file")")"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
  fi

  for candidate in "${candidates[@]}"; do
    candidate="$(trim_whitespace "$candidate")"
    [[ -z "$candidate" || "$candidate" == "unknown" ]] && continue
    candidate_hex="$(ton_address_to_hex "$candidate" || true)"
    [[ -n "$candidate_hex" ]] || continue
    # A valid .addr file is authoritative. Old metadata must not replace its
    # account with another address; matching friendly addresses can be shown.
    if [[ "$address_hex" != unknown && "$candidate_hex" != "$address_hex" ]]; then
      continue
    fi
    address_hex="$candidate_hex"
    [[ "$address" != unknown ]] || address="$candidate_hex"
    if [[ "$candidate" != *:* ]]; then
      address="$candidate"
      break
    fi
  done

  private_key_hex="$(file_bytes_to_hex "$pk_file" || true)"
  private_key_hex="$(trim_whitespace "$private_key_hex")"
  if ! [[ "$private_key_hex" =~ ^[0-9A-Fa-f]+$ ]]; then
    echo "Error: failed to export private key hex for '${wallet_name}'." >&2
    return 1
  fi
  private_key_hex="$(printf '%s' "$private_key_hex" | tr '[:upper:]' '[:lower:]')"
  subwallet_id="$(resolve_wallet_subwallet_id_by_name "$wallet_name" || true)"
  subwallet_id="$(trim_whitespace "$subwallet_id")"
  [[ -z "$subwallet_id" ]] && subwallet_id="unknown"

  {
    echo -e "wallet-name\tsubwallet-id\twallet-address\taddress-hex\tprivate-key-hex"
    printf '%s\t%s\t%s\t%s\t%s\n' "$wallet_name" "$subwallet_id" "$address" "$address_hex" "$private_key_hex"
  } | awk -F'\t' '
    {
      if (NF > max_nf) max_nf = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > width[i]) width[i] = length($i)
      }
      rows = NR
    }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        for (i = 1; i <= max_nf; i++) {
          val = cell[r, i]
          fmt = "%-" width[i] "s"
          if (i == 1) line = sprintf(fmt, val)
          else line = line "  " sprintf(fmt, val)
        }
        print line
      }
    }
  '
}

main_wallet_deploy() {
  local wallet_name="${1:-}"
  local boc_file
  local normalized_mode
  local -a boc_files=()
  local -a failed_wallets=()
  local file base

  if (( $# > 1 )); then
    echo "Error: usage: main-wallet.sh deploy [wallet-name]" >&2
    return 1
  fi

  normalized_mode="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "$wallet_name" ]]; then
    boc_file="${MAIN_WALLET_DIR}/${wallet_name}-query.boc"
    if [[ ! -s "$boc_file" ]]; then
      echo "Error: missing BOC file ${boc_file}. Run create first." >&2
      return 1
    fi
    require_wallet_network_match "$wallet_name" || return $?
    deploy_boc_with_mode "$wallet_name" "$boc_file" "$normalized_mode" || return $?
    record_wallet_deploy_network "$wallet_name"
    return 0
  fi

  shopt -s nullglob
  for file in "$MAIN_WALLET_DIR"/*-query.boc; do
    if [[ -s "$file" ]]; then
      boc_files+=("$file")
    fi
  done
  shopt -u nullglob

  if [[ ${#boc_files[@]} -eq 0 ]]; then
    echo "Error: no wallet query BOC files found in ${MAIN_WALLET_DIR}. Run create first." >&2
    return 1
  fi

  # Check the complete set before publishing any deployment messages.
  for file in "${boc_files[@]}"; do
    base="${file##*/}"
    require_wallet_network_match "${base%-query.boc}" || return $?
  done

  for file in "${boc_files[@]}"; do
    base="${file##*/}"
    wallet_name="${base%-query.boc}"
    if deploy_boc_with_mode "$wallet_name" "$file" "$normalized_mode"; then
      record_wallet_deploy_network "$wallet_name"
    else
      failed_wallets+=("$wallet_name")
    fi
  done

  if [[ ${#failed_wallets[@]} -gt 0 ]]; then
    echo "Error: failed to deploy wallet(s): ${failed_wallets[*]}" >&2
    return 1
  fi
  return 0
}

resolve_wallet_address_by_name() {
  local wallet_name="$1"
  local wallet_meta="$MAIN_WALLET_DIR/${wallet_name}.wallet.meta"
  local wallet_addr_file="$MAIN_WALLET_DIR/${wallet_name}.addr"
  local wallet_address="" key

  if wallet_address="$(wallet_address_file_to_hex "$wallet_addr_file")"; then
    printf '%s' "$wallet_address"
    return 0
  fi

  if [[ -f "$wallet_meta" ]]; then
    for key in wallet_address non_bounceable bounceable; do
      wallet_address="$(ton_address_to_hex "$(read_meta_value "$key" "$wallet_meta")" || true)"
      [[ -n "$wallet_address" ]] || continue
      printf '%s' "$wallet_address"
      return 0
    done
  fi

  return 1
}

resolve_wallet_subwallet_id_by_name() {
  local wallet_name="$1"
  local wallet_meta="$MAIN_WALLET_DIR/${wallet_name}.wallet.meta"
  local subwallet_id=""

  if [[ -f "$wallet_meta" ]]; then
    subwallet_id="$(read_meta_value wallet_id "$wallet_meta")"
    subwallet_id="$(trim_whitespace "$subwallet_id")"
    if [[ "$subwallet_id" =~ ^[0-9]+$ ]]; then
      printf '%s' "$subwallet_id"
      return 0
    fi
  fi

  # Keep compatibility with historical defaults when wallet metadata is absent.
  printf '%s' "42"
}

# Regenerate the initialization message from the existing key, never from a new
# key or an unchecked saved BOC. Matching the derived account proves that the
# workchain, wallet id, public key and V3 contract code describe this wallet.
wallet_build_deploy_boc() (
  local wallet_name="$1" destination="${2:-${MAIN_WALLET_DIR}/${1}-verified-init.boc}"
  local wallet_address generated_address workchain wallet_id wallet_fif fift_bin tmp_dir
  wallet_address="$(resolve_wallet_address_by_name "$wallet_name")" || return 1
  [[ "$wallet_address" =~ ^-?[0-9]+:[0-9A-Fa-f]{64}$ ]] || return 1
  workchain="${wallet_address%%:*}"
  wallet_id="$(read_meta_value wallet_id "${MAIN_WALLET_DIR}/${wallet_name}.wallet.meta" 2>/dev/null || true)"
  if ! [[ "$wallet_id" =~ ^[0-9]{1,10}$ ]] || (( 10#$wallet_id > 4294967295 )); then
    echo "Error: cannot verify V3 initialization for '${wallet_name}': a valid saved wallet-id is required." >&2
    return 1
  fi
  [[ -s "${MAIN_WALLET_DIR}/${wallet_name}.pk" ]] || {
    echo "Error: existing private-key file is missing for '${wallet_name}'; refusing to generate a replacement key." >&2
    return 1
  }
  wallet_fif="$(resolve_new_wallet_fif)" || return 1
  fift_bin="$(resolve_fift_bin)" || return 1
  umask 077
  # Keep copied key material on the helper's existing memory-backed runtime.
  tmp_dir="$(mktemp -d "$MAIN_WALLET_DIR/.wallet-init.XXXXXX")" || return 1
  trap 'rm -rf "$tmp_dir"' EXIT
  cp "${MAIN_WALLET_DIR}/${wallet_name}.pk" "$tmp_dir/wallet.pk" || return 1
  if ! (
    cd "$tmp_dir" || exit 1
    export FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}"
    "$fift_bin" -s "$wallet_fif" "$workchain" "$wallet_id" "$tmp_dir/wallet" >"$tmp_dir/fift.log" 2>&1
  ); then
    echo "Error: could not rebuild the V3 initialization message for '${wallet_name}'." >&2
    return 1
  fi
  generated_address="$(wallet_address_file_to_hex "$tmp_dir/wallet.addr")" || return 1
  if [[ "$generated_address" != "$wallet_address" || ! -s "$tmp_dir/wallet-query.boc" ]] ||
    ! cmp -s "${MAIN_WALLET_DIR}/${wallet_name}.pk" "$tmp_dir/wallet.pk"; then
    echo "Error: rebuilt V3 initialization does not match '${wallet_name}'; original wallet files are unchanged." >&2
    return 1
  fi
  cp "$tmp_dir/wallet-query.boc" "$destination" || return 1
  chmod 600 "$destination" || return 1
  printf '%s' "$destination"
)

main_wallet_version_by_name() {
  local wallet_name="$1" version="" tmp_boc
  local meta_file="${MAIN_WALLET_DIR}/${1}.wallet.meta"
  [[ ! -f "$meta_file" ]] || version="$(trim_whitespace "$(read_meta_value wallet_version "$meta_file")")"
  if [[ "$version" =~ ^[vV][0-9]+([rR][0-9]+)?$ ]]; then
    printf '%s' "$version"
    return 0
  fi
  # Historical metadata predates wallet_version. Verify the actual account
  # against the V3 constructor before identifying it; filenames alone prove
  # neither a version nor a contract revision. Show must not rewrite metadata.
  if [[ -f "$meta_file" ]] && tmp_boc="$(mktemp)"; then
    if wallet_build_deploy_boc "$wallet_name" "$tmp_boc" >/dev/null 2>&1; then
      rm -f "$tmp_boc"
      printf '%s' v3
      return 0
    fi
    rm -f "$tmp_boc"
  fi
  printf '%s' unknown
}

# The official runtime image includes jq. Keep HTTPS reads tied to the active
# fleet network; a saved wallet label or an unrelated API must not supply seqno.
wallet_request_timeout() {
  local maximum="${1:-15}" remaining
  if [[ -n "${WALLET_QUERY_DEADLINE:-}" ]]; then
    remaining=$((WALLET_QUERY_DEADLINE - $(date +%s)))
    (( remaining > 0 )) || return 1
    (( maximum <= remaining )) || maximum="$remaining"
  fi
  printf '%s' "$maximum"
}

wallet_bounded_sleep() {
  local seconds="$1" remaining
  if [[ -n "${WALLET_QUERY_DEADLINE:-}" ]]; then
    remaining=$((WALLET_QUERY_DEADLINE - $(date +%s)))
    (( remaining > 0 )) || return 1
    (( seconds <= remaining )) || seconds="$remaining"
  fi
  (( seconds == 0 )) || sleep "$seconds"
}

wallet_toncenter_base() {
  local network
  network="$(resolve_current_wallet_network)" || return 1
  case "${TONCENTER_URL%/}" in
    https://toncenter.com) [[ "$network" == mainnet ]] || return 1 ;;
    https://testnet.toncenter.com) [[ "$network" == testnet ]] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s/api/v2' "${TONCENTER_URL%/}"
}

# Keep anonymous requests below TONCenter's one-request-per-second limit,
# including across command substitutions. This file contains only a timestamp.
wallet_http_pace() {
  local interval="${MAIN_WALLET_HTTP_MIN_INTERVAL_MS:-1100}" now previous=0 wait_ms remaining
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1100
  (( interval > 0 )) && [[ -d "$MAIN_WALLET_DIR" ]] || return 0
  now="$(date +%s%3N)" || return 1
  if [[ -f "$MAIN_WALLET_DIR/.http-last-call" ]]; then
    read -r previous <"$MAIN_WALLET_DIR/.http-last-call" || previous=0
    [[ "$previous" =~ ^[0-9]+$ ]] || previous=0
  fi
  wait_ms=$((previous + interval - now))
  if (( wait_ms > 0 )); then
    if [[ -n "${WALLET_QUERY_DEADLINE:-}" ]]; then
      remaining=$((WALLET_QUERY_DEADLINE * 1000 - now))
      (( wait_ms < remaining )) || return 1
    fi
    sleep "$(printf '%d.%03d' "$((wait_ms / 1000))" "$((wait_ms % 1000))")" || return 1
  fi
  date +%s%3N >"$MAIN_WALLET_DIR/.http-last-call"
}

wallet_toncenter_get() (
  local method="$1" base parameter response headers timeout connect attempt code curl_rc retry_after=1
  shift
  local WALLET_QUERY_DEADLINE="${WALLET_QUERY_DEADLINE:-$(($(date +%s) + 15))}"
  local -a curl_args=()
  base="$(wallet_toncenter_base)" || return 1
  [[ "$method" =~ ^[A-Za-z]+$ ]] || return 1
  [[ -z "$TONCENTER_API_KEY" ]] || curl_args+=(-H "X-API-Key: ${TONCENTER_API_KEY}")
  for parameter in "$@"; do curl_args+=(--data-urlencode "$parameter"); done
  headers="$(mktemp)" || return 1
  trap 'rm -f "$headers"' EXIT
  for ((attempt = 1; attempt <= 3; attempt++)); do
    wallet_http_pace || return 1
    timeout="$(wallet_request_timeout 15)" || return 1
    connect="$timeout"; (( connect <= 5 )) || connect=5
    : >"$headers"
    if response="$(curl -fsS --connect-timeout "$connect" --max-time "$timeout" \
      --dump-header "$headers" --get "${curl_args[@]}" "$base/$method")"; then
      printf '%s' "$response"
      return 0
    else
      curl_rc=$?
    fi
    code="$(awk '/^HTTP\// {code=$2} END {print code}' "$headers")"
    case "$code" in
      '') case "$curl_rc" in 6|7|28|52|56) ;; *) return 1 ;; esac ;;
      429|5??) ;;
      *) return 1 ;;
    esac
    retry_after="$(awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$headers" | tail -n1)"
    [[ "$retry_after" =~ ^[0-9]{1,3}$ ]] || retry_after=1
    (( attempt == 3 )) || wallet_bounded_sleep "$retry_after" || return 1
  done
  return 1
)

wallet_toncenter_information() {
  local wallet_address="$1" response
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$wallet_address" =~ ^-?[0-9]+:[0-9A-Fa-f]{64}$ ]] || return 1
  response="$(wallet_toncenter_get getWalletInformation "address=${wallet_address}")" || return 1
  printf '%s' "$response" | jq -ers '
    select(length == 1) | .[0] |
    select(.ok == true and (.result | type) == "object") | .result |
    (.account_state | if . == "uninitialized" or . == "uninit" then "uninit"
      elif . == "active" or . == "frozen" or . == "nonexist" then . else empty end) as $state |
    (.balance | tostring | select(test("^[0-9]+$"))) as $balance |
    (if $state == "uninit" or $state == "nonexist" then "0"
      elif $state == "active" and .wallet == true and (.seqno | type) == "number"
        and .seqno >= 0 and .seqno <= 4294967295 and .seqno == (.seqno | floor)
        then (.seqno | tostring) else "unknown" end) as $seqno |
    [$state, $balance, $seqno] | @tsv'
}

# Hash the signed external-message body cell, rather than the BOC file bytes.
# TONCenter exposes this exact hash as in_msg.body_hash, independent of whether
# the message body or its StateInit was stored inline or in a reference.
wallet_message_body_hash() (
  local boc_file="$1" fift_bin script_file body_hash
  [[ -s "$boc_file" ]] || return 1
  fift_bin="$(resolve_fift_bin)" || return 1
  script_file="$(mktemp "$MAIN_WALLET_DIR/.wallet-body-hash.XXXXXX.fif")" || return 1
  trap 'rm -f "$script_file"' EXIT
  cat >"$script_file" <<'FIF'
"TonUtil.fif" include
{ 1 u@+ swap { ref@+ drop } if } : skip-maybe-ref
{ 1 u@+ swap { 5 u@+ nip } if
  1 u@+ swap { 2 u@+ nip } if
  skip-maybe-ref skip-maybe-ref skip-maybe-ref
} : skip-inline-stateinit
$1 file>B B>boc <s
7 u@+ swap 68 <> abort"unsupported external message header"
8 u@+ nip 256 u@+ nip
Gram@+ swap 0<> abort"nonzero import fee"
1 u@+ swap {
  1 u@+ swap { ref@+ drop } { skip-inline-stateinit } cond
} if
1 u@+ swap { ref@ } { s>c } cond
hashu 256 u>B B>base64 type cr
FIF
  body_hash="$(FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}" \
    "$fift_bin" -s "$script_file" "$boc_file" 2>/dev/null)" || return 1
  [[ "$body_hash" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  printf '%s' "$body_hash"
)

# Return 0 with LT<TAB>transaction-hash only for this exact signed request and
# its expected outgoing payment. 10 means it is not present in the returned
# history yet; 11 means it was consumed without that outgoing payment. Neither
# API failure nor a missing/cached receipt establishes that a transfer failed.
wallet_transaction_receipt() {
  local source_address="$1" body_hash="$2" destination_address="$3" amount_nano="$4"
  local network response matches transaction_count index transaction source actual_destination
  local lt transaction_hash outgoing output_source output_destination output_value output_lines
  source_address="$(ton_address_to_hex "$source_address")" || return 1
  destination_address="$(ton_address_to_hex "$destination_address")" || return 1
  [[ "$body_hash" =~ ^[A-Za-z0-9+/]{43}=$ && "$amount_nano" =~ ^[0-9]+$ ]] || return 1
  network="$(resolve_current_wallet_network)" || return 1
  case "${TONCENTER_URL%/}" in
    https://toncenter.com) [[ "$network" == mainnet ]] || return 1 ;;
    https://testnet.toncenter.com) [[ "$network" == testnet ]] || return 1 ;;
    *) return 1 ;;
  esac
  response="$(wallet_toncenter_get getTransactions "address=${source_address}" 'limit=100')" || return 1
  matches="$(printf '%s' "$response" | jq -ecs --arg body_hash "$body_hash" '
    select(length == 1) | .[0] |
    select(.ok == true and (.result | type) == "array") |
    [.result[] | select(.in_msg.body_hash == $body_hash and .in_msg.source == "")]
  ')" || return 1
  transaction_count="$(printf '%s' "$matches" | jq -r length)" || return 1
  (( transaction_count > 0 )) || return 10
  for ((index = 0; index < transaction_count; index++)); do
    transaction="$(printf '%s' "$matches" | jq -ec --argjson index "$index" '.[$index] |
      select((.in_msg.destination | type) == "string" and (.out_msgs | type) == "array"
        and (.transaction_id.lt | type) == "string" and (.transaction_id.lt | test("^[0-9]+$"))
        and (.transaction_id.hash | type) == "string" and (.transaction_id.hash | test("^[A-Za-z0-9+/]{43}=$"))
        and all(.out_msgs[]; (.source | type) == "string" and (.destination | type) == "string"
          and (.value | type) == "string" and (.value | test("^[0-9]+$"))))')" || return 1
    actual_destination="$(printf '%s' "$transaction" | jq -r '.in_msg.destination')" || return 1
    actual_destination="$(ton_address_to_hex "$actual_destination")" || return 1
    [[ "$actual_destination" == "$source_address" ]] || return 1
    if printf '%s' "$transaction" | jq -e '.aborted == true or .description.aborted == true' >/dev/null; then
      return 11
    fi
    output_lines="$(printf '%s' "$transaction" | jq -er '
      [.out_msgs[] | [.source, .destination, .value] | @tsv] | join("\n")')" || return 1
    while IFS=$'\t' read -r output_source output_destination output_value; do
      [[ -n "$output_source" ]] || continue
      [[ "$output_value" =~ ^[0-9]+$ ]] || return 1
      source="$(ton_address_to_hex "$output_source")" || return 1
      outgoing="$(ton_address_to_hex "$output_destination")" || return 1
      [[ "$source" == "$source_address" && "$outgoing" == "$destination_address" && "$output_value" == "$amount_nano" ]] || continue
      lt="$(printf '%s' "$transaction" | jq -r '.transaction_id.lt')" || return 1
      transaction_hash="$(printf '%s' "$transaction" | jq -r '.transaction_id.hash')" || return 1
      printf '%s\t%s' "$lt" "$transaction_hash"
      return 0
    done <<<"$output_lines"
  done
  return 11
}

# Before replacing an expired signed request, pin both the clock observation
# and the unchanged wallet counter to the same masterchain snapshot. The
# replacement must retain the original seqno, destination and amount.
wallet_expired_message_unconsumed() {
  local source_address="$1" old_seqno="$2" expiry="$3"
  local info block block_seqno root_hash file_hash header block_time wallet
  source_address="$(ton_address_to_hex "$source_address")" || return 1
  [[ "$old_seqno" =~ ^[0-9]{1,10}$ && "$expiry" =~ ^[0-9]{1,10}$ ]] || return 1
  (( 10#$old_seqno <= 4294967295 && 10#$expiry <= 4294967295 )) || return 1
  old_seqno="$((10#$old_seqno))"
  expiry="$((10#$expiry))"
  info="$(wallet_toncenter_get getMasterchainInfo)" || return 1
  block="$(printf '%s' "$info" | jq -ers '
    select(length == 1) | .[0] | select(.ok == true) | .result.last |
    select(.workchain == -1 and (.shard | tostring) == "-9223372036854775808"
      and (.seqno | type) == "number" and .seqno > 0 and .seqno <= 4294967295
      and .seqno == (.seqno | floor)
      and (.root_hash | type) == "string" and (.root_hash | test("^[A-Za-z0-9+/]{43}=$"))
      and (.file_hash | type) == "string" and (.file_hash | test("^[A-Za-z0-9+/]{43}=$"))) |
    [.seqno, .root_hash, .file_hash] | @tsv')" || return 1
  IFS=$'\t' read -r block_seqno root_hash file_hash <<<"$block"
  header="$(wallet_toncenter_get getBlockHeader 'workchain=-1' 'shard=-9223372036854775808' \
    "seqno=${block_seqno}" "root_hash=${root_hash}" "file_hash=${file_hash}")" || return 1
  block_time="$(printf '%s' "$header" | jq -ers --argjson seqno "$block_seqno" --arg root_hash "$root_hash" --arg file_hash "$file_hash" '
    select(length == 1) | .[0] | select(.ok == true) | .result |
    select(.id.workchain == -1 and (.id.shard | tostring) == "-9223372036854775808"
      and .id.seqno == $seqno and .id.root_hash == $root_hash and .id.file_hash == $file_hash
      and (.gen_utime | type) == "number" and .gen_utime >= 0 and .gen_utime <= 4294967295
      and .gen_utime == (.gen_utime | floor)) | .gen_utime')" || return 1
  (( block_time > expiry + 10 )) || return 1
  wallet="$(wallet_toncenter_get getWalletInformation "address=${source_address}" "seqno=${block_seqno}")" || return 1
  printf '%s' "$wallet" | jq -es --argjson old_seqno "$old_seqno" '
    length == 1 and (.[0] | .ok == true and .result.wallet == true
      and .result.account_state == "active" and (.result.seqno | type) == "number"
      and .result.seqno == $old_seqno)' >/dev/null || return 1
  jq -nc --argjson masterchain_seqno "$block_seqno" --argjson gen_utime "$block_time" --argjson wallet_seqno "$old_seqno" \
    '{masterchain_seqno:$masterchain_seqno,gen_utime:$gen_utime,wallet_seqno:$wallet_seqno}'
}

parse_account_status() {
  local output="$1" status
  if liteclient_account_state_is_empty "$output"; then
    printf '%s' nonexist
    return 0
  fi
  for status in uninit active frozen; do
    if printf '%s\n' "$output" | grep -Eiq "state:[[:space:]]*\(?[[:space:]]*(account_)?${status}([^[:alnum:]_]|$)"; then
      printf '%s' "$status"
      return 0
    fi
  done
  return 1
}

wallet_account_status() {
  local wallet_address="$1" output status api_balance api_seqno
  local WALLET_QUERY_DEADLINE="${WALLET_QUERY_DEADLINE:-$(($(date +%s) + 30))}"
  if output="$(wallet_toncenter_information "$wallet_address")"; then
    IFS=$'\t' read -r status api_balance api_seqno <<<"$output"
    printf '%s' "$status"
    return 0
  fi
  if wallet_request_timeout 15 >/dev/null && output="$(run_liteclient_query "getaccount $wallet_address" 2>/dev/null)" &&
    status="$(parse_account_status "$output")"; then
    printf '%s' "$status"
    return 0
  fi
  echo "Error: cannot determine the on-chain state of source wallet ${wallet_address}." >&2
  return 1
}

wallet_wait_for_seqno() {
  local wallet_address="$1" expected="$2" attempt attempts delay seqno timeout_sec
  attempts="$(main_wallet_confirm_attempts)"
  delay="$(main_wallet_confirm_delay_seconds)"
  timeout_sec="${MAIN_WALLET_CONFIRM_TIMEOUT_SEC:-180}"
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || timeout_sec=180
  local WALLET_QUERY_DEADLINE="$(($(date +%s) + timeout_sec))"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    wallet_request_timeout 15 >/dev/null || break
    seqno="$(wallet_seqno_decimal "$wallet_address" 2>/dev/null || true)"
    if [[ "$seqno" =~ ^[0-9]+$ ]] && (( 10#$seqno == expected )); then
      printf '%s' "$seqno"
      return 0
    fi
    if [[ "$seqno" =~ ^[0-9]+$ ]] && (( 10#$seqno > expected )); then
      echo "Error: source wallet seqno advanced beyond ${expected}; another operation may be using this wallet. Stopping." >&2
      return 1
    fi
    if (( attempt < attempts )); then wallet_bounded_sleep "$delay" || break; fi
  done
  echo "Error: on-chain confirmation of source wallet seqno=${expected} was not observed within ${timeout_sec}s. Check wallet status before retrying." >&2
  return 1
}

wallet_prepare_source() {
  local wallet_name="$1" wallet_address="$2" normalized_mode="$3"
  local status balance boc_file seqno
  status="$(wallet_account_status "$wallet_address")" || return 1
  case "$status" in
    active)
      if [[ "$(main_wallet_version_by_name "$wallet_name")" != v3 ]]; then
        echo "Error: cannot verify V3 contract identity for source wallet '${wallet_name}'; refusing to sign a transfer with an unknown wallet format." >&2
        return 1
      fi
      wallet_seqno_decimal "$wallet_address"
      ;;
    uninit)
      balance="$(wallet_balance_nano "$wallet_address")" || return 1
      if ! [[ "$balance" =~ ^[0-9]+$ ]] || (( 10#$balance == 0 )); then
        echo "Error: fund '${wallet_name}' at its non-bounceable address before deploying or sending." >&2
        return 1
      fi
      wallet_send_progress "[wallet] '${wallet_name}' is funded but undeployed; deploying its verified V3 contract before sending."
      boc_file="$(wallet_build_deploy_boc "$wallet_name")" || return 1
      if ! deploy_boc_with_mode "$wallet_name" "$boc_file" "$normalized_mode" >&2; then
        rm -f "$boc_file"
        echo "Error: wallet deployment submission failed; no transfers were attempted. Check its status before retrying." >&2
        return 1
      fi
      rm -f "$boc_file"
      seqno="$(wallet_wait_for_seqno "$wallet_address" 1)" || return 1
      record_wallet_deploy_network "$wallet_name"
      printf '%s' "$seqno"
      ;;
    nonexist)
      echo "Error: '${wallet_name}' is not funded or deployed; fund its non-bounceable address first." >&2
      return 1
      ;;
    *)
      echo "Error: source wallet '${wallet_name}' has state '${status}'; no transfers were attempted." >&2
      return 1
      ;;
  esac
}

liteclient_int_token_to_decimal() {
  local token="$1"

  token="$(trim_whitespace "$token")"
  if [[ "$token" =~ ^0x[0-9A-Fa-f]{1,8}$ ]]; then
    printf '%s' "$((16#${token:2}))"
    return 0
  fi
  if [[ "$token" =~ ^[0-9]{1,10}$ ]] && (( 10#$token <= 4294967295 )); then
    printf '%s' "$((10#$token))"
    return 0
  fi
  return 1
}

parse_seqno_from_runmethod_output() {
  local output="${1//$'\r'/}" line result="" capture=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*result:[[:space:]]*\[ ]]; then
      capture=1
      result="${line#*[[]}"
    elif (( capture )); then
      result+=" $line"
    fi
    if (( capture )) && [[ "$result" == *"]"* ]]; then
      # seqno returns exactly one uint32. Error text, other stack entries and
      # truncated output must not be mistaken for an accepted sequence number.
      if [[ "$result" =~ ^[[:space:]]*(0x[0-9A-Fa-f]+|[0-9]+)[[:space:]]*\][[:space:]]*$ ]]; then
        liteclient_int_token_to_decimal "${BASH_REMATCH[1]}"
        return $?
      fi
      return 1
    fi
  done <<<"$output"
  return 1
}

parse_seqno_from_account_output() {
  local output="$1"
  local line seq_hex
  local in_data=0

  while IFS= read -r line; do
    line="${line//$'\r'/}"

    if [[ "$line" =~ data:[[:space:]]*x\{([0-9A-Fa-f]{8,}) ]]; then
      seq_hex="${BASH_REMATCH[1]:0:8}"
      printf '%d' "$((16#$seq_hex))"
      return 0
    fi

    if [[ "$line" =~ data:[[:space:]]*\(just|data:[[:space:]]*x\{ ]]; then
      in_data=1
    fi

    if (( in_data )); then
      if [[ "$line" =~ x\{([0-9A-Fa-f]{8,}) ]]; then
        seq_hex="${BASH_REMATCH[1]:0:8}"
        printf '%d' "$((16#$seq_hex))"
        return 0
      fi
      if [[ "$line" =~ library: ]]; then
        in_data=0
      fi
    fi
  done <<<"$output"

  return 1
}

liteclient_account_state_is_empty() {
  local output="${1//$'\r'/}"

  # Current lite-client prints this sentence instead of an account_none TL-B
  # record when a successfully checked account does not exist on-chain.
  printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*account state is empty[[:space:]]*$|state:[[:space:]]*\(?[[:space:]]*(account_none|none|nonexist)([^[:alnum:]_]|$)|account_none\$0'
}

wallet_seqno_decimal() {
  local wallet_address="$1" output seq_dec attempts delay attempt status api_balance
  local WALLET_QUERY_DEADLINE="${WALLET_QUERY_DEADLINE:-$(($(date +%s) + 30))}"
  # HTTPS first: a responsive but lagging lite-server must not hide a newer
  # source counter, and one poll must fit inside the caller's deadline.
  if output="$(wallet_toncenter_information "$wallet_address" 2>/dev/null)"; then
    IFS=$'\t' read -r status api_balance seq_dec <<<"$output"
    if [[ "$seq_dec" =~ ^[0-9]+$ ]]; then printf '%s' "$seq_dec"; return 0; fi
  fi
  attempts="$(main_wallet_send_retry_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    wallet_request_timeout 15 >/dev/null || break
    if output="$(run_liteclient_query "runmethod $wallet_address seqno" 2>/dev/null)"; then
      seq_dec="$(parse_seqno_from_runmethod_output "$output" || true)"
      if [[ "$seq_dec" =~ ^[0-9]+$ ]]; then printf '%s' "$seq_dec"; return 0; fi
    fi
    wallet_request_timeout 15 >/dev/null || break
    if output="$(run_liteclient_query "getaccount $wallet_address" 2>/dev/null)"; then
      status="$(parse_account_status "$output" || true)"
      if [[ "$status" == nonexist || "$status" == uninit ]]; then printf '%s' 0; return 0; fi
      seq_dec=""
      [[ "$status" != active ]] || seq_dec="$(parse_seqno_from_account_output "$output" || true)"
      if [[ "$seq_dec" =~ ^[0-9]+$ ]]; then printf '%s' "$seq_dec"; return 0; fi
    fi
    if (( attempt < attempts )); then wallet_bounded_sleep "$delay" || break; fi
  done
  echo "Error: cannot resolve wallet seqno from bounded HTTPS/lite-server reads for ${wallet_address}." >&2
  return 1
}

wallet_balance_nano() {
  local wallet_address="$1"
  local output balance attempts delay attempt status api_seqno

  local WALLET_QUERY_DEADLINE="${WALLET_QUERY_DEADLINE:-$(($(date +%s) + 30))}"
  if output="$(wallet_toncenter_information "$wallet_address" 2>/dev/null)"; then
    IFS=$'\t' read -r status balance api_seqno <<<"$output"
    if [[ "$balance" =~ ^[0-9]+$ ]]; then printf '%s' "$balance"; return 0; fi
  fi
  attempts="$(main_wallet_send_retry_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    wallet_request_timeout 15 >/dev/null || break
    if output="$(run_liteclient_query "getaccount $wallet_address" 2>/dev/null)"; then
      if liteclient_account_state_is_empty "$output"; then
        printf '%s' "0"
        return 0
      fi
      balance="$(printf '%s\n' "$output" | awk '
        /balance:/ {in_balance=1}
        in_balance && match($0, /value:[[:space:]]*[0-9]+/) {
          v=substr($0, RSTART, RLENGTH)
          sub(/value:[[:space:]]*/, "", v)
          print v
          exit
        }
      ')"
      balance="$(trim_whitespace "$balance")"
      if [[ "$balance" =~ ^[0-9]+$ ]]; then
        printf '%s' "$balance"
        return 0
      fi
    fi

    if (( attempt < attempts )); then
      echo "Warning: failed to parse wallet balance for ${wallet_address} (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        wallet_bounded_sleep "$delay" || break
      fi
    fi
  done

  echo "Error: failed to parse wallet balance for ${wallet_address} after ${attempts} attempts." >&2
  return 1
}

nano_to_gram_amount() {
  local nano="$1"
  local whole frac

  if ! [[ "$nano" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  whole=$((nano / 1000000000))
  frac=$((nano % 1000000000))
  printf '%s.%09d' "$whole" "$frac"
}

gram_amount_to_nano() {
  local amount="$1"
  local normalized whole frac padded

  normalized="$(trim_whitespace "$amount")"
  if ! [[ "$normalized" =~ ^[0-9]+([.][0-9]+)?[.]?$ ]]; then
    return 1
  fi
  if [[ "$normalized" == *"." ]]; then
    normalized="${normalized%.}"
  fi

  whole="$normalized"
  frac=""
  if [[ "$normalized" == *"."* ]]; then
    whole="${normalized%%.*}"
    frac="${normalized#*.}"
  fi

  [[ -z "$whole" ]] && whole="0"
  [[ -z "$frac" ]] && frac="0"
  if ! [[ "$whole" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$frac" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( ${#frac} > 9 )); then
    return 1
  fi

  padded="${frac}"
  while (( ${#padded} < 9 )); do
    padded="${padded}0"
  done

  printf '%s' "$((10#$whole * 1000000000 + 10#$padded))"
}

send_single_transfer() {
  local from_wallet="$1"
  local destination_address="$2"
  local amount_gram="$3"
  local seqno_dec="$4"
  local subwallet_id="$5"
  local normalized_mode="$6"
  local no_bounce_flag="${7:-}"
  local wallet_fif fift_bin base_path query_file
  local -a fift_cmd=()
  local rc=0 expiry body_hash destination_raw amount_nano pending

  wallet_fif="$(resolve_wallet_fif || true)"
  wallet_fif="$(trim_whitespace "$wallet_fif")"
  if [[ -z "$wallet_fif" ]]; then
    echo "Error: wallet-v3.fif not found in ${SMARTCONT_DIR}." >&2
    return 1
  fi

  fift_bin="$(resolve_fift_bin || true)"
  fift_bin="$(trim_whitespace "$fift_bin")"
  if [[ -z "$fift_bin" ]]; then
    echo "Error: fift binary not found." >&2
    return 1
  fi

  base_path="${MAIN_WALLET_DIR}/${from_wallet}"
  if [[ ! -f "${base_path}.pk" || ! -f "${base_path}.addr" ]]; then
    echo "Error: source wallet files are missing for '${from_wallet}' (expected ${base_path}.pk/.addr)." >&2
    return 1
  fi

  query_file="${MAIN_WALLET_DIR}/${from_wallet}-send-${seqno_dec}.boc"
  # A failed Fift invocation must never cause an old signed file to be sent.
  rm -f "$query_file"
  fift_cmd=(
    "$fift_bin" -s "$wallet_fif"
    "$base_path" "$destination_address" "$subwallet_id" "$seqno_dec" "$amount_gram" "${from_wallet}-send-${seqno_dec}"
    -t 180
  )
  if [[ -n "$no_bounce_flag" ]]; then
    if [[ "$no_bounce_flag" != "-n" ]]; then
      echo "Error: unsupported wallet.fif option '${no_bounce_flag}'." >&2
      return 1
    fi
    fift_cmd+=("$no_bounce_flag")
  fi
  if ! (
    cd "$MAIN_WALLET_DIR" || exit 1
    export FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}"
    "${fift_cmd[@]}"
  ); then
    rm -f "$query_file"
    echo "Error: failed to sign the transfer for '${from_wallet}'; no BOC was submitted." >&2
    return 1
  fi
  if [[ ! -s "$query_file" ]]; then
    echo "Error: failed to create transfer BOC ${query_file}." >&2
    return 1
  fi
  # Fift samples its clock while signing. Recording an upper bound after it
  # returns prevents a slow invocation from making the journal expire early.
  expiry=$(($(date +%s) + 180))

  # Commit the exact signed bytes before any transport can see them. The
  # encrypted key bundle and this public outgoing journal have separate lives.
  body_hash="$(wallet_message_body_hash "$query_file")" || {
    rm -f "$query_file"
    echo 'Error: cannot identify the signed transfer body; nothing was broadcast.' >&2
    return 1
  }
  destination_raw="$(ton_address_to_hex "$destination_address")" || return 1
  amount_nano="$(gram_amount_to_nano "$amount_gram")" || return 1
  wallet_outbox_stage "$WALLET_OUTBOX_INDEX" "$seqno_dec" "$expiry" "$body_hash" "$query_file" "$destination_raw" "$amount_nano" || return 1
  pending="$(wallet_outbox_pending)" || return 1
  IFS=$'\t' read -r _ _ _ WALLET_PENDING_BOC _ _ _ <<<"$pending"
  [[ -s "$WALLET_PENDING_BOC" ]] || return 1
  echo "Sending from '${from_wallet}' to '${destination_address}' amount='${amount_gram}' seqno=${seqno_dec} ..."
  local WALLET_QUERY_DEADLINE="$(($(date +%s) + 60))"
  send_boc_payload "$WALLET_PENDING_BOC" "$normalized_mode" || rc=$?
  rm -f "$query_file"
  return "$rc"
}

wallet_outbox_atomic_json() {
  local destination="$1" payload="$2" temporary parent
  parent="${destination%/*}"
  temporary="$(mktemp "$parent/.journal.XXXXXX")" || return 1
  if ! { printf '%s\n' "$payload" > "$temporary" && chmod 600 "$temporary" && sync "$temporary" \
    && mv -f "$temporary" "$destination" && sync "$parent"; }; then
    echo 'Error: could not durably commit the outgoing wallet journal; no further messages may be sent.' >&2
    return 1
  fi
}

wallet_outbox_read_state() {
  local state batch
  [[ -n "${WALLET_OUTBOX_DIR:-}" && -f "$WALLET_OUTBOX_DIR/state.json" && ! -L "$WALLET_OUTBOX_DIR/state.json" ]] || return 1
  state="$(cat "$WALLET_OUTBOX_DIR/state.json")" || return 1
  printf '%s' "$state" | jq -e '
    .version == 1 and (.batch_id | type == "string" and test("^batch-[A-Za-z0-9]+$")) and
    (.plan | type == "object") and (.plan.destinations | type == "array" and length > 0) and
    (.next | type == "number" and . >= 0 and . == floor) and .next <= (.plan.destinations | length) and
    (.confirmed | type == "array") and (.confirmed | length) == .next and
    ([.confirmed[].index] == [range(0;.next)]) and
    all(.confirmed[]; (.transaction_id|type=="string" and length>0)) and
    ((.expired // []) | type == "array") and
    (.complete == true or .complete == false) and
    (if .complete then .next == (.plan.destinations | length) and .pending == null else true end) and
    (if .pending == null then true else
      (.pending | type == "object") and .pending.index == .next and
      .pending.destination == .plan.destinations[.next] and .pending.amount_nano == .plan.amount_nano
      end)' >/dev/null || {
    echo 'Error: outgoing wallet journal is malformed; refusing to sign or submit another payment.' >&2
    return 1
  }
  batch="$(printf '%s' "$state" | jq -er '.batch_id')" || return 1
  [[ -d "$WALLET_OUTBOX_DIR/$batch" && ! -L "$WALLET_OUTBOX_DIR/$batch" ]] || {
    echo 'Error: outgoing batch directory is missing or unsafe.' >&2; return 1;
  }
  printf '%s' "$state"
}

wallet_outbox_validate_entry() {
  local state="$1" record="$2" directory file expected_digest actual_digest
  directory="$WALLET_OUTBOX_DIR/$(printf '%s' "$state" | jq -er '.batch_id')/entry-$(printf '%s' "$state" | jq -er '.next')" || return 1
  file="$directory/payload.boc"
  [[ -f "$file" && ! -L "$file" && ! -L "$directory" ]] || {
    echo 'Error: pending signed wallet payload is missing or unsafe; no replacement payment was signed.' >&2; return 1;
  }
  printf '%s\n%s\n' "$state" "$record" | jq -es --arg file "$file" '
    length == 2 and .[1].index == .[0].next and .[1].destination == .[0].plan.destinations[.[0].next] and
    .[1].amount_nano == .[0].plan.amount_nano and .[1].path == $file and
    (.[1].seqno | type == "string" and test("^[0-9]{1,10}$")) and
    (.[1].seqno | tonumber) <= 4294967295 and
    (.[1].expiry | type == "string" and test("^[0-9]{1,12}$")) and
    (.[1].body_hash | type == "string" and test("^[A-Za-z0-9_+/=-]{43,88}$")) and
    (.[1].sha256 | type == "string" and test("^[a-f0-9]{64}$"))' >/dev/null || {
    echo 'Error: pending outgoing record does not match its approved batch; refusing to continue.' >&2; return 1;
  }
  expected_digest="$(printf '%s' "$record" | jq -er '.sha256')" || return 1
  actual_digest="$(sha256sum "$file")" || return 1
  [[ "${actual_digest%% *}" == "$expected_digest" ]] || {
    echo 'Error: pending signed wallet payload checksum changed; refusing to submit it.' >&2; return 1;
  }
}

wallet_outbox_recover_entry() {
  local state record directory updated retired archive batch archive_name
  state="$(wallet_outbox_read_state)" || return 1
  if [[ "$(printf '%s' "$state" | jq -r '.pending != null')" == true ]]; then
    record="$(printf '%s' "$state" | jq -c '.pending')" || return 1
    wallet_outbox_validate_entry "$state" "$record" || return 1
    return 0
  fi
  directory="$WALLET_OUTBOX_DIR/$(printf '%s' "$state" | jq -er '.batch_id')/entry-$(printf '%s' "$state" | jq -er '.next')" || return 1
  [[ -e "$directory" || -L "$directory" ]] || return 0
  [[ -f "$directory/record.json" && ! -L "$directory/record.json" && ! -L "$directory" ]] || {
    echo 'Error: an incomplete outgoing journal publication needs inspection; refusing another payment.' >&2; return 1;
  }
  record="$(cat "$directory/record.json")" || return 1
  wallet_outbox_validate_entry "$state" "$record" || return 1
  retired="$(printf '%s' "$state" | jq -c --argjson record "$record" \
    '[(.expired//[])[]|select(.index==$record.index and .sha256==$record.sha256 and .body_hash==$record.body_hash)]|last//null')" || return 1
  if [[ "$retired" != null ]]; then
    # Expiration is committed in state before the old payload is moved. A
    # process death between those operations must never resurrect that entry.
    archive="$(printf '%s' "$retired" | jq -er '.archive_directory')" || return 1
    batch="$(printf '%s' "$state" | jq -er '.batch_id')" || return 1
    archive_name="${archive##*/}"
    [[ "$archive" == "$WALLET_OUTBOX_DIR/$batch/$archive_name" && "$archive_name" =~ ^expired-[0-9]+-[A-Za-z0-9]+$ \
      && -d "$archive" && ! -L "$archive" && ! -e "$archive/entry" && ! -L "$archive/entry" ]] || {
      echo 'Error: expired outgoing archive is missing or unsafe; refusing to replace its payload.' >&2; return 1;
    }
    mv "$directory" "$archive/entry" && sync "$archive" "$WALLET_OUTBOX_DIR/$batch" || return 1
    return 0
  fi
  updated="$(printf '%s' "$state" | jq --argjson record "$record" '.pending=$record')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated" || return 1
}

wallet_outbox_release() {
  if [[ -n "${WALLET_OUTBOX_LOCK_FD:-}" ]]; then
    exec {WALLET_OUTBOX_LOCK_FD}>&- || return 1
  fi
  WALLET_OUTBOX_LOCK_FD="" WALLET_OUTBOX_LOCK_PATH=""
}

wallet_outbox_begin() {
  local wallet="$1" source="$2" network="$3" wallet_id="$4" amount="$5"
  shift 5
  local root lock_key lock_path source_raw amount_nano destination destinations='[]' plan state other_state other batch_id batch_dir updated
  local bounce="${no_bounce_flag:-}"
  umask 077
  for dependency in jq flock sha256sum sync mktemp; do require_bin "$dependency" || return 1; done
  [[ "$wallet" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$wallet" != . && "$wallet" != .. \
    && "$wallet_id" =~ ^[0-9]{1,10}$ && "$network" =~ ^(mainnet|testnet)$ && ( -z "$bounce" || "$bounce" == -n ) ]] || {
    echo 'Error: invalid outgoing wallet batch identity.' >&2; return 1;
  }
  (( 10#$wallet_id <= 4294967295 )) || return 1
  source_raw="$(ton_address_to_hex "$source")" || return 1
  amount_nano="$(gram_amount_to_nano "$amount")" || return 1
  [[ "$amount_nano" =~ ^[0-9]+$ ]] && (( amount_nano > 0 && $# > 0 )) || return 1
  for destination in "$@"; do
    destination="$(ton_address_to_hex "$destination")" || return 1
    destinations="$(printf '%s' "$destinations" | jq --arg destination "$destination" '.+[$destination]')" || return 1
  done
  root="$MAIN_WALLET_BUNDLE_DIR/.outbox"
  [[ ! -L "$MAIN_WALLET_BUNDLE_DIR" && ! -L "$root" && ! -L "$root/$wallet" && ! -L "$root/.locks" ]] || return 1
  mkdir -p "$root/.locks" "$root/$wallet" || return 1
  chmod 700 "$root" "$root/.locks" "$root/$wallet" || return 1
  root="$(cd "$root" && pwd -P)" || return 1
  lock_key="$(printf '%s\n%s' "$network" "$source_raw" | sha256sum)" || return 1
  lock_path="$root/.locks/${lock_key%% *}.lock"
  [[ ! -L "$lock_path" && ! -L "$root/.locks" ]] || return 1
  if [[ "${WALLET_OUTBOX_LOCK_PATH:-}" != "$lock_path" || -z "${WALLET_OUTBOX_LOCK_FD:-}" ]]; then
    wallet_outbox_release || return 1
    exec {WALLET_OUTBOX_LOCK_FD}> "$lock_path" || return 1
    if ! flock -n "$WALLET_OUTBOX_LOCK_FD"; then
      exec {WALLET_OUTBOX_LOCK_FD}>&-
      WALLET_OUTBOX_LOCK_FD=""
      echo 'Error: another process holds the source wallet outgoing lock; no payment was signed.' >&2
      return 1
    fi
    WALLET_OUTBOX_LOCK_PATH="$lock_path"
  fi
  # Wallet aliases must not hide an unresolved operation for the same source.
  for other in "$root"/*/state.json; do
    [[ -f "$other" && "$other" != "$root/$wallet/state.json" ]] || continue
    other_state="$(cat "$other")" || return 1
    if ! printf '%s' "$other_state" | jq -e --arg source "$source_raw" --arg network "$network" \
      'type=="object" and .version==1 and (.complete==true or .complete==false) and
        (.plan.source|type=="string") and (.plan.network|type=="string") and
        (.complete==true or .plan.source!=$source or .plan.network!=$network)' >/dev/null; then
      echo 'Error: another wallet alias has an unresolved or invalid outgoing journal; inspect it before sending.' >&2
      return 1
    fi
  done
  WALLET_OUTBOX_DIR="$root/$wallet"
  plan="$(jq -nc --arg wallet "$wallet" --arg source "$source_raw" --arg network "$network" --arg wallet_id "$((10#$wallet_id))" \
    --arg amount "$amount_nano" --arg bounce "$bounce" --argjson destinations "$destinations" \
    '{wallet:$wallet,source:$source,network:$network,wallet_id:$wallet_id,amount_nano:$amount,bounce:$bounce,destinations:$destinations}')" || return 1
  WALLET_OUTBOX_RESUMED=false
  if [[ -e "$WALLET_OUTBOX_DIR/state.json" || -L "$WALLET_OUTBOX_DIR/state.json" ]]; then
    state="$(wallet_outbox_read_state)" || return 1
    if [[ "$(printf '%s' "$state" | jq -r '.complete')" != true ]]; then
      if ! printf '%s' "$state" | jq -e --argjson plan "$plan" '.plan==$plan' >/dev/null; then
        echo "Error: an unfinished outgoing batch exists for '${wallet}'; rerun its original recipients, amount and bounce option to resume. No new payment was signed." >&2
        return 1
      fi
      WALLET_OUTBOX_RESUMED=true
      wallet_outbox_recover_entry || return 1
      state="$(wallet_outbox_read_state)" || return 1
      WALLET_OUTBOX_INDEX="$(printf '%s' "$state" | jq -er '.next')" || return 1
      return 0
    fi
    batch_id="$(printf '%s' "$state" | jq -er '.batch_id')" || return 1
    wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/$batch_id/final-state.json" "$state" || return 1
  elif [[ -n "$(find "$WALLET_OUTBOX_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo 'Error: outgoing files exist without their state journal; inspect them before sending.' >&2
    return 1
  fi
  batch_dir="$(mktemp -d "$WALLET_OUTBOX_DIR/batch-XXXXXXXXXXXX")" || return 1
  chmod 700 "$batch_dir" || return 1
  batch_id="${batch_dir##*/}"
  updated="$(jq -nc --arg batch "$batch_id" --argjson plan "$plan" \
    '{version:1,batch_id:$batch,plan:$plan,next:0,confirmed:[],expired:[],pending:null,complete:false}')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated" || return 1
  WALLET_OUTBOX_INDEX=0
}

wallet_outbox_pending() {
  wallet_outbox_recover_entry || return 1
  local state
  state="$(wallet_outbox_read_state)" || return 1
  printf '%s' "$state" | jq -r 'if .pending==null then empty else .pending|[.seqno,.expiry,.body_hash,.path,.destination,.amount_nano,(.index|tostring)]|@tsv end'
}

wallet_outbox_retry_seqno() {
  local state counters
  wallet_outbox_recover_entry || return 1
  state="$(wallet_outbox_read_state)" || return 1
  counters="$(printf '%s' "$state" | jq -c '[.next as $index|(.expired//[])[]|select(.index==$index)|.seqno]|unique')" || return 1
  [[ "$(printf '%s' "$counters" | jq 'length')" -le 1 ]] || {
    echo 'Error: retired payloads for one recipient have inconsistent sequence numbers.' >&2; return 1;
  }
  printf '%s' "$counters" | jq -r 'if length==0 then empty else .[0] end'
}

wallet_outbox_receipts() {
  local state
  wallet_outbox_recover_entry || return 1
  state="$(wallet_outbox_read_state)" || return 1
  printf '%s' "$state" | jq -r '.next as $index|([(.expired//[])[]|select(.index==$index)]+[.pending|select(.!=null)])|unique_by(.body_hash)[]|[.body_hash,.destination,.amount_nano]|@tsv'
}

wallet_outbox_expire() {
  local index="$1" proof="$2" state archive updated
  [[ "$index" =~ ^[0-9]+$ ]] || return 1
  wallet_outbox_recover_entry || return 1
  state="$(wallet_outbox_read_state)" || return 1
  # The caller obtains this proof from a pinned, current masterchain block.
  # Recheck its numeric binding here so stale proof cannot retire a new BOC.
  printf '%s' "$state" | jq -e --argjson index "$index" --argjson proof "$proof" '
    .complete==false and .next==$index and .pending.index==$index and
    ($proof|type=="object") and
    ($proof.masterchain_seqno|type=="number" and .>=0 and .==floor) and
    ($proof.gen_utime|type=="number" and .>=0 and .==floor) and
    ($proof.wallet_seqno|type=="number" and .>=0 and .==floor) and
    $proof.wallet_seqno==(.pending.seqno|tonumber) and
    $proof.gen_utime>((.pending.expiry|tonumber)+10)' >/dev/null || {
    echo 'Error: expiration proof does not establish that this exact old sequence number remained unconsumed after expiry.' >&2; return 1;
  }
  archive="$(mktemp -d "$WALLET_OUTBOX_DIR/$(printf '%s' "$state" | jq -er '.batch_id')/expired-${index}-XXXXXXXXXXXX")" || return 1
  chmod 700 "$archive" || return 1
  updated="$(printf '%s' "$state" | jq --argjson proof "$proof" --arg archive "$archive" \
    '.expired=((.expired//[])+[(.pending+{expiration_proof:$proof,archive_directory:$archive})])|.pending=null')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated" || return 1
  wallet_outbox_recover_entry
}

wallet_outbox_stage() {
  local index="$1" seqno="$2" expiry="$3" body_hash="$4" input="$5" destination="$6" amount="$7"
  local state record pending directory temporary digest updated retry_seqno copied_digest
  wallet_outbox_recover_entry || return 1
  state="$(wallet_outbox_read_state)" || return 1
  [[ "$index" =~ ^[0-9]+$ && "$seqno" =~ ^[0-9]{1,10}$ && "$expiry" =~ ^[0-9]{1,12}$ && "$body_hash" =~ ^[A-Za-z0-9_+/=-]{43,88}$ \
    && -s "$input" && ! -L "$input" ]] || return 1
  destination="$(ton_address_to_hex "$destination")" || return 1
  (( 10#$seqno <= 4294967295 )) || return 1
  retry_seqno="$(wallet_outbox_retry_seqno)" || return 1
  [[ -z "$retry_seqno" || "$seqno" == "$retry_seqno" ]] || {
    echo 'Error: re-signing an expired recipient must retain its original unresolved sequence number.' >&2; return 1;
  }
  [[ "$(printf '%s' "$state" | jq -r '.complete')" == false && "$(printf '%s' "$state" | jq -r '.next')" == "$index" ]] || return 1
  [[ "$(printf '%s' "$state" | jq -r --argjson index "$index" '.plan.destinations[$index]')" == "$destination" \
    && "$(printf '%s' "$state" | jq -r '.plan.amount_nano')" == "$amount" ]] || {
    echo 'Error: signed payload destination or amount differs from the approved outgoing plan.' >&2; return 1;
  }
  digest="$(sha256sum "$input")" || return 1; digest="${digest%% *}"
  pending="$(printf '%s' "$state" | jq -c '.pending')" || return 1
  if [[ "$pending" != null ]]; then
    printf '%s' "$pending" | jq -e --arg seqno "$seqno" --arg expiry "$expiry" --arg hash "$body_hash" --arg digest "$digest" \
      '.seqno==$seqno and .expiry==$expiry and .body_hash==$hash and .sha256==$digest' >/dev/null || {
      echo 'Error: an unresolved signed payload already exists; refusing to replace or re-sign it.' >&2; return 1;
    }
    return 0
  fi
  directory="$WALLET_OUTBOX_DIR/$(printf '%s' "$state" | jq -er '.batch_id')/entry-$index" || return 1
  temporary="$(mktemp -d "${directory%/*}/.entry-${index}.XXXXXX")" || return 1
  chmod 700 "$temporary" || return 1
  record="$(jq -nc --argjson index "$index" --arg seqno "$seqno" --arg expiry "$expiry" --arg hash "$body_hash" --arg digest "$digest" \
    --arg path "$directory/payload.boc" --arg destination "$destination" --arg amount "$amount" \
    '{index:$index,seqno:$seqno,expiry:$expiry,body_hash:$hash,sha256:$digest,path:$path,destination:$destination,amount_nano:$amount}')" || return 1
  # Publish payload+record as one directory, then point the state at it. A
  # crash between these renames is recovered by wallet_outbox_recover_entry.
  if ! { cp "$input" "$temporary/payload.boc" && copied_digest="$(sha256sum "$temporary/payload.boc")" \
    && [[ "${copied_digest%% *}" == "$digest" ]] && printf '%s\n' "$record" > "$temporary/record.json" \
    && chmod 600 "$temporary/payload.boc" "$temporary/record.json" \
    && sync "$temporary/payload.boc" "$temporary/record.json" "$temporary" \
    && mv "$temporary" "$directory" && sync "${directory%/*}"; }; then
    echo 'Error: signed wallet payload could not be durably staged; nothing further may be broadcast.' >&2
    return 1
  fi
  updated="$(printf '%s' "$state" | jq --argjson record "$record" '.pending=$record')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated"
}

wallet_outbox_confirm() {
  local index="$1" transaction="$2" matched_hash="${3:-}" state updated record
  [[ "$index" =~ ^[0-9]+$ && -n "$transaction" && "$transaction" != *$'\n'* ]] || return 1
  wallet_outbox_recover_entry || return 1
  state="$(wallet_outbox_read_state)" || return 1
  if printf '%s' "$state" | jq -e --argjson index "$index" --arg transaction "$transaction" \
    --arg hash "$matched_hash" '.confirmed[$index].index==$index and .confirmed[$index].transaction_id==$transaction and ($hash=="" or .confirmed[$index].body_hash==$hash)' >/dev/null; then return 0; fi
  printf '%s' "$state" | jq -e --argjson index "$index" '.complete==false and .next==$index' >/dev/null || return 1
  record="$(printf '%s' "$state" | jq -ec --argjson index "$index" --arg hash "$matched_hash" \
    '([(.expired//[])[]|select(.index==$index)]+[.pending|select(.!=null)])|map(select($hash=="" or .body_hash==$hash))|last|select(.!=null)')" || return 1
  updated="$(printf '%s' "$state" | jq --arg transaction "$transaction" --argjson record "$record" \
    '.confirmed += [($record + {transaction_id:$transaction})] | .pending=null | .next+=1')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated" || return 1
  WALLET_OUTBOX_INDEX="$(printf '%s' "$updated" | jq -er '.next')" || return 1
}

wallet_outbox_complete() {
  local state updated
  state="$(wallet_outbox_read_state)" || return 1
  printf '%s' "$state" | jq -e '.pending==null and .next==(.plan.destinations|length)' >/dev/null || return 1
  updated="$(printf '%s' "$state" | jq '.complete=true')" || return 1
  wallet_outbox_atomic_json "$WALLET_OUTBOX_DIR/state.json" "$updated"
}

wallet_outbox_fail() {
  echo "Error: ${1:-payment outcome is unresolved}. The persistent outgoing batch was retained; rerun the same command to inspect/resume it without paying confirmed recipients twice." >&2
  return 1
}

# A counter alone cannot identify a payment: another request can consume it,
# and a wallet can consume a request without emitting the intended message.
wallet_confirm_known_receipts() {
  local source="$1" rows hash destination amount receipt rc any_error=0
  rows="$(wallet_outbox_receipts)" || return 13
  [[ -n "$rows" ]] || return 10
  while IFS=$'\t' read -r hash destination amount; do
    if receipt="$(wallet_transaction_receipt "$source" "$hash" "$destination" "$amount")"; then
      printf '%s\t%s' "${receipt//$'\t'/:}" "$hash"
      return 0
    else
      rc=$?
    fi
    (( rc != 11 )) || {
      echo 'Error: this exact request was consumed without emitting the approved payment; inspect the source transaction before taking further action.' >&2
      return 11
    }
    (( rc == 10 )) || any_error=1
  done <<<"$rows"
  (( any_error == 0 )) || return 1
  return 10
}

wallet_rebroadcast_transfer() {
  local boc="$1" mode="$2" expiry="$3" pending pending_path
  local WALLET_QUERY_DEADLINE="${WALLET_QUERY_DEADLINE:-$expiry}"
  (( WALLET_QUERY_DEADLINE <= expiry )) || WALLET_QUERY_DEADLINE="$expiry"
  wallet_request_timeout 15 >/dev/null || return 1
  pending="$(wallet_outbox_pending)" || return 13
  IFS=$'\t' read -r _ _ _ pending_path _ _ _ <<<"$pending"
  [[ "$pending_path" == "$boc" ]] || return 13
  case "$mode" in
    liteserver) send_boc_liteserver "$boc" ;;
    auto|fallback|both|toncenter) send_boc_toncenter "$boc" ;;
    *) echo "Error: unsupported wallet transport mode '${mode}'; no rebroadcast attempted." >&2; return 1 ;;
  esac
}

wallet_confirm_transfer() {
  local source="$1" expected="$2" boc="$3" body_hash="$4" destination="$5" amount="$6" expiry="$7"
  local initially_submitted="${8:-false}" mode="${9:-${MODE:-auto}}"
  local attempts delay timeout_sec rebroadcast_delay rebroadcast_limit attempt receipt rc seqno=unknown
  local last_broadcast now broadcasts=0 proof information status balance
  attempts="$(main_wallet_confirm_attempts)"
  delay="$(main_wallet_confirm_delay_seconds)"
  timeout_sec="${MAIN_WALLET_CONFIRM_TIMEOUT_SEC:-180}"
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || timeout_sec=180
  rebroadcast_delay="${MAIN_WALLET_REBROADCAST_DELAY_SEC:-10}"
  [[ "$rebroadcast_delay" =~ ^[0-9]+$ ]] || rebroadcast_delay=10
  rebroadcast_limit="${MAIN_WALLET_REBROADCAST_ATTEMPTS:-3}"
  [[ "$rebroadcast_limit" =~ ^[0-9]+$ ]] || rebroadcast_limit=3
  local WALLET_QUERY_DEADLINE="$(($(date +%s) + timeout_sec))"
  last_broadcast="$(date +%s)"
  [[ "$initially_submitted" == true ]] || last_broadcast=$((last_broadcast - rebroadcast_delay))
  [[ -s "$boc" && "$expected" =~ ^[0-9]+$ && "$expiry" =~ ^[0-9]+$ && -n "$body_hash" && -n "$destination" && "$amount" =~ ^[0-9]+$ ]] || return 1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    wallet_request_timeout 15 >/dev/null || break
    if receipt="$(wallet_confirm_known_receipts "$source")"; then
      printf '%s' "$receipt"
      return 0
    else
      rc=$?
    fi
    (( rc != 11 && rc != 13 )) || return "$rc"
    now="$(date +%s)"
    if (( now >= expiry )); then
      # Clock expiry or an empty cached history is insufficient. Keep the
      # original seqno reserved even after a pinned post-expiry observation.
      if proof="$(wallet_expired_message_unconsumed "$source" "$((expected - 1))" "$expiry")"; then
        printf '%s' "$proof"
        return 12
      fi
      break
    fi
    if information="$(wallet_toncenter_information "$source" 2>/dev/null)"; then
      IFS=$'\t' read -r status balance seqno <<<"$information"
    fi
    now="$(date +%s)"
    if (( now < expiry && broadcasts < rebroadcast_limit && now - last_broadcast >= rebroadcast_delay )) &&
      { [[ ! "$seqno" =~ ^[0-9]+$ ]] || (( 10#$seqno < expected )); }; then
      wallet_send_progress "[wallet] Payment receipt is pending (last source seqno=${seqno}); rebroadcasting the same signed message (${broadcasts}/${rebroadcast_limit} retries used)."
      # Cross-broadcast after an ACK in auto mode as well. ACK 1 only admits
      # the message at one server; it does not establish network inclusion.
      if wallet_rebroadcast_transfer "$boc" "$mode" "$expiry" >&2; then
        :
      else
        rc=$?
        (( rc != 13 )) || return 13
      fi
      broadcasts=$((broadcasts + 1))
      last_broadcast="$(date +%s)"
    fi
    if (( attempt < attempts )); then wallet_bounded_sleep "$delay" || break; fi
  done
  echo "Error: no exact outgoing-payment receipt was verified within the confirmation budget (last source seqno=${seqno}, expected=${expected}). A transport acknowledgement alone cannot mark it paid." >&2
  return 1
}

main_wallet_send() (
  local from_wallet="${1:-}"
  shift || true
  local normalized_mode source_wallet_address current_seqno source_subwallet_id
  local -a destination_addresses=()
  local destination_address amount_gram
  local total_amount_gram total_amount_nano amount_each_nano remainder_nano
  local split_amount_arg target_count
  local multi_send_pause_sec
  local no_bounce_flag=""
  local arg
  local expected_seqno idx

  if (( $# > 0 )); then
    if [[ "$(trim_whitespace "${!#}")" == "-n" ]]; then
      no_bounce_flag="-n"
      set -- "${@:1:$(($# - 1))}"
    fi
  fi
  for arg in "$@"; do
    if [[ "$arg" == "-n" ]]; then
      echo "Error: '-n' must be the last optional argument." >&2
      return 1
    fi
  done

  if [[ -z "$from_wallet" ]]; then
    echo "Error: usage: main-wallet.sh send [from-wallet-name] [to-address] [amount] [-n]" >&2
    echo "       usage: main-wallet.sh send [from-wallet-name] [amount] [to-address...] [-n]" >&2
    return 1
  fi

  require_wallet_network_match "$from_wallet" || return $?
  normalized_mode="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_mode" in
    auto|fallback|both|liteserver|toncenter) ;;
    *) echo "Error: unsupported MODE=${MODE}. Use auto, liteserver, or toncenter." >&2; return 1 ;;
  esac
  wallet_toncenter_base >/dev/null || {
    echo 'Error: verified payment receipts require a TONCenter endpoint matching the active wallet network; no payment was signed.' >&2
    return 1
  }
  source_wallet_address="$(resolve_wallet_address_by_name "$from_wallet" || true)"
  source_wallet_address="$(trim_whitespace "$source_wallet_address")"
  if [[ -z "$source_wallet_address" ]]; then
    echo "Error: cannot resolve source wallet address for '${from_wallet}'." >&2
    return 1
  fi

  source_subwallet_id="$(resolve_wallet_subwallet_id_by_name "$from_wallet" || true)"
  source_subwallet_id="$(trim_whitespace "$source_subwallet_id")"
  if ! [[ "$source_subwallet_id" =~ ^[0-9]+$ ]]; then
    echo "Error: failed to resolve source wallet subwallet-id for '${from_wallet}'." >&2
    return 1
  fi
  multi_send_pause_sec="$(main_wallet_multi_send_pause_seconds)"

  split_amount_arg="$(trim_whitespace "${1:-}")"
  if (( $# >= 2 )) && [[ "$split_amount_arg" =~ ^[0-9]+([.][0-9]+)?[.]?$ ]]; then
    total_amount_gram="$split_amount_arg"
    shift || true

    destination_addresses=()
    for destination_address in "$@"; do
      destination_address="$(trim_whitespace "$destination_address")"
      [[ -z "$destination_address" ]] && continue
      if ! ton_address_to_hex "$destination_address" >/dev/null; then
        echo "Error: invalid destination wallet address '${destination_address}'." >&2
        return 1
      fi
      destination_addresses+=("$destination_address")
    done
    target_count="${#destination_addresses[@]}"
    if (( target_count < 1 )); then
      echo "Error: usage: main-wallet.sh send [from-wallet-name] [amount] [to-address...] [-n]" >&2
      return 1
    fi

    total_amount_nano="$(gram_amount_to_nano "$total_amount_gram" || true)"
    total_amount_nano="$(trim_whitespace "$total_amount_nano")"
    if ! [[ "$total_amount_nano" =~ ^[0-9]+$ ]] || (( total_amount_nano <= 0 )); then
      echo "Error: amount '${total_amount_gram}' must be numeric TON amount (for example: 1, 1., 1.5)." >&2
      return 1
    fi

    amount_each_nano=$(( total_amount_nano / target_count ))
    if (( amount_each_nano <= 0 )); then
      echo "Error: amount '${total_amount_gram}' is too low for equal distribution across ${target_count} targets." >&2
      return 1
    fi
    remainder_nano=$(( total_amount_nano - (amount_each_nano * target_count) ))
    amount_gram="$(nano_to_gram_amount "$amount_each_nano")"
    amount_gram="$(trim_whitespace "$amount_gram")"
    if [[ -z "$amount_gram" ]]; then
      echo "Error: failed to convert equal share amount." >&2
      return 1
    fi
    if (( remainder_nano > 0 )); then
      echo "Warning: ${remainder_nano} nanoTON remainder is not sent due to equal split rounding." >&2
    fi

  else

    if (( $# != 2 )); then
      echo "Error: usage: main-wallet.sh send [from-wallet-name] [to-address] [amount] [-n]" >&2
      echo "       usage: main-wallet.sh send [from-wallet-name] [amount] [to-address...] [-n]" >&2
      return 1
    fi
    destination_address="$(trim_whitespace "${1:-}")"
    amount_gram="$(trim_whitespace "${2:-}")"
    if [[ -z "$destination_address" || -z "$amount_gram" ]]; then
      echo "Error: destination address and amount are required." >&2
      return 1
    fi
    if ! [[ "$amount_gram" =~ ^[0-9]+([.][0-9]+)?[.]?$ ]]; then
      echo "Error: amount '${amount_gram}' must be numeric TON amount (for example: 1, 1., 1.5)." >&2
      return 1
    fi
    total_amount_nano="$(gram_amount_to_nano "$amount_gram" || true)"
    if ! [[ "$total_amount_nano" =~ ^[0-9]+$ ]] || (( total_amount_nano <= 0 )); then
      echo "Error: amount '${amount_gram}' must be greater than zero and have at most nine decimal places." >&2
      return 1
    fi
    if ! ton_address_to_hex "$destination_address" >/dev/null; then
      echo "Error: invalid destination wallet address '${destination_address}'." >&2
      return 1
    fi
    destination_addresses=("$destination_address")
    target_count=1
  fi

  source_wallet_address="$(ton_address_to_hex "$source_wallet_address")" || return 1
  local network pending pending_seq expiry body_hash boc dest_raw nano item initially_submitted
  local receipt receipt_rc transaction_id matched_hash proof retries old_seq minimum_seqno state
  network="$(resolve_current_wallet_network)" || return 1
  wallet_outbox_begin "$from_wallet" "$source_wallet_address" "$network" "$source_subwallet_id" "$amount_gram" "${destination_addresses[@]}" || return 1
  local WALLET_SEND_DIAGNOSTICS_FILE="" WALLET_SEND_DIAGNOSTICS_OWNER="$BASHPID" WALLET_SEND_PROGRESS_FD
  exec {WALLET_SEND_PROGRESS_FD}>&2
  if ! wallet_send_verbose_enabled; then
    WALLET_SEND_DIAGNOSTICS_FILE="$(mktemp "$MAIN_WALLET_DIR/.send-diagnostics.XXXXXX")" || return 1
    chmod 600 "$WALLET_SEND_DIAGNOSTICS_FILE" || { rm -f "$WALLET_SEND_DIAGNOSTICS_FILE"; return 1; }
    trap 'wallet_send_diagnostics_finish "$?"' EXIT
  fi
  if [[ "$WALLET_OUTBOX_RESUMED" == true ]]; then
    echo "[wallet] Resuming saved batch: ${WALLET_OUTBOX_INDEX}/${target_count} payments already confirmed; those recipients will be skipped." >&2
  fi
  for ((idx = WALLET_OUTBOX_INDEX; idx < target_count; idx++)); do
    WALLET_OUTBOX_INDEX="$idx"
    destination_address="${destination_addresses[$idx]}"
    retries=0
    while :; do
      pending="$(wallet_outbox_pending)" || return 1
      initially_submitted=false
      if [[ -z "$pending" ]]; then
        # A crash may have followed retirement of an expired attempt. Its
        # original seqno remains reserved for this same recipient and amount.
        old_seq="$(wallet_outbox_retry_seqno)" || return 1
        if [[ -n "$old_seq" ]]; then
          if receipt="$(wallet_send_diagnostics_run stderr wallet_confirm_known_receipts "$source_wallet_address")"; then
            IFS=$'\t' read -r transaction_id matched_hash <<<"$receipt"
            wallet_outbox_confirm "$idx" "$transaction_id" "$matched_hash" || return 1
            [[ -z "$WALLET_SEND_DIAGNOSTICS_FILE" ]] || : >"$WALLET_SEND_DIAGNOSTICS_FILE"
            break
          else
            receipt_rc=$?
            (( receipt_rc != 13 )) || return 13
            (( receipt_rc != 11 )) || { wallet_outbox_fail 'the expired request was consumed without the expected outgoing payment'; return 1; }
          fi
        fi
        state="$(wallet_outbox_read_state)" || return 1
        minimum_seqno="$(printf '%s' "$state" | jq -r 'if .confirmed|length>0 then (.confirmed[-1].seqno|tonumber)+1 else 0 end')" || return 1
        if (( minimum_seqno > 0 )); then
          [[ "$(main_wallet_version_by_name "$from_wallet")" == v3 ]] || return 1
          current_seqno="$(wallet_seqno_decimal "$source_wallet_address" 2>/dev/null || true)"
          # An exact earlier receipt proves its seqno was consumed even while
          # the wallet-information endpoint still serves its five-second cache.
          if [[ ! "$current_seqno" =~ ^[0-9]+$ ]] || (( 10#$current_seqno < minimum_seqno )); then
            current_seqno="$minimum_seqno"
          fi
        else
          current_seqno="$(wallet_send_diagnostics_run stderr wallet_prepare_source "$from_wallet" "$source_wallet_address" "$normalized_mode")" || return 1
        fi
        [[ "$current_seqno" =~ ^[0-9]+$ ]] || return 1
        if [[ -n "$old_seq" && "$current_seqno" != "$old_seq" ]]; then
          wallet_outbox_fail 'the reserved seqno changed but its exact payment receipt is not available yet'
          return 1
        fi
        wallet_send_progress "[wallet] Sending payment $((idx + 1))/${target_count}: ${amount_gram} TON from '${from_wallet}' to '${destination_address}'."
        if wallet_send_diagnostics_run all send_single_transfer "$from_wallet" "$destination_address" "$amount_gram" "$current_seqno" "$source_subwallet_id" "$normalized_mode" "$no_bounce_flag"; then
          initially_submitted=true
        fi
        pending="$(wallet_outbox_pending)" || return 1
        if [[ -z "$pending" ]]; then
          wallet_outbox_fail 'signing or staging failed before any payment could be submitted'
          return 1
        fi
      fi
      IFS=$'\t' read -r pending_seq expiry body_hash boc dest_raw nano item <<<"$pending"
      expected_seqno=$((10#$pending_seq + 1))
      echo "[wallet] Confirming payment $((idx + 1))/${target_count} to '${destination_address}' (source seqno=${pending_seq}) ..." >&2
      if receipt="$(wallet_send_diagnostics_run stderr wallet_confirm_transfer "$source_wallet_address" "$expected_seqno" "$boc" "$body_hash" "$dest_raw" "$nano" "$expiry" "$initially_submitted" "$normalized_mode")"; then
        IFS=$'\t' read -r transaction_id matched_hash <<<"$receipt"
        wallet_outbox_confirm "$idx" "$transaction_id" "$matched_hash" || return 1
        # Discard recovered transport/signing chatter only once this exact
        # outgoing payment and its durable journal update are both confirmed.
        [[ -z "$WALLET_SEND_DIAGNOSTICS_FILE" ]] || : >"$WALLET_SEND_DIAGNOSTICS_FILE"
        echo "[wallet] Confirmed outgoing payment $((idx + 1))/${target_count}; transaction ${transaction_id}." >&2
        break
      else
        receipt_rc=$?
      fi
      if (( receipt_rc == 12 && retries < 1 )); then
        proof="$receipt"
        wallet_outbox_expire "$idx" "$proof" || return 1
        retries=$((retries + 1))
        echo '[wallet] The expired request left the source counter unchanged; renewing this same payment with its original seqno.' >&2
        continue
      fi
      wallet_outbox_fail "payment $((idx + 1))/${target_count} could not be verified; no later recipients were attempted"
      return 1
    done
    if (( idx + 1 < target_count && multi_send_pause_sec > 0 )); then sleep "$multi_send_pause_sec"; fi
  done
  if ! wallet_outbox_complete; then
    echo "Error: all ${target_count} outgoing payments were verified, but the final journal update failed. Inspect the saved journal before any retry; do not submit another payment batch." >&2
    return 1
  fi
  echo "[wallet] All ${target_count} outgoing payments confirmed. Check recipient balances for final delivery." >&2
)

run_action() {
  local action="${1:-}"
  shift || true
  case "$action" in
    create)
      main_wallet_create "$@"
      ;;
    deploy)
      main_wallet_deploy "$@"
      ;;
    send)
      main_wallet_send "$@"
      ;;
    show)
      main_wallet_show "$@"
      ;;
    export)
      main_wallet_export "$@"
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      echo "Error: unknown main-wallet action '${action}'." >&2
      usage
      return 1
      ;;
  esac
}

run_with_persistence() {
  local action="${1:-}"
  shift || true
  local action_rc=0
  local backup_rc=0

  restore_bundle
  if run_action "$action" "$@"; then
    action_rc=0
  else
    action_rc=$?
  fi
  # Sending changes the durable public outbox, not the encrypted signing keys.
  # Rewriting the key bundle after confirmed payments adds both corruption
  # risk on interruption and a misleading post-payment failure to retry.
  if [[ "$action" == "show" || "$action" == "export" || "$action" == "send" ]]; then
    return "$action_rc"
  fi
  if backup_bundle; then
    backup_rc=0
  else
    backup_rc=$?
  fi

  if (( action_rc != 0 )); then
    return "$action_rc"
  fi
  if (( backup_rc != 0 )); then
    return "$backup_rc"
  fi
  return 0
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    run)
      if [[ $# -lt 1 ]]; then
        echo "Error: usage: main-wallet.sh run <create|deploy|send|show|export> [args...]" >&2
        return 1
      fi
      run_with_persistence "$@"
      ;;
    create|deploy|send|show|export)
      run_action "$command" "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Error: unknown command '$command'." >&2
      usage
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
