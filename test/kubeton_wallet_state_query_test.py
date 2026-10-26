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
import urllib.error
import urllib.parse
import urllib.request
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
ZERO_STATE_HASHES = {
    "mainnet": (
        "F6OpKZKqvqeFp6CQmFomXNMfMj2EnaUSOXN+Mh+wVWk=",
        "XplPz01CXAps5qeSWUtxcyBfdAo5zVb1N979KLSKD24=",
    ),
    "testnet": (
        "gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=",
        "Z+IKwYS54DmmJmesw/nAD5DzWadnOCMzee+kdgSYDOg=",
    ),
}


def account_response(state="active", balance=2500000000):
    return (
        "account state is (account\n"
        " storage:(account_storage last_trans_lt:123\n"
        f" balance:(currencies grams:(nanograms amount:(var_uint len:4 value:{balance})))\n"
        f" state:(account_{state})))\n"
    )


def http_account_response(state="uninitialized", balance="0"):
    return {
        "ok": True,
        "result": {
            "@type": "raw.fullAccountState",
            "state": state,
            "balance": balance,
            "code": "",
            "data": "",
            "frozen_hash": "",
            "extra_currencies": [],
            "block_id": {"@type": "ton.blockIdExt", "workchain": -1, "seqno": 12345678},
            "last_transaction_id": {
                "@type": "internal.transactionId",
                "lt": "0",
                "hash": base64.b64encode(bytes(32)).decode(),
            },
        },
    }


def shard_account_boc(account_none=True, with_crc=True, root_data=None):
    """Build an ordinary ShardAccount root and one 1-bit Account cell."""
    root_data = bytes(40) if root_data is None else root_data
    if len(root_data) != 40:
        raise ValueError("ShardAccount stores 256 hash bits plus 64 logical-time bits")
    # One-byte counters and offsets, two cells, one root, no absent cells,
    # 46 bytes of cell payload. Root: one reference and 320 data bits. Leaf:
    # one data bit (0=account_none, 1=nonempty account), followed by top-up bit.
    header = bytes.fromhex("b5ee9c72") + bytes([0x41 if with_crc else 0x01])
    header += bytes.fromhex("010201002e00")
    payload = bytes.fromhex("0150") + root_data + bytes([1, 0, 1, 0x40 if account_none else 0xC0])
    serialized = header + payload
    if with_crc:
        crc = 0xFFFFFFFF
        for byte in serialized:
            crc ^= byte
            for _ in range(8):
                crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
        serialized += (crc ^ 0xFFFFFFFF).to_bytes(4, "little")
    return base64.b64encode(serialized).decode()


