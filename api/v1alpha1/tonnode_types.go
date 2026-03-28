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

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// TonNodeSpec defines the desired state of TonNode.
type TonNodeSpec struct {
	// Image is the TON node container image.
	// +kubebuilder:default:="ghcr.io/ton-blockchain/ton-docker-ctrl:latest"
	Image string `json:"image,omitempty"`

	// Replicas is the desired number of TON nodes.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:default:=1
	Replicas *int32 `json:"replicas,omitempty"`

	// Storage defines PVC settings for TON data and MyTonCtrl state.
	Storage TonNodeStorageSpec `json:"storage,omitempty"`

	// Resources defines CPU and memory requests/limits for the TON container.
	// +optional
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`

	// Network defines TON networking parameters passed via environment variables.
	Network TonNodeNetworkSpec `json:"network,omitempty"`

	// ConfigRef optionally points to a Secret containing a config.json key.
	// When specified, the Secret is copied into /var/ton-work/db/config.json
	// on first startup if the file does not already exist.
	// +optional
	ConfigRef *corev1.LocalObjectReference `json:"configRef,omitempty"`

	// Env allows passing extra environment variables to the TON container.
	// +optional
	Env []corev1.EnvVar `json:"env,omitempty"`

	// KeyManagement enables secure key handling with in-memory keys and encrypted bundles.
	// +optional
	KeyManagement *TonNodeKeyManagementSpec `json:"keyManagement,omitempty"`
}

// TonNodeStorageSpec defines persistent storage settings.
type TonNodeStorageSpec struct {
	// TonWorkSize is the PVC size for /var/ton-work.
	// +kubebuilder:default:="200Gi"
	TonWorkSize string `json:"tonWorkSize,omitempty"`

	// MyTonCoreSize is the PVC size for /usr/local/bin/mytoncore.
	// +kubebuilder:default:="20Gi"
	MyTonCoreSize string `json:"myTonCoreSize,omitempty"`

	// StorageClassName explicitly selects the StorageClass.
	// If not set, the operator prefers Longhorn, then default StorageClass.
	// +optional
	StorageClassName *string `json:"storageClassName,omitempty"`

	// AccessModes configures PVC access modes.
	// Defaults to ReadWriteOnce when omitted.
	// +optional
	AccessModes []corev1.PersistentVolumeAccessMode `json:"accessModes,omitempty"`
}

// TonNodeNetworkSpec defines TON network-related settings.
type TonNodeNetworkSpec struct {
	// GlobalConfigURL is the TON global config URL.
	// +kubebuilder:default:="https://ton.org/global.config.json"
	GlobalConfigURL string `json:"globalConfigURL,omitempty"`

	// ValidatorPort is the validator UDP port.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default:=30001
	ValidatorPort int32 `json:"validatorPort,omitempty"`

	// LiteServerPort is the lite-server TCP port.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default:=30003
	LiteServerPort int32 `json:"liteServerPort,omitempty"`

	// ValidatorConsolePort is the validator console TCP port.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default:=30002
	ValidatorConsolePort int32 `json:"validatorConsolePort,omitempty"`

	// PublicIP explicitly sets PUBLIC_IP for TON.
	// If omitted and replicas=1, operator prefers the scheduled node ExternalIP.
	// If not available, it falls back to the Pod's host IP.
	// +optional
	PublicIP string `json:"publicIP,omitempty"`

	// HostPortsEnabled exposes validator/lite-server ports via hostPort on the node.
	// Enabled by default for external TON reachability.
	// +kubebuilder:default:=true
	// +optional
	HostPortsEnabled *bool `json:"hostPortsEnabled,omitempty"`
}

// TonNodeKeyManagementSpec defines key protection workflow.
type TonNodeKeyManagementSpec struct {
	// Enabled toggles secure key handling.
	// +kubebuilder:default:=false
	Enabled bool `json:"enabled,omitempty"`

	// Provider selects the root-of-trust system used to wrap data keys.
	// +kubebuilder:validation:Enum=vault;kms
	// +kubebuilder:default:="vault"
	Provider string `json:"provider,omitempty"`

	// CredentialsSecretRef points to credentials/config required by the selected provider.
	// +optional
	CredentialsSecretRef *corev1.LocalObjectReference `json:"credentialsSecretRef,omitempty"`

	// VaultTransitKey is required when provider=vault.
	// +optional
	VaultTransitKey string `json:"vaultTransitKey,omitempty"`

	// KMSKeyID is required when provider=kms.
	// +optional
	KMSKeyID string `json:"kmsKeyID,omitempty"`

	// KMSVendor selects the KMS CLI flow used by the key agent when provider=kms.
	// +kubebuilder:validation:Enum=aws;gcp
	// +optional
	KMSVendor string `json:"kmsVendor,omitempty"`

	// InMemory configures tmpfs mounts for live key files.
	// +optional
	InMemory TonNodeInMemoryKeySpec `json:"inMemory,omitempty"`

	// EncryptedBundle configures where encrypted key bundles are stored at rest.
	// +optional
	EncryptedBundle TonNodeEncryptedBundleSpec `json:"encryptedBundle,omitempty"`

	// Agent configures helper containers that restore and backup encrypted bundles.
	// +optional
	Agent TonNodeKeyAgentSpec `json:"agent,omitempty"`
}

// TonNodeInMemoryKeySpec defines tmpfs sizing for live key directories.
type TonNodeInMemoryKeySpec struct {
	// KeysSizeLimit is the tmpfs size limit for /var/ton-work/keys.
	// +kubebuilder:default:="128Mi"
	KeysSizeLimit string `json:"keysSizeLimit,omitempty"`

	// WalletsSizeLimit is the tmpfs size limit for /usr/local/bin/mytoncore/wallets.
	// +kubebuilder:default:="512Mi"
	WalletsSizeLimit string `json:"walletsSizeLimit,omitempty"`
}

// TonNodeEncryptedBundleSpec defines encrypted key bundle persistence settings.
type TonNodeEncryptedBundleSpec struct {
	// PVCSize is the PVC size used for encrypted key bundles.
	// +kubebuilder:default:="5Gi"
	PVCSize string `json:"pvcSize,omitempty"`

	// StorageClassName explicitly selects the StorageClass for encrypted bundles.
	// +optional
	StorageClassName *string `json:"storageClassName,omitempty"`

	// AccessModes configures PVC access modes for encrypted bundles.
	// Defaults to ReadWriteOnce when omitted.
	// +optional
	AccessModes []corev1.PersistentVolumeAccessMode `json:"accessModes,omitempty"`

	// FileName is the encrypted bundle filename.
	// +kubebuilder:default:="keys.bundle.enc"
	FileName string `json:"fileName,omitempty"`

	// MetaFileName stores wrapped key metadata for bundle decryption.
	// +kubebuilder:default:="keys.bundle.meta"
	MetaFileName string `json:"metaFileName,omitempty"`
}

// TonNodeKeyAgentSpec defines helper container settings for key restore/backup.
type TonNodeKeyAgentSpec struct {
	// Image is the init/sidecar image used for key management scripts.
	// +kubebuilder:default:="ghcr.io/ton-blockchain/ton-docker-ctrl:latest"
	Image string `json:"image,omitempty"`

	// Resources defines CPU and memory requests/limits for key helper containers.
	// +optional
	Resources corev1.ResourceRequirements `json:"resources,omitempty"`
}

// TonNodeStatus defines the observed state of TonNode.
type TonNodeStatus struct {
	// ObservedGeneration is the most recent reconciled generation.
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// ReadyReplicas is the number of ready TON Pods.
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// ServiceName is the name of the headless Service.
	ServiceName string `json:"serviceName,omitempty"`

	// Conditions describes the reconciliation status.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=".status.readyReplicas"
// +kubebuilder:printcolumn:name="Service",type=string,JSONPath=".status.serviceName"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"

// TonNode is the Schema for the tonnodes API.
type TonNode struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   TonNodeSpec   `json:"spec,omitempty"`
	Status TonNodeStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// TonNodeList contains a list of TonNode.
type TonNodeList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []TonNode `json:"items"`
}

func init() {
	SchemeBuilder.Register(&TonNode{}, &TonNodeList{})
}
