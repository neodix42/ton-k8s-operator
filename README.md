# TON Kubernetes Operator

Kubernetes operator for `ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64`, built with Go + Kubebuilder.

This operator creates and manages:
- `TonNode` custom resources (`ton.ton.org/v1alpha1`)
- A headless `Service` per `TonNode`
- A `StatefulSet` per `TonNode`
- Two PVC templates per replica:
  - `/var/ton-work`
  - `/usr/local/bin/mytoncore`

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
  - `GLOBAL_CONFIG_URL`
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
- `kubeton drop` removes TON resources/PVCs only.
- `kubeton uninstall` removes TON resources/PVCs, kubeton-managed Prometheus/Grafana/VictoriaMetrics/VictoriaLogs resources, operator release, Longhorn release/namespace, Vault release/namespace, and `encrypted-sc` StorageClass, but keeps `TonNode` CRD.
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
- on bare-metal, `kubeton start` aligns TON pod placement with `LONGHORN_NODE_SELECTOR` by setting `tonNode.nodeSelector` automatically
- on bare-metal, Vault server pod is also constrained to `LONGHORN_NODE_SELECTOR` so its PVC can attach only on nodes with Longhorn CSI
- with default `LONGHORN_NODE_SELECTOR=node.longhorn.io/create-default-disk=true`: if there are not enough labeled nodes, `kubeton start` auto-labels only the required number of nodes (based on requested TON replicas)
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
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.1.55/install.sh" | bash
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
./kubeton install
./kubeton bootstrap-baremetal
./kubeton start
./kubeton prometheus start
./kubeton grafana start
./kubeton victoria-metrics install
./kubeton backup-keys
./kubeton restore-keys ./key-backups/<timestamp>
./kubeton wallet create main-wallet
./kubeton wallet deploy
./kubeton wallet deploy main-wallet
./kubeton wallet send main-wallet tonnode-0 validator_wallet_001 10.
./kubeton wallet send main-wallet tonnode-0 validator_wallet_001 10. -n
./kubeton wallet send main-wallet 10.
./kubeton wallet show
./kubeton wallet show main-wallet
./kubeton verify
./kubeton status
./kubeton exec "sync"

# install TON k8s operator only
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

# drops TON nodes and storage (PVCs)
./kubeton drop

# delete operator release + Longhorn + Vault + kubeton-managed observability stacks (keeps TonNode CRD)
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
MAIN_WALLET_POD_TIMEOUT
MAIN_WALLET_RUNTIME_TMPFS_SIZE

AUTO_BAREMETAL_BOOTSTRAP
FORCE_BAREMETAL_BOOTSTRAP
SKIP_KEY_PREREQ_CHECK

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
VICTORIA_LOGS_STORAGE_CLASS
VICTORIA_LOGS_NODE_SELECTOR
VICTORIA_LOGS_PIN_TO_LONGHORN_CSI
VICTORIA_LOGS_PORT
VICTORIA_LOGS_LOCAL_PORT_BASE
VICTORIA_LOGS_API_PROXY_LOCAL_PORT_BASE
VICTORIA_LOGS_PORT_FORWARD_DIR
VICTORIA_LOGS_PORT_FORWARD_WAIT_SECONDS
VICTORIA_LOGS_PORT_FORWARD_VERIFY_SECONDS
VICTORIA_LOGS_PORT_FORWARD_ADDRESS
VICTORIA_LOGS_STATE_CONFIGMAP
VICTORIA_LOGS_HELM_TIMEOUT_SECONDS
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

`kubeton victoria-metrics install` installs VictoriaMetrics operator (QuickStart-style `install-no-webhook` manifest), deploys `VMSingle` + `VMAgent` + `VMAuth` + `VMUser`, auto-generates TonNode scrape resources (`Service` + `VMServiceScrape`) from TonNode `CUSTOM_PARAMETERS --exporter-address`, and (by default) installs `victoria-logs-single` + `victoria-logs-collector` from the official Helm charts.

Behavior:
- applies/updates VictoriaMetrics operator in namespace `vm` (configurable)
- deploys kubeton-managed VM stack resources with generated or user-provided auth credentials
- creates/updates TonNode scrape resources so `VMAgent` starts scraping TonNode exporters
- installs/updates VictoriaLogs backend (`victoria-logs-single`) and cluster-wide collector (`victoria-logs-collector` DaemonSet) with `remoteWrite[0].url` pointed at VictoriaLogs
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
- `VICTORIA_LOGS_STORAGE_CLASS` (default auto; uses `longhorn` when available)
- `VICTORIA_LOGS_NODE_SELECTOR` (default on bare-metal: `LONGHORN_NODE_SELECTOR`)
- `VICTORIA_LOGS_PIN_TO_LONGHORN_CSI` (default `true`; adds nodeAffinity to nodes exposing `driver.longhorn.io`)
- `VICTORIA_LOGS_PORT`

### Cloud Install Options

For AWS/GCP/AliCloud, you can use any of these install paths:

- Cloud Shell (fastest): run the same release-pinned command above from AWS CloudShell, GCP Cloud Shell, or Alibaba Cloud Cloud Shell.
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
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.1.55/install.sh" | bash
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
If you want to remove CRD too (destructive, removes `TonNode` objects):

```bash
kubectl delete crd tonnodes.ton.ton.org
```

For `kubeton`-based full destructive cleanup (including CRD), use:

```bash
./kubeton purge
```

`kubeton purge` includes uninstall of operator, Longhorn, Vault, and kubeton-managed observability resources, then deletes TonNode CRD.

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
- Private cloud workers (no public node IP): provide per-node/per-replica public forwarding; one shared LB endpoint/port pair is not sufficient for many TON replicas.
- Storage class: explicitly set `spec.storage.storageClassName` when you need deterministic storage behavior.
- Bare metal: if Longhorn exists, the operator prefers it automatically.
- If no StorageClass exists in the cluster, `TonNode` will stay `Ready=False` with reason `StorageClassMissing`.
- `IGNORE_MINIMAL_REQS`: default is `true` for easier local/k3d startup; for production set `spec.env: [{ name: IGNORE_MINIMAL_REQS, value: "false" }]`.
- Right-size resources in `spec.resources` for TON fullnode/validator workloads.

### How TON Storage Is Placed

Data from all TON pods is not stored in one shared place.

With this operator setup:
- Each TON pod gets its own PVCs (`ton-work-...` and `mytoncore-...`).
- PVCs are `ReadWriteOnce`, so one PVC is attached to one pod.
- For 20 replicas, the total PVC count is 40.

If you use `local-path` StorageClass:
- Data is written to the local disk on the node where that pod volume is provisioned.
- Storage is distributed across nodes/pods, not centralized.
- If a node is lost, data tied to that node-local volume is also lost (unless you use replicated storage such as Longhorn).

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
k3d cluster create --agents 5 --api-port 127.0.0.1:6550
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
# removes operator + Longhorn + Vault + kubeton-managed observability resources
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
