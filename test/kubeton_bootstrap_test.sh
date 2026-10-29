#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export KUBETON_LAUNCH_LOGS_ENABLED=false

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }
assert_absent() { ! grep -Fq -- "$1" "$2" || fail "unexpected '$1' in $2"; }
assert_failure() {
  local rc=0
  # Deliberately invoke under a conditional: Bash must not hide a failed
  # bootstrap step when a launch wrapper or caller disables errexit.
  if "$@"; then fail "unexpected success: $*"; else rc=$?; fi
  [[ "$rc" == 23 ]] || fail "expected exit 23, got $rc: $*"
}

for failed_step in none longhorn crypto storage-class vault init transit; do
  (
    source "$kubeton"
    require_bin() { :; }
    calls="$test_dir/stack-${failed_step}.calls"
    : >"$calls"
    step() {
      printf '%s\n' "$1" >>"$calls"
      [[ "$failed_step" != "$1" ]] || return 23
    }
    ensure_longhorn_installed() { step longhorn; }
    ensure_longhorn_crypto_secret() { step crypto; }
    ensure_encrypted_storage_class() { step storage-class; }
    ensure_vault_installed() { [[ "$1" == longhorn ]] || fail 'wrong Vault class'; step vault; }
    initialize_and_unseal_vault() { step init || return $?; printf test-root-token; }
    configure_vault_for_ton() { [[ "$1" == test-root-token ]] || fail 'wrong token'; step transit; }
    if [[ "$failed_step" == none ]]; then
      if ! ensure_baremetal_stack; then fail 'healthy bootstrap failed'; fi
      expected=$'longhorn\ncrypto\nstorage-class\nvault\ninit\ntransit'
    else
      assert_failure ensure_baremetal_stack
      expected="$(printf '%s\n' longhorn crypto storage-class vault init transit | sed "/^${failed_step}$/q")"
    fi
    [[ "$(cat "$calls")" == "$expected" ]] || fail "bootstrap continued past ${failed_step}"
  )
done

(
  source "$kubeton"
  cluster_is_baremetal() { return 1; }
  cluster_is_k3d() { return 1; }
  AUTO_BAREMETAL_BOOTSTRAP=true
  FORCE_BAREMETAL_BOOTSTRAP=false
  if should_bootstrap_baremetal; then fail 'cloud bootstrapped without force'; fi
  FORCE_BAREMETAL_BOOTSTRAP=true
  should_bootstrap_baremetal || fail 'force did not enable cloud bootstrap'
  AUTO_BAREMETAL_BOOTSTRAP=false
  if should_bootstrap_baremetal; then fail 'force overrode disabled auto bootstrap'; fi
  ensure_baremetal_stack() { return 23; }
  assert_failure ensure_auto_bootstrap_stack
  cluster_is_k3d() { return 0; }
  ensure_localdev_stack() { return 23; }
  assert_failure ensure_auto_bootstrap_stack
)

for bootstrap_rc in 0 23; do
  (
    source "$kubeton"
    require_bin() { :; }
    cluster_is_baremetal() { return 1; }
    cluster_is_k3d() { return 1; }
    FORCE_BAREMETAL_BOOTSTRAP=true
    resolve_ton_replicas_for_node_check() { printf 3; }
    prepare_node_prerequisites_for_workload() { [[ "$*" == '3 true' ]] || fail 'wrong preflight'; }
    ensure_auto_bootstrap_stack() { return "$bootstrap_rc"; }
    if [[ "$bootstrap_rc" == 0 ]]; then
      run_bootstrap_baremetal >"$test_dir/bootstrap.out"
      assert_contains '[bootstrap] Completed.' "$test_dir/bootstrap.out"
    else
      assert_failure run_bootstrap_baremetal >"$test_dir/bootstrap-failed.out"
      assert_absent '[bootstrap] Completed.' "$test_dir/bootstrap-failed.out"
    fi
  )
done

(
  source "$kubeton"
  require_bin() { :; }
  resolve_ton_replicas_from_values_file() { printf 3; }
  FORCE_BAREMETAL_BOOTSTRAP=true
  AUTO_BAREMETAL_BOOTSTRAP=true
  KUBETON_START_VICTORIA_LOGS_ENABLED=false
  prepare_node_prerequisites_for_workload() { :; }
  fleet_has_stop_annotations() { return 1; }
  ensure_ton_storage_class_available() { :; }
  append_ton_storage_overrides() { :; }
  should_use_sequential_ton_start() { return 1; }
  ensure_start_victoria_logs_buffering_collector() { :; }
  ensure_auto_bootstrap_stack() { return 23; }
  append_baremetal_key_overrides() { fail 'start continued after failed bootstrap'; }
  if run_start >"$test_dir/start-failed.out" 2>&1; then fail 'start hid bootstrap failure'; fi
  assert_absent 'start continued' "$test_dir/start-failed.out"
)

