package controller

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	tonv1alpha1 "github.com/neodix/ton-k8s-operator/api/v1alpha1"
)

// Real tar/OpenSSL exercise the bundle format. The local KMS stub keeps these
// tests independent of credentials, network calls, host users and cluster PVCs.
func runKeyScript(t *testing.T, script, work, bundle string, extraEnv ...string) ([]byte, error) {
	t.Helper()
	for _, binary := range []string{"openssl", "tar", "base64", "python3", "cmp"} {
		if _, err := exec.LookPath(binary); err != nil {
			t.Skipf("key script integration requires %s", binary)
		}
	}
	scratch := keyRAMTempDir(t)
	// Do not depend on the developer/CI host's swap configuration and never
	// change it. A separate fault test checks the fail-closed swap branch.
	writeKeyFixture(t, scratch, "swaps", "Filename\tType\tSize\tUsed\tPriority\n")
	if err := os.MkdirAll(filepath.Join(work, "raw-work"), 0o700); err != nil {
		t.Fatal(err)
	}
	// The normal and raw PVC mounts share public db/config.json in production;
	// only controller, keys and keyring are covered by memory mounts.
	if config, err := os.ReadFile(filepath.Join(work, "raw-work/db/config.json")); err == nil {
		if _, err := os.Stat(filepath.Join(work, "db/config.json")); os.IsNotExist(err) {
			writeKeyFixture(t, work, "db/config.json", string(config))
		}
	}
	node := &tonv1alpha1.TonNode{Spec: tonv1alpha1.TonNodeSpec{KeyManagement: &tonv1alpha1.TonNodeKeyManagementSpec{Enabled: true}}}
	restore := desiredKeyRestoreInitContainer(node)
	script = strings.Replace(script, keyRestoreScript, restore.Command[2], 1)
	script = strings.NewReplacer("/var/ton-work", work, "/var/ton-key-bundle", bundle,
		"/tmp/key-backup", filepath.Join(work, "backup-control"),
		"/mnt/ton-work", filepath.Join(work, "raw-work"), "/proc/swaps", filepath.Join(scratch, "swaps"), "/tmp", scratch).Replace(script)
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
		"KEY_BUNDLE_FILE=keys.bundle.enc", "KEY_BUNDLE_META_FILE=keys.bundle.meta", "TMPDIR="+scratch)
	command.Env = append(command.Env, extraEnv...)
	return command.CombinedOutput()
}

