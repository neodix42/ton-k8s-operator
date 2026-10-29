#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

for scenario in prometheus-failure prometheus-discovery-empty vm-custom vm-failure vm-shared vm-invalid-state vm-inventory-denied vm-pvc vm-no-ledger vm-empty-namespace vm-shared-namespace vm-other-operator vm-policies vm-external-policy vm-external-state-cm vm-orphan-unknown vm-untracked-shared vm-untracked-other-operator wallet-custom sweep-failure; do
  log="$test_dir/$scenario.log"
  SCENARIO="$scenario" EVENT_LOG="$log" bash -c '
    source "$1"
    kubectl() {
      printf "%s\n" "$*" >>"$EVENT_LOG"
      case "$*" in
        *"api-resources"*"--namespaced=false"*) printf "clusterroles.rbac.authorization.k8s.io\n" ;;
        *"api-resources"*"--api-group=operator.victoriametrics.com"*)
          printf "vmusers.operator.victoriametrics.com\nvmauths.operator.victoriametrics.com\nvmagents.operator.victoriametrics.com\nvmsingles.operator.victoriametrics.com\nvmservicescrapes.operator.victoriametrics.com\n"
          ;;
        *"api-resources"*)
          [[ "$SCENARIO" != sweep-failure ]] || return 1
          [[ "$SCENARIO" != prometheus-discovery-empty ]] || return 0
          printf "deployments.apps\nreplicasets.apps\nstatefulsets.apps\npods\nservices\nconfigmaps\nsecrets\nserviceaccounts\nroles.rbac.authorization.k8s.io\nrolebindings.rbac.authorization.k8s.io\npersistentvolumeclaims\nnetworkpolicies.networking.k8s.io\nvmusers.operator.victoriametrics.com\nvmauths.operator.victoriametrics.com\nvmagents.operator.victoriametrics.com\nvmsingles.operator.victoriametrics.com\nvmservicescrapes.operator.victoriametrics.com\n"
          ;;
        "get configmap -A -l app.kubernetes.io/name=kubeton-victoria-metrics,"*)
          [[ "$SCENARIO" != vm-inventory-denied ]] || return 1
          case "$SCENARIO" in vm-no-ledger|vm-orphan-unknown|vm-untracked-*) return 0 ;; esac
          if [[ "$SCENARIO" == vm-invalid-state ]]; then
            printf "old-operator|custom-state||old-fleet|old-operator\n"
            return
          fi
          printf "old-operator|custom-state|old-metrics|old-fleet|old-operator\n"
          ;;
        "get pvc -A -l app.kubernetes.io/name=kubeton-main-wallet,"*) printf "old-wallets\tcustom-main-wallet-keybundle\n" ;;
        "get vmsingles.operator.victoriametrics.com -A --ignore-not-found -o name")
          case "$SCENARIO" in vm-shared|vm-untracked-shared) printf "vmsingle/external-stack\n" ;; esac
          ;;
        "get vmauths.operator.victoriametrics.com -A -l "*)
          [[ "$SCENARIO" != vm-no-ledger ]] || printf "old-metrics\told-fleet\n"
          ;;
        "get deployments -A -l app.kubernetes.io/name=victoria-metrics-operator "*)
          if [[ "$SCENARIO" == vm-other-operator ]]; then
            printf "old-operator\nexternal-operator\n"
          elif [[ "$SCENARIO" == vm-untracked-other-operator ]]; then
            printf "vm|vm-operator\nexternal-operator|vm-operator\n"
          fi
          ;;
        "-n vm get deployment vm-operator --ignore-not-found -o name")
          case "$SCENARIO" in vm-orphan-unknown|vm-untracked-*) printf "deployment.apps/vm-operator\n" ;; esac
          ;;
        "-n old-metrics get pvc -l "*)
          [[ "$SCENARIO" != vm-pvc ]] || printf "vmsingle-old-fleet\n"
          ;;
        "-n old-metrics get pvc vmsingle-old-fleet "*) printf pv-vmsingle ;;
        "get namespace "*)
          if [[ "$SCENARIO" == vm-empty-namespace || "$SCENARIO" == vm-shared-namespace || "$SCENARIO" == vm-external-policy || "$SCENARIO" == vm-external-state-cm ]]; then
            printf "namespace/%s\n" "$3"
          fi
          ;;
        "-n old-operator get networkpolicy vm-allow-metrics-traffic "*)
          if [[ "$SCENARIO" == vm-policies ]]; then
            printf "test|kustomize|test|controller-manager"
          elif [[ "$SCENARIO" == vm-external-policy ]]; then
            printf "test|external-owner|test|controller-manager"
          fi
          ;;
        "-n old-operator get networkpolicy vm-allow-webhook-traffic "*)
          [[ "$SCENARIO" != vm-policies ]] || printf "vm-operator|kustomize|vm-operator|controller-manager"
          ;;
        "-n old-operator get networkpolicies.networking.k8s.io --ignore-not-found -o name")
          [[ "$SCENARIO" != vm-external-policy ]] || printf "networkpolicy.networking.k8s.io/vm-allow-metrics-traffic\n"
          ;;
        "-n old-metrics get secrets --ignore-not-found -o name")
          [[ "$SCENARIO" != vm-shared-namespace ]] || printf "secret/external-credentials\n"
          ;;
        *"get serviceaccounts --ignore-not-found -o name") printf "serviceaccount/default\n" ;;
        *"get configmaps --ignore-not-found -l app.kubernetes.io/name!=kubeton-victoria-metrics -o name") printf "configmap/kube-root-ca.crt\n" ;;
        "-n old-operator get configmaps --ignore-not-found -l app.kubernetes.io/name=kubeton-victoria-metrics,app.kubernetes.io/managed-by!=kubeton -o name")
          [[ "$SCENARIO" != vm-external-state-cm ]] || printf "configmap/external-metrics-settings\n"
          ;;
        "get crd -o name") printf "customresourcedefinition.apiextensions.k8s.io/vmauths.operator.victoriametrics.com\n" ;;
        *"delete services "*"kubeton-prometheus"*) [[ "$SCENARIO" != prometheus-failure ]] ;;
        *"delete vmagents.operator.victoriametrics.com "*) [[ "$SCENARIO" != vm-failure ]] ;;
      esac
    }
    cleanup_prometheus_port_forwards() { echo close-prometheus >>"$EVENT_LOG"; }
    cleanup_victoria_metrics_port_forwards() { echo close-vm >>"$EVENT_LOG"; }
    cleanup_victoria_logs_resources() { echo cleanup-logs >>"$EVENT_LOG"; }
    append_pv_cleanup_ledger_row_for_pv() {
      local -n rows="$3"; rows+=("$1 $2"); echo "inventory-pv $1 $2" >>"$EVENT_LOG"
    }
    append_local_path_exact_cleanup_rows_for_pv() { :; }
    record_local_path_cleanup_ledger() { echo record-storage-ledger >>"$EVENT_LOG"; }
    delete_pvc_rows_and_backing_volumes() {
      local -n rows="$1"
      [[ ${#rows[@]} -eq 0 ]] || echo "delete-recorded-vm-pvc ${rows[*]}" >>"$EVENT_LOG"
      return 0
    }
    case "$SCENARIO" in
      prometheus-failure|prometheus-discovery-empty)
        if cleanup_prometheus_resources; then exit 21; fi
        ;;
      vm-custom|vm-shared|vm-pvc|vm-no-ledger|vm-empty-namespace|vm-shared-namespace|vm-other-operator|vm-policies|vm-external-policy|vm-external-state-cm|vm-untracked-*) cleanup_victoria_metrics_resources ;;
      vm-orphan-unknown)
        if cleanup_victoria_metrics_resources >"$EVENT_LOG.error" 2>&1; then exit 25; fi
        test "$KUBETON_RETAIN_VICTORIA_METRICS_STATE" = 1
        ;;
      wallet-custom) cleanup_main_wallet_resources ;;
      vm-invalid-state|vm-inventory-denied)
        if cleanup_victoria_metrics_resources; then exit 24; fi
        test "$KUBETON_RETAIN_VICTORIA_METRICS_STATE" = 1
        ;;
      vm-failure)
        if cleanup_victoria_metrics_resources; then exit 22; fi
        test "$KUBETON_RETAIN_VICTORIA_METRICS_STATE" = 1
        cleanup_kubeton_managed_labeled_resources || true
        ;;
      sweep-failure)
        if cleanup_kubeton_managed_labeled_resources; then exit 23; fi
        ;;
    esac
  ' _ "$kubeton"
