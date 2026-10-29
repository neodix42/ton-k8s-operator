# TON Node Key Security Model

This document describes the implemented key protection workflow in `ton-k8s-operator`:

- external root of trust (`Vault Transit` or cloud `KMS`)
- live controller state, signing keys, validator keyring and staging in pod memory (`emptyDir{medium: Memory}`)
- encrypted key bundle at rest (dedicated PVC)

It also documents cluster-level controls (`etcd` encryption with KMS provider) and residual risks.

## 1. Direct Answers

### 1.1 Where plaintext keys are exposed

With key management enabled, normal managed operations handle plaintext in
memory. Restore decrypts and unpacks archives on memory-backed `/tmp`, then
restores controller state, wallet files, console keys and the validator keyring
into tmpfs. Runtime processes read those files and keep key material in process
memory. Backup copies and compresses that state in memory before encryption;
only encrypted recovery data and wrapped-key metadata are published to the
bundle PVC.

Fresh keys are generated in memory before their first encrypted checkpoint.
An abrupt failure in that interval can lose them. Subsequent changes become
durable only after a successful checkpoint, so this is not a zero-loss storage
system. Graceful shutdown quiesces services and attempts a final checkpoint.

Secret operations check the required tmpfs mounts and reject workers with
active swap. Managed entrypoints and the collection driver disable process
core dumps. Host crash-dump collectors, hibernation and other privileged host
mechanisms require separate administration.

The main-wallet helper also checks its tmpfs runtime and worker swap state.
Its plaintext archives and generic temporary files stay under its memory-backed
runtime; `/tmp` is a separate memory volume. Its persistent public `.outbox`
contains signed BOCs and payment journals, not wallet private keys, and remains
durable for duplicate-payment prevention.

Public `/var/ton-work/db/config.json` remains on the work PVC. It contains
advertised addresses and key identifiers rather than private signing keys.
Blockchain databases and dump files also stay on that PVC. With key management
disabled, live controller state and private keys use the work PVC as before.

### 1.2 Fleet migration recovery keys

Fleet migration adds another controlled exposure window: `backup-fleet` unwraps
each bundle's data key using the source Vault and streams it into GnuPG inside
a temporary tools pod. `recovery.gpg` protects those data keys with a separate
passphrase and binds them to the fleet manifest and bundle checksums. Recovery
keys exist in process memory and pipes; no plaintext recovery-key file is
created. The passphrase is entered at a hidden terminal prompt and streamed
over kubectl exec stdin; it is not stored in Pod env or command arguments.
The live TonNode specification in `fleet.json` is not encrypted
and can contain literal environment values, so the backup directory is private
(`0700`) and must be handled as sensitive operational data.

The fleet backup plus its passphrase can recover identities without the source
Vault. Protecting and storing that passphrase separately is therefore part of
the recovery trust model. Destination helpers decrypt/rebind bundles on an
`emptyDir{medium: Memory}` scratch volume, rewrap their data keys with the new
Vault, verify encryption/decryption and copied ciphertext, and persist only
encrypted bundles on the destination bundle PVCs. Neither Vault root tokens nor
unseal keys are included in the portable backup.

The tools ServiceAccount and RBAC are temporary. Backup has resource-specific
permissions for workload scaling, pod exec/copy and reads. Restore requires a
temporary cluster-admin binding to install CRDs, operator RBAC and prerequisites.
The caller must have the corresponding Kubernetes privileges. Tool scratch
volumes use memory. If remote cleanup cannot be confirmed after a lost
connection, the tools pod and binding remain available for cleanup and kubeton
prints their names; they must be removed once that cleanup finishes.

### 1.3 Can an admin still extract plaintext keys?

Yes, a privileged cluster/node admin can still extract plaintext keys.

Examples:
- `kubectl exec` into pod with sufficient RBAC
- host root access (container runtime / proc memory / filesystem)
- direct etcd access if secrets encryption is weak/misconfigured

This model significantly reduces accidental exposure and at-rest leakage, but it does not protect against fully privileged administrators. That requires stronger controls (separation of duties, break-glass process, audited privileged access, HSM-backed signing).

## 2. Architecture Overview

When `spec.keyManagement.enabled=true`, operator configures:

1. Memory-backed runtime mounts:

| Path | Default limit | `spec.keyManagement.inMemory` setting |
|---|---|---|
| `/var/ton-work/controller` | `512Mi` | `controllerSizeLimit` |
| `/var/ton-work/keys` | `128Mi` | `keysSizeLimit` |
| `/var/ton-work/controller/mytoncore/wallets` | `512Mi` | `walletsSizeLimit` |
| `/var/ton-work/db/keyring` | `128Mi` | `keyringSizeLimit` |
| `/tmp` | `2Gi` | `stagingSizeLimit` |
| `/run` | `2Gi` | `stagingSizeLimit` |