// Scripts enforce tmpfs rather than trusting TMPDIR. Real /dev/shm-backed
// fixtures exercise that check without privileged mounts or a Kubernetes API.
func keyRAMTempDir(t *testing.T) string {
	t.Helper()
	path, err := os.MkdirTemp("/dev/shm", "kubeton-key-test-")
	if err != nil {
		t.Skipf("key script integration requires writable tmpfs /dev/shm: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(path) })
	filesystem, err := exec.Command("stat", "-f", "-c", "%T", path).Output()
	if err != nil || strings.TrimSpace(string(filesystem)) != "tmpfs" {
		t.Skipf("key script integration requires real tmpfs, got %q (%v)", filesystem, err)
	}
	return path
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
	source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
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
	restored := keyRAMTempDir(t)
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
	protectMemoryMounts := `
rm() {
  for target in "$@"; do
    case "$target" in
      /var/ton-work/keys|/var/ton-work/controller|/var/ton-work/controller/mytoncore/wallets|/var/ton-work/db/keyring)
        echo 'test mountpoint cannot be removed; clear its contents instead' >&2
        return 92
        ;;
    esac
  done
  command rm "$@"
}
`
	if output, err := runKeyScript(t, protectMemoryMounts+keyRestoreScript, restored, bundle); err != nil {
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
	source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	writeKeyFixture(t, source, "keys/client", "legacy-private-key")
	writeKeyFixture(t, source, "tondb/config.json", "legacy-config")
	writeKeyFixture(t, source, "tondb/mtc_done", "legacy-commit")
	writeKeyFixture(t, source, "tondb/systemd-units/validator.service", "legacy-unit")
	archive := filepath.Join(keyRAMTempDir(t), "legacy.tar.gz")
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
	restored := keyRAMTempDir(t)
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
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
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
		{"inconsistent-copied-state", `cp() {
  for copied_target do :; done
  command cp "$@" || return
  case "$copied_target" in */stage/controller/) printf 'incomplete copy' > "$copied_target/mytoncore/mytoncore.db";; esac
}
`},
		{"encryption", "openssl() { if [ \"$1\" = enc ]; then return 23; fi; command openssl \"$@\"; }\n"},
		{"random-key", "openssl() { return 23; }\n"},
		{"key-wrapping", "aws() { return 23; }\n"},
		{"publish-ciphertext", "mv() { case \"$2\" in */new.bundle) return 23;; esac; command mv \"$@\"; }\n"},
		{"publish-metadata", "mv() { case \"$2\" in */new.meta) return 23;; esac; command mv \"$@\"; }\n"},
		{"publish-sync", "publication_sync_count=0; sync() { publication_sync_count=$((publication_sync_count + 1)); [ \"$publication_sync_count\" -ne 3 ]; }\n"},
	} {
		t.Run(fault.name, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
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
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
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
			restored := keyRAMTempDir(t)
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
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
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

func migrationKeyFixtures() map[string]string {
	return map[string]string{
		"keys/client":                           "legacy-console-private-key",
		"controller/initialized.json":           `{"MTC_USER":"root"}`,
		"controller/mytoncore/mytoncore.db":     `{"token":"legacy-private-controller-token"}`,
		"controller/mytoncore/wallets/node.pk":  "legacy-wallet-private-key",
		"controller/services/validator.service": "[Service]\nExecStart=/usr/bin/ton/validator-engine/validator-engine",
		"controller/services/mytoncore.service": "[Service]\nExecStart=/opt/mytonctrl/venv/bin/python -m mytoncore",
		"db/config.json":                        `{"adnl":[{"id":"retained-public-identity"}]}`,
		"db/keyring/node-private":               "legacy-validator-private-key",
	}
}

func TestKeyRestoreMigratesPersistentPlaintextBeforeRemovingIt(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	raw := filepath.Join(work, "raw-work")
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, raw, name, content)
	}
	if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err != nil {
		t.Fatalf("migrate persistent secrets to encrypted bundle and RAM: %v\n%s", err, output)
	}
	if info, err := os.Stat(filepath.Join(bundle, ".historical-plaintext-exposure")); err != nil || info.Size() == 0 {
		t.Errorf("migration must retain a durable warning about historical disk copies: %v", err)
	}
	for name, want := range migrationKeyFixtures() {
		got, err := os.ReadFile(filepath.Join(work, name))
		if err != nil || string(got) != want {
			t.Errorf("migrated RAM payload %s = %q, err=%v; want %q", name, got, err, want)
		}
	}
	for _, name := range []string{"keys/client", "controller/mytoncore/mytoncore.db", "controller/mytoncore/wallets/node.pk", "db/keyring/node-private"} {
		if _, err := os.Stat(filepath.Join(raw, name)); !os.IsNotExist(err) {
			t.Errorf("verified migration retained live plaintext path %s: %v", name, err)
		}
	}
	// A separate Pod must recover the same identity using only ciphertext. This
	// catches migration code that deletes the source before publishing a usable
	// archive or accidentally archives the empty tmpfs views instead of raw PVCs.
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("restore migrated bundle into a new Pod: %v\n%s", err, output)
	}
	for name, want := range migrationKeyFixtures() {
		got, err := os.ReadFile(filepath.Join(restarted, name))
		if err != nil || string(got) != want {
			t.Errorf("restarted %s = %q, err=%v; want %q", name, got, err, want)
		}
	}
}

func TestKeyMigrationFailurePreservesPersistentSecrets(t *testing.T) {
	for _, fault := range []struct{ name, shell string }{
		{"key-wrapping", "aws() { return 23; }\n"},
		{"encryption", "openssl() { if [ \"$1\" = enc ]; then return 23; fi; command openssl \"$@\"; }\n"},
		{"archive", "tar() { return 23; }\n"},
		{"restore-verification", "openssl() { for arg in \"$@\"; do [ \"$arg\" != -d ] || return 23; done; command openssl \"$@\"; }\n"},
	} {
		t.Run(fault.name, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			raw := filepath.Join(work, "raw-work")
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, raw, name, content)
			}
			if output, err := runKeyScript(t, fault.shell+keyRestoreScript, work, bundle); err == nil {
				t.Fatalf("migration unexpectedly succeeded during %s failure: %s", fault.name, output)
			}
			for name, want := range migrationKeyFixtures() {
				got, err := os.ReadFile(filepath.Join(raw, name))
				if err != nil || string(got) != want {
					t.Errorf("failed migration changed persistent %s: %q, %v", name, got, err)
				}
			}
		})
	}
}