done

grep -Fq 'delete secrets -l app.kubernetes.io/name=kubeton-prometheus,app.kubernetes.io/managed-by=kubeton' "$test_dir/prometheus-failure.log"
grep -Fq close-prometheus "$test_dir/prometheus-failure.log"
grep -Fq -- '--cascade=foreground --wait=true --timeout=60s' "$test_dir/prometheus-failure.log"
grep -Fq -- '-n old-metrics delete deployments.apps -l app.kubernetes.io/name=vmauth,app.kubernetes.io/instance=old-fleet' "$test_dir/vm-custom.log"
grep -Fq -- '-n old-operator delete deployments.apps -l app.kubernetes.io/name=victoria-metrics-operator' "$test_dir/vm-custom.log"
grep -Fq 'delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-metrics,app.kubernetes.io/managed-by=kubeton' "$test_dir/vm-custom.log"
grep -Fq -- '-n old-operator delete serviceaccounts -l app.kubernetes.io/name=vm-operator' "$test_dir/vm-custom.log"
grep -Fq -- '-n old-operator delete role vm-leader-election-role' "$test_dir/vm-custom.log"
grep -Fq 'delete clusterrole vm-operator' "$test_dir/vm-custom.log"
grep -Fq -- '-n old-operator delete networkpolicy vm-allow-metrics-traffic' "$test_dir/vm-policies.log"
grep -Fq -- '-n old-operator delete networkpolicy vm-allow-webhook-traffic' "$test_dir/vm-policies.log"
if grep -Eq 'delete networkpolicy vm-allow-metrics-traffic|delete namespace old-operator' "$test_dir/vm-external-policy.log"; then
  echo 'cleanup deleted a policy with different ownership or its namespace' >&2; exit 1
