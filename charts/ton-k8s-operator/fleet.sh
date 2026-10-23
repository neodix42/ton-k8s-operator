#!/usr/bin/env bash
# Loaded only for fleet commands; shared Kubernetes helpers live in kubeton.

fleet_require_tools() {
  local bin
  for bin in kubectl python3 gpg sha256sum; do require_bin "$bin"; done
  [[ -f "$CHART_DIR/fleet.py" && -f "$CHART_DIR/fleet-crypto.sh" ]] || {
    echo "Error: fleet.py and fleet-crypto.sh must be installed beside kubeton." >&2
    return 1
  }
}

fleet_parse_args() {
  local action="$1"
  shift
  while (( $# )); do
    case "$1" in
      --passphrase-file|--storage-class|--bundle-storage-class|--node-selector|--public-ips)
        (( $# >= 2 )) && [[ -n "$2" ]] || { echo "Error: $1 needs a value." >&2; return 1; }
        case "$1" in
          --passphrase-file) passphrase_file="$2" ;;
          --storage-class) data_class="$2" ;;
          --bundle-storage-class) bundle_class="$2" ;;
          --node-selector) node_selector="$2" ;;
          --public-ips) public_ips="$2" ;;
        esac
        if [[ "$action" == backup && "$1" != --passphrase-file ]]; then
          echo "Error: $1 is only supported by restore-fleet." >&2
          return 1
        fi
        shift 2
        ;;
      --bootstrap)
        [[ "$action" == restore ]] || return 1
        bootstrap=1
        shift
        ;;
      -*) echo "Error: unknown fleet option: $1" >&2; return 1 ;;
      *)
        [[ -z "$backup_dir" ]] || { echo "Error: only one backup directory is allowed." >&2; return 1; }
        backup_dir="$1"
        shift
        ;;
    esac
  done
  [[ -n "$backup_dir" && -s "$passphrase_file" ]] || {
    echo "Error: usage: kubeton ${action}-fleet <directory> --passphrase-file <file>" >&2
    return 1
  }
  [[ -n "$(head -n 1 "$passphrase_file")" ]] || {
    echo "Error: the first line of the passphrase file must not be empty." >&2
    return 1
  }
}

fleet_gpg() {
  gpg --no-options --batch --yes --pinentry-mode loopback --no-symkey-cache \
    --passphrase-file "$passphrase_file" "$@"
}

fleet_recovery_key() {
  local root="$1" identity="${2:-}"
  fleet_gpg --decrypt "$root/recovery.gpg" | python3 "$CHART_DIR/fleet.py" recovery "$root" "$identity"
}

fleet_resume_operator() {
  local index
  for index in "${!operator_deploy_names[@]}"; do
    kubectl -n "$OP_NAMESPACE" scale deployment "${operator_deploy_names[$index]}" \
      --replicas="${operator_deploy_replicas[$index]}" >/dev/null || return 1
    kubectl -n "$OP_NAMESPACE" rollout status "deployment/${operator_deploy_names[$index]}" \
      --timeout=300s >/dev/null || return 1
  done
}

