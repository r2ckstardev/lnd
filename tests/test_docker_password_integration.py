"""Regtest startup checks using the released, unmodified LND binary.

Run with: python3 -m unittest discover -s tests -p test_docker_password_integration.py -v
Requires Docker. Creates isolated containers, a network and disposable volumes.
No public-chain connection or real funds are used.
"""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid


ROOT = Path(__file__).resolve().parents[1]
LND_IMAGE = "btcpayserver/lnd:v0.21.3-beta-1"
BITCOIN_IMAGE = "btcpayserver/bitcoin:31.1"
WALLET_DIR = "/data/data/chain/bitcoin/regtest"


def docker(*args, input=None, check=True):
    result = subprocess.run(
        ["docker", *args], input=input, capture_output=True, timeout=180,
    )
    if check and result.returncode:
        raise RuntimeError(f"docker {args[0]} failed: {result.stderr.decode()}")
    return result.stdout


def wait_for(action, timeout=90):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            result = action()
            if result is not None and result is not False:
                return result
        except (HTTPError, URLError, OSError, RuntimeError, ValueError) as error:
            last = error
        time.sleep(0.5)
    raise AssertionError(f"startup timed out: {last}")


class DockerMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prefix = "btcpay-startup-test-" + uuid.uuid4().hex[:12]
        cls.network = cls.prefix + "-network"
        cls.bitcoin = cls.prefix + "-bitcoin"
        cls.image = cls.prefix + ":test"
        cls.addClassCleanup(docker, "image", "rm", cls.image, check=False)
        cls.addClassCleanup(docker, "network", "rm", cls.network, check=False)
        cls.addClassCleanup(docker, "rm", "-f", cls.bitcoin, check=False)
        docker("pull", LND_IMAGE)
        docker("pull", BITCOIN_IMAGE)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for name in ("docker-entrypoint.sh", "docker-initunlocklnd.sh", "docker-password-migration.sh"):
                shutil.copyfile(ROOT / name, directory / name)
            (directory / "Dockerfile").write_text(
                f"FROM {LND_IMAGE}\n"
                "COPY docker-entrypoint.sh docker-initunlocklnd.sh docker-password-migration.sh /\n"
                "RUN chmod 755 /docker-entrypoint.sh /docker-initunlocklnd.sh\n"
            )
            docker("build", "-q", "-t", cls.image, str(directory))
        original = docker("run", "--rm", "--entrypoint", "sha256sum", LND_IMAGE, "/bin/lnd")
        overlay = docker("run", "--rm", "--entrypoint", "sha256sum", cls.image, "/bin/lnd")
        if original != overlay:
            raise AssertionError("The BTCPay overlay changed the LND binary")
        docker("network", "create", "--internal", cls.network)
        docker(
            "run", "-d", "--name", cls.bitcoin, "--network", cls.network,
            "--network-alias", "bitcoin", "--entrypoint", "bitcoind", BITCOIN_IMAGE,
            "-regtest=1", "-server=1", "-rpcuser=test", "-rpcpassword=test",
            "-rpcbind=0.0.0.0:18443", "-rpcallowip=0.0.0.0/0", "-listen=0",
            "-zmqpubrawblock=tcp://0.0.0.0:28332", "-zmqpubrawtx=tcp://0.0.0.0:28333",
        )
        wait_for(lambda: docker(
            "exec", cls.bitcoin, "bitcoin-cli", "-regtest", "-rpcuser=test",
            "-rpcpassword=test", "getblockchaininfo",
        ))

    def setUp(self):
        self.name = self.prefix + "-" + uuid.uuid4().hex[:8]
        self.volume = self.name + "-data"
        docker("volume", "create", self.volume)
        self.addCleanup(docker, "volume", "rm", self.volume, check=False)
        self.addCleanup(docker, "rm", "-f", self.name, check=False)
        self.old_password = "hellorockstar"
        self.config = "\n".join((
            "bitcoin.active=1", "bitcoin.regtest=1", "bitcoin.node=bitcoind",
            "bitcoind.rpchost=bitcoin:18443", "bitcoind.rpcuser=test", "bitcoind.rpcpass=test",
            "bitcoind.zmqpubrawblock=tcp://bitcoin:28332", "bitcoind.zmqpubrawtx=tcp://bitcoin:28333",
            "restlisten=0.0.0.0:8080", "rpclisten=127.0.0.1:10009", "no-rest-tls=1",
            "adminmacaroonpath=/data/admin.macaroon", "readonlymacaroonpath=/data/readonly.macaroon",
            "invoicemacaroonpath=/data/invoice.macaroon", "noseedbackup=0",
        ))

    def start(self, overlay):
        args = [
            "run", "-d", "--name", self.name, "--network", self.network,
            "-v", self.volume + ":/data", "-p", "127.0.0.1::8080",
        ]
        if overlay:
            args += [
                "--restart", "unless-stopped", "-e", "LND_CHAIN=btc",
                "-e", "LND_ENVIRONMENT=regtest", "-e", "LND_EXTRA_ARGS=" + self.config,
                "-e", "LND_REST_LISTEN_HOST=http://127.0.0.1:8080",
                "-e", "LND_MACAROON_ROTATION_ID=integration-test",
                self.image,
            ]
        else:
            args += ["--entrypoint", "lnd", LND_IMAGE, "--lnddir=/data"]
            args += ["--" + setting for setting in self.config.splitlines()]
        docker(*args)
        port = json.loads(docker("inspect", self.name))[0]["NetworkSettings"]["Ports"]["8080/tcp"][0]["HostPort"]
        self.url = "http://127.0.0.1:" + port

    def request(self, endpoint, payload=None, authenticated=False):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Grpc-Metadata-macaroon"] = docker("exec", self.name, "cat", "/data/admin.macaroon").hex()
        request = Request(
            self.url + "/v1/" + endpoint,
            data=None if payload is None else json.dumps(payload).encode(), headers=headers,
        )
        with urlopen(request, timeout=20) as response:
            return json.load(response)

    def write_unlock(self, content):
        docker(
            "exec", "-i", self.name, "sh", "-c", f"cat > {WALLET_DIR}/walletunlock.json",
            input=json.dumps(content).encode(),
        )

    def initialize_legacy(self, newline=False):
        if newline:
            self.old_password += "\n"
        self.start(False)
        seed = wait_for(lambda: self.request("genseed"))["cipher_seed_mnemonic"]
        self.request("initwallet", {
            "wallet_password": base64.b64encode(self.old_password.encode()).decode(),
            "cipher_seed_mnemonic": seed,
        })
        wait_for(lambda: self.request("getinfo", authenticated=True))
        self.original = {"wallet_password": "hellorockstar", "cipher_seed_mnemonic": seed}
        self.write_unlock(self.original)
        self.old_macaroon = docker("exec", self.name, "cat", "/data/admin.macaroon")
        docker("stop", self.name)
        docker("rm", self.name)

    def remove_macaroons(self):
        # Only this test's disposable volume is mounted into this container.
        docker(
            "run", "--rm", "-v", self.volume + ":/data", "--entrypoint", "sh", LND_IMAGE,
            "-c", "find /data -type f \\( -name '*.macaroon' -o -name 'macaroons.db' \\) -exec rm -f {} \\;",
        )

    def assert_migrated(self):
        def ready():
            saved = json.loads(docker("exec", self.name, "cat", WALLET_DIR + "/walletunlock.json"))
            if "wallet_password_pending" in saved or saved["wallet_password"] == "hellorockstar":
                return False
            docker("exec", self.name, "test", "-f", "/data/.macaroon-rotated-integration-test")
            return self.request("getinfo", authenticated=True)

        try:
            wait_for(ready, timeout=120)
        except AssertionError:
            print(docker("logs", "--tail", "60", self.name, check=False).decode())
            raise
        saved = json.loads(docker("exec", self.name, "cat", WALLET_DIR + "/walletunlock.json"))
        self.assertNotEqual(saved["wallet_password"], "hellorockstar")
        self.assertNotIn("wallet_password_pending", saved)
        self.assertEqual(saved["cipher_seed_mnemonic"], self.original["cipher_seed_mnemonic"])
        docker("exec", self.name, "test", "-f", "/data/.macaroon-rotated-integration-test")
        request = Request(self.url + "/v1/getinfo", headers={"Grpc-Metadata-macaroon": self.old_macaroon.hex()})
        with self.assertRaises(HTTPError):
            urlopen(request, timeout=10)
        # Verify another restart uses exactly the saved password.
        docker("restart", self.name)
        wait_for(lambda: self.request("getinfo", authenticated=True))
        restarted = json.loads(docker("exec", self.name, "cat", WALLET_DIR + "/walletunlock.json"))
        self.assertEqual(saved, restarted)

    def test_legacy_rotation(self):
        self.initialize_legacy()
        self.start(True)
        self.assert_migrated()

    def test_newline_legacy_rotation(self):
        self.initialize_legacy(newline=True)
        self.start(True)
        self.assert_migrated()

    def test_previously_removed_macaroon_database(self):
        self.initialize_legacy()
        self.remove_macaroons()
        self.start(True)
        self.assert_migrated()

    def test_resume_after_real_partial_password_change(self):
        self.initialize_legacy()
        self.remove_macaroons()
        self.start(False)
        wait_for(lambda: self.request("state"))
        replacement = "persisted-test-replacement-password"
        self.write_unlock(self.original | {"wallet_password_pending": replacement})
        with self.assertRaises(HTTPError) as failure:
            self.request("changepassword", {
                "current_password": base64.b64encode(self.old_password.encode()).decode(),
                "new_password": base64.b64encode(replacement.encode()).decode(),
            })
        self.assertEqual(json.load(failure.exception)["message"], "default root key not found")
        docker("stop", self.name)
        docker("rm", self.name)
        self.start(True)
        self.assert_migrated()
        saved = json.loads(docker("exec", self.name, "cat", WALLET_DIR + "/walletunlock.json"))
        self.assertEqual(saved["wallet_password"], replacement)


if __name__ == "__main__":
    unittest.main()
