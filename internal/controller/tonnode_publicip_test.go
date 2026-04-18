package controller

import (
	"context"
	"fmt"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

const (
	testK8sNodeName0 = "k8s-node-0"
	testK8sNodeName1 = "k8s-node-1"
	testK8sNodeName2 = "k8s-node-2"
	testK8sNodeName3 = "k8s-node-3"

	testHostName0 = "node-host-00"
	testHostName1 = "node-host-01"
	testHostName2 = "node-host-02"
	testHostName3 = "node-host-03"
)

func TestDesiredPublicIPEnv(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatalf("add corev1 scheme: %v", err)
	}
	if err := tonv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("add ton scheme: %v", err)
	}

	tests := []struct {
		name          string
		tonNode       *tonv1alpha1.TonNode
		objects       []client.Object
		wantValue     string
		wantFieldPath string
	}{
		{
			name: "uses explicit spec network public ip",
			tonNode: &tonv1alpha1.TonNode{
				ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
				Spec: tonv1alpha1.TonNodeSpec{
					Network:  tonv1alpha1.TonNodeNetworkSpec{PublicIP: "95.217.73.161"},
					Replicas: ptr.To[int32](1),
				},
			},
			wantValue: "95.217.73.161",
		},
		{
			name: "uses node external ip for single replica",
			tonNode: &tonv1alpha1.TonNode{
				ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
				Spec: tonv1alpha1.TonNodeSpec{
					Replicas: ptr.To[int32](1),
				},
			},
			objects: []client.Object{
				&corev1.Pod{
					ObjectMeta: metav1.ObjectMeta{Name: "tonnode-0", Namespace: "default"},
					Spec:       corev1.PodSpec{NodeName: testK8sNodeName3},
				},
				&corev1.Node{
					ObjectMeta: metav1.ObjectMeta{Name: testK8sNodeName3},
					Status: corev1.NodeStatus{
						Addresses: []corev1.NodeAddress{
							{Type: corev1.NodeInternalIP, Address: "10.0.0.10"},
							{Type: corev1.NodeExternalIP, Address: "95.217.73.161"},
						},
					},
				},
			},
			wantValue: "95.217.73.161",
		},
		{
			name: "falls back to host ip when external ip is missing",
			tonNode: &tonv1alpha1.TonNode{
				ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
				Spec: tonv1alpha1.TonNodeSpec{
					Replicas: ptr.To[int32](1),
				},
			},
			objects: []client.Object{
				&corev1.Pod{
					ObjectMeta: metav1.ObjectMeta{Name: "tonnode-0", Namespace: "default"},
					Spec:       corev1.PodSpec{NodeName: testK8sNodeName3},
				},
				&corev1.Node{
					ObjectMeta: metav1.ObjectMeta{Name: testK8sNodeName3},
					Status: corev1.NodeStatus{
						Addresses: []corev1.NodeAddress{
							{Type: corev1.NodeInternalIP, Address: "10.0.0.10"},
						},
					},
				},
			},
			wantFieldPath: "status.hostIP",
		},
		{
			name: "falls back to host ip for multi replica",
			tonNode: &tonv1alpha1.TonNode{
				ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
				Spec: tonv1alpha1.TonNodeSpec{
					Replicas: ptr.To[int32](3),
				},
			},
			wantFieldPath: "status.hostIP",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeClient := fake.NewClientBuilder().
				WithScheme(scheme).
				WithObjects(tt.objects...).
				Build()
			reconciler := &TonNodeReconciler{Client: fakeClient, Scheme: scheme}

			envVar, err := reconciler.desiredPublicIPEnv(context.Background(), tt.tonNode)
			if err != nil {
				t.Fatalf("desiredPublicIPEnv() unexpected error: %v", err)
			}

			if envVar.Name != "PUBLIC_IP" {
				t.Fatalf("env var name = %q, want PUBLIC_IP", envVar.Name)
			}

			if tt.wantValue != "" {
				if envVar.Value != tt.wantValue {
					t.Fatalf("env var value = %q, want %q", envVar.Value, tt.wantValue)
				}
				if envVar.ValueFrom != nil {
					t.Fatalf("env var valueFrom should be nil when explicit value is set")
				}
				return
			}

			if envVar.ValueFrom == nil || envVar.ValueFrom.FieldRef == nil {
				t.Fatalf("env var valueFrom.fieldRef is nil, want fieldPath %q", tt.wantFieldPath)
			}
			if envVar.ValueFrom.FieldRef.FieldPath != tt.wantFieldPath {
				t.Fatalf("fieldPath = %q, want %q", envVar.ValueFrom.FieldRef.FieldPath, tt.wantFieldPath)
			}
		})
	}
}

