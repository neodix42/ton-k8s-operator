#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin"

# Model Kubernetes objects and their immutable ownership links, rather than
# replacing any production cleanup/ownership helper. Every unhandled API call
# is a test failure, including calls hidden behind a production stderr redirect.
cat >"$temporary/bin/mock-storage-api" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys

path = os.environ["MOCK_STORAGE_STATE"]
events = os.environ["MOCK_STORAGE_EVENTS"]
args = sys.argv[1:]
tool = os.path.basename(sys.argv[0])
state = json.load(open(path, encoding="utf-8"))


def log(event):
    with open(events, "a", encoding="utf-8") as output:
        output.write(event + "\n")


def save():
    with open(path, "w", encoding="utf-8") as output:
        json.dump(state, output)


def fail(message):
    log("UNHANDLED " + message)
    print(message, file=sys.stderr)
    sys.exit(93)


def value(obj, field):
    parts = re.split(r"(?<!\\)\.", field.lstrip("."))
    result = obj
    for part in parts:
        if not isinstance(result, dict):
            return None
        result = result.get(part.replace("\\.", "."))
    return result


def canonical(resource):
    aliases = {
        "namespace": "namespaces", "ns": "namespaces", "pv": "persistentvolumes",
        "pvc": "persistentvolumeclaims", "configmap": "configmaps", "pod": "pods",
        "daemonsets": "daemonsets.apps", "crd": "customresourcedefinitions.apiextensions.k8s.io",
        "csidriver": "csidrivers.storage.k8s.io", "storageclass": "storageclasses.storage.k8s.io",
        "clusterrole": "clusterroles.rbac.authorization.k8s.io",
        "clusterrolebinding": "clusterrolebindings.rbac.authorization.k8s.io",
        "validatingwebhookconfiguration": "validatingwebhookconfigurations.admissionregistration.k8s.io",
        "mutatingwebhookconfiguration": "mutatingwebhookconfigurations.admissionregistration.k8s.io",
        "priorityclass": "priorityclasses.scheduling.k8s.io", "job": "jobs.batch",
        "ClusterRole": "clusterroles.rbac.authorization.k8s.io",
        "ClusterRoleBinding": "clusterrolebindings.rbac.authorization.k8s.io",
        "PriorityClass": "priorityclasses.scheduling.k8s.io",
    }
    return aliases.get(resource, resource)


if tool == "helm":
    if args == ["list", "--help"]:
        print("  -a, --all list all releases")
    elif args[:1] == ["list"]:
        if state["namespace"] and state["release"]:
            print("longhorn")
    elif args[:2] == ["uninstall", "longhorn"]:
        log("HELM " + " ".join(args))
        if state["scenario"] == "helm-failure":
            sys.exit(17)
        if not state["deleting-confirmation"]:
            fail("Helm uninstall ran before enabling Longhorn deletion")
        log("HOOK longhorn-uninstall completed")
        state["release"] = False
        # Leave generated children and an annotated cluster resource behind
        # to require the real residual-cleanup path after successful hooks.
        for resource, objects in state["objects"].items():
            state["objects"][resource] = [obj for obj in objects if not obj["metadata"].get("namespace") or obj["metadata"].get("annotations", {}).get("meta.helm.sh/release-name") != "longhorn"]
        if state["scenario"] == "stale-discovery":
            state["crds"] = []
            for resource in state["resources"]:
                if resource.endswith(".longhorn.io"):
                    state["objects"][resource] = []
            state["objects"]["pods"] = []
            state["objects"]["daemonsets.apps"] = []
        save()
    else:
        fail(tool + " " + " ".join(args))
    sys.exit(0)

namespace = None
if args[:1] == ["-n"]:
    namespace, args = args[1], args[2:]
if not args:
    fail("empty kubectl command")
verb = args[0]
if verb == "api-resources":
    discovered = state["resources"] if state["scenario"] == "stale-discovery" else [resource for resource in state["resources"] if not resource.endswith(".longhorn.io") or resource in state["crds"]]
    if "--api-group=longhorn.io" in args:
        print("\n".join(resource for resource in discovered if resource.endswith(".longhorn.io")))
    elif "--namespaced=true" in args:
        print("\n".join(discovered))
    else:
        fail("kubectl " + " ".join(args))
    sys.exit(0)

