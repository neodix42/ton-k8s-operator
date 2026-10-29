#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeton="$repo_root/charts/ton-k8s-operator/kubeton"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# These fixtures mirror Longhorn v1.10.0: EngineImage Pod templates omit the
# DaemonSet's longhorn.io/managed-by label; their EngineImage owner reference
# has no controller flag. CSIStorageCapacity ownership ends at a Deployment.
python3 - "$test_dir" <<'PY'
import copy, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
ns = 'longhorn-system'

def ref(api, kind, name, uid, **extra):
    return dict(apiVersion=api, kind=kind, name=name, uid=uid, **extra)

def obj(resource, api, kind, name, uid, labels=None, owners=None, annotations=None):
    return resource, dict(apiVersion=api, kind=kind, metadata=dict(name=name, namespace=ns, uid=uid,
        labels=labels or {}, annotations=annotations or {}, ownerReferences=owners or []))

managed = {'longhorn.io/managed-by': 'longhorn-manager'}
ei_labels = {'longhorn.io/component': 'engine-image', 'longhorn.io/engine-image': 'ei-26bab25d'}
ei_ref = ref('longhorn.io/v1beta2', 'EngineImage', 'ei-26bab25d', 'ei-uid', blockOwnerDeletion=True)
ei = obj('engineimages.longhorn.io', 'longhorn.io/v1beta2', 'EngineImage', 'ei-26bab25d', 'ei-uid')
ds = obj('daemonsets.apps', 'apps/v1', 'DaemonSet', 'engine-image-ei-26bab25d', 'ds-uid', dict(managed, **ei_labels), [ei_ref])
ds_ref = ref('apps/v1', 'DaemonSet', 'engine-image-ei-26bab25d', 'ds-uid', controller=True)
pod = obj('pods', 'v1', 'Pod', 'engine-image-ei-26bab25d-5sjbt', 'pod-uid', ei_labels, [ei_ref])
cases = []
def case(name, objects, allow=True, release='longhorn', denied=None, missing_api=None):
    cases.append((name, copy.deepcopy(objects), allow, release, denied, missing_api))

case('engine-image-direct-noncontroller-ref', [pod, ei])
case('engine-image-daemonset-chain', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ds_ref]), ds])
case('engine-image-either-valid-ref', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ei_ref, ds_ref]), ds])
case('daemonset-controllerrevision', [obj('controllerrevisions.apps', 'apps/v1', 'ControllerRevision', 'engine-image-ei-26bab25d-b76f9d86c', 'rev-uid', ei_labels, [ds_ref]), ds])
case('instance-manager-live-owner', [obj('pods', 'v1', 'Pod', 'instance-manager-1f5b12d3e03d9de412c1030d3190fe9d', 'im-pod-uid', {}, [ref('longhorn.io/v1beta2', 'InstanceManager', 'instance-manager-1f5b12d3e03d9de412c1030d3190fe9d', 'im-uid', controller=True)]), obj('instancemanagers.longhorn.io', 'longhorn.io/v1beta2', 'InstanceManager', 'instance-manager-1f5b12d3e03d9de412c1030d3190fe9d', 'im-uid')])
case('instance-manager-upstream-labels', [obj('pods', 'v1', 'Pod', 'instance-manager-1f5b12d3e03d9de412c1030d3190fe9d', 'im-pod-uid', dict(managed, **{'longhorn.io/component': 'instance-manager'}))])
case('engine-image-v1beta1-owner-converted-parent', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ref('longhorn.io/v1beta1', 'EngineImage', 'ei-26bab25d', 'ei-uid')]), ei])

