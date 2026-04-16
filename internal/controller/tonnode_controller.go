/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
)

const (
	defaultImage                       = "ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64"
	defaultReplicas              int32 = 1
	defaultTonWorkSize                 = "200Gi"
	defaultMyTonCoreSize               = "20Gi"
	defaultCPURequest                  = "16000m"
	defaultMemoryRequest               = "64Gi"
	defaultCPULimit                    = "128000m"
	defaultMemoryLimit                 = "256Gi"
	defaultGlobalConfigURL             = "https://ton.org/global.config.json"
	defaultValidatorPort         int32 = 30001
	defaultLiteServerPort        int32 = 30003
	defaultQuicPort              int32 = 31001
	defaultConsolePort           int32 = 30002
	defaultKeyProvider                 = "vault"
	defaultKeyAgentImage               = "ghcr.io/ton-blockchain/ton-docker-ctrl:v2026.04-amd64"
	defaultKeysTmpfsSize               = "128Mi"
	defaultWalletsTmpfsSize            = "512Mi"
	defaultKeyBundlePVCSize            = "5Gi"
	defaultKeyBundleFileName           = "keys.bundle.enc"
	defaultKeyBundleMetaFileName       = "keys.bundle.meta"

	tonContainerName = "ton-node"
	tonWorkClaimName = "ton-work"
	myTonCoreClaim   = "mytoncore"
	keyBundleClaim   = "keybundle"

	headlessServiceSuffix    = "headless"
	bootstrapConfigVolume    = "bootstrap-config"
	bootstrapConfigMountPath = "/bootstrap"
	configSecretKey          = "config.json"
	keysTmpfsVolume          = "ton-keys-tmpfs"
	walletsTmpfsVolume       = "wallets-tmpfs"
	keyBundleMountPath       = "/var/ton-key-bundle"

	readyConditionType = "Ready"

	// kubetonPauseReplicasAnnotationKey stores the pre-pause replica count on TonNode/StatefulSet.
	// When present with a parseable integer value, reconciliation keeps StatefulSet replicas at 0.
	kubetonPauseReplicasAnnotationKey = "ton.ton.org/kubeton-paused-replicas"
)

// TonNodeReconciler reconciles a TonNode object
type TonNodeReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=ton.ton.org,resources=tonnodes,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ton.ton.org,resources=tonnodes/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=ton.ton.org,resources=tonnodes/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get
// +kubebuilder:rbac:groups=storage.k8s.io,resources=storageclasses,verbs=get;list;watch

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
func (r *TonNodeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var tonNode tonv1alpha1.TonNode
	if err := r.Get(ctx, req.NamespacedName, &tonNode); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	replicas := desiredReplicas(&tonNode)
	targetStatefulSetReplicas := desiredStatefulSetReplicas(&tonNode)
	pausedReplicas, pauseRequested := pausedReplicasAnnotation(&tonNode)
	if tonNode.Spec.ConfigRef != nil && replicas > 1 {
		message := "spec.configRef supports replicas=1 only to avoid sharing a single config.json across replicas"
		if err := r.updateStatus(ctx, &tonNode, 0, "", false, "InvalidSpec", message); err != nil {
			return ctrl.Result{}, err
		}
		log.Info("TonNode spec is not reconcilable", "name", req.NamespacedName, "reason", message)
		return ctrl.Result{}, nil
	}
	if message := validateKeyManagementSpec(&tonNode); message != "" {
		if err := r.updateStatus(ctx, &tonNode, 0, "", false, "InvalidSpec", message); err != nil {
			return ctrl.Result{}, err
		}
		log.Info("TonNode spec is not reconcilable", "name", req.NamespacedName, "reason", message)
		return ctrl.Result{}, nil
	}

	storageClassName, err := r.detectStorageClassName(ctx, &tonNode)
	if err != nil {
		return ctrl.Result{}, err
	}
	if storageClassName == nil {
		message := "no StorageClass found. Install/provide a StorageClass or set spec.storage.storageClassName"
		if err := r.updateStatus(ctx, &tonNode, 0, "", false, "StorageClassMissing", message); err != nil {
			return ctrl.Result{}, err
		}
		log.Info("TonNode blocked waiting for StorageClass", "name", req.NamespacedName)
		return ctrl.Result{}, nil
	}

	serviceName := fmt.Sprintf("%s-%s", tonNode.Name, headlessServiceSuffix)
	if err := r.reconcileHeadlessService(ctx, &tonNode, serviceName); err != nil {
		return ctrl.Result{}, err
	}

	sts, err := r.reconcileStatefulSet(ctx, &tonNode, serviceName, storageClassName)
	if err != nil {
		return ctrl.Result{}, err
	}

	isReady := false
	reason := "Reconciling"
	message := fmt.Sprintf("ready replicas %d/%d", sts.Status.ReadyReplicas, targetStatefulSetReplicas)
	if pauseRequested {
		reason = "Paused"
		if sts.Status.ReadyReplicas == 0 {
			isReady = true
			message = fmt.Sprintf("pause requested (%s=%d); all TON replicas are stopped", kubetonPauseReplicasAnnotationKey, pausedReplicas)
		} else {
			message = fmt.Sprintf("pause requested (%s=%d); draining replicas, ready=%d", kubetonPauseReplicasAnnotationKey, pausedReplicas, sts.Status.ReadyReplicas)
		}
	} else {
		isReady = sts.Status.ReadyReplicas >= targetStatefulSetReplicas
		if isReady {
			reason = "Ready"
			message = "all TON replicas are ready"
		}
	}

	if err := r.updateStatus(ctx, &tonNode, sts.Status.ReadyReplicas, serviceName, isReady, reason, message); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *TonNodeReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&tonv1alpha1.TonNode{}).
		Owns(&appsv1.StatefulSet{}).
		Owns(&corev1.Service{}).
		Named("tonnode").
		Complete(r)
}

func (r *TonNodeReconciler) reconcileHeadlessService(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
	serviceName string,
) error {
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      serviceName,
			Namespace: tonNode.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, service, func() error {
		labels := labelsForTonNode(tonNode)
		service.Labels = labels
		service.Spec.Selector = labels
		service.Spec.ClusterIP = corev1.ClusterIPNone
		service.Spec.PublishNotReadyAddresses = true
		service.Spec.Ports = []corev1.ServicePort{
			{
				Name:       "validator-udp",
				Port:       desiredValidatorPort(tonNode),
				Protocol:   corev1.ProtocolUDP,
				TargetPort: intstr.FromInt32(desiredValidatorPort(tonNode)),
			},
			{
				Name:       "quic-udp",
				Port:       desiredQuicPort(tonNode),
				Protocol:   corev1.ProtocolUDP,
				TargetPort: intstr.FromInt32(desiredQuicPort(tonNode)),
			},
			{
				Name:       "liteserver-tcp",
				Port:       desiredLiteServerPort(tonNode),
				Protocol:   corev1.ProtocolTCP,
				TargetPort: intstr.FromInt32(desiredLiteServerPort(tonNode)),
			},
			{
				Name:       "console-tcp",
				Port:       desiredConsolePort(tonNode),
				Protocol:   corev1.ProtocolTCP,
				TargetPort: intstr.FromInt32(desiredConsolePort(tonNode)),
			},
		}
		return controllerutil.SetControllerReference(tonNode, service, r.Scheme)
	})
	return err
}