if verb not in {"get", "patch", "delete"} or len(args) < 2:
    fail("kubectl " + " ".join(args))
resource_arg = args[1]
tokens = args[2:]
names = []
index = 0
output_format = ""
selector = ""
while index < len(tokens):
    token = tokens[index]
    if token in {"-o", "-l", "--type", "-p"}:
        if index + 1 >= len(tokens):
            fail("missing value: " + token)
        if token == "-o":
            output_format = tokens[index + 1]
        elif token == "-l":
            selector = tokens[index + 1]
        index += 2
    elif token.startswith("-"):
        index += 1
    else:
        names.append(token)
        index += 1
resources = []
for item in resource_arg.split(","):
    if "/" in item:
        item, item_name = item.split("/", 1)
        names.append(item_name)
    resources.append(canonical(item))
if resources == ["all"]:
    resources = ["pods", "daemonsets.apps", "deployments.apps", "replicasets.apps", "services", "jobs.batch"]
known_resources = set(state["resources"]) | set(state["objects"]) | {
    "namespaces", "persistentvolumes", "customresourcedefinitions.apiextensions.k8s.io",
    "priorityclasses.scheduling.k8s.io", "clusterroles.rbac.authorization.k8s.io",
    "clusterrolebindings.rbac.authorization.k8s.io", "csidrivers.storage.k8s.io",
    "validatingwebhookconfigurations.admissionregistration.k8s.io",
    "mutatingwebhookconfigurations.admissionregistration.k8s.io", "storageclasses.storage.k8s.io",
}
if any(resource not in known_resources for resource in resources):
    fail("unsupported Kubernetes resource: " + resource_arg)
if verb == "get":
    if any(resource.endswith(".longhorn.io") and resource not in state["crds"] for resource in resources):
        sys.exit(23)
    if state["scenario"] in {"list-denied", "crd-read-error"} and resources == ["engineimages.longhorn.io"] and not names:
        sys.exit(23)
    if state["scenario"] == "crd-read-error" and resources == ["customresourcedefinitions.apiextensions.k8s.io"] and names == ["engineimages.longhorn.io"]:
        sys.exit(23)
    if state["scenario"] == "foreign-api-error" and resources == ["deployments.apps"]:
        sys.exit(23)

objects = []
for resource in resources:
    if resource == "namespaces":
        if state["namespace"] and (not names or "longhorn-system" in names):
            objects.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "longhorn-system", "uid": "namespace-uid"}, "status": {"phase": "Active"}})
        if "kube-system" in names:
            objects.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "kube-system", "uid": "system-uid"}, "status": {"phase": "Active"}})
    elif resource == "customresourcedefinitions.apiextensions.k8s.io":
        objects.extend({"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition", "metadata": {"name": name}} for name in state["crds"] if not names or name in names)
    else:
        objects.extend(obj for obj in state["objects"].get(resource, []) if (not names or obj["metadata"]["name"] in names) and (namespace is None or obj["metadata"].get("namespace") == namespace))
if selector:
    terms = [term.split("=", 1) for term in selector.split(",")]
    objects = [obj for obj in objects if all(obj["metadata"].get("labels", {}).get(key) == expected for key, expected in terms)]

if verb == "get":
    if "custom-columns=" in output_format:
        fields = [column.split(":", 1)[1] for column in output_format.split("=", 1)[1].split(",")]
        for obj in objects:
            print(" ".join("<none>" if value(obj, field) in (None, "") else str(value(obj, field)) for field in fields))
    elif output_format == "name":
        for obj in objects:
            print(canonical(resource_arg.split(",")[0]) + "/" + obj["metadata"]["name"])
        if state["scenario"] == "cr-deleted-after-list" and resources == ["engineimages.longhorn.io"] and not names and not state["release"]:
            state["objects"]["engineimages.longhorn.io"] = []
            save()
    elif "jsonpath=" in output_format:
        if "META|" in output_format:
            for obj in objects:
                metadata = obj["metadata"]
                fields = [obj.get("apiVersion"), obj.get("kind"), metadata.get("namespace"), metadata.get("name"), metadata.get("uid")]
                fields += [metadata.get("labels", {}).get(key) for key in ("app.kubernetes.io/instance", "release")]
                fields += [metadata.get("annotations", {}).get(key) for key in ("meta.helm.sh/release-name", "meta.helm.sh/release-namespace")]
                fields += [metadata.get("labels", {}).get(key) for key in ("longhorn.io/managed-by", "app", "app.kubernetes.io/name", "owner", "name")]
                print("META|" + "|".join(str(field or "") for field in fields))
                for owner in metadata.get("ownerReferences", []):
                    print("OWNER|" + "|".join(owner.get(key, "") for key in ("apiVersion", "kind", "name", "uid")))
        elif len(objects) == 1:
            expression = output_format.split("=", 1)[1]
            if expression.startswith("{range .webhooks[*]}"):
                for webhook in objects[0].get("webhooks", []):
                    print(webhook["clientConfig"]["service"]["namespace"])
            elif expression.startswith("{.") and expression.endswith("}") and expression.count("{") == 1:
                result = value(objects[0], expression[1:-1])
                print("" if result is None else result, end="")
            else:
                fail("unsupported JSONPath " + expression)
        elif objects:
            fail("unexpected multiple objects for JSONPath: " + " ".join(args))
    elif output_format == "json":
        print(json.dumps(objects[0] if names and objects else {"items": objects}))
    elif objects:
        print("present")
    sys.exit(0)