func TestKeyMigrationRejectsRawSecretSymlinks(t *testing.T) {
	for _, name := range []string{"controller", "keys", "db/keyring"} {
		t.Run(name, func(t *testing.T) {
			work, bundle, target := keyRAMTempDir(t), keyRAMTempDir(t), keyRAMTempDir(t)
			writeKeyFixture(t, target, "private-key", "external-secret-preserved")
			link := filepath.Join(work, "raw-work", name)
			if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, link); err != nil {
				t.Fatal(err)
			}
			if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err == nil {
				t.Fatalf("unsafe legacy secret symlink was accepted: %s", output)
			}
			got, err := os.ReadFile(filepath.Join(target, "private-key"))
			if err != nil || string(got) != "external-secret-preserved" {
				t.Errorf("symlink target changed: %q, %v", got, err)
			}
			if _, err := os.Lstat(link); err != nil {
				t.Errorf("rejected migration removed original link: %v", err)
			}
		})
	}
}

func TestKeyMigrationRetainsNewerPersistentSettingsAndAdditionalKeys(t *testing.T) {
	oldWork, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, oldWork, name, content)
	}
	if output, err := runKeyScript(t, keyBackupOnceScript(t), oldWork, bundle); err != nil {
		t.Fatalf("previous encrypted checkpoint: %v\n%s", err, output)
	}
	work := keyRAMTempDir(t)
	fixtures := migrationKeyFixtures()
	fixtures["controller/mytoncore/mytoncore.db"] = `{"token":"newer-live-controller-settings"}`
	fixtures["db/keyring/new-validator-key"] = "newer-live-validator-key"
	for name, content := range fixtures {
		writeKeyFixture(t, filepath.Join(work, "raw-work"), name, content)
	}
	if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err != nil {
		t.Fatalf("migrate newer live identity with an older bundle present: %v\n%s", err, output)
	}
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("restore refreshed identity: %v\n%s", err, output)
	}
	for _, name := range []string{"controller/mytoncore/mytoncore.db", "controller/mytoncore/wallets/node.pk", "db/keyring/node-private", "db/keyring/new-validator-key"} {
		got, err := os.ReadFile(filepath.Join(restarted, name))
		if err != nil || string(got) != fixtures[name] {
			t.Errorf("migration rolled back newer live identity %s: %q, %v", name, got, err)
		}
	}
}

func TestKeyMigrationCombinesExistingMemoryOnlyKeysWithNewerPersistentSettings(t *testing.T) {
	source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	fixtures := migrationKeyFixtures()
	for name, content := range fixtures {
		writeKeyFixture(t, source, name, content)
	}
	if output, err := runKeyScript(t, keyBackupOnceScript(t), source, bundle); err != nil {
		t.Fatalf("previous operator's encrypted memory-only keys: %v\n%s", err, output)
	}
	work := keyRAMTempDir(t)
	// The previous operator already overmounted keys and wallets with tmpfs.
	// Its PVC therefore contains fresh settings/keyring but empty private-key
	// mountpoints. Copying only raw PVC state would silently lose the wallets.
	fixtures["controller/mytoncore/mytoncore.db"] = `{"token":"newer-persisted-controller-settings"}`
	fixtures["db/keyring/new-validator-key"] = "newer-persisted-validator-key"
	for name, content := range fixtures {
		if strings.HasPrefix(name, "keys/") || strings.HasPrefix(name, "controller/mytoncore/wallets/") {
			continue
		}
		writeKeyFixture(t, filepath.Join(work, "raw-work"), name, content)
	}
	for _, name := range []string{"keys", "controller/mytoncore/wallets"} {
		if err := os.MkdirAll(filepath.Join(work, "raw-work", name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err != nil {
		t.Fatalf("merge encrypted private keys with current persistent state: %v\n%s", err, output)
	}
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("restore merged migration checkpoint: %v\n%s", err, output)
	}
	for _, directory := range []string{work, restarted} {
		for name, want := range fixtures {
			got, err := os.ReadFile(filepath.Join(directory, name))
			if err != nil || string(got) != want {
				t.Errorf("migration lost encrypted key or reverted current settings %s in %s: %q, %v", name, directory, got, err)
			}
		}
	}
}

func TestKeyMigrationStopsOnSeedDecryptionFailure(t *testing.T) {
	source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, source, name, content)
	}
	if output, err := runKeyScript(t, keyBackupOnceScript(t), source, bundle); err != nil {
		t.Fatalf("initial checkpoint: %v\n%s", err, output)
	}
	previous, _ := os.ReadFile(filepath.Join(bundle, "keys.bundle.enc"))
	work := keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, filepath.Join(work, "raw-work"), name, content)
	}
	// A decryptor can produce output before reporting an error. The seed
	// subshell must retain errexit rather than continuing on those bytes.
	fault := `openssl() {
  command openssl "$@" || return
  for arg do [ "$arg" != -d ] || return 23; done
}
`
	if output, err := runKeyScript(t, fault+keyRestoreScript, work, bundle); err == nil {
		t.Fatalf("migration ignored failed seed decryption: %s", output)
	}
	gotBundle, _ := os.ReadFile(filepath.Join(bundle, "keys.bundle.enc"))
	if string(gotBundle) != string(previous) {
		t.Error("seed failure replaced previous encrypted bundle")
	}
	for name, want := range migrationKeyFixtures() {
		got, err := os.ReadFile(filepath.Join(work, "raw-work", name))
		if err != nil || string(got) != want {
			t.Errorf("seed failure changed raw %s: %q, %v", name, got, err)
		}
	}
}

