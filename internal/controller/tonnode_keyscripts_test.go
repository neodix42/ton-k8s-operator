package controller

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Real tar/OpenSSL exercise the bundle format. The local KMS stub keeps these
// tests independent of credentials, network calls, host users and cluster PVCs.
func runKeyScript(t *testing.T, script, work, bundle string) ([]byte, error) {
	t.Helper()
	for _, binary := range []string{"openssl", "tar", "base64"} {
		if _, err := exec.LookPath(binary); err != nil {
			t.Skipf("key script integration requires %s", binary)
		}
	}
	script = strings.NewReplacer("/var/ton-work", work, "/var/ton-key-bundle", bundle,
		"/tmp/key-backup", filepath.Join(work, "backup-control")).Replace(script)
	stub := `
aws() {
  for arg in "$@"; do
    case "$arg" in fileb://*) base64 < "${arg#fileb://}" | tr -d '\n'; return ;; esac
  done
  return 1
}
id() { return 1; }
`
	command := exec.Command("sh", "-ec", stub+script)
	command.Env = append(os.Environ(), "KEY_PROVIDER=kms", "KMS_VENDOR=aws", "KMS_KEY_ID=test-local",
		"KEY_BUNDLE_FILE=keys.bundle.enc", "KEY_BUNDLE_META_FILE=keys.bundle.meta")
	return command.CombinedOutput()
}

