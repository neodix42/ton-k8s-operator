package controller

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	chartassets "github.com/neodix/ton-k8s-operator/charts"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"
)

func jemallocTestNode(hold, keys bool, args []string) *tonv1alpha1.TonNode {
	node := &tonv1alpha1.TonNode{
		ObjectMeta: metav1.ObjectMeta{Name: "profiled-ton", Namespace: "default"},
		Spec: tonv1alpha1.TonNodeSpec{
			Image:    "ghcr.io/example/mytonctrl:testing",
			TonImage: "ghcr.io/example/ton:testing",
			Args:     args,
			Debug:    tonv1alpha1.TonNodeDebugSpec{HoldOnFailure: hold},
			Env: []corev1.EnvVar{
				{Name: "CUSTOM_PARAMETERS", Value: "--exporter-address 0.0.0.0:9777"},
				{Name: "DUMP_EXTRACT_THREADS", Value: "2"},
			},
			ConfigRef: &corev1.LocalObjectReference{Name: "validator-config"},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("16"),
					corev1.ResourceMemory: resource.MustParse("64Gi"),
				},
				Limits: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("128Gi")},
			},
		},
	}
	if keys {
		node.Spec.KeyManagement = &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true}
	}
	return node
}

func TestJemallocDisabledPreservesPodTemplate(t *testing.T) {
	for _, hold := range []bool{false, true} {
		for _, keys := range []bool{false, true} {
			t.Run(fmt.Sprintf("hold=%t/keys=%t", hold, keys), func(t *testing.T) {
				node := jemallocTestNode(hold, keys, []string{"-m", "validator", "-n", "mainnet", "-d"})
				// Existing allocator settings remain user-owned while the feature is off.
				node.Spec.Env = append(node.Spec.Env, corev1.EnvVar{Name: "MALLOC_CONF", Value: "background_thread:true"})
				r := &TonNodeReconciler{}
				baseline := r.desiredPodTemplate(node, labelsForTonNode(node), corev1.EnvVar{}, nil)
				node.Spec.Debug.Jemalloc = &tonv1alpha1.TonNodeJemallocSpec{
					Enabled: false, SampleLog2: ptr.To[int32](1), IntervalLog2: ptr.To[int32](1), MaxProfiles: ptr.To[int32](0),
				}
				if message := validateJemallocSpec(node); message != "" {
					t.Fatalf("disabled profiling rejected dormant settings: %s", message)
				}
				got := r.desiredPodTemplate(node, labelsForTonNode(node), corev1.EnvVar{}, nil)
				if !reflect.DeepEqual(got, baseline) {
					t.Fatal("explicitly disabling profiling changed the existing pod template")
				}
				if got := envVarValueByName(got.Spec.Containers[0].Env, "MALLOC_CONF"); got != "background_thread:true" {
					t.Fatalf("user allocator configuration changed while profiling was disabled: %q", got)
				}
			})
		}
	}
}

func TestJemallocEnabledPreservesLaunchAndOtherContainers(t *testing.T) {
	installArgs := []string{"-m", "validator", "-n", "mainnet", "-d", "-c", "/config/with spaces.json", "$(touch should-not-run); literal"}
	for _, config := range []struct {
		name string
		spec *tonv1alpha1.TonNodeJemallocSpec
		want []string
	}{
		{
			name: "defaults", spec: &tonv1alpha1.TonNodeJemallocSpec{Enabled: true},
			want: []string{"--sample-log2", "19", "--interval-log2", "34", "--max-profiles", "8", "--"},
		},
		{
			name: "custom",
			spec: &tonv1alpha1.TonNodeJemallocSpec{
				Enabled: true, SampleLog2: ptr.To[int32](21), IntervalLog2: ptr.To[int32](36), MaxProfiles: ptr.To[int32](12),
			},
			want: []string{"--sample-log2", "21", "--interval-log2", "36", "--max-profiles", "12", "--"},
		},
	} {
		for _, args := range [][]string{nil, installArgs} {
			for _, hold := range []bool{false, true} {
				for _, keys := range []bool{false, true} {
					t.Run(fmt.Sprintf("%s/args=%t/hold=%t/keys=%t", config.name, len(args) > 0, hold, keys), func(t *testing.T) {
						node := jemallocTestNode(hold, keys, args)
						r := &TonNodeReconciler{}
						baseline := r.desiredPodTemplate(node, labelsForTonNode(node), corev1.EnvVar{}, []string{"worker-1"})
						node.Spec.Debug.Jemalloc = config.spec.DeepCopy()
						got := r.desiredPodTemplate(node, labelsForTonNode(node), corev1.EnvVar{}, []string{"worker-1"})
						main := &got.Spec.Containers[0]
						if !reflect.DeepEqual(main.Command, []string{"/opt/mytonctrl/venv/bin/python", "-c", chartassets.JemallocProfileScript}) {
							t.Fatal("main container does not invoke the shared profiling supervisor")
						}
						if len(main.Args) < len(config.want) || !reflect.DeepEqual(main.Args[:len(config.want)], config.want) {
							t.Fatalf("profiling flags = %q, want prefix %q", main.Args, config.want)
						}

						baseMain := baseline.Spec.Containers[0]
						wantLaunch := append([]string(nil), baseMain.Command...)
						if len(wantLaunch) == 0 {
							wantLaunch = []string{"/opt/mytonctrl/venv/bin/python", "/usr/local/lib/mytonctrl/entrypoint.py", "run"}
							if len(args) > 0 {
								wantLaunch = append(wantLaunch, args...)
							}
						} else {
							wantLaunch = append(wantLaunch, baseMain.Args...)
						}
						if !reflect.DeepEqual(main.Args[len(config.want):], wantLaunch) {
							t.Fatalf("profiling changed literal launch arguments: got %q, want %q", main.Args[len(config.want):], wantLaunch)
						}

						// Profiling must only wrap the application's command. Comparing the
						// rest of the complete template catches accidental wrapping of key
						// restore/backup, config or recovery bootstrap, and changed resource
						// limits, probes, mounts or RAM-backed secret volumes.
						main.Command, main.Args = baseMain.Command, baseMain.Args
						if !reflect.DeepEqual(got, baseline) {
							t.Fatal("profiling changed pod configuration beyond the main launch command")
						}
					})
				}
			}
		}
	}
}

