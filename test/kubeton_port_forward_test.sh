#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
declare -a fixture_pids=()
cleanup() {
  local pid
  for pid in "${fixture_pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
  rm -rf "$test_dir"
}
trap cleanup EXIT
fail() { echo "test failure: $*" >&2; exit 1; }

# Preserve original argument boundaries and reject substring matches.
mkdir -p "$test_dir/proc/4242"
KUBETON_PROCESS_PROC_ROOT="$test_dir/proc"
set_fixture_args() { printf '%s\0' "$@" >"$test_dir/proc/4242/cmdline"; }
matches() { port_forward_process_matches 4242 vm vmauth-kubeton 8427 8427 "$1"; }
set_fixture_args /usr/local/bin/kubectl -n vm port-forward --address 127.0.0.1 svc/vmauth-kubeton 8427:8427
matches 127.0.0.1 || fail 'separated address did not match'
matches '' || fail 'endpoint identity did not allow an unspecified bind address'
if matches 0.0.0.0; then fail 'loopback forward matched public bind'; fi
set_fixture_args kubectl --namespace=vm port-forward --address=0.0.0.0 service/vmauth-kubeton 8427:8427
matches 0.0.0.0 || fail 'equal-form address/namespace did not match'
if matches 127.0.0.1; then fail 'public forward matched loopback bind'; fi
for fixture_case in namespace service local-port remote-port executable argument-boundary; do
  case "$fixture_case" in
    namespace) set_fixture_args kubectl -n vm-other port-forward --address 127.0.0.1 svc/vmauth-kubeton 8427:8427 ;;
    service) set_fixture_args kubectl -n vm port-forward --address 127.0.0.1 svc/vmauth-kubeton-other 8427:8427 ;;
    local-port) set_fixture_args kubectl -n vm port-forward --address 127.0.0.1 svc/vmauth-kubeton 18427:8427 ;;
    remote-port) set_fixture_args kubectl -n vm port-forward --address 127.0.0.1 svc/vmauth-kubeton 8427:84270 ;;
    executable) set_fixture_args bash -c 'kubectl -n vm port-forward --address 127.0.0.1 svc/vmauth-kubeton 8427:8427' ;;
    argument-boundary) set_fixture_args kubectl -n vm port-forward --address 127.0.0.1 'svc/vmauth-kubeton 8427:8427' ;;
  esac
  if matches 127.0.0.1; then fail "$fixture_case incorrectly matched a different endpoint"; fi
done

# Saved API-proxy processes need the same PID-reuse protection during teardown.
set_fixture_args kubectl proxy --disable-filter --address 127.0.0.1 --port 18427
kubectl_proxy_process_matches 4242 18427 || fail 'managed API proxy did not match'
if kubectl_proxy_process_matches 4242 18428; then fail 'API proxy matched another port'; fi
set_fixture_args bash -c 'kubectl proxy --address 127.0.0.1 --port 18427'
if kubectl_proxy_process_matches 4242 18427; then fail 'API proxy matched another executable'; fi

# Keep a conservative ps fallback for platforms without Linux /proc.
KUBETON_PROCESS_PROC_ROOT="$test_dir/no-proc"
ps() { printf '%s\n' '/usr/local/bin/kubectl --namespace vm port-forward --address=127.0.0.1 svc/vmauth-kubeton 8427:8427'; }
matches 127.0.0.1 || fail 'ps fallback did not match exact arguments'
if matches 0.0.0.0; then fail 'ps fallback ignored the address'; fi
unset -f ps
unset KUBETON_PROCESS_PROC_ROOT

# A synthetic kubectl uses a real socket and delays termination. Rebinding
# before it exits would fail, reproducing the native port-forward bind race.
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
exec -a kubectl python3 -c '
import os, signal, socket, sys, time
args = sys.argv[1:]
address = args[args.index("--address") + 1]
port = int(args[-1].split(":")[0])
listener = socket.socket()
listener.bind((address, port))
listener.listen()
with open(os.environ["KUBETON_TEST_FORWARD_EVENTS"], "a") as output:
    output.write("start %s %s\n" % (os.getpid(), address))
