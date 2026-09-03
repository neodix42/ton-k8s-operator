# TON Kubernetes Operator

Kubernetes operator for `ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64`, built with Go + Kubebuilder.

This operator creates and manages:
- `TonNode` custom resources (`ton.ton.org/v1alpha1`)
- A headless `Service` per `TonNode`
- A `StatefulSet` per `TonNode`
- Four data PVC templates per replica:
  - `/var/ton-work`
  - `/usr/src/ton`
  - `/usr/local/bin/mytoncore`
  - `/usr/local/bin/mytonctrl`
- `/usr/local/bin/mytoncore/mytoncore.db` is persisted on the `mytoncore` PVC.

## Behavior Implemented

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
- Passes TON env vars expected by `ton-docker-ctrl`:
  - `PUBLIC_IP` (explicit `spec.network.publicIP`, otherwise auto node `ExternalIP` for single-replica; fallback `status.hostIP`)
  - `NETWORK` (defaults to `mainnet`; use `testnet` for testnet)
  - `GLOBAL_CONFIG_URL` derived from `NETWORK` (`https://ton.org/global.config.json` for mainnet, `https://ton.org/testnet-global.config.json` for testnet)
  - `VALIDATOR_PORT`
  - `LITESERVER_PORT`
  - `VALIDATOR_CONSOLE_PORT`
- For `hostPortsEnabled=true` with auto `PUBLIC_IP` (empty `spec.network.publicIP`), operator preselects sticky worker hostnames before first pod launch (Ready/schedulable nodes matching `spec.nodeSelector`) to prevent node/IP drift on restarts without a post-launch rollout.
- Sets `IGNORE_MINIMAL_REQS=true` by default (can be overridden through `spec.env`).
- Applies default pod resources (overridable via `spec.resources`):
  - requests: `cpu=16000m`, `memory=64Gi`
  - limits: `cpu=128000m`, `memory=256Gi`

## TonNode Spec

The CRD includes:
- `image`
- `replicas`
- `storage`
- `resources`
- `network`
- `configRef`
- `keyManagement`
- `env`

See sample:
- `config/samples/ton_v1alpha1_tonnode.yaml`

## Key and Secret Strategy

Each replica stores TON state in per-pod PVCs and generates keys on the first start.

Secure key workflow is available via `spec.keyManagement`:
- plaintext key directories mounted on tmpfs (memory only)
- encrypted key bundle persisted on dedicated `keybundle` PVC
- init container restores/decrypts a bundle before TON start
- sidecar writes encrypted bundles when explicitly triggered by `kubeton backup-keys` and during `kubeton stop` when stop-time backup is enabled
- `kubeton wallet ...` runs in a separate ephemeral pod with its own encrypted bundle PVC; it is intentionally excluded from `kubeton status` and `kubeton backup-keys` flows
- when the wallet bundle PVC uses Longhorn storage, `kubeton wallet ...` pins the helper pod to nodes exposing `driver.longhorn.io` (from `CSINode`) to avoid attach failures on non-Longhorn nodes

Manual encrypted bundle backup is available with:
- `./kubeton backup-keys [output-dir]`
- `./kubeton stop` scales TON StatefulSets to `0` (keeps TonNode/StatefulSet/PVC resources)
- `./kubeton start` restores TON replicas from stop metadata (and also performs normal start/upgrade flow when no stop metadata exists)
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
- `/var/ton-work/db/systemd-units/**`
- `/var/ton-work/db/mtc_done`
- `/usr/local/bin/mytoncore/**` (entire folder, including wallets and mytoncore state files)
- `/usr/local/bin/mytonctrl/**`
- `keys.bundle.meta` contains bundle metadata: `provider`, `wrapped_key`, `algorithm`, `created_at`
- TON DB data outside this set (for example `/var/ton-work/db/celldb/**`, `/var/ton-work/db/archive/**`) is not part of this key bundle backup.
- if `spec.keyManagement.encryptedBundle.fileName` or `metaFileName` is customized, exported filenames follow those values.

