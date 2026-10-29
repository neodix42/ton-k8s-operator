#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# A Kubernetes/RBAC error cannot be interpreted as an absent namespace.
if bash -c '
  source "$1"
  kubectl() { return 19; }
  delete_namespace_with_progress vault 0
' _ "$kubeton" >"$test_dir/ns-error" 2>&1; then
  echo "namespace read failure incorrectly reported cleanup success" >&2; exit 1
fi
grep -Fq 'cannot inspect namespace vault' "$test_dir/ns-error"

# Exhausted retries are failures even when force cleanup commands return 0.
if bash -c '
  source "$1"
  kubectl() {
    case "$*" in
      *"get namespace"*"-o name"*) echo namespace/vault ;;
      *".status.phase"*) echo Terminating ;;
    esac
  }
  sleep() { :; }
  cleanup_vault_force() { :; }
  storage_namespace_is_release_owned() { :; }
  delete_namespace_with_progress vault 0
' _ "$kubeton" >"$test_dir/ns-timeout" 2>&1; then
  echo "stuck namespace incorrectly reported cleanup success" >&2; exit 1
fi
grep -Fq 'uninstall is incomplete' "$test_dir/ns-timeout"

# Normal asynchronous deletion verifies absence, including on a later retry.
bash -c '
  source "$1"
  storage_namespace_is_release_owned() { :; }
  namespace_state_file="$2"
  printf present >"$namespace_state_file"
  kubectl() {
    case "$*" in
      *"get namespace"*"-o name"*) [[ ! -s "$namespace_state_file" ]] || echo namespace/vault ;;
      *"delete namespace"*) : >"$namespace_state_file" ;;
    esac
  }
  delete_namespace_with_progress vault 0
  delete_namespace_with_progress vault 0
' _ "$kubeton" "$test_dir/ns-state" >"$test_dir/ns-ok" 2>&1
grep -Fq 'Namespace vault removed.' "$test_dir/ns-ok"
grep -Fq 'Namespace vault already absent.' "$test_dir/ns-ok"

# The exact failed command status must survive if/else handling and fallback.
for component in longhorn vault; do
  if bash -c '
    source "$1"
    component="$2"
    storage_release_present() { return 0; }
    longhorn_storage_is_unused() { :; }
    kubectl() { :; }
    run_with_timeout() {
      [[ "$*" != *--no-hooks* ]] || return 7
      return 124
    }
    cleanup_longhorn_force() { return 42; }
    cleanup_vault_force() { return 42; }
    "uninstall_${component}"
  ' _ "$kubeton" "$component" >"$test_dir/helm-$component" 2>&1; then
    echo "$component fallback failure incorrectly reported success" >&2; exit 1
  else
    [[ $? == 42 ]]
  fi
  grep -Fq 'timed out' "$test_dir/helm-$component"
  grep -Fq 'failed (exit 7)' "$test_dir/helm-$component"
done

# Readable Helm inventory distinguishes not-found from API failure.
bash -c '
  source "$1"
  helm() { printf "vault-other\nvault\n"; }
  storage_release_present vault vault
  if storage_release_present va vault; then exit 1; else [[ $? == 1 ]]; fi
  helm() { return 9; }
  if storage_release_present vault vault; then exit 1; else [[ $? == 2 ]]; fi
' _ "$kubeton" >"$test_dir/helm-inventory" 2>&1

# Helm 3 requires --all to include failed/pending states, while Helm 4 has
# removed the flag. Exercise both interfaces without contacting a cluster.
for helm_major in 3 4; do
  bash -c '
    source "$1"
    helm_major="$2"
    helm() {
      if [[ "$*" == "list --help" ]]; then
        if [[ "$helm_major" == 3 ]]; then echo "  -a, --all show all releases"; else echo "  -A, --all-namespaces list namespaces"; fi
        return 0
      fi
      if [[ "$helm_major" == 3 ]]; then
        [[ "$*" == *" --all" ]] || return 32
      else
        [[ "$*" != *" --all" ]] || return 42
      fi
      echo vault
    }
    storage_release_present vault vault
  ' _ "$kubeton" "$helm_major"
done

# Neither uninstall hooks nor force cleanup may touch a shared storage stack.
for target in pv backend; do
  if bash -c '
    source "$1"
    event_log="$2" target="$3"
    storage_cleanup_ledger_has_pending_longhorn_targets() { return 1; }
    kubectl() {
      case "$*" in
        "get pv "*) [[ "$target" != pv ]] || echo "pv-other driver.longhorn.io" ;;
        "get crd volumes.longhorn.io"*) echo customresourcedefinition.apiextensions.k8s.io/volumes.longhorn.io ;;
        "get volumes.longhorn.io"*) [[ "$target" != backend ]] || echo volume.longhorn.io/external-data ;;
        *delete*|*patch*) printf "%s\n" "$*" >>"$event_log" ;;
      esac
      return 0
    }
    uninstall_longhorn() { printf "UNSAFE Helm\n" >>"$event_log"; }
    cleanup_longhorn_release
  ' _ "$kubeton" "$test_dir/shared-$target-events" "$target" >"$test_dir/shared-$target" 2>&1; then
    echo "shared $target failed to block Longhorn teardown" >&2; exit 1
  fi
  [[ ! -s "$test_dir/shared-$target-events" ]]
