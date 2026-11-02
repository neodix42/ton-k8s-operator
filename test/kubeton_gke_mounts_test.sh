#!/usr/bin/env bash
# Opt-in Linux mount test. Privilege is confined to a disposable container:
# no host paths or host PID/mount namespaces are passed to Docker.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/charts/ton-k8s-operator/kubeton"

{
  printf 'cat > /entrypoint.sh <<\x27HOST_SCRIPT\x27\n'
  gke_longhorn_prerequisite_script
  printf 'HOST_SCRIPT\ncat > /engine-check.sh <<\x27ENGINE_SCRIPT\x27\n'
  gke_longhorn_engine_execution_script
  printf 'ENGINE_SCRIPT\n'
  cat <<'TEST_SCRIPT'
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p /host/etc /host/sys/module/{iscsi_tcp,dm_crypt} /host/proc /fixture-bin
printf 'ID=cos\n' >/host/etc/os-release
ln -s /proc/1 /host/proc/1
export PATH="/fixture-bin:$PATH"
# Stub only packages, modules, service lifetime, and chroot directory creation.
# nsenter, mount, findmnt, and the execution probes are the real Linux tools.
for tool in modprobe zypper pgrep sleep; do
  printf '#!/bin/sh\nexit 0\n' >"/fixture-bin/$tool"
done
cat >/fixture-bin/chroot <<'CHROOT'
#!/bin/sh
root=$1
shift
[ "$1 $2" = 'mkdir -p' ] || exit 23
case "$root" in
  /host) /bin/mkdir -p "$3" ;;
  /host/home/kubernetes/containerized_mounter/rootfs)
    /bin/mkdir -p "/home/kubernetes/containerized_mounter/rootfs$3" ;;
  *) exit 23 ;;
esac
CHROOT
chmod +x /fixture-bin/*

# Reproduce COS /var without touching the machine running this test.
mount -t tmpfs -o noexec,nosuid,nodev tmpfs /var
mkdir -p /var/lib/longhorn /home/kubernetes/containerized_mounter/rootfs/var/lib/longhorn
data=/var/lib/longhorn
mounter=/home/kubernetes/containerized_mounter/rootfs$data
check_exec() {
  case ",$(findmnt -n -o OPTIONS -T "$1")," in *,noexec,*) fail "still noexec: $1" ;; esac
}
check_parent() {
  case ",$(findmnt -n -o OPTIONS -T /var)," in *,noexec,*) ;; *) fail '/var lost noexec' ;; esac
}

bash /entrypoint.sh
check_exec "$data"
check_exec "$mounter"
check_parent
bash /entrypoint.sh check

# Existing bind mounts need both flags repaired, without accumulating binds.
before=$(findmnt -rn -o TARGET | wc -l)
mount -o remount,bind,noexec "$data"
mount -o remount,bind,noexec "$mounter"
if bash /entrypoint.sh check; then fail 'noexec passed readiness'; fi
bash /entrypoint.sh
after=$(findmnt -rn -o TARGET | wc -l)
[[ "$before" == "$after" ]] || fail 'rerun stacked duplicate mounts'
check_exec "$data"
check_exec "$mounter"
check_parent
bash /entrypoint.sh check
[[ -z "$(find "$data/engine-binaries" -name '.kubeton-exec-check.*' -print)" ]] || fail 'probe leaked files'

# Model an old instance manager's independent mount flags. These mounts must
# be repaired in place, without restarting a process or changing PVCs.
mkdir -p /host/var/lib/longhorn/engine-binaries/test-engine /engine-binaries
cp /bin/true /host/var/lib/longhorn/engine-binaries/test-engine/longhorn
mount --bind /host/var/lib/longhorn/engine-binaries /host/var/lib/longhorn/engine-binaries
mount -o remount,bind,noexec /host/var/lib/longhorn/engine-binaries
mount --bind /host/var/lib/longhorn/engine-binaries /engine-binaries
if /host/var/lib/longhorn/engine-binaries/test-engine/longhorn; then fail 'fixture is executable'; fi
sh /engine-check.sh
check_exec /host/var/lib/longhorn/engine-binaries
check_exec /engine-binaries
/host/var/lib/longhorn/engine-binaries/test-engine/longhorn
check_parent

# Execution denial from file permissions must still fail after mount repair.
chmod 600 /host/var/lib/longhorn/engine-binaries/test-engine/longhorn
if sh /engine-check.sh; then fail 'non-executable engine passed'; fi
echo 'kubeton GKE Linux mount and execution tests passed.'
TEST_SCRIPT
} | docker run --rm --privileged -i --entrypoint /bin/bash \
  longhornio/longhorn-instance-manager:v1.10.0 -es