Manual backup is still required for external/exported copies and destructive workflows:
- run `./kubeton backup-keys` immediately after first key generation/initial setup when you need an external/off-cluster copy
- run it again after any key change/rotation before maintenance, upgrade, or cluster-level operations

Restore prerequisites:
- `./kubeton restore-keys <input-dir>` automatically scales TON StatefulSets to `0`, restores available replica bundles, then scales back to previous replica counts.
- if the backup directory is missing for some replica ordinal, restore reports it and continues with other replicas.
- for one-by-one scaling, use:
- `./kubeton add` to add one replica.
- `./kubeton del` to remove one replica; it always removes the highest ordinal (tail) pod and does not accept a pod name.
- encrypted bundles can be decrypted only if the same root-of-trust is still available:
- Vault mode: same Vault Transit key history/material (same logical key with old versions available).
- KMS mode: same cloud KMS key resource still exists and is usable for decrypt.
- `kubeton drop` removes TON resources/PVCs, verified local-path backing directories, and supported CSI/Longhorn backing volumes.
- `kubeton uninstall` is a full cleanup: it removes TON resources/PVCs, verified local-path backing directories, supported CSI/Longhorn backing volumes, kubeton-managed Prometheus/Grafana/VictoriaMetrics/VictoriaLogs resources, main-wallet/debug helper resources, operator release/namespace, Longhorn release/namespace, Vault release/namespace, and `encrypted-sc` StorageClass, but keeps `TonNode` CRD.
- for an explicit `kubeton uninstall` or `kubeton drop`, legacy TON claim-template names are also recognized when their ownership labels are missing. This covers all per-ordinal claims, including `mytoncore-...`, so a partial `mytoncore.db` cannot survive a successful cleanup merely because it was created by an older controller. The fallback is limited to an exact configured or captured TON StatefulSet claim-template identity; it does not delete PVCs merely because they share a prefix.
- before deleting a PVC, `kubeton` stores the bound PV/PVC UIDs; local-path host paths and Longhorn CSI volume handles are recorded as well. A later `./kubeton uninstall` can therefore retry storage cleanup even after Kubernetes has deleted the PVC object.
- if Kubernetes is still terminating resources or a cleanup step errors, `kubeton uninstall` continues with the remaining steps, reports leftovers, and exits non-zero rather than claiming completion while a cleanup ledger remains. `Retain`, static, or unknown backing storage is intentionally left in the ledger for manual removal rather than being force-deleted. Rerun `./kubeton uninstall` after resolving the reported issue.
- `kubeton purge` runs full uninstall and also deletes CRD `tonnodes.ton.ton.org`; this is separated from `uninstall` because CRD deletion is cluster-scoped/destructive.
- if Vault is reinitialized or Vault data is lost, old bundles become undecryptable even if key name is reused.

`configRef` safety rule remains: `spec.configRef` is allowed only with `replicas=1`.

For full design, threat model, provider requirements, and hardening steps, see:
- `SECURITY.md`

## Prerequisites

- Go installed (project currently scaffolds with controller-runtime/Kubebuilder tooling that may use Go toolchain auto-download).
- Docker
- kubectl
- Helm 3
- k3d (or another Kubernetes cluster)

## Production Deployment

Yes, for production you must install this operator into the target cluster.
Installation means applying:
- CRD (`TonNode`)
- RBAC
- controller Deployment

Use one of these production-safe flows:

### Flow B: Cluster User (Helm, recommended)

Use this flow if you want simpler install/upgrade without `make`.

Requirements:
- `kubectl`
- `helm`
- access to this chart (`./charts/ton-k8s-operator`) or a packaged `.tgz`

Before creating `TonNode`, ensure your cluster has at least one `StorageClass`:

```bash
kubectl get sc
```