func writeKeyFixture(t *testing.T, work, name, content string) {
	t.Helper()
	path := filepath.Join(work, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func keyBackupOnceScript(t *testing.T) string {
	t.Helper()
	index := strings.Index(keyBackupScript, "\nwhile true; do")
	if index < 0 {
		t.Fatal("backup polling loop missing")
	}
	// Match the sidecar's conditional invocation, where sh disables errexit
	// within the function. Failures must be propagated explicitly.
	return keyBackupScript[:index] + "\nif perform_backup; then exit 0; else exit 37; fi\n"
}

func TestKeyBundleRoundTripRetainsControllerAndNodeIdentity(t *testing.T) {
	source, bundle := t.TempDir(), t.TempDir()
	fixtures := map[string]string{
		"keys/client":                               "client-key",
		"controller/initialized.json":               `{"MTC_USER":"root","BIN_DIR":"/usr/bin","SRC_DIR":"/usr/src","TON_WORK_DIR":"/var/ton-work"}`,
		"controller/node-initialized.json":          `{"complete":true}`,
		"controller/mytoncore/mytoncore.db":         `{"validatorConsole":{"port":30002}}`,
		"controller/mytoncore/wallets/validator.pk": "wallet-key",
		"controller/mytonctrl/settings.json":        `{"language":"en"}`,
		"controller/services/validator.service":     "[Service]\nExecStart=/usr/bin/ton/validator-engine/validator-engine",
		"controller/services/mytoncore.service":     "[Service]\nExecStart=/opt/mytonctrl/venv/bin/python -m mytoncore",
		"controller/enabled/validator.service":      "enabled",
		"controller/enabled/mytoncore.service":      "enabled",
		"controller/global.config.json":             `{"network":"testnet"}`,
		"controller/local.config.json":              `{"local":true}`,
		"db/config.json":                            `{"node":"original"}`,
		"db/keyring/node-private":                   "validator-key",
	}
	for name, content := range fixtures {
		writeKeyFixture(t, source, name, content)
	}
	writeKeyFixture(t, source, "controller/.container.lock", "runtime-lock")
	if output, err := runKeyScript(t, keyBackupOnceScript(t), source, bundle); err != nil {
		t.Fatalf("encrypted backup: %v\n%s", err, output)
	}
	restored := t.TempDir()
	if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err != nil {
		t.Fatalf("encrypted restore: %v\n%s", err, output)
	}
	for name, content := range fixtures {
		got, err := os.ReadFile(filepath.Join(restored, name))
		if err != nil || string(got) != content {
			t.Errorf("restored %s = %q, err=%v; want %q", name, got, err, content)
		}
	}
	if _, err := os.Stat(filepath.Join(restored, "controller/.container.lock")); !os.IsNotExist(err) {
		t.Errorf("container lock must not be restored: %v", err)
	}
	// Ordinary restarts refill tmpfs without rolling back committed settings.
	writeKeyFixture(t, restored, "controller/mytoncore/mytoncore.db", "updated-core-settings")
	writeKeyFixture(t, restored, "db/config.json", "updated-node-settings")
	if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err != nil {
		t.Fatalf("restore over committed state: %v\n%s", err, output)
	}
	for name, want := range map[string]string{
		"controller/mytoncore/mytoncore.db": "updated-core-settings", "db/config.json": "updated-node-settings",
	} {
		got, _ := os.ReadFile(filepath.Join(restored, name))
		if string(got) != want {
			t.Errorf("restore rolled back %s: %q", name, got)
		}
	}
	// An interrupted initialization must retain its recovery checkpoint.
	if err := os.Remove(filepath.Join(restored, "controller/initialized.json")); err != nil {
		t.Fatal(err)
	}
	writeKeyFixture(t, restored, "controller/.initializing", "resume-settings")
	if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err != nil {
		t.Fatalf("restore during resumed installation: %v\n%s", err, output)
	}
	if _, err := os.Stat(filepath.Join(restored, "controller/initialized.json")); !os.IsNotExist(err) {
		t.Errorf("restore falsely committed interrupted installation: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(restored, "controller/mytoncore/mytoncore.db"))
	if string(got) != "updated-core-settings" {
		t.Errorf("restore overwrote resumed settings: %q", got)
	}

	// Explicit restore must replace controller settings and node identity together.
	writeKeyFixture(t, bundle, ".restore-controller-state", "explicit-request")
	writeKeyFixture(t, restored, "keys/foreign-private-key", "foreign")
	writeKeyFixture(t, restored, "controller/mytoncore/wallets/foreign.pk", "foreign")
	writeKeyFixture(t, restored, "db/keyring/foreign", "foreign")
	if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err != nil {
		t.Fatalf("explicit restore: %v\n%s", err, output)
	}
	for name, content := range fixtures {
		got, err := os.ReadFile(filepath.Join(restored, name))
		if err != nil || string(got) != content {
			t.Errorf("explicitly restored %s = %q, err=%v; want %q", name, got, err, content)
		}
	}
	for _, name := range []string{"keys/foreign-private-key", "controller/mytoncore/wallets/foreign.pk", "db/keyring/foreign", "controller/.initializing"} {
		if _, err := os.Stat(filepath.Join(restored, name)); !os.IsNotExist(err) {
			t.Errorf("explicit restore retained unrelated old state %s: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(bundle, ".restore-controller-state")); !os.IsNotExist(err) {
		t.Errorf("successful restore did not acknowledge explicit request: %v", err)
	}
}

func TestKeyRestoreRejectsLegacyBundleWithoutChangingState(t *testing.T) {
	source, bundle := t.TempDir(), t.TempDir()
	writeKeyFixture(t, source, "keys/client", "legacy-private-key")
	writeKeyFixture(t, source, "tondb/config.json", "legacy-config")
	writeKeyFixture(t, source, "tondb/mtc_done", "legacy-commit")
	writeKeyFixture(t, source, "tondb/systemd-units/validator.service", "legacy-unit")
	archive := filepath.Join(t.TempDir(), "legacy.tar.gz")
	if output, err := exec.Command("tar", "-czf", archive, "-C", source, ".").CombinedOutput(); err != nil {
		t.Fatalf("create legacy fixture: %v\n%s", err, output)
	}
	command := exec.Command("openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-md", "sha256", "-pass", "env:KEY_TEST_PASSWORD",
		"-in", archive, "-out", filepath.Join(bundle, "keys.bundle.enc"))
	command.Env = append(os.Environ(), "KEY_TEST_PASSWORD=local-test-password")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("encrypt legacy fixture: %v\n%s", err, output)
	}
	wrapped, err := exec.Command("sh", "-ec", "printf local-test-password | base64").Output()
	if err != nil {
		t.Fatal(err)
	}
	writeKeyFixture(t, bundle, "keys.bundle.meta", "wrapped_key="+strings.TrimSpace(string(wrapped))+"\n")
	originalBundle, _ := os.ReadFile(filepath.Join(bundle, "keys.bundle.enc"))
	restored := t.TempDir()
	writeKeyFixture(t, restored, "keys/client", "current-private-key")
	writeKeyFixture(t, restored, "db/config.json", "current-config")
	writeKeyFixture(t, bundle, ".restore-controller-state", "explicit-request")
	output, err := runKeyScript(t, keyRestoreScript, restored, bundle)
	if err == nil || !strings.Contains(string(output), "native MyTonCtrl backup") {
		t.Fatalf("legacy restore should fail with migration instructions: %v\n%s", err, output)
	}
	for name, want := range map[string]string{"keys/client": "current-private-key", "db/config.json": "current-config"} {
		got, _ := os.ReadFile(filepath.Join(restored, name))
		if string(got) != want {
			t.Errorf("legacy restore changed %s: %q", name, got)
		}
	}
	gotBundle, _ := os.ReadFile(filepath.Join(bundle, "keys.bundle.enc"))
	if string(gotBundle) != string(originalBundle) {
		t.Error("legacy bundle was changed")
	}
	if _, err := os.Stat(filepath.Join(bundle, ".restore-controller-state")); err != nil {
		t.Errorf("failed restore consumed explicit request: %v", err)
	}
}

func TestKeyBackupRejectsUncommittedInstallation(t *testing.T) {
	work, bundle := t.TempDir(), t.TempDir()
	writeKeyFixture(t, work, "keys/client", "private-key")
	writeKeyFixture(t, work, "controller/.initializing", "resume")
	writeKeyFixture(t, work, "db/config.json", "pending-config")
	output, err := runKeyScript(t, keyBackupOnceScript(t), work, bundle)
	if err == nil || !strings.Contains(string(output), "complete bootstrap state not present yet") {
		t.Fatalf("uncommitted backup should fail: %v\n%s", err, output)
	}
	if _, err := os.Stat(filepath.Join(bundle, "keys.bundle.enc")); !os.IsNotExist(err) {
		t.Errorf("uncommitted state published a bundle: %v", err)
	}
}

func TestKeyBackupFailureKeepsPreviousBundle(t *testing.T) {
	for _, fault := range []struct {
		name, shell string
	}{
		{"copy", "cp() { return 23; }\n"},
		{"archive", "tar() { return 23; }\n"},
		{"encryption", "openssl() { if [ \"$1\" = enc ]; then return 23; fi; command openssl \"$@\"; }\n"},
		{"random-key", "openssl() { return 23; }\n"},
		{"key-wrapping", "aws() { return 23; }\n"},
		{"publish-ciphertext", "mv() { case \"$2\" in */new.bundle) return 23;; esac; command mv \"$@\"; }\n"},
		{"publish-metadata", "mv() { case \"$2\" in */new.meta) return 23;; esac; command mv \"$@\"; }\n"},
		{"publish-sync", "publication_sync_count=0; sync() { publication_sync_count=$((publication_sync_count + 1)); [ \"$publication_sync_count\" -ne 3 ]; }\n"},
	} {
		t.Run(fault.name, func(t *testing.T) {
			work, bundle := t.TempDir(), t.TempDir()
			for _, name := range []string{"keys/client", "controller/initialized.json", "controller/mytoncore/mytoncore.db",
				"controller/services/validator.service", "controller/services/mytoncore.service", "db/config.json"} {
				writeKeyFixture(t, work, name, "complete-state")
			}
			writeKeyFixture(t, bundle, "keys.bundle.enc", "previous-good-bundle")
			writeKeyFixture(t, bundle, "keys.bundle.meta", "previous-good-metadata")
			output, err := runKeyScript(t, fault.shell+keyBackupOnceScript(t), work, bundle)
			if err == nil || strings.Contains(string(output), "encrypted key bundle updated") {
				t.Fatalf("failed backup reported success: %v\n%s", err, output)
			}
			for name, want := range map[string]string{"keys.bundle.enc": "previous-good-bundle", "keys.bundle.meta": "previous-good-metadata"} {
				got, err := os.ReadFile(filepath.Join(bundle, name))
				if err != nil || string(got) != want {
					t.Errorf("failed backup replaced %s: %q, %v", name, got, err)
				}
			}
		})
	}
}

func TestKeyBundleRecoversInterruptedPublication(t *testing.T) {
	for _, existing := range []bool{false, true} {
		name := "first-backup"
		if existing {
			name = "replaces-existing-backup"
		}
		t.Run(name, func(t *testing.T) {
			work, bundle := t.TempDir(), t.TempDir()
			for _, path := range []string{"keys/client", "controller/initialized.json", "controller/mytoncore/mytoncore.db",
				"controller/services/validator.service", "controller/services/mytoncore.service", "db/config.json"} {
				writeKeyFixture(t, work, path, "previous-complete-state")
			}
			previous := map[string][]byte{}
			if existing {
				if output, err := runKeyScript(t, keyBackupOnceScript(t), work, bundle); err != nil {
					t.Fatalf("initial backup: %v\n%s", err, output)
				}
				for _, path := range []string{"keys.bundle.enc", "keys.bundle.meta"} {
					var err error
					previous[path], err = os.ReadFile(filepath.Join(bundle, path))
					if err != nil {
						t.Fatal(err)
					}
				}
			}
			writeKeyFixture(t, work, "keys/client", "new-state-not-yet-committed")
			killAfterFirstPublish := `
mv() {
  command mv "$@" || return
  case "$2" in */new.bundle) kill -KILL $$ ;; esac
}
`
			if output, err := runKeyScript(t, killAfterFirstPublish+keyBackupOnceScript(t), work, bundle); err == nil {
				t.Fatalf("publication should be interrupted: %s", output)
			}
			if _, err := os.Stat(filepath.Join(bundle, ".backup-publish/rollback-required")); err != nil {
				t.Fatalf("interrupted publication lost recovery journal: %v", err)
			}
			restored := t.TempDir()
			if existing {
				killDuringRecovery := `
mv() {
  command mv "$@" || return
  case "$2" in */restore.bundle) kill -KILL $$ ;; esac
}
`
				if output, err := runKeyScript(t, killDuringRecovery+keyRestoreScript, restored, bundle); err == nil {
					t.Fatalf("recovery should be interrupted: %s", output)
				}
				for _, path := range []string{"rollback-required", "previous.bundle", "previous.meta"} {
					if _, err := os.Stat(filepath.Join(bundle, ".backup-publish", path)); err != nil {
						t.Errorf("interrupted recovery consumed %s: %v", path, err)
					}
				}
			}
			if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err != nil {
				t.Fatalf("recover interrupted publication during restore: %v\n%s", err, output)
			}
			for _, path := range []string{"keys.bundle.enc", "keys.bundle.meta"} {
				got, err := os.ReadFile(filepath.Join(bundle, path))
				if existing {
					if err != nil || string(got) != string(previous[path]) {
						t.Errorf("recovery changed previous %s: %v", path, err)
					}
				} else if !os.IsNotExist(err) {
					t.Errorf("recovery retained incomplete first backup %s: %v", path, err)
				}
			}
			if existing {
				got, err := os.ReadFile(filepath.Join(restored, "keys/client"))
				if err != nil || string(got) != "previous-complete-state" {
					t.Errorf("restored uncommitted key state: %q, %v", got, err)
				}
			}
			if _, err := os.Stat(filepath.Join(bundle, ".backup-publish")); !os.IsNotExist(err) {
				t.Errorf("completed recovery retained journal: %v", err)
			}
		})
	}
}

func TestKeyBundleRejectsIncompleteRecoveryJournal(t *testing.T) {
	work, bundle := t.TempDir(), t.TempDir()
	writeKeyFixture(t, bundle, "keys.bundle.enc", "current-ciphertext")
	writeKeyFixture(t, bundle, "keys.bundle.meta", "current-metadata")
	writeKeyFixture(t, bundle, ".backup-publish/rollback-required", "pending")
	writeKeyFixture(t, bundle, ".backup-publish/previous.bundle", "previous-ciphertext")
	output, err := runKeyScript(t, keyRestoreScript, work, bundle)
	if err == nil || !strings.Contains(string(output), "recovery journal is incomplete") {
		t.Fatalf("incomplete journal should block restoration: %v\n%s", err, output)
	}
	for path, want := range map[string]string{"keys.bundle.enc": "current-ciphertext", "keys.bundle.meta": "current-metadata"} {
		got, err := os.ReadFile(filepath.Join(bundle, path))
		if err != nil || string(got) != want {
			t.Errorf("invalid recovery changed %s: %q, %v", path, got, err)
		}
	}
}
