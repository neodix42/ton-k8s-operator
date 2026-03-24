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
