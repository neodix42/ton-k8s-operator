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
		`AUTO_DONE_FILE="${BUNDLE_DIR}/.bootstrap-auto-backup.done"`,
		`dir_has_payload() {`,
		`key_material_present() {`,
		`bundle_present() {`,
		`auto_backup_ready() {`,
		`[ -f "$MTC_DONE_FILE" ] || return 1`,
		`[ -s "$DB_CONFIG_FILE" ] || return 1`,
		`dir_has_payload "$DB_KEYRING_DIR" || return 1`,
		`[ -s "$KEYS_DIR/client" ] || return 1`,
		`[ -s "$KEYS_DIR/client.pub" ] || return 1`,
		`[ -s "$KEYS_DIR/server.pub" ] || return 1`,
		`[ -s "$KEYS_DIR/liteserver.pub" ] || return 1`,
		`[ "$(wc -c < "$KEYS_DIR/client")" -gt 128 ] || return 1`,
		`if [ -f "$MTC_DONE_FILE" ]; then`,
		`cp -a "$SYSTEMD_UNITS_DIR" "$work_dir/stage/tondb/systemd-units"`,
		`cp -a "$MTC_DONE_FILE" "$work_dir/stage/tondb/mtc_done"`,
		`echo "automatic bootstrap backup mode enabled"`,
		`if [ ! -f "$AUTO_DONE_FILE" ]; then`,
		`key material not ready yet; automatic bootstrap backup retrying`,
		`automatic bootstrap backup completed`,
	}
	for _, fragment := range required {
		if !strings.Contains(keyBackupScript, fragment) {
			t.Fatalf("keyBackupScript missing fragment: %q", fragment)
		}
	}
}
