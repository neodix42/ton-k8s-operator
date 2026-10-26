#!/usr/bin/env python3
"""Exercise the production, read-only pod query without a cluster or network."""

import base64
import binascii
import contextlib
import io
import json
import pathlib
import subprocess
import sys
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
KUBETON = REPO_ROOT / "charts/ton-k8s-operator/kubeton"
CONFIG_PATH = "/var/ton-work/controller/global.config.json"
DATABASE_PATH = "/var/ton-work/controller/mytoncore/mytoncore.db"
BINARY_PATH = "/fixture/lite-client"
WALLET = "validator_wallet_001"
ACCOUNT = bytes([0, 124, 10, 13, 255] + list(range(27)))
RAW_ADDRESS = f"-1:{ACCOUNT.hex()}"
FRIENDLY_BODY = bytes([0x51, 0xFF]) + ACCOUNT
FRIENDLY_ADDRESS = base64.urlsafe_b64encode(
    FRIENDLY_BODY + binascii.crc_hqx(FRIENDLY_BODY, 0).to_bytes(2, "big")
).decode()
BOUNCEABLE_BODY = bytes([0x11, 0xFF]) + ACCOUNT
BOUNCEABLE_ADDRESS = base64.urlsafe_b64encode(
    BOUNCEABLE_BODY + binascii.crc_hqx(BOUNCEABLE_BODY, 0).to_bytes(2, "big")
).decode()


def account_response(state="active", balance=2500000000):
    return (
        "account state is (account\n"
        " storage:(account_storage last_trans_lt:123\n"
        f" balance:(currencies grams:(nanograms amount:(var_uint len:4 value:{balance})))\n"
        f" state:(account_{state})))\n"
    )


class StateQueryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # This only sources the local CLI and prints its embedded script. The
        # script itself runs below with every I/O boundary replaced by a mock.
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; tonnode_wallet_query_script', "_", str(KUBETON)],
            check=True,
            text=True,
            capture_output=True,
        )
        cls.script = compile(result.stdout, "kubeton-tonnode-wallet-query", "exec")

    def setUp(self):
        self.config = {
            "@type": "config.global",
            "liteservers": [
                {"ip": 2130706433, "port": 10000 + index, "id": {"@type": "pub.ed25519", "key": "AA=="}}
                for index in range(4)
            ],
            "validator": {"zero_state": {"root_hash": "F6OpKZKqvqeFp6CQmFomXNMfMj2EnaUSOXN+Mh+wVWk="}},
        }
        self.database = {
            "liteClient": {"appPath": BINARY_PATH},
            "walletsVersionList": {BOUNCEABLE_ADDRESS: "v1"},
        }
        self.responses = [(0, "account state is empty\n")]
        self.files = {CONFIG_PATH: self.config, DATABASE_PATH: self.database}
        self.which_result = BINARY_PATH
        self.calls = []
        self.reads = []

    def run_script(self, attempts=3, timeout=10):
        stdout = io.StringIO()
        stderr = io.StringIO()

        def read_text(path, *args, **kwargs):
            name = str(path)
            self.reads.append(name)
            if name not in self.files:
                raise FileNotFoundError(name)
            value = self.files[name]
            return json.dumps(value) if isinstance(value, dict) else value

        def run(command, *args, **kwargs):
            self.assertIsInstance(command, (list, tuple), "query must not execute a shell command string")
            self.assertEqual(command[0], BINARY_PATH)
            self.assertFalse(kwargs.get("shell", False), "lite-client must not run through a shell")
            self.assertIn("-C", command)
            self.assertEqual(command[command.index("-C") + 1], CONFIG_PATH)
            self.assertIn("-i", command)
            index = int(command[command.index("-i") + 1])
            self.assertGreaterEqual(index, 0)
            self.assertLess(index, len(self.config["liteservers"]))
            self.assertIn(f"getaccount {RAW_ADDRESS}", command)
            self.assertEqual(kwargs.get("timeout"), timeout)
            self.calls.append((list(command), kwargs))
            response = self.responses[min(len(self.calls) - 1, len(self.responses) - 1)]
            if response == "timeout":
                raise subprocess.TimeoutExpired(command, timeout)
            rc, output = response
            return subprocess.CompletedProcess(command, rc, output, "")

        def refuse_io(*args, **kwargs):
            raise AssertionError("query attempted an unexpected file access or filesystem mutation")

        code = 0
        # Path.read_text serves the two public JSON documents. Every other
        # open/write is forbidden, as are real child processes and sleeping.
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(pathlib.Path, "read_text", read_text))
            stack.enter_context(mock.patch.object(pathlib.Path, "open", side_effect=refuse_io))
            stack.enter_context(mock.patch("builtins.open", side_effect=refuse_io))
            stack.enter_context(mock.patch("os.open", side_effect=refuse_io))
            stack.enter_context(mock.patch("subprocess.run", side_effect=run))
            stack.enter_context(mock.patch("shutil.which", return_value=self.which_result))
            stack.enter_context(mock.patch("time.sleep", return_value=None))
            stack.enter_context(mock.patch.object(sys, "argv", ["wallet-query", WALLET, RAW_ADDRESS, str(attempts), str(timeout)]))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                exec(self.script, {"__name__": "__main__"})
            except SystemExit as error:
                code = error.code or 0
        self.assertTrue(set(self.reads).issubset({CONFIG_PATH, DATABASE_PATH}), self.reads)
        return code, stdout.getvalue(), stderr.getvalue()

    def assert_row(self, state, balance, version=None):
        code, stdout, stderr = self.run_script()
        self.assertEqual(code, 0, stderr)
        cells = stdout.strip().split("\t")
        self.assertEqual(len(cells), 6, stdout)
        self.assertEqual(cells[:3], [WALLET, state, balance])
        if version is not None:
            self.assertEqual(cells[3], version)
        self.assertEqual(cells[4:], ["-1", FRIENDLY_ADDRESS])
        return cells

    def assert_query_failed(self):
        code, stdout, stderr = self.run_script()
        self.assertNotEqual(code, 0, (stdout, stderr))
        self.assertEqual(stdout, "", "unsuccessful query must not fabricate a wallet row")
        return code, stderr

    def test_confirmed_empty_account(self):
        self.assert_row("empty", "0.000000000")
        self.assertEqual(len(self.calls), 1)

    def test_confirmed_empty_account_with_crlf(self):
        self.responses = [(0, "zerostate set to fixture\r\n  account state is empty\r\n")]
        self.assert_row("empty", "0.000000000")

    def test_explicit_account_none(self):
        self.responses = [(0, "account state is (account_none)\n")]
        self.assert_row("empty", "0.000000000")

    def test_active_balance(self):
        self.responses = [(0, account_response("active", 12345000000))]
        self.assert_row("active", "12.345000000")

    def test_active_zero_balance_does_not_mean_empty(self):
        self.responses = [(0, account_response("active", 0))]
        self.assert_row("active", "0.000000000")

    def test_funded_uninitialized_balance(self):
        self.responses = [(0, account_response("uninit", 2500000000))]
        self.assert_row("uninit", "2.500000000")

    def test_bare_uninitialized_constructor(self):
        self.responses = [(0, account_response("uninit", 2500000000).replace("(account_uninit)", "account_uninit"))]
        self.assert_row("uninit", "2.500000000")

    def test_bare_legacy_empty_constructor(self):
        self.responses = [(0, "account state is account_none\n")]
        self.assert_row("empty", "0.000000000")

    def test_transient_failure_with_one_configured_server(self):
        self.config["liteservers"] = self.config["liteservers"][:1]
        self.responses = [(1, "RPC request failed\n"), (0, "account state is empty\n")]
        self.assert_row("empty", "0.000000000")
        self.assertEqual(len(self.calls), 2)

    def test_frozen_balance(self):
        self.responses = [(0, account_response("frozen", 1))]
        self.assert_row("frozen", "0.000000001")

    def test_balance_uses_integer_precision(self):
        self.responses = [(0, account_response("active", 123456789012345678901))]
        self.assert_row("active", "123456789012.345678901")

    def test_transient_rpc_error_retries_another_server(self):
        self.responses = [(1, "RPC request failed\n"), (0, account_response("active", 4200000000))]
        self.assert_row("active", "4.200000000")
        self.assertEqual(len(self.calls), 2)
        indices = [command[command.index("-i") + 1] for command, _ in self.calls]
        self.assertEqual(len(set(indices)), 2, "retry must select another configured liteserver")

    def test_timeout_retries_another_server(self):
        self.responses = ["timeout", (0, "account state is empty\n")]
        self.assert_row("empty", "0.000000000")
        self.assertEqual(len(self.calls), 2)

    def test_stale_preferred_server_does_not_trap_retries(self):
        self.database["liteServers"] = [0]
        self.responses = [(1, "RPC request failed\n"), (0, "account state is empty\n")]
        self.assert_row("empty", "0.000000000")
        indices = [int(command[command.index("-i") + 1]) for command, _ in self.calls]
        self.assertEqual(indices[0], 0)
        self.assertNotEqual(indices[1], 0)

    def test_persistent_failure_is_bounded(self):
        self.responses = [(1, "RPC request failed\n")]
        self.assert_query_failed()
        self.assertEqual(len(self.calls), 3)
        indices = [command[command.index("-i") + 1] for command, _ in self.calls]
        self.assertEqual(len(set(indices)), 3)

    def test_failed_rc_cannot_confirm_empty(self):
        self.responses = [(1, "account state is empty\n")]
        self.assert_query_failed()

    def test_failed_rc_cannot_supply_balance(self):
        self.responses = [(1, account_response("active", 999000000000))]
        self.assert_query_failed()

    def test_empty_stdout_is_not_an_empty_account(self):
        self.responses = [(0, "")]
        self.assert_query_failed()

    def test_method_error_is_not_an_empty_account(self):
        self.responses = [(0, "account state is empty (cannot run method seqno)\n")]
        self.assert_query_failed()

    def test_state_without_balance_is_unavailable(self):
        self.responses = [(0, "account state is (account state:(account_active))\n")]
        self.assert_query_failed()

    def test_incomplete_account_record_is_unavailable(self):
        self.responses = [(0, account_response("active", 2500000000).rstrip()[:-1])]
        self.assert_query_failed()

    def test_negative_balance_is_unavailable(self):
        self.responses = [(0, account_response("active", -1))]
        self.assert_query_failed()

    def test_balance_without_state_is_unavailable(self):
        self.responses = [(0, "balance:(currencies grams:(nanograms amount:(var_uint value:2500000000)))\n")]
        self.assert_query_failed()

    def test_missing_config_is_unavailable_prerequisite(self):
        del self.files[CONFIG_PATH]
        code, _ = self.assert_query_failed()
        self.assertEqual(code, 78)
        self.assertEqual(self.calls, [])

    def test_missing_binary_is_unavailable_prerequisite(self):
        self.which_result = None
        code, _ = self.assert_query_failed()
        self.assertEqual(code, 78)
        self.assertEqual(self.calls, [])

    def test_version_uses_existing_public_database(self):
        self.assert_row("empty", "0.000000000", "v1")
        self.assertIn(DATABASE_PATH, self.reads)

    def test_untrusted_version_text_is_not_printed(self):
        self.database["walletsVersionList"][BOUNCEABLE_ADDRESS] = "v1\tactive\t999"
        self.assert_row("empty", "0.000000000", "unknown")

    def test_missing_database_can_use_binary_from_path(self):
        del self.files[DATABASE_PATH]
        self.assert_row("empty", "0.000000000", "unknown")


if __name__ == "__main__":
    unittest.main(verbosity=2)
