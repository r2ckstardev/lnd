"""Supplementary fault injection. This fixture is intentionally outside the PR."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = Path(__file__).resolve().parents[1] / "docker-initunlocklnd.sh"


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        self.wallet_dir = self.data / "data/chain/bitcoin/regtest"
        self.wallet_dir.mkdir(parents=True)
        self.wallet = self.wallet_dir / "wallet.db"
        self.wallet.write_bytes(b"wallet")
        (self.wallet_dir / "macaroons.db").write_bytes(b"store")
        for name in ("admin", "readonly", "invoice"):
            (self.wallet_dir / (name + ".macaroon")).write_bytes(b"token")
        (self.data / "lnd.conf").write_text("bitcoin.regtest=1\n")
        self.unlock = self.wallet_dir / "walletunlock.json"
        self.recovery = self.wallet_dir / "walletunlock.json.recovery"
        self.write_metadata({"wallet_password": "hellorockstar", "cipher_seed_mnemonic": ["seed retained"], "other": 7})
        self.password = "hellorockstar"
        self.store_password = self.password
        self.locked = True
        self.calls = []
        self.rotations = 0
        self.seed_requests = 0
        self.mode = "success"
        self.durable = []
        self.bin = self.data / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, LND_DATA=str(self.data), LND_MACAROON_ROTATION_ID="test", PATH=str(self.bin) + ":" + os.environ["PATH"])
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, body, status=200):
                encoded = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                if self.path.endswith("state"):
                    self.reply({"state": "NON_EXISTING" if not fixture.wallet.exists() else "LOCKED" if fixture.locked else "RPC_ACTIVE"})
                elif self.path.endswith("getinfo"):
                    self.reply({"identity_pubkey": "fixture"}, 500 if fixture.locked else 200)
                elif self.path.endswith("genseed"):
                    fixture.seed_requests += 1
                    self.reply({"cipher_seed_mnemonic": [None] if fixture.mode == "invalid-seed" else ["abandon"] * 24})
                else:
                    self.reply({"code": 5}, 404)

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.calls.append((self.path, request))
                if self.path.endswith("initwallet"):
                    saved = json.loads(fixture.unlock.read_text())
                    supplied = base64.b64decode(request["wallet_password"]).decode()
                    fixture.durable.append(saved["wallet_password"] == supplied and saved["cipher_seed_mnemonic"] == request["cipher_seed_mnemonic"])
                    fixture.password = fixture.store_password = supplied
                    fixture.wallet.write_bytes(b"initialized wallet")
                    (fixture.wallet_dir / "macaroons.db").write_bytes(b"store")
                    for name in ("admin", "readonly", "invoice"):
                        (fixture.wallet_dir / (name + ".macaroon")).write_bytes(b"token")
                    fixture.locked = False
                    if fixture.mode == "lost-response":
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                    else:
                        self.reply({"admin_macaroon": "fixture"})
                    return
                changing = self.path.endswith("changepassword")
                supplied = base64.b64decode(request["current_password" if changing else "wallet_password"]).decode()
                if fixture.mode == "busy":
                    self.reply({"code": 2, "message": "timeout opening database"}, 500)
                    return
                if supplied != fixture.password:
                    self.reply({"code": 2, "message": "invalid passphrase for master public key"}, 500)
                    return
                if changing:
                    record = fixture.read_record()
                    new = base64.b64decode(request["new_password"]).decode()
                    fixture.durable.append(record["password"] == new and record["pending"] and json.loads(fixture.unlock.read_text())["wallet_password_pending"] == new)
                    fixture.password = new
                    if fixture.mode == "store-error" or supplied != fixture.store_password:
                        self.reply({"code": 2, "message": "invalid password"}, 500)
                        return
                    fixture.store_password = new
                    if request.get("new_macaroon_root_key"):
                        fixture.rotations += 1
                if fixture.mode == "rewrite":
                    fixture.write_metadata({"wallet_password": "hellorockstar", "cipher_seed_mnemonic": ["Seed removed"], "concurrent": True})
                fixture.locked = False
                if fixture.mode == "lost-response":
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.reply({"admin_macaroon": "fixture"} if changing else {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.env["LND_REST_LISTEN_HOST"] = "http://127.0.0.1:%d" % self.server.server_port

    def write_metadata(self, value):
        self.unlock.write_text(json.dumps(value))

    def read_record(self):
        return json.loads(self.recovery.read_text())

    def run_script(self, ok=True, prepare=False):
        result = subprocess.run(["bash", str(SCRIPT), "bitcoin", "regtest"] + (["--prepare", "lnd"] if prepare else []), env=self.env, capture_output=True, text=True, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        return result.stderr

    def wrapper(self, command, body):
        path = self.bin / command
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def test_migrate_rotate_durable_and_steady(self):
        self.run_script()
        first = self.read_record()
        self.assertTrue(all(self.durable))
        self.assertEqual(len(first["password"]), 44)
        self.assertEqual(len(base64.b64decode(first["password"])), 32)
        self.assertNotIn("cipher_seed_mnemonic", first)
        self.assertEqual(first["old_passwords"], ["hellorockstar", "hellorockstar\n"])
        self.assertEqual(self.rotations, 1)
        self.locked = True
        self.run_script()
        self.assertEqual(self.rotations, 1)
        self.assertEqual(self.read_record(), first)

    def test_omitted_default_newline(self):
        self.password = self.store_password = "hellorockstar\n"
        self.run_script()
        self.assertTrue(all(self.durable))
        self.assertNotEqual(self.password, "hellorockstar\n")

    def test_custom_newline_plain_unlock(self):
        self.password = self.store_password = "custom password\n"
        self.write_metadata({"wallet_password": "custom password"})
        self.env["LND_MACAROON_ROTATION_ID"] = ""
        self.run_script()
        self.assertTrue(all(path.endswith("unlockwallet") for path, _ in self.calls))
        self.assertEqual(self.read_record()["password"], "custom password\n")

    def test_custom_newline_rotation(self):
        self.password = self.store_password = "custom password\n"
        self.write_metadata({"wallet_password": "custom password"})
        self.run_script()
        self.assertEqual(self.password, "custom password\n")
        self.assertEqual(self.rotations, 1)

    def test_lost_response_keeps_originals(self):
        self.mode = "lost-response"
        self.run_script(False)
        before = self.read_record()
        self.assertTrue(before["pending"])
        self.assertEqual(before["password"], self.password)
        self.locked = True
        self.mode = "success"
        self.run_script()
        self.assertEqual(self.read_record()["old_passwords"], before["old_passwords"])
        self.assertEqual(self.read_record()["password"], before["password"])

    def test_partial_store_failure_no_fallback(self):
        self.mode = "store-error"
        output = self.run_script(False)
        self.assertIn("other than the recognized wrong-wallet-password", output)
        self.assertNotIn("none of the saved", output)
        self.assertEqual(self.read_record()["password"], self.password)
        self.assertTrue(self.read_record()["pending"])
        self.assertTrue(self.locked)
        self.assertEqual(len(self.durable), 1)

    def test_busy_does_not_test_next_password(self):
        self.mode = "busy"
        output = self.run_script(False)
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn("none of the saved", output)

    def test_all_rejected(self):
        self.password = "not-saved-anywhere"
        output = self.run_script(False)
        self.assertIn("none of the saved password candidates", output)
        self.assertEqual(len(self.calls), 3)
        self.assertIn("issuecomment-5659154559", output)

    def test_seed_rewrite_during_rpc(self):
        self.mode = "rewrite"
        self.run_script()
        metadata = json.loads(self.unlock.read_text())
        self.assertEqual(metadata["cipher_seed_mnemonic"], ["Seed removed"])
        self.assertTrue(metadata["concurrent"])
        self.assertEqual(metadata["wallet_password"], self.password)

    def test_seed_rewrite_after_success(self):
        self.run_script()
        before = self.read_record()
        self.write_metadata({"wallet_password": "hellorockstar", "cipher_seed_mnemonic": ["Seed removed"]})
        self.locked = True
        self.run_script()
        self.assertEqual(self.read_record(), before)
        self.assertEqual(self.rotations, 1)

    def test_invalid_metadata_preflight(self):
        for invalid in ("", "{", "[]", "{} {}", '{"wallet_password":7}', '{"wallet_password_pending":null}', '{"wallet_password_pending":"hellorockstar"}'):
            with self.subTest(invalid=invalid):
                self.unlock.write_text(invalid)
                output = self.run_script(False, True)
                self.assertIn("Invalid metadata", output)
                self.assertEqual(self.unlock.read_text(), invalid)
        self.assertFalse(self.calls)

    def test_missing_store_is_preflight_failure(self):
        (self.wallet_dir / "macaroons.db").unlink()
        self.assertIn("Authentication preparation", self.run_script(False, True))
        self.assertFalse(self.calls)

    def test_missing_token_is_preflight_failure(self):
        (self.wallet_dir / "readonly.macaroon").unlink()
        self.assertIn("required token file", self.run_script(False, True))
        self.assertFalse(self.calls)

    def test_missing_wallet_with_node_evidence(self):
        self.wallet.unlink()
        self.assertIn("No replacement seed", self.run_script(False, True))
        self.assertFalse(self.calls)

    def test_record_conflict_preserved(self):
        self.run_script()
        before = self.recovery.read_bytes()
        self.write_metadata({"wallet_password_pending": "different-saved-password"})
        self.assertIn("conflicting credentials", self.run_script(False, True))
        self.assertEqual(self.recovery.read_bytes(), before)

    def test_mktemp_failure_no_request(self):
        self.wrapper("mktemp", "exit 1")
        self.assertIn("Filesystem error", self.run_script(False))
        self.assertFalse(self.calls)

    def test_sync_failure_no_request(self):
        self.wrapper("sync", "exit 1")
        original = self.unlock.read_bytes()
        self.assertIn("Filesystem error", self.run_script(False))
        self.assertFalse(self.calls)
        self.assertEqual(self.unlock.read_bytes(), original)

    def test_pending_rename_failure_preserves_metadata(self):
        self.wrapper("mv", '[[ "${@: -1}" == *walletunlock.json ]] && exit 1\nexec /usr/bin/mv "$@"')
        original = self.unlock.read_bytes()
        self.assertIn("Filesystem error", self.run_script(False))
        self.assertFalse(self.calls)
        self.assertEqual(self.unlock.read_bytes(), original)
        self.assertTrue(self.read_record()["pending"])

    def test_promotion_failure_does_not_repeat_rotation(self):
        self.wrapper("mv", '''if [[ "${@: -1}" == *walletunlock.json ]] && ! /usr/bin/jq -e 'has("wallet_password_pending")' "${@: -2:1}" >/dev/null; then exit 1; fi
exec /usr/bin/mv "$@"''')
        self.run_script(False)
        self.assertFalse(self.read_record()["pending"])
        self.assertEqual(self.rotations, 1)
        (self.bin / "mv").unlink()
        self.locked = True
        self.run_script()
        self.assertEqual(self.rotations, 1)

    def fresh(self):
        for path in self.wallet_dir.iterdir():
            path.unlink()
        self.run_script(prepare=True)

    def test_initialization_saved_before_request(self):
        self.fresh()
        initial = self.read_record()["password"]
        self.run_script()
        self.assertEqual(self.password, initial)
        self.assertEqual(self.seed_requests, 1)
        self.assertTrue(all(self.durable))
        self.assertEqual(self.recovery.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.unlock.stat().st_mode & 0o777, 0o600)

    def test_invalid_seed_is_not_saved_or_submitted(self):
        self.fresh()
        self.mode = "invalid-seed"
        self.assertIn("Invalid seed response", self.run_script(False))
        self.assertFalse(self.unlock.exists())
        self.assertFalse(self.calls)

    def test_initialization_lost_response_reuses_password(self):
        self.fresh()
        self.mode = "lost-response"
        self.run_script(False)
        first = json.loads(self.unlock.read_text())
        self.mode = "success"
        self.locked = True
        self.run_script()
        self.assertEqual(json.loads(self.unlock.read_text()), first)
        self.assertEqual(self.seed_requests, 1)
        self.assertEqual(sum(path.endswith("initwallet") for path, _ in self.calls), 1)
        self.assertEqual(self.rotations, 1)

    def test_saved_initialization_request_reused(self):
        self.fresh()
        first = {"wallet_password": self.read_record()["password"], "cipher_seed_mnemonic": ["abandon"] * 24}
        self.write_metadata(first)
        self.run_script()
        self.assertEqual(self.seed_requests, 0)
        self.assertEqual(json.loads(self.unlock.read_text()), first)

    def test_legacy_initialization_requires_manual_preparation(self):
        self.fresh()
        record = self.read_record()
        record["password"] = "hellorockstar"
        self.recovery.write_text(json.dumps(record))
        self.assertIn("shared legacy password", self.run_script(False, True))
        self.assertFalse(self.calls)

    def test_custom_newline_rotation_retry_keeps_exact_password(self):
        self.password = self.store_password = "custom password\n"
        self.write_metadata({"wallet_password": "custom password"})
        self.mode = "lost-response"
        self.run_script(False)
        self.mode = "success"
        self.locked = True
        self.run_script()
        self.assertEqual(self.password, "custom password\n")
        self.assertFalse(self.read_record()["migrate"])

    def test_failure_after_record_rename_no_request(self):
        self.wrapper("sync", '''count_file="$LND_DATA/sync-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
echo $((count+1)) > "$count_file"
[[ $count -eq 1 ]] && exit 1
exec /usr/bin/sync''')
        self.run_script(False)
        self.assertFalse(self.calls)
        self.assertTrue(self.read_record()["pending"])

    def test_completed_record_failure_preserves_recovery(self):
        self.wrapper("mv", '''if [[ "${@: -1}" == *.recovery ]] && /usr/bin/jq -e '.pending == false' "${@: -2:1}" >/dev/null; then exit 1; fi
exec /usr/bin/mv "$@"''')
        self.run_script(False)
        self.assertTrue(self.read_record()["pending"])
        self.assertEqual(self.read_record()["password"], self.password)
        self.assertEqual(self.read_record()["old_passwords"], ["hellorockstar", "hellorockstar\n"])
        (self.bin / "mv").unlink()
        self.locked = True
        self.run_script()
        self.assertEqual(self.rotations, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