func (r *TonNodeReconciler) reconcileStatefulSet(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
	serviceName string,
	storageClassName *string,
) (*appsv1.StatefulSet, error) {
	sts := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      tonNode.Name,
			Namespace: tonNode.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, sts, func() error {
		labels := labelsForTonNode(tonNode)
		replicas := desiredStatefulSetReplicas(tonNode)
		publicIP, err := r.desiredPublicIPEnv(ctx, tonNode)
		if err != nil {
			return err
		}
		stickyNodeHostnames, err := r.desiredStickyNodeHostnames(ctx, tonNode, sts.Spec.Template.Spec.Affinity, labels)
		if err != nil {
			return err
		}
		sts.Labels = labels
		sts.Spec.Replicas = ptr.To(replicas)
		sts.Spec.ServiceName = serviceName
		sts.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		sts.Spec.PodManagementPolicy = appsv1.ParallelPodManagement
		sts.Spec.UpdateStrategy = appsv1.StatefulSetUpdateStrategy{Type: appsv1.RollingUpdateStatefulSetStrategyType}
		sts.Spec.Template = r.desiredPodTemplate(tonNode, labels, publicIP, stickyNodeHostnames)
		sts.Spec.VolumeClaimTemplates = desiredVolumeClaims(tonNode, storageClassName)
		return controllerutil.SetControllerReference(tonNode, sts, r.Scheme)
	})
	if err != nil {
		return nil, err
	}

	if err := r.Get(ctx, client.ObjectKeyFromObject(sts), sts); err != nil {
		return nil, err
	}
	return sts, nil
}

func (r *TonNodeReconciler) desiredPodTemplate(
	tonNode *tonv1alpha1.TonNode,
	labels map[string]string,
	publicIP corev1.EnvVar,
	stickyNodeHostnames []string,
) corev1.PodTemplateSpec {
	env := mergeEnvVars(defaultTonEnv(tonNode, publicIP), tonNode.Spec.Env)
	containerPorts := []corev1.ContainerPort{
		{
			Name:          "validator-udp",
			ContainerPort: desiredValidatorPort(tonNode),
			Protocol:      corev1.ProtocolUDP,
		},
		{
			Name:          "quic-udp",
			ContainerPort: desiredQuicPort(tonNode),
			Protocol:      corev1.ProtocolUDP,
		},
		{
			Name:          "liteserver-tcp",
			ContainerPort: desiredLiteServerPort(tonNode),
			Protocol:      corev1.ProtocolTCP,
		},
		{
			Name:          "console-tcp",
			ContainerPort: desiredConsolePort(tonNode),
			Protocol:      corev1.ProtocolTCP,
		},
	}
	if hostPortsEnabled(tonNode) {
		for i := range containerPorts {
			if containerPorts[i].Name == "console-tcp" {
				continue
			}
			containerPorts[i].HostPort = containerPorts[i].ContainerPort
		}
	}

	volumeMounts := []corev1.VolumeMount{
		{Name: tonWorkClaimName, MountPath: "/var/ton-work"},
		{Name: myTonCoreClaim, MountPath: "/usr/local/bin/mytoncore"},
	}
	if keyManagementEnabled(tonNode) {
		volumeMounts = append(volumeMounts,
			corev1.VolumeMount{Name: keysTmpfsVolume, MountPath: "/var/ton-work/keys"},
			corev1.VolumeMount{Name: walletsTmpfsVolume, MountPath: "/usr/local/bin/mytoncore/wallets"},
			corev1.VolumeMount{Name: keyBundleClaim, MountPath: keyBundleMountPath},
		)
	}

	container := corev1.Container{
		Name:            tonContainerName,
		Image:           desiredImage(tonNode),
		ImagePullPolicy: desiredImagePullPolicy(tonNode),
		Env:             env,
		Resources:       desiredResources(tonNode),
		Ports:           containerPorts,
		VolumeMounts:    volumeMounts,
	}

	podSpec := corev1.PodSpec{
		NodeSelector: desiredNodeSelector(tonNode),
		Affinity:     requiredPodAntiAffinity(labels, stickyNodeHostnames),
		Containers:   []corev1.Container{container},
	}
	if keyManagementEnabled(tonNode) {
		podSpec.Volumes = append(podSpec.Volumes,
			corev1.Volume{
				Name: keysTmpfsVolume,
				VolumeSource: corev1.VolumeSource{
					EmptyDir: &corev1.EmptyDirVolumeSource{
						Medium:    corev1.StorageMediumMemory,
						SizeLimit: ptr.To(parseQuantityOrDefault(desiredKeysTmpfsSize(tonNode), defaultKeysTmpfsSize)),
					},
				},
			},
			corev1.Volume{
				Name: walletsTmpfsVolume,
				VolumeSource: corev1.VolumeSource{
					EmptyDir: &corev1.EmptyDirVolumeSource{
						Medium:    corev1.StorageMediumMemory,
						SizeLimit: ptr.To(parseQuantityOrDefault(desiredWalletsTmpfsSize(tonNode), defaultWalletsTmpfsSize)),
					},
				},
			},
		)
		podSpec.InitContainers = append(podSpec.InitContainers, desiredKeyRestoreInitContainer(tonNode))
		podSpec.Containers = append(podSpec.Containers, desiredKeyBackupSidecar(tonNode))
	}

	if tonNode.Spec.ConfigRef != nil {
		podSpec.InitContainers = append(podSpec.InitContainers, corev1.Container{
			Name:            "bootstrap-config",
			Image:           "busybox:1.36",
			ImagePullPolicy: corev1.PullIfNotPresent,
			Command: []string{
				"sh",
				"-c",
				"if [ -f /bootstrap/config.json ] && [ ! -f /var/ton-work/db/config.json ]; then cp /bootstrap/config.json /var/ton-work/db/config.json; fi",
			},
			VolumeMounts: []corev1.VolumeMount{
				{Name: bootstrapConfigVolume, MountPath: bootstrapConfigMountPath, ReadOnly: true},
				{Name: tonWorkClaimName, MountPath: "/var/ton-work"},
			},
		})
		podSpec.Volumes = append(podSpec.Volumes, corev1.Volume{
			Name: bootstrapConfigVolume,
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{
					SecretName: tonNode.Spec.ConfigRef.Name,
					Items: []corev1.KeyToPath{
						{Key: configSecretKey, Path: configSecretKey},
					},
					Optional: ptr.To(false),
				},
			},
		})
	}

	return corev1.PodTemplateSpec{
		ObjectMeta: metav1.ObjectMeta{Labels: labels},
		Spec:       podSpec,
	}
}

