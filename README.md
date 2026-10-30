# TON Kubernetes Operator

## TL;DR

Bootstrap a local installation bundle from a pinned release for your existing
Kubernetes cluster:

```bash
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.5.10/install.sh" | bash
cd ./ton-k8s-operator-0.5.5
./kubeton
```

`./kubeton` lists the available commands. Follow
[Production Deployment](#production-deployment) to review the values, install
the operator and start the TON fleet.

## Overview

Kubernetes operator for [MyTonCtrl](https://github.com/neodix42/mytonctrl), built with Go + Kubebuilder. Each TON pod uses two independently selected images:

- `tonNode.image` / `spec.image`: `ghcr.io/neodix42/mytonctrl:v1.0.0`, which runs MyTonCtrl and supervises TON services.
- `tonNode.tonImage` / `spec.tonImage`: `ghcr.io/ton-blockchain/ton:v2026.08-amd64`, which supplies the official TON executables, Fift libraries and smart-contract scripts.

The `stage-ton-exporter` init container takes the exporter script from the MyTonCtrl image. The `export-ton-binaries` init container runs it in the official TON image, bypassing that image's normal entrypoint, and exports its artifacts into a shared `emptyDir`. MyTonCtrl mounts `/ton-artifacts` read-only and selects a private `/run/ton-active` snapshot before starting services. Changing either image rolls the pod; application code and binaries are supplied by the images.

This operator creates and manages:
- `TonNode` custom resources (`ton.ton.org/v1alpha1`)
- A headless `Service` per `TonNode`
- A `StatefulSet` per `TonNode`
- Persistent blockchain data on the `ton-work` PVC at `/var/ton-work`.
- With `spec.keyManagement.enabled: true`, controller state, wallet files, validator keyring and backup staging use memory-backed tmpfs. Encrypted checkpoints persist on the separate `keybundle` PVC.
- With key management disabled, controller state and key files persist directly on `ton-work`. Public validator configuration at `/var/ton-work/db/config.json` remains on `ton-work` in both modes.

## Behavior Implemented

<details>
<summary>Operator behavior, networking and runtime defaults</summary>

- Uses StatefulSet for TON replicas.
- Uses headless Service (`clusterIP: None`) for stable DNS.
- Exposes TON validator/quic/lite-server ports on worker nodes with `hostPort` by default:
  - UDP `30001` (`validatorPort`)
  - UDP `31001` (`quicPort`)
  - TCP `30003` (`liteServerPort`)
  - can be disabled via `spec.network.hostPortsEnabled: false`
- Enforces anti-affinity (`kubernetes.io/hostname`) so replicas of the same `TonNode` are not scheduled on the same worker.
- Auto-selects storage class:
  1. `spec.storage.storageClassName` (if set)
  2. `longhorn` if present
  3. cluster default StorageClass
  4. no class (cluster policy decides)
- Passes the environment variables supported by the MyTonCtrl container:
  - `PUBLIC_IP` (explicit `spec.network.publicIP`, otherwise auto node `ExternalIP` for single-replica; fallback `status.hostIP`)
  - `NETWORK` (fallback `mainnet`; prefer the `-n` installation flag)
  - `GLOBAL_CONFIG_URL` when explicitly supplied; otherwise the upstream entrypoint selects the global configuration after processing `-n` (`https://ton-blockchain.github.io/global.config.json` for mainnet, `https://ton-blockchain.github.io/testnet-global.config.json` for testnet)
  - `VALIDATOR_PORT`
  - `LITESERVER_PORT`
  - `VALIDATOR_CONSOLE_PORT`
  - `QUIC_PORT`
- For `hostPortsEnabled=true` with auto `PUBLIC_IP` (empty `spec.network.publicIP`), operator preselects sticky worker hostnames before first pod launch (Ready/schedulable nodes matching `spec.nodeSelector`) to prevent node/IP drift on restarts without a post-launch rollout.
- Passes `spec.args` after the container's `run` command. `tonnode-values.yaml`, used by `kubeton start`, selects `-m validator -n testnet -d`. The chart's base `values.yaml` selects `-m liteserver -n mainnet -d -i` for the lab configuration; `-i` bypasses the upstream hardware check, while `kubeton check` still checks Kubernetes node capacity.
- Readiness requires the committed controller state and active `validator` and `mytoncore` services; with key management enabled, an encrypted recovery bundle must also exist. Managed shutdown quiesces services and checkpoints secrets within the Pod's termination grace period.
- Applies default pod resources (overridable via `spec.resources`):
  - requests: `cpu=16000m`, `memory=64Gi`
  - limits: `cpu=128000m`, `memory=256Gi`

</details>

## TonNode Spec

The CRD includes:
- `image` (MyTonCtrl runtime)
- `tonImage` (official TON artifact provider)
- `args` (MyTonCtrl first-install flags)
- `replicas`
- `storage`
- `resources`
- `network`
- `configRef`
- `keyManagement`
- `env`
- `debug` (including optional jemalloc allocation profiling)

See sample:
- `config/samples/ton_v1alpha1_tonnode.yaml`

### MyTonCtrl startup arguments

Set arguments as a YAML array; each flag and value is a separate element. This example selects a mainnet liteserver with dump download and bypasses the upstream hardware check:

```yaml
tonNode:
  image: ghcr.io/neodix42/mytonctrl:v1.0.0
  tonImage: ghcr.io/ton-blockchain/ton:v2026.08-amd64
  args: ["-m", "liteserver", "-n", "mainnet", "-d", "-i"]
```

| Argument | Purpose |
| --- | --- |
| `-m validator` / `-m liteserver` | Select the first-install mode. |
| `-n mainnet` / `-n testnet` / `-n custom` | Select the network. Custom networks require a global configuration. |
| `-c URL` / `-c /mounted/config.json` | Use a custom global configuration URL or mounted absolute file. |
| `-d` | Download and extract a blockchain dump. Omit it for initialization without a dump. |
| `-i` | Bypass the upstream CPU/RAM requirement check. |
| `-t` | Disable telemetry. |
| `-s` | Skip startup checks when opening the MyTonCtrl console. |

If `spec.args` and `MYTONCTRL_ARGS` are omitted, upstream defaults select a mainnet validator without dump download. Installation options are applied when `/var/ton-work/controller/initialized.json` is first committed. Existing controller state retains its original installation settings; changing an argument does not reinstall a running node. Supplemental installation parameters such as `CUSTOM_PARAMETERS`, `DUMP_EXTRACT_THREADS` and `VERBOSITY` remain available through `tonNode.env`. The operator requires `/var/ton-work`: `-W /var/ton-work` is allowed, custom work directories and `-e` environment-file overrides are rejected. Host source-selection options (`-a`, `-r`, `-b`, `-g`, `-v`) are rejected by the container: select the desired MyTonCtrl and TON images instead. See the upstream [container startup documentation](https://github.com/neodix42/mytonctrl/blob/master/README.docker.md).

The partial-service `-l` / `--only-node` and `-o` / `--only-mtc` modes are rejected because operator readiness requires both TON and MyTonCore services. With encrypted key management enabled, `-u` supports only `root` or `validator`, matching restored key ownership.

Diagnostic `--help`, `-h`, `--print-env` and `MYTONCTRL_PRINT_ENV` settings are rejected because they exit without running services. `--archive`, `ARCHIVE` and `ARCHIVE_BLOCKS` are also unsupported with the standard official TON image because that mode requires the additional `tonutils-storage` binary.

<details>
<summary>Optional jemalloc profiling for validator OOM investigation</summary>

After deploying an operator build with profiling support, enable it in
`tonnode-values.yaml` and run `./kubeton start` to apply the configuration.
This changes the Pod template and restarts the fleet; existing node data and
installation arguments are retained. Profiling is disabled by default.

```yaml
tonNode:
  debug:
    jemalloc:
      enabled: true
      sampleLog2: 19
      intervalLog2: 34
      maxProfiles: 8
```

The standard TON `v2026.10-amd64` binary and MyTonCtrl `v1.0.5` runtime support
this without rebuilding the images or using `LD_PRELOAD`. Startup probes the
actual validator binary and runtime allocator; an unsupported custom image
fails with an explicit profiling error before node services start. Do not also
set `MALLOC_CONF` in `tonNode.env`: the optional profiler manages it.

`sampleLog2: 19` samples approximately every 512 KiB allocated.
`intervalLog2: 34` requests a profile approximately every 16 GiB of cumulative
allocation activity, rather than every 16 GiB of live memory or a time interval.
Reduce it for more frequent snapshots, allowing for profiling and disk I/O
overhead. Both settings follow [jemalloc's profiling options](https://jemalloc.net/jemalloc.3.html).
OOM/SIGKILL cannot run an exit handler; the retained profiles show allocations
before the kill, with no guarantee of a snapshot at the exact failure instant.

Each container launch gets a unique private directory under
`/var/ton-work/diagnostics/jemalloc` on the `ton-work` PVC. It includes `.heap`
profiles, the exact `validator-engine` executable, its SHA256/image reference,
and `memory.json` with the latest available cgroup counters (v1 or v2).
Profiles survive container/Pod recreation while that PVC is retained. They
are removed with the work volume during destructive recovery/uninstall.
Every ten seconds, retention keeps the newest `maxProfiles` heap files across
launches and removes unused old binary directories. The count is best effort
and can temporarily be exceeded between checks; it is not a disk quota.

Export diagnostics from a running/restarted Pod:

```bash
kubectl -n default exec tonnode-0 -c ton-node -- ls -lt /var/ton-work/diagnostics/jemalloc
kubectl -n default cp tonnode-0:/var/ton-work/diagnostics/jemalloc ./tonnode-0-jemalloc -c ton-node
```

On an analysis machine with `jeprof` installed, select one `.heap` and the
binary from the same launch directory:

```bash
jeprof --text ./<launch>/validator-engine ./<launch>/<profile>.heap
# Compare growth between two snapshots from the same binary:
jeprof --text --base=./<launch>/<earlier>.heap ./<launch>/validator-engine ./<launch>/<later>.heap
```

See the official [heap profiling guide](https://github.com/jemalloc/jemalloc/wiki/Use-Case:-Heap-Profiling).
Resolving library frames may additionally require matching runtime libraries
and debug symbols. Profiles contain sampled allocation sizes, stack addresses
and mappings, rather than the contents of allocations; this is not a core dump.
Keep diagnostics private. Heap profiles alone do not cover all mmap, page-cache,
tmpfs or kernel memory; compare them with `memory.json`, container limits and
Kubernetes `OOMKilled` events. Disable `debug.jemalloc.enabled` and apply
`./kubeton start` again to stop collecting; retained diagnostics remain on the PVC.

</details>

## Prerequisites

For deployment to an existing Kubernetes cluster:

- `kubectl` configured to access the target cluster
- Helm 3
- Bash, Python 3, OpenSSL and `tar`
- `curl` or `wget` to download the installer

## Production Deployment

Bootstrap a local installation bundle from a pinned release:

```bash
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.5.10/install.sh" | bash
```

The script:

- creates a local folder named `ton-k8s-operator-<chart-version>` by default
- downloads chart from `oci://ghcr.io/neodix42/charts/ton-k8s-operator`
- extracts the chart and prints next commands
- downloads the matching `kubeton` and all three fleet helpers from release assets

The extracted chart already includes:

- `values.yaml`
- `operator-values.yaml`
- `tonnode-values.yaml`
- `kubeton`
- `fleet.sh`, `fleet.py`, and `fleet-crypto.sh` for fleet migration

Then follow:

```bash
cd ./ton-k8s-operator-0.5.5

# review defaults
ls -1 values.yaml operator-values.yaml tonnode-values.yaml kubeton

# helper script for common fleet operations
./kubeton help
./kubeton check
./kubeton install
./kubeton start

# required: refresh and export encrypted recovery backups
./kubeton backup-keys
```

### Longhorn and Vault bootstrap

Longhorn does not need to be installed before `./kubeton install` on bare metal.
`install` installs or updates the TON operator and waits for its Deployment;
`start` prepares the storage/key-management dependencies before deploying TON.

| Cluster | What `kubeton start` bootstraps |
| --- | --- |
| Bare metal | Longhorn, encrypted StorageClass `encrypted-sc`, Vault, its Transit key and TON credentials. Existing healthy Longhorn is reused. |
| Local k3d | Vault and a local StorageClass fallback; Longhorn is skipped. This fallback does not provide Longhorn disk encryption. |
| GKE / other cloud | Automatic bootstrap is off by default. Prepare the dependencies yourself or explicitly opt in with `FORCE_BAREMETAL_BOOTSTRAP=true`. |

`AUTO_BAREMETAL_BOOTSTRAP` defaults to `true`; setting it to `false` disables
automatic bootstrap even when `FORCE_BAREMETAL_BOOTSTRAP=true`.
To prepare dependencies separately, use `./kubeton bootstrap-baremetal`.

The command `FORCE_BAREMETAL_BOOTSTRAP=true ./kubeton install` still installs
only the operator. The prefix also applies only to that one command; export it
or repeat it when running `start`. For GKE, follow the
[GKE setup instructions](#install-on-google-cloud-gke), including worker and
StorageClass preparation, before enabling bootstrap.

With the default storage layout, Longhorn holds encrypted key bundles and
Vault state; the validator database uses `local-path` on bare metal or the
selected GKE Persistent Disk class. VictoriaLogs uses its separately selected
storage class and may also use Longhorn. Worker requirements such as iSCSI,
mount propagation and encryption tools remain administrator responsibilities;
kubeton does not install host packages.

After a successful `./kubeton start`, **you must run `./kubeton backup-keys`**
as part of this production deployment workflow. It refreshes each node's
in-cluster encrypted bundle and exports a current recovery copy to the machine
running kubeton. The automatic first-start bundle stays inside the cluster and
does not replace this required export. The backup command temporarily stops and
restarts the TON fleet while exporting.

Keep the exported directory outside the cluster and take a fresh backup after
creating wallets or changing keys. These bundles still require the original
Vault Transit or cloud KMS key for decryption; retain that root of trust.

### VictoriaLogs dashboard access

After `kubeton start`, open the password-protected VictoriaLogs dashboard:

1. Run this on the server from which you want to expose the dashboard:

   ```bash
   ./kubeton logs expose
   ```

   Open the printed URL, typically
   `http://<server-public-ip>:8427/select/vmui/`. The command starts a background
   port-forward through VMAuth and verifies that login is required. Allow inbound
   TCP to the printed port through that server's firewall/NAT. To advertise a
   specific hostname or use another port:

   ```bash
   ./kubeton logs expose --public-host logs.example.com --port 18427
   ```

2. Retrieve the username and password using the command printed by `logs expose`.
   With the default namespace and Secret name:

   ```bash
   kubectl -n vm get secret vmuser-kubeton -o go-template='{{printf "Username: %s\nPassword: %s\n" (.data.username | base64decode) (.data.password | base64decode)}}'
   ```

3. Enter those decoded credentials in the browser's login prompt. `logs expose`
   prints the retrieval command, not the password itself. Use the discovered
   namespace and Secret name if you customized them.

The exposed endpoint uses HTTP Basic Auth. Use an HTTPS reverse proxy to encrypt
credentials and log responses for public access. For local access instructions
without exposing a public port, run `./kubeton logs`.

### Node preflight: `kubeton check`

Run this before installing or starting a fleet:

```bash
./kubeton check
```

`kubeton` reads the effective TON settings from `TON_VALUES_FILE` (by default
`tonnode-values.yaml`); it does not source a `.env` file. With the defaults,
each TON replica requests `760Gi` of data PVC capacity:

```yaml
tonWorkSize: 700Gi
tonSourceSize: 20Gi
myTonCoreSize: 20Gi
myTonCtrlSize: 20Gi
```

<details>
<summary>Node capacity checks and placement details</summary>

For local-path and other local or unrecognized provisioners, the node filesystem
minimum is these configured storage sizes plus `KUBETON_CHECK_DISK_HEADROOM`
(default `20Gi`). GKE Persistent Disk and Longhorn data PVCs use separate storage
capacity, so only the headroom is charged against the node filesystem; their
provisioning quotas and storage-pool capacity must be verified separately. Mixed
live StatefulSet claim templates charge only their local storage requests to the
node filesystem. `kubeton check` does not fetch dump metadata or automatically increase the requirement when
`DUMP=true`. Because the compressed archive and extracted database coexist
under `/var/ton-work` during bootstrap, the operator must set `tonWorkSize`
large enough for that peak and the desired kubelet eviction reserve before
running `kubeton start`. Rancher `local-path` does not reserve or enforce the
PVC byte request; here `tonWorkSize` is the explicit placement-policy input.

The check requires at least 16 vCPU and 64Gi memory per TON pod (or a larger
`tonNode.resources.requests` value).
It rejects NotReady/cordoned nodes, `DiskPressure`, `MemoryPressure`,
`PIDPressure`, hard taints, insufficient allocatable CPU or memory after
assigned pod requests, insufficient free node filesystem space, and requested
TON `hostPort` reservations owned by other assigned non-terminal Pods. The
host-port gate covers validator UDP, QUIC UDP, lite-server TCP, and an optional
exporter TCP port from literal `CUSTOM_PARAMETERS`; it ignores only Pods of the
same live TonNode StatefulSet during an in-place upgrade. Free disk comes from the
kubelet Summary API (`nodes/proxy` RBAC is required), rather than
`ephemeral-storage` allocatable capacity.

The command prints every node, but succeeds when there are enough compatible
target nodes for the configured replica count. TON uses hostname anti-affinity,
so replicas need distinct nodes. When Longhorn is present or will be
bootstrapped, it instead requires `max(tonNode.replicas,
LONGHORN_DEFAULT_REPLICA_COUNT)` compatible nodes. This means an unhealthy node
such as a `DiskPressure` node is reported and excluded when other compatible
nodes exist.

`kubeton install` runs the same read-only gate before Helm is invoked.
`kubeton start` and `kubeton bootstrap-baremetal` run it before Longhorn is
installed. For a fresh Longhorn install using the default selector, kubeton
marks only selected compatible nodes with its managed
`ton.ton.org/kubeton-prereq=ready` label and adds that label to the Longhorn and
TON selectors, including Longhorn's system-managed CSI DaemonSet selector. This
prevents a Longhorn DaemonSet from being sent to a known `DiskPressure` node.
When Longhorn already exists, `kubeton check` also requires both
`driver.longhorn.io` in every selected node's `CSINode` and a non-terminating
Ready `longhorn-csi-plugin` pod on that node. `kubeton start` waits for the same
per-node state before stale-PVC cleanup, checks it again after cleanup, reruns
disk/pressure/host-port checks, and performs one final CSI probe immediately
before Helm. This prevents aggregate Longhorn readiness from hiding a missing
CSI plugin on a particular TON target node and minimizes the window in which a
previously safe node can become an initial target.
Existing Longhorn installations are not automatically
reselected because that could disrupt mounted volumes; both the Longhorn manager
and CSI DaemonSet selectors are checked and the command fails with affected
nodes instead. The exception is a previously failed Longhorn install with no
Longhorn volumes: kubeton safely rebuilds its placement on compatible nodes.
Existing TON resources using local-path are also left on their current node
selector rather than being relabelled onto a new node.

</details>

### Launch evidence and durable logs

`kubeton install` and `kubeton start` create a private evidence directory on
the machine where the command is executed. The default location is:

```text
./kubeton-launch-logs/<UTC timestamp>-<install|start>-<pid>/
```

Use `./kubeton logs` for recent container output and dashboard access
instructions. After starting the fleet, follow the
[VictoriaLogs dashboard access](#victorialogs-dashboard-access) steps below.

<details>
<summary>Launch diagnostics, startup waits, log collection and access details</summary>

The directory and its files are owner-only (`0700`/`0600`). It contains the
complete kubeton command transcript, a timestamped Pod-state timeline, target
namespace and cluster-wide Kubernetes Event streams, controller output,
and final Pod/StatefulSet/TonNode, PVC/PV, VolumeAttachment, node, CSINode,
Longhorn, Vault, operator, and Victoria status snapshots. During `install`, or
when automatic VictoriaLogs capture is explicitly disabled for `start`, it
also retains best-effort current/previous output from every TON init and
application container. The
cluster-wide Event watcher starts before storage bootstrap or Helm can create a
TON Pod, so it also preserves scheduler, CSI, Vault, Longhorn, and logging
failures that occur before a TON object exists. The path is printed at the
beginning and end of the command. Treat the bundle as sensitive operational
data even though kubeton does not read Kubernetes Secret contents, does not
query Secret or ConfigMap objects for final diagnostics, and does not copy
literal container environment values into its Pod JSON snapshot.

When automatic VictoriaLogs is enabled, `start` deliberately does not open a
second long-lived `kubectl logs --follow` connection for every TON container.
VictoriaLogs is already required to be Ready before the first TON Pod is
created and durably captures those streams. Avoiding the redundant followers
also preserves API/proxy connection capacity for placement, reconciliation,
and bootstrap status reads on remote clusters.

When the default evidence directory is inside an extracted chart, Helm excludes
it from the chart payload. The live transcript pipes are created separately in
a private temporary directory and removed after the command, so Helm never
encounters those irregular files while loading the chart.

Useful evidence locations include `events-cluster.log` for the cluster-wide
stream, `final/events-cluster.txt` for its final snapshot,
`final/{operator,longhorn,vault}-diagnostics.txt` for each dependency
namespace, `final/longhorn-storage.txt` for Longhorn CR/storage status, and
`final/victoria-*-diagnostics.txt` for every configured VictoriaMetrics,
VictoriaLogs, or VictoriaMetrics-operator namespace, plus
`final/victoria-*-resources.txt` for Victoria custom-resource status. These
diagnostics contain workload, Service/endpoint, PVC, lease, Event, and
non-secret custom-resource status only; they never read Secret payloads.

`kubeton install` keeps these watchers alive until the operator Deployment
reports Ready (up to 10 minutes by default). A failed rollout makes the command
fail and leaves its controller logs, Pod status, and Events in the bundle.

For `start`, the local watcher begins before storage bootstrap or Helm creates
the TON objects. A pod can be `Running` while a dump is downloading or
extracting. The readiness probe checks committed initialization, active
services and, with key management enabled, the encrypted recovery bundle.
`kubeton start` also inspects the bootstrap contents directly. By default, it
waits up to 24 hours for every ordinal to have the MyTonCtrl commit state:

- `/var/ton-work/controller/initialized.json`
- a non-empty `/var/ton-work/db/config.json`
- a non-empty `/var/ton-work/controller/mytoncore/mytoncore.db`
- `validator.service` and `mytoncore.service` units in `/var/ton-work/controller/services`

With key management enabled, controller files are live in memory and recovered
from encrypted checkpoints. Readiness does not create an off-cluster copy;
the required `./kubeton backup-keys` export after `start` remains a separate step.

It prints state changes and one-minute heartbeats such as `FailedScheduling`,
`FailedAttachVolume`, `downloading`, `extracting`, `CrashLoopBackOff`, and
`complete`. Five repeated CrashLoop restarts with a non-zero exit fail the
command early while leaving the Pods/PVCs intact for diagnosis. After a
sequential scale-up, `start` also waits for the final TonNode and StatefulSet
generations and every expected non-terminating Pod object before starting the
bootstrap-content checks. Repeated Kubernetes API read failures retain the
`kubectl` exit reason and fail after three consecutive attempts by default
instead of being reported as an unknown Pod state for the full 24-hour window.

On a fresh infrastructure bootstrap, `start` installs the node collector before
Longhorn or Vault. Both that collector and the VictoriaLogs backend are
restricted to the exact node set accepted by the command's fresh deployment
prerequisite preflight; this also applies to local k3d. A node rejected for
disk, pressure, taint, readiness, CPU, memory, or host-port reasons is therefore
not a VictoriaLogs target. The collector queues early container logs in a
bounded, release-specific host directory under
`/var/lib/kubeton-vlogs-buffer-*`; the queue flushes when the VictoriaLogs
backend becomes available. Before the first TON Pod is created, `start` also
installs or verifies that backend and refuses to deploy TON unless a
non-terminating Ready collector of the current DaemonSet revision exists on
every selected TON node. An upgrade also waits until collectors left on nodes
that no longer pass the preflight have been removed; readiness on the remaining
nodes cannot hide a stale or misscheduled collector. If TON preflight itself
fails but an older stack already exists, `start` still narrows its collector to
the partial PASS set and scales the exactly identified backend StatefulSet to
zero before returning the TON failure; Helm state, PVC data, and bounded
collector buffers are preserved. A conclusive zero-PASS result suspends the
collector as well. An API/inventory failure that cannot prove a complete check
does not perform this emergency mutation. The next successful reconcile restores
the backend. Sequential local-volume staging rechecks coverage before each
additional ordinal is created.

`./kubeton start` runs a fresh node prerequisite preflight before installing
or reconciling VictoriaLogs and the VictoriaMetrics access stack. Logging
placement cannot widen beyond the nodes approved by that check. The approved
hostnames and configured selector overrides are retained with the VictoriaLogs state for
audit and cleanup, but the effective intersections are recomputed—not trusted
as current authority—on every reconcile.
`VICTORIA_LOGS_NODE_SELECTOR` and
`VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR` may only narrow the preflight-approved
set; they never replace or widen it.
VictoriaLogs is the durable source for selected container stdout/stderr across rapid
restarts and an SSH/API interruption; the local bundle supplements it with
control-plane Events and launch state that do not exist in container logs.
The tested default chart versions are pinned, collector disk buffering is
bounded, and collector CPU/memory/ephemeral-storage requests prevent it from
being a zero-request BestEffort eviction target.

Collection is limited to TON runtime/artifact initialization containers,
the operator manager in its configured namespace, and recognized Longhorn
components in the configured storage namespace. Wallet, fleet, backup/restore,
Vault, key-management sidecars and unrelated workloads are excluded before
their log files are read. Pod labels and annotations are not copied into
stored log entries. Application messages can still contain secrets if the
application prints them; this filter does not redact message contents.
Older collector versions collected helper output, including wallet exports.
Updating the collector does not erase that retained history or its on-node
buffer; review previously collected logs and restrict access accordingly.

The VictoriaLogs backend itself does not authenticate requests. By default,
kubeton therefore installs a `NetworkPolicy` that allows backend traffic only
from the exact kubeton collector release and the exact kubeton VMAuth instance.
This protects the in-cluster query endpoint when the CNI enforces Kubernetes
NetworkPolicy (Calico does). Set `VICTORIA_LOGS_NETWORK_POLICY_ENABLED=false`
only for a cluster whose CNI cannot support that policy; kubeton prints an
explicit warning because any in-cluster Pod may then reach the backend directly.
The release-specific collector buffer is intentionally retained on nodes after
an uninstall so a failed bootstrap/reinstall can resume and flush queued logs;
after deciding the history is no longer needed, an administrator may remove
only the printed/configured release's exact `/var/lib/kubeton-vlogs-buffer-*`
directory on each former collector node. During uninstall, kubeton removes the
VictoriaLogs access Service first but keeps the ingress NetworkPolicy and its
release cleanup records until the backend is proven gone. If that bounded
cleanup check fails, uninstall exits non-zero and also defers Longhorn removal;
rerunning uninstall safely retries the recorded release instead of exposing or
stranding the retained launch evidence.

Useful launch controls:

- `KUBETON_LAUNCH_LOG_ROOT` (default `$PWD/kubeton-launch-logs`)
- `KUBETON_LAUNCH_LOGS_ENABLED` (default `true`)
- `KUBETON_LAUNCH_SNAPSHOT_INTERVAL_SECONDS` (default `15`)
- `KUBETON_INSTALL_READY_TIMEOUT_SECONDS` (default `600`; `install` keeps
  capturing logs and fails unless the operator Deployment becomes Ready)
- `KUBETON_START_WAIT_FOR_BOOTSTRAP` (default `true`)
- `KUBETON_START_READY_TIMEOUT_SECONDS` (default `86400`)
- `KUBETON_START_RECONCILE_TIMEOUT_SECONDS` (default `auto`, calculated as 15
  minutes per replica plus 15 minutes; final TonNode/StatefulSet generation
  and Pod-object convergence after sequential staging)
- `KUBETON_START_STATUS_INTERVAL_SECONDS` (default `60`)
- `KUBETON_START_FATAL_RESTART_COUNT` (default `5`; `0` disables fail-fast)
- `KUBETON_START_STATUS_READ_ERROR_LIMIT` (default `3`; consecutive failed
  Kubernetes API reads before `start` stops waiting; `0` leaves only the
  overall wait timeout in effect)
- `KUBETON_START_VICTORIA_LOGS_ENABLED` (default `true`; setting it to
  `false` explicitly accepts that the local watcher cannot guarantee every
  rapid restart)

The VictoriaLogs collector covers Kubernetes container stdout/stderr, not the
host's kubelet/containerd/Docker system journal. Continuous host-journal access
would require a separate privileged node agent and is intentionally not enabled
by default. Scheduler, CSI, eviction, and kubelet decisions relevant to launch
are retained from the cluster-wide Kubernetes Event API stream in the local
evidence bundle. Final dependency snapshots also retain Pod `.status.reason`
and `.status.message` plus init/application-container restart and termination
state, including an `Evicted` Pod's low-ephemeral-storage message even when its
own Event list is empty.

To determine whether a replica downloaded or extracted a dump, use its bundle,
not `df` from an arbitrary host:

```bash
grep -E 'downloading|extracting|complete|Failed|CrashLoop' \
  kubeton-launch-logs/<run>/timeline.tsv \
  kubeton-launch-logs/<run>/command.log
grep -R -E 'Download complete|Starting extraction|MyTonCtrl ready|initialized.json|exit code' \
  kubeton-launch-logs/<run>/pods/
```

The authenticated VictoriaMetrics access layer is installed automatically by
`./kubeton start`. Run `./kubeton logs` for its access instructions. You can
also use a temporary direct port-forward and open
`http://127.0.0.1:9428/select/vmui/` on the machine running kubectl:

```bash
LOG_SERVICE=$(kubectl -n vm get service \
  -l app.kubernetes.io/name=kubeton-victoria-logs-access \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n vm port-forward --address 127.0.0.1 "service/${LOG_SERVICE}" 9428:9428
```

For external browser access, run this on the server with cluster access:

```bash
./kubeton logs expose
# Explicit hostname/NAT address or a different listening port:
./kubeton logs expose --public-host logs.example.com --port 18427
```

The command starts a background `kubectl port-forward --address 0.0.0.0`
to VMAuth and prints the external dashboard URL, for example
`http://203.0.113.10:8427/select/vmui/`. It discovers this server's public IPv4
address using [ipify](https://www.ipify.org/); use `--public-host` when NAT, proxies, or DNS require a
different advertised address. Permit inbound TCP to the printed port in the
server firewall and any upstream NAT. The command discovers the installed
VMAuth gateway even if its saved metrics state is missing. For older clusters
with VictoriaLogs already running, it sets up missing authenticated access or
adds the logs route to an existing kubeton-managed gateway. This does not
restart the TON fleet or reinstall its storage, logs backend, or collector;
there is no need to rerun `kubeton start`. Existing credentials and metrics
routes are preserved. The command never publishes the bare VictoriaLogs
backend. Before publishing the forward it checks that anonymous dashboard
requests are rejected and that the decoded VMAuth credentials can load the
dashboard. It retries while the authentication configuration loads and requests
one configuration refresh if those credentials remain rejected. A failed
check keeps access local and exits with an error, rather than reporting success.

Use the decoded username and password from the printed Secret for the browser's
HTTP Basic Auth prompt. With the default names, retrieve them on the server:

```bash
kubectl -n vm get secret vmuser-kubeton -o go-template='{{printf "Username: %s\nPassword: %s\n" (.data.username | base64decode) (.data.password | base64decode)}}'
```

`kubeton logs expose` prints the same retrieval command with the discovered
namespace and Secret name. Credentials are not printed by `logs expose` itself.
If the browser cached a previous login, open a private window and enter the
decoded values there.

VMAuth's port-forward serves HTTP Basic Auth. Public HTTP does not encrypt
credentials or responses; use an HTTPS reverse proxy when encrypted public
access is required. `kubeton uninstall`/`purge` stop the managed forward.

A host filesystem is relevant only after the replica's local-path PV
`nodeAffinity` or `local.path.provisioner/selected-node` points to that host.

For a separate filesystem mounted at `LOCAL_PATH_PROVISIONER_ROOT`, the kubelet
node filesystem statistic is only a safety signal, not an authoritative free
space measurement for that mount. Use a host-level disk monitor/probe as well.
Useful overrides are `KUBETON_CHECK_MIN_CPU`,
`KUBETON_CHECK_MIN_MEMORY`, and `KUBETON_CHECK_DISK_HEADROOM`; set
`KUBETON_SKIP_NODE_PREREQ_CHECK=true` only when intentionally bypassing the
gate. Skipping the TON preflight does not authorize a cluster-wide
VictoriaLogs deployment: `start` refuses automatic logging without a fresh
safe set. Metrics and authenticated access are reconciled within the same
`start` lifecycle.

Security note:
- bootstrap stores Vault init material in `vault/ton-vault-bootstrap`; rotate/restrict access after bootstrap.

Cloud behavior:
- bare-metal bootstrap is skipped by default
- local k3d bootstrap is enabled by default
- before `./kubeton start`, configure prerequisites manually:
  - encrypted StorageClass named `encrypted-sc` (or adjust env/values)
  - Vault credential secret `ton-vault-creds` in TON namespace (`default` by default)

If your cloud setup uses custom names, override with env vars:
- `ENCRYPTED_SC_NAME`
- `TON_VAULT_CREDS_SECRET`
- `TON_NAMESPACE`

</details>

<details>
<summary>Additional administration, wallet and log command examples</summary>

```bash
./kubeton upgrade
./kubeton prometheus start
./kubeton grafana start
./kubeton backup-keys
./kubeton restore-keys ./key-backups/<timestamp>
./kubeton wallet create main-wallet
./kubeton wallet deploy
./kubeton wallet deploy main-wallet
./kubeton wallet send main-wallet tonnode-0 validator_wallet_001 10.
./kubeton wallet send main-wallet tonnode-0 validator_wallet_001 10. -n
./kubeton wallet send main-wallet 10.
./kubeton wallet collect main-wallet
./kubeton wallet collect main-wallet 10.
./kubeton wallet collect main-wallet tonnode-0
./kubeton wallet collect main-wallet tonnode-0 validator_wallet_001 10.
./kubeton wallet collect main-wallet tonnode-0 validator_wallet_001 alld
./kubeton wallet activate
./kubeton wallet activate tonnode-0
./kubeton wallet activate tonnode-0 validator_wallet_001
./kubeton wallet show
./kubeton wallet show main-wallet
./kubeton wallet show balance
./kubeton wallet show balance tonnode-0
./kubeton wallet show balance tonnode-0 validator_wallet_001
./kubeton wallet export
./kubeton wallet export main-wallet
./kubeton wallet export tonnode-0 validator_wallet_001
./kubeton verify
./kubeton status
./kubeton logs
./kubeton logs devnet-16
./kubeton logs tonnode-2
./kubeton logs default/tonnode-2
./kubeton logs expose
./kubeton exec "sync"
./kubeton exec-mtc "set stake 1000000"
```

</details>

`kubeton status` shows separate `TON image` and `MyTonCtrl image` tag columns
(for example, `v2026.08-amd64` and `v1.0.3`) from each pod's image references,
alongside the validator build date, wallet, ADNL, sync, and database sizes.

`kubeton logs [server-name|pod-name]` prints a snapshot of the last 20 lines from each TON pod's
`ton-node` container across namespaces, selected by `TON_POD_LABEL`. Each pod's
output has a namespace, pod, and node heading. If a pod's logs cannot be read,
the command still tries the remaining pods and exits with a nonzero status.
Omit the name to show all TON pods. Run `./kubeton logs devnet-16` for the pods
on that server, or `./kubeton logs tonnode-2` for pods with that name. Server
and pod names match exactly. If a pod name exists in several namespaces, all
matching pods are shown; use `./kubeton logs default/tonnode-2` to select one
namespace. Pods can be selected by name even before a server is assigned. If
no TON pods match, the command prints a message and exits with a nonzero status.

<details>
<summary>Historical logs and wallet operation details</summary>

The initial message points to VictoriaLogs for full historical container logs.
It discovers installed Services, including custom names and ports, and prefers
VMAuth when its VictoriaLogs routes exist; otherwise it shows the internal
backend. In-cluster URLs are labeled accordingly, with a manual port-forward
command and the localhost UI URL to open after forwarding. The command does
not start a forward. Run `kubeton logs expose` to start a public background
port-forward through VMAuth and print its external dashboard URL. Missing
VictoriaLogs does not block pod log output.

`kubeton wallet create` only generates main-wallet files and the init BOC.
Send funds to the non-bounceable init address printed by `wallet create`.
Funding gives an undeployed wallet a balance but does not install its contract;
the account remains uninitialized until deployment. A verified undeployed
account reports seqno `0`; failed state queries remain `unknown`.
`kubeton wallet show` also displays `wallet-version`. You can deploy explicitly
with `kubeton wallet deploy <name>`. A send from a funded, uninitialized wallet
deploys the saved wallet contract first and waits for an active account before
building the transfer. It checks that the deployment matches the existing key,
workchain, wallet ID, and address.

When distributing funds, each payment is verified against the source wallet's
transaction history: the signed message body, destination and nanoTON amount
must match an actual outgoing payment before the next recipient is attempted.
A source seqno change or a lite-server acknowledgement alone is insufficient.
Check recipient balances when you need to confirm final delivery.
Send output shows progress, concise retry or fallback notices, and confirmed
payments by default. A recovered lite-server failure does not print the raw
error trace when the payment is confirmed. For Fift, lite-client, and TONCenter
diagnostics, run `MAIN_WALLET_VERBOSE=true ./kubeton wallet send ...`.
Unconfirmed failures still print detailed diagnostics automatically.
Receipt verification uses the matching TONCenter history endpoint in every
transport mode; `liteserver` restricts broadcasting, while confirmation still
requires HTTPS access to that endpoint.

Before broadcasting, `wallet send` saves the exact signed message and the batch
plan under `.outbox/<wallet-name>/` on the main-wallet bundle PVC. This journal
contains public transaction data, has restricted file permissions, and contains
no private keys. An exclusive source-wallet lock prevents concurrent kubeton
send batches. Keep this directory with the PVC's encrypted wallet bundle.
Recovery progress follows this PVC: `backup-fleet` excludes the main-wallet and
its journal, and exporting a signing key does not preserve pending-payment
history. A main-wallet PVC migration must retain the entire PVC while its
helpers are stopped, preserve access to its Vault key, and start only one copy.

If a new send is interrupted or confirmation times out, rerun **the same command**
with the same recipients, amount and bounce option. It resumes the unfinished
batch, checks receipts again, skips confirmed payments, and rebroadcasts the same
signed bytes. A different unfinished plan is rejected. An expired message can
be renewed only after a pinned post-expiry chain query reports its original
seqno unchanged; the replacement retains that seqno, recipient and amount.
Unavailable or inconsistent receipts stop the batch with its progress retained.
Transaction-history lookup checks the latest 100 source transactions; an old
batch displaced by heavy unrelated activity may require manual inspection.

A completed batch is a completed payment instruction: running it again creates
a new payment. Sends made by older releases without this journal cannot be
resumed automatically; check their source transactions and recipient balances
before constructing another payment.

After topping up mytonctrl wallets inside TON pods with split mode, for example
`kubeton wallet send main-wallet 2`, activate those pod wallets with
`kubeton wallet activate [tonnode-name] [wallet-name]`. The
activate command executes `aw <wallet-name>` through `mytonctrl` inside the TON
pod, which submits the wallet's deployment BOC using MyTonCtrl's configured
transports. MyTonCtrl may submit redundant copies: once the first copy
activates the account, later copies can be rejected with a seqno mismatch
(`exitcode=33`). This can occur during a successful activation.

`kubeton` checks the selected wallet's live chain state after `aw`. A matching
wallet name and raw account must report `active` before it prints a concise
`is active (confirmed on chain)` message and counts that wallet as activated.
Intermediate transport diagnostics stay quiet after verified success. If the
wallet remains uninitialized, cannot be queried, or has a different identity,
the command returns a failure and prints the MyTonCtrl output and verification
failure. A console `ActivateWallet - OK` alone cannot establish success.
Wallets already active at the initial check are skipped.

Confirmation makes up to six checks with two seconds between checks and a
shared 60-second deadline across metadata, HTTPS and lite-client reads. Set
`WALLET_ACTIVATION_CONFIRM_ATTEMPTS`,
`WALLET_ACTIVATION_CONFIRM_DELAY_SECONDS`, or
`WALLET_ACTIVATION_CONFIRM_TIMEOUT_SECONDS` to adjust these limits. MyTonCtrl's
activation command retains its separate `MYTONCTRL_EXEC_TIMEOUT` limit.
`kubeton wallet collect` starts new `mg` operations only for active source
wallets. The default `alld` drains the source balance and destroys its on-chain
contract. Its local keys and address remain available; a future top-up requires
activation again before collection. A deleted wallet has no seqno getter, so
MyTonCtrl's old `WaitTransaction` check can time out after a successful drain.

Collection now verifies the incoming transaction at the destination main
wallet. Each operation records a unique public comment before submitting `mg`;
the receipt must match that comment, source, destination and amount. Numeric
amounts must match exactly; `alld` must deliver a positive amount within the
recorded source balance after fees. A source becoming empty, a changed balance,
or a console success message alone cannot confirm collection. Verified
payments produce a concise received-amount message even if MyTonCtrl's seqno
wait failed; unresolved payments retain the original diagnostics and return a
failure. Delivery fallbacks remain enabled.

Public operation journals live in
`/var/ton-work/controller/.kubeton-collect/`, with
restricted permissions and a lock preventing concurrent collection from the
same account. With key management enabled, this directory is in memory and a
new pending intent must receive its own encrypted-checkpoint acknowledgement
before `mg` can sign a payment. Missing checkpoint support, a failed snapshot or
a 60-second checkpoint timeout stops collection before submission. With key
management disabled, journals remain on the work PVC.
Rerunning an unresolved collection checks its existing receipt
without signing another transfer, including when `alld` already deleted the
source. In fleet recovery, matching completed operations are skipped while
pending operations are checked. A completed collection followed by a fresh
invocation is a new payment instruction. Preserve the corresponding encrypted
bundle or work PVC; restoring an older copy also rolls back its journal history.
Older releases did not record these operation identifiers, so inspect their
transactions before constructing another payment.

Confirmation queries the latest 100 destination transactions over the matching
network's HTTPS API, with paced requests and transient-error retries. The
`WALLET_COLLECT_CONFIRM_TIMEOUT_SECONDS` default is `60`; the MyTonCtrl command
has its separate `MYTONCTRL_EXEC_TIMEOUT` limit. Old requests displaced from
that history window remain unresolved for manual inspection.

`kubeton wallet deploy`, `kubeton wallet send`, and `kubeton wallet collect`
detect the network from `/var/ton-work/controller/global.config.json` in every
TON pod. Detection matches both zero-state root and file hashes against the
known mainnet and testnet identities. Deploy/send use that active global
configuration for lite-client and the matching TONCenter endpoint. Local
Python 3 is required for detection; it uses only the standard library.

Transactions stop before sending if there are no TON pods, any active config
cannot be read or identified, or pods use different networks. Desired
`NETWORK`, installer arguments and configuration URLs do not replace this
check: restored PVCs may retain a different configuration. A legacy leading
`mainnet` or `testnet` argument is accepted only when it matches detection;
it cannot select another network. The optional final `-n` on `wallet send`
still means no-bounce.

Create and export do not require an active blockchain network. Create saves
the detected network when available, and deploy/send/collect reject a wallet whose
saved network differs from the active network. `kubeton wallet show [name]`
prints addresses and metadata even when detection is unavailable; balance and
seqno are shown only with a readable, consistent active network that matches
the wallet, otherwise they are unknown. A successful deploy also records the
wallet network in the encrypted main-wallet metadata.

Friendly addresses shown by create/show and deployment hints use the wallet's
known network. For workchain 0, mainnet uses `UQ`/`EQ` forms and testnet uses
`0Q`/`kQ` forms.
Older wallet metadata may contain Fift's default test-only forms even for a
mainnet wallet. These are corrected when displayed, preserving the same raw
account, keys, wallet ID, and bounce behavior. A genuine saved-network mismatch
still blocks transfers. A successful lite-client response that an account is
empty reports zero balance and seqno; connection/query failures remain unknown.

By default wallet BOC sending uses
`MAIN_WALLET_MODE=auto`: two lite-server attempts followed by two TONCenter
attempts.
For sendfile, a successful lite-client exit code alone is not an acceptance
acknowledgement. The command requires `external message status is 1`; an RPC
failure or missing acknowledgement uses the configured fallback with the same
signed message. An acknowledgement still requires transaction verification.
In `auto` mode, a missing receipt after 10 seconds also triggers rebroadcast of
the **same** signed message through TONCenter, even if a lite-server acknowledged
it. Each payment has a 180-second confirmation budget; HTTP and lite-client
requests, retries and delays respect the remaining budget.

Main-wallet account queries prefer the matching network's HTTPS endpoint,
pace anonymous requests, and retry transient rate-limit/server failures.
Successful payment receipts establish a minimum next seqno so an older cached
wallet-information response cannot reuse an already consumed counter. Failed
queries remain unknown. The helper's default completion deadline grows with
the recipient count; an explicit `MAIN_WALLET_POD_TIMEOUT` takes precedence.
`MAIN_WALLET_CONFIRM_TIMEOUT_SEC`, `MAIN_WALLET_REBROADCAST_DELAY_SEC`,
`MAIN_WALLET_REBROADCAST_ATTEMPTS` and `MAIN_WALLET_HTTP_MIN_INTERVAL_MS` control
the confirmation and retry limits.
Pod wallet state checks first use HTTPS from the machine running `kubeton`.
The active `global.config.json` zero-state identity selects TONCenter mainnet
or testnet, so queries do not depend on each pod's outbound lite-server
connection. No API key is required; requests are paced for the anonymous rate
limit and retry rate-limit responses. Public APIs are not queried for an
unrecognized or private network.

If HTTPS is unavailable, the pod's lite-client queries the exact local wallet
address using its active configuration. This fallback tries configured servers
in a stable order, with up to three attempts and 45 seconds per process to allow
connection setup and the client's multiple RPCs to complete. Adjust these with
`WALLET_QUERY_ATTEMPTS` (1–10) and `WALLET_QUERY_TIMEOUT_SECONDS` (1–60); the
whole pod command is bounded by `MYTONCTRL_EXEC_TIMEOUT` (default `180s`).

A successful response that the account does not exist shows `empty` and
`0.000000000`. For HTTPS results, `kubeton` checks the returned ShardAccount
cell for an explicit `account_none` at the same masterchain block; a zero
balance alone does not establish emptiness. A funded, undeployed account shows
`uninit` and its actual balance. If both query paths fail, the output includes
the HTTPS/RPC failure reasons and retains the row with unknown live state and
balance. Local address, workchain, and known wallet version remain visible.
Unknown means the balance could not be checked; it must not be treated as empty
or zero.
Older installations without the direct query prerequisites use `mytonctrl wl`
as a compatibility fallback. Activation and collection still execute MyTonCtrl
commands inside the TON pods.

Collection stops before confirmation if any selected pod's live state or saved
operation cannot be read safely. Confirmed inactive wallets without a saved
request are skipped, with funding guidance for empty wallets and activation
guidance for uninitialized wallets. A saved pending request can still be checked
after its source contract has disappeared.

Sending to pod wallets reads their named `.addr` files without querying live
balances. These destinations use non-bounceable addresses for the detected
network, allowing initial funding while nodes are still syncing. If the file
cannot be read, a successful, validated `mytonctrl wl` lookup is used as a
compatibility fallback. Fleet sends require every pod's destination to resolve
before confirmation; a failed lookup stops the command instead of dividing the
total amount among fewer wallets.

`kubeton wallet export` prints private key material to stdout after confirmation:
with no arguments it exports all pod wallet `.pk` files, with one argument it
exports the named main wallet, including its subwallet id, from the encrypted
main-wallet bundle, and with `<pod-name> <wallet-name>` it exports one pod
wallet.
Export decodes binary Fift `.addr` files into the canonical
`workchain:account-hex` address. It retains a valid friendly address when it
matches the wallet file, and checks its tag and checksum. Invalid address data
is shown as `unknown`, so binary bytes cannot corrupt the output columns.

The ephemeral main-wallet helper uses the deployed official TON artifact image from `tonImage`, independently of the MyTonCtrl image tag. A digest pin is preserved. Override `MAIN_WALLET_IMAGE` to select a separate helper image.

</details>

<details>
<summary>Lifecycle, image upgrade, monitoring and cleanup commands</summary>

```bash
# install TON k8s operator only
./kubeton check
./kubeton install

# start TON nodes (replicas from tonnode-values.yaml)
./kubeton start

# expose the password-protected VictoriaLogs dashboard and print its login-retrieval command
./kubeton logs expose

# apply changed MyTonCtrl/TON images from tonnode-values.yaml
./kubeton upgrade

# create/update Prometheus scrapers from TonNode CUSTOM_PARAMETERS --exporter-address
# require a password, start background port-forward(s), and print credentials
./kubeton prometheus start

# remove kubeton-managed Prometheus resources and background port-forward(s)
./kubeton prometheus stop

# create/update Grafana with kubeton-managed Prometheus datasource(s)
# require login, start background local/public port-forward, and print credentials
./kubeton grafana start

# remove kubeton-managed Grafana resources and background port-forward(s)
./kubeton grafana stop

# kubeton start also manages VictoriaLogs, the VictoriaMetrics operator,
# metrics scraping, and authenticated access with a local VMAuth port-forward.
# kubeton logs prints browser access instructions.
./kubeton logs

# scale by one replica
./kubeton add
./kubeton del   # always removes the highest ordinal (tail) replica
./kubeton recreate tonnode-10 ./key-backups/<timestamp>  # recreates one pod data PVCs and restores its backup bundle

# pause TON pods and managed Prometheus/Grafana; retain data, configuration and credentials
./kubeton stop
./kubeton start             # restore TON and previously paused managed dashboards

# verify
./kubeton verify

# drops TON nodes and storage (PVCs/PVs/Longhorn resources)
./kubeton drop

# full best-effort cleanup of kubeton-managed resources (keeps TonNode CRD)
./kubeton uninstall

# OR full destructive cleanup including TonNode CRD
# kept separate from uninstall because CRD deletion is cluster-scoped
./kubeton purge
```

`kubeton stop` saves the replica counts of kubeton-managed Prometheus and
Grafana Deployments, scales them to zero, closes their local background
port-forwards, and waits for their controlled Pods to disappear. It retains
their configuration and credential Secrets. Dashboard cleanup also runs when
there are no TON StatefulSets left to stop.

`kubeton start` resumes only dashboards previously paused by `kubeton stop`,
after restoring TON and refreshing metrics setup. It does not install
Prometheus or Grafana merely because `start` was run. Use
`./kubeton prometheus start` or `./kubeton grafana start` to print access
credentials and start a local dashboard port-forward again.

VictoriaLogs, VictoriaMetrics, Vault and Longhorn continue running during
`kubeton stop` so historical logs, storage and key recovery remain available.
Use `kubeton uninstall` or `kubeton purge` for destructive teardown. The
dedicated `kubeton prometheus stop` and `kubeton grafana stop` subcommands remove
those dashboards' managed resources instead of preserving them for a resume.

`kubeton uninstall` removes the managed fleet, dashboards, logging stack and
helper resources, then tears down eligible Vault/Longhorn infrastructure. It
keeps the TonNode CRD; `kubeton purge` additionally removes that CRD. Both
commands report incomplete cleanup as a failure instead of treating a deletion
request as proof that the resource is gone.

Earlier versions could leave components behind because some Kubernetes/Helm
errors were ignored, VictoriaMetrics discovery depended on the current
namespace settings, and generated resources did not always carry kubeton's
labels. Cleanup now follows recorded stack/operator identities across custom
namespaces and includes generated VictoriaMetrics workloads, service accounts
and RBAC. It also checks Longhorn's CSI, webhook and RBAC resources. PVC cleanup
records backing-volume identity before deleting claims; a generic label sweep
does not bypass that storage ledger.

Deletion failures, Helm failures and namespace timeouts return non-zero and
retain the relevant cleanup records for retry. VictoriaLogs ingress protection
stays until its unauthenticated backend is proven gone. Empty recorded
observability namespaces are removed; shared namespaces are preserved.
VictoriaMetrics operators/CRDs used by other applications are retained. A shared
Vault namespace, remaining Longhorn users/backend volumes, or an in-use
encrypted StorageClass blocks that dependency's removal and is reported.
If an older teardown erased VictoriaMetrics ownership records but left its
operator running, cleanup reports that unverified installation for review.

For an earlier incomplete teardown, run the updated CLI's
`./kubeton uninstall` or `./kubeton purge` again. Resolve the reported API/RBAC,
finalizer, ownership or active-storage issue before retrying. Do not remove
unrelated applications or their data merely to make a shared dependency
disappear. Successful cleanup is limited to verified managed resources;
provider snapshots and external backups require separate handling.

When retrying removal of an older fleet, keep `TON_VALUES_FILE` pointed at its
original namespace/name settings. Cleanup also discovers remaining dynamic,
`Delete`-policy TON PVs whose PVCs were already removed by an earlier teardown,
including higher replica ordinals. It records verified PV/claim UIDs and
Longhorn volume identity before removing supported backing storage; retained,
static, mounted, rebound or unrelated volumes remain protected. Missing
TonNode CRDs and non-deployed Helm history are handled as partial-cleanup
state, without requiring the operator to be reinstalled.

If `0.5.5` prints `flags cannot be placed before plugin name: -A`, update the
`kubeton` script before retrying. That version placed `-A` before the `delete`
command in one monitoring-cleanup helper, preventing its deletions. The CLI
fix also handles the leftover-PV discovery above; an operator image reinstall
is not required to run the corrected purge.

</details>

### Environment overrides

`kubeton` reads these environment variables:

<details>
<summary>All supported environment variables</summary>

```bash
RELEASE_NAME
OP_NAMESPACE
CHART_DIR
OP_VALUES_FILE
TON_VALUES_FILE
TON_POD_LABEL
TON_NAMESPACE
TON_STORAGE_CLASS_NAME
MAIN_WALLET_IMAGE_REPOSITORY
MAIN_WALLET_IMAGE
MAIN_WALLET_SCRIPT_FILE
MAIN_WALLET_SCRIPT_CONFIGMAP
MAIN_WALLET_BUNDLE_PVC
MAIN_WALLET_BUNDLE_SIZE
MAIN_WALLET_BUNDLE_STORAGE_CLASS
MAIN_WALLET_BUNDLE_ACCESS_MODE
MAIN_WALLET_MODE
MAIN_WALLET_VERBOSE
MAIN_WALLET_GLOBAL_CONFIG_URL
MAIN_WALLET_TONCENTER_URL
MAIN_WALLET_TONCENTER_API_KEY
MAIN_WALLET_NAME
MAIN_WALLET_SEND_RETRY_ATTEMPTS
MAIN_WALLET_LITESERVER_SEND_ATTEMPTS
MAIN_WALLET_TONCENTER_SEND_ATTEMPTS
MAIN_WALLET_SEND_RETRY_DELAY_SEC
MAIN_WALLET_CONFIRM_ATTEMPTS
MAIN_WALLET_CONFIRM_DELAY_SEC
MAIN_WALLET_CONFIRM_TIMEOUT_SEC
MAIN_WALLET_HTTP_MIN_INTERVAL_MS
MAIN_WALLET_REBROADCAST_DELAY_SEC
MAIN_WALLET_REBROADCAST_ATTEMPTS
MAIN_WALLET_POD_TIMEOUT
MAIN_WALLET_RUNTIME_TMPFS_SIZE
WALLET_QUERY_ATTEMPTS
WALLET_QUERY_TIMEOUT_SECONDS
WALLET_ACTIVATION_CONFIRM_TIMEOUT_SECONDS
WALLET_ACTIVATION_CONFIRM_ATTEMPTS
WALLET_ACTIVATION_CONFIRM_DELAY_SECONDS
WALLET_COLLECT_CONFIRM_TIMEOUT_SECONDS

AUTO_BAREMETAL_BOOTSTRAP
FORCE_BAREMETAL_BOOTSTRAP
SKIP_KEY_PREREQ_CHECK
KUBETON_SKIP_NODE_PREREQ_CHECK
KUBETON_CHECK_MIN_CPU
KUBETON_CHECK_MIN_MEMORY
KUBETON_CHECK_DISK_HEADROOM
KUBETON_NODE_PREREQ_LABEL_KEY
KUBETON_NODE_PREREQ_LABEL_VALUE

LONGHORN_RELEASE_NAME
LONGHORN_NAMESPACE
LONGHORN_CHART
LONGHORN_CHART_VERSION
LONGHORN_DEFAULT_REPLICA_COUNT
ENCRYPTED_SC_NAME
LONGHORN_CRYPTO_SECRET_NAME
LOCALDEV_BASE_SC
ALLOW_DESTRUCTIVE_LONGHORN_REPAIR
LONGHORN_NODE_SELECTOR

VAULT_RELEASE_NAME
VAULT_NAMESPACE
VAULT_CHART
VAULT_CHART_VERSION
VAULT_TRANSIT_KEY
VAULT_TON_POLICY_NAME
VAULT_BOOTSTRAP_SECRET
VAULT_BOOTSTRAP_UNSEAL_KEY
VAULT_BOOTSTRAP_ROOT_TOKEN
VAULT_LOCALDEV_NODE_SELECTOR
TON_VAULT_CREDS_SECRET
VAULT_ADDR_INTERNAL
VAULT_TOKEN_PERIOD

NAMESPACE_DELETE_PROGRESS_TIMEOUT
KUBETON_PAUSE_ANNOTATION_KEY
KUBETON_PAUSE_NODEMAP_ANNOTATION_KEY
STICKY_ORDINAL_NODE_MAP_ANNOTATION_KEY
KUBETON_DEBUG_POD_CLEANUP_ON_UNINSTALL
KUBETON_DEBUG_POD_PREFIX
KUBETON_LOCAL_PATH_CLEANUP
LOCAL_PATH_PROVISIONER_ROOT
KUBETON_LOCAL_PATH_CLEANUP_IMAGE
KUBETON_LOCAL_PATH_CLEANUP_NAMESPACE
KUBETON_LOCAL_PATH_CLEANUP_TIMEOUT_SECONDS
KUBETON_LOCAL_PATH_PATTERN_CLEANUP
KUBETON_LOCAL_PATH_CLEANUP_LEDGER_NAME
KUBETON_LOCAL_PATH_CLEANUP_LEDGER_NAMESPACE
KUBETON_SEQUENTIAL_TON_START
KUBETON_VOLUME_STAGE_TIMEOUT_SECONDS
KUBETON_LONGHORN_READY_TIMEOUT_SECONDS
KUBETON_VAULT_MOUNT_RECOVERY_ATTEMPTS
KUBETON_FAIL_ON_LONGHORN_MULTIPATHD
KUBETON_LAUNCH_LOGS_ENABLED
KUBETON_LAUNCH_LOG_ROOT
KUBETON_LAUNCH_SNAPSHOT_INTERVAL_SECONDS
KUBETON_INSTALL_READY_TIMEOUT_SECONDS
KUBETON_START_WAIT_FOR_BOOTSTRAP
KUBETON_START_READY_TIMEOUT_SECONDS
KUBETON_START_RECONCILE_TIMEOUT_SECONDS
KUBETON_START_STATUS_INTERVAL_SECONDS
KUBETON_START_FATAL_RESTART_COUNT
KUBETON_START_STATUS_READ_ERROR_LIMIT
KUBETON_START_VICTORIA_LOGS_ENABLED
KUBETON_UPGRADE_TIMEOUT_SECONDS
SKIP_STOP_KEY_BACKUP
STATUS_EXEC_TIMEOUT
HELPER_POD_READY_TIMEOUT
HELM_UNINSTALL_CMD_TIMEOUT

PROMETHEUS_IMAGE
PROMETHEUS_PORT
PROMETHEUS_LOCAL_PORT_BASE
PROMETHEUS_PORT_FORWARD_DIR
PROMETHEUS_PORT_FORWARD_WAIT_SECONDS
PROMETHEUS_PORT_FORWARD_VERIFY_SECONDS
PROMETHEUS_PORT_FORWARD_ADDRESS
PROMETHEUS_ADMIN_USER
PROMETHEUS_ADMIN_PASSWORD
PROMETHEUS_ADMIN_SECRET_NAME
PROMETHEUS_TARGET_MODE
PROMETHEUS_EXTERNAL_NODEIP_AUTOFIX
PROMETHEUS_EXTERNAL_NODEIP_AUTOFIX_TIMEOUT_SECONDS
PROMETHEUS_EXTERNAL_NODEIP_OPERATOR_AUTOFIX
OP_CONTROLLER_DEPLOYMENT

GRAFANA_IMAGE
GRAFANA_NAMESPACE
GRAFANA_PORT
GRAFANA_LOCAL_PORT_BASE
GRAFANA_PORT_FORWARD_DIR
GRAFANA_PORT_FORWARD_WAIT_SECONDS
GRAFANA_PORT_FORWARD_VERIFY_SECONDS
GRAFANA_PORT_FORWARD_ADDRESS
GRAFANA_ADMIN_USER
GRAFANA_ADMIN_PASSWORD
GRAFANA_ADMIN_SECRET_NAME
GRAFANA_DASHBOARD_UID
GRAFANA_DASHBOARD_TITLE

VICTORIA_METRICS_NAMESPACE
VICTORIA_METRICS_STACK_NAME
VICTORIA_METRICS_AUTH_USERNAME
VICTORIA_METRICS_AUTH_PASSWORD
VM_OPERATOR_VERSION
VICTORIA_METRICS_OPERATOR_INSTALL_MANIFEST
VICTORIA_METRICS_OPERATOR_NAMESPACE
VICTORIA_METRICS_OPERATOR_DEPLOYMENT
VICTORIA_METRICS_ROLLOUT_TIMEOUT_SECONDS
VICTORIA_METRICS_AUTH_PORT
VICTORIA_METRICS_NODEPORT_ENABLED
VICTORIA_METRICS_AUTH_LOCAL_PORT_BASE
VICTORIA_METRICS_API_PROXY_LOCAL_PORT_BASE
VICTORIA_METRICS_PORT_FORWARD_DIR
VICTORIA_METRICS_PORT_FORWARD_WAIT_SECONDS
VICTORIA_METRICS_PORT_FORWARD_VERIFY_SECONDS
VICTORIA_METRICS_PORT_FORWARD_ADDRESS
VICTORIA_METRICS_STATE_CONFIGMAP

VICTORIA_LOGS_ENABLED
VICTORIA_LOGS_NAMESPACE
VICTORIA_LOGS_RELEASE_NAME
VICTORIA_LOGS_COLLECTOR_RELEASE_NAME
VICTORIA_LOGS_HELM_REPO_NAME
VICTORIA_LOGS_HELM_REPO_URL
VICTORIA_LOGS_SINGLE_CHART_VERSION
VICTORIA_LOGS_COLLECTOR_CHART_VERSION
VICTORIA_LOGS_RETENTION_PERIOD
VICTORIA_LOGS_PVC_SIZE
VICTORIA_LOGS_RETENTION_DISK_SPACE
VICTORIA_LOGS_COLLECTOR_BUFFER_SIZE
VICTORIA_LOGS_COLLECTOR_CPU_REQUEST
VICTORIA_LOGS_COLLECTOR_MEMORY_REQUEST
VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_REQUEST
VICTORIA_LOGS_COLLECTOR_CPU_LIMIT
VICTORIA_LOGS_COLLECTOR_MEMORY_LIMIT
VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_LIMIT
VICTORIA_LOGS_STORAGE_CLASS
VICTORIA_LOGS_NODE_SELECTOR
VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR
VICTORIA_LOGS_PIN_TO_LONGHORN_CSI
VICTORIA_LOGS_NETWORK_POLICY_ENABLED
VICTORIA_LOGS_PORT
VICTORIA_LOGS_LOCAL_PORT_BASE
VICTORIA_LOGS_API_PROXY_LOCAL_PORT_BASE
VICTORIA_LOGS_PORT_FORWARD_DIR
VICTORIA_LOGS_PORT_FORWARD_WAIT_SECONDS
VICTORIA_LOGS_PORT_FORWARD_VERIFY_SECONDS
VICTORIA_LOGS_PORT_FORWARD_ADDRESS
VICTORIA_LOGS_STATE_CONFIGMAP
VICTORIA_LOGS_HELM_TIMEOUT_SECONDS
VICTORIA_LOGS_CLEANUP_TIMEOUT_SECONDS
```

</details>

### kubeton prometheus

`kubeton prometheus start` creates or updates the Prometheus scrapers and
requires HTTP Basic authentication for the dashboard and API. It generates a
random password on the first start and stores the credentials in the Kubernetes
Secret `kubeton-prometheus-admin` in each Prometheus namespace. Later starts
reuse those credentials and print the username, password, Secret location and
dashboard address.

Credential overrides:

- `PROMETHEUS_ADMIN_USER` (default `admin`)
- `PROMETHEUS_ADMIN_PASSWORD` (default empty; generate or reuse the stored password)
- `PROMETHEUS_ADMIN_SECRET_NAME` (default `kubeton-prometheus-admin`)

For example, the command prints credentials in this form:

```text
[metrics] Admin user: admin
[metrics] Admin password: <generated-password>
```

Prometheus and Grafana keep their existing port-forward bind defaults:
`0.0.0.0` on bare metal, and `127.0.0.1` on k3d or cloud clusters. Override
`PROMETHEUS_PORT_FORWARD_ADDRESS` or `GRAFANA_PORT_FORWARD_ADDRESS` to choose
the listening address. Password authentication does not encrypt external HTTP
traffic; use an HTTPS reverse proxy for encrypted browser access.

### PROMETHEUS_TARGET_MODE

`PROMETHEUS_TARGET_MODE` controls how `kubeton prometheus start` builds scrape targets from TonNode `CUSTOM_PARAMETERS` (`--exporter-address`).

<details>
<summary>Scrape target modes, host-port requirements and remediation controls</summary>

- `auto` (default):
  - bare-metal (non-k3d): uses `external-nodeip`
  - k3d/cloud: uses `pod-ip`
- `pod-ip`: Prometheus targets pod addresses (`<podIP>:<port>`). This is cluster-internal and does not require node-level exporter exposure.
- `external-nodeip`: Prometheus targets node external addresses (`<nodeExternalIP>:<port>`). Use this when you want exporter endpoints reachable via server IP.
  - when `ExternalIP` is absent on a node, `kubeton` falls back to that node `InternalIP`.

`external-nodeip` prerequisites:
- TON pods are `Running`
- exporter port from `--exporter-address` is valid
- TON pod template exposes matching `hostPort` (requires `hostPortsEnabled=true`)
- worker nodes have `ExternalIP` or `InternalIP`
- firewall/security-group allows inbound traffic to exporter port (for example `9777/tcp`)

Examples:

```bash
# force cluster-internal pod IP targets
PROMETHEUS_TARGET_MODE=pod-ip ./kubeton prometheus start

# force server/node external IP targets
PROMETHEUS_TARGET_MODE=external-nodeip ./kubeton prometheus start
```

If prerequisites for `external-nodeip` are missing, `kubeton` prints warnings and skips Prometheus stack creation for that TonNode until fixed.

In `external-nodeip` mode, `kubeton prometheus start` auto-remediates by default:
- patches `spec.network.hostPortsEnabled=true` on the TonNode when it is disabled
- waits for StatefulSet template to expose exporter `hostPort`
- performs one StatefulSet rollout restart so running pods pick up the exporter `hostPort`

Auto-remediation controls:
- `PROMETHEUS_EXTERNAL_NODEIP_AUTOFIX=true|false` (default `true`)
- `PROMETHEUS_EXTERNAL_NODEIP_AUTOFIX_TIMEOUT_SECONDS` (default `420`)
- `PROMETHEUS_EXTERNAL_NODEIP_OPERATOR_AUTOFIX=true|false` (default `true`, auto-upgrades operator to chart version when needed)
- `OP_CONTROLLER_DEPLOYMENT` (default `ton-k8s-operator-controller-manager`)

`operator-values.yaml` is operator-focused (image/resources/metrics); `kubeton install` preserves existing TonNode chart values on upgrade (`--reuse-values`) and does not delete active TON resources.
`tonnode-values.yaml` enables TON nodes, enables key-management by default (`vault`, `ton-vault-creds`, `encrypted-sc`), and selects both runtime images, MyTonCtrl startup arguments and supported container environment parameters.

</details>

### kubeton grafana

`kubeton grafana start` automates Grafana installation/start and wires datasource/dashboard provisioning to kubeton-managed Prometheus service(s).

<details>
<summary>Grafana setup, credentials, dashboards and environment overrides</summary>

Behavior:

- ensures kubeton-managed Prometheus stack exists (from TonNode `CUSTOM_PARAMETERS --exporter-address`)
- deploys `kubeton-grafana` (`grafana/grafana`)
- provisions authenticated Prometheus datasources using credentials from Kubernetes Secrets, so dashboard queries continue to work with Prometheus authentication enabled
- provisions the TON overview dashboard and opens it as the default home dashboard
- starts background `kubectl port-forward` and prints local/remote URL
- requires login, disables anonymous access and self-registration, and prints Grafana admin credentials on every start

The first start generates a random admin password and stores it in the
`kubeton-grafana-admin` Secret in the Grafana namespace. Later starts reuse the
stored credentials. `GRAFANA_ADMIN_USER` defaults to `admin`;
`GRAFANA_ADMIN_PASSWORD` defaults to empty (generate or reuse the password), and
`GRAFANA_ADMIN_SECRET_NAME` defaults to `kubeton-grafana-admin`.

```text
[grafana] Admin user: admin
[grafana] Admin password: <generated-password>
```

The TON overview is installed automatically; no manual dashboard import is
needed. With the updated CLI, run the command again to provision or refresh it:

```bash
./kubeton grafana start
```

Open the printed `/d/kubeton-ton-overview` URL, or find **TON Exporter Overview**
under **Dashboards → Kubeton**. The dashboard includes target availability,
masterchain sequence number and block age, shard processing lag, validator
groups, collation/validation rates and timing, mempool messages, ADNL/QUIC traffic,
actor worker activity, and scrape health. Choose **Prometheus**, **TON job** and
**Node target** at the top; each managed Prometheus instance is selectable.

<details>
<summary>Grafana charts, filters, time windows and metric availability</summary>

Expand the four additional sections for session-style charts from native TON
metrics:

| Section | Charts |
| --- | --- |
| Block production and workload | Successful collated candidates/s, candidate TPS, mean block and collated-data sizes, gas/block, transactions/block, external messages offered and their outcomes |
| Message queues and overload | Latest outbound queue size, outbound cleanup/block, inbound messages processed/skipped per block, overload causes, blocks requesting a shard split |
| Collation and validation time | Mean end-to-end elapsed time and instrumented real/CPU time, with separate masterchain and shard traces |
| Storage-stat cache | Lookups and account cells per block by hit/miss/small outcome, eligible lookup hit rate, lookups/s |

The **Chain** selector chooses masterchain, shards or both. **Leader-window
position** selects the first block, later blocks or both for candidate rate,
candidate TPS, transactions/block and end-to-end collation elapsed time. Other
charts include all positions because their exporter counters have no `first`
label. On legacy/non-window collation paths, TON reports `first=0`; interpret the
first/later comparison on validators or collators using leader windows.

**Window size** offers `10s`, `1m`, `5m`, `15m` and `1h` for these four sections.
The current scrape interval is 15 seconds, so the effective rate window is at
least one minute, including for `10s`. Rates and per-block averages use counter
changes over that window; they are not exact event buckets. With no successful
blocks in a window, per-block charts show **No data**. The existing overview
charts continue to use Grafana's automatic rate interval.

Recent-range links offer `1h`, `2h`, `6h`, `1d`, `1w`, `30d`, `90d`, `180d` and
`365d` while preserving dashboard filters. They show only history retained by
the selected Prometheus server; selecting a year does not configure retention
or persistent storage. The optional **Test runs** annotation layer displays
Grafana annotations tagged `ton-run`; add an annotation or time region in Grafana
to mark a run. It does not automatically import runs from `ton-mesh`.

The session-stats service used by `ton-mesh` parses session logs and correlates
candidates with accepted blocks. These Prometheus charts measure each node's
collated candidates, so candidate TPS and candidate rate can differ from
on-chain TPS or block rate. The queue gauge is the most recent collation for
each chain; on a multi-shard collator it is whichever shard finished last,
rather than one series per shard. Size estimates, load fractions, the remaining
first/later splits and LiteServer TPS/block rate need session-log or LiteServer
data that this exporter does not supply. No session-log collector is installed
by this dashboard.

Panels use the raw metrics documented for
[TON v2026.10](https://github.com/ton-blockchain/ton/blob/v2026.10/metrics/METRICS.md).
Synchronization series appear after initialization. Validator groups and timing
histograms may show **No data** until the node participates; rate charts need a
few scrapes. The native exporter does not provide CellDB/archive sizes or host
memory/filesystem metrics, so those are not included. `kubeton status` still
reports database sizes.

</details>

The command checks that the provisioned dashboard is available before printing
its access URL. `GRAFANA_DASHBOARD_UID` and `GRAFANA_DASHBOARD_TITLE` customize its
identity and title; existing datasource UIDs and login credentials are preserved.

Main environment overrides:

- `GRAFANA_IMAGE`
- `GRAFANA_NAMESPACE`
- `GRAFANA_PORT`
- `GRAFANA_LOCAL_PORT_BASE`
- `GRAFANA_PORT_FORWARD_ADDRESS`
- `GRAFANA_ADMIN_USER`
- `GRAFANA_ADMIN_PASSWORD`
- `GRAFANA_ADMIN_SECRET_NAME`
- `GRAFANA_DASHBOARD_UID`
- `GRAFANA_DASHBOARD_TITLE`

</details>

### Automatic VictoriaLogs and VictoriaMetrics

`kubeton install` installs the TON operator. `kubeton start` automatically
installs or updates VictoriaLogs, the VictoriaMetrics operator, and
`VMSingle` + `VMAgent` + `VMAuth` + `VMUser` before deploying TON pods. It
refreshes TonNode scrape resources (`Service` + `VMServiceScrape`) from
`CUSTOM_PARAMETERS --exporter-address` after applying the fleet, including the
first start when no TonNode existed during metrics setup.

Use `kubeton logs` for access instructions. `kubeton uninstall` and
`kubeton purge` remove the managed logging/metrics resources and local
port-forwards.

For browser access and credentials, follow
[VictoriaLogs dashboard access](#victorialogs-dashboard-access).

<details>
<summary>VictoriaLogs and VictoriaMetrics resources, placement and environment overrides</summary>

Behavior:
- applies/updates VictoriaMetrics operator in namespace `vm` (configurable)
- deploys kubeton-managed VM stack resources with generated or user-provided auth credentials
- creates/updates TonNode scrape resources so `VMAgent` starts scraping TonNode exporters
- runs a fresh node prerequisite preflight, then installs/updates the VictoriaLogs backend (`victoria-logs-single`) and collector (`victoria-logs-collector` DaemonSet) only on the exact nodes that pass it, with `remoteWrite[0].url` pointed at VictoriaLogs
- caps the collector's per-destination on-node buffer and sets explicit CPU, memory, and ephemeral-storage requests/limits
- waits for collectors on nodes removed from the approved set to disappear and strictly requires a Ready current-revision collector on every selected TON node
- constrains VictoriaLogs single to the fresh preflight-approved set; when its PVC uses Longhorn, also respects existing Longhorn manager placement (or the bootstrap selector for a new installation)
- detects Longhorn by the selected StorageClass provisioner, including custom class names, and by default requires registered, Ready Longhorn CSI on backend nodes; GKE Persistent Disk does not require Longhorn labels or CSI
- starts background `kubectl port-forward` to `VMAuth` on `127.0.0.1` and prints VMUI/targets URLs and the credentials Secret reference
- exposes VictoriaLogs UI/query through VMAuth (`/select/vmui/`, `/select/logsql/query`) so the same VMAuth username/password is required
- does not expose unauthenticated external `:9428` by default; remote logs access uses the VMAuth endpoint/port
- if `port-forward` is unavailable, starts a local `kubectl proxy` fallback and prints localhost VMUI/targets/query URLs via API proxy
- if port-forward is unavailable, public `NodePort` fallback stays disabled unless explicitly enabled with `VICTORIA_METRICS_NODEPORT_ENABLED=true`
- printed `*.svc` URLs are in-cluster only (usable from pods or `kubectl exec`), not direct host localhost URLs

Main environment overrides:
- `VICTORIA_METRICS_NAMESPACE`
- `VICTORIA_METRICS_STACK_NAME`
- `VICTORIA_METRICS_AUTH_USERNAME`
- `VICTORIA_METRICS_AUTH_PASSWORD`
- `VM_OPERATOR_VERSION`
- `VICTORIA_METRICS_OPERATOR_INSTALL_MANIFEST`
- `VICTORIA_METRICS_OPERATOR_NAMESPACE`
- `VICTORIA_METRICS_OPERATOR_DEPLOYMENT`
- `VICTORIA_METRICS_AUTH_PORT`
- `VICTORIA_METRICS_NODEPORT_ENABLED` (default `false`; opting in publishes VMAuth over HTTP on node ports, including Basic Auth credentials and log responses; use `kubeton logs expose` for an explicit dashboard port-forward)
- `VICTORIA_METRICS_AUTH_LOCAL_PORT_BASE`
- `VICTORIA_METRICS_PORT_FORWARD_ADDRESS`
- `VICTORIA_LOGS_ENABLED` (default `true`)
- `VICTORIA_LOGS_NAMESPACE`
- `VICTORIA_LOGS_RELEASE_NAME`
- `VICTORIA_LOGS_COLLECTOR_RELEASE_NAME`
- `VICTORIA_LOGS_RETENTION_PERIOD`
- `VICTORIA_LOGS_PVC_SIZE`
- `VICTORIA_LOGS_RETENTION_DISK_SPACE` (default `8GB`)
- `VICTORIA_LOGS_COLLECTOR_BUFFER_SIZE` (default `5GB` per node/destination)
- `VICTORIA_LOGS_COLLECTOR_CPU_REQUEST` / `VICTORIA_LOGS_COLLECTOR_CPU_LIMIT`
- `VICTORIA_LOGS_COLLECTOR_MEMORY_REQUEST` / `VICTORIA_LOGS_COLLECTOR_MEMORY_LIMIT`
- `VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_REQUEST` / `VICTORIA_LOGS_COLLECTOR_EPHEMERAL_STORAGE_LIMIT`
- `VICTORIA_LOGS_SINGLE_CHART_VERSION` (tested default `0.13.9`)
- `VICTORIA_LOGS_COLLECTOR_CHART_VERSION` (tested default `0.3.7`)
- `VICTORIA_LOGS_STORAGE_CLASS` (explicit class wins; otherwise uses an existing class named `longhorn`, then exactly one annotated Kubernetes default; missing or ambiguous defaults require an explicit override)
- `VICTORIA_LOGS_NODE_SELECTOR` (optional additional restriction for the
  backend; it is intersected with the fresh preflight-approved placement;
  inferred Longhorn selectors apply only to a Longhorn-backed PVC or planned
  Longhorn bootstrap)
- `VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR` (optional additional restriction for
  collectors; it is intersected with the fresh preflight-approved placement
  and can never restore rejected nodes)
- `VICTORIA_LOGS_PIN_TO_LONGHORN_CSI` (default `true`; verifies registered, Ready CSI nodes for Longhorn-backed storage; other backends retain fresh-preflight affinity without a Longhorn requirement)
- `VICTORIA_LOGS_NETWORK_POLICY_ENABLED` (default `true`; isolates the unauthenticated backend so only the kubeton collector and VMAuth can connect; requires enforcement by the cluster CNI)
- `VICTORIA_LOGS_CLEANUP_TIMEOUT_SECONDS` (default `300`; keeps backend ingress protection and cleanup state when uninstall cannot prove that logging workloads are gone)
- `VICTORIA_LOGS_PORT`

VMAuth and direct VictoriaLogs port-forwards default to loopback. Explicit
`VICTORIA_METRICS_PORT_FORWARD_ADDRESS` or `VICTORIA_LOGS_PORT_FORWARD_ADDRESS`
overrides can widen access. New defaults do not terminate old public
port-forwards or remove existing NodePort Services; audit and close previous
public access separately. `kubeton logs` only prints access instructions and
does not change Services, NetworkPolicies, credentials or running forwards.

</details>

### Cloud Install Options

For AWS/GCP/AliCloud, you can use any of these install paths:

- Cloud Shell (fastest): run the same release-pinned command above from AWS CloudShell, GCP Cloud Shell, or Alibaba Cloud Shell.
- CI/CD or bastion host: run `helm install/upgrade` from your deployment runner against the target kube-context.
- GitOps (recommended for production): use Argo CD or Flux with this chart and versioned values files.
- Terraform: use `helm_release` to install/upgrade declaratively.

Cloud provider dashboards can help create the cluster and open Cloud Shell, but this operator is not currently a managed one-click marketplace add-on. Installation is still done by Helm/kubectl.

### Install on Google Cloud (GKE)

Use **GKE Standard** with Linux/amd64 workers. For Longhorn, choose
**Ubuntu with containerd** (`ubuntu_containerd`) for the node pool. The current
TON deployment reserves fixed host ports, and Longhorn needs privileged host
access; the default Autopilot policies do not permit this setup. See
[GKE node images](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-images)
and [Autopilot restrictions](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security).

Size workers for at least **16 CPU and 64 GiB of free allocatable memory per
TON replica**, plus Kubernetes, Longhorn, Vault and logging overhead. A machine
with exactly 16 vCPU/64 GiB total will not have that much available to the Pod.
Each TON replica needs a different worker. The default Longhorn bootstrap also
requires at least three compatible workers for its three storage replicas.
Keep node preflight enabled; it checks resources, pressure, placement and host
ports before deployment.

**Connect and download the installer.** Run these commands in Google Cloud
Shell or an administration machine with `gcloud`, `gke-gcloud-auth-plugin`,
`kubectl`, Helm, Bash, Python 3 and OpenSSL installed. The account needs
permission to install CRDs, RBAC, workloads and the selected storage stack.
Replace the placeholders; `LOCATION` is the cluster's region or zone. See
[GKE cluster access](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl).

```bash
gcloud container clusters get-credentials CLUSTER_NAME \
  --location LOCATION --project PROJECT_ID
kubectl config current-context
kubectl get nodes -o wide
kubectl get storageclass

wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.5.10/install.sh" | bash
cd ton-k8s-operator-0.5.5
```

Review `operator-values.yaml` and `tonnode-values.yaml` before installing.
Set `tonNode.replicas`, keep the desired installation arguments (for example
`["-m", "validator", "-n", "mainnet", "-d"]`), and size `tonWorkSize` for the
database plus peak dump download/extraction space. The examples below change
only the shown fields; merge them into the existing `tonNode` section.
Complete the networking requirements below before running `kubeton start`,
particularly when deploying more than one replica.

**Storage layout.** Keep the validator database and dump files on GKE
Persistent Disk, and use Longhorn for encrypted key bundles. Vault's own
persistent state also uses Longhorn in the managed bootstrap. This follows the
same separation as bare metal, where TON data defaults to `local-path` and
encrypted key bundles use `encrypted-sc`.

| Data | GKE StorageClass | Configuration |
|---|---|---|
| TON database, public validator configuration and dump files | `premium-rwo` | `tonNode.storage.storageClassName` |
| Encrypted wallet/ADNL key bundles | `encrypted-sc` (Longhorn) | `tonNode.keyManagement.encryptedBundle.storageClassName` |

Enable the
[Persistent Disk CSI driver](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/gce-pd-csi-driver)
and choose a data class actually listed by `kubectl get storageclass`, such as
`premium-rwo` (SSD). Merge these settings into `tonnode-values.yaml`:

```yaml
tonNode:
  storage:
    storageClassName: premium-rwo
  keyManagement:
    enabled: true
    provider: vault
    credentialsSecretRef: ton-vault-creds
    vaultTransitKey: ton-validator
    encryptedBundle:
      storageClassName: encrypted-sc
```

<details>
<summary>GKE key management, Longhorn/Vault setup, networking and verification</summary>

**Prepare key management.** Longhorn's V1 engine needs `open-iscsi` with
`iscsid` running, the `iscsi_tcp` module, mount propagation, and an ext4/XFS
backing filesystem. Encrypted `encrypted-sc` volumes additionally need host
`cryptsetup` with Argon2i support. Verify these on every worker that will mount
or store a key-bundle volume; kubeton does not install host packages. See the
pinned version's
[Longhorn prerequisites](https://longhorn.io/docs/archives/1.10.0/deploy/install/)
and [GKE guidance](https://longhorn.io/docs/archives/1.10.0/advanced-resources/os-distro-specific/csi-on-gke/).

Ubuntu is the straightforward choice for this bootstrap. Longhorn 1.10.0 also
supports GKE Container-Optimized OS using an additional node-agent DaemonSet,
but kubeton does not install that agent, and some COS images need a different
encryption KDF from kubeton's `argon2i` default. Follow the
[Longhorn COS procedure](https://longhorn.io/docs/archives/1.10.0/advanced-resources/os-distro-specific/container-optimized-os-support/)
if choosing that route.

Provision persistent backing storage for key management and arrange for host
prerequisites, disk mounts and labels to be restored when GKE replaces or
upgrades a worker. Budget Longhorn replication, snapshots and rebuild headroom
for key bundles and Vault state separately from the large TON data disks.
Coordinate managed node upgrades with
[Longhorn's GKE maintenance procedure](https://longhorn.io/docs/archives/1.10.0/advanced-resources/support-managed-k8s-service/upgrade-k8s-on-gke/).

GKE advertises a cloud provider ID, so kubeton skips automatic bare-metal
bootstrap by default. For a **fresh** installation where you intentionally want
kubeton to provision Longhorn, encrypted storage and Vault, enable it explicitly:

```bash
export TON_STORAGE_CLASS_NAME=premium-rwo
export ENCRYPTED_SC_NAME=encrypted-sc
export VICTORIA_LOGS_STORAGE_CLASS=premium-rwo
export AUTO_BAREMETAL_BOOTSTRAP=true
export FORCE_BAREMETAL_BOOTSTRAP=true

./kubeton check
./kubeton install
./kubeton start   # installs/reuses Longhorn + encrypted-sc + Vault before TON
./kubeton backup-keys
```

The exports above remain active for every subsequent command in this shell.
If you prefer to prepare Longhorn and Vault before installing the operator,
run `./kubeton bootstrap-baremetal` after `check` and before `install`.
Prefixing only `install` with `FORCE_BAREMETAL_BOOTSTRAP=true` neither installs
these dependencies nor enables bootstrap for a later unprefixed `start`.

The bootstrap uses the same Longhorn/Vault workflow as bare metal, including
the default compatible-node selection and per-node CSI readiness checks.
Keep these environment selections for subsequent `check`, `start` and `add`
commands. `TON_STORAGE_CLASS_NAME` keeps TON data on GKE Persistent Disk;
`VICTORIA_LOGS_STORAGE_CLASS` also places log data there. Longhorn serves key
management storage rather than the validator database.

**GKE readiness and validation limits.** This path has code review and offline
regression coverage; it is not a completed installation test on your GKE
cluster. A successful `kubeton check` verifies Kubernetes resource/disk/placement
requirements, not every Longhorn host prerequisite. Before `start`, confirm
the Ubuntu workers have the iSCSI/encryption prerequisites above, enough
persistent space for Longhorn replicas, and policies permitting its privileged
host access. The invoking account needs CRD/RBAC/Secret/Helm permissions and
access to kubelet summary data (`kubectl auth can-i get nodes/proxy`). Private
clusters also need working access to the chart/image registries and required
TON network endpoints. The force flag opts into bootstrap; it does not prepare
worker operating systems, cloud disks, firewall rules or permissions.

Check control-plane access to Longhorn's conversion/admission webhooks as well.
Where the GKE firewall does not already allow it, permit TCP `9501` and `9502`
from the cluster's actual control-plane source range to the Longhorn workers;
keep these ports private. Otherwise API requests can time out even when the
Longhorn Pods are running. See [Longhorn networking](https://longhorn.io/docs/archives/1.10.0/references/networking/)
and [GKE webhook connectivity troubleshooting](https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/network-isolation#api_request_that_triggers_admission_webhook_timing_out).

Bootstrap stops on failed Longhorn setup/readiness, encryption Secret or
StorageClass creation, Vault startup, initialization/unseal or Transit
configuration. These checks surface installation failures; they do not imply
that arbitrary GKE configurations are guaranteed to work.

For **existing** Longhorn/Vault installations, keep their StorageClass names,
Vault Transit key and credentials. Prepare the credentials described below,
omit `bootstrap-baremetal`, and leave
`FORCE_BAREMETAL_BOOTSTRAP=false` unless you intend kubeton to manage those
dependencies. A healthy existing Longhorn deployment is reused without an
automatic Helm upgrade; kubeton does not automatically change selectors on
storage nodes that hold volumes.

For an existing Vault, provide a reachable, initialized and unsealed service
with a Transit key named
`ton-validator`. Its TON token needs `update` on
`transit/encrypt/ton-validator` and `transit/decrypt/ton-validator`; retain the
key's old versions for existing backups. Create `default/ton-vault-creds`
from a private environment file containing `VAULT_ADDR`, `VAULT_TOKEN`, and
optionally the Vault Enterprise `VAULT_NAMESPACE`:

```bash
# Prepare this file securely with your existing Vault connection details.
chmod 600 /secure/ton-vault.env
kubectl -n default create secret generic ton-vault-creds \
  --from-env-file=/secure/ton-vault.env

export TON_STORAGE_CLASS_NAME=premium-rwo
export ENCRYPTED_SC_NAME=encrypted-sc
export VICTORIA_LOGS_STORAGE_CLASS=premium-rwo
export FORCE_BAREMETAL_BOOTSTRAP=false

./kubeton check
./kubeton install
./kubeton start
```

The existing-infrastructure route requires Longhorn, `encrypted-sc` and Vault
to be ready. Wallet/ADNL bundles are encrypted with Vault and stored on
`encrypted-sc`. Google-managed disk encryption or a CMEK setting is an
additional infrastructure layer; neither replaces Vault Transit. The targeted
`restore-keys ... --to-node ...` recovery currently supports local-path and
Longhorn volumes; do not assume that workflow supports native GKE PD volumes.

With the storage-aware preflight, GKE PD and Longhorn data PVC sizes are not
charged against the worker's root filesystem. The local filesystem must still
pass the configured headroom and pressure checks. Local-path data continues to
require its full configured capacity plus headroom. VictoriaLogs selects an
available storage class and requires Longhorn CSI placement only when its own
PVC uses Longhorn; ordinary GKE PD logging does not require Longhorn labels.
Set `VICTORIA_LOGS_STORAGE_CLASS` if you want a specific log backend class.

**Networking and verification.** Public worker addresses are the simplest
starting point. Allow inbound UDP `30001` and `31001` to the TON workers in the
VPC firewall; open TCP `30003` only to the clients that need the lite-server.
Keep the validator console, Vault and unauthenticated logging backend private.
Private workers need per-replica public forwarding and an advertised address
that matches that forwarding; Cloud NAT alone does not provide inbound access.

For a single replica, the operator can use its worker's `ExternalIP`. For
multiple replicas, the current fallback is `status.hostIP`, which is normally
a private GKE address. Plan per-replica advertised public addresses before
funding wallets or enabling validation; one shared `network.publicIP` and the
same host ports are insufficient for several separately reachable validators.
Verify the generated validator addresses against the external mapping.

```bash
kubectl -n ton-k8s-operator-system get deployments,pods
./kubeton verify
./kubeton status
./kubeton logs
```

The monitoring stack is installed by `kubeton start`. Its local port-forwards
run on the machine executing kubeton; Cloud Shell is not a permanent public
dashboard host. Use the printed port-forward instructions or an authenticated
HTTPS access layer for ongoing access.
See [VictoriaLogs dashboard access](#victorialogs-dashboard-access) for the
exposure command and browser login credentials.

</details>

### Repo-Based Direct Deploy (advanced)

If you do use this repo directly, these `make` targets operate on your current `kubectl` context:

- `make install`: installs only CRD(s).
- `make deploy IMG=...`: deploys controller (RBAC + Deployment).
- `make undeploy`: removes controller resources.
- `make uninstall`: removes CRD(s).

Run them from repo root:
- this repository root directory (where `Makefile` is)

## Production TON Notes

- `PUBLIC_IP`: by default, for `replicas=1`, operator tries node `ExternalIP`, then falls back to node host IP. For multi-replica or private/NAT workers, set `spec.network.publicIP`.
- `hostPortsEnabled`: default is `true`. This is required for direct TON reachability on bare-metal/public-node setups (`validatorPort`, `quicPort`, `liteServerPort`).
- When `spec.network.publicIP` is empty, operator pins replicas to a preselected worker hostname set before first launch to avoid advertised-IP drift after pod restarts.
- New TON StatefulSets use Kubernetes `Parallel` pod management so all replicas can start at once. If `kubeton start` finds an older stopped StatefulSet using immutable `OrderedReady` policy, it recreates that StatefulSet while replicas are `0`; PVCs are retained and reused.
- Private cloud workers (no public node IP): provide per-node/per-replica public forwarding; one shared LB endpoint/port pair is not sufficient for many TON replicas.
- Storage class: explicitly set `spec.storage.storageClassName` when you need deterministic storage behavior.
- Bare metal: `kubeton start` sets TON data storage to `TON_STORAGE_CLASS_NAME` by default (`local-path`); set `TON_STORAGE_CLASS_NAME=<class>` to use another local class or `TON_STORAGE_CLASS_NAME=auto` to use operator auto-detection.
- Operator auto-detection prefers known local classes (`local-path`, `local-storage`, `openebs-hostpath`, `hostpath`), then Longhorn, then the default StorageClass.
- If no StorageClass exists in the cluster, `TonNode` will stay `Ready=False` with reason `StorageClassMissing`.
- `tonnode-values.yaml` keeps the upstream CPU/RAM requirement check enabled. The chart's base `values.yaml` includes `-i` for lab startup; remove that flag to enable the upstream check there too. `kubeton check` independently verifies Kubernetes capacity.
- Right-size resources in `spec.resources` for TON fullnode/validator workloads.

### How TON Storage Is Placed

Data from all TON pods is not stored in one shared place.

<details>
<summary>Per-replica volumes, local-path placement and storage cleanup</summary>

With this operator setup:
- Each TON pod gets its own data PVCs (`ton-work-...`, `ton-src-...`, `mytoncore-...`, and `mytonctrl-...`).
- With `spec.keyManagement.enabled: true`, `/var/ton-work/controller`, node keys and `/var/ton-work/db/keyring` use tmpfs, restored from encrypted checkpoints on the `keybundle` PVC. This includes `mytoncore.db`, wallets and MyTonCtrl console data.
- Public `/var/ton-work/db/config.json`, blockchain data and dump files remain on `ton-work`. With key management disabled, controller state and key files also persist directly there.
- The `ton-src`, `mytoncore` and `mytonctrl` PVCs are retained for compatibility/recovery, and are no longer runtime mounts. TON executables and Fift resources come from the selected official TON image and are refreshed by the init containers on pod creation.
- `/usr/bin/ton` and `/usr/src/ton/crypto` are compatibility links created by the MyTonCtrl entrypoint to its private `/run/ton-active` snapshot.
- PVCs are `ReadWriteOnce`, so one PVC is attached to one pod.
- For 20 replicas with encrypted key management enabled, the total PVC count is 100.
- `tonWorkSize` defaults to `700Gi` for the local-path lab setup. Dump bootstrap may require substantially more at runtime because the compressed archive and extracted database coexist. `kubeton check` deliberately trusts the configured `tonWorkSize`; increase it to the expected peak before starting when more space is required.

If you use `local-path` StorageClass:
- Data is written to the local disk on the node where that pod volume is provisioned.
- Storage is distributed across nodes/pods, not centralized.
- If a node is lost, data tied to that node-local volume is also lost (unless you use replicated storage such as Longhorn).
- `kubeton drop` and `kubeton uninstall` purge exact, verified local-path backing directories for the PVCs they remove. This works with a custom local-path root such as `/home/danklishch/state-200gb-b5`; it is not limited to `/opt/local-path-provisioner`.
- For Rancher local-path PVCs from older provisioner/controller versions, cleanup can safely use the PV's `local.path.provisioner/selected-node` provenance when hostname affinity is absent or does not uniquely resolve every selector term. It still requires that exact node to exist and rejects a fully-resolved affinity/provenance disagreement; it never guesses from a filesystem path or fans cleanup out across nodes.
- before PVC deletion, a cleanup-ledger ConfigMap records the PV/PVC UIDs, exact local host path when applicable, and Longhorn's CSI volume handle/UID when applicable. The ledger is deleted only after the host path and supported backing volume are verified gone. If cleanup cannot run, `kubeton uninstall` returns non-zero and a rerun uses the ledger without needing the original PVC/PV.
- If an explicit `kubeton uninstall` or `kubeton drop` can record a TON PVC's immutable PV/PVC identity but cannot prove its local-path owning node, it clears that *unmounted PVC object's* finalizers so the claim cannot block teardown. It does not guess at the host directory or force-delete the PV; the unresolved storage record remains in the ledger and the command exits non-zero for manual reconciliation. The provisioner may independently honor a `Delete` reclaim policy after the PVC is removed, but kubeton does not claim that unverified host data was purged. A PVC with no durable identity record, or one still referenced by any pod, is never force-deleted.
- `LOCAL_PATH_PROVISIONER_ROOT` is only needed for the optional wildcard fallback. `KUBETON_LOCAL_PATH_PATTERN_CLEANUP=true` may remove old, untracked directories by PVC-name pattern and is appropriate only in an isolated kubeton-owned cluster. Unknown historical directories without a PVC/PV or cleanup ledger cannot be safely attributed by default.
- set `KUBETON_LOCAL_PATH_CLEANUP=false` to opt out of host cleanup. Local-path PVs then remain as an unresolved ledger item (and uninstall exits non-zero) rather than silently deleting unverified host data; CSI PV retry records are still retained. The ledger is stored in `kube-system` by default, because it is an authorization boundary for privileged node cleanup. The invoking identity needs read/write/delete access to that ConfigMap. Use `KUBETON_LOCAL_PATH_CLEANUP_LEDGER_NAME` and `KUBETON_LOCAL_PATH_CLEANUP_LEDGER_NAMESPACE` only when you need fixed ConfigMap placement for auditing or RBAC; choose an existing admin-only namespace that `kubeton uninstall` does not remove.

</details>

<details>
<summary>Local Development and Testing (k3d)</summary>

## Local Development and Testing (k3d)

**Local prerequisites:**

- Go installed (project currently scaffolds with controller-runtime/Kubebuilder tooling that may use Go toolchain auto-download).
- Docker
- kubectl
- Helm 3
- k3d (or another Kubernetes cluster)

Use this workflow for local development from this repository.

Production deployments should use release artifacts/charts, not this dev-repo flow.

The test environments cover different behavior:

- `make test-kubeton` runs CLI regression tests with synthetic files and mocked
  Kubernetes responses. StorageClass query tests also run the actual `kubectl`
  renderer against an isolated local HTTP API fixture with an empty kubeconfig.
  It does not start containers or modify a Kubernetes cluster.
- `make test-main-wallet-runtime` uses the published TON Docker image with real
  Fift signing and synthetic keys on temporary container filesystems. Network
  access is disabled and only RPC/HTTP responses are mocked. It checks ACK
  without inclusion, identical-message rebroadcast, exact payment receipts and
  sequential sends. Docker is required; `TON_RUNTIME_TEST_IMAGE` overrides the
  default image. It neither starts Kubernetes nor sends a real transaction.
- `make test` also runs Go unit tests and `envtest`, which starts local
  `kube-apiserver` and `etcd` processes. This checks Kubernetes API behavior but
  does not run a scheduler, kubelet, or application containers.
- The workflow below runs actual containers in k3d. Its Kubernetes nodes are
  Docker containers, with TON pods running inside those nodes. The separate
  `make test-e2e` target currently expects a disposable **Kind** cluster; it is
  not the k3d workflow.

For example, run the deletion confirmation checks without a cluster:

```bash
bash test/kubeton_del_test.sh
```

For actual container testing, build and import the operator image with
`./devrun.sh`, then deploy it with `kubeton install` and `kubeton start` as below.
An image build or a passing mocked test does not demonstrate successful pod
scheduling, storage provisioning, or TON synchronization. k3d also uses the
local `encrypted-sc` development fallback rather than Longhorn disk encryption;
test production Longhorn behavior separately. Several k3d nodes still share
one machine's CPU, memory, disk, and public IP.

Prerequisites:
- `k3d`
- `docker`
- `kubectl`
- `helm`
- `make`

Create a local k3d cluster (example with 3 agent nodes):

```bash
k3d cluster create --agents 3 --api-port 127.0.0.1:6550
kubectl config current-context
kubectl get nodes -o wide
```

Drop the whole k3d cluster:

```bash
# if using the default cluster name
k3d cluster delete
```

### Flow A: Maintainer (local build and test)

Run from the repository root:

```bash
./devrun.sh
```

`devrun.sh` executes:
- builds local operator image (`OPERATOR_IMG`, default `ghcr.io/neodix42/ton-k8s-operator:dev-local`)
- generates `dist/install.yaml`
- if the current cluster is `k3d`, imports the image into that cluster (`K3D_CLUSTER_NAME` can override autodetection)
- updates `charts/ton-k8s-operator/operator-values.yaml` `image.repository` and `image.tag` to match `OPERATOR_IMG`

`kubeton` is included in:
- `charts/ton-k8s-operator/kubeton`

Deploy operator and TON nodes:

```bash
cd charts/ton-k8s-operator

# operator only
./kubeton check
./kubeton install

# operator + TON nodes (uses tonnode-values.yaml defaults)
./kubeton start

# operator + TON nodes (replicas from tonnode-values.yaml)
./kubeton start
```

On k3d, `./kubeton start` automatically bootstraps Vault and StorageClass `encrypted-sc` (local fallback) if missing.

Verify:

```bash
./kubeton verify
```

Stop and cleanup local dev deployment:

```bash
cd charts/ton-k8s-operator
./kubeton stop
./kubeton drop

# safe cleanup (keeps TonNode CRD)
# full best-effort cleanup of kubeton-managed resources
./kubeton uninstall

# OR full destructive cleanup (includes TonNode CRD)
# separated from uninstall because CRD deletion is cluster-scoped
./kubeton purge
```

### Upgrade Workflow (When Image Changes)

Use the dedicated scripts to update the operator release or an individual runtime image:

```bash
# A) Operator release (bumps operator + chart versions; keeps both TON runtime image tags unchanged)
./upgrade-ton-operator.sh 0.3.1

# B) Update only the MyTonCtrl image tag
./upgrade-mytonctrl-only.sh v1.0.0

# C) Update only the official TON image tag
./upgrade-ton-image-only.sh v2026.08-amd64
```

The image helpers update only their corresponding image tag in the chart values files. They leave chart and operator versions and installer release URLs unchanged.

To apply image changes to an existing fleet, edit `tonNode.image` and/or
`tonNode.tonImage` in the local `tonnode-values.yaml` (or `TON_VALUES_FILE`), then run:

```bash
./kubeton upgrade
```

This targets `tonNode.namespace`/`tonNode.name` and patches only changed image
fields, preserving other configuration and the deployed replica count. It
refreshes encrypted backups before replacing initialized pods. Stopped fleets
remain stopped. If the deployed images already match, it prints
`Nothing to upgrade.`; rerunning during a pending rollout resumes waiting.
`KUBETON_UPGRADE_TIMEOUT_SECONDS` sets the total reconciliation and rollout wait
(default `1800`).

Changing either image recreates pods. Their init containers export the official
TON binaries before MyTonCtrl starts, including after a MyTonCtrl-only change:
the exported artifacts belong to each pod, so the same TON image is exported
again. MyTonCtrl runs the exported TON binaries within its pod.

<details>
<summary>Release publishing, manual Helm upgrades, rollback and uninstall</summary>

For an operator/chart release, commit and push the versioned changes:

```bash
# commit + push to main
git add .
git commit -m "release: 0.3.1"
git push origin main
```

`publish-operator.yml` will then publish:
- operator image (for operator releases): `ghcr.io/neodix42/ton-k8s-operator:<appVersion>`
- chart: `oci://ghcr.io/neodix42/charts/ton-k8s-operator:<chart-version>`
- release asset: `install.sh` on GitHub Release `<chart-version>`

Installer URL in docs always uses chart version:

```bash
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/<chart-version>/install.sh" | bash
```

Cluster upgrade workflow:

```bash
# fetch new release installer and chart
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.5.10/install.sh" | bash
cd ./ton-k8s-operator-0.5.5

# review values before upgrade
cat operator-values.yaml
cat tonnode-values.yaml
```

Upgrade operator only:

```bash
kubectl apply -f crds/ton.ton.org_tonnodes.yaml
kubectl wait --for=condition=Established crd/tonnodes.ton.ton.org --timeout=60s
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  --rollback-on-failure --wait --timeout 20m
```

Upgrade operator and TON nodes:

```bash
kubectl apply -f crds/ton.ton.org_tonnodes.yaml
kubectl wait --for=condition=Established crd/tonnodes.ton.ton.org --timeout=60s
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --rollback-on-failure --wait --timeout 40m
```

To update MyTonCtrl or TON independently, keep the operator version and set the corresponding image explicitly:

```bash
kubectl apply -f crds/ton.ton.org_tonnodes.yaml
kubectl wait --for=condition=Established crd/tonnodes.ton.ton.org --timeout=60s
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/neodix42/mytonctrl:<mytonctrl-tag> \
  --set-string tonNode.tonImage=ghcr.io/ton-blockchain/ton:<ton-tag> \
  --rollback-on-failure --wait --timeout 40m
```

Monitor rollout:

```bash
kubectl -n ton-k8s-operator-system rollout status deploy/ton-k8s-operator-controller-manager --timeout=10m
kubectl -n default rollout status sts/tonnode --timeout=40m
kubectl -n default get tonnodes
kubectl -n default get pods -l app.kubernetes.io/name=ton-node -o wide
kubectl -n ton-k8s-operator-system logs deploy/ton-k8s-operator-controller-manager --tail=200
kubectl -n default get events --sort-by=.lastTimestamp | tail -n 40
```

Rollback:

```bash
# find previous revision
helm history ton-k8s-operator -n ton-k8s-operator-system

# rollback release (operator + tonnode manifests managed by Helm)
helm rollback ton-k8s-operator <REVISION> \
  -n ton-k8s-operator-system \
  --wait --timeout 20m
```

Image-specific rollback (when needed):

```bash
# rollback operator image tag explicitly
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  --set image.tag=<old-version> \
  --rollback-on-failure --wait --timeout 20m

# rollback MyTonCtrl and TON artifact images explicitly
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/neodix42/mytonctrl:<old-mytonctrl-tag> \
  --set-string tonNode.tonImage=ghcr.io/ton-blockchain/ton:<old-ton-tag> \
  --rollback-on-failure --wait --timeout 40m
```

Change TON replica count later:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set tonNode.replicas=23
```

Check resources:

```bash
kubectl get tonnodes -A
kubectl get pods -A -l app.kubernetes.io/name=ton-node
kubectl get pvc -A
```

If pods are not created, inspect status and events:

```bash
kubectl get tonnode tonnode -n default -o yaml
kubectl describe tonnode tonnode -n default
kubectl get events -n default --sort-by=.lastTimestamp | tail -n 30
```

Uninstall Helm release:

```bash
helm uninstall ton-k8s-operator -n ton-k8s-operator-system
```

Complete Helm cleanup (optional):

```bash
# remove release
helm uninstall ton-k8s-operator -n ton-k8s-operator-system

# remove operator namespace
kubectl delete namespace ton-k8s-operator-system

# remove CRD (destructive: removes all TonNode resources)
kubectl delete crd tonnodes.ton.ton.org
```

Note: CRDs installed from Helm `crds/` are not removed by `helm uninstall`.
Raw `helm uninstall` also cannot run kubeton's retryable PVC/PV cleanup or its
privileged node-local storage cleanup. Use `./kubeton uninstall` when TON
storage must be removed.
If you want to remove CRD too (destructive, removes `TonNode` objects):

```bash
kubectl delete crd tonnodes.ton.ton.org
```

For `kubeton`-based full destructive cleanup (including CRD), use:

```bash
./kubeton purge
```

`kubeton purge` includes uninstall of kubeton-managed resources, then deletes
the TonNode CRD. Cleanup failures or shared infrastructure that cannot safely
be removed are reported; rerun the updated CLI after resolving them.

</details>

### Alternative: Run Controller On Host (`make run`)

`make run` starts the operator manager process on your local machine (not as a Pod in Kubernetes).

It uses your current `kubectl` context and watches/reconciles resources in that cluster.

```bash
make generate manifests
make test
make install
make run
```

In another terminal:

```bash
kubectl apply -f config/samples/ton_v1alpha1_tonnode.yaml
kubectl get tonnodes
kubectl get pods -l app.kubernetes.io/instance=tonnode -o wide
kubectl get pvc
```

Stop local run:
- Stop `make run` with `Ctrl+C` in the terminal where it is running.

Cleanup host-run resources:

```bash
kubectl delete -f config/samples/ton_v1alpha1_tonnode.yaml --ignore-not-found
make uninstall
make undeploy
kubectl delete pvc -l app.kubernetes.io/name=ton-node
```

</details>

## Optional configRef Secret Example

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ton-config
type: Opaque
stringData:
  config.json: |
    { ... }
```

Then reference it:

```yaml
spec:
  replicas: 1
  configRef:
    name: ton-config
```

## Key and Secret Strategy

Each replica stores TON state in per-pod PVCs and generates keys on the first start.

With `spec.keyManagement.enabled: true` (the default in `tonnode-values.yaml`):
- controller state, node keys, wallet files and validator keyring are plaintext in tmpfs; backup and restore staging also uses memory
- an encrypted recovery bundle persists on the dedicated `keybundle` PVC and is restored before TON starts
- `key-backup` checks for changes about every two seconds and automatically updates encrypted checkpoints, including resumable partial initialization; readiness requires an encrypted bundle
- managed shutdown quiesces services and requests a final checkpoint; manual backup and managed image-upgrade requests also refresh the bundle
- `kubeton wallet ...` runs in a separate ephemeral pod with its own encrypted bundle PVC; it is intentionally excluded from `kubeton status` and `kubeton backup-keys` flows
- when the wallet bundle PVC uses Longhorn storage, `kubeton wallet ...` pins the helper pod to nodes exposing `driver.longhorn.io` (from `CSINode`) to avoid attach failures on non-Longhorn nodes

<details>
<summary>Key backup, restore, scaling and cleanup behavior</summary>

Encryption applies to managed recovery bundles, not the whole `ton-work` PVC.
The standard managed secret paths use `emptyDir{medium: Memory}`:

| Live path | Default memory-volume limit | Setting under `keyManagement.inMemory` |
|---|---|---|
| `/var/ton-work/controller` | `512Mi` | `controllerSizeLimit` |
| `/var/ton-work/keys` | `128Mi` | `keysSizeLimit` |
| `/var/ton-work/controller/mytoncore/wallets` | `512Mi` | `walletsSizeLimit` |
| `/var/ton-work/db/keyring` | `128Mi` | `keyringSizeLimit` |
| `/tmp` | `2Gi` | `stagingSizeLimit` |
| `/run` | `2Gi` | `stagingSizeLimit` |

Controller databases, their local backup files, wallet `.pk` files, service
settings and validator private keys therefore use memory during normal managed
operation. Plaintext backup archives, decrypted archives and signing scratch
files also remain in memory. The main-wallet helper has its own memory-backed
runtime and `/tmp`; its staging explicitly stays under the runtime directory.
Required memory mounts and disabled worker swap are checked before secret
operations, and managed entrypoints disable core dumps. A missing mount or
active swap fails closed instead of falling back to a writable disk layer.

Blockchain data and `/var/ton-work/db/config.json` stay on `ton-work`.
The validator configuration contains advertised addresses and key identifiers,
not the corresponding private signing keys. Its storage-layer encryption is
independent of bundle encryption. With key management disabled, none of the
memory-only secret-path protections apply.

Memory limits are ceilings, not reservations. Budget worker and container
memory for the live state, `/run` TON artifact snapshot, and temporary copies
used by compression, encryption and verification. A large controller directory
or backup can exceed its memory limit; adjust the settings and resource budgets
before rollout.

When upgrading a current native MyTonCtrl deployment, the restore init container
copies known plaintext `ton-work/controller`, `keys` and `db/keyring` contents
into memory. An existing encrypted bundle first supplies wallets and console
keys that earlier versions already kept only in RAM; current persistent
controller settings are then merged into that state. Conflicting private files
stop migration and preserve both sources for explicit recovery. It creates an encrypted checkpoint and verifies real provider
unwrap and archive decryption before unlinking those known originals. Failed
encryption or verification preserves the original files and stops startup.
A durable `.historical-plaintext-exposure` marker records that old plaintext
existed and produces a startup warning. Legacy `ton-docker-ctrl` layouts remain
blocked and preserved.

Unlinking live files is **not secure erasure** of old blocks, snapshots or
backups. Deprecated PVCs and other historical copies are not automatically
wiped. If historical plaintext must be eliminated, recover onto fresh storage
and arrange secure retirement or sanitization of the old volumes, snapshots
and backups through the storage provider.

Before adopting this layout, take and verify an external encrypted backup,
retain the Vault/KMS root of trust, disable swap on eligible workers, and budget
the additional memory. Deploy the updated operator and bundled CRD, then apply
the desired TonNode values with the matching `kubeton start`; use the same
release's CLI and chart. Existing Pods receive the new mounts on replacement.
Back up again after the rollout. Updating only the CLI does not change live
Pod mounts.

Checkpoints are not synchronous writes of every change. Snapshot duration,
provider outages and continually changing state can delay completion. Graceful
shutdown attempts a final quiescent checkpoint, but abrupt node loss, forced
termination or a crash can lose changes since the last successful checkpoint.
The interval between generating a new key and its first completed checkpoint
also remains a recovery risk; keep current off-cluster backups.

This protection covers the standard managed runtime paths. Kubernetes
credentials in Secrets/etcd, Vault's own storage, application logs,
administrator-directed plaintext exports and optional services with other key
paths need their own controls. Privileged administrators can still read live
memory or mounted keys. See [SECURITY.md](SECURITY.md) for the trust boundaries.

Manual encrypted bundle backup is available with:
- `./kubeton backup-keys [output-dir]`
- `./kubeton stop` scales TON StatefulSets and kubeton-managed Prometheus/Grafana Deployments to `0`, retaining TON resources/PVCs and dashboard configuration/credentials; it also stops their local port-forwards and waits for controlled Pods to terminate
- `./kubeton start` restores TON replicas and previously paused managed dashboards from stop metadata (and also performs normal start/upgrade flow when no stop metadata exists); VictoriaLogs, VictoriaMetrics, Vault and Longhorn remain running during a stop
- TON StatefulSets are created with parallel pod management; `kubeton start` restores stopped replicas in parallel after preapplying saved node placement metadata. Set `KUBETON_SEQUENTIAL_TON_START=true` only as a compatibility fallback.
- stop-time backup is skipped by default; enable it with: `SKIP_STOP_KEY_BACKUP=false ./kubeton stop`
- restore from a backup directory with `./kubeton restore-keys <input-dir>` (overwrites encrypted bundle PVC content and restarts TON pods)
- per replica (default names):
- `<output-dir>/<namespace>/<statefulset>/<ordinal>/bundle/keys.bundle.enc`
- `<output-dir>/<namespace>/<statefulset>/<ordinal>/bundle/keys.bundle.meta`
- `<output-dir>/<namespace>/<statefulset>/<ordinal>/SHA256SUMS`
- `keys.bundle.enc` is an encrypted tar archive containing all files from pod paths:
- `/var/ton-work/keys/**` (for example: `client.pub`, `liteserver.pub`, `client`, `server.pub`)
- `/var/ton-work/db/config.json`
- `/var/ton-work/db/keyring/**`
- `/var/ton-work/controller/**` (initialization marker, controller databases, wallets, network configurations, service units and enabled-service state)
- `keys.bundle.meta` contains bundle metadata: `provider`, `wrapped_key`, `algorithm`, `created_at`
- TON DB data outside this set (for example `/var/ton-work/db/celldb/**`, `/var/ton-work/db/archive/**`) is not part of this key bundle backup.
- if `spec.keyManagement.encryptedBundle.fileName` or `metaFileName` is customized, exported filenames follow those values.

In-cluster persistence is automatic with key management enabled.
`key-backup` checkpoints changed controller/key state, including resumable
partial initialization, and readiness requires an encrypted recovery bundle.
The sidecar checks about every two seconds; a change is durable only after its
checkpoint succeeds. Manual `backup-keys` exports still require complete
initialization. Automatic checkpoints remain in the cluster and do not replace
the mandatory external export after `kubeton start`.

Manual backup is still needed for a current external/off-cluster copy:

- Run `./kubeton backup-keys [output-dir]` after initial setup to refresh the
  in-cluster bundle and export a copy to the machine running kubeton.
- Run it again after creating wallets, changing or rotating keys, or changing
  recovery-relevant configuration, before maintenance or destructive operations.
- The command temporarily stops and restarts the TON fleet while exporting;
  move its output outside the cluster for off-cluster recovery.

`kubeton upgrade` refreshes the in-cluster bundle before replacing initialized
pods for image changes, but does not export a copy. `kubeton stop` skips the
explicit pre-stop backup by default; `SKIP_STOP_KEY_BACKUP=false` enables that
extra in-cluster refresh. Managed Pod shutdown still attempts its final
quiescent checkpoint. None of these mechanisms exports an external backup.

Exported `backup-keys` bundles still require the original Vault Transit key or
cloud KMS key to decrypt. Before deleting that root of trust, use
`backup-fleet` for portable recovery of a supported Vault-backed fleet.

Restore prerequisites:
- `./kubeton restore-keys <input-dir>` automatically scales TON StatefulSets to `0`, restores available replica bundles, then scales back to previous replica counts.
- An ordinary Pod replacement restores controller state, keys, wallets and keyring from the latest successful encrypted checkpoint, including a resumable partial initialization when present. An explicit `restore-keys` or `recreate` verifies uploaded bytes, then records `.restore-controller-state` on the encrypted bundle PVC so startup replaces controller state, validator configuration and keyring together from that selected bundle. The request is removed only after restoration succeeds; a failed restoration keeps it for retry.
- Interrupted encrypted-bundle publication leaves a `.backup-publish` journal; run or restart `key-backup` to recover it before exporting a backup, and export again rather than restoring a directory that still contains that journal.
- if the backup directory is missing for some replica ordinal, restore reports it and continues with other replicas.
- If a replica restore fails (for example, checksum verification, missing PVC, or upload failure), `restore-keys` restores the previous replica counts and operator reconciliation, prints the restore summary, and exits non-zero without printing a completion message. Missing backup directories remain reported skips.
- for one-by-one scaling, use:
- `./kubeton add` to add one replica.
- `./kubeton del` to remove one replica; it always removes the highest ordinal (tail) pod and does not accept a pod name.
- encrypted bundles can be decrypted only if the same root-of-trust is still available:
- Vault mode: same Vault Transit key history/material (same logical key with old versions available).
- KMS mode: same cloud KMS key resource still exists and is usable for decrypt.
- `kubeton drop` removes TON resources/PVCs, verified local-path backing directories, and supported CSI/Longhorn backing volumes.
- `kubeton uninstall` removes TON resources/PVCs, verified local-path backing directories, supported CSI/Longhorn backing volumes, managed Prometheus/Grafana/VictoriaMetrics/VictoriaLogs resources, helpers and operator resources. It also removes eligible Vault/Longhorn releases, their generated cluster resources and namespaces, and the unused `encrypted-sc` StorageClass. Shared or still-used infrastructure is preserved and reported; the TonNode CRD is kept.
- for an explicit `kubeton uninstall` or `kubeton drop`, legacy TON claim-template names are also recognized when their ownership labels are missing. This covers all per-ordinal claims, including `mytoncore-...`, so a partial `mytoncore.db` cannot survive a successful cleanup merely because it was created by an older controller. The fallback is limited to an exact configured or captured TON StatefulSet claim-template identity; it does not delete PVCs merely because they share a prefix.
- before deleting a PVC, `kubeton` stores the bound PV/PVC UIDs; local-path host paths and Longhorn CSI volume handles are recorded as well. A later `./kubeton uninstall` can therefore retry storage cleanup even after Kubernetes has deleted the PVC object.
- if Kubernetes is still terminating resources or a cleanup step errors, `kubeton uninstall` continues with the remaining steps, reports leftovers, and exits non-zero rather than claiming completion while a cleanup ledger remains. Ordinary `uninstall` and `drop` preserve `Retain` storage. Static or unverifiable backing storage also remains protected. Rerun the command after resolving the reported issue.
- VictoriaMetrics cleanup uses recorded stack/operator identities across namespaces, removes their generated child workloads and RBAC, and retains its ledger after a failed deletion. Its shared operators/CRDs and non-empty shared namespaces are preserved. Vault namespace ownership, Longhorn PVC/PV/backend users and encrypted StorageClass users are checked before removing those dependencies.
- Longhorn cleanup runs the chart's uninstall hook first, then removes residual Longhorn resources, cluster-scoped CRDs/RBAC/StorageClasses/CSI configuration/webhooks, and the namespace. Generated workloads such as engine-image pods can lack Helm labels; their same-namespace owner references are verified against the parents' exact UIDs. Deleting only `longhorn-system` does not remove cluster-scoped resources. If another workload or volume still uses Longhorn, cleanup reports it and preserves the installation.
- `kubeton purge` runs full uninstall, removes verified retained TON recovery volumes for the configured fleet, and deletes CRD `tonnodes.ton.ton.org`. Its confirmation explicitly includes those retained recovery copies. Targeted `restore-keys ... --to-node ...` deliberately leaves old PVs with `Retain`; several old PVs can therefore refer to different lifetimes of the same claim name. Purge checks each PV/PVC UID and backing volume separately, records its exact identity before deletion, and preserves that record if cleanup needs a retry. Legacy-volume recovery refuses adoption while a same-name PVC still exists, and protects mounted or shared storage, foreign ownership, static volumes and Helm `keep` resources. Repeated claim names alone do not block cleanup, and rejection messages identify the field or check that prevents deletion.
- if Vault is reinitialized or Vault data is lost, old bundles become undecryptable even if key name is reused.

`kubeton add` checks one additional, unoccupied worker against the live
StatefulSet's CPU, memory, storage, host ports, selectors, and retained volume
placement. Reusing Vault and StorageClasses does not skip that check. It can
extend kubeton's managed placement labels on an approved worker while retaining
the labels on existing workers. Explicit selectors and manually disabled storage
labels remain constraints. Longhorn-backed claims also require the selected
worker's CSI plugin to become ready before scaling.

After applying placement and the replica count and restoring operator
reconciliation, `kubeton add` returns immediately without waiting for the new
TON pod to become Ready. It reports that startup has been initiated on the
selected worker; initialization and blockchain synchronization continue in the
background. Use `./kubeton status` and `./kubeton logs <node>` to follow progress,
then run `./kubeton backup-keys` after the new keys have been generated.

If an earlier add left an unassigned Pending tail such as `tonnode-5`, retrying
`kubeton add` resumes that replica without increasing the count to seven. The
command refreshes placement and recreates only that unscheduled tail pod. It
retains every existing PVC, including an already-bound encrypted key bundle.
For a new ordinal, Kubernetes creates claims from the current StatefulSet
templates; `add` does not clone old PVC settings or delete retained volumes.
`WaitForFirstConsumer` claims normally remain Pending until the pod is scheduled,
and an unscheduled pod has neither a node nor a pod IP.

This fix requires the updated operator image as well as the updated CLI. The
operator preserves existing validators during placement-only growth using
`OnDelete`; an intentional non-replica TonNode spec change, such as an image
upgrade, restores rolling updates. Operator-only installs preserve the live
TON replica count, including counts previously changed by `add` or `del`.
To recover an unfinished add from an older release, use the updated release
bundle with its updated operator image configured, then run:

```bash
# Upgrade the operator without requalifying disk capacity on existing replicas.
KUBETON_SKIP_NODE_PREREQ_CHECK=true ./kubeton install
./kubeton add
```

`add` still performs fresh admission for the extra worker. If no worker passes,
it reports the failed prerequisites before changing replica counts or PVCs.

`kubeton del` inventories every wallet on the tail pod, including address-only
wallets, and displays its on-chain status and balance without reading private
key contents. A positive balance or an existing non-empty account state requires
an additional confirmation. Failed queries, an unavailable pod, or an incomplete
wallet inventory produce a separate unknown-balance warning and confirmation;
they are never treated as empty wallets.

Before any scale-down or storage deletion, `del` also asks whether you have a
current backup of that pod's keys and wallets stored outside the cluster, then
asks for final approval of the deletion. Answering `n`, pressing Enter, or
closing input cancels. Backup confirmation is your acknowledgement; the command
does not verify a backup archive. Use `./kubeton backup-fleet <backup-dir>` for
portable recovery, or `./kubeton backup-keys <backup-dir>` while retaining the
original Vault/KMS key. If the fleet count or tail pod identity changes
during the checks, `del` aborts so that a fresh run can inspect the new target.

`configRef` safety rule remains: `spec.configRef` is allowed only with `replicas=1`.

</details>

### Recovering one damaged validator on a replacement server

Use a server name, pod name, or namespace/pod to recover one validator whose
blockchain database is damaged:

```bash
# Select a compatible free server automatically.
./kubeton restore-keys devnet-16

# Select the replacement server explicitly.
./kubeton restore-keys tonnode-2 --to-node devnet-21

# Use a previously exported backup for this ordinal instead of the live bundle.
./kubeton restore-keys default/tonnode-2 ./key-backups/20261027T120000Z --to-node devnet-21
```

<details>
<summary>Single-validator recovery behavior, requirements and failure handling</summary>

The selected validator keeps its pod name and ordinal. Recovery checks the
replacement's live resource, storage, selector, host-port, and Longhorn CSI
requirements. By default it triggers a fresh backup on only the selected pod
and captures its committed encrypted bundle. An explicit backup directory must
contain that ordinal's bundle and matching `SHA256SUMS`; it restores the keys
and wallets captured at that backup's date.

Before replacing storage, a temporary helper decrypts and validates the bundle
using the existing Vault key. It preserves wallet key/address files, validator
and ADNL keys, the controller database, and node configuration. Only advertised
IPv4 addresses in `config.json` and the validator service's `--ip` endpoint are
rebound to the replacement server. Plaintext and unwrapped keys remain in the
helper's memory-backed volumes. The original encrypted backup remains intact.

Recovery pauses the operator and temporarily removes the StatefulSet controller
with orphan propagation, so sibling pods keep running. It stops only the
selected pod, retains its original backing PVs, creates fresh claims from the
live templates, and stages the verified identity before recreating the
StatefulSet. The recreated workload uses `OnDelete`, and recovery verifies that
the sibling pod UIDs were retained and adopted before restoring the operator.
The replacement initializes and synchronizes in the background; follow it with
`./kubeton status` and `./kubeton logs tonnode-2`.

Recovery preserves the TonNode's installation arguments and container
environment. If dump download was enabled with `-d` in `spec.args` or
`MYTONCTRL_ARGS`, or with `DUMP=true`, a `restore-node-bootstrap` init container downloads and imports the
dump before starting the validator. It uses the restored `global.config.json`
to select the network, keeps wallet/ADNL keys, `config.json`, and controller
settings, and resumes an interrupted download or extraction on retry. The
command returns without waiting for the dump or blockchain synchronization.
Without dump download enabled, the replacement synchronizes normally. Inspect
dump progress with `kubectl -n default logs tonnode-2 -c restore-node-bootstrap -f`.
Upgrade the operator with `./kubeton upgrade` before using this recovery path
on an older installation. Recovery checks that the running operator supports
the bootstrap init before changing storage, so a recreated Pod can also resume
an unfinished import.

This path requires a single live TonNode fleet with automatic sticky placement,
Vault key management, dynamic local-path or Longhorn storage, and healthy
siblings. The source Kubernetes server must be reachable for an ordinary pod
shutdown; this command does not force-delete an unreachable validator or fence
a failed physical server. An inaccessible or incomplete identity bundle is an
error, never a reason to generate replacement keys. No snapshot can recover
wallets created after that snapshot.

The command retains a private `kubeton-recovery-...` checkpoint and the original
target PVs for review. These occupy storage until you explicitly remove them.
If a failure occurs after removing the StatefulSet controller, the operator
remains paused and the checkpoint records the completed phase. Review the
saved resources and staged identity before resuming reconciliation; running
`start`, `add`, or `install` at that point can bypass the recovery staging.

The original `./kubeton restore-keys <existing-backup-dir>` syntax still restores
all available replica bundles and restarts the fleet. Use the node/pod form
above for isolated replacement onto another server.

</details>

### Moving a fleet to another Kubernetes cluster

`backup-fleet` and `restore-fleet` move TON identities and controller state to
fresh storage on another cluster. Fleet restore creates the TonNode resources,
StatefulSets and PVCs and uses the saved replica counts. It installs the operator
using the destination `operator-values.yaml`; `replicaCount` in that file
controls operator pods, not the saved TON replica counts.

The installer downloads `kubeton`, `main-wallet.sh`, `fleet.sh`, `fleet.py`, and `fleet-crypto.sh`
together from the selected GitHub release. The fleet commands need only Bash,
`kubectl`, and `tar` on the machine running them. They launch a temporary tools
pod using `ghcr.io/neodix42/ton-k8s-operator:fleet-tools-0.3.4`, which includes
Python, GnuPG, OpenSSL, kubectl, Helm, curl, jq, and the shell utilities used by
backup and restore. Destination migration helpers use the same image. The
installer itself also needs Helm and either curl or wget.

On the source cluster, run:

```bash
./kubeton backup-fleet
# Or choose the output directory:
./kubeton backup-fleet ./fleet-backups/migration
```

Enter a recovery passphrase twice when prompted, and keep it in your password
manager. No passphrase-generation command or local passphrase file is required.
With no directory argument, the backup is saved under
`./fleet-backups/<UTC timestamp>`. Passphrase input is hidden and is passed to
the tools pod over `kubectl exec` stdin, not in command arguments or Pod env.

The source fleets must be running and initialized, with matching TonNode and
StatefulSet replica counts. Backup restarts the source pods, using the existing
`backup-keys` workflow, and captures all TonNode specifications and replica
bundles. The output directory must not already exist. The directory is
published only after every bundle and recovery key has been verified.

`fleet.json` records the specifications, counts and bundle checksums.
`recovery.gpg` contains passphrase-encrypted recovery keys and authenticates the
manifest and bundle inventory. Recovery keys are streamed through GnuPG; they
are not written to plaintext files; GnuPG runs inside the tools pod. The
backup and its passphrase together can recover the validator identities.
Transfer the directory and keep its passphrase separately. Do not change
`fleet.json` or the bundle files after backup.

Stop the source validators before starting their restored identities:

```bash
./kubeton stop
```

On the destination, select its Kubernetes context and provision the desired
StorageClasses. For the default bare-metal/k3d storage and Vault setup, restore
can bootstrap the prerequisites:

```bash
./kubeton restore-fleet ./fleet-backups/migration \
  --storage-class local-path \
  --bundle-storage-class encrypted-sc \
  --bootstrap
```

Enter the same recovery passphrase when prompted.

<details>
<summary>Fleet restore requirements and advanced options</summary>

For an existing storage/Vault setup, omit `--bootstrap`. Each restored namespace
must already contain `TON_VAULT_CREDS_SECRET` (default `ton-vault-creds`) with
`VAULT_ADDR`, `VAULT_TOKEN`, and optionally `VAULT_NAMESPACE`. Its token must
allow encrypt/decrypt on the destination `VAULT_TRANSIT_KEY` (default
`ton-validator`). Fleet restore verifies encryption/decryption with that Vault
and rewraps each replica's recovery key. **The destination Vault may be entirely
new; the original Vault is not required once fleet backup has completed.**
Vault root/unseal credentials and source Kubernetes Secrets are not exported.

Tools pods use short-lived ServiceAccounts. Backup receives a role limited to
the resource reads, pod exec/copy and workload scaling needed by the backup
workflow. Restore temporarily binds its tools ServiceAccount to `cluster-admin`
because it installs CRDs, operator RBAC, storage/Vault prerequisites and fleet
resources. The caller must already be allowed to create those bindings. The
pod, ServiceAccount and bindings are removed after the command finishes. If a
connection is lost and remote cleanup cannot be confirmed, `kubeton` reports
the retained pod and binding names so cleanup can finish before access is revoked.

Use `KUBETON_FLEET_TOOLS_NAMESPACE` to select the tools namespace (default
`default`), `KUBETON_FLEET_TOOLS_IMAGE` to override the image, and
`KUBETON_FLEET_TOOLS_MEMORY` to change the tools pod memory limit (default `2Gi`).
The published tools image targets Linux amd64, matching the default TON image.
The tools namespace must allow its pod to reach the Kubernetes API.

For automation, `--passphrase-file /secure/fleet.passphrase` remains available;
the file is read locally and its contents are streamed to the pod. For an
explicit local execution with all tools already installed, set
`KUBETON_FLEET_RUNTIME=native`. The current backup format supports Vault-backed
fleets; KMS-backed fleets and external `configRef` or `env.valueFrom` dependencies
are rejected to avoid an incomplete migration backup.

Destination data and bundle StorageClasses are independent. Defaults come from
`TON_STORAGE_CLASS_NAME` (`local-path`) and `ENCRYPTED_SC_NAME` (`encrypted-sc`);
the command flags override them. An explicit data class is required; `auto`
is not accepted. Both classes must support the requested claim sizes and
scheduling all of a replica's volumes onto the same worker. The destination
needs enough eligible workers, CPU, memory and disk for the saved workload.
One replica of each fleet is allowed per worker; host ports can require more
workers when multiple fleets share their port numbers.

Source node selectors, node names and explicit public IP settings are discarded.
Use `--node-selector 'pool=validators'` to restrict destination placement. Helper
pods reserve the TON resources and host ports while the scheduler provisions
all five PVCs per replica. Restore chooses the worker's `ExternalIP`, falling
back to its host IP, and updates the saved validator advertised IPv4 addresses
and any service `--ip` argument. Ports and validator identities are retained.
For NAT/private workers, supply publicly forwarded addresses explicitly:

```json
{
  "default/tonnode/0": "203.0.113.10",
  "default/tonnode/1": "203.0.113.11"
}
```

Pass that JSON file with `--public-ips /path/to/public-ips.json`; keys are
`namespace/TonNode-name/ordinal`. Configured ports must be reachable at those
addresses. Unknown replica names and invalid IPv4 addresses are rejected.

Restore validates the passphrase, authenticated manifest and all bundle hashes
before any cluster writes. It refuses existing TonNode resources, TON
StatefulSets or matching PVCs. Every identity is staged and re-encrypted before
any TON process starts, and replicas start on their newly selected workers.
On failure, restore attempts to stop destination fleets and retains PVCs for
inspection. If those stop requests fail, it leaves the operator paused and
reports the need to check replica counts before resuming reconciliation. Remove
the partial destination fleets before retrying.

Bulk blockchain databases, `kubeton wallet`'s separate main-wallet bundle,
and its outgoing-payment journal are excluded. TON must synchronize blockchain data on its fresh volumes.
The restored TonNodes are created directly rather than owned by a Helm chart.
Before using `kubeton start` for later changes, align destination
`tonnode-values.yaml` (or `TON_VALUES_FILE`) with the restored names, namespace,
replica count, images and storage choices; the local values file is not
rewritten by restore. For multiple TonNodes, manage each specification explicitly.

For full design, threat model, provider requirements, and hardening steps, see:
- `SECURITY.md`

</details>
