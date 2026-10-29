#!/usr/bin/env python3
"""Local, dependency-free manifest handling for kubeton fleet migration."""

import base64
import copy
import hashlib
import io
import ipaddress
import json
import re
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def safe_file(root, relative):
    path = Path(relative)
    require(not path.is_absolute() and ".." not in path.parts, "unsafe backup path")
    current = root
    for part in path.parts:
        current = current / part
        require(not current.is_symlink(), f"backup symlink is not allowed: {relative}")
    require(current.is_file(), f"missing backup file: {relative}")
    return current


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def validate_fleets(manifest):
    require(manifest.get("format") == "kubeton-fleet" and manifest.get("version") == 1,
            "unsupported fleet backup format/version")
    fleets = manifest.get("fleets")
    require(isinstance(fleets, list) and fleets, "backup contains no TON fleets")
    seen = set()
    for fleet in fleets:
        for field in ("namespace", "name"):
            value = fleet.get(field, "")
            require(isinstance(value, str) and len(value) <= 253 and
                    re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value),
                    f"invalid fleet {field}")
        identity = fleet["namespace"], fleet["name"]
        require(identity not in seen, "duplicate fleet")
        seen.add(identity)
        spec = fleet["spec"]
        replicas = spec.get("replicas", 1)
        require(type(replicas) is int and 0 < replicas <= 10000,
                "backup-fleet requires a running fleet with positive replicas")
        keys = spec.get("keyManagement", {})
        require(keys.get("enabled") and keys.get("provider", "vault") == "vault",
                "fleet migration currently requires Vault key management")
        require(not spec.get("configRef") and
                not any("valueFrom" in item for item in spec.get("env", [])),
                "external configRef/env valueFrom dependencies must be migrated separately; "
                "backup-fleet does not export them")
        for field, default in (("fileName", "keys.bundle.enc"),
                               ("metaFileName", "keys.bundle.meta")):
            value = keys.get("encryptedBundle", {}).get(field, default)
            require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value),
                    "bundle filenames must be simple filenames")


def entries(manifest):
    for fleet in manifest["fleets"]:
        bundle = fleet["spec"]["keyManagement"].get("encryptedBundle", {})
        for ordinal in range(fleet["spec"].get("replicas", 1)):
            yield (fleet["namespace"], fleet["name"], str(ordinal),
                   bundle.get("fileName", "keys.bundle.enc"),
                   bundle.get("metaFileName", "keys.bundle.meta"))


def load(root, verify=False):
    manifest = json.loads(safe_file(root, "fleet.json").read_text())
    validate_fleets(manifest)
    if verify:
        expected = {f"{ns}/{name}/{ordinal}/bundle/{filename}"
                    for ns, name, ordinal, enc, meta in entries(manifest)
                    for filename in (enc, meta)}
        require(set(manifest.get("files", {})) == expected, "incomplete fleet file inventory")
        for relative, checksum in manifest["files"].items():
            require(digest(safe_file(root, relative)) == checksum,
                    f"backup checksum failed: {relative}")
    return manifest


def recovery(root, selected):
    manifest = load(root, verify=True)
    lines = sys.stdin.read().splitlines()
    require(lines and lines[0] == "kubeton-fleet-v1\t" + digest(root / "fleet.json"),
            "recovery keys do not authenticate this fleet manifest")
    keys = {}
    for line in lines[1:]:
        identity, value = line.split("\t")
        require(identity not in keys, "duplicate recovery key")
        require(len(base64.b64decode(value, validate=True)) in (32, 48), "invalid recovery key")
        keys[identity] = value
    expected = {"/".join(entry[:3]) for entry in entries(manifest)}
    require(set(keys) == expected, "incomplete recovery keys")
    if selected:
        require(selected in keys, "replica recovery key is missing")
        print(keys[selected])


def prepare(root, work, data_class, bundle_class, secret, transit_key, selector):
    manifest = load(root, verify=True)
    target_selector = {}
    for pair in filter(None, selector.split(",")):
        key, value = pair.split("=", 1)
        require(key and value, "node selector must use key=value pairs")
        target_selector[key] = value
    for fleet in manifest["fleets"]:
        spec = copy.deepcopy(fleet["spec"])
        spec["replicas"] = 0
        spec["nodeSelector"] = target_selector
        spec.setdefault("network", {}).pop("publicIP", None)
        spec["env"] = [item for item in spec.get("env", []) if item["name"] != "PUBLIC_IP"]
        spec.setdefault("storage", {})["storageClassName"] = data_class
        keys = spec["keyManagement"]
        keys["provider"] = "vault"
        keys["vaultTransitKey"] = transit_key
        keys["credentialsSecretRef"] = {"name": secret}
        keys.setdefault("encryptedBundle", {})["storageClassName"] = bundle_class
        resource = {"apiVersion": "ton.ton.org/v1alpha1", "kind": "TonNode",
                    "metadata": {"namespace": fleet["namespace"], "name": fleet["name"]},
                    "spec": spec}
        write_json(work / f"{fleet['namespace']}--{fleet['name']}.json", resource)