func TestDesiredPodTemplateHostPorts(t *testing.T) {
	reconciler := &TonNodeReconciler{}
	labels := map[string]string{"app.kubernetes.io/instance": "tonnode"}
	publicIP := corev1.EnvVar{Name: "PUBLIC_IP", Value: "95.217.73.161"}

	t.Run("enabled by default", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)

		if len(tpl.Spec.Containers) != 1 {
			t.Fatalf("expected one container, got %d", len(tpl.Spec.Containers))
		}
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		quic := containerPortByName(t, ports, "quic-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.HostPort != defaultValidatorPort {
			t.Fatalf("validator hostPort = %d, want %d", validator.HostPort, defaultValidatorPort)
		}
		if quic.HostPort != defaultQuicPort {
			t.Fatalf("quic hostPort = %d, want %d", quic.HostPort, defaultQuicPort)
		}
		if liteserver.HostPort != defaultLiteServerPort {
			t.Fatalf("liteserver hostPort = %d, want %d", liteserver.HostPort, defaultLiteServerPort)
		}
		if console.HostPort != 0 {
			t.Fatalf("console hostPort = %d, want 0", console.HostPort)
		}
	})

	t.Run("disabled explicitly", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Network: tonv1alpha1.TonNodeNetworkSpec{
					HostPortsEnabled: ptr.To(false),
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		quic := containerPortByName(t, ports, "quic-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.HostPort != 0 || quic.HostPort != 0 || liteserver.HostPort != 0 || console.HostPort != 0 {
			t.Fatalf("all hostPorts should be disabled, got validator=%d quic=%d liteserver=%d console=%d", validator.HostPort, quic.HostPort, liteserver.HostPort, console.HostPort)
		}
	})

	t.Run("uses overridden ton ports", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Network: tonv1alpha1.TonNodeNetworkSpec{
					ValidatorPort:        32001,
					QuicPort:             32011,
					LiteServerPort:       32003,
					ValidatorConsolePort: 32002,
					HostPortsEnabled:     ptr.To(true),
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		quic := containerPortByName(t, ports, "quic-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.ContainerPort != 32001 || validator.HostPort != 32001 {
			t.Fatalf("validator ports = container:%d host:%d, want 32001/32001", validator.ContainerPort, validator.HostPort)
		}
		if quic.ContainerPort != 32011 || quic.HostPort != 32011 {
			t.Fatalf("quic ports = container:%d host:%d, want 32011/32011", quic.ContainerPort, quic.HostPort)
		}
		if liteserver.ContainerPort != 32003 || liteserver.HostPort != 32003 {
			t.Fatalf("liteserver ports = container:%d host:%d, want 32003/32003", liteserver.ContainerPort, liteserver.HostPort)
		}
		if console.ContainerPort != 32002 || console.HostPort != 0 {
			t.Fatalf("console ports = container:%d host:%d, want 32002/0", console.ContainerPort, console.HostPort)
		}
	})

	t.Run("exposes exporter hostPort from custom parameters", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Env: []corev1.EnvVar{
					{
						Name:  customParametersEnvName,
						Value: "--exporter-address 0.0.0.0:9777",
					},
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)
		ports := tpl.Spec.Containers[0].Ports

		exporter := containerPortByName(t, ports, exporterContainerPortName)
		if exporter.ContainerPort != 9777 || exporter.HostPort != 9777 {
			t.Fatalf("exporter ports = container:%d host:%d, want 9777/9777", exporter.ContainerPort, exporter.HostPort)
		}
	})

	t.Run("keeps exporter hostPort disabled when host ports are disabled", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Network: tonv1alpha1.TonNodeNetworkSpec{
					HostPortsEnabled: ptr.To(false),
				},
				Env: []corev1.EnvVar{
					{
						Name:  customParametersEnvName,
						Value: "--exporter-address=0.0.0.0:9777",
					},
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)
		ports := tpl.Spec.Containers[0].Ports

		exporter := containerPortByName(t, ports, exporterContainerPortName)
		if exporter.ContainerPort != 9777 || exporter.HostPort != 0 {
			t.Fatalf("exporter ports = container:%d host:%d, want 9777/0", exporter.ContainerPort, exporter.HostPort)
		}
	})

	t.Run("ignores invalid exporter address", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Env: []corev1.EnvVar{
					{
						Name:  customParametersEnvName,
						Value: "--exporter-address=not-a-port",
					},
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)
		ports := tpl.Spec.Containers[0].Ports
		if hasContainerPortNamed(ports, exporterContainerPortName) {
			t.Fatalf("unexpected %s container port for invalid exporter address", exporterContainerPortName)
		}
	})

	t.Run("adds sticky hostname node affinity", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, []string{testHostName0, testHostName3})

		affinity := tpl.Spec.Affinity
		if affinity == nil || affinity.NodeAffinity == nil || affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
			t.Fatalf("expected required node affinity for sticky hostnames")
		}
		terms := affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
		if len(terms) != 1 || len(terms[0].MatchExpressions) != 1 {
			t.Fatalf("unexpected node affinity terms: %#v", terms)
		}
		req := terms[0].MatchExpressions[0]
		if req.Key != "kubernetes.io/hostname" {
			t.Fatalf("node affinity key = %q, want kubernetes.io/hostname", req.Key)
		}
		if req.Operator != corev1.NodeSelectorOpIn {
			t.Fatalf("node affinity operator = %q, want In", req.Operator)
		}
		if len(req.Values) != 2 || req.Values[0] != testHostName0 || req.Values[1] != testHostName3 {
			t.Fatalf("node affinity values = %#v, want [%s %s]", req.Values, testHostName0, testHostName3)
		}
	})
}