csi = obj('deployments.apps', 'apps/v1', 'Deployment', 'csi-provisioner', 'csi-uid', dict(managed, app='csi-provisioner'))
csi_ref = ref('apps/v1', 'Deployment', 'csi-provisioner', 'csi-uid', controller=True)
rs = obj('replicasets.apps', 'apps/v1', 'ReplicaSet', 'csi-provisioner-545795d674', 'rs-uid', {}, [csi_ref])
case('csi-replicaset-pod-chain', [obj('pods', 'v1', 'Pod', 'csi-provisioner-545795d674-fxrsb', 'csi-pod-uid', {}, [ref('apps/v1', 'ReplicaSet', 'csi-provisioner-545795d674', 'rs-uid', controller=True)]), rs, csi])
case('csi-storagecapacity', [obj('csistoragecapacities.storage.k8s.io', 'storage.k8s.io/v1', 'CSIStorageCapacity', 'csisc-88ncf', 'capacity-uid', {}, [csi_ref]), csi])
service = obj('services', 'v1', 'Service', 'longhorn-backend', 'svc-uid', {'app.kubernetes.io/instance': 'longhorn'})
case('endpointslice-service-owner', [obj('endpointslices.discovery.k8s.io', 'discovery.k8s.io/v1', 'EndpointSlice', 'longhorn-backend-tddkq', 'slice-uid', {}, [ref('v1', 'Service', 'longhorn-backend', 'svc-uid', controller=True)]), service])
job = obj('jobs.batch', 'batch/v1', 'Job', 'longhorn-uninstall', 'job-uid', {'app.kubernetes.io/instance': 'longhorn'})
case('uninstall-hook-pod', [obj('pods', 'v1', 'Pod', 'longhorn-uninstall-vkzp6', 'hook-pod-uid', {}, [ref('batch/v1', 'Job', 'longhorn-uninstall', 'job-uid', controller=True)]), job])
custom_job = obj('jobs.batch', 'batch/v1', 'Job', 'longhorn-uninstall', 'job-uid', {'app.kubernetes.io/instance': 'storage-release'})
case('custom-release-owner', [obj('pods', 'v1', 'Pod', 'longhorn-uninstall-vkzp6', 'hook-pod-uid', {}, [ref('batch/v1', 'Job', 'longhorn-uninstall', 'job-uid', controller=True)]), custom_job], release='storage-release')
case('custom-release-engine-image', [pod, ei], release='storage-release')
case('system-restore-job-and-pod', [obj('pods', 'v1', 'Pod', 'system-rollout-restore1-qjq6v', 'restore-pod-uid', {}, [ref('batch/v1', 'Job', 'system-rollout-restore1', 'restore-job-uid', controller=True)]), obj('jobs.batch', 'batch/v1', 'Job', 'system-rollout-restore1', 'restore-job-uid', {}, [ref('longhorn.io/v1beta2', 'SystemRestore', 'restore1', 'restore-uid')]), obj('systemrestores.longhorn.io', 'longhorn.io/v1beta2', 'SystemRestore', 'restore1', 'restore-uid')])
case('support-bundle-deployment-pod-chain', [obj('pods', 'v1', 'Pod', 'supportbundle-manager-bundle1-566d8b9f6-cg99p', 'bundle-pod-uid', {'app': 'support-bundle-manager'}, [ref('apps/v1', 'ReplicaSet', 'supportbundle-manager-bundle1-566d8b9f6', 'bundle-rs-uid', controller=True)]), obj('replicasets.apps', 'apps/v1', 'ReplicaSet', 'supportbundle-manager-bundle1-566d8b9f6', 'bundle-rs-uid', {'app': 'support-bundle-manager'}, [ref('apps/v1', 'Deployment', 'supportbundle-manager-bundle1', 'bundle-dp-uid', controller=True)]), obj('deployments.apps', 'apps/v1', 'Deployment', 'supportbundle-manager-bundle1', 'bundle-dp-uid', {'app': 'support-bundle-manager'}, [ref('longhorn.io/v1beta2', 'SupportBundle', 'bundle1', 'bundle-uid')]), obj('supportbundles.longhorn.io', 'longhorn.io/v1beta2', 'SupportBundle', 'bundle1', 'bundle-uid')])
case('support-bundle-stale-owner', [obj('deployments.apps', 'apps/v1', 'Deployment', 'supportbundle-manager-bundle1', 'bundle-dp-uid', {'app': 'support-bundle-manager'}, [ref('longhorn.io/v1beta2', 'SupportBundle', 'bundle1', 'stale-bundle-uid')]), obj('supportbundles.longhorn.io', 'longhorn.io/v1beta2', 'SupportBundle', 'bundle1', 'bundle-uid')], False)