func desiredVolumeClaims(
	tonNode *tonv1alpha1.TonNode,
	storageClassName *string,
) []corev1.PersistentVolumeClaim {
	labels := labelsForTonNode(tonNode)
	accessModes := tonNode.Spec.Storage.AccessModes
	if len(accessModes) == 0 {
		accessModes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
	}

	tonWorkSize := parseQuantityOrDefault(tonNode.Spec.Storage.TonWorkSize, defaultTonWorkSize)
	myTonCoreSize := parseQuantityOrDefault(tonNode.Spec.Storage.MyTonCoreSize, defaultMyTonCoreSize)

	claims := []corev1.PersistentVolumeClaim{
		{
			ObjectMeta: metav1.ObjectMeta{Name: tonWorkClaimName, Labels: labels},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      accessModes,
				StorageClassName: storageClassName,
				Resources: corev1.VolumeResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceStorage: tonWorkSize,
					},
				},
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: myTonCoreClaim, Labels: labels},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      accessModes,
				StorageClassName: storageClassName,
				Resources: corev1.VolumeResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceStorage: myTonCoreSize,
					},
				},
			},
		},
	}

	if !keyManagementEnabled(tonNode) {
		return claims
	}

	keyAccessModes := desiredKeyBundleAccessModes(tonNode)
	keyStorageClassName := desiredKeyBundleStorageClassName(tonNode, storageClassName)
	keyBundleSize := parseQuantityOrDefault(desiredKeyBundlePVCSize(tonNode), defaultKeyBundlePVCSize)
	claims = append(claims, corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: keyBundleClaim, Labels: labels},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes:      keyAccessModes,
			StorageClassName: keyStorageClassName,
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceStorage: keyBundleSize,
				},
			},
		},
	})

	return claims
}

func keyManagementEnabled(tonNode *tonv1alpha1.TonNode) bool {
	return tonNode.Spec.KeyManagement != nil && tonNode.Spec.KeyManagement.Enabled
}

func validateKeyManagementSpec(tonNode *tonv1alpha1.TonNode) string {
	if !keyManagementEnabled(tonNode) {
		return ""
	}

	keySpec := tonNode.Spec.KeyManagement
	if keySpec.CredentialsSecretRef == nil || strings.TrimSpace(keySpec.CredentialsSecretRef.Name) == "" {
		return "spec.keyManagement.credentialsSecretRef.name is required when key management is enabled"
	}

	switch desiredKeyProvider(tonNode) {
	case "vault":
		if strings.TrimSpace(desiredVaultTransitKey(tonNode)) == "" {
			return "spec.keyManagement.vaultTransitKey is required for provider=vault"
		}
	case "kms":
		if strings.TrimSpace(desiredKMSKeyID(tonNode)) == "" {
			return "spec.keyManagement.kmsKeyID is required for provider=kms"
		}
		switch desiredKMSVendor(tonNode) {
		case "aws", "gcp":
			// ok
		default:
			return "spec.keyManagement.kmsVendor must be aws or gcp for provider=kms"
		}
	default:
		return "spec.keyManagement.provider must be vault or kms"
	}

	return ""
}

func desiredKeyProvider(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeyProvider
	}
	if provider := strings.TrimSpace(tonNode.Spec.KeyManagement.Provider); provider != "" {
		return strings.ToLower(provider)
	}
	return defaultKeyProvider
}

func desiredVaultTransitKey(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return ""
	}
	return strings.TrimSpace(tonNode.Spec.KeyManagement.VaultTransitKey)
}

func desiredKMSKeyID(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return ""
	}
	return strings.TrimSpace(tonNode.Spec.KeyManagement.KMSKeyID)
}

func desiredKMSVendor(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(tonNode.Spec.KeyManagement.KMSVendor))
}

func desiredKeyAgentImage(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeyAgentImage
	}
	if image := strings.TrimSpace(tonNode.Spec.KeyManagement.Agent.Image); image != "" {
		return image
	}
	return defaultKeyAgentImage
}

func desiredKeyAgentImagePullPolicy(tonNode *tonv1alpha1.TonNode) corev1.PullPolicy {
	if imagePinnedByDigest(desiredKeyAgentImage(tonNode)) {
		return corev1.PullIfNotPresent
	}
	return corev1.PullAlways
}

func desiredKeyAgentResources(tonNode *tonv1alpha1.TonNode) corev1.ResourceRequirements {
	if tonNode.Spec.KeyManagement == nil {
		return corev1.ResourceRequirements{}
	}
	return tonNode.Spec.KeyManagement.Agent.Resources
}

func desiredKeysTmpfsSize(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeysTmpfsSize
	}
	size := strings.TrimSpace(tonNode.Spec.KeyManagement.InMemory.KeysSizeLimit)
	if size == "" {
		return defaultKeysTmpfsSize
	}
	return size
}

func desiredWalletsTmpfsSize(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultWalletsTmpfsSize
	}
	size := strings.TrimSpace(tonNode.Spec.KeyManagement.InMemory.WalletsSizeLimit)
	if size == "" {
		return defaultWalletsTmpfsSize
	}
	return size
}

func desiredKeyBundlePVCSize(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeyBundlePVCSize
	}
	size := strings.TrimSpace(tonNode.Spec.KeyManagement.EncryptedBundle.PVCSize)
	if size == "" {
		return defaultKeyBundlePVCSize
	}
	return size
}

func desiredKeyBundleStorageClassName(
	tonNode *tonv1alpha1.TonNode,
	defaultStorageClassName *string,
) *string {
	if tonNode.Spec.KeyManagement == nil || tonNode.Spec.KeyManagement.EncryptedBundle.StorageClassName == nil {
		return defaultStorageClassName
	}
	name := strings.TrimSpace(*tonNode.Spec.KeyManagement.EncryptedBundle.StorageClassName)
	if name == "" {
		return defaultStorageClassName
	}
	return &name
}

func desiredKeyBundleAccessModes(tonNode *tonv1alpha1.TonNode) []corev1.PersistentVolumeAccessMode {
	if tonNode.Spec.KeyManagement == nil || len(tonNode.Spec.KeyManagement.EncryptedBundle.AccessModes) == 0 {
		return []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
	}
	return tonNode.Spec.KeyManagement.EncryptedBundle.AccessModes
}

