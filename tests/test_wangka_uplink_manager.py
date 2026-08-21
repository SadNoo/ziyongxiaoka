from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "config"
    / "network"
    / "wangka-uplink-manager.py"
)


class UplinkManagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        os.environ["WANGKA_STATE_DIR"] = str(cls.root / "state")
        os.environ["WANGKA_HOST_UPLINK_CONFIG"] = str(cls.root / "pairing.json")
        os.environ["WANGKA_HOST_UPLINK_FIREWALL"] = str(cls.root / "guard.nft")
        os.environ["WANGKA_RESOLV_CONF"] = str(cls.root / "resolv.conf")
        spec = importlib.util.spec_from_file_location("wangka_uplink_manager", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def setUp(self) -> None:
        self.module.save_state(self.module.default_state())
        self.module.PAIRING_FILE.write_text(
            json.dumps(
                {
                    "helper_url": "http://192.168.5.242:19531",
                    "token": "a" * 64,
                }
            ),
            encoding="utf-8",
        )

    def test_pairing_is_strict_and_secret_is_not_returned(self) -> None:
        pairing = self.module.load_pairing()
        self.assertEqual(pairing["helper_url"], "http://192.168.5.242:19531")
        self.module.PAIRING_FILE.write_text(
            '{"helper_url":"http://127.0.0.1:19531","token":"' + "a" * 64 + '"}',
            encoding="utf-8",
        )
        with self.assertRaises(self.module.UplinkError):
            self.module.load_pairing()

    def test_helper_request_retries_one_transient_network_error(self) -> None:
        response = mock.MagicMock()
        response.status = 200
        response.read.return_value = b'{"status":"ok","enabled":false}'
        context = mock.MagicMock()
        context.__enter__.return_value = response
        with (
            mock.patch.object(
                self.module,
                "urlopen",
                side_effect=[self.module.URLError("temporary"), context],
            ) as opener,
            mock.patch.object(self.module.time, "sleep") as pause,
        ):
            result = self.module.helper_request("status", timeout=0.01)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(opener.call_count, 2)
        pause.assert_called_once_with(0.15)

    def test_enable_response_rejects_management_dns(self) -> None:
        host, dns = self.module.validate_enable_response(
            {
                "enabled": True,
                "host_address": "192.168.5.242",
                "dns_servers": ["10.0.0.53", "1.1.1.1"],
            }
        )
        self.assertEqual(host, "192.168.5.242")
        self.assertEqual(dns, ["10.0.0.53", "1.1.1.1"])
        with self.assertRaises(self.module.UplinkError):
            self.module.validate_enable_response(
                {
                    "enabled": True,
                    "host_address": "192.168.5.242",
                    "dns_servers": ["192.168.5.1"],
                }
            )

    def test_resolver_write_is_atomic_and_redacted(self) -> None:
        self.module.write_resolv_conf(["1.1.1.1", "8.8.8.8"], "test")
        content = self.module.RESOLV_CONF.read_text(encoding="ascii")
        self.assertIn("nameserver 1.1.1.1", content)
        self.assertNotIn("token", content)
        self.assertEqual(self.module.RESOLV_CONF.stat().st_mode & 0o777, 0o644)

    def test_device_mode_dns_uses_china_fallback_when_no_link_dns_exists(self) -> None:
        with mock.patch.object(self.module, "run_command", return_value=""):
            result = self.module.device_mode_dns()
        self.assertEqual(result, ["114.114.114.114", "223.5.5.5"])

    def test_host_failure_rolls_back_to_device_mode(self) -> None:
        helper_payload = {
            "status": "ok",
            "enabled": True,
            "host_address": "192.168.5.242",
            "dns_servers": ["1.1.1.1"],
        }
        actions: list[str] = []

        def fake_helper(action: str, **_: object) -> dict[str, object]:
            actions.append(action)
            return helper_payload

        with (
            mock.patch.object(self.module, "helper_request", side_effect=fake_helper),
            mock.patch.object(
                self.module, "apply_host_network", side_effect=self.module.UplinkError("route failed")
            ),
            mock.patch.object(self.module, "clear_host_network") as clear,
        ):
            with self.assertRaises(self.module.UplinkError):
                self.module.switch_host()
        self.assertEqual(actions, ["enable", "disable"])
        clear.assert_called_once_with()
        state = self.module.load_state()
        self.assertEqual(state["uplink_mode"], "device-uplink")
        self.assertEqual(state["uplink_last_result"], "rolled-back")

    def test_shared_profile_route_does_not_set_forbidden_dns_property(self) -> None:
        commands: list[list[str]] = []

        def record(args: list[str], **_: object) -> str:
            commands.append(args)
            return ""

        with (
            mock.patch.object(self.module, "usb_management_ready"),
            mock.patch.object(self.module, "host_guard_active", return_value=False),
            mock.patch.object(self.module, "run_command", side_effect=record),
            mock.patch.object(self.module, "write_resolv_conf") as resolver,
        ):
            self.module.apply_host_network("192.168.5.242", ["1.1.1.1"])
        flattened = " ".join(" ".join(command) for command in commands)
        self.assertNotIn("ipv4.dns", flattened)
        self.assertIn("0.0.0.0/0 192.168.5.242 50", flattened)
        self.assertLess(flattened.index(str(self.module.HOST_FIREWALL)), flattened.index("ipv4.routes"))
        resolver.assert_called_once_with(["1.1.1.1"], "macOS host-uplink")

    def test_cleanup_error_does_not_skip_mac_helper_disable(self) -> None:
        actions: list[str] = []

        def fake_helper(action: str, **_: object) -> dict[str, object]:
            actions.append(action)
            if action == "enable":
                return {
                    "status": "ok",
                    "enabled": True,
                    "host_address": "192.168.5.242",
                    "dns_servers": ["1.1.1.1"],
                }
            return {"status": "ok", "enabled": False}

        with (
            mock.patch.object(self.module, "helper_request", side_effect=fake_helper),
            mock.patch.object(self.module, "apply_host_network", side_effect=OSError("apply")),
            mock.patch.object(self.module, "clear_host_network", side_effect=OSError("cleanup")),
        ):
            with self.assertRaises(self.module.UplinkError):
                self.module.switch_host()
        self.assertEqual(actions, ["enable", "disable"])
        self.assertEqual(self.module.load_state()["uplink_mode"], "device-uplink")

    def test_status_never_exposes_pairing_token(self) -> None:
        with mock.patch.object(
            self.module,
            "helper_request",
            return_value={
                "status": "ok",
                "enabled": False,
                "host_address": "192.168.5.242",
                "token": "a" * 64,
            },
        ):
            result = self.module.status()
        self.assertNotIn("token", json.dumps(result))

    def test_first_renew_timeout_is_tolerated(self) -> None:
        state = self.module.load_state()
        state["uplink_mode"] = "host-uplink"
        self.module.save_state(state)
        with (
            mock.patch.object(
                self.module,
                "helper_request",
                side_effect=self.module.UplinkError("temporary timeout"),
            ),
            mock.patch.object(self.module, "clear_host_network") as clear,
        ):
            result = self.module.reconcile()
        self.assertEqual(result["mode"], "host-uplink")
        self.assertEqual(result["renew_failures"], 1)
        clear.assert_not_called()
        saved = self.module.load_state()
        self.assertEqual(saved["uplink_mode"], "host-uplink")
        self.assertEqual(saved["uplink_last_result"], "renew-warning")

    def test_second_renew_timeout_rolls_back(self) -> None:
        state = self.module.load_state()
        state.update({"uplink_mode": "host-uplink", "uplink_renew_failures": 1})
        self.module.save_state(state)
        actions: list[str] = []

        def fake_helper(action: str, **_: object) -> dict[str, object]:
            actions.append(action)
            if action == "enable":
                raise self.module.UplinkError("temporary timeout")
            return {"status": "ok", "enabled": False}

        with (
            mock.patch.object(self.module, "helper_request", side_effect=fake_helper),
            mock.patch.object(self.module, "clear_host_network") as clear,
        ):
            with self.assertRaises(self.module.UplinkError):
                self.module.reconcile()
        self.assertEqual(actions, ["enable", "disable"])
        clear.assert_called_once_with()
        saved = self.module.load_state()
        self.assertEqual(saved["uplink_mode"], "device-uplink")
        self.assertEqual(saved["uplink_last_result"], "rolled-back")

    def test_successful_renew_resets_failure_counter(self) -> None:
        state = self.module.load_state()
        state.update({"uplink_mode": "host-uplink", "uplink_renew_failures": 1})
        self.module.save_state(state)
        helper_payload = {
            "status": "ok",
            "enabled": True,
            "host_address": "192.168.5.242",
            "dns_servers": ["1.1.1.1"],
            "lease_deadline_epoch": 1234,
        }
        with (
            mock.patch.object(self.module, "helper_request", return_value=helper_payload),
            mock.patch.object(self.module, "apply_host_network"),
        ):
            result = self.module.reconcile()
        self.assertEqual(result["mode"], "host-uplink")
        saved = self.module.load_state()
        self.assertEqual(saved["uplink_renew_failures"], 0)
        self.assertEqual(saved["uplink_lease_deadline_epoch"], 1234)
        self.assertEqual(saved["uplink_last_result"], "renewed")


if __name__ == "__main__":
    unittest.main()