case('missing-parent', [pod], False)
case('name-labels-alone-not-ownership', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels)], False)
case('stale-owner-uid', [pod, obj('engineimages.longhorn.io', 'longhorn.io/v1beta2', 'EngineImage', 'ei-26bab25d', 'replacement-ei-uid')], False)
case('wrong-parent-kind', [pod, obj('engineimages.longhorn.io', 'longhorn.io/v1beta2', 'InstanceManager', 'ei-26bab25d', 'ei-uid')], False)
case('wrong-parent-api-group', [pod, obj('engineimages.longhorn.io', 'foreign.example/v1', 'EngineImage', 'ei-26bab25d', 'ei-uid')], False)
case('unsupported-owner-api', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ref('foreign.example/v1', 'EngineImage', 'ei-26bab25d', 'ei-uid')]), ei], False)
case('unsupported-owner-kind', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ref('longhorn.io/v1beta2', 'Arbitrary', 'ei-26bab25d', 'ei-uid')]), ei], False)
case('missing-owner-uid', [obj('pods', 'v1', 'Pod', pod[1]['metadata']['name'], 'pod-uid', ei_labels, [ref('longhorn.io/v1beta2', 'EngineImage', 'ei-26bab25d', '')]), ei], False)
case('denied-parent-read', [pod, ei], False, denied='engineimages.longhorn.io/ei-26bab25d')
case('denied-child-read', [pod, ei], False, denied='pods/' + pod[1]['metadata']['name'])
foreign_child = copy.deepcopy(pod); foreign_child[1]['metadata']['annotations'] = {'meta.helm.sh/release-name': 'another-release', 'meta.helm.sh/release-namespace': ns}
case('foreign-child-helm-identity', [foreign_child, ei], False)
foreign_parent = copy.deepcopy(ei); foreign_parent[1]['metadata']['labels'] = {'app.kubernetes.io/instance': 'another-release'}
case('foreign-parent-helm-identity', [pod, foreign_parent], False)
foreign_parent_ns = copy.deepcopy(ei); foreign_parent_ns[1]['metadata']['annotations'] = {'meta.helm.sh/release-namespace': 'another-namespace'}
case('foreign-parent-helm-namespace', [pod, foreign_parent_ns], False)
wrong_namespace = copy.deepcopy(ei); wrong_namespace[1]['metadata']['namespace'] = 'another-namespace'
case('cross-namespace-parent-response', [pod, wrong_namespace], False)
cycle_a = obj('pods', 'v1', 'Pod', 'cycle-pod', 'cycle-pod-uid', {}, [ref('apps/v1', 'ReplicaSet', 'cycle-a', 'a-uid')])
cycle_rs = obj('replicasets.apps', 'apps/v1', 'ReplicaSet', 'cycle-a', 'a-uid', {}, [ref('apps/v1', 'ReplicaSet', 'cycle-b', 'b-uid')])
cycle_b = obj('replicasets.apps', 'apps/v1', 'ReplicaSet', 'cycle-b', 'b-uid', {}, [ref('apps/v1', 'ReplicaSet', 'cycle-a', 'a-uid')])
case('owner-cycle', [cycle_a, cycle_rs, cycle_b], False)
chain = [obj('pods', 'v1', 'Pod', 'deep-pod', 'deep-pod-uid', {}, [ref('apps/v1', 'ReplicaSet', 'deep-0', 'deep-0-uid')])]
for i in range(9):
    chain.append(obj('replicasets.apps', 'apps/v1', 'ReplicaSet', 'deep-' + str(i), 'deep-' + str(i) + '-uid', managed if i == 8 else {}, [] if i == 8 else [ref('apps/v1', 'ReplicaSet', 'deep-' + str(i+1), 'deep-' + str(i+1) + '-uid')]))