func desiredKeyBundleFileName(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeyBundleFileName
	}
	name := strings.TrimSpace(tonNode.Spec.KeyManagement.EncryptedBundle.FileName)
	if name == "" {
		return defaultKeyBundleFileName
	}
	return name
}

func desiredKeyBundleMetaFileName(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil {
		return defaultKeyBundleMetaFileName
	}
	name := strings.TrimSpace(tonNode.Spec.KeyManagement.EncryptedBundle.MetaFileName)
	if name == "" {
		return defaultKeyBundleMetaFileName
	}
	return name
}

func desiredKeyAgentSecretName(tonNode *tonv1alpha1.TonNode) string {
	if tonNode.Spec.KeyManagement == nil || tonNode.Spec.KeyManagement.CredentialsSecretRef == nil {
		return ""
	}
	return strings.TrimSpace(tonNode.Spec.KeyManagement.CredentialsSecretRef.Name)
}

func desiredKeyAgentEnvFrom(tonNode *tonv1alpha1.TonNode) []corev1.EnvFromSource {
	secretName := desiredKeyAgentSecretName(tonNode)
	if secretName == "" {
		return nil
	}
	return []corev1.EnvFromSource{
		{
			SecretRef: &corev1.SecretEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{Name: secretName},
				Optional:             ptr.To(false),
			},
		},
	}
}

func desiredKeyAgentEnv(tonNode *tonv1alpha1.TonNode) []corev1.EnvVar {
	env := []corev1.EnvVar{
		{Name: "KEY_PROVIDER", Value: desiredKeyProvider(tonNode)},
		{Name: "KEY_BUNDLE_FILE", Value: desiredKeyBundleFileName(tonNode)},
		{Name: "KEY_BUNDLE_META_FILE", Value: desiredKeyBundleMetaFileName(tonNode)},
	}
	if value := desiredVaultTransitKey(tonNode); value != "" {
		env = append(env, corev1.EnvVar{Name: "VAULT_TRANSIT_KEY", Value: value})
	}
	if value := desiredKMSKeyID(tonNode); value != "" {
		env = append(env, corev1.EnvVar{Name: "KMS_KEY_ID", Value: value})
	}
	if value := desiredKMSVendor(tonNode); value != "" {
		env = append(env, corev1.EnvVar{Name: "KMS_VENDOR", Value: value})
	}
	return env
}

func desiredKeyAgentVolumeMounts() []corev1.VolumeMount {
	return []corev1.VolumeMount{
		{Name: tonWorkClaimName, MountPath: "/var/ton-work"},
		{Name: myTonCoreClaim, MountPath: "/usr/local/bin/mytoncore"},
		{Name: keysTmpfsVolume, MountPath: "/var/ton-work/keys"},
		{Name: walletsTmpfsVolume, MountPath: "/usr/local/bin/mytoncore/wallets"},
		{Name: keyBundleClaim, MountPath: keyBundleMountPath},
	}
}

func desiredKeyRestoreInitContainer(tonNode *tonv1alpha1.TonNode) corev1.Container {
	return corev1.Container{
		Name:            "key-restore",
		Image:           desiredKeyAgentImage(tonNode),
		ImagePullPolicy: desiredKeyAgentImagePullPolicy(tonNode),
		Command:         []string{"sh", "-ec", keyRestoreScript},
		Env:             desiredKeyAgentEnv(tonNode),
		EnvFrom:         desiredKeyAgentEnvFrom(tonNode),
		Resources:       desiredKeyAgentResources(tonNode),
		VolumeMounts:    desiredKeyAgentVolumeMounts(),
	}
}

func desiredKeyBackupSidecar(tonNode *tonv1alpha1.TonNode) corev1.Container {
	return corev1.Container{
		Name:            "key-backup",
		Image:           desiredKeyAgentImage(tonNode),
		ImagePullPolicy: desiredKeyAgentImagePullPolicy(tonNode),
		Command:         []string{"sh", "-ec", keyBackupScript},
		Env:             desiredKeyAgentEnv(tonNode),
		EnvFrom:         desiredKeyAgentEnvFrom(tonNode),
		Resources:       desiredKeyAgentResources(tonNode),
		VolumeMounts:    desiredKeyAgentVolumeMounts(),
	}
}