func TestKeyMigrationRejectsConflictingPrivateIdentityWithoutChangingSources(t *testing.T) {
	for _, conflict := range []string{"keys/client", "controller/mytoncore/wallets/node.pk", "db/keyring/node-private"} {
		t.Run(conflict, func(t *testing.T) {
			source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, source, name, content)
			}
			if output, err := runKeyScript(t, keyBackupOnceScript(t), source, bundle); err != nil {
				t.Fatalf("committed encrypted identity: %v\n%s", err, output)
			}
			previous := map[string][]byte{}
			for _, name := range []string{"keys.bundle.enc", "keys.bundle.meta"} {
				var err error
				previous[name], err = os.ReadFile(filepath.Join(bundle, name))
				if err != nil {
					t.Fatal(err)
				}
			}
			work := keyRAMTempDir(t)
			fixtures := migrationKeyFixtures()
			fixtures[conflict] = "conflicting-private-key-requires-explicit-selection"
			for name, content := range fixtures {
				writeKeyFixture(t, filepath.Join(work, "raw-work"), name, content)
			}
			output, err := runKeyScript(t, keyRestoreScript, work, bundle)
			if err == nil || !strings.Contains(string(output), "Conflicting") {
				t.Fatalf("ambiguous private-key conflict was accepted: %v\n%s", err, output)
			}
			for name, want := range fixtures {
				got, err := os.ReadFile(filepath.Join(work, "raw-work", name))
				if err != nil || string(got) != want {
					t.Errorf("conflict changed raw source %s: %q, %v", name, got, err)
				}
			}
			for name, want := range previous {
				got, err := os.ReadFile(filepath.Join(bundle, name))
				if err != nil || string(got) != string(want) {
					t.Errorf("conflict replaced encrypted source %s: %v", name, err)
				}
			}
		})
	}
}

func TestKeyBackupRejectsUnrestorableLinksBeforeReplacingBundle(t *testing.T) {
	work, bundle, target := keyRAMTempDir(t), keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, content)
	}
	if output, err := runKeyScript(t, keyBackupOnceScript(t), work, bundle); err != nil {
		t.Fatalf("initial valid backup: %v\n%s", err, output)
	}
	previous := map[string][]byte{}
	for _, name := range []string{"keys.bundle.enc", "keys.bundle.meta"} {
		var err error
		previous[name], err = os.ReadFile(filepath.Join(bundle, name))
		if err != nil {
			t.Fatal(err)
		}
	}
	writeKeyFixture(t, target, "private", "unrelated-secret")
	if err := os.Symlink(filepath.Join(target, "private"), filepath.Join(work, "controller/mytoncore/unrestorable-link")); err != nil {
		t.Fatal(err)
	}
	if output, err := runKeyScript(t, keyBackupOnceScript(t), work, bundle); err == nil {
		t.Fatalf("backup published a bundle that restore must reject: %s", output)
	}
	for name, want := range previous {
		got, err := os.ReadFile(filepath.Join(bundle, name))
		if err != nil || string(got) != string(want) {
			t.Errorf("unrestorable backup replaced previous %s: %v", name, err)
		}
	}
}