case('bounded-owner-depth', chain, False)
case('foreign-label-even-with-managed-by', [obj('pods', 'v1', 'Pod', 'foreign-pod', 'foreign-uid', dict(managed, **{'app.kubernetes.io/instance': 'another-release'}))], False)
case('foreign-helm-secret-identity', [obj('secrets', 'v1', 'Secret', 'sh.helm.release.v1.other.v1', 'foreign-secret-uid', {'owner': 'helm', 'name': 'another-release', 'longhorn.io/managed-by': 'longhorn-manager'})], False)
case('foreign-namespace-even-with-managed-by', [obj('pods', 'v1', 'Pod', 'foreign-pod', 'foreign-uid', managed, annotations={'meta.helm.sh/release-namespace': 'foreign-system'})], False)
case('foreign-release-even-with-own-instance', [obj('pods', 'v1', 'Pod', 'foreign-pod', 'foreign-uid', {'app.kubernetes.io/instance': 'longhorn'}, annotations={'meta.helm.sh/release-name': 'another-release'})], False)
for malformed in ('header-extra-empty-column', 'owner-extra-empty-column', 'tab-in-header', 'carriage-return-in-owner'):
    case('malformed-' + malformed, [pod, ei], False)

for name, objects, allow, release, denied, missing_api in cases:
    d = out / name; d.mkdir()
    (d / 'expect').write_text('allow' if allow else 'deny')
    (d / 'release').write_text(release)
    (d / 'denied').write_text(denied or '')
    resources=[]; inventories={}
    for resource, value in objects:
        if resource not in resources: resources.append(resource)
        meta = value['metadata']; labels = meta['labels']; annotations = meta['annotations']; n = meta['name']
        columns=[n, labels.get('app.kubernetes.io/instance'), labels.get('release'), annotations.get('meta.helm.sh/release-name'), annotations.get('meta.helm.sh/release-namespace'), labels.get('app'), labels.get('app.kubernetes.io/name'), labels.get('owner'), labels.get('name'), labels.get('longhorn.io/managed-by'), labels.get('kubernetes.io/service-name'), None, None]
        inventories.setdefault(resource, []).append(' '.join(v or '<none>' for v in columns))
        meta_columns=['META', value['apiVersion'], value['kind'], meta['namespace'], n, meta['uid'], labels.get('app.kubernetes.io/instance',''), labels.get('release',''), annotations.get('meta.helm.sh/release-name',''), annotations.get('meta.helm.sh/release-namespace',''), labels.get('longhorn.io/managed-by',''), labels.get('app',''), labels.get('app.kubernetes.io/name',''), labels.get('owner',''), labels.get('name','')]
        owner_rows=['|'.join(['OWNER', r['apiVersion'], r['kind'], r['name'], r['uid']]) for r in meta['ownerReferences']]
        (d / (resource + '__' + n)).write_text('\n'.join(['|'.join(meta_columns), *owner_rows]) + '\n')
    (d / 'resources').write_text('\n'.join(resources) + '\n')
    for resource, inventory in inventories.items(): (d / (resource + '__list')).write_text('\n'.join(inventory) + '\n')
    if name.startswith('malformed-'):
        path = d / (objects[0][0] + '__' + objects[0][1]['metadata']['name'])
        rows = path.read_text().splitlines()
        if name == 'malformed-header-extra-empty-column': rows[0] += '|'
        if name == 'malformed-owner-extra-empty-column': rows[1] += '|'
        if name == 'malformed-tab-in-header': rows[0] = rows[0].replace('pod-uid', 'pod-uid\t')
        if name == 'malformed-carriage-return-in-owner': rows[1] += '\r'
        path.write_text('\n'.join(rows) + '\n')
PY

source "$kubeton"
# Helm inventory is intentionally separate from per-object ownership checks.
storage_list_helm_releases() { cat "$fixture_dir/release"; }
kubectl() {
  printf '%s\n' "$*" >>"$fixture_dir/calls"
  if [[ "$*" == 'get namespace longhorn-system --ignore-not-found -o name' ]]; then
    echo namespace/longhorn-system; return 0
  fi
  if [[ "$*" == "get namespace longhorn-system --ignore-not-found -o jsonpath={.metadata.uid}" ]]; then
    printf '%s' "${mock_namespace_uid:-namespace-uid}"; return 0
  fi
  if [[ "$1" == api-resources ]]; then cat "$fixture_dir/resources"; return 0; fi
  if [[ "$1" == -n && "$2" == longhorn-system && "$3" == get ]]; then
    local resource="$4" object="$5" path denied
    denied="$(cat "$fixture_dir/denied")"
    if [[ "$object" == --ignore-not-found ]]; then
      [[ "$*" == *'custom-columns='* ]] || return 92
      path="$fixture_dir/${resource}__list"
    else
      [[ "$*" == *'jsonpath={"META|"}'* ]] || return 93
      [[ "$resource/$object" != "$denied" ]] || return 19
      path="$fixture_dir/${resource}__${object}"
    fi
    [[ ! -f "$path" ]] || cat "$path"
    return 0
  fi
  echo "Unexpected mock API request: $*" >&2
  return 91
}