func TestDesiredResources(t *testing.T) {
	t.Run("uses defaults when spec resources are empty", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{}
		resources := desiredResources(tonNode)

		assertQuantityEqual(t, resources.Requests[corev1.ResourceCPU], defaultCPURequest, "requests.cpu")
		assertQuantityEqual(t, resources.Requests[corev1.ResourceMemory], defaultMemoryRequest, "requests.memory")
		assertQuantityEqual(t, resources.Limits[corev1.ResourceCPU], defaultCPULimit, "limits.cpu")
		assertQuantityEqual(t, resources.Limits[corev1.ResourceMemory], defaultMemoryLimit, "limits.memory")
	})

	t.Run("merges user overrides with defaults", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU: resource.MustParse("20000m"),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceMemory: resource.MustParse("300Gi"),
					},
				},
			},
		}
		resources := desiredResources(tonNode)

		assertQuantityEqual(t, resources.Requests[corev1.ResourceCPU], "20000m", "requests.cpu")
		assertQuantityEqual(t, resources.Requests[corev1.ResourceMemory], defaultMemoryRequest, "requests.memory")
		assertQuantityEqual(t, resources.Limits[corev1.ResourceCPU], defaultCPULimit, "limits.cpu")
		assertQuantityEqual(t, resources.Limits[corev1.ResourceMemory], "300Gi", "limits.memory")
	})
}

func TestDesiredImagePullPolicy(t *testing.T) {
	tests := []struct {
		name  string
		image string
		want  corev1.PullPolicy
	}{
		{
			name:  "versioned tag uses pull always",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64",
			want:  corev1.PullAlways,
		},
		{
			name:  "latest tag uses pull always",
			image: "busybox:latest",
			want:  corev1.PullAlways,
		},
		{
			name:  "image without tag is treated as latest",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl",
			want:  corev1.PullAlways,
		},
		{
			name:  "digest pin uses if not present",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl@sha256:0123456789abcdef",
			want:  corev1.PullIfNotPresent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tonNode := &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					Image: tt.image,
				},
			}
			got := desiredImagePullPolicy(tonNode)
			if got != tt.want {
				t.Fatalf("desiredImagePullPolicy(%q) = %q, want %q", tt.image, got, tt.want)
			}
		})
	}
}

