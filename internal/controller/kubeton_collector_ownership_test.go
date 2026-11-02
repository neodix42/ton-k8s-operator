package controller

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var _ = Describe("kubeton VictoriaLogs Helm ownership", func() {
	It("resumes suspended collectors with Helm 4 without replacing them or widening affinity", func() {
		if testEnv.UseExistingCluster != nil && *testEnv.UseExistingCluster {
			Skip("Requires an isolated envtest API; do not install the fixture on an existing cluster")
		}
		helm, err := exec.LookPath("helm")
		if err != nil {
			Skip("Helm is required for this CLI integration test")
		}
		help, err := exec.Command(helm, "upgrade", "--help").CombinedOutput()
		Expect(err).NotTo(HaveOccurred())
		if !strings.Contains(string(help), "--force-conflicts") {
			Skip("This integration test requires Helm server-side apply support")
		}
		directory, err := os.MkdirTemp("", "kubeton-collector-ownership-*")
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(os.RemoveAll, directory)
		kubeconfig := filepath.Join(directory, "kubeconfig")
		configuration := clientcmdapi.Config{
			Clusters: map[string]*clientcmdapi.Cluster{"test": {
				Server: cfg.Host, CertificateAuthorityData: cfg.CAData,
			}},
			AuthInfos: map[string]*clientcmdapi.AuthInfo{"test": {
				ClientCertificateData: cfg.CertData, ClientKeyData: cfg.KeyData,
			}},
			Contexts:       map[string]*clientcmdapi.Context{"test": {Cluster: "test", AuthInfo: "test"}},
			CurrentContext: "test",
		}
		Expect(clientcmd.WriteToFile(configuration, kubeconfig)).To(Succeed())
		chart := filepath.Join(directory, "chart")
		Expect(os.MkdirAll(filepath.Join(chart, "templates"), 0o700)).To(Succeed())
		Expect(os.WriteFile(filepath.Join(chart, "Chart.yaml"), []byte("apiVersion: v2\nname: collector-fixture\nversion: 0.1.0\n"), 0o600)).To(Succeed())
		// No workload controllers run in envtest. This chart exercises the real
		// Helm field ownership and actual kubeton affinity/buffer arguments;
		// it creates no Pods, host mounts, or connections to external clusters.
		Expect(os.WriteFile(filepath.Join(chart, "templates", "collector.yaml"), []byte(`apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: collector-victoria-logs-collector
  labels:
    app.kubernetes.io/instance: collector
    app.kubernetes.io/name: victoria-logs-collector
spec:
  selector:
    matchLabels:
      app: collector-fixture
  template:
    metadata:
      labels:
        app: collector-fixture
    spec:
      affinity: {{ .Values.affinity | toJson }}
      containers:
        - name: vlagent
          image: example.invalid/collector:fixture
      volumes:
        - name: buffer
          hostPath:
            path: {{ .Values.persistence.volume.hostPath.path | quote }}
            type: DirectoryOrCreate
`), 0o600)).To(Succeed())
		kubeton, err := filepath.Abs(filepath.Join("..", "..", "charts", "ton-k8s-operator", "kubeton"))
		Expect(err).NotTo(HaveOccurred())
		run := func(program string, arguments ...string) (string, error) {
			commandContext, cancelCommand := context.WithTimeout(ctx, 30*time.Second)
			defer cancelCommand()
			command := exec.CommandContext(commandContext, program, arguments...)
			command.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig, "KUBETON_LAUNCH_LOGS_ENABLED=false", "HELM_DRIVER=secret")
			output, err := command.CombinedOutput()
			return string(output), err
		}
		install := func() {
			output, err := run("bash", "-euo", "pipefail", "-c", `
source "$1"
victoria_logs_resolve_allowed_nodes() { local -n nodes="$3"; nodes=(worker-a worker-b); }
victoria_logs_validate_ton_nodes_covered() { :; }
install_victoria_logs_collector_release ownership-test collector "$2" '' http://backend:9428 20 ''
`, "_", kubeton, chart)
			Expect(err).NotTo(HaveOccurred(), output)
		}
		install()
		key := client.ObjectKey{Namespace: "ownership-test", Name: "collector-victoria-logs-collector"}
		daemonset := &appsv1.DaemonSet{}
		Expect(k8sClient.Get(ctx, key, daemonset)).To(Succeed())
		originalUID := daemonset.UID
		originalBuffer := daemonset.Spec.Template.Spec.Volumes[0].HostPath.Path

		for _, manager := range []string{"kubectl-patch", "helm"} {
			By("resuming a collector suspended by the " + manager + " field manager")
			affinity := map[string]interface{}{"nodeAffinity": map[string]interface{}{
				"requiredDuringSchedulingIgnoredDuringExecution": map[string]interface{}{
					"nodeSelectorTerms": []interface{}{map[string]interface{}{"matchFields": []interface{}{map[string]interface{}{
						"key": "metadata.name", "operator": "In", "values": []string{"kubeton-vlogs-suspended-" + string(originalUID)},
					}}}},
				},
			}}
			patch, err := json.Marshal([]map[string]interface{}{
				{"op": "test", "path": "/metadata/uid", "value": originalUID},
				{"op": "add", "path": "/spec/template/spec/affinity", "value": affinity},
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(k8sClient.Patch(ctx, daemonset, client.RawPatch(types.JSONPatchType, patch), client.FieldOwner(manager))).To(Succeed())
			if manager == "kubectl-patch" {
				// Negative control reproduces the exact upgrade failure seen on
				// GKE, rather than making a mock return a synthetic conflict.
				output, err := run(helm, "upgrade", "collector", chart, "-n", key.Namespace, "--reuse-values")
				Expect(err).To(HaveOccurred())
				Expect(output).To(ContainSubstring(`conflict with "kubectl-patch"`))
			}
			install()
			Expect(k8sClient.Get(ctx, key, daemonset)).To(Succeed())
			Expect(daemonset.UID).To(Equal(originalUID))
			Expect(daemonset.Spec.Template.Spec.Volumes[0].HostPath.Path).To(Equal(originalBuffer))
			terms := daemonset.Spec.Template.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
			Expect(terms).To(HaveLen(1))
			Expect(terms[0].MatchFields).To(BeEmpty())
			Expect(terms[0].MatchExpressions).To(HaveLen(1))
			Expect(terms[0].MatchExpressions[0].Key).To(Equal("kubernetes.io/hostname"))
			Expect(terms[0].MatchExpressions[0].Values).To(ConsistOf("worker-a", "worker-b"))
		}

		By("resuming a release previously managed with client-side apply")
		output, err := run(helm, "upgrade", "collector", chart, "-n", key.Namespace, "--reuse-values", "--server-side=false")
		Expect(err).NotTo(HaveOccurred(), output)
		install()
		Expect(k8sClient.Get(ctx, key, daemonset)).To(Succeed())
		Expect(daemonset.UID).To(Equal(originalUID))
		Expect(daemonset.Spec.Template.Spec.Volumes[0].HostPath.Path).To(Equal(originalBuffer))
	})
})
