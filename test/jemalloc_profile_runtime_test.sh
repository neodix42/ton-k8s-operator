#!/usr/bin/env bash
set -euo pipefail

# Optional integration: use the real published validator with the deployed
# MyTonCtrl allocator. No cluster, network, host PID namespace or privilege is used.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ton_image="${TON_RUNTIME_TEST_IMAGE:-ghcr.io/ton-blockchain/ton:v2026.10-amd64}"
controller_image="${MYTONCTRL_RUNTIME_TEST_IMAGE:-ghcr.io/neodix42/mytonctrl:v1.0.5}"
command -v docker >/dev/null 2>&1 || { echo 'Docker is required for the jemalloc runtime test.' >&2; exit 1; }
for image in "$ton_image" "$controller_image"; do
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "Cache the runtime test image first: docker pull $image" >&2
    exit 1
  }
done

test_root="$(mktemp -d /tmp/kubeton-jemalloc-runtime.XXXXXX)"
source_container=''
cleanup() {
  if [[ -n "$source_container" ]]; then
    docker rm -f "$source_container" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
mkdir -p "$test_root/artifacts/bin" "$test_root/diagnostics"
source_container="$(docker create --network none --entrypoint /bin/true "$ton_image")"
docker cp "$source_container:/usr/local/bin/validator-engine" "$test_root/artifacts/bin/validator-engine"
docker rm "$source_container" >/dev/null
source_container=''
printf '%s\n' "$ton_image" >"$test_root/artifacts/image-ref"

docker run --rm --interactive --network none --read-only \
  --user 0:0 --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,source=${repo_root},target=/repo,readonly" \
  --mount "type=bind,source=${test_root}/artifacts,target=/artifacts,readonly" \
  --mount "type=bind,source=${test_root}/diagnostics,target=/var/ton-work/diagnostics" \
  --env "HOST_TEST_UID=$(id -u)" --env "HOST_TEST_GID=$(id -g)" \
  --env PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint /opt/mytonctrl/venv/bin/python "$controller_image" - <<'PY'
import atexit
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys

spec = importlib.util.spec_from_file_location('profile', '/repo/charts/ton-k8s-operator/jemalloc-profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
binary = Path('/artifacts/bin/validator-engine')
root = profile.PROFILE_ROOT
os.umask(0o077)

def restore_test_ownership():
    uid, gid = int(os.environ['HOST_TEST_UID']), int(os.environ['HOST_TEST_GID'])
    for directory, directories, files in os.walk(root.parent, topdown=False):
        for name in directories + files:
            os.chown(Path(directory) / name, uid, gid)
        os.chown(directory, uid, gid)

atexit.register(restore_test_ownership)
validator = pwd.getpwnam('validator')

def service_command(argv, name):
    service = Path('/tmp') / f'{name}.json'
    service.write_text(json.dumps({'user': 'validator', 'argv': argv}))
    return [sys.executable, '/usr/local/lib/mytonctrl/run-service.py', str(service)]

# This is the actual binary under the actual controller runtime library, not a
# mocked mallctl implementation or a separately compiled test allocator.
profile.probe(binary)
session, lock = profile.create_session(binary, root)
try:
    assert root.parent.stat().st_uid == validator.pw_uid
    assert root.stat().st_uid == validator.pw_uid
    assert session.stat().st_uid == validator.pw_uid
    env = dict(os.environ, MALLOC_CONF=profile.configuration(session / 'validator', final=True))
    # Match production: the root entrypoint creates diagnostics, then the
    # service launcher drops privileges before executing validator-engine.
    subprocess.run(service_command([str(binary), '--version'], 'version-service'), env=env, check=True)
    real_profiles = list(session.glob('validator.*.heap'))
    assert real_profiles, 'actual validator did not write a heap profile'
    assert all(path.read_bytes().startswith(b'heap_v2/') for path in real_profiles)
    before_kill = {str(path): path.read_bytes() for path in real_profiles}
finally:
    lock.close()

# Use a controlled allocation process with the same runtime jemalloc, then
# SIGKILL it. No validator node is started and no network is contacted.
child = r'''
import glob, os, signal
options = dict(part.split(':', 1) for part in os.environ['MALLOC_CONF'].split(','))
allocations = [bytearray(1024 * 1024) for _ in range(32)]
profiles = glob.glob(options['prof_prefix'] + '.*.heap')
assert profiles, 'allocation-interval profiling produced no pre-kill profile'
os.kill(os.getpid(), signal.SIGKILL)
'''
rc = profile.run(service_command(['/usr/bin/env', 'LD_PRELOAD=libjemalloc.so.2',
                                  sys.executable, '-c', child], 'allocation-service'),
                 19, 20, 8, root, binary)
assert rc == 137, f'SIGKILL must propagate as 137, got {rc}'
profiles = list(root.glob('*/validator.*.heap'))
assert profiles, 'profiles disappeared after the child was killed'
assert len(profiles) <= 8, 'cross-session retention limit was not applied'
assert all(path.read_bytes().startswith(b'heap_v2/') for path in profiles)
for session in root.iterdir():
    if not session.is_dir():
        continue
    metadata = json.loads((session / 'metadata.json').read_text())
    exact_binary = (session / 'validator-engine').read_bytes()
    assert metadata['binarySHA256'] == hashlib.sha256(exact_binary).hexdigest()
    assert exact_binary == binary.read_bytes(), 'profile lost its exact executable'
    assert (session / 'memory.json').is_file() or str(session) in {str(Path(p).parent) for p in before_kill}
print('PASS: validator service UID, real heap profiles, exact executable, retention and pre-SIGKILL dumps')
PY
