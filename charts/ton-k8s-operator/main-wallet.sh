#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-liteserver}"
GLOBAL_CONFIG_URL="${GLOBAL_CONFIG_URL:-https://ton.org/global.config.json}"
TONCENTER_URL="${TONCENTER_URL:-https://testnet.toncenter.com}"
TONCENTER_API_KEY="${TONCENTER_API_KEY:-}"

MAIN_WALLET_DIR="${MAIN_WALLET_DIR:-/var/main-wallet/runtime}"
MAIN_WALLET_BUNDLE_DIR="${MAIN_WALLET_BUNDLE_DIR:-/var/main-wallet/bundle}"
MAIN_WALLET_BUNDLE_FILE="${MAIN_WALLET_BUNDLE_FILE:-main-wallet.bundle.enc}"
MAIN_WALLET_BUNDLE_META_FILE="${MAIN_WALLET_BUNDLE_META_FILE:-main-wallet.bundle.meta}"
MAIN_WALLET_NAME_DEFAULT="${MAIN_WALLET_NAME_DEFAULT:-main-wallet}"
SMARTCONT_DIR="${SMARTCONT_DIR:-/usr/share/ton/smartcont}"
MAIN_WALLET_SEND_RETRY_ATTEMPTS="${MAIN_WALLET_SEND_RETRY_ATTEMPTS:-3}"
MAIN_WALLET_SEND_RETRY_DELAY_SEC="${MAIN_WALLET_SEND_RETRY_DELAY_SEC:-3}"