If the list is empty, install a simple dynamic provisioner for lab/testing (local-path):

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```

Bare-metal/local-dev default setup is automated by `kubeton`:
- detects bare-metal cluster (`spec.providerID` empty on all nodes) or local k3d cluster (context/node name starts with `k3d-`)
- on bare-metal: installs Longhorn v1 (`LONGHORN_CHART_VERSION`, default `1.10.0`) and creates encrypted StorageClass `encrypted-sc` (LUKS/dm-crypt, `aes-xts-plain64`, `sha256`, `argon2i`, replica count `3`)
- on bare-metal, TON data PVCs (`/var/ton-work`, including `/var/ton-work/db`) use `TON_STORAGE_CLASS_NAME` by default (`local-path`) so dump download writes to node-local storage instead of Longhorn
- on bare-metal, `kubeton start` aligns TON pod placement with `LONGHORN_NODE_SELECTOR` by setting `tonNode.nodeSelector` automatically
- on bare-metal, Vault server pod is also constrained to `LONGHORN_NODE_SELECTOR` so its PVC can attach only on nodes with Longhorn CSI
- with default `LONGHORN_NODE_SELECTOR=node.longhorn.io/create-default-disk=true`: `kubeton` selects only nodes that pass its resource/disk preflight, then labels the required number of them for Longhorn
- on local k3d: skips Longhorn install and creates `encrypted-sc` from an existing local StorageClass (`LOCALDEV_BASE_SC`, default `local-path`) for dev convenience
- installs Vault (`VAULT_CHART_VERSION`, default `0.30.0`)
- initializes/unseals Vault and configures Transit key `ton-validator`
- creates TON secret `ton-vault-creds` in namespace `default`
- deploys TonNode with key-management enabled by default

Local k3d note:
- `encrypted-sc` on k3d is a development fallback and does not provide Longhorn-backed disk encryption.
l- if local Vault bootstrap credentials become stale (for example after manual Vault namespace deletion), `kubeton start` attempts one automatic Vault reinstall/reinitialize recovery on k3d.

You can run bootstrap explicitly:

```bash
./kubeton bootstrap-baremetal
```

Or just run `./kubeton start`; it bootstraps automatically before TON deployment on bare-metal and local k3d clusters.

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

The node filesystem minimum is controlled entirely by these configured storage
sizes plus `KUBETON_CHECK_DISK_HEADROOM` (default `20Gi`). `kubeton check` does
not fetch dump metadata or automatically increase the requirement when
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

### Launch evidence and durable logs

`kubeton install` and `kubeton start` create a private evidence directory on
the machine where the command is executed. The default location is:

```text
./kubeton-launch-logs/<UTC timestamp>-<install|start>-<pid>/
```

The directory and its files are owner-only (`0700`/`0600`). It contains the
complete kubeton command transcript, a timestamped Pod-state timeline, target
namespace and cluster-wide Kubernetes Event streams, controller output,
best-effort current/previous output from every TON init and application
container, and final Pod/StatefulSet/TonNode, PVC/PV, VolumeAttachment, node,
CSINode, Longhorn, Vault, operator, and Victoria status snapshots. The
cluster-wide Event watcher starts before storage bootstrap or Helm can create a
TON Pod, so it also preserves scheduler, CSI, Vault, Longhorn, and logging
failures that occur before a TON object exists. The path is printed at the
beginning and end of the command. Treat the bundle as sensitive operational
data even though kubeton does not read Kubernetes Secret contents, does not
query Secret or ConfigMap objects for final diagnostics, and does not copy
literal container environment values into its Pod JSON snapshot.

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
the TON objects. The command no longer treats `Running`/`Ready` as successful
bootstrap: TON currently has no readiness probe, so Kubernetes can report
Ready while the dump is still downloading or extracting. By default, `start`
waits up to 24 hours for every ordinal to have all of the durable MyTonCtrl
commit state:

- `/var/ton-work/db/mtc_done`
- a non-empty `/var/ton-work/db/config.json`
- persisted `validator.service` and `mytoncore.service` units

It prints state changes and one-minute heartbeats such as `FailedScheduling`,
`FailedAttachVolume`, `downloading`, `extracting`, `CrashLoopBackOff`, and
`complete`. Five repeated CrashLoop restarts with a non-zero exit fail the
command early while leaving the Pods/PVCs intact for diagnosis.

On a fresh infrastructure bootstrap, `start` installs the cluster-wide node
collector before Longhorn or Vault. The collector queues those early container
logs in a bounded, release-specific host directory under
`/var/lib/kubeton-vlogs-buffer-*`; the queue flushes when the VictoriaLogs
backend becomes available. Before the first TON Pod is created, `start` also
installs or verifies that backend and refuses to deploy TON unless a
non-terminating Ready collector of the current DaemonSet revision exists on
every selected TON node. Unavailable unrelated nodes may leave the aggregate
collector DaemonSet partially Ready, but do not block TON once the selected
nodes are covered. Sequential local-volume staging rechecks coverage before
each additional ordinal is created.
VictoriaLogs is the durable source for container stdout/stderr across rapid
restarts and an SSH/API interruption; the local bundle supplements it with
control-plane Events and launch state that do not exist in container logs.
The tested default chart versions are pinned, collector disk buffering is
bounded, and collector CPU/memory/ephemeral-storage requests prevent it from
being a zero-request BestEffort eviction target.

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
- `KUBETON_START_STATUS_INTERVAL_SECONDS` (default `60`)
- `KUBETON_START_FATAL_RESTART_COUNT` (default `5`; `0` disables fail-fast)
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
grep -R -E 'Download complete|Starting extraction|mtc_done|exit code' \
  kubeton-launch-logs/<run>/pods/
```