func TestKeyMigrationResumesInterruptedCleanupFromVerifiedBundle(t *testing.T) {
	for _, remaining := range []string{"controller", "keyring", "none"} {
		t.Run(remaining, func(t *testing.T) {
			source, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, source, name, content)
			}
			if output, err := runKeyScript(t, keyBackupOnceScript(t), source, bundle); err != nil {
				t.Fatalf("verified pre-cleanup snapshot: %v\n%s", err, output)
			}
			writeKeyFixture(t, bundle, ".historical-plaintext-exposure", "cleanup-started-before-crash")
			work := keyRAMTempDir(t)
			writeKeyFixture(t, work, "raw-work/db/config.json", migrationKeyFixtures()["db/config.json"])
			switch remaining {
			case "controller":
				writeKeyFixture(t, work, "raw-work/controller/mytoncore/mytoncore.db", "partial-raw-controller-must-not-win")
			case "keyring":
				writeKeyFixture(t, work, "raw-work/db/keyring/node-private", "partial-raw-keyring-must-not-win")
			}
			if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err != nil {
				t.Fatalf("resume interrupted plaintext cleanup: %v\n%s", err, output)
			}
			for name, want := range migrationKeyFixtures() {
				got, err := os.ReadFile(filepath.Join(work, name))
				if err != nil || string(got) != want {
					t.Errorf("crash recovery did not prefer verified snapshot %s: %q, %v", name, got, err)
				}
			}
			for _, name := range []string{"controller/mytoncore/mytoncore.db", "db/keyring/node-private"} {
				if _, err := os.Stat(filepath.Join(work, "raw-work", name)); !os.IsNotExist(err) {
					t.Errorf("resumed migration retained raw plaintext %s: %v", name, err)
				}
			}
		})
	}
}

func TestKeyMigrationCleanupMarkerRequiresUsableBundle(t *testing.T) {
	for _, broken := range []string{"missing-pair", "missing-metadata", "corrupt-ciphertext"} {
		t.Run(broken, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, filepath.Join(work, "raw-work"), name, content)
			}
			writeKeyFixture(t, bundle, ".historical-plaintext-exposure", "prior-cleanup-interrupted")
			if broken != "missing-pair" {
				writeKeyFixture(t, bundle, "keys.bundle.enc", "corrupt-ciphertext")
			}
			if broken == "corrupt-ciphertext" {
				writeKeyFixture(t, bundle, "keys.bundle.meta", "wrapped_key=cHJldmlvdXMta2V5\n")
			}
			if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err == nil {
				t.Fatalf("cleanup marker with %s must fail closed: %s", broken, output)
			}
			for name, want := range migrationKeyFixtures() {
				got, err := os.ReadFile(filepath.Join(work, "raw-work", name))
				if err != nil || string(got) != want {
					t.Errorf("failed crash recovery changed raw %s: %q, %v", name, got, err)
				}
			}
		})
	}
}

func keyPartialCheckpointScript(t *testing.T) string {
	t.Helper()
	return strings.Replace(keyBackupOnceScript(t), "\nif perform_backup; then", "\nif perform_backup allow-initializing; then", 1)
}

func TestKeyInitialCheckpointRecoversIdentityWithoutCommittingBootstrap(t *testing.T) {
	for _, withConfig := range []bool{false, true} {
		t.Run(map[bool]string{false: "before-public-config", true: "with-public-config"}[withConfig], func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			fixtures := map[string]string{
				"controller/.initializing":       `{"MTC_USER":"root","TON_WORK_DIR":"/var/ton-work"}`,
				"keys/client":                    "initial-console-key",
				"db/keyring/initial-private-key": "initial-validator-key",
			}
			if withConfig {
				fixtures["db/config.json"] = `{"adnl":[{"id":"initial-public-identity"}]}`
			}
			for name, content := range fixtures {
				writeKeyFixture(t, work, name, content)
			}
			if output, err := runKeyScript(t, keyPartialCheckpointScript(t), work, bundle); err != nil {
				t.Fatalf("checkpoint initial private identity: %v\n%s", err, output)
			}
			meta, err := os.ReadFile(filepath.Join(bundle, "keys.bundle.meta"))
			if err != nil || !strings.Contains(string(meta), "bootstrap_state=initializing") {
				t.Fatalf("initialization checkpoint must be explicitly distinguished from completed bundles: %q, %v", meta, err)
			}
			restarted := keyRAMTempDir(t)
			if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
				t.Fatalf("restore interrupted initial identity: %v\n%s", err, output)
			}
			for name, want := range fixtures {
				got, err := os.ReadFile(filepath.Join(restarted, name))
				if err != nil || string(got) != want {
					t.Errorf("restored initialization checkpoint %s: %q, %v", name, got, err)
				}
			}
			if _, err := os.Stat(filepath.Join(restarted, "controller/initialized.json")); !os.IsNotExist(err) {
				t.Errorf("partial checkpoint falsely committed initialization: %v", err)
			}
		})
	}
}

