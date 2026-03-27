# TON Node Key Security Model

This document describes the implemented key protection workflow in `ton-k8s-operator`:

- external root of trust (`Vault Transit` or cloud `KMS`)
- live keys in pod memory (`emptyDir{medium: Memory}`)
- encrypted key bundle at rest (dedicated PVC)

It also documents cluster-level controls (`etcd` encryption with KMS provider) and residual risks.

## 1. Direct Answers

### 1.1 Where plaintext keys are exposed

Even with this model, plaintext key material exists in controlled windows:

1. During restore init container:
- the encrypted bundle is decrypted in memory/tmp files inside the init container.
- plaintext keys are written into tmpfs mounts:
  - `/var/ton-work/keys`
  - `/usr/local/bin/mytoncore/wallets`

2. During node runtime:
- validator and supporting processes keep keys in process memory.
- key files remain plaintext in tmpfs only (not on PVC by default).

3. During the backup sidecar operation:
- sidecar reads plaintext keys from tmpfs.
- creates a short-lived plaintext tarball in sidecar filesystem (`/tmp`) before encrypting.

4. During the first boot key generation (no bundle yet):
- TON container generates keys directly into tmpfs.
- the backup sidecar then encrypts and stores a bundle.

### 1.2 Can an admin still extract plaintext keys?

Yes, a privileged cluster/node admin can still extract plaintext keys.

Examples:
- `kubectl exec` into pod with sufficient RBAC
- host root access (container runtime / proc memory / filesystem)
- direct etcd access if secrets encryption is weak/misconfigured

This model significantly reduces accidental exposure and at-rest leakage, but it does not protect against fully privileged administrators. That requires stronger controls (separation of duties, break-glass process, audited privileged access, HSM-backed signing).

## 2. Architecture Overview

When `spec.keyManagement.enabled=true`, operator configures:

1. In-memory key mounts:
- `emptyDir{medium: Memory}` on `/var/ton-work/keys`
- `emptyDir{medium: Memory}` on `/usr/local/bin/mytoncore/wallets`

2. Encrypted bundle persistence:
- dedicated PVC claim template: `keybundle`
- mounted at `/var/ton-key-bundle`
- stores only encrypted artifacts (`keys.bundle.enc`, `keys.bundle.meta`)

3. Init restore container (`key-restore`):
- decrypts existing encrypted bundle
- restores plaintext key files into tmpfs mounts before TON starts

4. Backup sidecar (`key-backup`):
- periodically packages current tmpfs keys
- envelope-encrypts bundle
- persists only encrypted files to `keybundle` PVC
- runs backup again on pod termination signal (`SIGTERM`)

## 3. CRD Configuration

`TonNode` now supports `spec.keyManagement`.

Minimal Vault example:

```yaml
spec:
  keyManagement:
    enabled: true
    provider: vault
    credentialsSecretRef:
      name: tonnode-key-provider
    vaultTransitKey: ton-validator
    inMemory:
      keysSizeLimit: 128Mi
      walletsSizeLimit: 512Mi
    encryptedBundle:
      pvcSize: 5Gi
      storageClassName: encrypted-sc
      accessModes:
        - ReadWriteOnce
      fileName: keys.bundle.enc
      metaFileName: keys.bundle.meta
      backupIntervalSeconds: 300
    agent:
      image: ghcr.io/ton-blockchain/ton-docker-ctrl:latest
```

Minimal KMS example:

```yaml
spec:
  keyManagement:
    enabled: true
    provider: kms
    kmsVendor: aws
    kmsKeyID: arn:aws:kms:eu-central-1:111111111111:key/abcd-...
    credentialsSecretRef:
      name: tonnode-key-provider
```

Validation rules enforced by the operator:

- `credentialsSecretRef.name` is required when enabled
- `provider=vault` requires `vaultTransitKey`
- `provider=kms` requires `kmsKeyID` and `kmsVendor` (`aws` or `gcp`)
- `encryptedBundle.backupIntervalSeconds >= 30`

## 4. Provider Secret Requirements

The credentials secret is injected into init/sidecar containers via `envFrom`.

### 4.1 Vault (`provider: vault`)

Required keys in secret:

- `VAULT_ADDR`
- `VAULT_TOKEN`

Optional keys:

- `VAULT_NAMESPACE`

`VAULT_TRANSIT_KEY` is normally provided in CR (`spec.keyManagement.vaultTransitKey`).

Example:

```bash
kubectl -n default create secret generic tonnode-key-provider \
  --from-literal=VAULT_ADDR=https://vault.example.internal \
  --from-literal=VAULT_TOKEN='s.xxxxx' \
  --from-literal=VAULT_NAMESPACE=ton
```

Bare-metal automated profile (`kubeton start` or `kubeton bootstrap-baremetal`) creates:
- in-cluster Vault deployment
- Transit key and policy
- TON credential secret `ton-vault-creds` in TON namespace (default `default`)

