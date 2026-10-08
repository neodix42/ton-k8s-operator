package controller

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
)

func TestRuntimePodStagesOfficialTonArtifacts(t *testing.T) {
	node := &tonv1alpha1.TonNode{
		Spec: tonv1alpha1.TonNodeSpec{
			Image:    "ghcr.io/example/mytonctrl:release",
			TonImage: "ghcr.io/ton-blockchain/ton:release",
		},
	}
	pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
	wantOrder := []string{persistentLayoutInitName, tonExporterInitName, tonBinariesInitName}
	if len(pod.InitContainers) != len(wantOrder) {
		t.Fatalf("init containers = %d, want %d", len(pod.InitContainers), len(wantOrder))
	}
	for i, name := range wantOrder {
		if pod.InitContainers[i].Name != name {
			t.Fatalf("init container %d = %q, want %q", i, pod.InitContainers[i].Name, name)
		}
	}
	stage := pod.InitContainers[1]
	export := pod.InitContainers[2]
	main := pod.Containers[0]
	if stage.Image != node.Spec.Image || main.Image != node.Spec.Image {
		t.Fatalf("controller image is not shared by helper and application: helper=%q main=%q", stage.Image, main.Image)
	}
	if export.Image != node.Spec.TonImage {
		t.Fatalf("binary provider image = %q, want %q", export.Image, node.Spec.TonImage)
	}
	if !reflect.DeepEqual(export.Command, []string{"/bin/sh", "/scripts/export-ton.sh"}) {
		t.Fatalf("official TON entrypoint must be bypassed: command=%v", export.Command)
	}
	if got := envVarValueByName(export.Env, "TON_IMAGE_REF"); got != node.Spec.TonImage {
		t.Fatalf("export metadata image = %q, want %q", got, node.Spec.TonImage)
	}
	for _, check := range []struct {
		container corev1.Container
		volume    string
		path      string
		readOnly  bool
	}{
		{stage, tonExporterVolume, "/scripts", false},
		{export, tonExporterVolume, "/scripts", true},
		{export, tonArtifactsVolume, "/ton-artifacts", false},
		{main, tonArtifactsVolume, "/ton-artifacts", true},
	} {
		mount := runtimeMountByName(t, check.container, check.volume)
		if mount.MountPath != check.path || mount.ReadOnly != check.readOnly {
			t.Errorf("%s %s mount = %+v, want path %q readOnly=%t", check.container.Name, check.volume, mount, check.path, check.readOnly)
		}
	}
	for _, name := range []string{tonExporterVolume, tonArtifactsVolume} {
		found := false
		for _, volume := range pod.Volumes {
			if volume.Name == name {
				found = true
				if volume.EmptyDir == nil || volume.PersistentVolumeClaim != nil {
					t.Errorf("%s must use ephemeral artifacts, got %+v", name, volume.VolumeSource)
				}
			}
		}
		if !found {
			t.Errorf("shared volume %s missing", name)
		}
	}
	if len(main.Command) != 0 || len(main.Args) != 0 {
		t.Fatalf("empty installation args should preserve MyTonCtrl image entrypoint/CMD: command=%v args=%v", main.Command, main.Args)
	}
	for _, mount := range main.VolumeMounts {
		switch mount.MountPath {
		case "/usr/src/ton", "/usr/local/bin/mytoncore", "/usr/local/bin/mytonctrl":
			t.Errorf("mount %s hides a path created by the MyTonCtrl entrypoint", mount.MountPath)
		}
	}
	if pod.TerminationGracePeriodSeconds == nil || *pod.TerminationGracePeriodSeconds != 75 {
		t.Errorf("termination grace = %v, want 75 seconds for upstream supervisor shutdown", pod.TerminationGracePeriodSeconds)
	}
}