The controller mount includes `mytoncore.db`, its local backup copies,
configuration, credentials, service units, wallet metadata and collection
journals. `/run` also contains the selected TON artifact snapshot. These limits
bound use; they do not reserve worker memory. Budget container and worker
memory for live files, artifact copies, plaintext staging, compressed archives
and encryption verification.

2. Encrypted bundle persistence:
- dedicated PVC claim template: `keybundle`
- mounted at `/var/ton-key-bundle`
- stores encrypted archives, wrapped-key metadata and public recovery/control markers

3. Init restore container (`key-restore`):
- decrypts existing encrypted bundle
- restores plaintext key files into tmpfs mounts before TON starts

4. Backup sidecar (`key-backup`):
- packages controller state and keys from tmpfs
- envelope-encrypts bundle
- persists only encrypted files to `keybundle` PVC
- checks for changed state about every two seconds and automatically checkpoints it
- preserves resumable partial initialization in encrypted checkpoints
- also handles explicit checkpoint requests and graceful shutdown

Readiness requires committed initialization, active validator/MyTonCore services
and an encrypted recovery bundle. Readiness does not establish an off-cluster
backup. Snapshot duration, changing files or Vault/KMS outages can delay later
checkpoints; failures preserve the previous committed bundle.

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
      controllerSizeLimit: 512Mi
      keyringSizeLimit: 128Mi
      stagingSizeLimit: 2Gi
    encryptedBundle:
      pvcSize: 5Gi
      storageClassName: encrypted-sc
      accessModes:
        - ReadWriteOnce
      fileName: keys.bundle.enc
      metaFileName: keys.bundle.meta
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
   Restores MyTonCtrl state to memory-backed `/var/ton-work/controller` and
   validator private keys to memory-backed `/var/ton-work/db/keyring`.
   Public validator configuration remains on the work PVC.
6. TON main container starts.

Bundles from the former `ton-docker-ctrl` layout contain `mytoncore/` and `mytonctrl/`
at the archive root. The new restore init container rejects that legacy layout with
migration instructions and preserves the existing state. Import a native
MyTonCtrl backup into a fresh work volume, then create a new encrypted bundle;
renaming archive directories does not reconstruct the required controller state.

### 5.2 Automatic and explicit checkpoints

1. `key-backup` gathers tmpfs keys, MyTonCtrl controller state, and selected TON DB key files.
2. Copies and compresses the state on memory-backed `/tmp`.
3. Generates random data key.
4. Wraps data key with Vault/KMS.
5. Verifies provider unwrap, encrypts the archive, and verifies decryption.
6. Publishes encrypted bundle + metadata using a durable rollback journal on
   the keybundle PVC. Interrupted publication is recovered before backup or restore;
   plaintext staging is never placed in that journal.
7. The sidecar polls for changed state and explicit requests. It publishes only
   a stable source revision and retries changing state or provider failures.

Initialization checkpoints may contain `.initializing` before the final
`initialized.json` commit. They allow an ordinary Pod replacement to resume
initialization without persisting controller secrets in plaintext. A manual
`backup-keys` export requires complete initialization.

Collection journals live in the controller memory volume. Before a new `mg`
payment, `kubeton wallet collect` waits for a uniquely identified encrypted
checkpoint acknowledgement. Missing support, failure or a 60-second timeout
prevents signing. An unresolved collection retains its pending identity for
receipt verification without another payment submission.

Managed Pod termination quiesces MyTonCore and validator services and attempts a
final encrypted checkpoint. `kubeton stop` also supports an explicit pre-stop
backup with `SKIP_STOP_KEY_BACKUP=false`; this is skipped by default. Neither
mechanism can guarantee a final write after forced deletion, power loss or a
process crash.

### 5.3 Manual admin backup (required)

Use the helper script to perform a quiesced encrypted backup:

1. `./kubeton backup-keys [output-dir]`
2. Script triggers one explicit encrypted backup in each running TON pod.
3. Script copies only encrypted bundle PVC contents to local backup directory.
4. Script computes `SHA256SUMS`.
5. Script scales TON StatefulSets to `0`, exports bundles, then restores original replica counts.

Exact exported files per replica (`<output-dir>/<namespace>/<statefulset>/<ordinal>/`):
- `bundle/keys.bundle.enc`
- `bundle/keys.bundle.meta`
- `SHA256SUMS`
- `keys.bundle.enc` decrypts to a tar archive with top-level folders:
- `keys/` = all files from pod path `/var/ton-work/keys/**`
- `controller/` = all state from pod path `/var/ton-work/controller/**`, including
  MyTonCore wallets, MyTonCtrl state, enabled services, configuration, and initialization markers
- `tondb/` = selected TON DB key files:
- `tondb/config.json` from pod path `/var/ton-work/db/config.json`
- `tondb/keyring/**` from pod path `/var/ton-work/db/keyring/**`
- common examples included from `keys/`: `client.pub`, `liteserver.pub`, `client`, `server.pub`
- common examples included from `controller/`: `mytoncore/wallets/validator_wallet_001.pk`
  and `mytonctrl/` configuration files