count=0
for fixture_dir in "$test_dir"/*; do
  release="$(cat "$fixture_dir/release")"
  expected="$(cat "$fixture_dir/expect")"
  actual=deny
  if storage_namespace_is_release_owned longhorn-system "$release" longhorn >"$fixture_dir/output" 2>&1; then actual=allow; fi
  if [[ "$actual" != "$expected" ]]; then
    echo "Longhorn ownership scenario $(basename "$fixture_dir"): expected $expected, got $actual" >&2
    cat "$fixture_dir/output" "$fixture_dir/calls" >&2
    exit 1
  fi
  # The bound and visited set make malformed ownership graphs finite.
  if [[ "$(basename "$fixture_dir")" == owner-cycle ]]; then
    calls="$(wc -l <"$fixture_dir/calls")"
    (( calls < 12 )) || { echo 'Owner cycle was not bounded' >&2; exit 1; }
  fi
  count=$((count + 1))
done
# One cleanup invocation may reuse ownership already proven for the exact
# child UID after Helm removes its parents. This proof never survives the
# caller's function scope and cannot authorize a replacement/foreign child.
cache_fixture="$test_dir/cache-regression"
cp -R "$test_dir/engine-image-direct-noncontroller-ref" "$cache_fixture"
fixture_dir="$cache_fixture"
cache_scope_regressions() {
  local KUBETON_LONGHORN_OWNER_CACHE_ACTIVE=true
  local KUBETON_LONGHORN_OWNER_CACHE_NAMESPACE_UID=namespace-uid
  local -A KUBETON_LONGHORN_PROVEN_OWNERS=()
  local resource=pods object=engine-image-ei-26bab25d-5sjbt
  storage_namespace_is_release_owned longhorn-system longhorn longhorn
  rm "$fixture_dir/engineimages.longhorn.io__ei-26bab25d"
  storage_namespace_is_release_owned longhorn-system longhorn longhorn
  cp "$fixture_dir/pods__${object}" "$fixture_dir/original-child"
  sed -i 's/pod-uid/replacement-pod-uid/' "$fixture_dir/pods__${object}"
  if longhorn_object_has_release_owner longhorn-system longhorn "$resource" "$object"; then
    echo 'Cached ownership authorized a replacement Pod UID' >&2; exit 1
  fi
  cp "$fixture_dir/original-child" "$fixture_dir/pods__${object}"
  # The fresh response now carries a foreign Helm release despite same UID.
  sed -i 's/|pod-uid||||/|pod-uid|foreign-release|||/' "$fixture_dir/pods__${object}"
  if longhorn_object_has_release_owner longhorn-system longhorn "$resource" "$object"; then
    echo 'Cached ownership authorized conflicting Helm identity' >&2; exit 1
  fi
  cp "$fixture_dir/original-child" "$fixture_dir/pods__${object}"
  local mock_namespace_uid=recreated-namespace-uid
  if storage_namespace_is_release_owned longhorn-system longhorn longhorn >"$fixture_dir/ns-replaced" 2>&1; then
    echo 'Cached ownership authorized a replacement namespace UID' >&2; exit 1
  fi
  grep -Fq 'namespace longhorn-system changed during teardown' "$fixture_dir/ns-replaced"
}
cache_scope_regressions
if longhorn_object_has_release_owner longhorn-system longhorn pods engine-image-ei-26bab25d-5sjbt; then
  echo 'Teardown ownership cache leaked beyond caller scope' >&2; exit 1
fi
count=$((count + 6))
printf 'Longhorn namespace ownership checks passed (%s scenarios).\n' "$count"