func TestRuntimeImageDefaultsAndIndependentPullPolicies(t *testing.T) {
	digest := "@sha256:" + strings.Repeat("a", 64)
	for _, tt := range []struct {
		name             string
		image            string
		tonImage         string
		wantImage        string
		wantTonImage     string
		controllerPolicy corev1.PullPolicy
		tonPolicy        corev1.PullPolicy
	}{
		{
			name: "published defaults", wantImage: "ghcr.io/neodix42/mytonctrl:v1.0.0",
			wantTonImage:     "ghcr.io/ton-blockchain/ton:v2026.08-amd64",
			controllerPolicy: corev1.PullAlways, tonPolicy: corev1.PullAlways,
		},
		{
			name: "only TON pinned", tonImage: " ghcr.io/ton-blockchain/ton" + digest + " ",
			wantImage: "ghcr.io/neodix42/mytonctrl:v1.0.0", wantTonImage: "ghcr.io/ton-blockchain/ton" + digest,
			controllerPolicy: corev1.PullAlways, tonPolicy: corev1.PullIfNotPresent,
		},
		{
			name: "only controller pinned", image: "ghcr.io/custom/mytonctrl" + digest,
			wantImage: "ghcr.io/custom/mytonctrl" + digest, wantTonImage: "ghcr.io/ton-blockchain/ton:v2026.08-amd64",
			controllerPolicy: corev1.PullIfNotPresent, tonPolicy: corev1.PullAlways,
		},
		{
			name: "both overridden", image: "ghcr.io/custom/mytonctrl:testing", tonImage: "ghcr.io/custom/ton:testing",
			wantImage: "ghcr.io/custom/mytonctrl:testing", wantTonImage: "ghcr.io/custom/ton:testing",
			controllerPolicy: corev1.PullAlways, tonPolicy: corev1.PullAlways,
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{Image: tt.image, TonImage: tt.tonImage}}
			pod := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec
			main := pod.Containers[0]
			export := pod.InitContainers[2]
			if main.Image != tt.wantImage || export.Image != tt.wantTonImage {
				t.Fatalf("images = (%q, %q), want (%q, %q)", main.Image, export.Image, tt.wantImage, tt.wantTonImage)
			}
			if main.ImagePullPolicy != tt.controllerPolicy || export.ImagePullPolicy != tt.tonPolicy {
				t.Fatalf("pull policies = (%q, %q), want (%q, %q)", main.ImagePullPolicy, export.ImagePullPolicy, tt.controllerPolicy, tt.tonPolicy)
			}
			if pod.InitContainers[1].ImagePullPolicy != main.ImagePullPolicy {
				t.Errorf("export-script helper must follow controller image pull policy")
			}
		})
	}
}

func TestRuntimeInstallationArgsRemainLiteral(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "shell-injection")
	flags := []string{"-m", "liteserver", "-n", "testnet", "-c", "/config/with spaces.json", "$(touch " + marker + "); touch " + marker}
	for _, debug := range []bool{false, true} {
		t.Run(map[bool]string{false: "normal entrypoint", true: "hold-on-failure wrapper"}[debug], func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{
				Args: flags, Debug: tonv1alpha1.TonNodeDebugSpec{HoldOnFailure: debug},
			}}
			main := (&TonNodeReconciler{}).desiredPodTemplate(node, nil, corev1.EnvVar{}, nil).Spec.Containers[0]
			want := append([]string{"run"}, flags...)
			if !debug {
				if len(main.Command) != 0 || !reflect.DeepEqual(main.Args, want) {
					t.Fatalf("native argv = %v command=%v, want %v", main.Args, main.Command, want)
				}
				return
			}
			if !reflect.DeepEqual(main.Command, []string{"bash", "-c"}) || len(main.Args) < 3 {
				t.Fatalf("debug shell wrapper shape = command %v args %v", main.Command, main.Args)
			}
			if !reflect.DeepEqual(main.Args[2:], want) {
				t.Fatalf("debug positional argv = %v, want %v", main.Args[2:], want)
			}
			// Replace only the fixed upstream executable with an argv recorder.
			// Execute the actual generated shell wrapper to catch quoting mistakes.
			script := strings.Replace(main.Args[0],
				"/opt/mytonctrl/venv/bin/python /usr/local/lib/mytonctrl/entrypoint.py",
				"printf '%s\\000'", 1)
			command := exec.Command(main.Command[0], main.Command[1], script, main.Args[1])
			command.Args = append(command.Args, main.Args[2:]...)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("debug argv recorder: %v\n%s", err, output)
			}
			got := strings.Split(strings.TrimSuffix(string(output), "\x00"), "\x00")
			if !reflect.DeepEqual(got, want) {
				t.Errorf("shell changed installation values: got %q want %q", got, want)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Errorf("installation argument executed shell code: %v", err)
			}
		})
	}
}

