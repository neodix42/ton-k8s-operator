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
	defaultImage                 = "ghcr.io/ton-blockchain/ton-docker-ctrl:latest"
	defaultReplicas        int32 = 1
	defaultTonWorkSize           = "200Gi"
	defaultMyTonCoreSize         = "20Gi"
	defaultCPURequest            = "16000m"
	defaultMemoryRequest         = "64Gi"
	defaultCPULimit              = "128000m"
	defaultMemoryLimit           = "256Gi"
	defaultGlobalConfigURL       = "https://ton.org/global.config.json"
	defaultValidatorPort   int32 = 30001
	defaultLiteServerPort  int32 = 30003
	defaultConsolePort     int32 = 30002

	tonContainerName = "ton-node"
	tonWorkClaimName = "ton-work"
	myTonCoreClaim   = "mytoncore"

	headlessServiceSuffix    = "headless"
	bootstrapConfigVolume    = "bootstrap-config"
	bootstrapConfigMountPath = "/bootstrap"
	configSecretKey          = "config.json"

	readyConditionType = "Ready"
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
// +kubebuilder:rbac:groups="",resources=pods,verbs=get
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
	if tonNode.Spec.ConfigRef != nil && replicas > 1 {
		message := "spec.configRef supports replicas=1 only to avoid sharing a single config.json across replicas"
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

	isReady := sts.Status.ReadyReplicas >= replicas
	reason := "Reconciling"
	message := fmt.Sprintf("ready replicas %d/%d", sts.Status.ReadyReplicas, replicas)
	if isReady {
		reason = "Ready"
		message = "all TON replicas are ready"
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
		replicas := desiredReplicas(tonNode)
		publicIP, err := r.desiredPublicIPEnv(ctx, tonNode)
		if err != nil {
			return err
		}
		sts.Labels = labels
		sts.Spec.Replicas = ptr.To(replicas)
		sts.Spec.ServiceName = serviceName
		sts.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		sts.Spec.PodManagementPolicy = appsv1.ParallelPodManagement
		sts.Spec.UpdateStrategy = appsv1.StatefulSetUpdateStrategy{Type: appsv1.RollingUpdateStatefulSetStrategyType}
		sts.Spec.Template = r.desiredPodTemplate(tonNode, labels, publicIP)
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
) corev1.PodTemplateSpec {
	env := mergeEnvVars(defaultTonEnv(tonNode, publicIP), tonNode.Spec.Env)
	containerPorts := []corev1.ContainerPort{
		{
			Name:          "validator-udp",
			ContainerPort: desiredValidatorPort(tonNode),
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

	container := corev1.Container{
		Name:            tonContainerName,
		Image:           desiredImage(tonNode),
		ImagePullPolicy: corev1.PullIfNotPresent,
		Env:             env,
		Resources:       desiredResources(tonNode),
		Ports:           containerPorts,
		VolumeMounts: []corev1.VolumeMount{
			{Name: tonWorkClaimName, MountPath: "/var/ton-work"},
			{Name: myTonCoreClaim, MountPath: "/usr/local/bin/mytoncore"},
		},
	}

	podSpec := corev1.PodSpec{
		Affinity:   requiredPodAntiAffinity(labels),
		Containers: []corev1.Container{container},
	}

	if tonNode.Spec.ConfigRef != nil {
		podSpec.InitContainers = []corev1.Container{
			{
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
			},
		}
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
	accessModes := tonNode.Spec.Storage.AccessModes
	if len(accessModes) == 0 {
		accessModes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
	}

	tonWorkSize := parseQuantityOrDefault(tonNode.Spec.Storage.TonWorkSize, defaultTonWorkSize)
	myTonCoreSize := parseQuantityOrDefault(tonNode.Spec.Storage.MyTonCoreSize, defaultMyTonCoreSize)

	return []corev1.PersistentVolumeClaim{
		{
			ObjectMeta: metav1.ObjectMeta{Name: tonWorkClaimName},
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
			ObjectMeta: metav1.ObjectMeta{Name: myTonCoreClaim},
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
}

func requiredPodAntiAffinity(labels map[string]string) *corev1.Affinity {
	return &corev1.Affinity{
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
