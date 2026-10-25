#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
fail() { echo "test failure: $*" >&2; exit 1; }

test_recovery() (
  source "$kubeton"
  local fixture_mode="$1" work="$test_dir/$1" fixture_ns=vm fixture_stack=kubeton rc=0
  mkdir -p "$work"
  if [[ "$fixture_mode" == existing-* ]]; then
    fixture_ns=custom-auth
    fixture_stack=custom-stack
    printf kubeton >"$work/auth-owner"
    printf kubeton >"$work/user-owner"
    [[ "$fixture_mode" == existing-retry ]] || touch "$work/service"
  fi
  if [[ "$fixture_mode" == foreign-owner ]]; then
    printf someone-else >"$work/auth-owner"
  fi
  [[ "$fixture_mode" == missing-operator* ]] || touch "$work/crds"
  record() { printf '%s\n' "$*" >>"$work/events"; }
  unexpected() { record "UNEXPECTED $*"; return 91; }
  require_bin() { :; }
  run_with_timeout() { shift; "$@"; }
  ensure_namespace() { record "namespace $1"; }
  ensure_victoria_metrics_operator() {
    record operator
    [[ "$fixture_mode" != missing-operator-failure ]] || return 1
    touch "$work/crds"
    printf 'v1\thttps://example.invalid/operator.yaml\n'
  }
  ensure_victoria_metrics_port_forward() {
    [[ "$*" == "$fixture_ns vmauth-$fixture_stack 8427 18427 0.0.0.0" ]] || unexpected "forward $*"
    record forward
    printf '%s\t%s\t8427\t1234\t/tmp/synthetic.log\n' "$fixture_ns" "vmauth-$fixture_stack"
  }
  kubectl() {
    local kube_ns='' verb resource name owner payload
    if [[ "${1:-}" == -n ]]; then kube_ns="$2"; shift 2; fi
    verb="${1:-}" resource="${2:-}" name="${3:-}"
    if [[ "$verb/$resource" == get/services ]]; then
      if [[ "$*" == *app.kubernetes.io/name=vmauth* ]]; then
        [[ ! -e "$work/service" ]] || printf '%s\t%s\n' "$fixture_ns" "$fixture_stack"
      elif [[ "$fixture_mode" == discovery-failure ]]; then
        return 1
      elif [[ "$fixture_mode" != missing-backend ]]; then
        printf 'custom-logs\trunning-backend\t19428\n'
      fi
      return 0
    fi
    if [[ "$verb/$resource" == get/configmaps ]]; then
      # A custom stack can also survive as saved state while its gateway
      # Service is being recreated. The state is deliberately absent otherwise.
      [[ "${work##*/}" != existing-retry ]] || printf '%s\t%s\n' "$fixture_ns" "$fixture_stack"
      return 0
    fi
    if [[ "$verb/$resource" == get/crd ]]; then
      [[ "$fixture_mode" != crd-denied ]] || return 1
      [[ ! -e "$work/crds" ]] || printf 'customresourcedefinition/vmauths.operator.victoriametrics.com\ncustomresourcedefinition/vmusers.operator.victoriametrics.com\n'
      return 0
    fi
    [[ "$kube_ns" == "$fixture_ns" || "$kube_ns" == custom-logs ]] || unexpected "$kube_ns $*"
    case "$verb/$resource" in
      get/vmauth|get/vmuser)
        [[ "$name" == "$fixture_stack" ]] || unexpected "$*"
        if [[ "$*" == *metadata.labels* ]]; then
          [[ "$fixture_mode" != owner-denied ]] || return 1
          if [[ "$resource" == vmauth ]]; then owner="$work/auth-owner"; else owner="$work/user-owner"; fi
          if [[ -e "$owner" ]]; then
            [[ "$*" != *metadata.name* ]] || printf '%s\t' "$fixture_stack"
            cat "$owner"
          fi
        elif [[ "$*" == *'range .spec.targetRefs'* ]]; then
          printf '\t/api/v1/.* /vmui.*\n'
          [[ ! -e "$work/route" ]] || printf 'http://running-backend.custom-logs.svc:19428\t/select/.*\n'
        elif [[ "$*" == *'{.spec.targetRefs}'* ]]; then
          if [[ "$fixture_mode" == existing-empty ]]; then
            printf null
          else
            printf '[{"crd":{"kind":"VMSingle","name":"custom-stack"},"paths":["/api/v1/.*","/vmui.*"]}]'
          fi
        else
          unexpected "$*"
        fi
        ;;
      get/service)
        [[ "$name" == "vmauth-$fixture_stack" && -e "$work/service" ]] || return 1
        printf 18427
        ;;
      get/secret)
        [[ "$name" == "vmuser-$fixture_stack" ]] || unexpected "$*"
        [[ "$fixture_mode" != credentials-failure ]] || return 1
        if [[ "$*" == *data.username* ]]; then
          printf synthetic-user | base64
        elif [[ "$*" == *data.password* ]]; then
          printf synthetic-password | base64
        fi
        ;;
      get/networkpolicy)
        [[ "$kube_ns/$name" == custom-logs/running-backend-ingress ]] || unexpected "$*"
        [[ "$fixture_mode" != policy-denied ]] || return 1
        [[ "$fixture_mode" == unprotected ]] || printf '{"matchLabels":{"app":"server","app.kubernetes.io/instance":"old-logs"}}'
        ;;
      apply/-f)
        payload="$(cat)"
        [[ "$fixture_mode" != apply-failure ]] || return 1
        if [[ "$payload" == *'kind: VMAuth'* ]]; then
          record auth-created
          printf '%s\n' "$payload" >"$work/auth.yaml"
          printf kubeton >"$work/auth-owner"
        elif [[ "$payload" == *'kind: VMUser'* ]]; then
          record user-created
          printf '%s\n' "$payload" >"$work/user.yaml"
          printf kubeton >"$work/user-owner"
          touch "$work/route"
        elif [[ "$payload" == *'kind: NetworkPolicy'* ]]; then
          record policy
          printf '%s\n' "$payload" >"$work/policy.yaml"
        else
          unexpected "apply $payload"
        fi
        ;;
      patch/vmuser)
        [[ "$fixture_mode" != existing-patch-failure ]] || return 1
        [[ "$name" == "$fixture_stack" && "$4" == --type=json && "$5" == -p ]] || unexpected "$*"
        printf '%s\n' "$6" >>"$work/patch.jsonl"
        record route-patched
        touch "$work/route"
        ;;
      wait/*)
        record wait
        [[ "$fixture_mode" != wait-failure && "$fixture_mode" != existing-retry ]] || return 1
        ;;
      rollout/status)
        record ready
        [[ "$fixture_mode" != rollout-failure ]] || return 1
        touch "$work/service"
        ;;
      *) unexpected "$kube_ns $*" ;;
    esac
  }

  run_logs expose --public-host logs.example.com >"$work/output" 2>&1 || rc=$?
  if [[ "$fixture_mode" == existing-retry ]]; then
    [[ "$rc" != 0 ]] || fail 'gateway readiness failure was ignored'
    # Retry after a failed readiness wait, still without a gateway Service.
    [[ "$(grep -c route-patched "$work/events")" == 1 ]] || fail 'initial route not added'
    fixture_mode=existing-ready
    rc=0
    run_logs expose --public-host logs.example.com >>"$work/output" 2>&1 || rc=$?
    [[ "$(grep -c route-patched "$work/events")" == 1 ]] || fail 'retry duplicated the logs route'
  fi
  case "$fixture_mode" in
    backend-only|missing-operator|unprotected|existing-ready|existing-empty)
      [[ "$rc" == 0 ]] || { cat "$work/output" >&2; fail "$fixture_mode recovery failed"; }
      grep -Fq 'now exposed externally: http://logs.example.com:8427/select/vmui/' "$work/output" || fail 'dashboard URL missing'
      grep -Fq "Credentials Secret: $fixture_ns/vmuser-$fixture_stack" "$work/output" || fail 'credentials reference missing'
      grep -q '^forward$' "$work/events" || fail 'gateway was not forwarded'
      if [[ "$fixture_mode" == existing-* ]]; then
        [[ ! -e "$work/auth.yaml" && ! -e "$work/user.yaml" ]] || fail 'existing auth was overwritten'
      else
        grep -Fq 'userSelector:' "$work/auth.yaml" || fail 'new gateway must select managed users in its namespace'
        ! grep -Fq 'selectAllByDefault: true' "$work/auth.yaml" || fail 'new gateway selected unrelated cluster users'
        grep -Fq 'generatePassword: true' "$work/user.yaml" || fail 'new user needs automatic credentials'
        grep -Fq 'http://running-backend.custom-logs.svc:19428' "$work/user.yaml" || fail 'actual backend URL lost'
      fi
      if [[ "$fixture_mode" == unprotected ]]; then
        [[ ! -e "$work/policy.yaml" ]] || fail 'recovery isolated an unprotected collector'
      else
        grep -Fq "kubernetes.io/metadata.name: $fixture_ns" "$work/policy.yaml" || fail 'wrong gateway namespace in policy'
        grep -Fq "app.kubernetes.io/instance: $fixture_stack" "$work/policy.yaml" || fail 'wrong gateway instance in policy'
        grep -Fq '"app.kubernetes.io/instance":"old-logs"' "$work/policy.yaml" || fail 'original backend selector lost'
      fi
      ;;
    *)
      [[ "$rc" != 0 ]] || fail "$fixture_mode was ignored"
      ! grep -q 'now exposed externally' "$work/output" || fail 'failed setup claimed exposure'
      ! grep -q '^forward$' "$work/events" 2>/dev/null || fail 'failed setup started a public forward'
      ;;
  esac
  ! grep -q UNEXPECTED "$work/events" 2>/dev/null || { cat "$work/events" >&2; fail 'unexpected cluster mutation/read'; }
  ! grep -Eq 'synthetic-password|c3ludGhldGljLXBhc3N3b3Jk' "$work/output" || fail 'credentials leaked into output'
  if [[ "$fixture_mode" == missing-operator* ]]; then
    grep -q '^operator$' "$work/events" || fail 'missing operator was not installed'
  else
    ! grep -q '^operator$' "$work/events" 2>/dev/null || fail 'existing operator was unnecessarily reinstalled'
  fi
  if [[ -e "$work/patch.jsonl" ]]; then
    python3 - "$work/patch.jsonl" <<'PY'
import json, pathlib, sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    patch, = json.loads(line)
    assert patch["op"] == "add"
    assert patch["path"] in ("/spec/targetRefs/-", "/spec/targetRefs")
    route = patch["value"] if isinstance(patch["value"], dict) else patch["value"][0]
    assert route == {"static": {"url": "http://running-backend.custom-logs.svc:19428"}, "paths": ["/select/.*"]}
PY
  fi
)

for fixture_mode in backend-only missing-operator unprotected existing-ready existing-empty existing-retry \
  discovery-failure missing-backend missing-operator-failure crd-denied owner-denied foreign-owner apply-failure \
  existing-patch-failure policy-denied wait-failure rollout-failure credentials-failure; do
  test_recovery "$fixture_mode"
done
echo 'kubeton logs existing-cluster recovery checks: PASS'