For durable history after the launching shell exits, install the authenticated
VictoriaMetrics access layer with `./kubeton victoria-metrics install`, or use
a temporary direct port-forward and open
`http://127.0.0.1:9428/select/vmui/`:

```bash
LOG_SERVICE=$(kubectl -n vm get service \
  -l app.kubernetes.io/name=kubeton-victoria-logs-access \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n vm port-forward "service/${LOG_SERVICE}" 9428:9428
```

A host filesystem is relevant only after the replica's local-path PV
`nodeAffinity` or `local.path.provisioner/selected-node` points to that host.

For a separate filesystem mounted at `LOCAL_PATH_PROVISIONER_ROOT`, the kubelet
node filesystem statistic is only a safety signal, not an authoritative free
space measurement for that mount. Use a host-level disk monitor/probe as well.
Useful overrides are `KUBETON_CHECK_MIN_CPU`,
`KUBETON_CHECK_MIN_MEMORY`, and `KUBETON_CHECK_DISK_HEADROOM`; set
`KUBETON_SKIP_NODE_PREREQ_CHECK=true` only when intentionally bypassing the
gate.

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

Bootstrap a local installation bundle from a pinned release:

```bash
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.2.2/install.sh" | bash
```

The script:
- creates a local folder named `ton-k8s-operator-<chart-version>` by default
- downloads chart from `oci://ghcr.io/neodix42/charts/ton-k8s-operator`
- extracts the chart and prints next commands

The extracted chart already includes:
- `values.yaml`
- `operator-values.yaml`
- `tonnode-values.yaml`
- `kubeton`

Then follow:

```bash
cd ./ton-k8s-operator-0.1.35

# review defaults
ls -1 values.yaml operator-values.yaml tonnode-values.yaml kubeton

# helper script for common fleet operations
./kubeton help
./kubeton check
./kubeton install
./kubeton bootstrap-baremetal
./kubeton start
./kubeton prometheus start
./kubeton grafana start
./kubeton victoria-metrics install
./kubeton backup-keys
./kubeton restore-keys ./key-backups/<timestamp>
./kubeton wallet create main-wallet
./kubeton wallet deploy testnet
./kubeton wallet deploy testnet main-wallet
./kubeton wallet send testnet main-wallet tonnode-0 validator_wallet_001 10.
./kubeton wallet send testnet main-wallet tonnode-0 validator_wallet_001 10. -n
./kubeton wallet send testnet main-wallet 10.
./kubeton wallet collect testnet main-wallet
./kubeton wallet collect testnet main-wallet 10.
./kubeton wallet collect testnet main-wallet tonnode-0
./kubeton wallet collect testnet main-wallet tonnode-0 validator_wallet_001 10.
./kubeton wallet collect testnet main-wallet tonnode-0 validator_wallet_001 alld
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
./kubeton exec "sync"
./kubeton exec-mtc "set stake 1000000"

`kubeton wallet create` only generates main-wallet files and the init BOC.
Before `kubeton wallet deploy <mainnet|testnet> <name>` can deploy a new main
wallet, send funds to the
non-bounceable init address printed by `wallet create`, wait until the funding
transaction is visible on-chain, then rerun
`kubeton wallet deploy <mainnet|testnet> <name>`.
After topping up mytonctrl wallets inside TON pods with split mode, for example
`kubeton wallet send testnet main-wallet 2`, activate those pod wallets with
`kubeton wallet activate [tonnode-name] [wallet-name]`. The
activate command executes `aw <wallet-name>` through `mytonctrl` inside the TON
pod and does not send a BOC payload to the network.
`kubeton wallet collect` reads the same `mytonctrl wl` status and only runs
`mg` for source wallets that are already `active`; activate funded pod wallets
before collecting from them.
`kubeton wallet deploy`, `kubeton wallet send`, and `kubeton wallet collect`
require an explicit `mainnet` or `testnet` argument. For deploy/send that
argument selects both the lite-server global config and TONCenter endpoint. By
default wallet BOC sending uses
`MAIN_WALLET_MODE=auto`: two lite-server attempts followed by two TONCenter
attempts.
After a successful `kubeton wallet deploy <mainnet|testnet> <name>`, kubeton
stores the wallet network in the encrypted main-wallet metadata, and
`kubeton wallet show [name]` also prints balance and seqno from that network.
`kubeton wallet activate ...` and `kubeton wallet show balance ...` run against
`mytonctrl` inside TON pods; `mytonctrl` already has the network configured.
`kubeton wallet export` prints private key material to stdout after confirmation:
with no arguments it exports all pod wallet `.pk` files, with one argument it
exports the named main wallet, including its subwallet id, from the encrypted
main-wallet bundle, and with `<pod-name> <wallet-name>` it exports one pod
wallet.

# install TON k8s operator only
./kubeton check
./kubeton install

# start TON nodes (replicas from tonnode-values.yaml)
./kubeton start

# create/update Prometheus scrapers from TonNode CUSTOM_PARAMETERS --exporter-address
# and start background local port-forward(s)
./kubeton prometheus start

# remove kubeton-managed Prometheus resources and background port-forward(s)
./kubeton prometheus stop

# create/update Grafana with kubeton-managed Prometheus datasource(s)
# and start background local/public port-forward
./kubeton grafana start

# remove kubeton-managed Grafana resources and background port-forward(s)
./kubeton grafana stop

# install VictoriaMetrics operator stack, auto-create TonNode scrape resources,
# install VictoriaLogs single + collector (enabled by default),
# start background VMAuth port-forward, expose VictoriaLogs via VMAuth auth routes,
# and print endpoints/credentials
./kubeton victoria-metrics install

# remove kubeton-managed VictoriaMetrics/VictoriaLogs resources and background port-forward(s)
./kubeton victoria-metrics uninstall

# scale by one replica
./kubeton add
./kubeton del   # always removes the highest ordinal (tail) replica
./kubeton recreate tonnode-10 ./key-backups/<timestamp>  # recreates one pod data PVCs and restores its backup bundle

# temporarily stop TON pods (keeps TonNode/STS/PVC resources)
./kubeton stop
./kubeton start             # restore previous TON replicas

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

### Environment overrides

`kubeton` reads these environment variables:

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
MAIN_WALLET_GLOBAL_CONFIG_URL
MAIN_WALLET_TONCENTER_URL
MAIN_WALLET_TONCENTER_API_KEY
MAIN_WALLET_NAME
MAIN_WALLET_SEND_RETRY_ATTEMPTS
MAIN_WALLET_LITESERVER_SEND_ATTEMPTS
MAIN_WALLET_TONCENTER_SEND_ATTEMPTS
MAIN_WALLET_SEND_RETRY_DELAY_SEC
MAIN_WALLET_POD_TIMEOUT
MAIN_WALLET_RUNTIME_TMPFS_SIZE

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
KUBETON_START_STATUS_INTERVAL_SECONDS
KUBETON_START_FATAL_RESTART_COUNT
KUBETON_START_VICTORIA_LOGS_ENABLED
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

### PROMETHEUS_TARGET_MODE

`PROMETHEUS_TARGET_MODE` controls how `kubeton prometheus start` builds scrape targets from TonNode `CUSTOM_PARAMETERS` (`--exporter-address`).

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
`tonnode-values.yaml` enables TON nodes, enables key-management by default (`vault`, `ton-vault-creds`, `encrypted-sc`), and includes common `ton-docker-ctrl` env parameters.

### kubeton grafana

`kubeton grafana start` automates Grafana installation/start and wires datasource/dashboard provisioning to kubeton-managed Prometheus service(s).

Behavior:
- ensures kubeton-managed Prometheus stack exists (from TonNode `CUSTOM_PARAMETERS --exporter-address`)
- deploys `kubeton-grafana` (`grafana/grafana`)
- provisions datasource file in Grafana (`/etc/grafana/provisioning/datasources/datasources.yaml`)
- provisions dashboard provider + starter TON dashboard
- starts background `kubectl port-forward` and prints local/remote URL
- prints Grafana admin credentials (stored in secret, reused across restarts)

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

### kubeton victoria-metrics

`kubeton victoria-metrics install` installs VictoriaMetrics operator (QuickStart-style `install-no-webhook` manifest), deploys `VMSingle` + `VMAgent` + `VMAuth` + `VMUser`, auto-generates TonNode scrape resources (`Service` + `VMServiceScrape`) from TonNode `CUSTOM_PARAMETERS --exporter-address`, and installs/updates the same VictoriaLogs stack that `kubeton start` ensures before TON bootstrap.

Behavior:
- applies/updates VictoriaMetrics operator in namespace `vm` (configurable)
- deploys kubeton-managed VM stack resources with generated or user-provided auth credentials
- creates/updates TonNode scrape resources so `VMAgent` starts scraping TonNode exporters
- installs/updates VictoriaLogs backend (`victoria-logs-single`) and a stable cluster-wide collector (`victoria-logs-collector` DaemonSet) with `remoteWrite[0].url` pointed at VictoriaLogs
- caps the collector's per-destination on-node buffer and sets explicit CPU, memory, and ephemeral-storage requests/limits
- warns when unrelated cluster nodes leave the aggregate collector DaemonSet partially Ready; `kubeton start` strictly requires a Ready collector on every selected TON node
- on bare-metal, pins VictoriaLogs single to Longhorn-selected nodes by default to avoid CSI attach failures on non-Longhorn nodes
- when using `longhorn` storageClass, also adds Longhorn CSI-based nodeAffinity fallback (from `CSINode`) so VictoriaLogs single cannot schedule to nodes without `driver.longhorn.io`
- starts background `kubectl port-forward` to `VMAuth` and prints VMUI/targets URLs + credentials
- exposes VictoriaLogs UI/query through VMAuth (`/select/vmui/`, `/select/logsql/query`) so the same VMAuth username/password is required
- does not expose unauthenticated external `:9428` by default; remote logs access uses the VMAuth endpoint/port
- if `port-forward` is unavailable, starts a local `kubectl proxy` fallback and prints localhost VMUI/targets/query URLs via API proxy
- if port-forward is unavailable (for example kubelet proxy `502` on local k3d), creates kubeton-managed `NodePort` access services and prints node-IP URLs (ExternalIP preferred, InternalIP fallback)
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
- `VICTORIA_LOGS_STORAGE_CLASS` (default auto; uses `longhorn` when available)
- `VICTORIA_LOGS_NODE_SELECTOR` (default on bare-metal: `LONGHORN_NODE_SELECTOR`)
- `VICTORIA_LOGS_COLLECTOR_NODE_SELECTOR` (default empty, meaning cluster-wide;
  set only when collector coverage is intentionally restricted)
- `VICTORIA_LOGS_PIN_TO_LONGHORN_CSI` (default `true`; adds nodeAffinity to nodes exposing `driver.longhorn.io`)
- `VICTORIA_LOGS_NETWORK_POLICY_ENABLED` (default `true`; isolates the unauthenticated backend so only the kubeton collector and VMAuth can connect; requires enforcement by the cluster CNI)
- `VICTORIA_LOGS_CLEANUP_TIMEOUT_SECONDS` (default `300`; keeps backend ingress protection and cleanup state when uninstall cannot prove that logging workloads are gone)
- `VICTORIA_LOGS_PORT`

### Cloud Install Options

For AWS/GCP/AliCloud, you can use any of these install paths:

- Cloud Shell (fastest): run the same release-pinned command above from AWS CloudShell, GCP Cloud Shell, or Alibaba Cloud Shell.
- CI/CD or bastion host: run `helm install/upgrade` from your deployment runner against the target kube-context.
- GitOps (recommended for production): use Argo CD or Flux with this chart and versioned values files.
- Terraform: use `helm_release` to install/upgrade declaratively.

Cloud provider dashboards can help create the cluster and open Cloud Shell, but this operator is not currently a managed one-click marketplace add-on. Installation is still done by Helm/kubectl.

### Upgrade Workflow (When Image Changes)

Use one of the dedicated release scripts:

```bash
# A) Operator release (bumps operator + chart versions; keeps ton-docker-ctrl tag unchanged)
./upgrade-ton-operator.sh 0.1.24