usage() {
  cat <<'EOF'
Usage:
  main-wallet.sh create [workchain] [subwallet-id] [wallet-name]
  main-wallet.sh deploy [wallet-name]
  main-wallet.sh send [from-wallet-name] [to-address] [amount] [-n]
  main-wallet.sh send [from-wallet-name] [amount] [to-address...] [-n]
  main-wallet.sh show [wallet-name]
  main-wallet.sh run <create|deploy|send|show> [args...]

Required env for deploy:
  MODE=liteserver|toncenter
  GLOBAL_CONFIG_URL=https://ton.org/global.config.json
  TONCENTER_URL=https://testnet.toncenter.com (or mainnet URL)

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

main_wallet_send_retry_attempts() {
  local raw
  raw="$(trim_whitespace "${MAIN_WALLET_SEND_RETRY_ATTEMPTS:-3}")"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "3"
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

extract_json_string() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
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
  for candidate in \
    "$MAIN_WALLET_DIR/wallet.fif" \
    "${SMARTCONT_DIR}/wallet.fif"; do
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

send_boc_toncenter() {
  local boc_file="$1"
  local boc_b64 response curl_args=()

  require_bin curl
  require_bin base64
  if [[ -z "$TONCENTER_URL" ]]; then
    echo "Error: TONCENTER_URL is empty." >&2
    return 1
  fi
  if [[ -n "$TONCENTER_API_KEY" ]]; then
    curl_args+=(-H "X-API-Key: ${TONCENTER_API_KEY}")
  fi

  boc_b64="$(base64 -w0 "$boc_file" 2>/dev/null || base64 < "$boc_file" | tr -d '\r\n')"
  response="$(curl -fsS \
    "${curl_args[@]}" \
    -H "Content-Type: application/json" \
    --request POST \
    --data "{\"boc\":\"${boc_b64}\"}" \
    "${TONCENTER_URL%/}/api/v2/sendBoc")"

  printf '%s\n' "$response"
  if ! printf '%s' "$response" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "Error: TONCenter sendBoc request did not return ok=true." >&2
    return 1
  fi
}

resolve_local_global_config_path() {
  local global_config_source global_config_path temp_config_file=""

  if [[ -z "$GLOBAL_CONFIG_URL" ]]; then
    echo "Error: GLOBAL_CONFIG_URL is empty." >&2
    return 1
  fi
  global_config_source="$(trim_whitespace "$GLOBAL_CONFIG_URL")"
  if [[ "$global_config_source" =~ ^https?:// ]]; then
    require_bin curl
    require_bin mktemp
    temp_config_file="$(mktemp)"
    if ! curl -fsSL "$global_config_source" -o "$temp_config_file"; then
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

run_liteclient_query() {
  local query="$1"
  local lite_client_bin
  local config_row config_path temp_config_path rc=0

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

  if "$lite_client_bin" -C "$config_path" -v 0 -c "$query"; then
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
  local attempts delay attempt rc=1

  attempts="$(main_wallet_send_retry_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if run_liteclient_query "sendfile $boc_file"; then
      return 0
    fi
    rc=$?
    if (( attempt < attempts )); then
      echo "Warning: lite-client sendfile failed (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        sleep "$delay"
      fi
    fi
  done

  return "$rc"
}

deploy_boc_with_mode() {
  local wallet_name="$1"
  local boc_file="$2"
  local normalized_mode="$3"

  echo "Deploying wallet '${wallet_name}' using BOC '${boc_file##*/}' ..."
  case "$normalized_mode" in
    liteserver)
      send_boc_liteserver "$boc_file"
      ;;
    toncenter)
      send_boc_toncenter "$boc_file"
      ;;
    *)
      echo "Error: unsupported MODE=${MODE}. Use liteserver or toncenter." >&2
      return 1
      ;;
  esac
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
  local wallet_address non_bounceable bounceable meta_file
  create_log="$(mktemp)"

  if ! (
    cd "$MAIN_WALLET_DIR"
    export FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}"
    "$fift_bin" -s "./new-wallet-v3.fif" "$workchain" "$subwallet_id" "$wallet_name" 2>&1 | tee "$create_log"
  ); then
    rm -f "$create_log"
    return 1
  fi

  wallet_address="$(sed -n 's/^new wallet address = \([^[:space:]]*\).*/\1/p' "$create_log" | tail -n1)"
  non_bounceable="$(sed -n 's/^Non-bounceable address (for init):[[:space:]]*\(.*\)$/\1/p' "$create_log" | tail -n1)"
  bounceable="$(sed -n 's/^Bounceable address (for later access):[[:space:]]*\(.*\)$/\1/p' "$create_log" | tail -n1)"
  rm -f "$create_log"

  if [[ -z "$wallet_address" && -s "$MAIN_WALLET_DIR/${wallet_name}.addr" ]]; then
    wallet_address="$(head -n1 "$MAIN_WALLET_DIR/${wallet_name}.addr" | tr -d '\r\n')"
  fi

  meta_file="$MAIN_WALLET_DIR/${wallet_name}.wallet.meta"
  {
    echo "wallet_name=${wallet_name}"
    echo "workchain=${workchain}"
    echo "wallet_id=${subwallet_id}"
    echo "wallet_address=${wallet_address}"
    echo "non_bounceable=${non_bounceable}"
    echo "bounceable=${bounceable}"
  } > "$meta_file"
  chmod 600 "$meta_file"
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
  local workchain wallet_id wallet_address non_bounceable bounceable

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
    wallet_address="$(trim_whitespace "$(read_meta_value wallet_address "$meta_file")")"
    non_bounceable="$(trim_whitespace "$(read_meta_value non_bounceable "$meta_file")")"
    bounceable="$(trim_whitespace "$(read_meta_value bounceable "$meta_file")")"

    [[ -z "$workchain" ]] && workchain="unknown"
    [[ -z "$wallet_id" ]] && wallet_id="unknown"
    [[ -z "$wallet_address" ]] && wallet_address="unknown"
    [[ -z "$non_bounceable" ]] && non_bounceable="unknown"
    [[ -z "$bounceable" ]] && bounceable="unknown"

    rows+=("${workchain}"$'\t'"${wallet_id}"$'\t'"${wallet_name}"$'\t'"${wallet_address}"$'\t'"${non_bounceable}"$'\t'"${bounceable}")
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
    wallet_address="$(LC_ALL=C tr -cd '[:print:]\n' < "$addr_file" | head -n1 | tr -d '\r\n')"
    wallet_address="$(trim_whitespace "$wallet_address")"
    if ! [[ "$wallet_address" =~ ^-?[0-9]+:[0-9A-Fa-f]+$ ]]; then
      wallet_address="unknown"
    fi
    workchain="unknown"
    if [[ "$wallet_address" == *:* ]]; then
      workchain="$(trim_whitespace "${wallet_address%%:*}")"
      [[ -z "$workchain" ]] && workchain="unknown"
    fi
    rows+=("${workchain}"$'\t'"unknown"$'\t'"${wallet_name}"$'\t'"${wallet_address:-unknown}"$'\t'"unknown"$'\t'"unknown")
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
    echo -e "workchain\twallet-id\twallet-name\twallet-address\tnon-bounceable\tbounceable"
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
    deploy_boc_with_mode "$wallet_name" "$boc_file" "$normalized_mode"
    return $?
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

  for file in "${boc_files[@]}"; do
    base="${file##*/}"
    wallet_name="${base%-query.boc}"
    if ! deploy_boc_with_mode "$wallet_name" "$file" "$normalized_mode"; then
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
  local wallet_address=""

  if [[ -f "$wallet_meta" ]]; then
    wallet_address="$(read_meta_value wallet_address "$wallet_meta")"
    wallet_address="$(trim_whitespace "$wallet_address")"
    if [[ "$wallet_address" =~ ^-?[0-9]+:[0-9A-Fa-f]+$ ]]; then
      printf '%s' "$wallet_address"
      return 0
    fi
  fi

  if [[ -f "$wallet_addr_file" ]]; then
    wallet_address="$(LC_ALL=C tr -cd '[:print:]\n' < "$wallet_addr_file" | sed -n 's/^\([-0-9][0-9]*:[0-9A-Fa-f][0-9A-Fa-f]*\)$/\1/p' | head -n1)"
    wallet_address="$(trim_whitespace "$wallet_address")"
    if [[ "$wallet_address" =~ ^-?[0-9]+:[0-9A-Fa-f]+$ ]]; then
      printf '%s' "$wallet_address"
      return 0
    fi
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

wallet_seqno_decimal() {
  local wallet_address="$1"
  local output seq_hex seq_dec seq_token attempts delay attempt

  attempts="$(main_wallet_send_retry_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    output="$(run_liteclient_query "runmethod $wallet_address seqno" 2>/dev/null || true)"
    seq_token="$(printf '%s\n' "$output" | awk '
      /result:/ {capture=1}
      capture && match($0, /0x[0-9A-Fa-f]+/) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
      capture && match($0, /-?[0-9]+/) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    ')"
    seq_token="$(trim_whitespace "$seq_token")"
    seq_dec=""
    if [[ "$seq_token" =~ ^0x[0-9A-Fa-f]+$ ]]; then
      seq_dec="$((16#${seq_token:2}))"
    elif [[ "$seq_token" =~ ^[0-9]+$ ]]; then
      seq_dec="$seq_token"
    fi
    if [[ "$seq_dec" =~ ^[0-9]+$ ]]; then
      printf '%s' "$seq_dec"
      return 0
    fi

    output="$(run_liteclient_query "getaccount $wallet_address" 2>/dev/null || true)"
    seq_hex="$(printf '%s\n' "$output" | grep 'x{' | tail -n1 | cut -c 4- | cut -c -8 | tr -cd '0-9A-Fa-f')"
    seq_hex="$(trim_whitespace "$seq_hex")"
    if [[ -n "$seq_hex" ]]; then
      printf '%d' "$((16#$seq_hex))"
      return 0
    fi

    if (( attempt < attempts )); then
      echo "Warning: failed to parse wallet seqno for ${wallet_address} (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        sleep "$delay"
      fi
    fi
  done

  echo "Error: failed to parse wallet seqno from account state for ${wallet_address} after ${attempts} attempts." >&2
  return 1
}

wallet_balance_nano() {
  local wallet_address="$1"
  local output balance attempts delay attempt

  attempts="$(main_wallet_send_retry_attempts)"
  delay="$(main_wallet_send_retry_delay_seconds)"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    output="$(run_liteclient_query "getaccount $wallet_address" 2>/dev/null || true)"
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

    if (( attempt < attempts )); then
      echo "Warning: failed to parse wallet balance for ${wallet_address} (attempt ${attempt}/${attempts}); retrying..." >&2
      if (( delay > 0 )); then
        sleep "$delay"
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
  local rc=0

  wallet_fif="$(resolve_wallet_fif || true)"
  wallet_fif="$(trim_whitespace "$wallet_fif")"
  if [[ -z "$wallet_fif" ]]; then
    echo "Error: wallet.fif not found in ${SMARTCONT_DIR}." >&2
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
  fift_cmd=(
    "$fift_bin" -s "$wallet_fif"
    "$base_path" "$destination_address" "$subwallet_id" "$seqno_dec" "$amount_gram" "${from_wallet}-send-${seqno_dec}"
  )
  if [[ -n "$no_bounce_flag" ]]; then
    if [[ "$no_bounce_flag" != "-n" ]]; then
      echo "Error: unsupported wallet.fif option '${no_bounce_flag}'." >&2
      return 1
    fi
    fift_cmd+=("$no_bounce_flag")
  fi
  (
    cd "$MAIN_WALLET_DIR"
    export FIFTPATH="${FIFTPATH:-/usr/lib/fift:/usr/share/ton/smartcont/}"
    "${fift_cmd[@]}"
  )
  if [[ ! -s "$query_file" ]]; then
    echo "Error: failed to create transfer BOC ${query_file}." >&2
    return 1
  fi

  echo "Sending from '${from_wallet}' to '${destination_address}' amount='${amount_gram}' seqno=${seqno_dec} ..."
  case "$normalized_mode" in
    liteserver)
      if ! send_boc_liteserver "$query_file"; then
        rc=$?
      fi
      ;;
    toncenter)
      if ! send_boc_toncenter "$query_file"; then
        rc=$?
      fi
      ;;
    *)
      echo "Error: unsupported MODE=${MODE}. Use liteserver or toncenter." >&2
      rc=1
      ;;
  esac
  rm -f "$query_file"
  return "$rc"
}

