package controller

import (
	"context"
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
					Spec:       corev1.PodSpec{NodeName: "devnet-15"},
				},
				&corev1.Node{
					ObjectMeta: metav1.ObjectMeta{Name: "devnet-15"},
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
					Spec:       corev1.PodSpec{NodeName: "devnet-15"},
				},
				&corev1.Node{
					ObjectMeta: metav1.ObjectMeta{Name: "devnet-15"},
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
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP)

		if len(tpl.Spec.Containers) != 1 {
			t.Fatalf("expected one container, got %d", len(tpl.Spec.Containers))
		}
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.HostPort != defaultValidatorPort {
			t.Fatalf("validator hostPort = %d, want %d", validator.HostPort, defaultValidatorPort)
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
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP)
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.HostPort != 0 || liteserver.HostPort != 0 || console.HostPort != 0 {
			t.Fatalf("all hostPorts should be disabled, got validator=%d liteserver=%d console=%d", validator.HostPort, liteserver.HostPort, console.HostPort)
		}
	})

	t.Run("uses overridden ton ports", func(t *testing.T) {
		tonNode := &tonv1alpha1.TonNode{
			Spec: tonv1alpha1.TonNodeSpec{
				Network: tonv1alpha1.TonNodeNetworkSpec{
					ValidatorPort:        32001,
					LiteServerPort:       32003,
					ValidatorConsolePort: 32002,
					HostPortsEnabled:     ptr.To(true),
				},
			},
		}
		tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP)
		ports := tpl.Spec.Containers[0].Ports

		validator := containerPortByName(t, ports, "validator-udp")
		liteserver := containerPortByName(t, ports, "liteserver-tcp")
		console := containerPortByName(t, ports, "console-tcp")

		if validator.ContainerPort != 32001 || validator.HostPort != 32001 {
			t.Fatalf("validator ports = container:%d host:%d, want 32001/32001", validator.ContainerPort, validator.HostPort)
		}
		if liteserver.ContainerPort != 32003 || liteserver.HostPort != 32003 {
			t.Fatalf("liteserver ports = container:%d host:%d, want 32003/32003", liteserver.ContainerPort, liteserver.HostPort)
		}
		if console.ContainerPort != 32002 || console.HostPort != 0 {
			t.Fatalf("console ports = container:%d host:%d, want 32002/0", console.ContainerPort, console.HostPort)
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
			name:  "latest tag uses pull always",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl:latest",
			want:  corev1.PullAlways,
		},
		{
			name:  "image without tag is treated as latest",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl",
			want:  corev1.PullAlways,
		},
		{
			name:  "versioned tag uses if not present",
			image: "ghcr.io/ton-blockchain/ton-docker-ctrl:0.1.7",
			want:  corev1.PullIfNotPresent,
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

	tpl := reconciler.desiredPodTemplate(tonNode, labels, publicIP)

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
