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