log(verb.upper() + " " + (namespace + "/" if namespace else "") + " ".join(args[1:]))
if verb == "patch":
    if resources == ["settings.longhorn.io"] and names == ["deleting-confirmation-flag"]:
        state["deleting-confirmation"] = True
    else:
        if "finalizers" not in " ".join(args):
            fail("unexpected patch " + " ".join(args))
        if state["scenario"] == "cr-deleted-after-list" and resources == ["engineimages.longhorn.io"] and not objects:
            sys.exit(23)
        for obj in objects:
            obj["metadata"]["finalizers"] = []
elif resources == ["namespaces"]:
    if names != ["longhorn-system"]:
        fail("unexpected namespace deletion")
    state["namespace"] = False
    state["release"] = False
    for resource, existing in state["objects"].items():
        state["objects"][resource] = [obj for obj in existing if obj["metadata"].get("namespace") != "longhorn-system"]
elif resources == ["customresourcedefinitions.apiextensions.k8s.io"]:
    state["crds"] = [name for name in state["crds"] if name not in names]
else:
    selected_ids = {id(obj) for obj in objects}
    for resource in resources:
        if state["scenario"] in {"terminating-child", "replaced-child"} and resource == "pods":
            for obj in state["objects"].get(resource, []):
                if obj["metadata"]["name"].startswith("engine-image-"):
                    selected_ids.discard(id(obj))
                    obj["metadata"]["deletionTimestamp"] = "2026-10-29T10:00:00Z"
                    if state["scenario"] == "replaced-child":
                        obj["metadata"]["uid"] = "replacement-child-uid"
        state["objects"][resource] = [obj for obj in state["objects"].get(resource, []) if id(obj) not in selected_ids]
save()
PY
chmod +x "$temporary/bin/mock-storage-api"
ln -s mock-storage-api "$temporary/bin/kubectl"
ln -s mock-storage-api "$temporary/bin/helm"

for scenario in success helm-failure stale-discovery cr-deleted-after-list terminating-child replaced-child foreign-workload live-volume live-backend list-denied crd-read-error foreign-api-error; do
  export MOCK_STORAGE_STATE="$temporary/$scenario.json"
  export MOCK_STORAGE_EVENTS="$temporary/$scenario.events"
  : >"$MOCK_STORAGE_EVENTS"
  python3 - "$scenario" "$MOCK_STORAGE_STATE" <<'PY'
import json
import sys

scenario, destination = sys.argv[1:]
objects = {}


def add(resource, kind, name, *, labels=None, annotations=None, owners=None, namespace="longhorn-system", **fields):
    obj = {"apiVersion": "apps/v1" if resource.endswith(".apps") else ("longhorn.io/v1beta2" if resource.endswith(".longhorn.io") else "v1"), "kind": kind,
           "metadata": {"name": name, "uid": name + "-uid", "labels": labels or {}, "annotations": annotations or {}}}
    if namespace:
        obj["metadata"]["namespace"] = namespace
    if owners:
        obj["metadata"]["ownerReferences"] = owners
    obj.update(fields)
    objects.setdefault(resource, []).append(obj)


