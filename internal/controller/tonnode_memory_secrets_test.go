package controller

import (
	"encoding/json"
	"os/exec"
	"strings"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// Check the complete Pod mount graph: protecting the application alone leaves
// init-container restore and sidecar archive staging on the container layer.
func TestManagedSecretsUseMemoryInEveryConsumer(t *testing.T) {
	node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{
		KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true},
		ConfigRef:     &corev1.LocalObjectReference{Name: "node-config"},
	}}
	pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
	volumes := make(map[string]corev1.Volume, len(pod.Volumes))
	for _, volume := range pod.Volumes {
		volumes[volume.Name] = volume
	}
	paths := []string{"/var/ton-work/keys", controllerWalletsPath, "/var/ton-work/controller", "/var/ton-work/db/keyring", "/tmp"}
	consumers := map[string]bool{tonContainerName: false, "key-restore": false, "key-backup": false, restoreBootstrapName: false}
	shared := map[string]string{}
	for _, container := range append(pod.InitContainers, pod.Containers...) {
		if _, ok := consumers[container.Name]; !ok {
			continue
		}
		consumers[container.Name] = true
		for _, path := range paths {
			mount := secretMountAt(t, container, path)
			volume, found := volumes[mount.Name]
			if !found || volume.EmptyDir == nil || volume.EmptyDir.Medium != corev1.StorageMediumMemory {
				t.Errorf("%s %s must be memory-backed, got %+v", container.Name, path, volume.VolumeSource)
			}
			if volume.EmptyDir != nil && (volume.EmptyDir.SizeLimit == nil || volume.EmptyDir.SizeLimit.Sign() <= 0) {
				t.Errorf("%s %s requires a positive RAM limit", container.Name, path)
			}
			if mount.ReadOnly || mount.SubPath != "" || mount.SubPathExpr != "" {
				t.Errorf("%s secret mount %s must use the shared writable memory directory, got %+v", container.Name, path, mount)
			}
			if previous, ok := shared[path]; ok && previous != mount.Name {
				t.Errorf("%s does not share %s with other secret consumers: %s != %s", container.Name, path, mount.Name, previous)
			}
			shared[path] = mount.Name
		}
		if container.Name == tonContainerName {
			mount := secretMountAt(t, container, "/run")
			if !hasMemoryVolume(pod.Volumes, mount.Name) {
				t.Error("runtime socket/token state under /run must use memory")
			}
		}
		if container.Name == "key-restore" {
			mount := secretMountAt(t, container, "/mnt/ton-work")
			if mount.Name != tonWorkClaimName {
				t.Errorf("migration must inspect the raw work volume: %+v", mount)
			}
		}
	}
	for name, found := range consumers {
		if !found {
			t.Errorf("missing secret consumer %s", name)
		}
	}
}

func TestManagedSecretMemoryLimits(t *testing.T) {
	for _, custom := range []bool{false, true} {
		t.Run(map[bool]string{false: "defaults", true: "configured"}[custom], func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true}}}
			want := map[string]string{"/var/ton-work/controller": "512Mi", "/var/ton-work/db/keyring": "128Mi", "/tmp": "2Gi"}
			if custom {
				if err := json.Unmarshal([]byte(`{"controllerSizeLimit":"768Mi","keyringSizeLimit":"256Mi","stagingSizeLimit":"3Gi"}`), &node.Spec.KeyManagement.InMemory); err != nil {
					t.Fatal(err)
				}
				want = map[string]string{"/var/ton-work/controller": "768Mi", "/var/ton-work/db/keyring": "256Mi", "/tmp": "3Gi"}
			}
			pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
			for path, size := range want {
				mount := secretMountAt(t, pod.Containers[0], path)
				for _, volume := range pod.Volumes {
					if volume.Name == mount.Name {
						expected := resource.MustParse(size)
						if volume.EmptyDir == nil || volume.EmptyDir.SizeLimit == nil || volume.EmptyDir.SizeLimit.Cmp(expected) != 0 {
							t.Errorf("%s memory size = %+v, want %s", path, volume.EmptyDir, size)
						}
					}
				}
			}
		})
	}
}

