package controller

import (
	"context"
	"fmt"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestScaleUpPreservesExistingValidators(t *testing.T) {
	const prerequisiteReady = "ready"
	scheme := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{corev1.AddToScheme, appsv1.AddToScheme, tonv1alpha1.AddToScheme} {
		if err := add(scheme); err != nil {
			t.Fatal(err)
		}
	}
	tonNode := &tonv1alpha1.TonNode{
		ObjectMeta: metav1.ObjectMeta{Name: "tonnode", Namespace: "default", UID: "tonnode-uid"},
		Spec: tonv1alpha1.TonNodeSpec{
			Replicas: ptr.To[int32](5), Image: "controller:old",
			NodeSelector: map[string]string{"ton.ton.org/kubeton-prereq": prerequisiteReady},
		},
	}
	objects := []client.Object{tonNode}
	for index := 0; index < 6; index++ {
		name := fmt.Sprintf("worker-%d", index)
		labels := map[string]string{corev1.LabelHostname: name}
		if index < 5 {
			labels["ton.ton.org/kubeton-prereq"] = prerequisiteReady
		}
		objects = append(objects, &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
			Status:     corev1.NodeStatus{Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}},
		})
	}
	reconciler := &TonNodeReconciler{Client: fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).Build(), Scheme: scheme}
	ctx := context.Background()
	reconcile := func() *appsv1.StatefulSet {
		t.Helper()
		sts, err := reconciler.reconcileStatefulSet(ctx, tonNode, "tonnode-headless", nil)
		if err != nil {
			t.Fatal(err)
		}
		return sts
	}
	initial := reconcile()
	if initial.Annotations[stickyPlacementSpecHashAnnotationKey] == "" {
		t.Fatal("missing safe-placement capability annotation")
	}
	for index := 0; index < 5; index++ {
		pod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: fmt.Sprintf("tonnode-%d", index), Namespace: "default", UID: types.UID(fmt.Sprintf("original-%d", index)), Labels: labelsForTonNode(tonNode)},
			Spec:       corev1.PodSpec{NodeName: fmt.Sprintf("worker-%d", index)},
		}
		if err := reconciler.Create(ctx, pod); err != nil {
			t.Fatal(err)
		}
	}
	tonNode.Spec.Replicas = ptr.To[int32](6)
	constrained := reconcile()
	if hosts := stickyNodeHostnamesFromAffinity(constrained.Spec.Template.Spec.Affinity); len(hosts) != 5 {
		t.Fatalf("unapproved sixth node bypassed the explicit selector: %v", hosts)
	}
	node := &corev1.Node{}
	if err := reconciler.Get(ctx, client.ObjectKey{Name: "worker-5"}, node); err != nil {
		t.Fatal(err)
	}
	node.Labels["ton.ton.org/kubeton-prereq"] = prerequisiteReady
	if err := reconciler.Update(ctx, node); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		grown := reconcile()
		if grown.Spec.UpdateStrategy.Type != appsv1.OnDeleteStatefulSetStrategyType {
			t.Fatalf("reconcile %d would roll existing validators after placement growth", attempt)
		}
		if hosts := stickyNodeHostnamesFromAffinity(grown.Spec.Template.Spec.Affinity); len(hosts) != 6 {
			t.Fatalf("expected six allowed hosts, got %v", hosts)
		}
	}
	for index := 0; index < 5; index++ {
		pod := &corev1.Pod{}
		if err := reconciler.Get(ctx, client.ObjectKey{Namespace: "default", Name: fmt.Sprintf("tonnode-%d", index)}, pod); err != nil {
			t.Fatal(err)
		}
		if string(pod.UID) != fmt.Sprintf("original-%d", index) {
			t.Fatal("existing validator identity changed")
		}
	}
	// The first reconcile after upgrading an older operator must also protect
	// an already-Pending scale-up, including API-defaulted Pod fields.
	legacy := &appsv1.StatefulSet{}
	if err := reconciler.Get(ctx, client.ObjectKey{Namespace: "default", Name: "tonnode"}, legacy); err != nil {
		t.Fatal(err)
	}
	delete(legacy.Annotations, stickyPlacementSpecHashAnnotationKey)
	legacy.Spec.UpdateStrategy.Type = appsv1.RollingUpdateStatefulSetStrategyType
	legacy.Spec.Template.Spec.DNSPolicy = corev1.DNSClusterFirst
	legacy.Spec.Template.Spec.Affinity = requiredPodAntiAffinity(labelsForTonNode(tonNode), []string{"worker-0", "worker-1", "worker-2", "worker-3", "worker-4"})
	if err := reconciler.Update(ctx, legacy); err != nil {
		t.Fatal(err)
	}
	if migrated := reconcile(); migrated.Spec.UpdateStrategy.Type != appsv1.OnDeleteStatefulSetStrategyType {
		t.Fatal("operator upgrade would roll existing validators while fixing Pending placement")
	}
	tonNode.Spec.Image = "controller:new"
	upgraded := reconcile()
	if upgraded.Spec.UpdateStrategy.Type != appsv1.RollingUpdateStatefulSetStrategyType {
		t.Fatal("intentional image change did not restore rolling updates")
	}
	if upgraded.Spec.Template.Spec.Containers[0].Image != "controller:new" {
		t.Fatal("image change was lost")
	}
}