func TestDesiredKeyAgentImagePullPolicy(t *testing.T) {
	tests := []struct {
		name    string
		tonNode *tonv1alpha1.TonNode
		want    corev1.PullPolicy
	}{
		{
			name:    "default key-agent image uses pull always",
			tonNode: &tonv1alpha1.TonNode{},
			want:    corev1.PullAlways,
		},
		{
			name: "versioned key-agent image uses pull always",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Agent: tonv1alpha1.TonNodeKeyAgentSpec{
							Image: "ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64",
						},
					},
				},
			},
			want: corev1.PullAlways,
		},
		{
			name: "digest-pinned key-agent image uses if not present",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Agent: tonv1alpha1.TonNodeKeyAgentSpec{
							Image: "ghcr.io/ton-blockchain/ton-docker-ctrl@sha256:0123456789abcdef",
						},
					},
				},
			},
			want: corev1.PullIfNotPresent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := desiredKeyAgentImagePullPolicy(tt.tonNode)
			if got != tt.want {
				t.Fatalf("desiredKeyAgentImagePullPolicy() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestValidateKeyManagementSpec(t *testing.T) {
	tests := []struct {
		name    string
		tonNode *tonv1alpha1.TonNode
		wantErr bool
	}{
		{
			name:    "disabled key management is valid",
			tonNode: &tonv1alpha1.TonNode{},
			wantErr: false,
		},
		{
			name: "enabled without credentials secret is invalid",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Enabled:         true,
						Provider:        "vault",
						VaultTransitKey: "ton-validator",
					},
				},
			},
			wantErr: true,
		},
		{
			name: "enabled vault without transit key is invalid",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Enabled:  true,
						Provider: "vault",
						CredentialsSecretRef: &corev1.LocalObjectReference{
							Name: "vault-creds",
						},
					},
				},
			},
			wantErr: true,
		},
		{
			name: "enabled kms without vendor is invalid",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Enabled:  true,
						Provider: "kms",
						KMSKeyID: "projects/proj/locations/global/keyRings/ring/cryptoKeys/key",
						CredentialsSecretRef: &corev1.LocalObjectReference{
							Name: "kms-creds",
						},
					},
				},
			},
			wantErr: true,
		},
		{
			name: "enabled vault with required fields is valid",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Enabled:         true,
						Provider:        "vault",
						VaultTransitKey: "ton-validator",
						CredentialsSecretRef: &corev1.LocalObjectReference{
							Name: "vault-creds",
						},
					},
				},
			},
			wantErr: false,
		},
		{
			name: "enabled kms with required fields is valid",
			tonNode: &tonv1alpha1.TonNode{
				Spec: tonv1alpha1.TonNodeSpec{
					KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
						Enabled:   true,
						Provider:  "kms",
						KMSKeyID:  "arn:aws:kms:eu-central-1:111111111111:key/abcd",
						KMSVendor: "aws",
						CredentialsSecretRef: &corev1.LocalObjectReference{
							Name: "kms-creds",
						},
					},
				},
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := validateKeyManagementSpec(tt.tonNode)
			if tt.wantErr && got == "" {
				t.Fatalf("validateKeyManagementSpec() expected error, got empty message")
			}
			if !tt.wantErr && got != "" {
				t.Fatalf("validateKeyManagementSpec() unexpected error: %s", got)
			}
		})
	}
}

