from __future__ import annotations

import importlib.util
import json
import os
import socket
import stat
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "config"
    / "vohive"
    / "wangka-management-proxy.py"
)


class ManagementProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        os.environ["WANGKA_STATE_DIR"] = cls.temporary.name
        spec = importlib.util.spec_from_file_location("wangka_management_proxy", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def setUp(self) -> None:
        self.module.save_state(self.module.default_state())
        self.server = self.module.ThreadingHTTPServer(
            ("127.0.0.1", 0), self.module.WangkaHandler
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_factory_state_is_atomic_and_private(self) -> None:
        state = self.module.load_state()
        self.assertFalse(state["initialized"])
        mode = stat.S_IMODE(self.module.STATE_FILE.stat().st_mode)
        self.assertEqual(mode, 0o600)

    def test_password_and_ssid_validation(self) -> None:
        self.module.validate_password("123456789")
        self.module.validate_ssid("Wangka-UFI103S")
        with self.assertRaises(ValueError):
            self.module.validate_password("short")
        with self.assertRaises(ValueError):
            self.module.validate_password("invalid:password")
        with self.assertRaises(ValueError):
            self.module.validate_ssid("")

    def test_time_validation_and_persistence(self) -> None:
        epoch = self.module.validate_client_epoch(1787328000)
        self.assertEqual(epoch, 1787328000)
        self.assertEqual(self.module.validate_timezone("UTC"), "UTC")
        with self.assertRaises(ValueError):
            self.module.validate_client_epoch(0)
        with self.assertRaises(ValueError):
            self.module.validate_timezone("../../etc")
        self.module.persist_trusted_epoch(epoch)
        self.assertEqual(int(self.module.LAST_EPOCH_FILE.read_text()), epoch)
        self.assertEqual(
            stat.S_IMODE(self.module.LAST_EPOCH_FILE.stat().st_mode), 0o600
        )

    def test_system_page_is_served(self) -> None:
        with urllib.request.urlopen(self.base + "/wangka/system-device") as response:
            body = response.read().decode("utf-8")
        self.assertIn("VoHive · 系统设备", body)
        self.assertIn("device-uplink", body)
        self.assertIn("host-uplink", body)
        self.assertIn("批次 2 后启用", body)
        self.assertIn("用本机时间校准", body)

    def test_uninstall_is_rejected_without_reaching_backend(self) -> None:
        request = urllib.request.Request(
            self.base + "/api/system/uninstall", data=b"", method="POST"
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 403)
        payload = json.loads(raised.exception.read())
        self.assertEqual(payload["code"], "disabled")

    def test_first_boot_blocks_normal_api(self) -> None:
        request = urllib.request.Request(self.base + "/api/devices")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 428)
        payload = json.loads(raised.exception.read())
        self.assertEqual(payload["code"], "initialization_required")

    def test_html_injection_removes_uninstall_and_adds_system_link(self) -> None:
        result = self.module.inject_html(b"<html><body>VoHive</body></html>")
        self.assertIn(b"wangka-shell-script", result)
        self.assertIn("拒绝并卸载".encode(), result)
        self.assertIn(b"/wangka/system-device", result)

    def test_prebound_socket_server(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(16)
        port = listener.getsockname()[1]
        server = self.module.serve_socket(listener)
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/wangka/system-device"
            ) as response:
                self.assertEqual(response.status, 200)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