main_wallet_send() {
  local from_wallet="${1:-}"
  shift || true
  local normalized_mode source_wallet_address current_seqno source_subwallet_id
  local -a destination_addresses=()
  local destination_address amount_gram
  local total_amount_gram total_amount_nano amount_each_nano remainder_nano
  local split_amount_arg target_count
  local no_bounce_flag=""
  local arg
  local -a failed_addresses=()

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

  normalized_mode="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"
  source_wallet_address="$(resolve_wallet_address_by_name "$from_wallet" || true)"
  source_wallet_address="$(trim_whitespace "$source_wallet_address")"
  if [[ -z "$source_wallet_address" ]]; then
    echo "Error: cannot resolve source wallet address for '${from_wallet}'." >&2
    return 1
  fi

  current_seqno="$(wallet_seqno_decimal "$source_wallet_address")"
  current_seqno="$(trim_whitespace "$current_seqno")"
  if ! [[ "$current_seqno" =~ ^[0-9]+$ ]]; then
    echo "Error: failed to resolve source wallet seqno for '${from_wallet}'." >&2
    return 1
  fi
  source_subwallet_id="$(resolve_wallet_subwallet_id_by_name "$from_wallet" || true)"
  source_subwallet_id="$(trim_whitespace "$source_subwallet_id")"
  if ! [[ "$source_subwallet_id" =~ ^[0-9]+$ ]]; then
    echo "Error: failed to resolve source wallet subwallet-id for '${from_wallet}'." >&2
    return 1
  fi

  split_amount_arg="$(trim_whitespace "${1:-}")"
  if (( $# >= 2 )) && [[ "$split_amount_arg" =~ ^[0-9]+([.][0-9]+)?[.]?$ ]]; then
    total_amount_gram="$split_amount_arg"
    shift || true

    destination_addresses=()
    for destination_address in "$@"; do
      destination_address="$(trim_whitespace "$destination_address")"
      [[ -z "$destination_address" ]] && continue
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

    for destination_address in "${destination_addresses[@]}"; do
      if ! send_single_transfer "$from_wallet" "$destination_address" "$amount_gram" "$current_seqno" "$source_subwallet_id" "$normalized_mode" "$no_bounce_flag"; then
        failed_addresses+=("$destination_address")
      fi
      current_seqno=$((current_seqno + 1))
    done
    if [[ ${#failed_addresses[@]} -gt 0 ]]; then
      echo "Error: failed to send to destination(s): ${failed_addresses[*]}" >&2
      return 1
    fi
    return 0
  fi

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
  send_single_transfer "$from_wallet" "$destination_address" "$amount_gram" "$current_seqno" "$source_subwallet_id" "$normalized_mode" "$no_bounce_flag"
}

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
  if [[ "$action" == "show" ]]; then
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
        echo "Error: usage: main-wallet.sh run <create|deploy|send|show> [args...]" >&2
        return 1
      fi
      run_with_persistence "$@"
      ;;
    create|deploy|send|show)
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

main "$@"
