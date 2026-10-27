#!/usr/bin/env python3
"""Run the production collection verifier against synthetic, public fixtures."""

import base64
import binascii
import contextlib
import copy
import fcntl
import hashlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
KUBETON = REPO_ROOT / "charts/ton-k8s-operator/kubeton"
SOURCE = "-1:" + "01" * 32
DESTINATION = "0:" + "02" * 32
OTHER = "-1:" + "03" * 32
MARKER = "kubeton-collect:00112233445566778899aabbccddeeff"
TRANSACTION_HASH = base64.b64encode(bytes(range(32))).decode()
MESSAGE_HASH = base64.b64encode(bytes(reversed(range(32)))).decode()
BALANCE = 756407580
PAID = 712900000


def friendly(raw, tag=0x51):
    workchain, account = raw.split(":")
    body = bytes([tag, int(workchain) & 255]) + bytes.fromhex(account)
    checksum = binascii.crc_hqx(body, 0).to_bytes(2, "big")
    return base64.urlsafe_b64encode(body + checksum).decode()


def transaction_boc(account='0:' + '02' * 32, lt=112730000000003,
                    source='-1:' + '01' * 32, amount=100000000,
                    comment='kubeton-collect:' + 'ab' * 16,
                    aborted=False, compute_success=True, bounced=False,
                    uninit=False, bounce=True, skip_reason=0, credit=True):
    def uint(value, width):
        return format(value, '0%db' % width) if width else ''

    def grams(value):
        size = (value.bit_length() + 7) // 8
        return uint(size, 4) + uint(value, size * 8)

    def addr(value):
        wc, digest = value.split(':')
        return '100' + uint(int(wc) & 255, 8) + uint(int(digest, 16), 256)

    def cell(bits, refs=()):
        return [bits, list(refs)]

    body = cell(uint(0, 32) + ''.join(uint(byte, 8) for byte in comment.encode()))
    # Complete internal Message with a referenced ordinary comment body.
    incoming = cell('01' + str(int(bounce)) + str(int(bounced)) + addr(source) + addr(account)
                    + grams(amount) + '0' + grams(0) + grams(0)
                    + uint(lt - 1, 64) + uint(1793119246, 32) + '01', [body])
    messages = cell('10', [incoming])  # present incoming, empty out-message map
    update = cell(uint(0x72, 8) + uint(0, 512))
    vm = cell(uint(0, 3) + uint(0, 3) + '0' + uint(0, 8) + uint(0, 32)
              + '0' + uint(1, 32) + uint(0, 512))
    # trans_ord, credit_first, no storage, present credit, no due fees,
    # positive credit, no extra currencies, successful VM with a separate
    # execution-details reference, no action, aborted?, no bounce, not destroyed.
    credit_phase = '1' + '0' + grams(amount) + '0' if credit else '0'
    compute_phase = ('0' + uint(skip_reason, 2) if uninit else
                     '1' + str(int(compute_success)) + '00' + grams(0))
    description = cell('0000' + '1' + '0' + credit_phase + compute_phase
                       + '0' + str(int(aborted)) + '00', [] if uninit else [vm])
    root = cell(uint(7, 4) + uint(int(account.split(':')[1], 16), 256)
                + uint(lt, 64) + uint(0, 256) + uint(0, 64)
                + uint(1793119246, 32) + uint(0, 15) + ('0000' if uninit else '1010')
                + grams(0) + '0', [messages, update, description])
    cells = []

    def visit(value):
        cells.append(value)
        for ref in value[1]:
            visit(ref)

    visit(root)
    positions = {id(value): index for index, value in enumerate(cells)}
    payload = bytearray()
    for bits, refs in cells:
        length = len(bits)
        padded = bits if length % 8 == 0 else bits + '1' + '0' * (7 - length % 8)
        data = int(padded, 2).to_bytes(len(padded) // 8, 'big') if padded else b''
        payload.extend(bytes([len(refs), length // 8 + (length + 7) // 8]))
        payload.extend(data)
        payload.extend(positions[id(ref)] for ref in refs)
    offset_size = max(1, (len(payload).bit_length() + 7) // 8)
    header = (bytes.fromhex('b5ee9c72') + bytes([1, offset_size, len(cells), 1, 0])
              + len(payload).to_bytes(offset_size, 'big') + b'\0')
    return base64.b64encode(header + payload).decode()



def receipt_response(value=PAID):
    # This is the destination history. A mode-160 transfer can delete the
    # source account, so successful collection must not require source seqno.
    return {
        "ok": True,
        "result": [{
            "@type": "raw.transaction",
            "utime": 1793119245,
            "data": transaction_boc(account=DESTINATION, source=SOURCE, amount=max(0, value), comment=MARKER),
            "transaction_id": {"lt": "112730000000003", "hash": TRANSACTION_HASH},
            "in_msg": {
                "@type": "raw.message",
                "source": friendly(SOURCE),
                "destination": friendly(DESTINATION, 0x11),
                "value": str(value),
                "hash": MESSAGE_HASH,
                "created_lt": "112730000000001",
                "body_hash": MESSAGE_HASH,
                "message": MARKER,
                "msg_data": {
                    "@type": "msg.dataText",
                    "text": base64.b64encode(MARKER.encode()).decode(),
                },
            },
            "out_msgs": [],
        }],
    }


def comment_boc(comment, split=True, crc=True, cycle=False):
    """Serialize a synthetic text-comment cell, including optional SnakeData."""
    encoded = comment.encode()
    root = bytes(4) + (encoded[:36] if split else encoded)
    tail = encoded[36:] if split else b""
    payload = bytes([1 if tail else 0, len(root) * 2]) + root
    if tail:
        payload += bytes([0 if cycle else 1, 0, len(tail) * 2]) + tail
    count = 2 if tail else 1
    header = bytes.fromhex("b5ee9c72") + bytes([0x41 if crc else 1, 1, count, 1, 0, len(payload), 0])
    data = header + payload
    if crc:
        checksum = 0xFFFFFFFF
        for byte in data:
            checksum ^= byte
            for _ in range(8):
                checksum = (checksum >> 1) ^ (0x82F63B78 if checksum & 1 else 0)
        data += (checksum ^ 0xFFFFFFFF).to_bytes(4, "little")
    return base64.b64encode(data).decode()


class CollectReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        emitted = subprocess.run(
            ["bash", "-c", 'source "$1"; tonnode_wallet_collect_script', "_", str(KUBETON)],
            capture_output=True, text=True, check=True,
        )
        cls.namespace = {"__name__": "kubeton_collect_under_test"}
        exec(compile(emitted.stdout, "kubeton-collect", "exec"), cls.namespace)

    def verify(self, response, amount=None):
        return self.namespace["parse_receipt"](
            response, SOURCE, DESTINATION, amount, BALANCE, MARKER,
        )

    def assert_no_receipt(self, response, amount=None):
        try:
            result = self.verify(response, amount)
        except (ValueError, TypeError):
            return
        self.assertIsNone(result, "unrelated or malformed payment was counted as collection")

    def test_alld_is_proved_from_destination_after_source_deletion(self):
        self.assertEqual(self.verify(receipt_response()),
                         ("112730000000003", TRANSACTION_HASH, PAID))

    def test_numeric_amount_requires_exact_nano_amount(self):
        self.assertEqual(self.verify(receipt_response(250000000), 250000000),
                         ("112730000000003", TRANSACTION_HASH, 250000000))
        self.assert_no_receipt(receipt_response(250000001), 250000000)
        self.assert_no_receipt(receipt_response(249999999), 250000000)

    def test_empty_destination_history_is_not_success(self):
        self.assert_no_receipt({"ok": True, "result": []})

    def test_marker_is_exact_and_cannot_match_an_older_collection(self):
        for marker in ("", "other operation", MARKER + "suffix", "prefix" + MARKER,
                       "kubeton-collect:ffeeddccbbaa99887766554433221100"):
            with self.subTest(marker=marker):
                response = receipt_response()
                message = response["result"][0]["in_msg"]
                message["message"] = marker
                message["msg_data"]["text"] = base64.b64encode(marker.encode()).decode()
                self.assert_no_receipt(response)

    def test_comment_without_expected_source_is_not_success(self):
        response = receipt_response()
        response["result"][0]["in_msg"]["source"] = OTHER
        self.assert_no_receipt(response)

    def test_comment_without_expected_destination_is_not_success(self):
        response = receipt_response()
        response["result"][0]["in_msg"]["destination"] = OTHER
        self.assert_no_receipt(response)

    def test_conflicting_text_comment_fields_do_not_prove_the_transfer(self):
        response = receipt_response()
        response["result"][0]["in_msg"]["msg_data"]["text"] = base64.b64encode(b"another payment").decode()
        self.assert_no_receipt(response)

    def test_base64_text_comment_is_decoded_before_matching(self):
        response = receipt_response()
        del response["result"][0]["in_msg"]["message"]
        self.assertEqual(self.verify(response), ("112730000000003", TRANSACTION_HASH, PAID))

    def test_raw_boc_message_text_cannot_impersonate_a_plain_comment(self):
        response = receipt_response()
        response["result"][0]["in_msg"]["msg_data"] = {
            "@type": "msg.dataRaw", "body": base64.b64encode(MARKER.encode()).decode(),
        }
        self.assert_no_receipt(response)

    def test_raw_comment_boc_is_decoded_including_snake_cells(self):
        for split in (False, True):
            for crc in (False, True):
                with self.subTest(split=split, crc=crc):
                    response = receipt_response()
                    response["result"][0]["in_msg"]["msg_data"] = {
                        "@type": "msg.dataRaw", "body": comment_boc(MARKER, split=split, crc=crc),
                    }
                    response["result"][0]["in_msg"]["message"] = base64.b64encode(bytes(4) + MARKER.encode()).decode()
                    self.assertEqual(self.verify(response), ("112730000000003", TRANSACTION_HASH, PAID))

    def test_corrupt_raw_comment_checksum_is_not_accepted(self):
        response = receipt_response()
        data = bytearray(base64.b64decode(comment_boc(MARKER)))
        data[-1] ^= 1
        response["result"][0]["in_msg"]["msg_data"] = {
            "@type": "msg.dataRaw", "body": base64.b64encode(data).decode(),
        }
        self.assert_no_receipt(response)

    def test_cyclic_snake_comment_is_not_accepted(self):
        response = receipt_response()
        response["result"][0]["in_msg"]["msg_data"] = {
            "@type": "msg.dataRaw", "body": comment_boc(MARKER, cycle=True),
        }
        self.assert_no_receipt(response)

    def test_real_fift_comment_snake_fixture_is_decoded(self):
        # Built offline by TON's actual TonUtil.simple-transfer-body, also
        # checked against wallet.fif -C. It contains 36+12 comment bytes.
        encoded = "te6cckEBAgEAOQABUAAAAABrdWJldG9uLWNvbGxlY3Q6MDEyMzQ1Njc4OWFiY2RlZjAxMjMBABg0NTY3ODlhYmNkZWZnIsS9"
        self.assertEqual(self.namespace["comment_body"](encoded),
                         "kubeton-collect:0123456789abcdef0123456789abcdef")

    def test_alld_requires_positive_payment_within_the_verified_balance(self):
        for value in (0, -1, BALANCE + 1):
            with self.subTest(value=value):
                self.assert_no_receipt(receipt_response(value))

    def test_transport_and_json_errors_are_not_success(self):
        for response in ({"ok": False, "result": receipt_response()["result"]},
                         {"ok": True, "result": {}}, {}, None, []):
            with self.subTest(response=response):
                self.assert_no_receipt(response)

    def test_malformed_transaction_identity_is_not_success(self):
        for key, value in (("lt", "not a logical time"), ("lt", "0"),
                           ("hash", "not a hash"), ("hash", "")):
            with self.subTest(key=key, value=value):
                response = receipt_response()
                response["result"][0]["transaction_id"][key] = value
                self.assert_no_receipt(response)

    def test_malformed_message_amount_is_not_success(self):
        for value in ("unknown", "1.2", "1e9", None, True):
            with self.subTest(value=value):
                response = receipt_response()
                response["result"][0]["in_msg"]["value"] = value
                self.assert_no_receipt(response)

    def test_corrupt_friendly_addresses_are_not_normalized(self):
        for field in ("source", "destination"):
            response = receipt_response()
            address = response["result"][0]["in_msg"][field]
            decoded = bytearray(base64.urlsafe_b64decode(address))
            decoded[-1] ^= 1
            response["result"][0]["in_msg"][field] = base64.urlsafe_b64encode(decoded).decode()
            with self.subTest(field=field):
                self.assert_no_receipt(response)

    def test_unrelated_receipt_before_matching_receipt_is_skipped(self):
        response = receipt_response()
        unrelated = copy.deepcopy(response["result"][0])
        unrelated["in_msg"]["message"] = "unrelated"
        unrelated["in_msg"]["msg_data"]["text"] = base64.b64encode(b"unrelated").decode()
        response["result"].insert(0, unrelated)
        self.assertEqual(self.verify(response), ("112730000000003", TRANSACTION_HASH, PAID))

    def test_aborted_destination_transaction_does_not_prove_payment(self):
        for update in ({"aborted": True}, {"description": {"aborted": True}}):
            with self.subTest(update=update):
                response = receipt_response()
                response["result"][0].update(update)
                self.assert_no_receipt(response)

    def test_bounced_payment_back_to_source_is_not_received_collection(self):
        response = receipt_response()
        response["result"][0]["out_msgs"] = [{
            "source": DESTINATION, "destination": SOURCE, "value": str(PAID - 1),
            "bounced": True,
        }]
        self.assert_no_receipt(response)

    def test_missing_transaction_boc_cannot_prove_successful_credit(self):
        response = receipt_response()
        del response["result"][0]["data"]
        self.assert_no_receipt(response)

    def test_transaction_boc_must_prove_compute_success_and_no_abort_or_bounce(self):
        for overrides in ({"aborted": True}, {"compute_success": False}, {"bounced": True}):
            with self.subTest(overrides=overrides):
                response = receipt_response()
                response["result"][0]["data"] = transaction_boc(
                    account=DESTINATION, source=SOURCE, amount=PAID, comment=MARKER, **overrides,
                )
                self.assert_no_receipt(response)

    def test_transaction_boc_must_belong_to_the_reported_account_and_logical_time(self):
        for overrides in ({"account": OTHER}, {"lt": 112730000000004}):
            with self.subTest(overrides=overrides):
                response = receipt_response()
                response["result"][0]["data"] = transaction_boc(**overrides)
                self.assert_no_receipt(response)

    def test_undeployed_receiver_can_receive_a_nonbounceable_collection(self):
        encoded = transaction_boc(account=DESTINATION, source=SOURCE, amount=PAID,
                                  comment=MARKER, uninit=True, bounce=False, aborted=True)
        for metadata in ({}, {"aborted": True}, {"description": {"aborted": True}}):
            with self.subTest(metadata=metadata):
                response = receipt_response()
                response["result"][0]["data"] = encoded
                response["result"][0].update(metadata)
                self.assertEqual(self.verify(response), ("112730000000003", TRANSACTION_HASH, PAID))

    def test_undeployed_receiver_compatibility_requires_positive_credit_and_no_bounce(self):
        for overrides in ({"bounce": True}, {"skip_reason": 1}, {"skip_reason": 2},
                          {"credit": False}, {"bounced": True}):
            with self.subTest(overrides=overrides):
                arguments = {"account": DESTINATION, "source": SOURCE, "amount": PAID,
                             "comment": MARKER, "uninit": True, "bounce": False, "aborted": True}
                arguments.update(overrides)
                response = receipt_response()
                response["result"][0]["data"] = transaction_boc(**arguments)
                response["result"][0]["aborted"] = True
                self.assert_no_receipt(response)

    def test_undeployed_credit_compatibility_does_not_weaken_active_wallet_proof(self):
        encoded = transaction_boc(account=DESTINATION, source=SOURCE, amount=PAID,
                                  comment=MARKER, uninit=True, bounce=False, aborted=True)
        proof = self.namespace["transaction_succeeded"]
        self.assertTrue(proof(encoded, DESTINATION, "112730000000003", allow_uninit=True))
        self.assertFalse(proof(encoded, DESTINATION, "112730000000003", allow_uninit=False))
        for overrides in ({"aborted": True}, {"compute_success": False}):
            with self.subTest(overrides=overrides):
                active = transaction_boc(account=DESTINATION, source=SOURCE, amount=PAID,
                                         comment=MARKER, **overrides)
                self.assertFalse(proof(active, DESTINATION, "112730000000003", allow_uninit=True))


class CollectDriverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        emitted = subprocess.run(
            ["bash", "-c", 'source "$1"; tonnode_wallet_collect_script', "_", str(KUBETON)],
            capture_output=True, text=True, check=True,
        )
        cls.script = compile(emitted.stdout, "kubeton-collect", "exec")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.namespace = {"__name__": "kubeton_collect_under_test"}
        exec(self.script, self.namespace)
        self.journal_root = self.root / "journals"
        wallet_root = self.root / "wallets"
        wallet_root.mkdir()
        (wallet_root / "validator_wallet_001.addr").write_bytes(
            bytes.fromhex(SOURCE.split(":")[1]) + (-1).to_bytes(4, "big", signed=True)
        )
        self.config = self.root / "global.config.json"
        self.config.write_text(json.dumps({"validator": {"zero_state": {
            "workchain": -1, "shard": -9223372036854775808, "seqno": 0,
            "root_hash": "F6OpKZKqvqeFp6CQmFomXNMfMj2EnaUSOXN+Mh+wVWk=",
            "file_hash": "XplPz01CXAps5qeSWUtxcyBfdAo5zVb1N979KLSKD24=",
        }}}))
        active_root = self.root / "active"
        for name in ("fift/Fift.fif", "smartcont/wallet.fif"):
            path = active_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic include file")
        self.namespace.update(JOURNAL_ROOT=self.journal_root, WALLET_ROOT=wallet_root,
                              CONFIG_PATH=self.config, ACTIVE_ROOT=active_root)
        self.journal = self.journal_root / (hashlib.sha256(("mainnet:" + SOURCE).encode()).hexdigest() + ".json")
        self.commands = []
        self.requests = []
        self.clock = 100.0
        self.receipt_mode = "paid"
        self.command_rc = 1
        self.command_timeout = False
        self.command_output = "Failed to send boc: account state unavailable\nWaitTransaction error: Can't get seqno\n"
        self.http_errors = []
        self.deadlines = []

    def run_driver(self, amount="alld", balance="0.756407580", destination=DESTINATION,
                   source=SOURCE, network="mainnet", confirm_timeout=5, inspect=False, expect=None):
        stdout, stderr = io.StringIO(), io.StringIO()

        def run(command, environment, timeout):
            self.assertEqual(command[:2], ["mytonctrl", "--cmd"])
            self.assertEqual(timeout, 2)
            self.assertIn(str(self.root / "active/fift"), environment["FIFTPATH"])
            tokens = command[2].split()
            self.assertEqual(tokens[:4], ["mg", "validator_wallet_001", destination, amount])
            self.assertEqual(tokens[4], "-C")
            self.assertEqual(len(tokens), 6, "exactly one new payment may be submitted")
            state = json.loads(self.journal.read_text())
            self.assertEqual(state["status"], "pending", "intent must be durable before broadcasting")
            self.assertEqual(state["marker"], tokens[5], "broadcast must use the persisted payment identifier")
            self.commands.append(command)
            if self.command_timeout:
                return 124, self.command_output
            return self.command_rc, self.command_output

        def urlopen(request, *args, **kwargs):
            self.assertEqual(request.get_method(), "GET", "confirmation cannot broadcast another payment")
            self.assertIsNone(request.data)
            parsed = urllib.parse.urlparse(request.full_url)
            self.assertEqual((parsed.scheme, parsed.netloc, parsed.path),
                             ("https", "toncenter.com", "/api/v2/getTransactions"))
            self.assertEqual(urllib.parse.parse_qs(parsed.query).get("address"), [DESTINATION])
            self.assertEqual(urllib.parse.parse_qs(parsed.query).get("limit"), ["100"])
            self.assertGreater(kwargs.get("timeout", 0), 0)
            self.assertLessEqual(kwargs["timeout"], confirm_timeout)
            self.requests.append((self.clock, request.full_url))
            if self.http_errors:
                error = self.http_errors.pop(0)
                if error is not None:
                    raise error
            if self.receipt_mode == "network-error":
                raise urllib.error.URLError("Synthetic confirmation network failure")
            if self.receipt_mode == "empty":
                payload = {"ok": True, "result": []}
            else:
                payload = receipt_response(250000000 if amount == "0.25" else PAID)
                state = json.loads(self.journal.read_text())
                message = payload["result"][0]["in_msg"]
                marker = state["marker"]
                if self.receipt_mode == "wrong-marker":
                    marker = "kubeton-collect:ffffffffffffffffffffffffffffffff"
                message["message"] = marker
                message["msg_data"]["text"] = base64.b64encode(marker.encode()).decode()
                payload["result"][0]["data"] = transaction_boc(
                    account=DESTINATION, source=SOURCE, amount=int(message["value"]), comment=marker,
                )
                if self.receipt_mode == "wrong-source":
                    message["source"] = OTHER
                if self.receipt_mode == "wrong-destination":
                    message["destination"] = OTHER
                if self.receipt_mode == "wrong-value":
                    message["value"] = "249999999"
            response = io.BytesIO(json.dumps(payload).encode())
            response.status = 200
            return response

        def sleep(delay):
            self.assertGreaterEqual(delay, 0)
            self.clock += delay + 0.001

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(self.namespace, run_mytonctrl=mock.Mock(side_effect=run)))
            stack.enter_context(mock.patch("subprocess.Popen", side_effect=AssertionError("unexpected child process")))
            stack.enter_context(mock.patch("urllib.request.urlopen", side_effect=urlopen))
            stack.enter_context(mock.patch("socket.create_connection", side_effect=AssertionError("unexpected network operation")))
            stack.enter_context(mock.patch("shutil.which", return_value="/fixture/mytonctrl"))
            stack.enter_context(mock.patch("time.monotonic", side_effect=lambda: self.clock))
            stack.enter_context(mock.patch("time.sleep", side_effect=sleep))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                arguments = [
                    "validator_wallet_001", source, destination, amount, network, balance, "2", str(confirm_timeout),
                ]
                prefix = ["--inspect"] if inspect else (["--expect", expect] if expect else [])
                rc = self.namespace["main"](prefix + arguments)
            except (OSError, ValueError, TypeError, KeyError) as error:
                rc = 1
                print("Error: " + str(error), file=stderr)
        return rc, stdout.getvalue(), stderr.getvalue()

    def assert_pending(self):
        self.assertEqual(json.loads(self.journal.read_text())["status"], "pending")

    def test_deleted_wallet_receipt_overrides_mytonctrl_timeout(self):
        rc, stdout, stderr = self.run_driver()
        self.assertEqual(rc, 0, stderr)
        self.assertIn("confirmed on chain", stdout)
        self.assertNotIn("Can't get seqno", stdout + stderr)
        self.assertEqual(len(self.commands), 1)
        state = json.loads(self.journal.read_text())
        self.assertEqual(state["status"], "complete")
        self.assertEqual(state["receipt"]["value"], str(PAID))

    def test_numeric_collect_confirms_exact_payment(self):
        rc, stdout, stderr = self.run_driver(amount="0.25")
        self.assertEqual(rc, 0, stderr)
        self.assertIn("0.250000000", stdout)
        self.assertEqual(len(self.commands), 1)

    def test_console_success_without_receipt_is_not_paid(self):
        self.command_rc, self.command_output, self.receipt_mode = 0, "MoveCoins - OK", "empty"
        rc, stdout, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertNotIn("confirmed on chain", stdout)
        self.assertIn("MoveCoins - OK", stderr)
        self.assert_pending()
        self.assertEqual(len(self.commands), 1)

    def test_real_rejection_keeps_diagnostics_and_does_not_resign(self):
        self.command_rc = 7
        self.command_output = "Error: signing key does not match wallet address"
        self.receipt_mode = "empty"
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn(self.command_output, stderr)
        self.assertEqual(len(self.commands), 1)
        self.assert_pending()

    def test_same_pending_collect_only_verifies_its_existing_intent(self):
        self.receipt_mode = "empty"
        self.assertNotEqual(self.run_driver()[0], 0)
        previous_marker = json.loads(self.journal.read_text())["marker"]
        self.receipt_mode = "paid"
        rc, stdout, stderr = self.run_driver()
        self.assertEqual(rc, 0, stderr)
        self.assertIn("previous collection", stdout)
        self.assertEqual(len(self.commands), 1, "pending verification signed a second transfer")
        self.assertEqual(json.loads(self.journal.read_text())["marker"], previous_marker)

    def test_deleted_pending_wallet_can_verify_with_zero_live_balance(self):
        self.receipt_mode = "empty"
        self.assertNotEqual(self.run_driver()[0], 0)
        self.receipt_mode = "paid"
        rc, stdout, stderr = self.run_driver(balance="0")
        self.assertEqual(rc, 0, stderr)
        self.assertIn("confirmed on chain", stdout)
        self.assertEqual(len(self.commands), 1)

    def test_different_pending_plan_cannot_start_another_payment(self):
        self.receipt_mode = "empty"
        self.assertNotEqual(self.run_driver()[0], 0)
        before = self.journal.read_bytes()
        rc, _, stderr = self.run_driver(amount="0.25")
        self.assertNotEqual(rc, 0)
        self.assertIn("pending", stderr)
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.journal.read_bytes(), before)

    def test_http_failure_preserves_pending_intent_without_resubmission(self):
        self.receipt_mode = "network-error"
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn("Synthetic confirmation network failure", stderr)
        self.assertEqual(len(self.commands), 1)
        self.assert_pending()

    def test_rate_limited_confirmation_recovers_without_resigning(self):
        failure = urllib.error.HTTPError("https://toncenter.com", 429, "rate limit", {"Retry-After": "0"}, io.BytesIO(b""))
        self.addCleanup(failure.close)
        self.http_errors = [failure]
        rc, stdout, stderr = self.run_driver()
        self.assertEqual(rc, 0, stderr)
        self.assertIn("confirmed on chain", stdout)
        self.assertEqual(len(self.commands), 1)
        self.assertGreaterEqual(len(self.requests), 2)
        self.assertGreaterEqual(self.requests[1][0] - self.requests[0][0], 1)

    def test_unrelated_destination_payment_cannot_override_cli_failure(self):
        for mode in ("wrong-marker", "wrong-source", "wrong-destination"):
            with self.subTest(mode=mode):
                if self.journal.exists():
                    self.journal.unlink()
                self.receipt_mode = mode
                before = len(self.commands)
                rc, stdout, stderr = self.run_driver()
                self.assertNotEqual(rc, 0)
                self.assertNotIn("confirmed on chain", stdout)
                self.assertIn("unconfirmed", stderr)
                self.assertEqual(len(self.commands), before + 1)
                self.assert_pending()

    def test_changed_local_source_address_aborts_before_broadcast(self):
        rc, _, stderr = self.run_driver(source=OTHER)
        self.assertNotEqual(rc, 0)
        self.assertIn("source wallet address changed", stderr)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])

    def test_private_network_cannot_query_public_account_history(self):
        config = json.loads(self.config.read_text())
        config["validator"]["zero_state"]["root_hash"] = TRANSACTION_HASH
        self.config.write_text(json.dumps(config))
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn("network", stderr)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])

    def test_same_source_lock_blocks_concurrent_collectors(self):
        self.journal_root.mkdir()
        lock_path = self.journal.with_suffix(".lock")
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn("already running", stderr)
        self.assertEqual(self.commands, [])

    def test_timed_out_process_can_still_have_a_confirmed_receipt(self):
        self.command_timeout = True
        rc, stdout, stderr = self.run_driver()
        self.assertEqual(rc, 0, stderr)
        self.assertIn("confirmed on chain", stdout)
        self.assertEqual(len(self.commands), 1)

    def test_inspect_without_pending_collect_is_read_only(self):
        rc, stdout, stderr = self.run_driver(inspect=True)
        self.assertEqual(rc, 3, stderr)
        self.assertIsNone(json.loads(stdout)["observed_marker"])
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])
        self.assertFalse(self.journal_root.exists(), "inspection created new collection state")

    def test_inspect_finds_pending_zero_balance_without_broadcasting(self):
        self.receipt_mode = "empty"
        self.assertNotEqual(self.run_driver()[0], 0)
        previous_state = self.journal.read_bytes()
        previous_requests = len(self.requests)
        rc, stdout, stderr = self.run_driver(inspect=True, balance="0")
        self.assertEqual(rc, 0, stderr)
        self.assertTrue(json.loads(stdout)["pending"])
        self.assertEqual(json.loads(stdout)["marker"], json.loads(previous_state)["marker"])
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(len(self.requests), previous_requests)
        self.assertEqual(self.journal.read_bytes(), previous_state)

    def test_new_zero_balance_collect_cannot_submit_a_payment(self):
        rc, _, stderr = self.run_driver(balance="0")
        self.assertNotEqual(rc, 0)
        self.assertIn("balance", stderr)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])

    def test_inspect_completed_matching_plan_is_read_only(self):
        self.assertEqual(self.run_driver()[0], 0)
        before = self.journal.read_bytes()
        before_requests = len(self.requests)
        rc, stdout, stderr = self.run_driver(inspect=True, balance="0")
        self.assertEqual(rc, 2, stderr)
        self.assertFalse(json.loads(stdout)["pending"])
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(len(self.requests), before_requests)
        self.assertEqual(self.journal.read_bytes(), before)

    def test_completed_operation_permits_a_new_explicit_collection(self):
        self.assertEqual(self.run_driver()[0], 0)
        old_marker = json.loads(self.journal.read_text())["marker"]
        rc, _, stderr = self.run_driver()
        self.assertEqual(rc, 0, stderr)
        self.assertEqual(len(self.commands), 2)
        self.assertNotEqual(json.loads(self.journal.read_text())["marker"], old_marker)

    def test_corrupt_pending_journal_cannot_be_overwritten_with_another_payment(self):
        self.journal_root.mkdir()
        self.journal.write_text('{"version":1,"status":"pending",')
        before = self.journal.read_bytes()
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])
        self.assertEqual(self.journal.read_bytes(), before)

    def test_intent_persistence_failure_aborts_before_broadcast(self):
        with mock.patch.dict(self.namespace, save_journal=mock.Mock(side_effect=OSError("Synthetic disk write failure"))):
            rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn("Synthetic disk write failure", stderr)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])

    def test_invalid_completed_journal_does_not_allow_another_broadcast(self):
        self.assertEqual(self.run_driver()[0], 0)
        state = json.loads(self.journal.read_text())
        del state["receipt"]
        self.journal.write_text(json.dumps(state))
        before = self.journal.read_bytes()
        for inspect in (False, True):
            with self.subTest(inspect=inspect):
                rc, _, stderr = self.run_driver(inspect=inspect)
                self.assertNotEqual(rc, 0)
                self.assertIn("receipt", stderr)
                self.assertEqual(len(self.commands), 1)
                self.assertEqual(self.journal.read_bytes(), before)

    def test_journal_symlink_is_not_followed_or_overwritten(self):
        self.journal_root.mkdir()
        target = self.root / "unrelated-file"
        target.write_text("unrelated contents")
        self.journal.symlink_to(target)
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertIn("symbolic link", stderr)
        self.assertEqual(target.read_text(), "unrelated contents")
        self.assertEqual(self.commands, [])

    def test_journal_directory_symlink_is_not_followed(self):
        target = self.root / "unrelated-directory"
        target.mkdir()
        self.journal_root.symlink_to(target, target_is_directory=True)
        for inspect in (False, True):
            with self.subTest(inspect=inspect):
                rc, _, stderr = self.run_driver(inspect=inspect)
                self.assertNotEqual(rc, 0)
                self.assertIn("symbolic link", stderr)
                self.assertEqual(list(target.iterdir()), [])
                self.assertEqual(self.commands, [])

    def test_lock_symlink_is_not_followed(self):
        self.journal_root.mkdir()
        target = self.root / "unrelated-file"
        target.write_text("unrelated contents")
        self.journal.with_suffix(".lock").symlink_to(target)
        rc, _, stderr = self.run_driver()
        self.assertNotEqual(rc, 0)
        self.assertEqual(target.read_text(), "unrelated contents")
        self.assertEqual(self.commands, [])

    def test_testnet_friendly_destination_cannot_be_used_on_mainnet(self):
        rc, _, stderr = self.run_driver(destination=friendly(DESTINATION, 0xD1))
        self.assertNotEqual(rc, 0)
        self.assertIn("another network", stderr)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.requests, [])

    def test_command_timeout_kills_descendants_that_inherit_stdout(self):
        # This runs a tiny Python fixture, never MyTonCtrl or a TON tool. Its
        # child inherits stdout just like lite-client does in the failing
        # console path. The production timeout must stop the entire group.
        command = [sys.executable, "-c", (
            "import subprocess,sys,time\n"
            "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])\n"
            "print('fixture-child='+str(child.pid), flush=True)\n"
            "time.sleep(30)\n"
        )]
        started = time.monotonic()
        rc, output = self.namespace["run_mytonctrl"](command, os.environ.copy(), 0.2)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(rc, 124)
        child = int(output.strip().split("fixture-child=")[1])
        child_status = pathlib.Path(f"/proc/{child}/stat")
        if child_status.exists():
            self.assertEqual(child_status.read_text().split()[2], "Z", "timed-out descendant was left running")

    def test_pending_observation_completed_by_another_collector_cannot_resend(self):
        self.receipt_mode = "empty"
        self.assertNotEqual(self.run_driver(amount="0.25")[0], 0)
        observed_marker = json.loads(self.journal.read_text())["marker"]
        self.receipt_mode = "paid"
        self.assertEqual(self.run_driver(amount="0.25")[0], 0)
        before = self.journal.read_bytes()
        rc, stdout, stderr = self.run_driver(amount="0.25", expect="resume:" + observed_marker)
        self.assertEqual(rc, 0, stderr)
        self.assertIn("confirmed", stdout)
        self.assertEqual(len(self.commands), 1, "a completed pending observation signed a duplicate payment")
        self.assertEqual(self.journal.read_bytes(), before)

    def test_fresh_observation_invalidated_by_another_collection_aborts(self):
        self.assertEqual(self.run_driver(amount="0.25")[0], 0)
        before = self.journal.read_bytes()
        rc, _, stderr = self.run_driver(amount="0.25", expect="fresh:none")
        self.assertNotEqual(rc, 0)
        self.assertEqual(len(self.commands), 1, "a stale fresh observation signed another payment")
        self.assertEqual(self.journal.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