# B) TON image-only release (bumps chart version only; keeps operator appVersion/tag unchanged)
./upgrade-ton-docker-ctrl-only.sh 0.1.24 v2026.05-amd64

# commit + push to main
git add .
git commit -m "release: 0.1.24"
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
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.2.2/install.sh" | bash
cd ./ton-k8s-operator-0.1.35

# review values before upgrade
cat operator-values.yaml
cat tonnode-values.yaml
```

Upgrade operator only:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  --rollback-on-failure --wait --timeout 20m
```

Upgrade operator and TON nodes:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --rollback-on-failure --wait --timeout 40m
```

If only TON image is changed, keep an operator version and update the node image explicitly:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/ton-blockchain/ton-docker-ctrl:<new-tag> \
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

# rollback TON node image explicitly
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/ton-blockchain/ton-docker-ctrl:<old-tag> \
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

`kubeton purge` includes full uninstall of kubeton-managed resources, then deletes TonNode CRD.

### Flow C: Cluster User (raw install.yaml fallback)

If you prefer plain manifests:

```bash
kubectl apply -f https://raw.githubusercontent.com/neodix42/ton-k8s-operator/refs/heads/main/dist/install.yaml
kubectl apply -f https://raw.githubusercontent.com/neodix42/ton-k8s-operator/refs/heads/main/config/samples/ton_v1alpha1_tonnode.yaml
```

Raw uninstall:

```bash
kubectl delete -f https://raw.githubusercontent.com/neodix42/ton-k8s-operator/refs/heads/main/dist/install.yaml
```

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
- `IGNORE_MINIMAL_REQS`: default is `true` for easier local/k3d startup; for production set `spec.env: [{ name: IGNORE_MINIMAL_REQS, value: "false" }]`.
- Right-size resources in `spec.resources` for TON fullnode/validator workloads.

### How TON Storage Is Placed

Data from all TON pods is not stored in one shared place.

With this operator setup:
- Each TON pod gets its own data PVCs (`ton-work-...`, `ton-src-...`, `mytoncore-...`, and `mytonctrl-...`).
- `/usr/local/bin/mytoncore` is mounted from the pod's `mytoncore` PVC; this is where `mytoncore.db` persists across pod restarts.
- `/usr/local/bin/mytonctrl` is mounted from the pod's `mytonctrl` PVC so any MyTonCtrl files written there also persist.
- When encrypted key management is enabled, only `/usr/local/bin/mytoncore/wallets` is overlaid with tmpfs and restored from the encrypted key bundle.
- `/usr/src/ton` is mounted from the pod's `ton-src` PVC so the TON source checkout used by MyTonCtrl/Fift survives pod recreation.
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

## Local Development and Testing (k3d)

Use this workflow for local development from this repository.  
Production deployments should use release artifacts/charts, not this dev-repo flow.

Prerequisites:
- `k3d`
- `docker`
- `kubectl`
- `helm`
- `make`

Create a local k3d cluster (example with 5 agent nodes):

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
