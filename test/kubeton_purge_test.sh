#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

for mode in success delete-error get-error both-errors still-present uninstall-error; do
  status=0
  bash -euo pipefail -c '
    source "$1"
    mode="$2"
    require_bin() { :; }
    confirm_or_exit() { :; }
    run_uninstall_core() { [[ "$mode" != uninstall-error ]]; }
    verify_uninstall_leftovers() { return 1; }
    kubectl() {
      case "$1 $2" in
        "delete crd")
          [[ "$3" == tonnodes.ton.ton.org && "$*" == *"--timeout="* ]] || return 99
          [[ "$mode" != delete-error && "$mode" != both-errors ]]
          ;;
        "get crd")
          [[ "$3" == tonnodes.ton.ton.org && "$*" == *"--ignore-not-found"* ]] || return 98
          if [[ "$mode" == get-error || "$mode" == both-errors ]]; then return 1; fi
          if [[ "$mode" == still-present ]]; then printf "customresourcedefinition/tonnodes.ton.ton.org\n"; fi
          return 0
          ;;
        *) printf "unexpected command: %s\n" "$*" >&2; return 97 ;;
      esac
    }
    run_purge
  ' _ "$repo_root/charts/ton-k8s-operator/kubeton" "$mode" >"$temporary/$mode.log" 2>&1 || status=$?
  if [[ "$mode" == success ]]; then
    [[ "$status" == 0 ]] && grep -Fq '[purge] Completed.' "$temporary/$mode.log" || {
      cat "$temporary/$mode.log" >&2; exit 1;
    }
  else
    if [[ "$status" == 0 ]] || grep -Fq '[purge] Completed.' "$temporary/$mode.log"; then
      echo "purge falsely succeeded for $mode" >&2; cat "$temporary/$mode.log" >&2; exit 1
    fi
  fi
done

echo 'kubeton purge verification checks: PASS (6 scenarios)'