func TestKeyExplicitRestoreRejectsInitialCheckpoint(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	writeKeyFixture(t, work, "controller/.initializing", "initializing")
	writeKeyFixture(t, work, "keys/client", "checkpoint-console-key")
	if output, err := runKeyScript(t, keyPartialCheckpointScript(t), work, bundle); err != nil {
		t.Fatalf("initial identity checkpoint: %v\n%s", err, output)
	}
	writeKeyFixture(t, bundle, ".restore-controller-state", "explicit restore")
	restored := keyRAMTempDir(t)
	writeKeyFixture(t, restored, "keys/client", "current-private-key")
	if output, err := runKeyScript(t, keyRestoreScript, restored, bundle); err == nil {
		t.Fatalf("explicit destructive restore accepted an incomplete initialization checkpoint: %s", output)
	}
	got, err := os.ReadFile(filepath.Join(restored, "keys/client"))
	if err != nil || string(got) != "current-private-key" {
		t.Errorf("rejected explicit restore changed current key: %q, %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(bundle, ".restore-controller-state")); err != nil {
		t.Errorf("rejected partial restore consumed the recovery request: %v", err)
	}
}

func TestKeyInitialCheckpointFailurePreservesCommittedBundle(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	writeKeyFixture(t, work, "controller/.initializing", "initializing")
	writeKeyFixture(t, work, "keys/client", "new-initial-console-key")
	previous := map[string]string{"keys.bundle.enc": "previous-committed-ciphertext", "keys.bundle.meta": "previous-committed-metadata"}
	for name, content := range previous {
		writeKeyFixture(t, bundle, name, content)
	}
	if output, err := runKeyScript(t, "aws() { return 23; }\n"+keyPartialCheckpointScript(t), work, bundle); err == nil {
		t.Fatalf("partial checkpoint reported success despite KMS failure: %s", output)
	}
	for name, want := range previous {
		got, err := os.ReadFile(filepath.Join(bundle, name))
		if err != nil || string(got) != want {
			t.Errorf("failed initial checkpoint replaced committed %s: %q, %v", name, got, err)
		}
	}
}

func TestKeyMissingCheckpointDoesNotRegeneratePersistedIdentity(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	writeKeyFixture(t, work, "db/config.json", `{"adnl":[{"id":"existing-public-identity"}]}`)
	if output, err := runKeyScript(t, keyRestoreScript, work, bundle); err == nil {
		t.Fatalf("persistent public identity without private checkpoint must fail before initialization: %s", output)
	}
	got, err := os.ReadFile(filepath.Join(work, "db/config.json"))
	if err != nil || string(got) != `{"adnl":[{"id":"existing-public-identity"}]}` {
		t.Errorf("missing-checkpoint failure changed existing node config: %q, %v", got, err)
	}
}

func TestKeyScriptsCannotRedirectPlaintextStagingWithTMPDIR(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, content)
	}
	// Production scripts must choose and verify their memory staging paths.
	// Fail even a short-lived disk temporary file before it can hold plaintext.
	checkTemporaryFilesystem := `
mktemp() {
  checked_temp="$(command mktemp "$@")" || return
  if [ "$(stat -f -c %T "$checked_temp")" != tmpfs ]; then
    rm -rf "$checked_temp"
    echo 'test detected disk-backed temporary file' >&2
    return 91
  fi
  printf '%s\n' "$checked_temp"
}
`
	unsafeDirectory, err := os.MkdirTemp("/var/tmp", "kubeton-key-disk-")
	if err != nil {
		t.Skipf("disk TMPDIR refusal requires writable /var/tmp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(unsafeDirectory) })
	filesystem, err := exec.Command("stat", "-f", "-c", "%T", unsafeDirectory).Output()
	if err != nil || strings.TrimSpace(string(filesystem)) == "tmpfs" {
		t.Skipf("disk TMPDIR refusal requires a disk-backed fixture, got %q (%v)", filesystem, err)
	}
	unsafeTMPDIR := "TMPDIR=" + unsafeDirectory
	if output, err := runKeyScript(t, checkTemporaryFilesystem+keyBackupOnceScript(t), work, bundle, unsafeTMPDIR); err != nil {
		t.Fatalf("backup must ignore disk-backed TMPDIR: %v\n%s", err, output)
	}
	restored := keyRAMTempDir(t)
	if output, err := runKeyScript(t, checkTemporaryFilesystem+keyRestoreScript, restored, bundle, unsafeTMPDIR); err != nil {
		t.Fatalf("restore must ignore disk-backed TMPDIR: %v\n%s", err, output)
	}
}

func TestKeyScriptsRejectDiskBackedStaging(t *testing.T) {
	for _, operation := range []string{"backup", "restore"} {
		t.Run(operation, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, work, name, content)
			}
			script := keyRestoreScript
			if operation == "backup" {
				script = keyBackupOnceScript(t)
			}
			// Fault the mount verification without privileged host mount changes.
			// A restore with no bundle must still validate the memory mount before
			// allowing initialization to generate new private keys.
			if output, err := runKeyScript(t, "stat() { printf 'ext2/ext3\\n'; }\n"+script, work, bundle); err == nil {
				t.Fatalf("%s accepted disk-backed secret staging: %s", operation, output)
			}
			if _, err := os.Stat(filepath.Join(bundle, "keys.bundle.enc")); !os.IsNotExist(err) {
				t.Errorf("rejected %s must not publish a bundle: %v", operation, err)
			}
		})
	}
}

