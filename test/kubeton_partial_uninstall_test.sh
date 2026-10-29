#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

for mode in absent deployed failed-upgrade helm-read-error crd-read-error crd-delete-error scale-error wait-error; do
  bash -euo pipefail -c '
    source "$1"
    mode="$2" events="$3"
    : >"$events"
    rows=()
    run_stop_without_backup() {
      echo helm-upgrade >>"$events"
      [[ "$mode" != failed-upgrade ]]
    }
    clear_stopped_metadata_for_statefulset_rows() { :; }
    scale_statefulset_rows_to_zero() { echo scale >>"$events"; [[ "$mode" != scale-error ]]; }
    wait_statefulset_rows_pods_gone() { echo wait >>"$events"; [[ "$mode" != wait-error ]]; }
    helm() {
      [[ "$*" == "list -n ton-k8s-operator-system --deployed --short --filter ^ton-k8s-operator$" ]] || return 91
      [[ "$mode" != helm-read-error ]] || return 1
      case "$mode" in deployed|failed-upgrade) echo ton-k8s-operator ;; esac
    }
    kubectl() {
      echo "$*" >>"$events"
      case "$*" in
        "get crd tonnodes.ton.ton.org --ignore-not-found -o name")
          [[ "$mode" != crd-read-error ]] || return 1
          case "$mode" in deployed|failed-upgrade|crd-delete-error) echo customresourcedefinition/tonnodes.ton.ton.org ;; esac
          ;;
        "delete tonnodes.ton.ton.org --all -A --ignore-not-found") [[ "$mode" != crd-delete-error ]] ;;
        *) return 92 ;;
      esac
    }
    rc=0
    stop_ton_for_destructive_cleanup rows || rc=$?
    case "$mode" in
      absent|deployed|failed-upgrade) [[ "$rc" == 0 ]] ;;
      *) [[ "$rc" != 0 ]] ;;
    esac
    case "$mode" in
      deployed|failed-upgrade) grep -Fxq helm-upgrade "$events" ;;
      *) ! grep -Fxq helm-upgrade "$events" ;;
    esac
    if [[ "$mode" == absent ]]; then
      ! grep -Fq "delete tonnodes" "$events"
    fi
    grep -Fxq scale "$events"
    grep -Fxq wait "$events"
  ' _ "$repo_root/charts/ton-k8s-operator/kubeton" "$mode" "$test_dir/$mode.events" \
    >"$test_dir/$mode.log" 2>&1 || { cat "$test_dir/$mode.log" >&2; exit 1; }
done

# An API read failure must not be mistaken for zero live Pods.
bash -euo pipefail -c '
  source "$1"
  kubectl() { return 1; }
  if wait_statefulset_pods_gone default tonnode; then
    echo "Pod read failure was treated as successful termination" >&2
    exit 1
  fi
' _ "$repo_root/charts/ton-k8s-operator/kubeton" >"$test_dir/pod-read.log" 2>&1

echo 'kubeton partial-uninstall shutdown checks: PASS'