func TestRuntimeReadinessRequiresCommittedBootstrapAndServices(t *testing.T) {
	required := []string{
		"controller/initialized.json", "controller/mytoncore/mytoncore.db", "db/config.json",
		"controller/services/validator.service", "controller/services/mytoncore.service",
	}
	for _, missing := range append([]string{"", "inactive-services"}, required...) {
		name := missing
		if name == "" {
			name = "ready"
		}
		t.Run(name, func(t *testing.T) {
			work := t.TempDir()
			for _, path := range required {
				if path != missing {
					writeRuntimeFixture(t, filepath.Join(work, path), "{}")
				}
			}
			bin := t.TempDir()
			systemctl := filepath.Join(bin, "systemctl")
			writeRuntimeFixture(t, systemctl, "#!/bin/sh\n"+
				"test \"$#\" -eq 4 && test \"$1\" = is-active && test \"$2\" = --quiet && "+
				"test \"$3\" = validator && test \"$4\" = mytoncore && test -f \"$RUNTIME_TEST_ACTIVE\"\n")
			if err := os.Chmod(systemctl, 0o755); err != nil {
				t.Fatal(err)
			}
			active := filepath.Join(work, "services-active")
			if missing != "inactive-services" {
				writeRuntimeFixture(t, active, "active")
			}
			probe := desiredRuntimeReadinessProbe()
			if probe.Exec == nil || len(probe.Exec.Command) != 3 {
				t.Fatalf("readiness exec missing: %+v", probe)
			}
			script := strings.ReplaceAll(probe.Exec.Command[2], "/var/ton-work", work)
			command := exec.Command(probe.Exec.Command[0], probe.Exec.Command[1], script)
			command.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "RUNTIME_TEST_ACTIVE="+active)
			output, err := command.CombinedOutput()
			if (err == nil) != (missing == "") {
				t.Fatalf("readiness result err=%v, missing=%q\n%s", err, missing, output)
			}
		})
	}
}

func TestRuntimeRejectsLegacySourceSelection(t *testing.T) {
	for _, name := range []string{"AUTHOR", "REPO", "BRANCH", "NODE_REPO", "NODE_VERSION", "MYTONCTRL_VERSION", "TON_BRANCH"} {
		for _, dynamic := range []bool{false, true} {
			t.Run(name+map[bool]string{false: "/literal", true: "/secret"}[dynamic], func(t *testing.T) {
				env := corev1.EnvVar{Name: name, Value: "master"}
				if dynamic {
					env.Value = ""
					env.ValueFrom = &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{Name: "runtime"}, Key: name,
					}}
				}
				node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{Env: []corev1.EnvVar{env}}}
				if message := validateRuntimeSpec(node); !strings.Contains(message, name) || !strings.Contains(message, "image") {
					t.Fatalf("source selection rejection = %q", message)
				}
			})
		}
	}
	node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{Env: []corev1.EnvVar{{Name: "MYTONCTRL_VERSION", Value: ""}}}}
	if message := validateRuntimeSpec(node); message != "" {
		t.Errorf("empty legacy source setting is allowed by upstream, got %q", message)
	}
}