func TestKeyScriptsRejectEnabledSwap(t *testing.T) {
	for _, operation := range []string{"backup", "restore"} {
		t.Run(operation, func(t *testing.T) {
			work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
			for name, content := range migrationKeyFixtures() {
				writeKeyFixture(t, work, name, content)
			}
			script := keyRestoreScript
			if operation == "backup" {
				script = keyBackupOnceScript(t)
			}
			swapFault := `
awk() {
  case "$1" in *'NR > 1'*) return 1 ;; esac
  command awk "$@"
}
`
			output, err := runKeyScript(t, swapFault+script, work, bundle)
			if err == nil || !strings.Contains(string(output), "swap enabled") {
				t.Fatalf("%s must reject enabled worker swap: %v\n%s", operation, err, output)
			}
		})
	}
}

func TestKeyAutomaticCheckpointRetainsChangedRAMState(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, content)
	}
	const pacing = "\n  sleep 2 &\n  wait $!\ndone"
	if !strings.HasSuffix(strings.TrimSpace(keyBackupScript), strings.TrimSpace(pacing)) {
		t.Fatal("backup polling harness must replace only its final loop pacing")
	}
	// Keep the production decision logic and encryption path; replace only its
	// wait so this covers two complete polling passes without a timed test.
	twoPasses := `
  test_poll_pass=$((${test_poll_pass:-0} + 1))
  if [ "$test_poll_pass" -eq 1 ]; then
    printf '%s' 'rotated-wallet-private-key' > "$WALLETS_DIR/node.pk"
    printf '%s' '{"token":"updated-private-controller-token"}' > "$MYTONCORE_DIR/mytoncore.db"
  else
    exit 0
  fi
done
`
	script := strings.TrimSuffix(strings.TrimSpace(keyBackupScript), strings.TrimSpace(pacing)) + "\n" + twoPasses
	if output, err := runKeyScript(t, script, work, bundle); err != nil {
		t.Fatalf("automatic checkpoints: %v\n%s", err, output)
	}
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("restore automatically updated checkpoint: %v\n%s", err, output)
	}
	for name, want := range map[string]string{
		"controller/mytoncore/wallets/node.pk": "rotated-wallet-private-key",
		"controller/mytoncore/mytoncore.db":    `{"token":"updated-private-controller-token"}`,
	} {
		got, err := os.ReadFile(filepath.Join(restarted, name))
		if err != nil || string(got) != want {
			t.Errorf("automatic checkpoint lost RAM change %s: %q, %v", name, got, err)
		}
	}
}