func TestDesiredPodTemplateKeyManagement(t *testing.T) {
	reconciler := &TonNodeReconciler{}
	labels := map[string]string{"app.kubernetes.io/instance": "tonnode"}
	publicIP := corev1.EnvVar{Name: "PUBLIC_IP", Value: "95.217.73.161"}

	tonNode := &tonv1alpha1.TonNode{
		Spec: tonv1alpha1.TonNodeSpec{
			KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
				Enabled:         true,
				Provider:        "vault",
				VaultTransitKey: "ton-validator",
				CredentialsSecretRef: &corev1.LocalObjectReference{
					Name: "vault-creds",
				},
			},
		},
	}

	tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP, nil)

	if len(tpl.Spec.Containers) != 2 {
		t.Fatalf("expected two containers (ton + sidecar), got %d", len(tpl.Spec.Containers))
	}
	if len(tpl.Spec.InitContainers) != 1 {
		t.Fatalf("expected one init container (key-restore), got %d", len(tpl.Spec.InitContainers))
	}
	if tpl.Spec.InitContainers[0].Name != "key-restore" {
		t.Fatalf("expected init container key-restore, got %q", tpl.Spec.InitContainers[0].Name)
	}
	if tpl.Spec.Containers[1].Name != "key-backup" {
		t.Fatalf("expected sidecar key-backup, got %q", tpl.Spec.Containers[1].Name)
	}

	main := tpl.Spec.Containers[0]
	if !hasMount(main.VolumeMounts, keysTmpfsVolume, "/var/ton-work/keys") {
		t.Fatalf("main container missing keys tmpfs mount")
	}
	if !hasMount(main.VolumeMounts, walletsTmpfsVolume, "/usr/local/bin/mytoncore/wallets") {
		t.Fatalf("main container missing wallets tmpfs mount")
	}
	if !hasMount(main.VolumeMounts, keyBundleClaim, keyBundleMountPath) {
		t.Fatalf("main container missing key bundle mount")
	}

	if !hasMemoryVolume(tpl.Spec.Volumes, keysTmpfsVolume) {
		t.Fatalf("pod spec missing memory emptyDir volume %q", keysTmpfsVolume)
	}
	if !hasMemoryVolume(tpl.Spec.Volumes, walletsTmpfsVolume) {
		t.Fatalf("pod spec missing memory emptyDir volume %q", walletsTmpfsVolume)
	}

	sidecar := tpl.Spec.Containers[1]
	if !hasEnv(sidecar.Env, "KEY_PROVIDER", "vault") {
		t.Fatalf("sidecar missing KEY_PROVIDER=vault env")
	}
	if len(sidecar.EnvFrom) != 1 || sidecar.EnvFrom[0].SecretRef == nil || sidecar.EnvFrom[0].SecretRef.Name != "vault-creds" {
		t.Fatalf("sidecar must consume credentials secret vault-creds")
	}
}