run_backup_fleet() (
  set -euo pipefail
  umask 077
  local backup_dir="" passphrase_file="${KUBETON_FLEET_PASSPHRASE_FILE:-}"
  fleet_parse_args backup "$@"
  fleet_require_tools
  [[ ! -e "$backup_dir" && ! -L "$backup_dir" ]] || {
    echo "Error: backup destination already exists: $backup_dir" >&2
    exit 1
  }
  mkdir -p "$(dirname "$backup_dir")"
  local staging_dir
  staging_dir="$(mktemp -d "${backup_dir}.partial.XXXXXX")"
  trap 'rm -rf -- "$staging_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  kubectl get tonnodes.ton.ton.org -A -o json | python3 "$CHART_DIR/fleet.py" capture "$staging_dir"
  python3 "$CHART_DIR/fleet.py" fleets "$staging_dir" > "$staging_dir/fleets.tsv"
  python3 "$CHART_DIR/fleet.py" rows "$staging_dir" > "$staging_dir/replicas.tsv"
  local ns name replicas live_replicas ordinal enc meta data_key
  while IFS=$'\t' read -r ns name replicas; do
    live_replicas="$(kubectl -n "$ns" get statefulset "$name" -o jsonpath='{.spec.replicas}')"
    [[ "$live_replicas" == "$replicas" ]] || {
      echo "Error: ${ns}/${name} replica count differs between TonNode and StatefulSet; reconcile before backup." >&2
      exit 1
    }
  done < "$staging_dir/fleets.tsv"

  confirm_or_exit "Back up all TON fleets and passphrase-protected recovery keys? TON pods will restart. Keep the passphrase separate from the backup."
  # Keep the original key backup's cleanup traps scoped to its own subshell.
  ( confirm_or_exit() { :; }; run_backup_keys "$staging_dir" )
  kubectl get tonnodes.ton.ton.org -A -o json | python3 "$CHART_DIR/fleet.py" check-source "$staging_dir"
  python3 "$CHART_DIR/fleet.py" seal "$staging_dir"
  {
    printf 'kubeton-fleet-v1\t%s\n' "$(sha256sum "$staging_dir/fleet.json" | awk '{print $1}')"
    while IFS=$'\t' read -r ns name ordinal enc meta; do
      data_key="$(kubectl -n "$ns" exec -i "${name}-${ordinal}" -c key-backup -- \
        sh -ec "$(cat "$CHART_DIR/fleet-crypto.sh")" -- unwrap \
        < "$staging_dir/$ns/$name/$ordinal/bundle/$meta")"
      printf '%s/%s/%s\t%s\n' "$ns" "$name" "$ordinal" "$data_key"
      unset data_key
    done < "$staging_dir/replicas.tsv"
  } | fleet_gpg --symmetric --cipher-algo AES256 --output "$staging_dir/recovery.gpg"
  fleet_recovery_key "$staging_dir" > /dev/null
  rm "$staging_dir/fleets.tsv" "$staging_dir/replicas.tsv"
  [[ ! -e "$backup_dir" && ! -L "$backup_dir" ]]
  mv -T "$staging_dir" "$backup_dir"
  trap - EXIT INT TERM
  echo "Fleet backup complete: $backup_dir"
  echo "Includes replica counts, TON specifications, encrypted bundles, and portable recovery keys. Blockchain database and main-wallet are excluded."
)

