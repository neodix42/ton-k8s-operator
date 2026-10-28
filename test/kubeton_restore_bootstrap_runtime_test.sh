#!/usr/bin/env bash
set -euo pipefail

# Exercise the published controller's real argument parser, pinned dump cache,
# plzip/tar extraction and ownership repair with synthetic files. The repository
# and image are read-only; all fixtures stay on tmpfs and networking is disabled.
if [[ "${KUBETON_RESTORE_RUNTIME_TEST_CONTAINER:-}" != 1 ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  image="${MYTONCTRL_RUNTIME_TEST_IMAGE:-ghcr.io/neodix42/mytonctrl:v1.0.5}"
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required for test-restore-bootstrap-runtime.' >&2; exit 1; }
  exec docker run --rm --network none --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=64m \
    --tmpfs /var/ton-work:rw,nosuid,nodev,size=64m \
    --tmpfs /var/ton-key-bundle:rw,nosuid,nodev,size=16m \
    --mount "type=bind,source=${repo_root},target=/repo,readonly" \
    --env KUBETON_RESTORE_RUNTIME_TEST_CONTAINER=1 \
    --entrypoint bash "$image" /repo/test/kubeton_restore_bootstrap_runtime_test.sh
fi

/opt/mytonctrl/venv/bin/python - <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tarfile

work = Path("/var/ton-work")
database = work / "db"
controller = work / "controller"
cache = work / "dump-cache"
request = Path("/var/ton-key-bundle/.restore-node-bootstrap.json")
helper = "/repo/charts/ton-k8s-operator/fleet.py"
identity = {
    "MTC_USER": "root", "BIN_DIR": "/usr/bin", "SRC_DIR": "/usr/src", "TON_WORK_DIR": str(work),
}
fixtures = {
    "controller/initialized.json": json.dumps(identity).encode(),
    "controller/node-initialized.json": b'{"version":1}',
    "controller/installer-progress.json": b'{"version":1,"completed":["controller_settings","node_settings","mode"]}',
    "controller/mytoncore/mytoncore.db": b'{"validatorConsole":{"addr":"127.0.0.1:30002"}}',
    "controller/mytoncore/wallets/validator_wallet_001.pk": b"synthetic-wallet-secret",
    "controller/mytoncore/wallets/validator_wallet_001.addr": b"synthetic-wallet-address",
    "controller/services/validator.service": b"[Service]\nUser=validator\nExecStart=/usr/bin/ton/validator-engine/validator-engine --custom-retained-argument 42\n",
    "controller/services/mytoncore.service": b"[Service]\nExecStart=/opt/mytonctrl/venv/bin/python -m mytoncore\n",
    "db/config.json": b'{"addrs":[{"ip":123456789,"port":30001}],"control":[],"liteservers":[]}',
    "db/keyring/adnl-identity": b"synthetic-original-adnl-secret",
    "db/keys/private": b"synthetic-original-node-secret",
    "db/nodekeys/private": b"synthetic-original-nodekeys-secret",
    "keys/client": b"synthetic-original-console-secret",
}


def reset(testnet=False):
    for root in (work, request.parent):
        for path in root.iterdir():
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    for relative, payload in fixtures.items():
        target = work / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
    network = "gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=" if testnet else "synthetic-mainnet-zero-state"
    (controller / "global.config.json").write_text(json.dumps({"validator": {"zero_state": {"root_hash": network}}}))


def write_request(args):
    request.write_text(json.dumps({"version": 1, "args": args}))


def seed_cache(testnet=False, broken_checksum=False):
    cache.mkdir()
    archive = cache / "fixture.tar.lz"
    tar = Path("/tmp/restore-fixture.tar")
    # Donor identities deliberately differ. Real container extraction must
    # exclude them while importing the blockchain database payload.
    contents = {
        "config.json": b"donor-config",
        "keyring/adnl-identity": b"donor-adnl-secret",
        "keys/private": b"donor-node-secret",
        "nodekeys/private": b"donor-nodekeys-secret",
        "celldb/fixture": b"synthetic-blockchain-data",
    }
    with tarfile.open(tar, "w") as target:
        for relative, payload in contents.items():
            member = tarfile.TarInfo(relative)
            member.size = len(payload)
            target.addfile(member, io.BytesIO(payload))
    with archive.open("wb") as stream:
        subprocess.run(["plzip", "-c", str(tar)], stdout=stream, check=True)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    state = {
        "version": 1, "dump_name": "latest_testnet" if testnet else "latest",
        "archive_url": "https://dump.ton.org/dumps/fixture.tar.lz", "archive_name": archive.name,
        "sha256": "0" * 64 if broken_checksum else checksum,
        "archive_size": archive.stat().st_size, "disk_size": 10240,
        "dump_dir": str(database), "phase": "verified",
    }
    (cache / "dump-state.json").write_text(json.dumps(state))
    return archive, checksum


def run_helper(expect_success=True, **options):
    env = dict(os.environ, DUMP="false", DUMP_EXTRACT_THREADS="1", MYTONCTRL_ARGS="")
    env.update(options)
    result = subprocess.run([sys.executable, helper, "restore-bootstrap"], env=env, capture_output=True, text=True)
    if (result.returncode == 0) != expect_success:
        raise AssertionError(f"unexpected helper status {result.returncode}:\n{result.stdout}\n{result.stderr}")
    return result


def assert_preserved():
    for relative, payload in fixtures.items():
        assert (work / relative).read_bytes() == payload, f"restored identity/settings changed: {relative}"


# Literal -d takes precedence over DUMP=false, just as in the main entrypoint.
reset()
archive, checksum = seed_cache()
write_request(["-m", "validator", "-n", "mainnet", "-d"])
run_helper()
assert not request.exists(), "successful import did not acknowledge recovery"
assert not archive.exists(), "completed archive was not reclaimed"
assert (database / "celldb/fixture").read_bytes() == b"synthetic-blockchain-data"
assert (database / ".mytonctrl-dump.json").is_file()
owner = pwd.getpwnam("validator")
assert (database / "celldb/fixture").stat().st_uid == owner.pw_uid
assert (database / "celldb/fixture").stat().st_gid == owner.pw_gid
assert_preserved()

# Re-running an acknowledged init is a no-op. Also simulate a restart after
# extraction but before request acknowledgement: pinned completion avoids any
# repeated extraction over a database which has subsequently advanced.
(database / "celldb/fixture").write_bytes(b"advanced-blockchain-data")
run_helper()
write_request(["-d"])
run_helper()
assert not request.exists()
assert (database / "celldb/fixture").read_bytes() == b"advanced-blockchain-data"
assert_preserved()
print("PASS: real dump import, identity retention, ownership repair and completed-import resume")

# An existing node without -d must not acquire the flag during recovery.
reset()
write_request(["-m", "validator", "-n", "mainnet"])
run_helper()
assert not request.exists() and not cache.exists()
assert not (database / "celldb").exists()
assert_preserved()
print("PASS: no-dump installation remains unchanged")

# MYTONCTRL_ARGS remains effective, and the actual restored global config
# determines which dump is used rather than an unrelated network default.
reset(testnet=True)
seed_cache(testnet=True)
write_request([])
run_helper(MYTONCTRL_ARGS="-m validator -n testnet -d")
assert json.loads((database / ".mytonctrl-dump.json").read_text())["dump_name"] == "latest_testnet"
assert_preserved()
print("PASS: environment installation arguments and restored testnet configuration")

# A corrupt cached archive fails before network access. Preserve its bytes and
# durable request for inspection/retry, then prove a repaired checksum resumes.
reset()
archive, checksum = seed_cache(broken_checksum=True)
payload = archive.read_bytes()
write_request(["-d"])
run_helper(expect_success=False)
assert request.is_file() and archive.read_bytes() == payload
assert not (database / "celldb").exists()
assert_preserved()
state = json.loads((cache / "dump-state.json").read_text())
state["sha256"] = checksum
(cache / "dump-state.json").write_text(json.dumps(state))
run_helper()
assert not request.exists() and not archive.exists()
assert (database / "celldb/fixture").read_bytes() == b"synthetic-blockchain-data"
assert_preserved()
print("PASS: failed import preserves request/cache and resumes after repair")
PY
