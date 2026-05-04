package controller

import (
	"strings"
	"testing"
)

func TestKeyRestoreScriptIncludesBootstrapArtifacts(t *testing.T) {
	required := []string{
		`MTC_DONE_FILE="${TON_DB_DIR}/mtc_done"`,
		`fix_validator_ownership() {`,
		`if ! id -u validator >/dev/null 2>&1; then`,
		`chown -R validator:validator "$KEYS_DIR" "$WALLETS_DIR" || true`,
		`chown validator:validator "$DB_CONFIG_FILE" "$MTC_DONE_FILE" || true`,
		`chmod 600 "$KEYS_DIR/client" "$KEYS_DIR/client.pub" "$KEYS_DIR/server.pub" "$KEYS_DIR/liteserver.pub" 2>/dev/null || true`,
		`fix_validator_ownership`,
		`rm -rf "$SYSTEMD_UNITS_DIR" || true`,
		`rm -f "$MTC_DONE_FILE" || true`,
		`if [ -d "$work_dir/unpacked/tondb/systemd-units" ]; then`,
		`cp -a "$work_dir/unpacked/tondb/systemd-units" "$SYSTEMD_UNITS_DIR"`,
		`if [ -f "$work_dir/unpacked/tondb/mtc_done" ]; then`,
		`cp -a "$work_dir/unpacked/tondb/mtc_done" "$MTC_DONE_FILE"`,
	}
	for _, fragment := range required {
		if !strings.Contains(keyRestoreScript, fragment) {
			t.Fatalf("keyRestoreScript missing fragment: %q", fragment)
		}
	}
}

func TestKeyBackupScriptIncludesBootstrapArtifacts(t *testing.T) {
	required := []string{
		`SYSTEMD_UNITS_DIR="${TON_DB_DIR}/systemd-units"`,
		`MTC_DONE_FILE="${TON_DB_DIR}/mtc_done"`,
		`AUTO_BOOTSTRAP_FLAG="${KEY_AUTO_BOOTSTRAP_BUNDLE:-true}"`,
		`dir_has_payload() {`,
		`key_material_present() {`,
		`is_true() {`,
		`bundle_present() {`,
		`auto_backup_ready() {`,
		`if [ -f "$MTC_DONE_FILE" ]; then`,
		`cp -a "$SYSTEMD_UNITS_DIR" "$work_dir/stage/tondb/systemd-units"`,
		`cp -a "$MTC_DONE_FILE" "$work_dir/stage/tondb/mtc_done"`,
		`echo "manual backup mode enabled"`,
		`echo "automatic bootstrap backup mode enabled"`,
		`elif is_true "$AUTO_BOOTSTRAP_FLAG" && ! bundle_present && auto_backup_ready; then`,
		`automatic bootstrap backup completed`,
	}
	for _, fragment := range required {
		if !strings.Contains(keyBackupScript, fragment) {
			t.Fatalf("keyBackupScript missing fragment: %q", fragment)
		}
	}
}