const keyRestoreScript = `
set -eu

KEYS_DIR="/var/ton-work/keys"
MYTONCORE_DIR="/usr/local/bin/mytoncore"
WALLETS_DIR="${MYTONCORE_DIR}/wallets"
TON_DB_DIR="/var/ton-work/db"
DB_CONFIG_FILE="${TON_DB_DIR}/config.json"
DB_KEYRING_DIR="${TON_DB_DIR}/keyring"
SYSTEMD_UNITS_DIR="${TON_DB_DIR}/systemd-units"
MTC_DONE_FILE="${TON_DB_DIR}/mtc_done"
BUNDLE_DIR="/var/ton-key-bundle"
BUNDLE_FILE="${BUNDLE_DIR}/${KEY_BUNDLE_FILE}"
META_FILE="${BUNDLE_DIR}/${KEY_BUNDLE_META_FILE}"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}

read_meta_value() {
  key="$1"
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$META_FILE"
}

vault_decrypt() {
  wrapped="$1"
  need_bin curl
  need_bin jq
  if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_TOKEN:-}" ] || [ -z "${VAULT_TRANSIT_KEY:-}" ]; then
    echo "vault provider requires VAULT_ADDR, VAULT_TOKEN and VAULT_TRANSIT_KEY" >&2
    return 1
  fi

  payload="$(printf '{"ciphertext":"%s"}' "$wrapped")"
  if [ -n "${VAULT_NAMESPACE:-}" ]; then
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  else
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/decrypt/${VAULT_TRANSIT_KEY}")"
  fi

  printf '%s' "$resp" | jq -r '.data.plaintext' | base64 -d
}

kms_decrypt() {
  wrapped="$1"
  case "${KMS_VENDOR:-}" in
    aws)
      need_bin aws
      if [ -z "${KMS_KEY_ID:-}" ]; then
        echo "kms provider requires KMS_KEY_ID for aws" >&2
        return 1
      fi
      blob_file="$(mktemp)"
      printf '%s' "$wrapped" | base64 -d >"$blob_file"
      plaintext_b64="$(aws kms decrypt --key-id "$KMS_KEY_ID" --ciphertext-blob "fileb://${blob_file}" --query Plaintext --output text)"
      rm -f "$blob_file"
      printf '%s' "$plaintext_b64" | base64 -d
      ;;
    gcp)
      need_bin gcloud
      if [ -z "${KMS_PROJECT_ID:-}" ] || [ -z "${KMS_LOCATION:-}" ] || [ -z "${KMS_KEY_RING:-}" ] || [ -z "${KMS_KEY_ID:-}" ]; then
        echo "gcp kms requires KMS_PROJECT_ID, KMS_LOCATION, KMS_KEY_RING and KMS_KEY_ID" >&2
        return 1
      fi
      cipher_file="$(mktemp)"
      plain_file="$(mktemp)"
      printf '%s' "$wrapped" | base64 -d >"$cipher_file"
      gcloud kms decrypt \
        --project "$KMS_PROJECT_ID" \
        --location "$KMS_LOCATION" \
        --keyring "$KMS_KEY_RING" \
        --key "$KMS_KEY_ID" \
        --ciphertext-file "$cipher_file" \
        --plaintext-file "$plain_file" >/dev/null
      cat "$plain_file"
      rm -f "$cipher_file" "$plain_file"
      ;;
    *)
      echo "unsupported KMS_VENDOR=${KMS_VENDOR:-}" >&2
      return 1
      ;;
  esac
}

unwrap_data_key() {
  wrapped="$1"
  case "${KEY_PROVIDER:-}" in
    vault)
      vault_decrypt "$wrapped"
      ;;
    kms)
      kms_decrypt "$wrapped"
      ;;
    *)
      echo "unsupported KEY_PROVIDER=${KEY_PROVIDER:-}" >&2
      return 1
      ;;
  esac
}

need_bin tar
need_bin openssl
need_bin base64
mkdir -p "$KEYS_DIR" "$WALLETS_DIR" "$MYTONCORE_DIR" "$TON_DB_DIR" "$BUNDLE_DIR"

if [ ! -s "$BUNDLE_FILE" ] || [ ! -s "$META_FILE" ]; then
  echo "no encrypted key bundle found; continuing without key restore"
  exit 0
fi

wrapped_key="$(read_meta_value wrapped_key)"
if [ -z "$wrapped_key" ]; then
  echo "key bundle metadata missing wrapped_key" >&2
  exit 1
fi

DATA_KEY_B64="$(unwrap_data_key "$wrapped_key")"
if [ -z "$DATA_KEY_B64" ]; then
  echo "failed to unwrap data key" >&2
  exit 1
fi
export DATA_KEY_B64

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 \
  -pass env:DATA_KEY_B64 \
  -in "$BUNDLE_FILE" \
  -out "$work_dir/bundle.tar.gz"

mkdir -p "$work_dir/unpacked"
tar -xzf "$work_dir/bundle.tar.gz" -C "$work_dir/unpacked"

find "$KEYS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
find "$MYTONCORE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
rm -f "$DB_CONFIG_FILE" || true
rm -rf "$DB_KEYRING_DIR" || true
rm -rf "$SYSTEMD_UNITS_DIR" || true
rm -f "$MTC_DONE_FILE" || true

if [ -d "$work_dir/unpacked/keys" ]; then
  cp -a "$work_dir/unpacked/keys/." "$KEYS_DIR/"
fi
if [ -d "$work_dir/unpacked/mytoncore" ]; then
  cp -a "$work_dir/unpacked/mytoncore/." "$MYTONCORE_DIR/"
fi
if [ -f "$work_dir/unpacked/tondb/config.json" ]; then
  cp -a "$work_dir/unpacked/tondb/config.json" "$DB_CONFIG_FILE"
fi
if [ -d "$work_dir/unpacked/tondb/keyring" ]; then
  cp -a "$work_dir/unpacked/tondb/keyring" "$DB_KEYRING_DIR"
fi
if [ -d "$work_dir/unpacked/tondb/systemd-units" ]; then
  cp -a "$work_dir/unpacked/tondb/systemd-units" "$SYSTEMD_UNITS_DIR"
fi
if [ -f "$work_dir/unpacked/tondb/mtc_done" ]; then
  cp -a "$work_dir/unpacked/tondb/mtc_done" "$MTC_DONE_FILE"
fi

chmod 700 "$KEYS_DIR" "$MYTONCORE_DIR" "$WALLETS_DIR" || true
chmod 700 "$DB_KEYRING_DIR" || true
chmod 700 "$SYSTEMD_UNITS_DIR" || true
chmod 600 "$DB_CONFIG_FILE" || true
chmod 600 "$MTC_DONE_FILE" || true
echo "encrypted key bundle restored"
`