helm = {"meta.helm.sh/release-name": "longhorn", "meta.helm.sh/release-namespace": "longhorn-system"}
managed = {"longhorn.io/managed-by": "longhorn-manager"}
ei_owner = {"apiVersion": "longhorn.io/v1beta2", "kind": "EngineImage", "name": "ei-26bab25d", "uid": "ei-26bab25d-uid"}
ds_owner = {"apiVersion": "apps/v1", "kind": "DaemonSet", "name": "engine-image-ei-26bab25d", "uid": "engine-image-ei-26bab25d-uid", "controller": True}
ei_labels = {"longhorn.io/component": "engine-image", "longhorn.io/engine-image": "ei-26bab25d"}
add("pods", "Pod", "engine-image-ei-26bab25d-5sjbt", labels=ei_labels, owners=[ei_owner, ds_owner])
add("daemonsets.apps", "DaemonSet", "engine-image-ei-26bab25d", labels={**managed, **ei_labels}, owners=[ei_owner])
add("engineimages.longhorn.io", "EngineImage", "ei-26bab25d", spec={"image": "longhornio/longhorn-engine:v1.10.0"})
objects["engineimages.longhorn.io"][0]["metadata"]["finalizers"] = ["longhorn.io"]
add("settings.longhorn.io", "Setting", "deleting-confirmation-flag", value="false")
add("daemonsets.apps", "DaemonSet", "longhorn-manager", labels={"app": "longhorn-manager"}, annotations=helm)
add("pods", "Pod", "longhorn-manager-abcde", labels={"app": "longhorn-manager"})
add("pods", "Pod", "instance-manager-1f5b12d3", labels=managed)
add("pods", "Pod", "csi-attacher-665df548f7-8b6c2", labels={"app": "csi-attacher"})
add("deployments.apps", "Deployment", "csi-attacher", labels=managed)
add("poddisruptionbudgets.policy", "PodDisruptionBudget", "instance-manager-1f5b12d3", spec={"selector": {"matchLabels": managed}})
add("leases.coordination.k8s.io", "Lease", "driver-longhorn-io")
add("secrets", "Secret", "longhorn-grpc-tls")
add("secrets", "Secret", "longhorn-crypto")
add("secrets", "Secret", "sh.helm.release.v1.longhorn.v1", labels={"owner": "helm", "name": "longhorn"})
add("endpointslices.discovery.k8s.io", "EndpointSlice", "webhook-abcde", labels={"kubernetes.io/service-name": "longhorn-admission-webhook"})
add("configmaps", "ConfigMap", "kube-root-ca.crt")
add("serviceaccounts", "ServiceAccount", "default")
add("clusterroles.rbac.authorization.k8s.io", "ClusterRole", "longhorn-role", annotations=helm, namespace="")
add("clusterrolebindings.rbac.authorization.k8s.io", "ClusterRoleBinding", "longhorn-bind", annotations=helm, namespace="")
add("csidrivers.storage.k8s.io", "CSIDriver", "driver.longhorn.io", namespace="")
add("storageclasses.storage.k8s.io", "StorageClass", "longhorn", namespace="", provisioner="driver.longhorn.io")
add("storageclasses.storage.k8s.io", "StorageClass", "longhorn-static", namespace="", provisioner="driver.longhorn.io", parameters={"staleReplicaTimeout": "30"})
for resource, kind, name in [("validatingwebhookconfigurations.admissionregistration.k8s.io", "ValidatingWebhookConfiguration", "longhorn-webhook-validator"), ("mutatingwebhookconfigurations.admissionregistration.k8s.io", "MutatingWebhookConfiguration", "longhorn-webhook-mutator")]:
    add(resource, kind, name, namespace="", webhooks=[{"clientConfig": {"service": {"namespace": "longhorn-system"}}}])
if scenario == "foreign-workload":
    add("pods", "Pod", "foreign-app", labels={"app": "foreign"})
if scenario == "live-volume":
    add("persistentvolumes", "PersistentVolume", "foreign-pv", namespace="", spec={"csi": {"driver": "driver.longhorn.io", "volumeHandle": "external-data"}})
if scenario == "live-backend":
    add("volumes.longhorn.io", "Volume", "external-data", spec={"nodeID": "worker-1"})
