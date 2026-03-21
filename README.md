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
- Enforces anti-affinity (`kubernetes.io/hostname`) so replicas of the same `TonNode` are not scheduled on the same worker.
- Auto-selects storage class:
  1. `spec.storage.storageClassName` (if set)
  2. `longhorn` if present
  3. cluster default StorageClass
  4. no class (cluster policy decides)
- Passes TON env vars expected by `ton-docker-ctrl`:
  - `PUBLIC_IP` (defaults from `status.hostIP` if not set)
  - `GLOBAL_CONFIG_URL`
  - `VALIDATOR_PORT`
  - `LITESERVER_PORT`
  - `VALIDATOR_CONSOLE_PORT`
- Sets `IGNORE_MINIMAL_REQS=true` by default (can be overridden through `spec.env`).

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
- k3d (or another Kubernetes cluster)

## Production Deployment

Yes, for production you must install this operator into the target cluster.
Installation means applying:
- CRD (`TonNode`)
- RBAC
- controller Deployment

Use one of these two flows:

### Flow A: Maintainer (build and publish operator release)

Use this flow if you maintain this repo.

Run commands from repo root:
- this repository root directory (where `Makefile` is)

Requirements:
- `make`
- `docker`
- `kubectl`

Build and push controller image:

```bash
export OPERATOR_IMG=ghcr.io/<your-org>/ton-k8s-operator:v0.1.0
make docker-build docker-push IMG=$OPERATOR_IMG
```

Generate install bundle (CRD + RBAC + Deployment in one file):

```bash
make build-installer IMG=$OPERATOR_IMG
```

This creates:
- `dist/install.yaml`

Publish `dist/install.yaml` (for example in a GitHub release or at a tag path in this repo), then cluster users can install with only `kubectl`.

### Flow B: Cluster User (install published operator, no clone/no make)

Use this flow if you only want to install and use the operator.

Requirements:
- `kubectl`
- access to a published `install.yaml` URL

Install:

```bash
kubectl apply -f https://raw.githubusercontent.com/<org>/<repo>/<tag>/dist/install.yaml
```

Verify:

```bash
kubectl get crd tonnodes.ton.ton.org
kubectl -n ton-k8s-operator-system get deploy,pods
```

Create TON nodes:

```bash
kubectl apply -f https://raw.githubusercontent.com/<org>/<repo>/<tag>/config/samples/ton_v1alpha1_tonnode.yaml
kubectl get tonnodes
```

Upgrade:
- apply a newer published `install.yaml` from a new tag/version.

Uninstall:

```bash
kubectl delete -f https://raw.githubusercontent.com/<org>/<repo>/<tag>/dist/install.yaml
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

- `PUBLIC_IP`: by default operator sets `PUBLIC_IP` from node host IP. If your worker IP is private/NATed, set `spec.network.publicIP`.
- Storage class: explicitly set `spec.storage.storageClassName` when you need deterministic storage behavior.
- Bare metal: if Longhorn exists, operator prefers it automatically.
- `IGNORE_MINIMAL_REQS`: default is `true` for easier local/k3d startup; for production set `spec.env: [{ name: IGNORE_MINIMAL_REQS, value: "false" }]`.
- Right-size resources in `spec.resources` for TON fullnode/validator workloads.

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