const keyBackupScript = `
set -eu

KEYS_DIR="/var/ton-work/keys"
MYTONCORE_DIR="/usr/local/bin/mytoncore"
WALLETS_DIR="${MYTONCORE_DIR}/wallets"
TON_DB_DIR="/var/ton-work/db"
DB_CONFIG_FILE="${TON_DB_DIR}/config.json"
DB_KEYRING_DIR="${TON_DB_DIR}/keyring"
SYSTEMD_UNITS_DIR="${TON_DB_DIR}/systemd-units"
MTC_DONE_FILE="${TON_DB_DIR}/mtc_done"
BUNDLE_DIR="/var/ton-key-bundle"
BUNDLE_FILE="${BUNDLE_DIR}/${KEY_BUNDLE_FILE}"
META_FILE="${BUNDLE_DIR}/${KEY_BUNDLE_META_FILE}"
REQUEST_FILE="/tmp/key-backup.request"
DONE_FILE="/tmp/key-backup.done"
FAIL_FILE="/tmp/key-backup.failed"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}

vault_encrypt() {
  data_key_b64="$1"
  need_bin curl
  need_bin jq
  if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_TOKEN:-}" ] || [ -z "${VAULT_TRANSIT_KEY:-}" ]; then
    echo "vault provider requires VAULT_ADDR, VAULT_TOKEN and VAULT_TRANSIT_KEY" >&2
    return 1
  fi

  plaintext="$(printf '%s' "$data_key_b64" | base64 | tr -d '\n')"
  payload="$(printf '{"plaintext":"%s"}' "$plaintext")"
  if [ -n "${VAULT_NAMESPACE:-}" ]; then
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/encrypt/${VAULT_TRANSIT_KEY}")"
  else
    resp="$(curl -fsS \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      --request POST \
      --data "$payload" \
      "${VAULT_ADDR%/}/v1/transit/encrypt/${VAULT_TRANSIT_KEY}")"
  fi

  printf '%s' "$resp" | jq -r '.data.ciphertext'
}

kms_encrypt() {
  data_key_b64="$1"
  case "${KMS_VENDOR:-}" in
    aws)
      need_bin aws
      if [ -z "${KMS_KEY_ID:-}" ]; then
        echo "kms provider requires KMS_KEY_ID for aws" >&2
        return 1
      fi
      plain_file="$(mktemp)"
      printf '%s' "$data_key_b64" >"$plain_file"
      aws kms encrypt --key-id "$KMS_KEY_ID" --plaintext "fileb://${plain_file}" --query CiphertextBlob --output text
      rm -f "$plain_file"
      ;;
    gcp)
      need_bin gcloud
      if [ -z "${KMS_PROJECT_ID:-}" ] || [ -z "${KMS_LOCATION:-}" ] || [ -z "${KMS_KEY_RING:-}" ] || [ -z "${KMS_KEY_ID:-}" ]; then
        echo "gcp kms requires KMS_PROJECT_ID, KMS_LOCATION, KMS_KEY_RING and KMS_KEY_ID" >&2
        return 1
      fi
      plain_file="$(mktemp)"
      cipher_file="$(mktemp)"
      printf '%s' "$data_key_b64" >"$plain_file"
      gcloud kms encrypt \
        --project "$KMS_PROJECT_ID" \
        --location "$KMS_LOCATION" \
        --keyring "$KMS_KEY_RING" \
        --key "$KMS_KEY_ID" \
        --plaintext-file "$plain_file" \
        --ciphertext-file "$cipher_file" >/dev/null
      base64 <"$cipher_file" | tr -d '\n'
      rm -f "$plain_file" "$cipher_file"
      ;;
    *)
      echo "unsupported KMS_VENDOR=${KMS_VENDOR:-}" >&2
      return 1
      ;;
  esac
}

wrap_data_key() {
  data_key_b64="$1"
  case "${KEY_PROVIDER:-}" in
    vault)
      vault_encrypt "$data_key_b64"
      ;;
    kms)
      kms_encrypt "$data_key_b64"
      ;;
    *)
      echo "unsupported KEY_PROVIDER=${KEY_PROVIDER:-}" >&2
      return 1
      ;;
  esac
}

backup_sources_present() {
  if find "$KEYS_DIR" -mindepth 1 -print -quit | grep -q .; then
    return 0
  fi
  if find "$MYTONCORE_DIR" -mindepth 1 -print -quit | grep -q .; then
    return 0
  fi
  if [ -s "$DB_CONFIG_FILE" ]; then
    return 0
  fi
  if [ -d "$DB_KEYRING_DIR" ] && find "$DB_KEYRING_DIR" -mindepth 1 -print -quit | grep -q .; then
    return 0
  fi
  if [ -d "$SYSTEMD_UNITS_DIR" ] && find "$SYSTEMD_UNITS_DIR" -mindepth 1 -print -quit | grep -q .; then
    return 0
  fi
  if [ -f "$MTC_DONE_FILE" ]; then
    return 0
  fi
  return 1
}

perform_backup() {
  need_bin tar
  need_bin openssl
  need_bin base64
  mkdir -p "$KEYS_DIR" "$WALLETS_DIR" "$MYTONCORE_DIR" "$TON_DB_DIR" "$BUNDLE_DIR"

  if ! backup_sources_present; then
    echo "key material not present yet; backup skipped"
    return 0
  fi

  work_dir="$(mktemp -d)"

  mkdir -p "$work_dir/stage/keys" "$work_dir/stage/mytoncore" "$work_dir/stage/tondb"
  cp -a "$KEYS_DIR/." "$work_dir/stage/keys/" 2>/dev/null || true
  cp -a "$MYTONCORE_DIR/." "$work_dir/stage/mytoncore/" 2>/dev/null || true
  if [ -f "$DB_CONFIG_FILE" ]; then
    cp -a "$DB_CONFIG_FILE" "$work_dir/stage/tondb/config.json"
  fi
  if [ -d "$DB_KEYRING_DIR" ]; then
    cp -a "$DB_KEYRING_DIR" "$work_dir/stage/tondb/keyring"
  fi
  if [ -d "$SYSTEMD_UNITS_DIR" ]; then
    cp -a "$SYSTEMD_UNITS_DIR" "$work_dir/stage/tondb/systemd-units"
  fi
  if [ -f "$MTC_DONE_FILE" ]; then
    cp -a "$MTC_DONE_FILE" "$work_dir/stage/tondb/mtc_done"
  fi
  tar -czf "$work_dir/bundle.tar.gz" -C "$work_dir/stage" .

  DATA_KEY_B64="$(openssl rand -base64 48 | tr -d '\n')"
  export DATA_KEY_B64
  wrapped_key="$(wrap_data_key "$DATA_KEY_B64")"
  if [ -z "$wrapped_key" ]; then
    echo "failed to wrap data key" >&2
    return 1
  fi

  openssl enc -aes-256-cbc -pbkdf2 -md sha256 \
    -pass env:DATA_KEY_B64 \
    -in "$work_dir/bundle.tar.gz" \
    -out "$work_dir/bundle.enc"

  {
    echo "provider=${KEY_PROVIDER}"
    echo "wrapped_key=${wrapped_key}"
    echo "algorithm=aes-256-cbc-pbkdf2"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$work_dir/bundle.meta"

  mv "$work_dir/bundle.enc" "$BUNDLE_FILE"
  mv "$work_dir/bundle.meta" "$META_FILE"
  chmod 600 "$BUNDLE_FILE" "$META_FILE" || true
  unset DATA_KEY_B64
  rm -rf "$work_dir"
  echo "encrypted key bundle updated"
}

mkdir -p "$KEYS_DIR" "$WALLETS_DIR" "$MYTONCORE_DIR" "$TON_DB_DIR" "$BUNDLE_DIR"
rm -f "$REQUEST_FILE" "$DONE_FILE" "$FAIL_FILE"
echo "manual backup mode enabled"

while true; do
  if [ -f "$REQUEST_FILE" ]; then
    rm -f "$REQUEST_FILE" "$DONE_FILE" "$FAIL_FILE"
    if perform_backup; then
      date -u +%Y-%m-%dT%H:%M:%SZ >"$DONE_FILE"
    else
      echo "backup failed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$FAIL_FILE"
    fi
  fi
  sleep 2 &
  wait $!
done
`

func requiredPodAntiAffinity(labels map[string]string, stickyNodeHostnames []string) *corev1.Affinity {
	affinity := &corev1.Affinity{
		PodAntiAffinity: &corev1.PodAntiAffinity{
			RequiredDuringSchedulingIgnoredDuringExecution: []corev1.PodAffinityTerm{
				{
					LabelSelector: &metav1.LabelSelector{
						MatchLabels: map[string]string{
							"app.kubernetes.io/instance": labels["app.kubernetes.io/instance"],
						},
					},
					TopologyKey: "kubernetes.io/hostname",
				},
			},
		},
	}
	if len(stickyNodeHostnames) > 0 {
		affinity.NodeAffinity = &corev1.NodeAffinity{
			RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
				NodeSelectorTerms: []corev1.NodeSelectorTerm{
					{
						MatchExpressions: []corev1.NodeSelectorRequirement{
							{
								Key:      "kubernetes.io/hostname",
								Operator: corev1.NodeSelectorOpIn,
								Values:   stickyNodeHostnames,
							},
						},
					},
				},
			},
		}
	}
	return affinity
}