func TestKeyCheckpointRequestsArrivingDuringSnapshotWaitForNextSnapshot(t *testing.T) {
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, content)
	}
	const pacing = "\n  sleep 2 &\n  wait $!\ndone"
	if !strings.HasSuffix(strings.TrimSpace(keyBackupScript), strings.TrimSpace(pacing)) {
		t.Fatal("checkpoint request harness must replace only its final loop pacing")
	}
	arriveDuringSnapshot := `
aws() {
  if [ "$1" = kms ] && [ "$2" = encrypt ] && [ ! -f /tmp/key-backup.test-injected ]; then
    : > /tmp/key-backup.requests/00000002
    : > /tmp/key-backup.test-injected
  fi
  for arg in "$@"; do
    case "$arg" in fileb://*) base64 < "${arg#fileb://}" | tr -d '\n'; return ;; esac
  done
  return 1
}
`
	script := strings.Replace(keyBackupScript, "\nwhile true; do", "\n: > /tmp/key-backup.requests/00000001\nwhile true; do", 1)
	twoPasses := `
  test_poll_pass=$((${test_poll_pass:-0} + 1))
  if [ "$test_poll_pass" -eq 1 ]; then
    test "$(cat /tmp/key-backup.acks/00000001)" = ok
    test ! -e /tmp/key-backup.acks/00000002
    test -f /tmp/key-backup.requests/00000002
    printf '%s' '{"token":"changed-after-request-arrival"}' > "$MYTONCORE_DIR/mytoncore.db"
  else
    test "$(cat /tmp/key-backup.acks/00000002)" = ok
    test ! -e /tmp/key-backup.requests/00000002
    exit 0
  fi
done
`
	script = arriveDuringSnapshot + strings.TrimSuffix(strings.TrimSpace(script), strings.TrimSpace(pacing)) + "\n" + twoPasses
	if output, err := runKeyScript(t, script, work, bundle); err != nil {
		t.Fatalf("correlated checkpoint requests acknowledged stale state: %v\n%s", err, output)
	}
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("restore final correlated checkpoint: %v\n%s", err, output)
	}
	got, err := os.ReadFile(filepath.Join(restarted, "controller/mytoncore/mytoncore.db"))
	if err != nil || string(got) != `{"token":"changed-after-request-arrival"}` {
		t.Errorf("later request was acknowledged without its later snapshot: %q, %v", got, err)
	}
}

func TestKeyConcurrentCheckpointsSerializeEncryptedPublication(t *testing.T) {
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("checkpoint serialization requires flock")
	}
	work, bundle := keyRAMTempDir(t), keyRAMTempDir(t)
	for name, content := range migrationKeyFixtures() {
		writeKeyFixture(t, work, name, content)
	}
	index := strings.Index(keyBackupScript, "\nwhile true; do")
	if index < 0 {
		t.Fatal("backup polling loop missing")
	}
	detectOverlap := `
aws() {
  if [ "$1" = kms ] && [ "$2" = encrypt ]; then
    if ! mkdir /tmp/key-backup.test-critical; then
      echo 'concurrent snapshots entered encryption/publication together' >&2
      return 93
    fi
    sleep 0.1
    rmdir /tmp/key-backup.test-critical
  fi
  for arg in "$@"; do
    case "$arg" in fileb://*) base64 < "${arg#fileb://}" | tr -d '\n'; return ;; esac
  done
  return 1
}
`
	concurrent := `
( if perform_backup; then exit 0; else exit 94; fi ) &
checkpoint_one=$!
( if perform_backup; then exit 0; else exit 95; fi ) &
checkpoint_two=$!
wait "$checkpoint_one"
wait "$checkpoint_two"
`
	if output, err := runKeyScript(t, detectOverlap+keyBackupScript[:index]+concurrent, work, bundle); err != nil {
		t.Fatalf("concurrent checkpoints were not serialized: %v\n%s", err, output)
	}
	restarted := keyRAMTempDir(t)
	if output, err := runKeyScript(t, keyRestoreScript, restarted, bundle); err != nil {
		t.Fatalf("concurrent snapshots left an unusable encrypted pair: %v\n%s", err, output)
	}
}