- `keys.bundle.meta` stores metadata fields used for restore: `provider`, `wrapped_key`, `algorithm`, `created_at`
- TON DB data outside this set (`/var/ton-work/db/celldb/**`, `/var/ton-work/db/archive/**`, etc.) is not included.
- if `spec.keyManagement.encryptedBundle.fileName` / `metaFileName` are customized, backup uses those exact filenames instead of defaults.

Mandatory operation rules:
- run `./kubeton backup-keys` immediately after successful `./kubeton start` to create an exported recovery copy, then move it off-cluster
- run `./kubeton backup-keys` after every validator/wallet key change or rotation
- keep using `./kubeton backup-keys` before destructive operations (`drop`, `uninstall`, PVC deletion) to keep an exported offline copy

Automatic checkpoints provide in-cluster persistence only. They neither copy
bundles off-cluster nor preserve the root of trust if Vault/KMS is lost.

### 5.4 Manual admin restore

Use:

1. `./kubeton restore-keys <input-dir>`
2. Script scales TON StatefulSets to `0` automatically.
3. For each current replica ordinal, script validates `SHA256SUMS` when present.
4. Script overwrites each `keybundle-<statefulset>-<ordinal>` PVC from `<input-dir>/<namespace>/<statefulset>/<ordinal>/bundle`.
5. Missing backup dirs are reported and skipped; restore continues for other replicas.
6. Script restores StatefulSet replicas; `key-restore` init container decrypts bundle and restores files into pod paths.

Root-of-trust continuity requirement:
- Vault mode: restore works only if the same Vault Transit key material/history is still available.
- KMS mode: restore works only if the same KMS key resource can decrypt previously wrapped data keys.
- If Vault is reinitialized (new storage/new keys) or old KMS key is deleted/disabled, old bundles are not decryptable.

Operational note about `drop`/`uninstall`:
- `kubeton drop` removes TON resources/PVCs, Longhorn backing artifacts, and kubeton TON directories left under the local-path provisioner root.
- `kubeton uninstall` is a full best-effort cleanup of kubeton-managed resources: TON PVCs, local-path backing directories, observability/VictoriaLogs resources, main-wallet/debug helpers, operator, Longhorn, Vault, and `encrypted-sc` StorageClass. It keeps the cluster-scoped `TonNode` CRD; use `kubeton purge` to remove it.
- local-path host cleanup uses exact PV paths captured from live PVC/PV objects by default; wildcard stale-directory cleanup by PVC name is opt-in with `KUBETON_LOCAL_PATH_PATTERN_CLEANUP=true`.
- if Kubernetes is still terminating resources or a cleanup step errors, uninstall reports leftovers and asks you to rerun `./kubeton uninstall`.
- If admins manually delete Vault data (or the whole cluster), Transit key history is lost and encrypted bundles cannot be decrypted.

### 5.5 Adopting memory-backed state on an existing deployment

Take and verify an external encrypted backup before rollout and preserve its
Vault/KMS root of trust. Disable swap on eligible workers and provide enough
memory for runtime and checkpoint staging. Apply the updated operator and
bundled CRD, then apply TonNode values with the matching chart/CLI. Updating
only `kubeton` does not replace existing Pod mounts.

For the current native MyTonCtrl layout, the restore init container reads the
underlying work PVC through a separate mount. It copies known controller,
console-key and validator-keyring paths into memory. Existing encrypted bundles
supply wallets and console keys already kept in RAM by earlier versions;
current persistent controller settings are merged into that state. Conflicting
private files stop migration and preserve both sources for explicit recovery.
It encrypts the merged state and verifies
provider unwrap and actual archive decryption before unlinking the known
plaintext originals. If preservation cannot be verified, startup stops and
the original files remain available. Legacy `ton-docker-ctrl` layouts remain
blocked and preserved rather than being silently converted.

The bundle PVC records `.historical-plaintext-exposure` and startup warns when
old plaintext was encountered. **Unlinking files is not secure erasure.**
Previously written blocks, storage snapshots, backups and deprecated PVCs can
still contain plaintext. They are not automatically wiped. For historical
plaintext assurance, restore onto fresh storage and arrange secure retirement
or sanitization of all old copies through the storage provider. Capture a new
off-cluster backup after rollout.

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
2. Sudden failure can lose changes since the last successful checkpoint,
   including a newly generated key before its first checkpoint. Automatic
   snapshots and graceful shutdown are not synchronous, zero-loss persistence.
3. Historical plaintext on old storage, snapshots and backups is not securely
   erased by migration. Optional services and user-selected export/backup paths
   can write outside the managed secret mounts.
4. Kubernetes Secrets/etcd encryption, Vault storage, host crash-dump collectors,
   application logs and administrative exports need separate controls. The
   plaintext `fleet.json` manifest may include literal environment values.
5. KMS mode depends on required CLI/tooling present in `keyManagement.agent.image`.
6. This model protects standard managed key files and staging paths; it does
   not protect against memory forensics, kernel compromise or privileged
   administrators who bypass these paths and process limits.

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