def claims(sts):
    result = []
    for ordinal in range(int(sys.argv[3])):
        for template in sts["spec"]["volumeClaimTemplates"]:
            result.append({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                           "metadata": {"name": f"{template['metadata']['name']}-{sts['metadata']['name']}-{ordinal}",
                                        "namespace": sts["metadata"]["namespace"],
                                        "labels": template["metadata"].get("labels", {})},
                           "spec": template["spec"]})
    return {"apiVersion": "v1", "kind": "List", "items": result}


def helper(sts, pod_name, ordinal, session, tools_image=None):
    template = sts["spec"]["template"]["spec"]
    agent = next(item for item in template["containers"] if item["name"] == "key-backup")
    main = next(item for item in template["containers"] if item["name"] == "ton-node")
    labels = {"ton.ton.org/fleet-restore": session, "ton.ton.org/fleet-name": sts["metadata"]["name"]}
    mounts, volumes = [], []
    for claim in sts["spec"]["volumeClaimTemplates"]:
        name = claim["metadata"]["name"]
        volumes.append({"name": name, "persistentVolumeClaim": {
            "claimName": f"{name}-{sts['metadata']['name']}-{ordinal}"}})
        mounts.append({"name": name, "mountPath": "/bundle" if name == "keybundle" else f"/volumes/{name}"})
    volumes.append({"name": "recovery", "emptyDir": {"medium": "Memory"}})
    mounts.append({"name": "recovery", "mountPath": "/recovery"})
    volumes.append({"name": "scratch", "emptyDir": {"medium": "Memory"}})
    mounts.append({"name": "scratch", "mountPath": "/tmp"})
    container = {"name": "restore", "image": tools_image or agent["image"],
                 "command": ["sh", "-c", "sleep 86400"], "env": agent.get("env", []),
                 "envFrom": agent.get("envFrom", []), "volumeMounts": mounts,
                 "resources": main.get("resources", {}), "ports": main.get("ports", [])}
    return {"apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": pod_name, "namespace": sts["metadata"]["namespace"], "labels": labels},
            "spec": {"restartPolicy": "Never", "nodeSelector": template.get("nodeSelector", {}),
                     "affinity": {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
                         {"labelSelector": {"matchLabels": labels}, "topologyKey": "kubernetes.io/hostname"}]}},
                     "containers": [container], "volumes": volumes}}


def rebind(source, target, address, port):
    ip = ipaddress.IPv4Address(address)
    require(not ip.is_loopback and not ip.is_unspecified and not ip.is_multicast,
            "restore needs a routable node IPv4 address")
    ip_int = int(ip)
    if ip_int >= 2 ** 31:
        ip_int -= 2 ** 32
    changed = set()
    with tarfile.open(source, "r:gz") as old, tarfile.open(target, "w:gz") as new:
        for member in old:
            name = member.name.removeprefix("./")
            require(not name.startswith("/") and ".." not in Path(name).parts, "unsafe bundle member")
            require(member.isfile() or member.isdir(), "unsafe bundle member type")
            payload = old.extractfile(member) if member.isfile() else None
            if name == "tondb/config.json":
                config = json.load(payload)
                require(config.get("addrs"), "validator config has no advertised addresses")
                require(any("ip" in item for item in config["addrs"]),
                        "unsupported validator advertised address format")
                for item in config["addrs"]:
                    if "ip" in item:
                        item["ip"] = ip_int
                payload = io.BytesIO((json.dumps(config, indent=2) + "\n").encode())
                member.size = len(payload.getbuffer())
                changed.add(name)
            elif name == "controller/services/validator.service":
                text = payload.read().decode()
                text, count = re.subn(r"--ip(?:=|\s+)[^\s\"']+", f"--ip {ip}:{port}", text)
                require(count <= 1, "unsupported validator service: multiple --ip arguments")
                payload = io.BytesIO(text.encode())
                member.size = len(payload.getbuffer())
                changed.add(name)
            new.addfile(member, payload)
    require(changed == {"tondb/config.json", "controller/services/validator.service"},
            "bundle lacks current validator/controller state")