def shard_account_response(boc=None):
    return {"ok": True, "result": {"@type": "tvm.cell", "bytes": boc or shard_account_boc()}}


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
        self.which_results = None
        self.calls = []
        self.reads = []
        self.http_calls = []
        self.http_response = urllib.error.URLError("HTTPS fixture unavailable")
        self.shard_response = shard_account_response()
        self.expected_http_network = None

    def use_public_network(self, network="mainnet"):
        root_hash, file_hash = ZERO_STATE_HASHES[network]
        self.config["validator"]["zero_state"] = {
            "workchain": -1,
            "shard": -9223372036854775808,
            "seqno": 0,
            "root_hash": root_hash,
            "file_hash": file_hash,
        }
        self.expected_http_network = network

    def run_script(self, attempts=3, timeout=45, mode=None, version="unknown"):
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
            self.assertIn("-v", command)
            self.assertGreaterEqual(int(command[command.index("-v") + 1]), 1,
                                    "lite-client must retain error logs for failure diagnostics")
            self.calls.append((list(command), kwargs))
            response = self.responses[min(len(self.calls) - 1, len(self.responses) - 1)]
            if response == "timeout":
                raise subprocess.TimeoutExpired(command, timeout)
            rc, output, *error = response
            return subprocess.CompletedProcess(command, rc, output, error[0] if error else "")

        def urlopen(request, *args, **kwargs):
            self.assertIsNotNone(self.expected_http_network, "private network must not query a public account API")
            if isinstance(request, urllib.request.Request):
                self.assertEqual(request.get_method(), "GET", "account lookup must remain read-only")
                self.assertIsNone(request.data)
                url = request.full_url
            else:
                url = request
            parsed = urllib.parse.urlparse(url)
            host = "toncenter.com" if self.expected_http_network == "mainnet" else "testnet.toncenter.com"
            self.assertEqual((parsed.scheme, parsed.netloc), ("https", host))
            self.assertIn(parsed.path, ("/api/v2/getAddressInformation", "/api/v2/getShardAccountCell"))
            self.assertEqual(urllib.parse.parse_qs(parsed.query).get("address"), [RAW_ADDRESS])
            if parsed.path.endswith("getShardAccountCell"):
                self.assertEqual(urllib.parse.parse_qs(parsed.query).get("seqno"), ["12345678"])
                payload = self.shard_response
            else:
                payload = self.http_response
            self.assertEqual(kwargs.get("timeout"), 10)
            self.http_calls.append(url)
            if isinstance(payload, Exception):
                raise payload
            payload = json.dumps(payload).encode() if isinstance(payload, dict) else payload
            response = io.BytesIO(payload)
            response.status = 200
            return response

        def refuse_io(*args, **kwargs):
            raise AssertionError("query attempted an unexpected file access or filesystem mutation")

        def which(candidate):
            if self.which_results is not None:
                return self.which_results.get(candidate)
            return self.which_result

        code = 0
        # Path.read_text serves the two public JSON documents. Every other
        # open/write is forbidden, as are real child processes and sleeping.
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(pathlib.Path, "read_text", read_text))
            stack.enter_context(mock.patch.object(pathlib.Path, "open", side_effect=refuse_io))
            stack.enter_context(mock.patch("builtins.open", side_effect=refuse_io))
            stack.enter_context(mock.patch("os.open", side_effect=refuse_io))
            stack.enter_context(mock.patch("subprocess.run", side_effect=run))
            stack.enter_context(mock.patch("urllib.request.urlopen", side_effect=urlopen))
            stack.enter_context(mock.patch("socket.create_connection", side_effect=refuse_io))
            stack.enter_context(mock.patch("shutil.which", side_effect=which))
            stack.enter_context(mock.patch("time.sleep", return_value=None))
            argv = ["wallet-query", WALLET, RAW_ADDRESS, str(attempts), str(timeout)]
            if mode is not None:
                argv += [mode, version]
            stack.enter_context(mock.patch.object(sys, "argv", argv))
            stack.enter_context(mock.patch.object(sys, "stdin", io.StringIO(json.dumps(self.config))))
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

    def test_stale_configured_binary_can_use_path_binary(self):
        self.database["liteClient"]["appPath"] = "/outdated/lite-client"
        self.which_results = {"lite-client": BINARY_PATH}
        self.assert_row("empty", "0.000000000")

    def test_missing_path_binary_can_use_known_ton_binary(self):
        self.database["liteClient"]["appPath"] = "/outdated/lite-client"
        self.which_results = {"/usr/bin/ton/lite-client/lite-client": BINARY_PATH}
        self.assert_row("empty", "0.000000000")

    def test_public_mainnet_uses_https_without_raw_tcp(self):
        self.use_public_network()
        self.http_response = http_account_response("active", "12345000000")
        self.assert_row("active", "12.345000000", "v1")
        self.assertEqual(len(self.http_calls), 1)
        self.assertEqual(self.calls, [])

    def test_public_testnet_uses_matching_https_host(self):
        self.use_public_network("testnet")
        self.http_response = http_account_response("active", "4200000000")
        self.assert_row("active", "4.200000000")
        self.assertEqual(len(self.http_calls), 1)
        self.assertEqual(self.calls, [])

    def test_https_escapes_unreachable_cached_tcp_servers(self):
        self.use_public_network()
        self.database["liteServers"] = [0, 1]
        self.responses = [(1, "", "connection refused")]
        self.http_response = http_account_response("active", "2500000000")
        self.assert_row("active", "2.500000000")
        self.assertEqual(self.calls, [], "reachable HTTPS must not wait for failing raw TCP endpoints")

    def test_https_success_does_not_require_lite_client_binary(self):
        self.use_public_network()
        self.which_result = None
        self.http_response = http_account_response("active", "1")
        self.assert_row("active", "0.000000001")
        self.assertEqual(self.calls, [])

    def test_https_confirmed_empty_account(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.assert_row("empty", "0.000000000")
        self.assertEqual(len(self.http_calls), 2, "v2 uninitialized state alone cannot establish account_none")
        self.assertIn("getShardAccountCell", self.http_calls[1])
        self.assertEqual(self.calls, [])

    def test_https_account_none_boc_without_optional_crc(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.shard_response = shard_account_response(shard_account_boc(with_crc=False))
        self.assert_row("empty", "0.000000000")

    def test_https_nonempty_account_cell_means_uninit(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.shard_response = shard_account_response(shard_account_boc(account_none=False))
        self.assert_row("uninit", "0.000000000")
        self.assertEqual(len(self.http_calls), 2)

    def test_https_bad_boc_crc_falls_back_to_raw_tcp(self):
        self.use_public_network()
        self.http_response = http_account_response()
        boc = bytearray(base64.b64decode(shard_account_boc()))
        boc[-1] ^= 1
        self.shard_response = shard_account_response(base64.b64encode(boc).decode())
        self.responses = [(0, account_response("active", 7500000000))]
        self.assert_row("active", "7.500000000")
        self.assertEqual(len(self.calls), 1)

    def test_https_bad_boc_cannot_mean_empty(self):
        for boc in ("not-a-boc", base64.b64encode(b"invalid bytes").decode(), shard_account_boc()[:-4]):
            with self.subTest(boc=boc):
                self.setUp()
                self.use_public_network()
                self.http_response = http_account_response()
                self.shard_response = shard_account_response(boc)
                self.responses = [(1, "", "TCP unavailable")]
                self.assert_query_failed()

    def test_https_nonzero_shard_transaction_fields_cannot_confirm_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.shard_response = shard_account_response(shard_account_boc(root_data=bytes([1]) + bytes(39)))
        self.responses = [(1, "", "TCP unavailable")]
        self.assert_query_failed()

    def test_https_second_lookup_failure_cannot_confirm_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.shard_response = urllib.error.URLError("account cell unavailable")
        self.responses = [(1, "", "TCP unavailable")]
        self.assert_query_failed()
        self.assertEqual(len(self.http_calls), 2)

    def test_https_second_api_error_cannot_confirm_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.shard_response = {"ok": False, "error": "cannot load pinned block", "code": 500}
        self.responses = [(1, "", "TCP unavailable")]
        self.assert_query_failed()

    def test_https_missing_pinned_block_falls_back_to_raw_tcp(self):
        self.use_public_network()
        self.http_response = http_account_response()
        del self.http_response["result"]["block_id"]["seqno"]
        self.responses = [(0, account_response("active", 2500000000))]
        self.assert_row("active", "2.500000000")
        self.assertEqual(len(self.calls), 1)

    def test_https_funded_uninitialized_account(self):
        self.use_public_network()
        self.http_response = http_account_response("uninitialized", "2500000000")
        self.assert_row("uninit", "2.500000000")
        self.assertEqual(self.calls, [])

    def test_https_frozen_account(self):
        self.use_public_network()
        self.http_response = http_account_response("frozen", "1")
        self.http_response["result"]["frozen_hash"] = base64.b64encode(bytes([1] * 32)).decode()
        self.assert_row("frozen", "0.000000001")

    def test_https_zero_balance_active_account_is_not_empty(self):
        self.use_public_network()
        self.http_response = http_account_response("active", "0")
        self.assert_row("active", "0.000000000")

    def test_https_zero_balance_with_transaction_history_is_not_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.http_response["result"]["last_transaction_id"]["lt"] = "123"
        self.assert_row("uninit", "0.000000000")

    def test_https_zero_balance_with_nonzero_transaction_hash_is_not_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.http_response["result"]["last_transaction_id"]["hash"] = base64.b64encode(bytes([1] * 32)).decode()
        self.assert_row("uninit", "0.000000000")

    def test_https_zero_balance_without_transaction_hash_is_not_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        del self.http_response["result"]["last_transaction_id"]["hash"]
        self.assert_row("uninit", "0.000000000")

    def test_https_zero_balance_with_contract_data_is_not_empty(self):
        for field in ("code", "data", "frozen_hash"):
            with self.subTest(field=field):
                self.setUp()
                self.use_public_network()
                self.http_response = http_account_response()
                self.http_response["result"][field] = "nonempty-public-account-data"
                self.assert_row("uninit", "0.000000000")

    def test_https_zero_ton_with_extra_currency_is_not_empty(self):
        self.use_public_network()
        self.http_response = http_account_response()
        self.http_response["result"]["extra_currencies"] = [{"id": 1, "amount": "100"}]
        self.assert_row("uninit", "0.000000000")

    def test_https_failure_falls_back_to_raw_tcp(self):
        self.use_public_network()
        self.responses = [(0, account_response("active", 7500000000))]
        self.assert_row("active", "7.500000000")
        self.assertEqual(len(self.http_calls), 1)
        self.assertEqual(len(self.calls), 1)

    def test_https_429_falls_back_to_raw_tcp(self):
        self.use_public_network()
        self.http_response = urllib.error.HTTPError("https://toncenter.com", 429, "Too Many Requests", {}, None)
        self.responses = [(0, account_response("active", 7500000000))]
        self.assert_row("active", "7.500000000")
        self.assertEqual(len(self.calls), 1)

    def test_https_invalid_json_is_not_empty(self):
        self.use_public_network()
        self.http_response = b'{"ok":true,"result":'
        self.responses = [(1, "", "TCP unavailable")]
        self.assert_query_failed()

    def test_https_api_failure_is_not_empty(self):
        self.use_public_network()
        self.http_response = {"ok": False, "error": "LITE_SERVER_UNKNOWN: cannot run query", "code": 500}
        self.responses = [(1, "", "TCP unavailable")]
        self.assert_query_failed()

    def test_https_malformed_account_is_not_empty(self):
        for changes in ({"state": "unknown"}, {"balance": "not-a-number"}, {"balance": "-1"}, {"balance": True}):
            with self.subTest(changes=changes):
                self.setUp()
                self.use_public_network()
                self.http_response = http_account_response()
                self.http_response["result"].update(changes)
                self.responses = [(1, "", "TCP unavailable")]
                self.assert_query_failed()

    def test_partial_public_zero_identity_does_not_enable_https(self):
        # The baseline fixture deliberately has a recognized root hash but no
        # matching file hash or complete identity tuple. It is not mainnet.
        self.assert_row("empty", "0.000000000")
        self.assertEqual(self.http_calls, [])

    def test_private_zero_identity_does_not_enable_public_https(self):
        self.use_public_network()
        self.config["validator"]["zero_state"]["file_hash"] = base64.b64encode(bytes([9] * 32)).decode()
        self.expected_http_network = None
        self.assert_row("empty", "0.000000000")
        self.assertEqual(self.http_calls, [])

    def test_raw_failure_retains_server_and_error_diagnostics(self):
        self.responses = [(1, "", "connection refused by configured liteserver")]
        _, stderr = self.assert_query_failed()
        self.assertTrue(stderr.strip(), "RPC failure must provide a useful diagnostic")
        self.assertIn("connection refused", stderr)

    def test_timeout_failure_retains_diagnostics(self):
        self.responses = ["timeout"]
        _, stderr = self.assert_query_failed()
        self.assertRegex(stderr.lower(), r"timeout|timed out")

    def test_cached_server_order_is_stable_between_runs(self):
        self.database["liteServers"] = [3, 1]
        self.responses = [(1, "", "connection refused")]
        self.assert_query_failed()
        first = [command[command.index("-i") + 1] for command, _ in self.calls]
        self.calls = []
        self.assert_query_failed()
        second = [command[command.index("-i") + 1] for command, _ in self.calls]
        self.assertEqual(first, second, "querying the same configured server pool must not pick random subsets")

    def test_https_only_mode_uses_supplied_config_without_pod_files(self):
        self.use_public_network()
        self.http_response = http_account_response("active", "2500000000")
        self.which_result = None
        code, stdout, stderr = self.run_script(mode="--https-only", version="v4r2")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(stdout.strip().split("\t"),
                         [WALLET, "active", "2.500000000", "v4r2", "-1", FRIENDLY_ADDRESS])
        self.assertEqual(self.reads, [], "host HTTPS lookup must use stdin metadata, not local pod paths")
        self.assertEqual(self.calls, [])

    def test_rpc_only_mode_does_not_repeat_public_https(self):
        self.use_public_network()
        self.http_response = http_account_response("active", "999000000000")
        self.responses = [(0, account_response("active", 7500000000))]
        code, stdout, stderr = self.run_script(mode="--rpc-only")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(stdout.strip().split("\t")[1:3], ["active", "7.500000000"])
        self.assertEqual(self.http_calls, [])


if __name__ == "__main__":
    unittest.main()