func (r *TonNodeReconciler) desiredStickyNodeHostnames(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
	existingAffinity *corev1.Affinity,
	labels map[string]string,
) ([]string, error) {
	// Keep replica placement stable when PUBLIC_IP is auto-derived from host node IP.
	// This avoids drifting to another worker (and public IP) after a restart.
	if !hostPortsEnabled(tonNode) || strings.TrimSpace(tonNode.Spec.Network.PublicIP) != "" {
		return nil, nil
	}

	targetReplicas := int(desiredStatefulSetReplicas(tonNode))
	existing := stickyNodeHostnamesFromAffinity(existingAffinity)
	if len(existing) > 0 {
		// Allow scale-up to discover a larger stable node set.
		if targetReplicas > len(existing) {
			return nil, nil
		}
		return existing, nil
	}

	var pods corev1.PodList
	if err := r.List(ctx, &pods, client.InNamespace(tonNode.Namespace), client.MatchingLabels(labels)); err != nil {
		return nil, err
	}

	hostnames := make([]string, 0, len(pods.Items))
	for i := range pods.Items {
		pod := pods.Items[i]
		if pod.DeletionTimestamp != nil {
			continue
		}
		hostname := strings.TrimSpace(pod.Spec.NodeName)
		if hostname == "" {
			continue
		}
		hostnames = append(hostnames, hostname)
	}
	hostnames = uniqueSortedStrings(hostnames)
	if len(hostnames) == 0 {
		return nil, nil
	}
	if targetReplicas > len(hostnames) {
		return nil, nil
	}
	return hostnames, nil
}

func stickyNodeHostnamesFromAffinity(affinity *corev1.Affinity) []string {
	if affinity == nil || affinity.NodeAffinity == nil || affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		return nil
	}
	terms := affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
	for i := range terms {
		requirements := terms[i].MatchExpressions
		for j := range requirements {
			requirement := requirements[j]
			if requirement.Key != "kubernetes.io/hostname" {
				continue
			}
			if requirement.Operator != corev1.NodeSelectorOpIn {
				continue
			}
			return uniqueSortedStrings(requirement.Values)
		}
	}
	return nil
}

func uniqueSortedStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	uniq := make(map[string]struct{}, len(values))
	for _, value := range values {
		item := strings.TrimSpace(value)
		if item == "" {
			continue
		}
		uniq[item] = struct{}{}
	}
	if len(uniq) == 0 {
		return nil
	}
	out := make([]string, 0, len(uniq))
	for item := range uniq {
		out = append(out, item)
	}
	sort.Strings(out)
	return out
}

func desiredNodeSelector(tonNode *tonv1alpha1.TonNode) map[string]string {
	if len(tonNode.Spec.NodeSelector) == 0 {
		return nil
	}
	out := make(map[string]string, len(tonNode.Spec.NodeSelector))
	for key, value := range tonNode.Spec.NodeSelector {
		out[key] = value
	}
	return out
}

func (r *TonNodeReconciler) detectStorageClassName(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
) (*string, error) {
	if tonNode.Spec.Storage.StorageClassName != nil {
		name := strings.TrimSpace(*tonNode.Spec.Storage.StorageClassName)
		if name != "" {
			return &name, nil
		}
	}

	var scList storagev1.StorageClassList
	if err := r.List(ctx, &scList); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(scList.Items) == 0 {
		return nil, nil
	}

	defaultClasses := make([]string, 0)
	allClasses := make([]string, 0, len(scList.Items))
	hasLonghorn := false
	for i := range scList.Items {
		sc := scList.Items[i]
		allClasses = append(allClasses, sc.Name)
		if sc.Name == "longhorn" {
			hasLonghorn = true
		}
		if sc.Annotations["storageclass.kubernetes.io/is-default-class"] == "true" ||
			sc.Annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true" {
			defaultClasses = append(defaultClasses, sc.Name)
		}
	}

	if hasLonghorn {
		selected := "longhorn"
		return &selected, nil
	}
	if len(defaultClasses) > 0 {
		sort.Strings(defaultClasses)
		selected := defaultClasses[0]
		return &selected, nil
	}

	// Some clusters define classes but do not mark one as default.
	// Use a stable fallback to avoid unresolved PVCs in that setup.
	sort.Strings(allClasses)
	selected := allClasses[0]
	return &selected, nil
}

func (r *TonNodeReconciler) updateStatus(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
	readyReplicas int32,
	serviceName string,
	isReady bool,
	reason string,
	message string,
) error {
	originalStatus := tonNode.Status
	tonNode.Status.ObservedGeneration = tonNode.Generation
	tonNode.Status.ReadyReplicas = readyReplicas
	tonNode.Status.ServiceName = serviceName

	conditionStatus := metav1.ConditionFalse
	if isReady {
		conditionStatus = metav1.ConditionTrue
	}
	meta.SetStatusCondition(&tonNode.Status.Conditions, metav1.Condition{
		Type:               readyConditionType,
		Status:             conditionStatus,
		ObservedGeneration: tonNode.Generation,
		Reason:             reason,
		Message:            message,
	})

	if reflect.DeepEqual(originalStatus, tonNode.Status) {
		return nil
	}
	return r.Status().Update(ctx, tonNode)
}

func hostIPPublicEnvVar() corev1.EnvVar {
	return corev1.EnvVar{
		Name: "PUBLIC_IP",
		ValueFrom: &corev1.EnvVarSource{
			FieldRef: &corev1.ObjectFieldSelector{
				FieldPath: "status.hostIP",
			},
		},
	}
}

func (r *TonNodeReconciler) desiredPublicIPEnv(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
) (corev1.EnvVar, error) {
	if ip := strings.TrimSpace(tonNode.Spec.Network.PublicIP); ip != "" {
		return corev1.EnvVar{Name: "PUBLIC_IP", Value: ip}, nil
	}

	// We can safely resolve a single external IP automatically only for one replica.
	if desiredReplicas(tonNode) == 1 {
		ip, err := r.resolveNodeExternalIP(ctx, tonNode)
		if err != nil {
			return corev1.EnvVar{}, err
		}
		if ip != "" {
			return corev1.EnvVar{Name: "PUBLIC_IP", Value: ip}, nil
		}
	}

	return hostIPPublicEnvVar(), nil
}

func (r *TonNodeReconciler) resolveNodeExternalIP(
	ctx context.Context,
	tonNode *tonv1alpha1.TonNode,
) (string, error) {
	pod := &corev1.Pod{}
	podName := fmt.Sprintf("%s-0", tonNode.Name)
	if err := r.Get(ctx, client.ObjectKey{Name: podName, Namespace: tonNode.Namespace}, pod); err != nil {
		if apierrors.IsNotFound(err) {
			return "", nil
		}
		return "", err
	}

	nodeName := strings.TrimSpace(pod.Spec.NodeName)
	if nodeName == "" {
		return "", nil
	}

	node := &corev1.Node{}
	if err := r.Get(ctx, client.ObjectKey{Name: nodeName}, node); err != nil {
		if apierrors.IsNotFound(err) {
			return "", nil
		}
		return "", err
	}

	return nodeAddressByType(node.Status.Addresses, corev1.NodeExternalIP), nil
}