def restore_bootstrap():
    """Import a replacement node's dump without reinstalling its controller.

    Runs as the last init container, after key restore and before any node
    service. The request lives on the encrypted-bundle PVC so an interrupted
    import survives both container restarts and recreation of the Pod.
    """
    import fcntl
    import resource
    import subprocess
    from types import SimpleNamespace

    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    request = Path("/var/ton-key-bundle/.restore-node-bootstrap.json")
    if not request.exists():
        return
    value = json.loads(request.read_text())
    require(isinstance(value, dict) and type(value.get("version")) is int and
            value["version"] == 1 and isinstance(value.get("args"), list) and
            all(isinstance(arg, str) for arg in value["args"]),
            "invalid node recovery bootstrap request; request was preserved")
    # Use the same parser and precedence as the controller's entrypoint,
    # including MYTONCTRL_ARGS and literal environment options such as DUMP.
    sys.path.insert(0, "/usr/local/lib/mytonctrl")
    from mytonctrl_docker_args import installation_environment

    import os

    env = installation_environment(os.environ, value["args"])
    work = Path(env["TON_WORK_DIR"])
    require(work == Path("/var/ton-work"), "unsupported node recovery work directory")
    dump = env.get("DUMP", "false").lower()
    require(dump in ("true", "false", "1", "0", "yes", "no"), "DUMP must be true or false")
    state, database = work / "controller", work / "db"
    require((state / "initialized.json").is_file() and (database / "config.json").is_file(),
            "node identity must be restored before recovery bootstrap")
    with (state / ".container.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        if dump in ("true", "1", "yes"):
            from mytoninstaller.dump import cleanup_completed_dump, download_dump, get_dump_cache_dir

            require((state / "global.config.json").is_file(), "restored node global.config.json is missing")
            os.environ.update(env)
            paths = SimpleNamespace(ton_work_dir=str(work), ton_db_dir=str(database),
                                    global_config_path=str(state / "global.config.json"))

            class Logger:
                @staticmethod
                def add_log(message, level="info"):
                    print(f"[restore-keys] [{level}] {message}", flush=True)

            print("[restore-keys] Downloading/resuming the blockchain dump requested by the preserved installation arguments.", flush=True)
            require(download_dump(Logger(), SimpleNamespace(paths=paths)) is True,
                    "node recovery dump import failed; request and download cache were preserved for retry")
            # Extraction runs as root. Repair ownership before the restored
            # validator service opens the database as its unprivileged user.
            subprocess.run(["chown", "-R", "validator:validator", str(database)], check=True)
            cleanup_completed_dump(get_dump_cache_dir(str(work)), str(database))
            print("[restore-keys] Blockchain dump imported; restored wallet, ADNL keys and controller settings retained.", flush=True)
        else:
            print("[restore-keys] Preserved installation arguments do not request a dump; synchronizing normally.", flush=True)
        request.unlink()
        # Commit acknowledgement before allowing the normal entrypoint to run.
        directory = os.open(str(request.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def main():
    action = sys.argv[1]
    if action == "restore-bootstrap":
        restore_bootstrap()
        return
    if action == "rebind":
        rebind(*sys.argv[2:])
        return
    if action == "claims":
        print(json.dumps(claims(json.load(sys.stdin))))
        return
    if action == "helper":
        print(json.dumps(helper(json.load(sys.stdin), *sys.argv[2:])))
        return
    root = Path(sys.argv[2])
    if action == "capture":
        fleets = [{"namespace": item["metadata"]["namespace"], "name": item["metadata"]["name"],
                   "spec": item["spec"]} for item in json.load(sys.stdin)["items"]]
        manifest = {"format": "kubeton-fleet", "version": 1,
                    "createdAt": datetime.now(timezone.utc).isoformat(), "fleets": fleets}
        validate_fleets(manifest)
        write_json(root / "fleet.json", manifest)
    elif action == "seal":
        manifest = load(root)
        manifest["files"] = {relative: digest(safe_file(root, relative))
                             for ns, name, ordinal, enc, meta in entries(manifest)
                             for filename in (enc, meta)
                             for relative in [f"{ns}/{name}/{ordinal}/bundle/{filename}"]}
        write_json(root / "fleet.json", manifest)
    elif action == "check-source":
        current = {(item["metadata"]["namespace"], item["metadata"]["name"]): item["spec"]
                   for item in json.load(sys.stdin)["items"]}
        saved = {(item["namespace"], item["name"]): item["spec"] for item in load(root)["fleets"]}
        require(current == saved, "source fleet configuration changed during backup; retry when stable")
    elif action == "verify":
        load(root, verify=True)
    elif action == "recovery":
        recovery(root, sys.argv[3] if len(sys.argv) > 3 else "")
    elif action == "prepare":
        prepare(root, Path(sys.argv[3]), *sys.argv[4:])
    elif action == "rows":
        for entry in entries(load(root)):
            print("\t".join(entry))
    elif action == "fleets":
        for fleet in load(root)["fleets"]:
            print(f"{fleet['namespace']}\t{fleet['name']}\t{fleet['spec'].get('replicas', 1)}")
    elif action == "public-ip":
        addresses = json.loads(Path(sys.argv[3]).read_text()) if sys.argv[3] else {}
        require(isinstance(addresses, dict), "public IP mapping must be a JSON object")
        expected = {"/".join(entry[:3]) for entry in entries(load(root))}
        require(set(addresses) <= expected, "public IP mapping contains an unknown fleet/ordinal")
        value = addresses.get(sys.argv[4], sys.argv[5])
        ip = ipaddress.IPv4Address(value)
        require(not ip.is_loopback and not ip.is_unspecified and not ip.is_multicast,
                "restore needs a routable node IPv4 address")
        print(ip)
    else:
        raise ValueError("unknown fleet helper operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, tarfile.TarError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