def stop(*_args):
    time.sleep(0.3)
    listener.close()
    with open(os.environ["KUBETON_TEST_FORWARD_EVENTS"], "a") as output:
        output.write("stop %s %s\n" % (os.getpid(), address))
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print("Forwarding from %s:%s" % (address, port), flush=True)
while True:
    signal.pause()
' "$@"
EOF
chmod +x "$test_dir/bin/kubectl"
export PATH="$test_dir/bin:$PATH"
export KUBETON_TEST_FORWARD_EVENTS="$test_dir/forward-events"
VICTORIA_METRICS_PORT_FORWARD_DIR="$test_dir/state"
VICTORIA_METRICS_PORT_FORWARD_WAIT_SECONDS=3
wait_victoria_metrics_http_ready() { return 0; }
test_port="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"

forward() {
  local row
  row="$(ensure_victoria_metrics_port_forward vm vmauth-kubeton "$test_port" 8427 "$1")" || fail "could not establish $1 forward"
  IFS=$'\t' read -r _ns _service _port current_pid _log <<<"$row"
  fixture_pids+=("$current_pid")
  port_forward_process_matches "$current_pid" vm vmauth-kubeton "$test_port" 8427 "$1" || fail 'native process identity did not match'
}
forward 127.0.0.1
first_pid="$current_pid"
forward 127.0.0.1
[[ "$current_pid" == "$first_pid" ]] || fail 'identical forward was not reused'
forward 0.0.0.0
public_pid="$current_pid"
[[ "$public_pid" != "$first_pid" ]] || fail 'promotion retained the loopback process'
forward 127.0.0.1
[[ "$current_pid" != "$public_pid" ]] || fail 'rollback retained the public process'
[[ "$(awk '{print $1 " " $3}' "$test_dir/forward-events")" == $'start 127.0.0.1\nstop 127.0.0.1\nstart 0.0.0.0\nstop 0.0.0.0\nstart 127.0.0.1' ]] \
  || fail 'replacement did not wait for the previous listener to stop'

# A stale PID file pointing to an unrelated live process must never kill it.
sleep 60 &
unrelated_pid="$!"
fixture_pids+=("$unrelated_pid")
mkdir -p "$test_dir/stale-state"
VICTORIA_METRICS_PORT_FORWARD_DIR="$test_dir/stale-state"
printf '%s\n' "$unrelated_pid" >"$VICTORIA_METRICS_PORT_FORWARD_DIR/vm__vmauth-kubeton__${test_port}.pid"
if ensure_victoria_metrics_port_forward vm vmauth-kubeton "$test_port" 8427 127.0.0.1 true >/dev/null; then
  fail 'a new listener unexpectedly acquired the already occupied port'
fi
kill -0 "$unrelated_pid" >/dev/null 2>&1 || fail 'stale PID handling killed an unrelated process'
printf '%s\n' "$unrelated_pid" >"$VICTORIA_METRICS_PORT_FORWARD_DIR/proxy-18427.pid"
cleanup_victoria_metrics_port_forwards
kill -0 "$unrelated_pid" >/dev/null 2>&1 || fail 'VM teardown killed a reused PID'
VICTORIA_LOGS_PORT_FORWARD_DIR="$test_dir/stale-log-state"
mkdir -p "$VICTORIA_LOGS_PORT_FORWARD_DIR"
printf '%s\n' "$unrelated_pid" >"$VICTORIA_LOGS_PORT_FORWARD_DIR/vm__vlogs__9428.pid"
printf '%s\n' "$unrelated_pid" >"$VICTORIA_LOGS_PORT_FORWARD_DIR/proxy-19428.pid"
cleanup_victoria_logs_port_forwards
kill -0 "$unrelated_pid" >/dev/null 2>&1 || fail 'VictoriaLogs teardown killed a reused PID'

echo 'kubeton port-forward tests passed'
