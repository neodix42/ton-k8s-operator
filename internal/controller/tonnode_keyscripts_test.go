package controller

import (
	"strings"
	"testing"
)

func TestKeyRestoreScriptIncludesBootstrapArtifacts(t *testing.T) {
	required := []string{
		`MTC_DONE_FILE="${TON_DB_DIR}/mtc_done"`,
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
		`AUTO_DONE_FILE="${BUNDLE_DIR}/.bootstrap-auto-backup.done"`,
		`dir_has_payload() {`,
		`key_material_present() {`,
		`bundle_present() {`,
		`auto_backup_ready() {`,
		`key_material_present`,
		`if [ -f "$MTC_DONE_FILE" ]; then`,
		`cp -a "$SYSTEMD_UNITS_DIR" "$work_dir/stage/tondb/systemd-units"`,
		`cp -a "$MTC_DONE_FILE" "$work_dir/stage/tondb/mtc_done"`,
		`echo "automatic bootstrap backup mode enabled"`,
		`if [ ! -f "$AUTO_DONE_FILE" ]; then`,
		`automatic bootstrap backup completed`,
	}
	for _, fragment := range required {
		if !strings.Contains(keyBackupScript, fragment) {
			t.Fatalf("keyBackupScript missing fragment: %q", fragment)
		}
	}
}