func TestDesiredStickyNodeHostnames(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatalf("add corev1 scheme: %v", err)
	}
	if err := tonv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("add ton scheme: %v", err)
	}

	t.Run("keeps existing sticky hostnames from affinity", func(t *testing.T) {
		reconciler := &TonNodeReconciler{}
		tonNode := &tonv1alpha1.TonNode{
			ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
			Spec: tonv1alpha1.TonNodeSpec{
				Replicas: ptr.To[int32](2),
			},
		}
		existingAffinity := &corev1.Affinity{
			NodeAffinity: &corev1.NodeAffinity{
				RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{
						{
							MatchExpressions: []corev1.NodeSelectorRequirement{
								{
									Key:      "kubernetes.io/hostname",
									Operator: corev1.NodeSelectorOpIn,
									Values:   []string{testHostName2, testHostName1},
								},
							},
						},
					},
				},
			},
		}

		got, err := reconciler.desiredStickyNodeHostnames(
			context.Background(),
			tonNode,
			existingAffinity,
			labelsForTonNode(tonNode),
			nil,
			int(desiredReplicas(tonNode)),
		)
		if err != nil {
			t.Fatalf("desiredStickyNodeHostnames() unexpected error: %v", err)
		}
		if len(got) != 2 || got[0] != testHostName1 || got[1] != testHostName2 {
			t.Fatalf("sticky hostnames = %#v, want [%s %s]", got, testHostName1, testHostName2)
		}
	})

	t.Run("preselects sticky hostnames from eligible nodes before first launch", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
			Spec: tonv1alpha1.TonNodeSpec{
				Replicas: ptr.To[int32](2),
			},
		}
		node0 := &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: testK8sNodeName0,
				Labels: map[string]string{
					corev1.LabelHostname: testHostName0,
				},
			},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		}
		node1 := &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: testK8sNodeName1,
				Labels: map[string]string{
					corev1.LabelHostname: testHostName1,
				},
			},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		}
		node2 := &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: testK8sNodeName2,
				Labels: map[string]string{
					corev1.LabelHostname: testHostName2,
				},
			},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionFalse},
				},
			},
		}
		fakeClient := fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(node0, node1, node2).
			Build()
		reconciler := &TonNodeReconciler{Client: fakeClient, Scheme: scheme}
		labels := labelsForTonNode(tonNode)

		got, err := reconciler.desiredStickyNodeHostnames(
			context.Background(),
			tonNode,
			nil,
			labels,
			nil,
			int(desiredReplicas(tonNode)),
		)
		if err != nil {
			t.Fatalf("desiredStickyNodeHostnames() unexpected error: %v", err)
		}
		if len(got) != 2 || got[0] != testHostName0 || got[1] != testHostName1 {
			t.Fatalf("sticky hostnames = %#v, want [%s %s]", got, testHostName0, testHostName1)
		}
	})

	t.Run("prefers stored ordinal map before first launch", func(t *testing.T) {
		fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()
		reconciler := &TonNodeReconciler{Client: fakeClient, Scheme: scheme}
		tonNode := &tonv1alpha1.TonNode{
			ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
			Spec: tonv1alpha1.TonNodeSpec{
				Replicas: ptr.To[int32](3),
			},
		}
		ordinalNodeMap := map[int]string{
			0: testHostName0,
			1: testHostName1,
			2: testHostName3,
		}

		got, err := reconciler.desiredStickyNodeHostnames(
			context.Background(),
			tonNode,
			nil,
			labelsForTonNode(tonNode),
			ordinalNodeMap,
			int(desiredReplicas(tonNode)),
		)
		if err != nil {
			t.Fatalf("desiredStickyNodeHostnames() unexpected error: %v", err)
		}
		if len(got) != 3 || got[0] != testHostName0 || got[1] != testHostName1 || got[2] != testHostName3 {
			t.Fatalf("sticky hostnames = %#v, want [%s %s %s]", got, testHostName0, testHostName1, testHostName3)
		}
	})

	t.Run("does not retrofit sticky hostnames from running pods", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
			Spec: tonv1alpha1.TonNodeSpec{
				Replicas: ptr.To[int32](2),
			},
		}
		labels := labelsForTonNode(tonNode)
		node0 := &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: testK8sNodeName0,
				Labels: map[string]string{
					corev1.LabelHostname: testHostName0,
				},
			},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		}
		node1 := &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{
				Name: testK8sNodeName1,
				Labels: map[string]string{
					corev1.LabelHostname: testHostName1,
				},
			},
			Status: corev1.NodeStatus{
				Conditions: []corev1.NodeCondition{
					{Type: corev1.NodeReady, Status: corev1.ConditionTrue},
				},
			},
		}
		pod0 := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "tonnode-0",
				Namespace: "default",
				Labels:    labels,
			},
			Spec: corev1.PodSpec{NodeName: testK8sNodeName0},
		}
		pod1 := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "tonnode-1",
				Namespace: "default",
				Labels:    labels,
			},
			Spec: corev1.PodSpec{NodeName: testK8sNodeName1},
		}
		fakeClient := fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(node0, node1, pod0, pod1).
			Build()
		reconciler := &TonNodeReconciler{Client: fakeClient, Scheme: scheme}

		got, err := reconciler.desiredStickyNodeHostnames(
			context.Background(),
			tonNode,
			nil,
			labels,
			nil,
			int(desiredReplicas(tonNode)),
		)
		if err != nil {
			t.Fatalf("desiredStickyNodeHostnames() unexpected error: %v", err)
		}
		if got != nil {
			t.Fatalf("sticky hostnames = %#v, want nil", got)
		}
	})

	t.Run("disables sticky hostnames when explicit public ip is set", func(t *testing.T) {
		reconciler := &TonNodeReconciler{}
		tonNode := &tonv1alpha1.TonNode{
			ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default"},
			Spec: tonv1alpha1.TonNodeSpec{
				Replicas: ptr.To[int32](1),
				Network:  tonv1alpha1.TonNodeNetworkSpec{PublicIP: "1.2.3.4"},
			},
		}

		got, err := reconciler.desiredStickyNodeHostnames(
			context.Background(),
			tonNode,
			nil,
			labelsForTonNode(tonNode),
			nil,
			int(desiredReplicas(tonNode)),
		)
		if err != nil {
			t.Fatalf("desiredStickyNodeHostnames() unexpected error: %v", err)
		}
		if got != nil {
			t.Fatalf("sticky hostnames = %#v, want nil", got)
		}
	})
}

