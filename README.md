# TON Kubernetes Operator

Kubernetes operator for `ghcr.io/ton-blockchain/ton-docker-ctrl:latest`, built with Go + Kubebuilder.

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
- Exposes TON validator/lite-server ports on worker nodes with `hostPort` by default:
  - UDP `30001` (`validatorPort`)
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
- `env`

See sample:
- `config/samples/ton_v1alpha1_tonnode.yaml`

## Key and Secret Strategy

`ton-docker-ctrl` generates `/var/ton-work/db/config.json` (including Ed25519 private keys) on first startup and persists it in the replica PVC.

Current operator behavior:
- Default mode (recommended for multi-replica): each replica gets its own PVC and independently generates unique keys/config on first boot.
- Optional bootstrap mode: `spec.configRef` can point to a Secret containing `config.json`; the operator copies it only if config does not exist yet.

Safety rule implemented:
- `configRef` is currently supported only when `replicas=1`, to avoid cloning one key set across multiple TON nodes.

If you want per-replica pre-generated keys from Kubernetes Secrets, the next step is ordinal-aware secret mapping (for example `tonnode-0`, `tonnode-1`, ...).

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

Use one of these three flows:

### Flow A: Maintainer (build and publish operator release)

Use this flow if you maintain this repo.

Run commands from the repo root:
- this repository root directory (where `Makefile` is)

Requirements:
- `make`
- `docker`
- `kubectl`

Build and push controller image:

```bash
export OPERATOR_IMG=ghcr.io/neodix42/ton-k8s-operator:0.1.7
make docker-build docker-push IMG=$OPERATOR_IMG
```

Generate an installation bundle (CRD + RBAC + Deployment in one file):

```bash
make build-installer IMG=$OPERATOR_IMG
```

This creates:
- `dist/install.yaml`

Helm chart is in:
- `charts/ton-k8s-operator`

Package chart (optional, for release distribution):

```bash
mkdir -p dist/charts
helm package charts/ton-k8s-operator -d dist/charts
```

Operator image and Helm chart publish are automated by GitHub Actions:
- workflow: `.github/workflows/publish-operator.yml`
- trigger: every push to `main`
- target registries:
  - operator image: `ghcr.io/neodix42/ton-k8s-operator:<appVersion>`
  - chart: `oci://ghcr.io/neodix42/charts/ton-k8s-operator`
- behavior:
  - image tag is taken from `Chart.yaml` `appVersion` and pushed if that tag does not already exist
  - chart publish version is computed as higher semver of `version` and `appVersion` (without leading `v`), so appVersion-only bumps are still published; if that version already exists, push is skipped

Install operator:

```bash
helm install ton-k8s-operator ./charts/ton-k8s-operator \
  -n ton-k8s-operator-system \
  --create-namespace
```

Or install operator and create TON nodes in one command:

```bash
helm upgrade --install ton-k8s-operator ./charts/ton-k8s-operator \
  -n ton-k8s-operator-system \
  --create-namespace \
  --set tonNode.enabled=true \
  --set tonNode.namespace=default \
  --set tonNode.replicas=3 \
  --set tonNode.storage.storageClassName=local-path
```

To publish a new version, bump either `version` or `appVersion` in `charts/ton-k8s-operator/Chart.yaml`, then push to `main`.

Publish `dist/install.yaml` and/or packaged Helm chart (for example, in GitHub Releases).

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

Bootstrap local install bundle from a pinned release:

```bash
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.1.7/install.sh" | bash
```

The script:
- creates a local folder
- downloads chart from `oci://ghcr.io/neodix42/charts/ton-k8s-operator`
- extracts chart and prints next commands

The extracted chart already includes:
- `values.yaml`
- `operator-values.yaml`
- `tonnode-values.yaml`

Then follow:

```bash
cd ./ton-k8s-operator

# a) review defaults
ls -1 values.yaml operator-values.yaml tonnode-values.yaml

# b) install TON k8s operator only
helm install ton-k8s-operator . \
  -n ton-k8s-operator-system \
  --create-namespace \
  -f operator-values.yaml

# c) install TON nodes
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml

# d) verify
kubectl -n ton-k8s-operator-system get deploy,pods
kubectl -n default get tonnodes
kubectl -n default get sts,pods,pvc

# e) Stop/remove TON nodes and delete operator:
# stop and remove all TON nodes (keep operator)
helm upgrade ton-k8s-operator . \
 -n ton-k8s-operator-system \
 -f operator-values.yaml \
 --set tonNode.enabled=false
kubectl delete tonnodes.ton.ton.org --all -A

# optional destructive TON data cleanup
kubectl delete pvc -A -l app.kubernetes.io/name=ton-node

# delete operator release + namespace
helm uninstall ton-k8s-operator -n ton-k8s-operator-system
kubectl delete namespace ton-k8s-operator-system

# optional destructive CRD cleanup
kubectl delete crd tonnodes.ton.ton.org
```