fi
if grep -Fq 'delete namespace old-operator' "$test_dir/vm-external-state-cm.log"; then
  echo 'cleanup ignored an externally managed metrics ConfigMap' >&2; exit 1
fi
grep -Fq 'unverified VictoriaMetrics operator remains at vm/vm-operator' "$test_dir/vm-orphan-unknown.log.error"
grep -Fq cleanup-logs "$test_dir/vm-orphan-unknown.log"
grep -Fq 'delete vmservicescrapes.operator.victoriametrics.com' "$test_dir/vm-orphan-unknown.log"
for scenario in vm-orphan-unknown vm-untracked-shared vm-untracked-other-operator; do
  if grep -Eq -- '-n vm delete|delete clusterrole|delete customresourcedefinition' "$test_dir/$scenario.log"; then
    echo 'cleanup deleted an operator without a kubeton ownership record' >&2; exit 1
  fi
done
grep -Fq -- '-n vm delete deployments.apps -l app.kubernetes.io/name=victoria-metrics-operator' "$test_dir/vm-no-ledger.log"
grep -Fq 'delete namespace old-metrics' "$test_dir/vm-empty-namespace.log"
if grep -Fq 'delete namespace old-metrics' "$test_dir/vm-shared-namespace.log"; then
  echo 'cleanup deleted a namespace containing unrelated credentials' >&2; exit 1
fi
if grep -Eq 'delete (clusterrole|customresourcedefinition)' "$test_dir/vm-other-operator.log"; then
  echo 'cleanup removed cluster resources used by another operator' >&2; exit 1
fi
ledger_line="$(grep -n '^record-storage-ledger$' "$test_dir/vm-pvc.log" | cut -d: -f1)"
cr_line="$(grep -n 'delete vmsingles.operator.victoriametrics.com' "$test_dir/vm-pvc.log" | head -n1 | cut -d: -f1)"
test "$ledger_line" -lt "$cr_line"
grep -Fq delete-recorded-vm-pvc "$test_dir/vm-pvc.log"
grep -Fq $'delete-recorded-vm-pvc old-wallets\tcustom-main-wallet-keybundle' "$test_dir/wallet-custom.log"
if grep -Fq 'delete configmap -A -l app.kubernetes.io/name=kubeton-victoria-metrics,' "$test_dir/vm-failure.log"; then
  echo 'failed VM cleanup deleted its state ledger' >&2; exit 1
fi
grep -Fq 'app.kubernetes.io/name!=kubeton-victoria-metrics' "$test_dir/vm-failure.log"
if grep -Eq 'delete (persistentvolumeclaims|clusterrole|customresourcedefinition)|old-operator delete' "$test_dir/vm-shared.log"; then
  echo 'shared VM infrastructure was selected for deletion' >&2; exit 1
fi
if grep -Fq 'delete persistentvolumeclaims' "$test_dir/vm-failure.log"; then
  echo 'generic sweep bypassed the PVC backing-storage ledger' >&2; exit 1
fi
if grep -Eq '(^| )delete ' "$test_dir/sweep-failure.log"; then
  echo 'cleanup mutated resources after discovery failed' >&2; exit 1
fi
for scenario in vm-invalid-state vm-inventory-denied prometheus-discovery-empty; do
  if grep -Eq '(^| )delete ' "$test_dir/$scenario.log"; then
    echo 'cleanup mutated resources without usable installation state' >&2; exit 1
  fi
done
echo 'kubeton uninstall observability checks: PASS'