func TestOrdinalNodeMapAnnotationHelpers(t *testing.T) {
	t.Run("parses and formats stable ordinal map", func(t *testing.T) {
		mapRaw := fmt.Sprintf("0=%s,1=%s,2=%s", testHostName2, testHostName1, testHostName3)
		parsed, ok := parseOrdinalNodeMapAnnotation(mapRaw)
		if !ok {
			t.Fatalf("expected map to parse")
		}
		if parsed[0] != testHostName2 || parsed[1] != testHostName1 || parsed[2] != testHostName3 {
			t.Fatalf("unexpected parsed map: %#v", parsed)
		}

		formatted := formatOrdinalNodeMapAnnotation(parsed, 3)
		if formatted != mapRaw {
			t.Fatalf("formatted map = %q, want %q", formatted, mapRaw)
		}
	})

	t.Run("merge keeps stored ordinal assignments", func(t *testing.T) {
		existing := map[int]string{
			0: testHostName2,
			1: testHostName1,
			2: testHostName3,
		}
		current := map[int]string{
			0: testHostName1,
			1: testHostName3,
			2: testHostName2,
		}

		merged := mergeOrdinalNodeMaps(existing, current, 3)
		if merged[0] != testHostName2 || merged[1] != testHostName1 || merged[2] != testHostName3 {
			t.Fatalf("merged map drifted from stored assignments: %#v", merged)
		}
	})
}

func TestDesiredVolumeClaimsWithKeyManagement(t *testing.T) {
	encryptedSC := "encrypted-sc"
	tonNode := &tonv1alpha1.TonNode{
		Spec: tonv1alpha1.TonNodeSpec{
			KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
				Enabled: true,
				EncryptedBundle: tonv1alpha1.TonNodeEncryptedBundleSpec{
					PVCSize:          "7Gi",
					StorageClassName: &encryptedSC,
					AccessModes: []corev1.PersistentVolumeAccessMode{
						corev1.ReadWriteOnce,
					},
				},
			},
		},
	}

	defaultSC := "default-sc"
	claims := desiredVolumeClaims(tonNode, &defaultSC)
	if len(claims) != 3 {
		t.Fatalf("expected 3 PVC templates with key management, got %d", len(claims))
	}

	var keyClaim *corev1.PersistentVolumeClaim
	for i := range claims {
		if claims[i].Name == keyBundleClaim {
			keyClaim = &claims[i]
			break
		}
	}
	if keyClaim == nil {
		t.Fatalf("missing %q PVC template", keyBundleClaim)
	}
	if keyClaim.Spec.StorageClassName == nil || *keyClaim.Spec.StorageClassName != encryptedSC {
		t.Fatalf("key bundle PVC storageClass = %v, want %s", keyClaim.Spec.StorageClassName, encryptedSC)
	}
	assertQuantityEqual(t, keyClaim.Spec.Resources.Requests[corev1.ResourceStorage], "7Gi", "key bundle pvc size")
}

func containerPortByName(t *testing.T, ports []corev1.ContainerPort, name string) corev1.ContainerPort {
	t.Helper()
	for _, port := range ports {
		if port.Name == name {
			return port
		}
	}
	t.Fatalf("port %q not found", name)
	return corev1.ContainerPort{}
}

func hasContainerPortNamed(ports []corev1.ContainerPort, name string) bool {
	for _, port := range ports {
		if port.Name == name {
			return true
		}
	}
	return false
}

func assertQuantityEqual(t *testing.T, actual resource.Quantity, expected string, field string) {
	t.Helper()
	want := resource.MustParse(expected)
	if actual.Cmp(want) != 0 {
		t.Fatalf("%s = %s, want %s", field, actual.String(), expected)
	}
}

func hasMount(mounts []corev1.VolumeMount, name string, path string) bool {
	for _, mount := range mounts {
		if mount.Name == name && mount.MountPath == path {
			return true
		}
	}
	return false
}

func hasMemoryVolume(volumes []corev1.Volume, name string) bool {
	for _, volume := range volumes {
		if volume.Name != name || volume.EmptyDir == nil {
			continue
		}
		if volume.EmptyDir.Medium == corev1.StorageMediumMemory {
			return true
		}
	}
	return false
}

func hasEnv(envVars []corev1.EnvVar, name string, value string) bool {
	for _, envVar := range envVars {
		if envVar.Name == name && envVar.Value == value {
			return true
		}
	}
	return false
}