resources = ["pods", "daemonsets.apps", "deployments.apps", "replicasets.apps", "jobs.batch", "persistentvolumeclaims", "services", "configmaps", "secrets", "serviceaccounts", "poddisruptionbudgets.policy", "leases.coordination.k8s.io", "endpointslices.discovery.k8s.io", "engineimages.longhorn.io", "settings.longhorn.io", "volumes.longhorn.io"]
json.dump({"scenario": scenario, "namespace": True, "release": True, "deleting-confirmation": False, "objects": objects, "resources": resources, "crds": ["engineimages.longhorn.io", "settings.longhorn.io", "volumes.longhorn.io"]}, open(destination, "w", encoding="utf-8"))
PY
  status=0
  PATH="$temporary/bin:$PATH" bash -euo pipefail -c '
    source "$1"
    timeout() { shift; "$@"; }
    sleep() { :; }
    cleanup_longhorn_release
    # Exercise an immediate retry through the same real production path.
    cleanup_longhorn_release
  ' _ "$repo_root/charts/ton-k8s-operator/kubeton" >"$temporary/$scenario.log" 2>&1 || status=$?
  if grep -Fq UNHANDLED "$MOCK_STORAGE_EVENTS"; then
    cat "$MOCK_STORAGE_EVENTS" >&2
    cat "$temporary/$scenario.log" >&2
    exit 1
  fi
  if [[ "$scenario" == success || "$scenario" == helm-failure || "$scenario" == stale-discovery || "$scenario" == terminating-child || "$scenario" == cr-deleted-after-list ]]; then
    if (( status != 0 )); then
      cat "$temporary/$scenario.log" >&2
      echo "Longhorn teardown failed for $scenario: $status" >&2
      exit 1
    fi
    python3 - "$MOCK_STORAGE_STATE" "$MOCK_STORAGE_EVENTS" "$scenario" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
events = open(sys.argv[2], encoding="utf-8").read().splitlines()
assert not state["namespace"], "Longhorn namespace survived"
assert not state["release"], "Helm release survived"
assert not state["crds"], "Longhorn CRDs survived"
for resource, objects in state["objects"].items():
    assert not objects, (resource, "owned objects survived")
assert sum(line.startswith("DELETE namespace longhorn-system ") for line in events) == 1, "retry must be idempotent"
helm = next(index for index, line in enumerate(events) if line.startswith("HELM "))
force = next(index for index, line in enumerate(events) if line.startswith("DELETE longhorn-system/job longhorn-uninstall"))
assert helm < force, "forced cleanup ran before official Helm hook"
assert any(line.startswith("PATCH longhorn-system/settings.longhorn.io deleting-confirmation-flag ") for line in events)
assert any(line.startswith("DELETE ClusterRole/longhorn-role ") for line in events), "cluster RBAC was not cleaned"
assert any(line.startswith("DELETE csidrivers.storage.k8s.io/driver.longhorn.io ") for line in events), "cluster CSI registration was not cleaned"
assert any(line.startswith("DELETE storageclass/longhorn-static ") for line in events), "generated static StorageClass was not cleaned"
assert any("DELETE customresourcedefinitions.apiextensions.k8s.io/" in line for line in events) or sys.argv[3] == "stale-discovery", "remaining CRDs were not cleaned"
if sys.argv[3] != "helm-failure":
    assert "HOOK longhorn-uninstall completed" in events
else:
    assert sum(line.startswith("HELM ") for line in events) == 2, "both ordinary and --no-hooks fallback must be attempted"
    assert any("--no-hooks" in line for line in events if line.startswith("HELM "))
PY
  elif [[ "$scenario" == replaced-child ]]; then
    if (( status == 0 )) || grep -Fq 'DELETE namespace longhorn-system ' "$MOCK_STORAGE_EVENTS"; then
      echo 'Longhorn teardown accepted an unproven replacement of the previously verified Pod' >&2
      exit 1
    fi
    grep -Fq 'ownership of pods/engine-image-ei-26bab25d-5sjbt' "$temporary/$scenario.log"
  else
    if (( status == 0 )); then
      echo "Longhorn teardown accepted $scenario" >&2
      exit 1
    fi
    if grep -Eq '^(PATCH|DELETE|HELM) ' "$MOCK_STORAGE_EVENTS"; then
      echo "Longhorn teardown mutated protected $scenario" >&2
      cat "$MOCK_STORAGE_EVENTS" >&2
      exit 1
    fi
  fi
done

echo 'kubeton Longhorn teardown integration checks: PASS (12 scenarios plus successful retries)'