done

# The configured encrypted StorageClass can also be shared, including by a
# Pending claim that has not created a backend volume yet.
for target in pvc pv; do
  if bash -c '
    source "$1"
    event_log="$2" target="$3"
    kubectl() {
      case "$*" in
        "get storageclass "*) echo storageclass.storage.k8s.io/encrypted-sc ;;
        "get pvc "*) [[ "$target" != pvc ]] || echo "other external encrypted-sc" ;;
        "get pv "*) [[ "$target" != pv ]] || echo "external-pv encrypted-sc" ;;
        delete*) printf "%s\n" "$*" >>"$event_log" ;;
      esac
      return 0
    }
    cleanup_encrypted_storage_class
  ' _ "$kubeton" "$test_dir/shared-sc-$target-events" "$target" >"$test_dir/shared-sc-$target" 2>&1; then
    echo "shared encrypted StorageClass $target failed to block deletion" >&2; exit 1
  fi
  [[ ! -s "$test_dir/shared-sc-$target-events" ]]
done

# Foreign workloads must prevent namespace-wide Vault deletion.
if bash -c '
  source "$1"
  event_log="$2"
  helm() { echo vault; }
  kubectl() {
    case "$*" in
      "get namespace "*) echo namespace/vault ;;
      api-resources*) echo deployments.apps ;;
      *"get deployments.apps "*) echo "foreign <none> <none> <none> <none> <none> <none> <none> <none>" ;;
      *delete*|*patch*) printf "%s\n" "$*" >>"$event_log" ;;
    esac
  }
  cleanup_vault_force
' _ "$kubeton" "$test_dir/shared-vault-events" >"$test_dir/shared-vault" 2>&1; then
  echo "foreign workload failed to block Vault namespace deletion" >&2; exit 1
fi
[[ ! -s "$test_dir/shared-vault-events" ]]
grep -Fq 'ownership of deployments.apps/foreign' "$test_dir/shared-vault"

# Helm release records are valid ownership evidence, including custom names.
bash -c '
  source "$1"
  helm() { echo custom-vault; }
  kubectl() {
    case "$*" in
      "get namespace "*) echo namespace/vault ;;
      api-resources*) echo secrets ;;
      *"get secrets "*) echo "sh.helm.release.v1.custom-vault.v1 <none> <none> <none> <none> <none> <none> helm custom-vault" ;;
    esac
  }
  storage_namespace_is_release_owned vault custom-vault vault
' _ "$kubeton"

# Longhorn 1.10 creates runtime components without Helm/app labels. Their
# upstream managed-by labels, PDB selectors, and exact leader leases establish
# ownership without accepting arbitrary workloads or name substrings.
bash -c '
  source "$1"
  helm() { echo longhorn; }
  kubectl() {
    case "$*" in
      "get namespace "*) echo namespace/longhorn-system ;;
      api-resources*) printf "pods\npoddisruptionbudgets.policy\nleases.coordination.k8s.io\nsecrets\nendpointslices.discovery.k8s.io\n" ;;
      *"get pods "*) echo "instance-manager-abc <none> <none> <none> <none> <none> <none> <none> <none> longhorn-manager <none> <none> <none>" ;;
      *"get poddisruptionbudgets.policy "*) echo "instance-manager-abc <none> <none> <none> <none> <none> <none> <none> <none> <none> <none> longhorn-manager <none>" ;;
      *"get leases.coordination.k8s.io "*) echo "longhorn-manager-webhook-lock <none> <none> <none> <none> <none> <none> <none> <none> <none> <none> <none> <none>" ;;
      *"get secrets "*) echo "longhorn-webhook-ca <none> <none> <none> <none> <none> <none> <none> <none> <none> <none> <none> <none>" ;;
      *"get endpointslices.discovery.k8s.io "*) echo "webhook-slice <none> <none> <none> <none> <none> <none> <none> <none> <none> longhorn-admission-webhook <none> <none>" ;;
    esac
  }
  storage_namespace_is_release_owned longhorn-system longhorn longhorn
' _ "$kubeton"

# Helm metadata can already be gone on retry. Exact release annotations still
# identify orphan RBAC, and runtime webhooks must point to this namespace.
bash -c '
  source "$1"
  event_log="$2"
  longhorn_storage_is_unused() { :; }
  storage_namespace_is_release_owned() { :; }
  kubectl() {
    case "$*" in
      "get clusterrole,"*)
        printf "ClusterRole longhorn-role longhorn longhorn-system\nClusterRole foreign-role other shared\n" ;;
      "get csidriver driver.longhorn.io "*) echo csidriver.storage.k8s.io/driver.longhorn.io ;;
      "get storageclass longhorn "*) echo driver.longhorn.io ;;
      "get validatingwebhookconfiguration longhorn-webhook-validator "*) echo longhorn-system ;;
      "get mutatingwebhookconfiguration longhorn-webhook-mutator "*) echo other-namespace ;;
      delete*) printf "%s\n" "$*" >>"$event_log" ;;
    esac
  }
  cleanup_longhorn_force