func nodeAddressByType(addresses []corev1.NodeAddress, addressType corev1.NodeAddressType) string {
	for _, address := range addresses {
		if address.Type != addressType {
			continue
		}
		ip := strings.TrimSpace(address.Address)
		if ip != "" {
			return ip
		}
	}
	return ""
}

func hostPortsEnabled(tonNode *tonv1alpha1.TonNode) bool {
	if tonNode.Spec.Network.HostPortsEnabled == nil {
		return true
	}
	return *tonNode.Spec.Network.HostPortsEnabled
}

func defaultTonEnv(tonNode *tonv1alpha1.TonNode, publicIP corev1.EnvVar) []corev1.EnvVar {
	return []corev1.EnvVar{
		publicIP,
		{Name: "GLOBAL_CONFIG_URL", Value: desiredGlobalConfigURL(tonNode)},
		{Name: "VALIDATOR_PORT", Value: strconv.Itoa(int(desiredValidatorPort(tonNode)))},
		{Name: "LITESERVER_PORT", Value: strconv.Itoa(int(desiredLiteServerPort(tonNode)))},
		{Name: "VALIDATOR_CONSOLE_PORT", Value: strconv.Itoa(int(desiredConsolePort(tonNode)))},
		// Default to true for local/dev clusters; override through spec.env for prod.
		{Name: "IGNORE_MINIMAL_REQS", Value: "true"},
	}
}

func mergeEnvVars(base []corev1.EnvVar, extra []corev1.EnvVar) []corev1.EnvVar {
	if len(extra) == 0 {
		return base
	}
	merged := make([]corev1.EnvVar, 0, len(base)+len(extra))
	positions := make(map[string]int, len(base)+len(extra))
	for _, item := range base {
		positions[item.Name] = len(merged)
		merged = append(merged, item)
	}
	for _, item := range extra {
		if idx, ok := positions[item.Name]; ok {
			merged[idx] = item
			continue
		}
		positions[item.Name] = len(merged)
		merged = append(merged, item)
	}
	return merged
}

func labelsForTonNode(tonNode *tonv1alpha1.TonNode) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":       "ton-node",
		"app.kubernetes.io/component":  "node",
		"app.kubernetes.io/managed-by": "ton-k8s-operator",
		"app.kubernetes.io/instance":   tonNode.Name,
	}
}

func desiredImage(tonNode *tonv1alpha1.TonNode) string {
	if image := strings.TrimSpace(tonNode.Spec.Image); image != "" {
		return image
	}
	return defaultImage
}

func desiredImagePullPolicy(tonNode *tonv1alpha1.TonNode) corev1.PullPolicy {
	if imagePinnedByDigest(desiredImage(tonNode)) {
		return corev1.PullIfNotPresent
	}
	return corev1.PullAlways
}

func imagePinnedByDigest(image string) bool {
	image = strings.TrimSpace(image)
	if image == "" {
		return false
	}
	return strings.Contains(image, "@")
}

func desiredResources(tonNode *tonv1alpha1.TonNode) corev1.ResourceRequirements {
	desired := corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(defaultCPURequest),
			corev1.ResourceMemory: resource.MustParse(defaultMemoryRequest),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(defaultCPULimit),
			corev1.ResourceMemory: resource.MustParse(defaultMemoryLimit),
		},
	}

	for name, quantity := range tonNode.Spec.Resources.Requests {
		desired.Requests[name] = quantity
	}
	for name, quantity := range tonNode.Spec.Resources.Limits {
		desired.Limits[name] = quantity
	}

	if len(tonNode.Spec.Resources.Claims) > 0 {
		desired.Claims = make([]corev1.ResourceClaim, len(tonNode.Spec.Resources.Claims))
		copy(desired.Claims, tonNode.Spec.Resources.Claims)
	}

	return desired
}

func desiredReplicas(tonNode *tonv1alpha1.TonNode) int32 {
	if tonNode.Spec.Replicas == nil || *tonNode.Spec.Replicas < 1 {
		return defaultReplicas
	}
	return *tonNode.Spec.Replicas
}

func desiredStatefulSetReplicas(tonNode *tonv1alpha1.TonNode) int32 {
	_, pauseRequested := pausedReplicasAnnotation(tonNode)
	if pauseRequested {
		return 0
	}
	return desiredReplicas(tonNode)
}

func pausedReplicasAnnotation(tonNode *tonv1alpha1.TonNode) (int32, bool) {
	if tonNode == nil || len(tonNode.Annotations) == 0 {
		return 0, false
	}
	raw := strings.TrimSpace(tonNode.Annotations[kubetonPauseReplicasAnnotationKey])
	if raw == "" {
		return 0, false
	}
	parsed, err := strconv.ParseInt(raw, 10, 32)
	if err != nil || parsed < 0 {
		return 0, false
	}
	return int32(parsed), true
}

func desiredGlobalConfigURL(tonNode *tonv1alpha1.TonNode) string {
	if url := strings.TrimSpace(tonNode.Spec.Network.GlobalConfigURL); url != "" {
		return url
	}
	return defaultGlobalConfigURL
}

func desiredValidatorPort(tonNode *tonv1alpha1.TonNode) int32 {
	if tonNode.Spec.Network.ValidatorPort > 0 {
		return tonNode.Spec.Network.ValidatorPort
	}
	return defaultValidatorPort
}

func desiredLiteServerPort(tonNode *tonv1alpha1.TonNode) int32 {
	if tonNode.Spec.Network.LiteServerPort > 0 {
		return tonNode.Spec.Network.LiteServerPort
	}
	return defaultLiteServerPort
}

func desiredQuicPort(tonNode *tonv1alpha1.TonNode) int32 {
	if tonNode.Spec.Network.QuicPort > 0 {
		return tonNode.Spec.Network.QuicPort
	}
	return defaultQuicPort
}

func desiredConsolePort(tonNode *tonv1alpha1.TonNode) int32 {
	if tonNode.Spec.Network.ValidatorConsolePort > 0 {
		return tonNode.Spec.Network.ValidatorConsolePort
	}
	return defaultConsolePort
}

func parseQuantityOrDefault(raw string, fallback string) resource.Quantity {
	value := strings.TrimSpace(raw)
	if value == "" {
		value = fallback
	}
	qty, err := resource.ParseQuantity(value)
	if err != nil {
		return resource.MustParse(fallback)
	}
	return qty
}
