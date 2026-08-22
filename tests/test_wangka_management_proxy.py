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
from unittest import mock


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
        os.environ["WANGKA_HOTSPOT_PROFILE"] = str(
            Path(cls.temporary.name) / "hotspot.nmconnection"
        )
        os.environ["WANGKA_HOST_UPLINK_CONFIG"] = str(
            Path(cls.temporary.name) / "host-uplink.json"
        )
        spec = importlib.util.spec_from_file_location("wangka_management_proxy", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def setUp(self) -> None:
        self.module.save_state(self.module.default_state())
        self.module.HOTSPOT_PROFILE.write_text(
            "[connection]\nid=hotspot\n[wifi]\nssid=Wangka-Test\n",
            encoding="utf-8",
        )
        self.server = None
        self.thread = None

    def start_server(self) -> None:
        try:
            self.server = self.module.ThreadingHTTPServer(
                ("127.0.0.1", 0), self.module.WangkaHandler
            )
        except PermissionError:
            self.skipTest("local socket binding is blocked by the test sandbox")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
        if self.thread is not None:
            self.thread.join(timeout=2)

    def test_factory_state_is_atomic_and_private(self) -> None:
        state = self.module.load_state()
        self.assertFalse(state["initialized"])
        mode = stat.S_IMODE(self.module.STATE_FILE.stat().st_mode)
        self.assertEqual(mode, 0o600)

    def test_local_auth_state_is_atomic_and_private(self) -> None:
        self.module.save_local_auth("secret-value")
        loaded = json.loads(self.module.LOCAL_AUTH_FILE.read_text(encoding="utf-8"))
        self.assertEqual(loaded, {"password": "secret-value", "username": "user"})
        self.assertEqual(
            stat.S_IMODE(self.module.LOCAL_AUTH_FILE.stat().st_mode), 0o600
        )

    def test_password_and_ssid_validation(self) -> None:
        self.module.validate_password("123456789")
        self.module.validate_ssid("Wangka-UFI103S")
        with self.assertRaises(ValueError):
            self.module.validate_password("short")
        with self.assertRaises(ValueError):
            self.module.validate_password("invalid:password")
        with self.assertRaises(ValueError):
            self.module.validate_ssid("")

    def test_steady_status_avoids_spawning_helpers_and_nmcli(self) -> None:
        state = self.module.load_state()
        state.update(
            {
                "uplink_mode": "device-uplink",
                "work_mode": "data",
                "work_mode_last_result": "ok",
            }
        )
        self.module.save_state(state)
        with mock.patch.object(self.module, "run_command") as command:
            uplink = self.module.uplink_status()
            work_mode = self.module.work_mode_status()
            ssid = self.module.hotspot_ssid()
        command.assert_not_called()
        self.assertEqual(uplink["mode"], "device-uplink")
        self.assertIs(uplink["helper_checked"], False)
        self.assertEqual(work_mode["mode"], "data")
        self.assertEqual(ssid, "Wangka-Test")

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
        self.start_server()
        with urllib.request.urlopen(self.base + "/wangka/system-device") as response:
            body = response.read().decode("utf-8")
        self.assertIn("VoHive · 系统设备", body)
        self.assertIn("device-uplink", body)
        self.assertIn("host-uplink", body)
        self.assertIn("切换到 Mac 上行", body)
        self.assertIn("不会转发 Wi-Fi 客户端", body)
        self.assertIn("用本机时间校准", body)

    def test_uplink_switch_only_accepts_fixed_modes(self) -> None:
        with self.assertRaises(ValueError):
            self.module.switch_uplink("host-uplink; reboot")
        completed = self.module.subprocess.CompletedProcess(
            ["wangka-uplink", "host-uplink"], 0, '{"status":"ok","mode":"host-uplink"}', ""
        )
        with mock.patch.object(self.module.subprocess, "run", return_value=completed) as invoked:
            result = self.module.switch_uplink("host-uplink")
        self.assertEqual(result["mode"], "host-uplink")
        self.assertEqual(invoked.call_args.args[0][-1], "host-uplink")

    def test_uninstall_is_rejected_without_reaching_backend(self) -> None:
        self.start_server()
        request = urllib.request.Request(
            self.base + "/api/system/uninstall", data=b"", method="POST"
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 403)
        payload = json.loads(raised.exception.read())
        self.assertEqual(payload["code"], "disabled")

    def test_upstream_password_route_requires_system_device(self) -> None:
        self.start_server()
        request = urllib.request.Request(
            self.base + "/api/settings/password", data=b"{}", method="POST"
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 409)
        payload = json.loads(raised.exception.read())
        self.assertEqual(payload["code"], "use_system_device")

    def test_first_boot_blocks_normal_api(self) -> None:
        self.start_server()
        request = urllib.request.Request(self.base + "/api/devices")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 428)
        payload = json.loads(raised.exception.read())
        self.assertEqual(payload["code"], "initialization_required")

    def test_html_injection_removes_uninstall_and_adds_system_link(self) -> None:
        result = self.module.inject_html(b"<html><body>VoHive</body></html>")
        self.assertIn(b"wangka-shell-script", result)
        self.assertIn(b"wangka-experience-script", result)
        self.assertIn("工作模式".encode(), result)
        self.assertIn("开启状态灯".encode(), result)
        self.assertIn("夜间模式".encode(), result)
        self.assertIn("+国家/地区码".encode(), result)
        self.assertNotIn(b"wangka-auth-bootstrap", result)
        self.assertIn("拒绝并卸载".encode(), result)
        self.assertIn(b"/wangka/system-device", result)

    def test_trusted_network_injection_bootstraps_local_session(self) -> None:
        state = self.module.load_state()
        state["access_mode"] = "trusted-network"
        self.module.save_state(state)
        result = self.module.inject_html(b"<html><head></head><body>VoHive</body></html>")
        self.assertIn(b"wangka-auth-bootstrap", result)
        self.assertIn(b"wangka-local-access", result)

    def test_default_modes_and_access_policy(self) -> None:
        state = self.module.load_state()
        self.assertEqual(state["work_mode"], "dual")
        self.assertEqual(state["access_mode"], "login-required")
        self.assertIs(state["led_enabled"], True)
        self.assertIs(state["led_night_mode"], False)

    def test_led_status_fallback_and_settings_are_bounded(self) -> None:
        state = self.module.load_state()
        work_mode = self.module.work_mode_status()
        thermal = {
            "status": "ok",
            "maximum_c": 70.0,
            "warning_c": 85.0,
            "critical_c": 92.0,
            "sensors": [],
        }
        with mock.patch.object(self.module, "LED_RUNTIME_FILE", Path("/missing-led-status")):
            status = self.module.led_status(state, work_mode, thermal)
        self.assertEqual(status["mode_color"], "white")
        self.assertEqual(status["color"], "white")
        self.assertEqual(status["pattern"], "steady")

        completed = self.module.subprocess.CompletedProcess(
            ["wangka-led", "apply"],
            0,
            '{"status":"ok","enabled":false,"night_mode":true,"mode":"dual",'
            '"mode_color":"white","color":"off","pattern":"off","meaning":"状态灯已关闭"}',
            "",
        )
        with mock.patch.object(self.module.subprocess, "run", return_value=completed):
            applied = self.module.apply_led_settings(False, True)
        self.assertIs(applied["enabled"], False)
        saved = self.module.load_state()
        self.assertIs(saved["led_enabled"], False)
        self.assertIs(saved["led_night_mode"], True)

    def test_work_mode_switch_only_accepts_fixed_modes(self) -> None:
        with self.assertRaises(ValueError):
            self.module.switch_work_mode("data; reboot")
        completed = self.module.subprocess.CompletedProcess(
            ["wangka-work-mode", "switch", "sms"],
            0,
            '{"status":"ok","mode":"sms"}',
            "",
        )
        with mock.patch.object(
            self.module.subprocess, "run", return_value=completed
        ) as invoked:
            result = self.module.switch_work_mode("sms")
        self.assertEqual(result["mode"], "sms")
        self.assertEqual(invoked.call_args.args[0][-2:], ["switch", "sms"])

    def test_thermal_status_is_bounded_and_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            zone = Path(temporary) / "thermal_zone9"
            zone.mkdir()
            (zone / "type").write_text("modem-secret-path\n", encoding="utf-8")
            (zone / "temp").write_text("91000\n", encoding="ascii")
            with mock.patch.object(self.module, "THERMAL_ROOT", Path(temporary)):
                status = self.module.thermal_status()
        self.assertEqual(status["maximum_c"], 91.0)
        self.assertEqual(status["level"], "warning")
        self.assertEqual(status["sensors"][0]["name"], "基带")
        self.assertNotIn("path", json.dumps(status))

    def test_prebound_socket_server(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", 0))
        except PermissionError:
            listener.close()
            self.skipTest("local socket binding is blocked by the test sandbox")
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