func TestUnmanagedNodesRetainPersistentRuntime(t *testing.T) {
	for _, keys := range []*tonv1alpha1.TonNodeKeyManagementSpec{nil, {Enabled: false}} {
		node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{KeyManagement: keys}}
		pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
		for _, container := range append(pod.InitContainers, pod.Containers...) {
			for _, mount := range container.VolumeMounts {
				if hasMemoryVolume(pod.Volumes, mount.Name) {
					t.Errorf("key-management-disabled container %s unexpectedly uses managed secret RAM mount %s", container.Name, mount.MountPath)
				}
			}
		}
		if !hasMount(pod.Containers[0].VolumeMounts, tonWorkClaimName, "/var/ton-work") {
			t.Error("unmanaged runtime lost its persistent work volume")
		}
	}
}

func TestManagedReadinessRequiresServicesAndDurableBundle(t *testing.T) {
	node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
		Enabled: true, EncryptedBundle: tonv1alpha1.TonNodeEncryptedBundleSpec{FileName: "custom.enc", MetaFileName: "custom.meta"},
	}}}
	pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
	main := pod.Containers[0]
	if pod.TerminationGracePeriodSeconds == nil || *pod.TerminationGracePeriodSeconds < 120 {
		t.Error("managed shutdown must reserve time for stopping services and encrypting final state")
	}
	for _, container := range pod.Containers {
		if container.Lifecycle == nil || container.Lifecycle.PreStop == nil || container.Lifecycle.PreStop.Exec == nil {
			t.Errorf("managed container %s lacks its final checkpoint shutdown hook", container.Name)
		}
	}
	for _, tt := range []struct {
		name             string
		bundle, metadata bool
		initialized      bool
		services         bool
		ready            bool
	}{
		{name: "initializing", bundle: true, metadata: true, services: true},
		{name: "no-checkpoint", initialized: true, services: true},
		{name: "missing-metadata", bundle: true, initialized: true, services: true},
		{name: "services-stopped", bundle: true, metadata: true, initialized: true},
		{name: "ready", bundle: true, metadata: true, initialized: true, services: true, ready: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, data := range migrationKeyFixtures() {
				if name != "controller/initialized.json" || tt.initialized {
					writeKeyFixture(t, work, name, data)
				}
			}
			if tt.bundle {
				writeKeyFixture(t, bundle, "custom.enc", "encrypted payload")
			}
			if tt.metadata {
				writeKeyFixture(t, bundle, "custom.meta", "wrapped key")
			}
			readiness := strings.NewReplacer("/var/ton-work", work, "/var/ton-key-bundle", bundle).Replace(main.ReadinessProbe.Exec.Command[2])
			serviceExit := "1"
			if tt.services {
				serviceExit = "0"
			}
			command := exec.Command("sh", "-c", "systemctl() { return "+serviceExit+"; }\n"+readiness)
			if output, err := command.CombinedOutput(); (err == nil) != tt.ready {
				t.Errorf("readiness = %v, want ready=%t: %s", err, tt.ready, output)
			}
		})
	}
}

func TestManagedReadinessTreatsCustomBundleFilenamesAsData(t *testing.T) {
	node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{
		Enabled: true, EncryptedBundle: tonv1alpha1.TonNodeEncryptedBundleSpec{
			FileName:     "custom 'quoted' \"$(false)\"; & bundle.enc",
			MetaFileName: "custom 'quoted' \"$(false)\"; & bundle.meta",
		},
	}}}
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, data := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, data)
	}
	writeKeyFixture(t, bundle, node.Spec.KeyManagement.EncryptedBundle.FileName, "encrypted payload")
	writeKeyFixture(t, bundle, node.Spec.KeyManagement.EncryptedBundle.MetaFileName, "wrapped key")
	pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
	readiness := strings.NewReplacer("/var/ton-work", work, "/var/ton-key-bundle", bundle).
		Replace(pod.Containers[0].ReadinessProbe.Exec.Command[2])
	output, err := exec.Command("sh", "-c", "systemctl() { return 0; }\n"+readiness).CombinedOutput()
	if err != nil || len(output) != 0 {
		t.Errorf("literal custom filenames must pass readiness without shell expansion: %v\n%s", err, output)
	}
}

func secretMountAt(t *testing.T, container corev1.Container, path string) corev1.VolumeMount {
	t.Helper()
	for _, mount := range container.VolumeMounts {
		if mount.MountPath == path {
			return mount
		}
	}
	t.Fatalf("%s lacks the required secret mount %s", container.Name, path)
	return corev1.VolumeMount{}
}