`operator-values.yaml` keeps `tonNode.enabled=false` (operator only).
`tonnode-values.yaml` enables TON nodes and includes common `ton-docker-ctrl` env parameters.

### Cloud Install Options

For AWS/GCP/AliCloud, you can use any of these install paths:

- Cloud Shell (fastest): run the same release-pinned command above from AWS CloudShell, GCP Cloud Shell, or Alibaba Cloud Cloud Shell.
- CI/CD or bastion host: run `helm install/upgrade` from your deployment runner against the target kube-context.
- GitOps (recommended for production): use Argo CD or Flux with this chart and versioned values files.
- Terraform: use `helm_release` to install/upgrade declaratively.

Cloud provider dashboards can help create the cluster and open Cloud Shell, but this operator is not currently a managed one-click marketplace add-on. Installation is still done by Helm/kubectl.

### Upgrade Workflow (When Image Changes)

Use this workflow when the operator image and/or TON node image changes.

Maintainer release workflow:

```bash
# bump all project version pins
./upgrade.sh 0.1.7

# commit + push to main
git add .
git commit -m "release: 0.1.7"
git push origin main
```

`publish-operator.yml` will then publish:
- operator image: `ghcr.io/neodix42/ton-k8s-operator:0.1.7`
- chart: `oci://ghcr.io/neodix42/charts/ton-k8s-operator:0.1.7`
- release asset: `install.sh` on GitHub Release `0.1.7`

Cluster upgrade workflow:

```bash
# fetch new release installer and chart
wget -qO- "https://github.com/neodix42/ton-k8s-operator/releases/download/0.1.7/install.sh" | bash
cd ./ton-k8s-operator

# review values before upgrade
cat operator-values.yaml
cat tonnode-values.yaml
```

Upgrade operator only:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  --atomic --wait --timeout 20m
```

Upgrade operator and TON nodes:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --atomic --wait --timeout 40m
```

If only TON image is changed, keep an operator version and update the node image explicitly:

```bash
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/ton-blockchain/ton-docker-ctrl:<new-tag> \
  --atomic --wait --timeout 40m
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
  --atomic --wait --timeout 20m

# rollback TON node image explicitly
helm upgrade ton-k8s-operator . \
  -n ton-k8s-operator-system \
  -f operator-values.yaml \
  -f tonnode-values.yaml \
  --set-string tonNode.image=ghcr.io/ton-blockchain/ton-docker-ctrl:<old-tag> \
  --atomic --wait --timeout 40m
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
- `hostPortsEnabled`: default is `true`. This is required for direct TON reachability on bare-metal/public-node setups.
- Private cloud workers (no public node IP): provide per-node/per-replica public forwarding; one shared LB endpoint/port pair is not sufficient for many TON replicas.
- Storage class: explicitly set `spec.storage.storageClassName` when you need deterministic storage behavior.
- Bare metal: if Longhorn exists, operator prefers it automatically.
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

## Local Dev (k3d)

`make run` starts the operator manager process on your local machine (not as a Pod in Kubernetes).  
It uses your current `kubectl` context and watches/reconciles resources in that cluster.

Why use this in local test (k3d):
- fast development loop (edit code, rerun quickly)
- easy debugging/logs directly in your terminal
- no need to build/push operator image for every code change

Why you do not use `make run` in production:
- production operator should run as an in-cluster Deployment (`make deploy IMG=...`)
- local process is not highly available and depends on your workstation session

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

### Stop Local Run

- Stop `make run` with `Ctrl+C` in the terminal where it is running.

### Uninstall/Cleanup Local Dev

Delete sample resources:

```bash
kubectl delete -f config/samples/ton_v1alpha1_tonnode.yaml --ignore-not-found
```

Remove CRD from current cluster context:

```bash
make uninstall
```

If you also deployed operator as Deployment in cluster (via `make deploy`), remove it:

```bash
make undeploy
```

Optional cleanup for retained TON PVCs:

```bash
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