func TestJemallocSpecValidation(t *testing.T) {
	for _, check := range []struct {
		name string
		min  int32
		max  int32
		set  func(*tonv1alpha1.TonNodeJemallocSpec, int32)
	}{
		{"sampleLog2", 10, 30, func(s *tonv1alpha1.TonNodeJemallocSpec, v int32) { s.SampleLog2 = ptr.To(v) }},
		{"intervalLog2", 20, 40, func(s *tonv1alpha1.TonNodeJemallocSpec, v int32) { s.IntervalLog2 = ptr.To(v) }},
		{"maxProfiles", 2, 100, func(s *tonv1alpha1.TonNodeJemallocSpec, v int32) { s.MaxProfiles = ptr.To(v) }},
	} {
		for _, value := range []int32{0, check.min - 1, check.min, check.max, check.max + 1} {
			t.Run(fmt.Sprintf("%s=%d", check.name, value), func(t *testing.T) {
				node := jemallocTestNode(false, false, nil)
				node.Spec.Debug.Jemalloc = &tonv1alpha1.TonNodeJemallocSpec{Enabled: true}
				check.set(node.Spec.Debug.Jemalloc, value)
				message := validateJemallocSpec(node)
				if value >= check.min && value <= check.max {
					if message != "" {
						t.Fatalf("valid boundary rejected: %s", message)
					}
				} else if !strings.Contains(message, "spec.debug.jemalloc."+check.name) {
					t.Fatalf("invalid value must identify the setting: %q", message)
				}
				if message != validateRuntimeSpec(node) {
					t.Fatalf("runtime validation did not propagate profiling validation: %q", validateRuntimeSpec(node))
				}
			})
		}
	}
	node := jemallocTestNode(false, false, nil)
	node.Spec.Debug.Jemalloc = &tonv1alpha1.TonNodeJemallocSpec{Enabled: true}
	if message := validateJemallocSpec(node); message != "" {
		t.Fatalf("omitted numeric settings should use defaults: %s", message)
	}
}

func TestJemallocRejectsConflictingAllocatorEnvironment(t *testing.T) {
	for _, env := range []corev1.EnvVar{
		{Name: "MALLOC_CONF", Value: "prof:false"},
		{Name: "MALLOC_CONF", Value: ""},
		{Name: "MALLOC_CONF", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: "allocator-options"}, Key: "options",
		}}},
		{Name: "MALLOC_CONF", ValueFrom: &corev1.EnvVarSource{ConfigMapKeyRef: &corev1.ConfigMapKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: "allocator-options"}, Key: "options",
		}}},
	} {
		t.Run(fmt.Sprintf("value=%q/source=%v", env.Value, env.ValueFrom), func(t *testing.T) {
			node := jemallocTestNode(false, false, nil)
			node.Spec.Env = append(node.Spec.Env, env)
			node.Spec.Debug.Jemalloc = &tonv1alpha1.TonNodeJemallocSpec{Enabled: true}
			if message := validateJemallocSpec(node); !strings.Contains(message, "MALLOC_CONF") || !strings.Contains(message, "conflict") {
				t.Fatalf("conflicting allocator option was not clearly rejected: %q", message)
			}
			for _, disabled := range []*tonv1alpha1.TonNodeJemallocSpec{nil, {Enabled: false}} {
				node.Spec.Debug.Jemalloc = disabled
				if message := validateRuntimeSpec(node); message != "" {
					t.Fatalf("disabled profiling must preserve custom allocator settings: %s", message)
				}
			}
		})
	}
}