run_restore_fleet() (
  set -euo pipefail
  umask 077
  local backup_dir="" passphrase_file="${KUBETON_FLEET_PASSPHRASE_FILE:-}"
  local data_class="$TON_STORAGE_CLASS_NAME" bundle_class="$ENCRYPTED_SC_NAME"
  local node_selector="" public_ips="" bootstrap=0
  fleet_parse_args restore "$@"
  fleet_require_tools
  require_bin helm
  [[ "$data_class" != auto ]] || { echo "Error: restore-fleet needs an explicit data StorageClass." >&2; exit 1; }
  backup_dir="$(cd "$backup_dir" && pwd)"
  # Fully authenticate/decrypt recovery records and check every bundle before
  # installing anything, creating PVCs, or calling a target key provider.
  python3 "$CHART_DIR/fleet.py" verify "$backup_dir"
  fleet_recovery_key "$backup_dir" > /dev/null

  local work_dir success=0 operator_paused=0
  local -a operator_deploy_names=() operator_deploy_replicas=() helpers=() created_fleets=()
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/kubeton-fleet-restore.XXXXXX")"
  cleanup_fleet_restore() {
    local item cleanup_ns cleanup_name stop_failed=0
    if (( success == 0 )); then
      for item in "${created_fleets[@]}"; do
        IFS=/ read -r cleanup_ns cleanup_name <<< "$item"
        kubectl -n "$cleanup_ns" patch tonnodes.ton.ton.org "$cleanup_name" --type=merge \
          -p '{"spec":{"replicas":0}}' >/dev/null 2>&1 || stop_failed=1
        set_ton_replicas "$cleanup_ns" "$cleanup_name" 0 >/dev/null 2>&1 || stop_failed=1
      done
    fi
    for item in "${helpers[@]}"; do
      IFS=/ read -r cleanup_ns cleanup_name <<< "$item"
      kubectl -n "$cleanup_ns" delete pod "$cleanup_name" --ignore-not-found >/dev/null 2>&1 || true
    done
    if (( operator_paused == 1 )); then
      if (( stop_failed == 0 )); then
        fleet_resume_operator || echo "Error: could not resume the destination operator; inspect its Deployment." >&2
      else
        echo "Error: could not confirm destination fleets were stopped. Operator reconciliation remains paused; inspect TonNode/StatefulSet replica counts before resuming it." >&2
      fi
    fi
    rm -rf -- "$work_dir"
    if (( success == 0 && ${#created_fleets[@]} > 0 )); then
      echo "Fleet restore failed. PVCs were retained for inspection. Check destination replica counts and remove the partial destination fleets before retrying." >&2
    fi
  }
  trap cleanup_fleet_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  python3 "$CHART_DIR/fleet.py" fleets "$backup_dir" > "$work_dir/fleets.tsv"
  python3 "$CHART_DIR/fleet.py" rows "$backup_dir" > "$work_dir/replicas.tsv"
  python3 "$CHART_DIR/fleet.py" prepare "$backup_dir" "$work_dir" \
    "$data_class" "$bundle_class" "$TON_VAULT_CREDS_SECRET" "$VAULT_TRANSIT_KEY" "$node_selector"

  local existing ns name replicas ordinal enc meta prefix pvc helper node address identity
  local -a claim_names=(ton-work ton-src mytoncore mytonctrl keybundle) expected_nodes=()
  existing="$(kubectl get crd tonnodes.ton.ton.org --ignore-not-found -o name)"
  if [[ -n "$existing" ]]; then
    existing="$(kubectl get tonnodes.ton.ton.org -A -o name)"
    [[ -z "$existing" ]] || { echo "Error: restore-fleet requires a destination without existing TonNode resources." >&2; exit 1; }
  fi
  existing="$(kubectl get statefulsets -A -l "$TON_POD_LABEL" -o name)"
  [[ -z "$existing" ]] || { echo "Error: destination already contains TON StatefulSets." >&2; exit 1; }
  while IFS=$'\t' read -r ns name ordinal enc meta; do
    identity="$ns/$name/$ordinal"
    python3 "$CHART_DIR/fleet.py" public-ip "$backup_dir" "$public_ips" "$identity" 192.0.2.1 > /dev/null
    for prefix in "${claim_names[@]}"; do
      pvc="${prefix}-${name}-${ordinal}"
      existing="$(kubectl -n "$ns" get pvc "$pvc" --ignore-not-found -o name)"
      [[ -z "$existing" ]] || { echo "Error: refusing to overwrite destination PVC ${ns}/${pvc}." >&2; exit 1; }
    done
  done < "$work_dir/replicas.tsv"

  confirm_or_exit "Restore fleet counts and identities onto the current Kubernetes context using data=${data_class}, bundles=${bundle_class}? Stop the source validators before starting their restored identities."
  # Bootstrap is explicit: existing external Vault credentials are otherwise
  # used as-is, with no import/export of Vault root tokens or key material.
  if (( bootstrap == 1 )); then
    local ENCRYPTED_SC_NAME="$bundle_class"
    ensure_auto_bootstrap_stack
    local root_token TON_NAMESPACE
    root_token="$(initialize_and_unseal_vault)"
    while IFS=$'\t' read -r ns name replicas; do
      TON_NAMESPACE="$ns"
      configure_vault_for_ton "$root_token"
    done < "$work_dir/fleets.tsv"
    unset root_token
  fi
  kubectl get storageclass "$data_class" >/dev/null
  kubectl get storageclass "$bundle_class" >/dev/null
  while IFS=$'\t' read -r ns name replicas; do
    kubectl -n "$ns" get secret "$TON_VAULT_CREDS_SECRET" >/dev/null || {
      echo "Error: configure destination Vault credentials in ${ns}/${TON_VAULT_CREDS_SECRET}, or use --bootstrap." >&2
      exit 1
    }
  done < "$work_dir/fleets.tsv"

  ensure_tonnode_crd_schema
  local -a helm_cmd=(helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" -n "$OP_NAMESPACE"
    --create-namespace -f "$OP_VALUES_FILE" --set tonNode.enabled=false --wait --timeout 10m)
  append_helm_force_conflicts_if_supported helm_cmd
  "${helm_cmd[@]}"
  while IFS=$'\t' read -r ns name replicas; do
    ensure_namespace "$ns"
    kubectl create -f "$work_dir/${ns}--${name}.json" >/dev/null
    created_fleets+=("$ns/$name")
    wait_statefulset_present "$ns" "$name" 300
  done < "$work_dir/fleets.tsv"
  operator_paused=1
  pause_operator_reconcile operator_deploy_names operator_deploy_replicas
  (( ${#operator_deploy_names[@]} > 0 )) || {
    echo "Error: cannot pause the destination operator; no release controller Deployment found." >&2
    exit 1
  }
  # Wait until controller pods actually exit before patching their resources.
  local deployment
  for deployment in "${operator_deploy_names[@]}"; do
    kubectl -n "$OP_NAMESPACE" rollout status "deployment/$deployment" --timeout=300s >/dev/null
  done

  while IFS=$'\t' read -r ns name replicas; do
    kubectl -n "$ns" get statefulset "$name" -o json > "$work_dir/${ns}--${name}.sts.json"
    python3 "$CHART_DIR/fleet.py" claims "$work_dir" "$replicas" \
      < "$work_dir/${ns}--${name}.sts.json" | kubectl create -f - >/dev/null
  done < "$work_dir/fleets.tsv"

  local session="fleet-$RANDOM-$RANDOM" bundle_dir validator_port
  while IFS=$'\t' read -r ns name ordinal enc meta; do
    helper="kubeton-fleet-$RANDOM-$RANDOM"
    helpers+=("$ns/$helper")
    python3 "$CHART_DIR/fleet.py" helper "$helper" "$ordinal" "$session" \
      < "$work_dir/${ns}--${name}.sts.json" | kubectl create -f - >/dev/null
    if ! kubectl -n "$ns" wait --for=condition=Ready "pod/$helper" --timeout="$HELPER_POD_READY_TIMEOUT"; then
      print_helper_pod_failure_context "$ns" "$helper"
      exit 1
    fi
    node="$(kubectl -n "$ns" get pod "$helper" -o jsonpath='{.spec.nodeName}')"
    address="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')"
    if [[ -z "$address" ]]; then
      address="$(kubectl -n "$ns" get pod "$helper" -o jsonpath='{.status.hostIP}')"
    fi
    identity="$ns/$name/$ordinal"
    address="$(python3 "$CHART_DIR/fleet.py" public-ip "$backup_dir" "$public_ips" "$identity" "$address")"
    printf '%s\n' "$node" >> "$work_dir/${ns}--${name}.nodes"
    validator_port="$(kubectl -n "$ns" get statefulset "$name" -o jsonpath='{.spec.template.spec.containers[?(@.name=="ton-node")].ports[?(@.name=="validator-udp")].containerPort}')"
    bundle_dir="$backup_dir/$ns/$name/$ordinal/bundle"
    kubectl -n "$ns" cp "$bundle_dir/$enc" "$helper:/bundle/$enc" >/dev/null
    kubectl -n "$ns" cp "$bundle_dir/$meta" "$helper:/bundle/$meta" >/dev/null
    kubectl -n "$ns" cp "$CHART_DIR/fleet.py" "$helper:/recovery/fleet.py" >/dev/null
    fleet_recovery_key "$backup_dir" "$identity" | kubectl -n "$ns" exec -i "$helper" -- \
      sh -ec "$(cat "$CHART_DIR/fleet-crypto.sh")" -- restore "$address" "$validator_port"
    echo "Staged $identity on $node (advertised IP $address)."
  done < "$work_dir/replicas.tsv"

  # Release helper mounts/host ports before any TON process starts. Every
  # replica now has its original identity, rewrapped by the destination Vault.
  local item
  for item in "${helpers[@]}"; do
    IFS=/ read -r ns helper <<< "$item"
    kubectl -n "$ns" delete pod "$helper" --wait=true --timeout=300s >/dev/null
  done
  helpers=()
  while IFS=$'\t' read -r ns name replicas; do
    mapfile -t expected_nodes < "$work_dir/${ns}--${name}.nodes"
    kubectl -n "$ns" patch tonnodes.ton.ton.org "$name" --type=merge \
      -p "{\"spec\":{\"replicas\":${replicas}}}" >/dev/null
    restore_statefulset_with_expected_nodes "$ns" "$name" "$replicas" expected_nodes
  done < "$work_dir/fleets.tsv"
  fleet_resume_operator
  operator_paused=0
  success=1
  echo "Fleet restore complete. Original identities and replica counts restored using destination nodes, storage, and Vault."
  echo "Blockchain data must synchronize on the fresh data volumes."
)