(
  source "$kubeton"
  require_bin() { :; }
  FORCE_BAREMETAL_BOOTSTRAP=true
  run_node_prerequisite_check_readonly() { :; }
  ensure_tonnode_crd_schema() { :; }
  append_helm_force_conflicts_if_supported() { :; }
  resolve_operator_controller_deployment_name() { printf ton-k8s-operator-controller-manager; }
  ensure_auto_bootstrap_stack() { fail 'install must remain operator-only'; }
  helm() {
    [[ "$*" != *'status'* ]] || return 1
    [[ "$*" == *'upgrade --install'* && "$*" != *longhorn* && "$*" != *vault* ]] || fail 'unexpected Helm install'
  }
  kubectl() { [[ "$*" == *'rollout status deployment/ton-k8s-operator-controller-manager'* ]] || fail 'unexpected install kubectl'; }
  run_install >"$test_dir/install.out"
  assert_contains 'Operator-only install' "$test_dir/install.out"
  assert_contains "'kubeton start' or 'kubeton bootstrap-baremetal'" "$test_dir/install.out"
  assert_contains 'an install-only prefix does not carry over' "$test_dir/install.out"
)

for failed_rollout in longhorn-manager longhorn-csi-plugin csi-attacher multipath; do
  (
    source "$kubeton"
    storage_class_provisioner() { printf driver.longhorn.io; }
    list_longhorn_csi_node_names() { printf node-1; }
    verify_longhorn_multipathd_safe() { [[ "$failed_rollout" != multipath ]] || return 23; }
    kubectl() {
      if [[ "$*" == *'rollout status'* && "$*" == *"/${failed_rollout} "* ]]; then return 23; fi
      if [[ "$*" == *jsonpath* ]]; then printf 1; fi
    }
    assert_failure wait_longhorn_storage_ready longhorn 30 >"$test_dir/readiness-${failed_rollout}.out"
  )
done

for failed_check in wait multipath; do
  (
    source "$kubeton"
    require_bin() { :; }
    LONGHORN_NODE_SELECTOR=''
    recover_stuck_longhorn_namespace() { :; }
    ensure_namespace_not_terminating() { :; }
    longhorn_release_status() { printf deployed; }
    longhorn_storage_ready_quick() { :; }
    apply_longhorn_post_start_settings() { :; }
    ensure_longhorn_daemonsets_constrained() { :; }
    wait_longhorn_storage_ready() { [[ "$failed_check" != wait ]] || return 23; }
    verify_longhorn_multipathd_safe() { [[ "$failed_check" != multipath ]] || return 23; }
    assert_failure ensure_longhorn_installed >"$test_dir/longhorn-${failed_check}.out"
    assert_absent 'CSI/storage are Ready; skipping Helm upgrade' "$test_dir/longhorn-${failed_check}.out"
  )
done

(
  source "$kubeton"
  require_bin() { :; }
  LONGHORN_NODE_SELECTOR=''
  ensure_namespace_not_terminating() { :; }
  ensure_helm_repo() { :; }
  helm() { :; }
  cluster_is_k3d() { return 1; }
  storage_class_is_longhorn() { return 0; }
  wait_longhorn_storage_ready() { return 23; }
  run_vault_helm_install() { fail 'Vault Helm started before storage was ready'; }
  assert_failure ensure_vault_installed longhorn >"$test_dir/vault-storage-failed.out"
)

for failed_op in none init secret-write unseal status; do
  (
    source "$kubeton"
    vault_status_with_retry() {
      [[ "$failed_op" != status ]] || return 23
      printf 'Initialized false\nSealed true\n'
    }
    vault_exec() {
      case "$*" in
        *'operator init'*)
          [[ "$failed_op" != init ]] || return 23
          printf 'Unseal Key 1: test-key\nInitial Root Token: test-token\n'
          ;;
        *'operator unseal'*) [[ "$failed_op" != unseal ]] || return 23 ;;
        *) fail "unexpected Vault command $*" ;;
      esac
    }
    kubectl() {
      case "$*" in
        'apply -f -') cat >/dev/null; [[ "$failed_op" != secret-write ]] || return 23 ;;
        *'create secret'*) printf 'kind: Secret\n' ;;
        *'data.unseal_key'*) printf test-key | base64 ;;
        *'data.root_token'*) printf test-token | base64 ;;
        *'get secret'*) : ;;
        *) fail "unexpected kubectl command $*" ;;
      esac
    }
    if [[ "$failed_op" == none ]]; then
      token="$(initialize_and_unseal_vault)" || fail 'healthy init/unseal failed'
      [[ "$token" == test-token ]] || fail 'incorrect init token output'
    else
      # A command substitution is another context where errexit cannot be
      # relied on to propagate failed Secret writes or unseal commands.
      rc=0
      if token="$(initialize_and_unseal_vault)"; then fail "Vault hid ${failed_op} failure"; else rc=$?; fi
      [[ "$rc" == 23 || "$failed_op" == status && "$rc" == 1 ]] || fail "wrong Vault failure status: $rc"
      [[ -z "$token" ]] || fail 'failed init/unseal returned a usable token'
    fi
  ) 2>"$test_dir/vault-init-${failed_op}.err"
done

(
  source "$kubeton"
  require_bin() { :; }
  kubectl() { [[ "$*" != *'create secret'* ]] || fail 'created a Secret after RNG failure'; return 1; }
  openssl() { return 23; }
  assert_failure ensure_longhorn_crypto_secret >"$test_dir/rng-failed.out"
)

echo 'kubeton Longhorn/Vault bootstrap regression tests passed.'
