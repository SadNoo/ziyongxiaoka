from __future__ import annotations

import importlib.util
import io
import json
import stat
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "config"
    / "network"
    / "wangka-modem.py"
)


class WangkaModemTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = importlib.util.spec_from_file_location("wangka_modem", MODULE_PATH)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_config_scalar_reads_private_values_without_logging(self) -> None:
        text = 'web:\n  username: "user"\n  password: "secret-value"\n'
        self.assertEqual(self.module.config_scalar(text, "username"), "user")
        self.assertEqual(self.module.config_scalar(text, "password"), "secret-value")

    def test_config_scalar_accepts_vohive_flow_style(self) -> None:
        text = 'web: {username: user, password: "secret,value:2"}\ndevices: []\n'
        self.assertEqual(self.module.config_scalar(text, "username"), "user")
        self.assertEqual(
            self.module.config_scalar(text, "password"), "secret,value:2"
        )

    def test_config_scalar_does_not_read_other_sections(self) -> None:
        text = 'web: {username: user}\nother:\n  password: "wrong"\n'
        with self.assertRaises(self.module.CLIError):
            self.module.config_scalar(text, "password")

    def test_root_credential_store_is_atomic_and_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vohive-local-auth.json"
            self.module.save_credentials("user", "secret-value", path)
            self.assertEqual(
                self.module.stored_credentials(path), ("user", "secret-value")
            )
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(list(path.parent.glob(".vohive-local-auth.json.*")), [])

    def test_world_readable_credential_store_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vohive-local-auth.json"
            path.write_text(
                '{"username":"user","password":"secret-value"}\n',
                encoding="utf-8",
            )
            path.chmod(0o644)
            with self.assertRaises(self.module.CLIError):
                self.module.stored_credentials(path)

    def test_malformed_credential_store_is_rejected_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vohive-local-auth.json"
            path.write_text("not-json\n", encoding="utf-8")
            path.chmod(0o600)
            with self.assertRaises(self.module.CLIError):
                self.module.stored_credentials(path)

    def test_first_config_login_migrates_to_private_store(self) -> None:
        with (
            mock.patch.object(
                self.module, "stored_credentials", side_effect=FileNotFoundError
            ),
            mock.patch.object(
                self.module,
                "config_credentials",
                return_value=("user", "secret-value"),
            ),
            mock.patch.object(
                self.module, "login_with_credentials", return_value="token"
            ),
            mock.patch.object(self.module, "save_credentials") as save,
        ):
            self.assertEqual(self.module.login(), "token")
        save.assert_called_once_with("user", "secret-value")

    def test_bootstrap_verifies_password_before_saving(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "credentials.env"
            target = Path(directory) / "local-auth.json"
            source.write_text("WANGKA_USER_PASSWORD='secret-value'\n", encoding="utf-8")
            with (
                mock.patch.object(self.module, "login_with_credentials") as login,
                mock.patch.object(self.module, "CREDENTIAL_PATH", target),
                redirect_stdout(io.StringIO()),
            ):
                self.module.command_credential_bootstrap(
                    "", Namespace(path=str(source))
                )
            login.assert_called_once_with("user", "secret-value")
            self.assertEqual(
                self.module.stored_credentials(target), ("user", "secret-value")
            )

    def test_public_help_hides_deployment_bootstrap(self) -> None:
        help_text = self.module.build_parser().format_help()
        self.assertNotIn("credential-bootstrap-file", help_text)
        self.assertNotIn("reconnect-saved-uplink", help_text)
        self.assertNotIn("data-suspend", help_text)

    def test_hidden_control_failure_uses_structured_json_stdout(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(
                self.module.sys,
                "argv",
                ["wangka-modem", "reconnect-saved-uplink"],
            ),
            mock.patch.object(
                self.module,
                "login",
                side_effect=self.module.CLIError("VoHive API is unavailable"),
            ),
            redirect_stdout(output),
        ):
            result = self.module.main()
        self.assertEqual(result, 1)
        self.assertEqual(
            json.loads(output.getvalue()),
            {"status": "error", "message": "VoHive API is unavailable"},
        )

    def test_data_suspend_preserves_network_preference(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            preference = Path(directory) / "network.json"
            self.module.save_network_preference(True, "internet", "v4", preference)
            with (
                mock.patch.object(self.module, "NETWORK_PREFERENCE_PATH", preference),
                mock.patch.object(
                    self.module,
                    "request_json",
                    return_value={"status": "ok", "network_connected": False},
                ) as request_json,
                redirect_stdout(io.StringIO()),
            ):
                self.module.command_data_suspend("token", Namespace())
            self.assertEqual(
                self.module.load_network_preference(preference),
                {"enabled": True, "apn": "internet", "ip_version": "v4"},
            )
            request_json.assert_called_once_with(
                "PATCH",
                "/api/devices/onboard-qmi/network",
                token="token",
                payload={"enabled": False},
                timeout=60.0,
            )

    def test_network_preference_is_atomic_private_and_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "modem-network.json"
            self.module.save_network_preference(True, "internet", "v4v6", path)
            self.assertEqual(
                self.module.load_network_preference(path),
                {"enabled": True, "apn": "internet", "ip_version": "v4v6"},
            )
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with self.assertRaises(self.module.CLIError):
            self.module.save_network_preference(True, "bad apn")

    def test_status_omits_hardware_and_sim_identifiers(self) -> None:
        overview = {
            "devices": [
                {
                    "running": True,
                    "healthy": True,
                    "control_online": True,
                    "radio_registered": True,
                    "network_connected": True,
                    "backend_mode": "qmi",
                    "modem": {
                        "operator": "carrier",
                        "network_mode": "LTE",
                        "signal_dbm": -80,
                        "imei": "synthetic-imei",
                        "imsi": "synthetic-imsi",
                        "iccid": "synthetic-iccid",
                    },
                }
            ]
        }
        output = io.StringIO()
        with (
            mock.patch.object(self.module, "request_json", return_value=overview),
            redirect_stdout(output),
        ):
            self.module.command_status("token", Namespace())
        parsed = json.loads(output.getvalue())
        self.assertTrue(parsed["network_connected"])
        serialized = output.getvalue()
        self.assertNotIn("synthetic-imei", serialized)
        self.assertNotIn("synthetic-imsi", serialized)
        self.assertNotIn("synthetic-iccid", serialized)
        self.assertNotIn("imei", serialized.lower())
        self.assertNotIn("imsi", serialized.lower())
        self.assertNotIn("iccid", serialized.lower())

    def test_data_connect_uses_vohive_network_api(self) -> None:
        response = {"status": "ok", "message": "started", "network_connected": True}
        output = io.StringIO()
        args = Namespace(apn="internet", ip_version="v4v6")
        with (
            mock.patch.object(self.module, "save_network_preference") as save,
            mock.patch.object(self.module, "request_json", return_value=response) as request,
            redirect_stdout(output),
        ):
            self.module.command_data_connect("token", args)
        self.assertEqual(request.call_args.args[:2], ("PATCH", "/api/devices/onboard-qmi/network"))
        self.assertEqual(request.call_args.kwargs["payload"]["apn"], "internet")
        save.assert_called_once_with(True, "internet", "v4v6")
        self.assertTrue(json.loads(output.getvalue())["network_connected"])

    def test_saved_uplink_reconnect_uses_registered_vohive_device(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(
                self.module,
                "load_network_preference",
                return_value={"enabled": True, "apn": "internet", "ip_version": "v4"},
            ),
            mock.patch.object(
                self.module,
                "device_overview",
                return_value={"running": True, "healthy": True, "radio_registered": True},
            ),
            mock.patch.object(
                self.module,
                "request_json",
                side_effect=[
                    {"status": "ok", "network_connected": False},
                    {"status": "ok", "network_connected": True},
                ],
            ) as request,
            redirect_stdout(output),
        ):
            self.module.command_reconnect("token", Namespace())
        self.assertEqual(request.call_count, 2)
        self.assertIs(request.call_args_list[0].kwargs["payload"]["enabled"], False)
        self.assertEqual(request.call_args_list[1].kwargs["payload"]["apn"], "internet")
        self.assertTrue(json.loads(output.getvalue())["network_connected"])

    def test_saved_uplink_reconnect_skips_unregistered_radio(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(
                self.module,
                "load_network_preference",
                return_value={"enabled": True, "apn": "internet", "ip_version": "v4v6"},
            ),
            mock.patch.object(
                self.module,
                "device_overview",
                return_value={"running": True, "healthy": True, "radio_registered": False},
            ),
            mock.patch.object(self.module, "request_json") as request,
            redirect_stdout(output),
        ):
            self.module.command_reconnect("token", Namespace())
        request.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["reason"], "radio-not-ready")

    def test_invalid_apn_is_rejected_before_api_call(self) -> None:
        with mock.patch.object(self.module, "request_json") as request:
            with self.assertRaises(self.module.CLIError):
                self.module.command_data_connect(
                    "token", Namespace(apn="bad apn", ip_version="v4")
                )
        request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
