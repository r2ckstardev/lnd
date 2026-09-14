"""Exercise the real startup script against a local HTTP WalletUnlocker fixture.

Run with: python3 -m unittest discover -s tests -p test_docker_password_migration.py
Requires bash, curl, jq and standard Unix utilities. The fixture models RPC
outcomes; the Docker integration tests exercise the unmodified LND binary.
"""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SCRIPT = Path(__file__).resolve().parents[1] / "docker-initunlocklnd.sh"


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.data = Path(self.temporary.name)
        wallet_dir = self.data / "data/chain/bitcoin/regtest"
        wallet_dir.mkdir(parents=True)
        (wallet_dir / "wallet.db").touch()
        self.unlock = wallet_dir / "walletunlock.json"
        self.original = {
            "wallet_password": "hellorockstar",
            "cipher_seed_mnemonic": ["seed", "words", "preserved"],
            "unrelated": {"keep": True},
        }
        self.write_unlock(self.original)
        self.password = "hellorockstar"
        self.locked = True
        self.mode = "success"
        self.calls = []
        self.durable_requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, body, status=200):
                encoded = json.dumps(body, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                if self.path == "/v1/getinfo":
                    self.reply({}, 500 if fixture.locked else 200)
                elif self.path == "/v1/state":
                    self.reply({"state": "LOCKED" if fixture.locked else "RPC_ACTIVE"})
                else:
                    self.reply({"code": 5}, 404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.calls.append((self.path, body))
                if not fixture.locked:
                    self.reply({"code": 2, "message": "wallet already unlocked"}, 500)
                    return

                field = "current_password" if self.path.endswith("changepassword") else "wallet_password"
                supplied = base64.b64decode(body[field]).decode()
                if supplied != fixture.password:
                    self.reply({"code": 2, "message": "invalid passphrase for master public key"}, 500)
                    return

                if self.path.endswith("unlockwallet"):
                    fixture.locked = False
                    self.reply({})
                    return

                replacement = base64.b64decode(body["new_password"]).decode()
                saved = fixture.read_unlock()
                fixture.durable_requests.append(
                    saved.get("wallet_password_pending") == replacement
                    and replacement in saved.get("wallet_password_history", [])
                    and supplied in saved.get("wallet_password_history", [])
                )
                if fixture.mode == "reject":
                    self.reply({"code": 2, "message": "database unavailable"}, 500)
                    return
                fixture.password = replacement
                if fixture.mode == "partial":
                    self.reply({"code": 2, "message": "default root key not found"}, 500)
                    return
                fixture.locked = False
                if fixture.mode == "lost_response":
                    self.close_connection = True
                    return
                self.reply({"admin_macaroon": "test-only"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def read_unlock(self):
        return json.loads(self.unlock.read_text())

    def write_unlock(self, value):
        self.unlock.write_text(json.dumps(value))

    def run_helper(self, extra_env=None):
        env = os.environ | {
            "LND_DATA": self.data.as_posix(),
            "LND_REST_LISTEN_HOST": f"http://127.0.0.1:{self.server.server_port}",
            "LND_HOST_FOR_LOOP": "",
            "LND_ENVIRONMENT": "regtest",
            "LND_MACAROON_ROTATION_ID": "",
            "LND_DAEMON_PID": "",
        }
        env.update(extra_env or {})
        bash = os.environ.get("BASH", shutil.which("bash"))
        self.assertIsNotNone(bash, "bash is required")
        return subprocess.run(
            [bash, SCRIPT.as_posix(), "bitcoin", "regtest"],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def assert_completed(self):
        saved = self.read_unlock()
        self.assertEqual(saved["wallet_password"], self.password)
        self.assertNotEqual(self.password, "hellorockstar")
        self.assertNotIn("wallet_password_pending", saved)
        self.assertEqual(saved["cipher_seed_mnemonic"], self.original["cipher_seed_mnemonic"])
        self.assertEqual(saved["unrelated"], self.original["unrelated"])
        self.assertTrue(all(self.durable_requests))
        self.assertIn(self.password, saved["wallet_password_history"])
        self.assertIn("hellorockstar", saved["wallet_password_history"])
        self.assertIn("hellorockstar\n", saved["wallet_password_history"])

    def test_migration_and_next_restart(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_completed()
        self.locked = True
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len([c for c in self.calls if c[0].endswith("changepassword")]), 1)

    def test_legacy_newline_password(self):
        self.password += "\n"
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.calls), 2)
        self.assert_completed()

    def test_empty_missing_and_null_password_fields(self):
        for value in ("", None, "missing"):
            with self.subTest(value=value):
                original = self.original.copy()
                if value == "missing":
                    del original["wallet_password"]
                else:
                    original["wallet_password"] = value
                self.write_unlock(original)
                self.password, self.locked = "hellorockstar", True
                result = self.run_helper()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_completed()

    def test_partial_failure_retains_both_passwords_and_first_error(self):
        self.mode = "partial"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        saved = self.read_unlock()
        self.assertEqual(saved["wallet_password"], "hellorockstar")
        self.assertEqual(saved["wallet_password_pending"], self.password)
        self.assertIn("default root key not found", result.stdout)
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn(self.password, result.stdout + result.stderr)
        self.mode, self.locked = "success", True
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls[-1][0], "/v1/changepassword")
        self.assert_completed()

    def test_lost_success_response_recovers_on_restart(self):
        self.mode = "lost_response"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_unlock()["wallet_password_pending"], self.password)
        self.mode, self.locked = "success", True
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_completed()

    def test_rejected_request_reuses_pending_password(self):
        self.mode = "reject"
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        pending = self.read_unlock()["wallet_password_pending"]
        self.assertEqual(self.password, "hellorockstar")
        self.mode = "success"
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.password, pending)
        self.assert_completed()

    def test_saved_password_before_request_is_resumed(self):
        pending = "already-persisted-before-the-request"
        self.write_unlock(self.original | {"wallet_password_pending": pending})
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.password, pending)
        self.assert_completed()

    def test_invalid_pending_password_stops_without_rpc(self):
        self.write_unlock(self.original | {"wallet_password_pending": None})
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls, [])
        self.assertIn("wallet_password_pending", self.read_unlock())

    def test_failed_persistence_never_changes_wallet(self):
        injection = self.data / "fail-write.sh"
        injection.write_text("mktemp() { return 1; }\n")
        result = self.run_helper({"BASH_ENV": injection.as_posix()})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.password, "hellorockstar")
        self.assertEqual(self.read_unlock(), self.original)

    def test_final_file_write_failure_retains_pending_password(self):
        injection = self.data / "fail-final-write.sh"
        injection.write_text('''mv() {
    if jq -e 'has("wallet_password_pending")' "$LND_DATA/data/chain/bitcoin/regtest/walletunlock.json" >/dev/null; then
        return 1
    fi
    command mv "$@"
}
''')
        result = self.run_helper({"BASH_ENV": injection.as_posix()})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_unlock()["wallet_password_pending"], self.password)
        self.assertEqual(self.read_unlock()["wallet_password"], "hellorockstar")
        self.locked = True
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_completed()

    def test_rotation_marker_only_after_success(self):
        env = {"LND_MACAROON_ROTATION_ID": "test-rotation", "LND_PASSWORD_ROTATE_MACAROONS": "true"}
        self.mode = "reject"
        result = self.run_helper(env)
        self.assertNotEqual(result.returncode, 0)
        marker = self.data / ".macaroon-rotated-test-rotation"
        self.assertFalse(marker.exists())
        self.mode = "success"
        result = self.run_helper(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_completed()
        self.assertTrue(marker.exists())
        self.assertTrue(self.calls[-1][1]["new_macaroon_root_key"])

    def test_already_unlocked_does_not_discard_pending_password(self):
        saved = self.original | {"wallet_password_pending": "uncertain-saved-password"}
        self.write_unlock(saved)
        self.locked = False
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        for key, value in saved.items():
            self.assertEqual(self.read_unlock()[key], value)

    def test_custom_newline_unlock_does_not_change_password(self):
        self.password = "custom with spaces\n"
        self.write_unlock(self.original | {"wallet_password": "custom with spaces"})
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(all(path.endswith("unlockwallet") for path, _ in self.calls))
        self.assertEqual(self.password, "custom with spaces\n")

    def test_history_is_retained_on_another_migration(self):
        self.write_unlock(self.original | {"wallet_password_history": ["previous-private-password"]})
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("previous-private-password", self.read_unlock()["wallet_password_history"])

    def test_prepare_preserves_auth_files_and_never_moves_wallet_data(self):
        saved = self.original | {"wallet_password_pending": "uncertain-saved-password"}
        self.write_unlock(saved)
        wallet_dir = self.unlock.parent
        files = {
            self.data / "admin.macaroon": b"old token",
            wallet_dir / "macaroons.db": b"old encrypted root keys",
        }
        for filename, content in files.items():
            filename.write_bytes(content)
        (wallet_dir / "wallet.db").write_bytes(b"wallet must stay")
        (wallet_dir / "channel.db").write_bytes(b"channels must stay")
        old_backup = self.data / ".password-migration-backups/previous/admin.macaroon"
        old_backup.parent.mkdir(parents=True)
        old_backup.write_bytes(b"previous preserved token")
        result = subprocess.run(
            [os.environ.get("BASH", shutil.which("bash")), "-c",
             'source "$1"; prepare_password_migration "$2" "$3"', "test",
             str(SCRIPT.parent / "docker-password-migration.sh"),
             self.data.as_posix(), wallet_dir.as_posix()],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        attempts = list((self.data / ".password-migration-backups").glob("attempt.*"))
        self.assertEqual(len(attempts), 1)
        for filename, content in files.items():
            self.assertFalse(filename.exists())
            self.assertEqual((attempts[0] / filename.relative_to(self.data)).read_bytes(), content)
        self.assertEqual(old_backup.read_bytes(), b"previous preserved token")
        self.assertEqual((wallet_dir / "wallet.db").read_bytes(), b"wallet must stay")
        self.assertEqual((wallet_dir / "channel.db").read_bytes(), b"channels must stay")
        self.assertEqual(self.read_unlock(), saved)


if __name__ == "__main__":
    unittest.main()