### 4.2 AWS KMS (`provider: kms`, `kmsVendor: aws`)

Usually required in secret (unless workload identity/IRSA is used):

- `AWS_REGION`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- optional `AWS_SESSION_TOKEN`

`KMS_KEY_ID` is normally provided in CR (`spec.keyManagement.kmsKeyID`).

### 4.3 GCP KMS (`provider: kms`, `kmsVendor: gcp`)

Required environment variables:

- `KMS_PROJECT_ID`
- `KMS_LOCATION`
- `KMS_KEY_RING`
- `KMS_KEY_ID` (CryptoKey name)

Authentication should be done via Workload Identity or by mounting a service account key (less preferred).

## 5. Encryption Workflow

### 5.1 Restore path (pod start)

1. `key-restore` checks for encrypted bundle files in `/var/ton-key-bundle`.
2. Reads wrapped data key from metadata file.
3. Unwraps a data key using selected provider:
- Vault Transit decrypt API, or
- KMS CLI decrypt.
4. Decrypts encrypted tarball (`openssl`).
5. Restores plaintext key files to tmpfs mounts.
6. TON main container starts.

### 5.2 Backup path (runtime / termination)

1. `key-backup` scans tmpfs key folders.
2. Creates tarball in sidecar temp storage.
3. Generates random data key.
4. Wraps data key with Vault/KMS.
5. Encrypts tarball with data key.
6. Writes encrypted bundle + metadata atomically to keybundle PVC.
7. Repeats by interval and on termination signal.

## 6. Storage Encryption for Keys Only

Use a dedicated encrypted StorageClass only for key bundle PVC:

1. Create/select encrypted StorageClass (cloud CMK, or bare-metal encrypted backend).
2. Set:

```yaml
spec:
  keyManagement:
    enabled: true
    encryptedBundle:
      storageClassName: encrypted-sc
```

This keeps TON data PVCs on regular storage while key bundle PVC uses encrypted backend.

## 7. etcd Secret Encryption with KMS Provider (Cluster-Level)

If Kubernetes Secrets are used for credentials, encrypt them in etcd with KMS provider.

High-level steps (cluster admin):

1. Configure a KMS provider plugin endpoint (cloud provider or external plugin).
2. Create kube-apiserver `EncryptionConfiguration`, for example:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - kms:
          apiVersion: v2
          name: external-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}
```

3. Start kube-apiserver with:
- `--encryption-provider-config=/path/to/encryption-config.yaml`

4. Restart kube-apiserver (according to your control-plane management method).
5. Re-encrypt existing secrets (rotate by rewriting):
- patch or replace each Secret in a controlled rollout so data is rewritten under new provider config.
6. Validate encryption at rest by inspecting etcd raw data (admin procedure).

Note: this is outside the operator scope and must be implemented by cluster administrators.

## 8. Operational Hardening Recommendations

1. Restrict RBAC:
- deny broad `pods/exec` and secret read access to regular operators.

2. Use workload identity over static cloud credentials:
- AWS IRSA / EKS Pod Identity
- GCP Workload Identity

3. NetworkPolicy:
- allow sidecar/init egress only to Vault/KMS endpoints.

4. Pod security:
- keep `allowPrivilegeEscalation=false`
- run as non-root where image permits
- apply seccomp/AppArmor profiles

5. Rotation:
- rotate Vault token / cloud credentials regularly.
- rotate KMS/Vault wrapping keys according to policy.
- force bundle rewrite after rotation.

## 9. Current Limitations

1. Node/cluster admin with high privilege can still extract plaintext.
2. Sidecar uses a temporary plaintext archive during backup inside container ephemeral FS.
3. KMS mode depends on required CLI/tooling present in `keyManagement.agent.image`.
4. This model protects key files at rest and in regular runtime flows, not memory forensics or kernel compromise.

## 10. Bare-Metal Auto Bootstrap

`kubeton` now includes a bare-metal bootstrap profile that runs before TON deployment:

1. installs Longhorn v1 (`LONGHORN_CHART_VERSION`, default `1.10.0`)
2. creates Longhorn crypto secret and encrypted StorageClass `encrypted-sc`
3. installs Vault chart (`VAULT_CHART_VERSION`, default `0.30.0`)
4. initializes/unseals Vault, enables Transit, creates Transit key `ton-validator`
5. creates Vault policy + token and writes TON secret `ton-vault-creds`
6. deploys TonNode with key-management enabled and encrypted bundle storage class set to `encrypted-sc`

Operational note:
- bootstrap stores Vault unseal/root material in Kubernetes secret `ton-vault-bootstrap` (namespace `vault`)
- rotate and restrict access to this secret, or replace bootstrap flow with your production Vault process

Cloud clusters:
- bare-metal bootstrap is skipped by default
- admins must provide prerequisites (encrypted StorageClass + Vault/KMS credentials secret) before TON start