' _ "$kubeton" "$test_dir/longhorn-orphans"
grep -Fq 'delete ClusterRole/longhorn-role' "$test_dir/longhorn-orphans"
grep -Fq 'delete csidriver.storage.k8s.io/driver.longhorn.io' "$test_dir/longhorn-orphans"
grep -Fq 'delete validatingwebhookconfiguration/longhorn-webhook-validator' "$test_dir/longhorn-orphans"
grep -Fq 'delete storageclass/longhorn' "$test_dir/longhorn-orphans"
if grep -Eq 'foreign-role|mutator' "$test_dir/longhorn-orphans"; then
  echo 'unrelated cluster resource selected for deletion' >&2; exit 1
fi

bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    case "$*" in
      "get clusterrole,"*) echo "ClusterRole vault-orphan vault vault" ;;
      delete*) printf "%s\n" "$*" >>"$event_log" ;;
    esac
  }
  cleanup_vault_force
' _ "$kubeton" "$test_dir/vault-orphans"
grep -Fq 'delete ClusterRole/vault-orphan' "$test_dir/vault-orphans"

# Per-resource LIST/discovery failures remain visible in the final report,
# rather than disappearing in process substitutions as an empty inventory.
for scenario in denied-list denied-discovery; do
  bash -c '
    source "$1"
    scenario="$2"
    kubectl() {
      case "$*" in
        "api-resources "*"--namespaced=true"*)
          [[ "$scenario" != denied-discovery ]] || return 23
          echo networkpolicies.networking.k8s.io ;;
        "api-resources "*"--namespaced=false"*) echo clusterroles.rbac.authorization.k8s.io ;;
        "get networkpolicies.networking.k8s.io "*) return 17 ;;
      esac
    }
    rows=()
    collect_labeled_resource_leftovers app.kubernetes.io/managed-by=kubeton rows
    printf "%s\n" "${rows[@]}"
    (( ${#rows[@]} > 0 ))
  ' _ "$kubeton" "$scenario" >"$test_dir/$scenario"
done
grep -Fq 'Managed-resource inventory unavailable: networkpolicies.networking.k8s.io' "$test_dir/denied-list"
grep -Fq 'Namespaced resource discovery unavailable' "$test_dir/denied-discovery"

# An already-purged TonNode CRD must not cause a spurious unavailable marker
# or a request against a nonexistent custom-resource endpoint.
bash -c '
  source "$1"
  event_log="$2"
  kubectl() {
    printf "%s\n" "$*" >>"$event_log"
    case "$*" in
      *"get tonnodes.ton.ton.org "*) return 99 ;;
    esac
  }
  helm() { :; }
  list_ton_statefulsets() { :; }
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() { :; }
  collect_local_path_cleanup_ledger_leftovers() { :; }
  collect_victoria_logs_release_rows() { :; }
  collect_labeled_resource_leftovers() { :; }
  rows=()
  collect_uninstall_leftovers rows
  (( ${#rows[@]} == 0 ))
' _ "$kubeton" "$test_dir/absent-ton-crd"
if grep -Fq 'get tonnodes.ton.ton.org ' "$test_dir/absent-ton-crd"; then
  echo 'verification queried a nonexistent TonNode API after purge' >&2; exit 1
fi

# Final verification records failed inventory queries rather than printing a
# misleading no-leftovers success message.
if bash -c '
  source "$1"
  kubectl() { return 13; }
  helm() { return 17; }
  list_ton_statefulsets() { :; }
  collect_expected_ton_pvc_rows_from_values() { :; }
  collect_labeled_ton_pvc_rows() { :; }
  collect_existing_kubeton_pvc_rows() { :; }
  collect_local_path_cleanup_ledger_leftovers() { :; }
  collect_victoria_logs_release_rows() { :; }
  collect_labeled_resource_leftovers() { :; }
  verify_uninstall_leftovers
' _ "$kubeton" >"$test_dir/final-inventory" 2>&1; then
  echo "unreadable final inventory incorrectly reported completion" >&2; exit 1
fi
grep -Fq 'Namespace inventory unavailable' "$test_dir/final-inventory"
grep -Fq 'Helm inventory unavailable' "$test_dir/final-inventory"
grep -Fq 'Storage CRD inventory unavailable' "$test_dir/final-inventory"
if grep -Fq 'No kubeton-managed leftovers found.' "$test_dir/final-inventory"; then exit 1; fi

echo 'kubeton storage uninstall checks: PASS'
