package controller

import (
	"fmt"
	"strconv"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	chartassets "github.com/neodix/ton-k8s-operator/charts"
	corev1 "k8s.io/api/core/v1"
)

func jemallocProfilingEnabled(node *tonv1alpha1.TonNode) bool {
	return node.Spec.Debug.Jemalloc != nil && node.Spec.Debug.Jemalloc.Enabled
}

func jemallocValue(value *int32, fallback int32) int32 {
	if value == nil {
		return fallback
	}
	return *value
}

func validateJemallocSpec(node *tonv1alpha1.TonNode) string {
	if !jemallocProfilingEnabled(node) {
		return ""
	}
	config := node.Spec.Debug.Jemalloc
	for _, check := range []struct {
		name     string
		value    int32
		min, max int32
	}{
		{"sampleLog2", jemallocValue(config.SampleLog2, 19), 10, 30},
		{"intervalLog2", jemallocValue(config.IntervalLog2, 34), 20, 40},
		{"maxProfiles", jemallocValue(config.MaxProfiles, 8), 2, 100},
	} {
		if check.value < check.min || check.value > check.max {
			return fmt.Sprintf("spec.debug.jemalloc.%s must be between %d and %d", check.name, check.min, check.max)
		}
	}
	for _, env := range node.Spec.Env {
		if env.Name == "MALLOC_CONF" {
			return "spec.env MALLOC_CONF conflicts with managed spec.debug.jemalloc profiling; remove it or disable profiling"
		}
	}
	return ""
}

func configureJemallocProfiling(node *tonv1alpha1.TonNode, main *corev1.Container) {
	if !jemallocProfilingEnabled(node) {
		return
	}
	config := node.Spec.Debug.Jemalloc
	command := append([]string(nil), main.Command...)
	args := main.Args
	if len(command) == 0 {
		// The profiler is the outer wrapper; keep the existing entrypoint, flags,
		// secret-memory/core-limit protection and hold-on-failure behavior.
		command = []string{"/opt/mytonctrl/venv/bin/python", "/usr/local/lib/mytonctrl/entrypoint.py"}
		if len(args) == 0 {
			args = []string{"run"}
		}
	}
	command = append(command, args...)
	main.Command = []string{"/opt/mytonctrl/venv/bin/python", "-c", chartassets.JemallocProfileScript}
	main.Args = []string{
		"--sample-log2", strconv.Itoa(int(jemallocValue(config.SampleLog2, 19))),
		"--interval-log2", strconv.Itoa(int(jemallocValue(config.IntervalLog2, 34))),
		"--max-profiles", strconv.Itoa(int(jemallocValue(config.MaxProfiles, 8))), "--",
	}
	main.Args = append(main.Args, command...)
}
