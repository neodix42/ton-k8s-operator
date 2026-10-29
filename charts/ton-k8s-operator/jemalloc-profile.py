"""Run the existing MyTonCtrl entrypoint with opt-in persistent jemalloc profiles.

No preload, debugger attachment, heap contents or private environment is saved.
The same script is embedded into the operator, so no new runtime image is needed.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid


PROFILE_ROOT = Path("/var/ton-work/diagnostics/jemalloc")
POLL_SECONDS = 10


def log(message):
    print(f"[jemalloc] {message}", flush=True)


def configuration(prefix, sample_log2=19, interval_log2=34, final=False):
    return (f"prof:true,prof_active:true,prof_accum:false,lg_prof_sample:{sample_log2},"
            f"lg_prof_interval:{interval_log2},prof_gdump:false,"
            f"prof_final:{str(final).lower()},prof_prefix:{prefix}")


def probe(binary):
    """Check the actual validator and runtime library, rather than assuming prof support."""
    with tempfile.TemporaryDirectory(prefix="jemalloc-probe-") as temporary:
        prefix = Path(temporary) / "validator"
        env = dict(os.environ, MALLOC_CONF=configuration(prefix, final=True))
        result = subprocess.run([str(binary), "--version"], env=env,
                                capture_output=True, timeout=30, check=False)
        profiles = list(Path(temporary).glob("validator.*.heap"))
        valid = False
        for path in profiles:
            with path.open("rb") as stream:
                valid = valid or stream.read(8) == b"heap_v2/"
        if result.returncode != 0 or not valid:
            raise RuntimeError("validator-engine did not produce a jemalloc profile during "
                               "the --version probe. Use a TON binary and runtime libjemalloc "
                               "built with profiling support, or disable debug.jemalloc.")


def private_directory(path):
    # Do not let a pre-existing symlink redirect diagnostics into key directories.
    for parent in reversed((path, *path.parents)):
        if parent.is_symlink():
            raise RuntimeError(f"Diagnostic directory cannot be a symlink: {parent}")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    if os.geteuid() == 0:
        # The supervisor is root, but validator.service drops to validator.
        # Its allocator must be able to create profiles without world access.
        account = pwd.getpwnam("validator")
        os.chown(path, account.pw_uid, account.pw_gid)


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
    temporary.replace(path)


def create_session(binary, root=PROFILE_ROOT):
    if root == PROFILE_ROOT:
        # With umask 077 the new diagnostics parent also needs validator
        # ownership. Leave ton-work and other pre-existing ancestors alone.
        private_directory(root.parent)
    private_directory(root)
    name = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex
    session = root / name
    private_directory(session)
    lock = (session / ".lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        # Keep the exact ELF for symbolization after image upgrades or restarts.
        target = session / "validator-engine"
        shutil.copyfile(binary, target)
        target.chmod(0o500)
        digest = hashlib.sha256()
        with target.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        image_ref = binary.parent.parent / "image-ref"
        write_json(session / "metadata.json", {
            "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "binarySHA256": digest.hexdigest(),
            "tonImage": image_ref.read_text().strip() if image_ref.is_file() else "unknown",
            "sampling": "Allocation stacks and sizes; no allocation contents. Not a core dump.",
        })
        return session, lock
    except BaseException:
        lock.close()
        shutil.rmtree(session)
        raise


def managed_sessions(root):
    for session in root.iterdir():
        # Only this helper's directories are eligible for retention cleanup.
        if (not session.is_symlink() and session.is_dir()
                and len(session.name) == 49 and session.name[16] == "-"
                and all(c in "0123456789abcdef" for c in session.name[17:])
                and (session / ".lock").is_file() and not (session / ".lock").is_symlink()):
            yield session


def prune_sessions(root, current, max_profiles):
    sessions = list(managed_sessions(root))
    profiles = [path for session in sessions for path in session.glob("validator.*.heap")
                if path.is_file() and not path.is_symlink()]
    profiles.sort(key=lambda path: (path.stat().st_mtime_ns, str(path)), reverse=True)
    for path in profiles[max_profiles:]:
        path.unlink(missing_ok=True)
    for session in sessions:
        if session == current or any(session.glob("validator.*.heap")):
            continue
        with (session / ".lock").open("r") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            shutil.rmtree(session)


def snapshot_memory(session):
    values = {"observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    # Namespace-relative cgroup mounts in ordinary Kubernetes v1/v2 containers.
    # Missing/hidden counters are recorded as unavailable, not as zero.
    for name, candidates in {
        "current": ("memory.current", "memory/memory.usage_in_bytes"),
        "limit": ("memory.max", "memory/memory.limit_in_bytes"),
        "events": ("memory.events", "memory/memory.failcnt"),
        "stat": ("memory.stat", "memory/memory.stat"),
    }.items():
        values[name] = "unavailable"
        for candidate in candidates:
            try:
                values[name] = (Path("/sys/fs/cgroup") / candidate).read_text().strip()
                break
            except OSError:
                pass
    write_json(session / "memory.json", values)


def run(command, sample_log2, interval_log2, max_profiles, root=PROFILE_ROOT, binary=None):
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if binary is None:
        binary = (Path(os.environ.get("TON_ARTIFACTS_DIR") or "/ton-artifacts")
                  / "current/bin/validator-engine").resolve(strict=True)
    probe(binary)
    session, lock = create_session(binary, root)
    child = None

    def forward(signum, _frame):
        if child is None:
            raise SystemExit(128 + signum)
        if child.poll() is None:
            child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    try:
        prune_sessions(root, session, max_profiles)
        snapshot_memory(session)
        env = dict(os.environ, MALLOC_CONF=configuration(session / "validator", sample_log2, interval_log2))
        log(f"Sampling enabled; profiles: {session}; retaining {max_profiles} heap files. "
            "OOM/SIGKILL cannot create a final profile.")
        child = subprocess.Popen(command, env=env)
        while True:
            try:
                rc = child.wait(timeout=POLL_SECONDS)
                break
            except subprocess.TimeoutExpired:
                try:
                    prune_sessions(root, session, max_profiles)
                    snapshot_memory(session)
                except OSError as error:
                    log(f"Diagnostic retention/cgroup snapshot failed: {error}")
        try:
            prune_sessions(root, session, max_profiles)
            snapshot_memory(session)
        except OSError as error:
            log(f"Final diagnostic retention/cgroup snapshot failed: {error}")
        return rc if rc >= 0 else 128 - rc
    finally:
        lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample-log2", type=int, choices=range(10, 31), default=19)
    parser.add_argument("--interval-log2", type=int, choices=range(20, 41), default=34)
    parser.add_argument("--max-profiles", type=int, choices=range(2, 101), default=8)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a child command is required")
    try:
        return run(command, args.sample_log2, args.interval_log2, args.max_profiles)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        log(f"Cannot start profiling: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