func TestRuntimePreservesOperatorWorkDirectory(t *testing.T) {
	for _, tt := range []struct {
		name string
		env  []corev1.EnvVar
		args []string
		fail bool
	}{
		{name: "default paths"},
		{name: "explicit fixed env", env: []corev1.EnvVar{{Name: "TON_WORK_DIR", Value: "/var/ton-work"}}},
		{name: "explicit fixed short flag", args: []string{"-W", "/var/ton-work"}},
		{name: "explicit fixed attached short flag", args: []string{"-W/var/ton-work"}},
		{name: "explicit fixed long flag", args: []string{"--ton-work-dir=/var/ton-work"}},
		{name: "ordinary environment arguments", env: []corev1.EnvVar{{Name: "MYTONCTRL_ARGS", Value: "-m liteserver -n testnet -d -i"}}},
		{name: "different env", env: []corev1.EnvVar{{Name: "TON_WORK_DIR", Value: "/data"}}, fail: true},
		{name: "unknown env value", env: []corev1.EnvVar{{Name: "TON_WORK_DIR", ValueFrom: &corev1.EnvVarSource{FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"}}}}, fail: true},
		{name: "missing short value", args: []string{"-W"}, fail: true},
		{name: "different short flag", args: []string{"-W", "/data"}, fail: true},
		{name: "different long flag", args: []string{"--ton-work-dir=/data"}, fail: true},
		{name: "attached short flag", args: []string{"-W/data"}, fail: true},
		{name: "equals short flag", args: []string{"-W=/data"}, fail: true},
		{name: "work path through environment arguments", env: []corev1.EnvVar{{Name: "MYTONCTRL_ARGS", Value: "-m liteserver -W /data"}}, fail: true},
		{name: "work path through mounted environment file", args: []string{"-e", "/config/runtime.env"}, fail: true},
		{name: "work path through attached environment file", args: []string{"-e/config/runtime.env"}, fail: true},
		{name: "work path through environment file in arguments", env: []corev1.EnvVar{{Name: "MYTONCTRL_ARGS", Value: "-e /config/runtime.env"}}, fail: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{Env: tt.env, Args: tt.args}}
			message := validateRuntimeSpec(node)
			if (message != "") != tt.fail {
				t.Errorf("validation = %q, want rejection=%t", message, tt.fail)
			}
		})
	}
}

func TestRuntimePersistentLayoutPreservesLegacyData(t *testing.T) {
	for _, tt := range []struct {
		name  string
		files map[string]string
		fail  bool
	}{
		{name: "new empty work volume"},
		{name: "legacy completed marker", files: map[string]string{"ton-work/db/mtc_done": ""}, fail: true},
		{name: "legacy separate controller claim", files: map[string]string{"mytoncore/mytoncore.db": "legacy secret state"}, fail: true},
		{name: "legacy combined controller claim", files: map[string]string{"ton-work/usr-local-bin-mytoncore/mytoncore.db": "legacy secret state"}, fail: true},
		{name: "legacy node identity before controller setup", files: map[string]string{
			"ton-work/db/config.json": "retained node configuration", "ton-work/db/keyring/private-key": "retained private key",
		}, fail: true},
		{name: "interrupted new initialization", files: map[string]string{
			"ton-work/controller/.initializing": "", "ton-work/db/config.json": "retained node configuration",
		}},
		{name: "completed new initialization with unused old claim", files: map[string]string{
			"ton-work/controller/initialized.json": "{}", "mytoncore/mytoncore.db": "legacy secret state",
		}},
		{name: "explicit encrypted restore can recover lost controller state", files: map[string]string{
			"keybundle/.restore-controller-state": "requested", "ton-work/db/config.json": "retained configuration",
			"ton-work/db/keyring/private-key": "retained private key",
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			mounts := t.TempDir()
			for _, name := range []string{"ton-work", "ton-src", "mytoncore", "mytonctrl"} {
				if err := os.Mkdir(filepath.Join(mounts, name), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			for path, data := range tt.files {
				writeRuntimeFixture(t, filepath.Join(mounts, path), data)
			}
			script := strings.ReplaceAll(persistentLayoutScript, "/mnt/", mounts+"/")
			output, err := exec.Command("/bin/sh", "-ec", script).CombinedOutput()
			if (err != nil) != tt.fail {
				t.Fatalf("layout err=%v, want rejection=%t\n%s", err, tt.fail, output)
			}
			if tt.fail && !bytes.Contains(output, []byte("native MyTonCtrl backup")) {
				t.Errorf("legacy rejection lacks migration instructions: %s", output)
			}
			for path, want := range tt.files {
				got, err := os.ReadFile(filepath.Join(mounts, path))
				if err != nil || string(got) != want {
					t.Errorf("guard altered persisted %s: got %q err=%v", path, got, err)
				}
			}
			if !tt.fail {
				info, err := os.Stat(filepath.Join(mounts, "ton-work/controller"))
				if err != nil || !info.IsDir() {
					t.Errorf("controller directory missing after safe layout preparation: %v", err)
				}
			}
		})
	}
}

func runtimeMountByName(t *testing.T, container corev1.Container, name string) corev1.VolumeMount {
	t.Helper()
	for _, mount := range container.VolumeMounts {
		if mount.Name == name {
			return mount
		}
	}
	t.Fatalf("%s lacks volume mount %s", container.Name, name)
	return corev1.VolumeMount{}
}

func writeRuntimeFixture(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}
