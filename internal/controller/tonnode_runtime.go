package controller

import (
	"fmt"
	"strings"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

const (
	tonExporterInitName   = "stage-ton-exporter"
	tonBinariesInitName   = "export-ton-binaries"
	tonExporterVolume     = "ton-exporter-script"
	tonArtifactsVolume    = "ton-artifacts"
	controllerWalletsPath = "/var/ton-work/controller/mytoncore/wallets"

	// Keep the old claims attached so existing StatefulSets do not require an
	// immutable claim-template change. The new runtime creates compatibility
	// symlinks itself, so those claims must not cover its image paths.
	persistentLayoutScript = `
set -eu
if [ ! -s /mnt/ton-work/controller/initialized.json ] \
  && [ ! -f /mnt/ton-work/controller/.initializing ] \
  && [ ! -f /mnt/keybundle/.restore-controller-state ]; then
  if [ -f /mnt/ton-work/db/mtc_done ] \
    || [ -s /mnt/mytoncore/mytoncore.db ] \
    || [ -s /mnt/ton-work/usr-local-bin-mytoncore/mytoncore.db ] \
    || { [ -s /mnt/ton-work/db/config.json ] && [ -d /mnt/ton-work/db/keyring ] \
      && [ -n "$(find /mnt/ton-work/db/keyring -mindepth 1 -print -quit)" ]; }; then
    echo "Legacy ton-docker-ctrl state detected. Stop the old node, export a native MyTonCtrl backup, and restore it with -p into a fresh TonNode work volume. Existing PVCs and keys were preserved." >&2
    exit 1
  fi
fi
mkdir -p /mnt/ton-work/controller
`

	tonExporterScript = `
set -eu
staged_script=$(mktemp /scripts/.export-ton.sh.XXXXXX)
trap 'rm -f "$staged_script"' EXIT
cp /usr/local/lib/mytonctrl/export-ton.sh "$staged_script"
chmod 444 "$staged_script"
mv -f "$staged_script" /scripts/export-ton.sh
`

	runtimeReadinessScript = `
test -s /var/ton-work/controller/initialized.json \
  && test -s /var/ton-work/controller/mytoncore/mytoncore.db \
  && test -s /var/ton-work/db/config.json \
  && test -s /var/ton-work/controller/services/validator.service \
  && test -s /var/ton-work/controller/services/mytoncore.service \
  && systemctl is-active --quiet validator mytoncore
`
)

func desiredTonImage(tonNode *tonv1alpha1.TonNode) string {
	if image := strings.TrimSpace(tonNode.Spec.TonImage); image != "" {
		return image
	}
	return defaultTonImage
}

func desiredTonImagePullPolicy(tonNode *tonv1alpha1.TonNode) corev1.PullPolicy {
	if imagePinnedByDigest(desiredTonImage(tonNode)) {
		return corev1.PullIfNotPresent
	}
	return corev1.PullAlways
}

func desiredTonExporterInitContainer(tonNode *tonv1alpha1.TonNode) corev1.Container {
	return corev1.Container{
		Name:                     tonExporterInitName,
		Image:                    desiredImage(tonNode),
		ImagePullPolicy:          desiredImagePullPolicy(tonNode),
		Command:                  []string{"/bin/sh", "-ec", tonExporterScript},
		Resources:                desiredKeyAgentResources(tonNode),
		TerminationMessagePolicy: corev1.TerminationMessageFallbackToLogsOnError,
		VolumeMounts: []corev1.VolumeMount{
			{Name: tonExporterVolume, MountPath: "/scripts"},
		},
	}
}

func desiredTonBinariesInitContainer(tonNode *tonv1alpha1.TonNode) corev1.Container {
	return corev1.Container{
		Name:            tonBinariesInitName,
		Image:           desiredTonImage(tonNode),
		ImagePullPolicy: desiredTonImagePullPolicy(tonNode),
		// The official TON image's init.sh must never initialize this node.
		Command:                  []string{"/bin/sh", "/scripts/export-ton.sh"},
		Env:                      []corev1.EnvVar{{Name: "TON_IMAGE_REF", Value: desiredTonImage(tonNode)}},
		Resources:                desiredKeyAgentResources(tonNode),
		TerminationMessagePolicy: corev1.TerminationMessageFallbackToLogsOnError,
		VolumeMounts: []corev1.VolumeMount{
			{Name: tonExporterVolume, MountPath: "/scripts", ReadOnly: true},
			{Name: tonArtifactsVolume, MountPath: "/ton-artifacts"},
		},
	}
}

func desiredRuntimeReadinessProbe() *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{
			Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-ec", runtimeReadinessScript}},
		},
		PeriodSeconds:    15,
		TimeoutSeconds:   5,
		FailureThreshold: 3,
	}
}

func validateRuntimeSpec(tonNode *tonv1alpha1.TonNode) string {
	for _, env := range tonNode.Spec.Env {
		switch env.Name {
		case "AUTHOR", "REPO", "BRANCH", "NODE_REPO", "NODE_VERSION", "MYTONCTRL_VERSION", "TON_BRANCH":
			if env.Value != "" || env.ValueFrom != nil {
				return fmt.Sprintf("spec.env %s selects sources; select spec.image or spec.tonImage instead", env.Name)
			}
		}
	}
	return validateInstallationArgs(tonNode)
}
